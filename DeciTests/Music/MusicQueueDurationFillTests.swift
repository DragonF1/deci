// DeciTests/Music/MusicQueueDurationFillTests.swift
// A song that came into the queue without a length (a Home tile, an artist page row) gets it from data the app already
// holds: a length known by id (an analysis row, a stream resolve).

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("MusicQueue duration fill")
struct MusicQueueDurationFillTests {
    private func song(_ id: String, seconds: Int?) -> Deci.MusicTrack {
        MusicSamples.track(id, title: "Song \(id)", seconds: seconds)
    }

    private func queue(_ seconds: [String: Int?]) -> MusicQueue {
        var queue = MusicQueue()
        let ids = ["a", "b", "c", "d"]
        queue.start(
            page: ids.map { song($0, seconds: seconds[$0] ?? nil) },
            playing: song("a", seconds: seconds["a"] ?? nil),
            browseId: "VLPL1", continuation: nil, automixPlaylistId: nil, mixPlaylistId: nil
        )
        return queue
    }

    @Test("a length known by id fills the songs that have none, in the queue, the staged radio and the parked radio")
    func fillsByIdEverywhere() {
        var queue = queue(["a": 100, "b": nil, "c": 120, "d": nil])
        _ = queue.stageAutoplay([song("r1", seconds: nil), song("r2", seconds: 90)], continuation: nil, seed: "d")
        let changed = queue.fillMissingDurations(["b": 211, "d": 187, "r1": 205])
        #expect(changed)
        #expect(queue.tracks.map(\.durationSeconds) == [100, 211, 120, 187])
        #expect(queue.autoplay.map(\.durationSeconds) == [205, 90])
    }

    @Test("a song that already has a length keeps it, and nothing changes when nothing is filled")
    func keepsOwnLength() {
        var queue = queue(["a": 100, "b": 150, "c": 120, "d": 80])
        let before = queue.tracks
        let first = queue.fillMissingDurations(["a": 999, "b": 999])
        let second = queue.fillMissingDurations([:])
        #expect(!first && !second)
        #expect(queue.tracks == before)
    }

    @Test("zero and negative lengths are not a length")
    func ignoresNonsense() {
        var queue = queue(["a": 100, "b": nil, "c": 120, "d": 80])
        let zero = queue.fillMissingDurations(["b": 0])
        let negative = queue.fillMissingDurations(["b": -4])
        #expect(!zero && !negative)
        #expect(queue.tracks[1].durationSeconds == nil)
    }
}
