// Deci/Music/Playback/MusicMixWindow.swift
// Which slice of a long queue the mix orders. Pure index math, the queue itself stays elsewhere.

import Foundation

nonisolated enum MusicMixWindow {
    static let size = 24
    /// A top-up orders the next window once this many songs of the current one were played.
    static let topUpAfter = 6

    /// Indices into the upcoming list (everything after the playing song): skips the user-queued prefix, then up to
    /// `size` songs. Empty when nothing is left to order.
    static func range(upcomingCount: Int, queuedCount: Int, size: Int = size) -> Range<Int> {
        let start = max(0, min(upcomingCount, queuedCount))
        let end = min(upcomingCount, start + max(0, size))
        return start..<end
    }

    static func window(upcoming: [String], queuedCount: Int, size: Int = size) -> [String] {
        Array(upcoming[range(upcomingCount: upcoming.count, queuedCount: queuedCount, size: size)])
    }

    static func needsTopUp(playedSinceOrdering: Int) -> Bool { playedSinceOrdering >= topUpAfter }
}
