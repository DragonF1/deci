// Deci/Views/Music/MusicPlayerLogic.swift
import SwiftUI

// The rules of the player column and the panels beside it (Lyrics, Up next) kept apart from the views, so they are
// tested without drawing anything: what the output control says, what Up next lists and what its header says, what the
// lyrics header and footer read and where a slider's knob sits.

/// The small label under the output control: where the music comes out, and the EQ profile in use on it.
nonisolated enum MusicOutputLabel {
    static let fallback = "Default output"

    /// "Device name · profile", the device alone when it has no profile, or "Default output" when the device is not
    /// known. A profile is never shown without its device.
    static func text(deviceName: String?, profileName: String?) -> String {
        let device = deviceName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !device.isEmpty else { return fallback }
        let profile = profileName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return profile.isEmpty ? device : device + " \u{00B7} " + profile
    }
}

/// What the Up next screen lists: the song in the player, every song that will play after it in play order, and where
/// the queue came from. After the queue's own songs come the next lap under Loop playlist (the songs before the current
/// one, from the start of the play order) or, with Autoplay, the radio staged to follow a page. The screen marks where
/// that radio starts, so the listing says which row it opens on. A tapped song that no radio will follow, because
/// Autoplay is off, names no source.
@MainActor
struct MusicQueueListing {
    let current: MusicTrack?
    let upcoming: [MusicTrack]
    let sourceLine: String?
    /// The index in `upcoming` where the staged radio's songs begin; nil when none are listed.
    let autoplayStart: Int?

    /// How many of the listed songs are the queue's own: all of them unless a staged radio follows.
    var queuedCount: Int { autoplayStart ?? upcoming.count }

    /// The small label over the first staged song.
    static let autoplayKicker = "AUTOPLAY"

    /// `autoplayIsOn` is the Autoplay setting; it only matters to a tapped song still waiting for its first radio.
    init(queue: MusicQueue, listsNextLap: Bool = false, listsAutoplay: Bool = false, autoplayIsOn: Bool = true) {
        current = queue.current
        var upcoming = Array(queue.upcoming)
        var autoplayStart: Int?
        if listsNextLap, let currentIndex = queue.currentIndex {
            upcoming += queue.tracks[..<currentIndex]
            // A queue of one song loops that song.
            if upcoming.isEmpty, let current = queue.current { upcoming = [current] }
        } else if listsAutoplay, queue.isPage {
            if !queue.autoplay.isEmpty { autoplayStart = upcoming.count }
            upcoming += queue.autoplay
        }
        self.upcoming = upcoming
        self.autoplayStart = autoplayStart
        // With Autoplay off a lone song never gets the radio its source would name.
        sourceLine = queue.awaitsFirstRadioPage && !autoplayIsOn ? nil : Self.sourceLine(for: queue.source)
    }

    /// Whether the row at `shownIndex` of a filtered list is the first shown row from the staged radio, so the
    /// "AUTOPLAY" label goes above it. `matches` are the list indices that pass the filter, in order, and `shownIndex`
    /// counts within them; an unfiltered list passes every index. With no staged songs, or no shown row from them,
    /// no row opens the radio.
    static func opensAutoplay(shownIndex: Int, matches: [Int], autoplayStart: Int?) -> Bool {
        guard let autoplayStart, matches.indices.contains(shownIndex), matches[shownIndex] >= autoplayStart else {
            return false
        }
        return shownIndex == 0 || matches[shownIndex - 1] < autoplayStart
    }

    /// The small label over the song in the player: "NOW PLAYING · FROM PLAYLIST", or just "NOW PLAYING" while the
    /// queue's source is not known.
    static func nowPlayingKicker(sourceLine: String?) -> String {
        guard let sourceLine, !sourceLine.isEmpty else { return "NOW PLAYING" }
        return "NOW PLAYING \u{00B7} " + sourceLine.uppercased()
    }

