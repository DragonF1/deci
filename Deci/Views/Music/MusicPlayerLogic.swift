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

/// What the Up next screen lists: the song in the player, the songs after it and where the queue came from. The songs
/// before the current one are not listed (Previous still reaches them).
@MainActor
struct MusicQueueListing {
    let current: MusicTrack?
    let upcoming: [MusicTrack]
    let sourceLine: String?

    init(queue: MusicQueue) {
        current = queue.current
        upcoming = Array(queue.upcoming)
        sourceLine = Self.sourceLine(for: queue.source)
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

/// The line under the Up next header that says what the three toggles are set to.
nonisolated enum MusicPlaybackStatus {
    /// "Shuffle off · Loop all · Autoplay on".
    static func text(shuffle: Bool, loop: MusicLoopMode, autoplay: Bool) -> String {
        let separator = " \u{00B7} "
        return "Shuffle \(word(shuffle))" + separator + "Loop \(loopWord(loop))" + separator + "Autoplay \(word(autoplay))"
    }

    /// Off, all (the queue starts over) or one (the song repeats).
    static func loopWord(_ loop: MusicLoopMode) -> String {
        switch loop {
        case .off: "off"
        case .playlist: "all"
        case .song: "one"
        }
    }

    private static func word(_ isOn: Bool) -> String { isOn ? "on" : "off" }
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
