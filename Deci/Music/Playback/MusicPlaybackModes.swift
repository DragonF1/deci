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

/// The three playback options that are remembered across launches.
struct MusicPlaybackPreferences: Equatable, Sendable {
    var shuffle = false
    var loop = MusicLoopMode.off
    /// Keep playing recommended songs after a playlist or an album has finished.
    var autoplay = true
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