    /// The small label over the songs that follow: "NEXT IN QUEUE · 12".
    static func nextKicker(count: Int) -> String {
        "NEXT IN QUEUE \u{00B7} \(max(count, 0))"
    }

    /// The same label over a filtered list: "NEXT IN QUEUE · 1 OF 4".
    static func nextKicker(matched: Int, total: Int) -> String {
        "NEXT IN QUEUE \u{00B7} \(max(matched, 0)) OF \(max(total, 0))"
    }

    /// The line under "Playing Next". The queue knows its source's id, not its name, so the line says what kind of
    /// source it was where the id tells.
    static func sourceLine(for source: MusicQueue.Source?) -> String? {
        switch source {
        case nil:
            nil
        case .radio:
            "From radio"
        case .page(let browseId):
            if browseId.hasPrefix("MPRE") { "From album" }
            else if browseId == MusicBrowseStore.likedMusic.browseId || browseId == "LM" { "From Liked music" }
            else if browseId.hasPrefix("VL") || browseId.hasPrefix("PL") { "From playlist" }
            else { "From playlist or album" }
        }
    }
}

/// The three toggles of the Up next header, in the order they sit.
nonisolated enum MusicPlaybackToggle: CaseIterable, Equatable {
    case shuffle
    case loop
    case autoplay

    /// What the toggle is called for VoiceOver and the tooltip; the loop's own wording says its mode.
    func title(loop: MusicLoopMode) -> String {
        switch self {
        case .shuffle: "Shuffle"
        case .loop: loop.label
        case .autoplay: "Autoplay"
        }
    }

    func symbol(loop: MusicLoopMode) -> String {
        switch self {
        case .shuffle: "shuffle"
        case .loop: loop.systemImage
        case .autoplay: "infinity"
        }
    }

    func isOn(shuffle: Bool, loop: MusicLoopMode, autoplay: Bool) -> Bool {
        switch self {
        case .shuffle: shuffle
        case .loop: loop != .off
        case .autoplay: autoplay
        }
    }
}

/// What the Lyrics panel says around the lines: the tag by the title, the kicker at the foot and the paragraphs of
/// lyrics that are not timed.
@MainActor
enum MusicLyricsCaption {
    static let title = "Lyrics"

    /// The tag beside the title: unsynced lyrics are marked as such, everything else has none.
    static func tag(for state: MusicLyricsStore.State) -> String? {
        if case .loaded(.plain) = state { return "Not synced" }
        return nil
    }

    /// The kicker at the foot, only under lyrics that are on screen.
    static func footer(for state: MusicLyricsStore.State) -> String? {
        switch state {
        case .loaded(.synced): "SYNCED LYRICS"
        case .loaded(.plain): "PLAIN LYRICS"
        default: nil
        }
    }

    /// The paragraphs of plain lyrics: split on empty lines, each paragraph's lines trimmed and kept in order.
    static func stanzas(of text: String) -> [String] {
        var stanzas: [String] = []
        var current: [String] = []
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                if !current.isEmpty { stanzas.append(current.joined(separator: "\n")) }
                current = []
            } else {
                current.append(trimmed)
            }
        }
        if !current.isEmpty { stanzas.append(current.joined(separator: "\n")) }
        return stanzas
    }
}

/// The measures of a thin slider (the volume): the knob, held inside the track.
nonisolated enum MusicSliderGeometry {
    /// The knob's leading edge along a track `width` wide: it runs from the start to one knob short of the end, so the
    /// knob never leaves the track. A fraction outside 0...1 or not a number is held inside it.
    static func knobOffset(fraction: Double, width: CGFloat, knob: CGFloat) -> CGFloat {
        guard width.isFinite, knob.isFinite else { return 0 }
        return max(0, width - knob) * CGFloat(clamped(fraction))
    }

    private static func clamped(_ fraction: Double) -> Double {
        fraction.isFinite ? min(max(fraction, 0), 1) : 0
    }
}
