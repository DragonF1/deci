// Deci/Views/Music/MusicPlayerLogic.swift
import SwiftUI

// The rules of the player screens (Now Playing, Lyrics, Up next) kept apart from the views, so they are tested without
// drawing anything: how dark the backdrop is, what the output control says, what Up next lists, what the lyrics caption
// reads and where a slider's knob sits.

/// How much black is poured over the blurred cover behind a player screen, as opacities at the top, the middle and the
/// bottom of the popover. Now Playing lets the cover show; Lyrics and Up next sit under text, so they are darker.
nonisolated enum MusicPlayerDim {
    struct Stops: Equatable {
        let top: Double
        let middle: Double
        let bottom: Double
    }

    static let artwork = Stops(top: 0.32, middle: 0.45, bottom: 0.64)
    static let text = Stops(top: 0.46, middle: 0.56, bottom: 0.74)

    static func stops(for screen: MusicShellScreen) -> Stops {
        switch screen {
        case .browse, .nowPlaying: artwork
        case .lyrics, .queue: text
        }
    }
}

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

/// The caption above the lyrics: unsynced lyrics are marked as such, everything else is just "Lyrics".
@MainActor
enum MusicLyricsCaption {
    static func text(for state: MusicLyricsStore.State) -> String {
        if case .loaded(.plain) = state { return "Not synced" }
        return "Lyrics"
    }
}

/// The measures of a thin slider (the scrubber and the volume): the filled part and the knob, held inside the track.
nonisolated enum MusicSliderGeometry {
    /// The knob's leading edge along a track `width` wide: it runs from the start to one knob short of the end, so the
    /// knob never leaves the track. A fraction outside 0...1 or not a number is held inside it.
    static func knobOffset(fraction: Double, width: CGFloat, knob: CGFloat) -> CGFloat {
        guard width.isFinite, knob.isFinite else { return 0 }
        return max(0, width - knob) * CGFloat(clamped(fraction))
    }

    /// The width of the filled part of a track `width` wide.
    static func filledWidth(fraction: Double, width: CGFloat) -> CGFloat {
        guard width.isFinite, width > 0 else { return 0 }
        return width * CGFloat(clamped(fraction))
    }

    private static func clamped(_ fraction: Double) -> Double {
        fraction.isFinite ? min(max(fraction, 0), 1) : 0
    }
}
