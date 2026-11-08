// Deci/Music/Playback/MusicPlaybackModes.swift
import Foundation

/// What the loop button does, in the order it cycles through them.
enum MusicLoopMode: String, Codable, CaseIterable, Sendable {
    case off
    /// When the last track of the queue ends, start again from its first track.
    case playlist
    /// When a track ends, play it again.
    case song

    /// Off, then Loop playlist, then Loop song, then Off again.
    var next: MusicLoopMode {
        switch self {
        case .off: .playlist
        case .playlist: .song
        case .song: .off
        }
    }
}

/// The playback options that are remembered across launches.
struct MusicPlaybackPreferences: Equatable, Sendable {
    /// The fade lengths Settings offers, in seconds.
    static let crossfadeRange: ClosedRange<Double> = 1...12
    static let defaultCrossfadeSeconds = 6.0

    /// `seconds` held to `crossfadeRange`; a value that is not a number is the default.
    static func clampedCrossfade(_ seconds: Double) -> Double {
        guard seconds.isFinite else { return defaultCrossfadeSeconds }
        return min(max(seconds, crossfadeRange.lowerBound), crossfadeRange.upperBound)
    }

    var shuffle = false
    var loop = MusicLoopMode.off
    /// Keep playing recommended songs after a playlist or an album has finished.
    var autoplay = true
    /// Fade the next song in over the end of the playing one. Off is the gapless switch.
    var crossfade = false
    /// How long that fade lasts, 1 to 12 seconds.
    var crossfadeSeconds = MusicPlaybackPreferences.defaultCrossfadeSeconds {
        didSet { crossfadeSeconds = Self.clampedCrossfade(crossfadeSeconds) }
    }

    /// Line songs of matching tempo up on the beat while they crossfade (only with Crossfade on).
    var beatMix = true

    /// Keep two singers from overlapping in a mix (only with Crossfade on).
    var vocalGuard = true

    init(
        shuffle: Bool = false, loop: MusicLoopMode = .off, autoplay: Bool = true, crossfade: Bool = false,
        crossfadeSeconds: Double = defaultCrossfadeSeconds, beatMix: Bool = true, vocalGuard: Bool = true
    ) {
        self.beatMix = beatMix
        self.vocalGuard = vocalGuard
        self.shuffle = shuffle
        self.loop = loop
        self.autoplay = autoplay
        self.crossfade = crossfade
        self.crossfadeSeconds = Self.clampedCrossfade(crossfadeSeconds)
    }
}

/// A seedable source of random numbers (SplitMix64), so a test can replay a shuffle.
struct MusicShuffleGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
