// DeciTests/Music/MusicQueueOfflineTests.swift
// Moving through the queue when only some of its songs can play: offline, a song that is not downloaded is stepped over
// in both directions, and the position lands on the next song that can play, never on the ones between.

import Foundation
import Testing
@testable import Deci

@Suite("MusicQueue offline stepping")
struct MusicQueueOfflineTests {
    private func song(_ id: String) -> MusicTrack { MusicSamples.track(id, title: "Song \(id)") }

    /// A page queue of `ids`, positioned on `current`.
    private func queue(_ ids: [String], current: String) -> MusicQueue {
        var queue = MusicQueue()
        queue.start(page: ids.map(song), playing: song(current), browseId: "VLPLx", continuation: nil)
        return queue
    }

    private func playable(_ ids: Set<String>) -> (MusicTrack) -> Bool {
        { ids.contains($0.videoId) }
    }

    @Test("advance(where:) skips the songs that cannot play and lands on the next one that can")
    func advanceSkips() {
        var queue = queue(["a", "b", "c", "d"], current: "a")

        let next = queue.advance(where: playable(["a", "c", "d"]))

        #expect(next?.videoId == "c")
        #expect(queue.current?.videoId == "c")
    }

    @Test("advance(where:) with nothing playable ahead stays where it is and answers nil")
    func advanceNothingAhead() {
        var queue = queue(["a", "b", "c"], current: "a")

        let next = queue.advance(where: playable(["a"]))

        #expect(next == nil)
        #expect(queue.current?.videoId == "a")
    }

    @Test("advance(where:) at the end of the queue answers nil")
    func advanceAtEnd() {
        var queue = queue(["a", "b"], current: "b")

        #expect(queue.advance(where: playable(["a", "b"])) == nil)
        #expect(queue.current?.videoId == "b")
    }

    @Test("retreat(where:) skips the songs that cannot play going back")
    func retreatSkips() {
        var queue = queue(["a", "b", "c", "d"], current: "d")

        let previous = queue.retreat(where: playable(["a", "d"]))

        #expect(previous?.videoId == "a")
        #expect(queue.current?.videoId == "a")
    }

    @Test("retreat(where:) with nothing playable behind stays where it is and answers nil")
    func retreatNothingBehind() {
        var queue = queue(["a", "b", "c"], current: "c")

        #expect(queue.retreat(where: playable(["c"])) == nil)
        #expect(queue.current?.videoId == "c")
    }

    @Test("hasNext(where:) and hasPrevious(where:) say whether a playable song lies that way")
    func neighbours() {
        let queue = queue(["a", "b", "c", "d"], current: "b")

        #expect(queue.hasNext(where: playable(["d"])))
        #expect(!queue.hasNext(where: playable(["a", "b"])))
        #expect(queue.hasPrevious(where: playable(["a"])))
        #expect(!queue.hasPrevious(where: playable(["b", "c", "d"])))
    }

    @Test("wrapToStart(where:) lands on the first song that can play")
    func wrapSkips() {
        var queue = queue(["a", "b", "c"], current: "c")

        let first = queue.wrapToStart(where: playable(["b", "c"]))

        #expect(first?.videoId == "b")
        #expect(queue.current?.videoId == "b")
    }

    @Test("wrapToStart(where:) with nothing playable stays where it is and answers nil")
    func wrapNothing() {
        var queue = queue(["a", "b", "c"], current: "c")

        #expect(queue.wrapToStart(where: playable([])) == nil)
        #expect(queue.current?.videoId == "c")
    }

    @Test("an empty queue has no neighbours")
    func emptyQueue() {
        var queue = MusicQueue()

        #expect(!queue.hasNext(where: { _ in true }))
        #expect(!queue.hasPrevious(where: { _ in true }))
        #expect(queue.advance(where: { _ in true }) == nil)
        #expect(queue.retreat(where: { _ in true }) == nil)
    }
}
