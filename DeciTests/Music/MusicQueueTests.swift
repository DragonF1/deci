// DeciTests/Music/MusicQueueTests.swift
// The play order: the tapped track first, radio pages appended without repeats, a moving
// current position and the "running low" rule that asks for the next page.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("MusicQueue")
struct MusicQueueTests {
    private func ids(_ tracks: some Sequence<MusicTrack>) -> [String] { tracks.map(\.videoId) }

    private func makeQueue(_ list: [String], current: Int = 0, continuation: String? = nil) -> MusicQueue {
        var queue = MusicQueue()
        let tracks = list.map { MusicSamples.track($0) }
        queue.start(with: tracks[0])
        queue.append(Array(tracks.dropFirst()), continuation: continuation)
        for _ in 0..<current { queue.advance() }
        return queue
    }

    @Test("starts empty")
    func startsEmpty() {
        let queue = MusicQueue()
        #expect(queue.isEmpty)
        #expect(queue.current == nil)
        #expect(queue.upcomingCount == 0)
        #expect(queue.hasNext == false)
        #expect(queue.hasPrevious == false)
    }

    @Test("start makes the tapped track the only item and the radio seed")
    func start() {
        var queue = makeQueue(["a", "b", "c"], continuation: "c1")
        queue.start(with: MusicSamples.track("z"))
        #expect(ids(queue.tracks) == ["z"])
        #expect(queue.current?.videoId == "z")
        #expect(queue.seedVideoId == "z")
        #expect(queue.continuation == nil)
    }

    @Test("append adds new tracks after the current one and keeps the continuation")
    func append() {
        var queue = makeQueue(["a"])
        queue.append(MusicSamples.tracks("b", "c"), continuation: "c1")
        #expect(ids(queue.tracks) == ["a", "b", "c"])
        #expect(ids(queue.upcoming) == ["b", "c"])
        #expect(queue.continuation == "c1")
    }

    @Test("append drops the seed and any track already queued, in the page and across pages")
    func appendDedupes() {
        var queue = makeQueue(["a"])
        let added = queue.append(MusicSamples.tracks("a", "b", "b", "c"), continuation: "c1")
        #expect(added == 2)
        #expect(ids(queue.tracks) == ["a", "b", "c"])
        let more = queue.append(MusicSamples.tracks("c", "a", "d"), continuation: nil)
        #expect(more == 1)
        #expect(ids(queue.tracks) == ["a", "b", "c", "d"])
    }

    @Test("a page without a continuation ends the radio")
    func appendLastPage() {
        var queue = makeQueue(["a"], continuation: "c1")
        queue.append(MusicSamples.tracks("b"), continuation: nil)
        #expect(queue.continuation == nil)
        #expect(queue.needsMore == false)
    }

    @Test("advance and retreat move the current position and stop at the ends")
    func moves() {
        var queue = makeQueue(["a", "b", "c"])
        #expect(queue.retreat() == nil)
        #expect(queue.advance()?.videoId == "b")
        #expect(queue.hasPrevious)
        #expect(queue.advance()?.videoId == "c")
        #expect(queue.advance() == nil)
        #expect(queue.current?.videoId == "c")
        #expect(queue.retreat()?.videoId == "b")
        #expect(ids(queue.tracks) == ["a", "b", "c"])
    }

    @Test("upcoming leaves out what already played")
    func upcomingSkipsPlayed() {
        let queue = makeQueue(["a", "b", "c", "d"], current: 2)
        #expect(ids(queue.upcoming) == ["d"])
        #expect(queue.upcomingCount == 1)
        #expect(ids(queue.fromCurrent) == ["c", "d"])
    }

    @Test("jump moves to the named track and ignores unknown ones")
    func jump() {
        var queue = makeQueue(["a", "b", "c", "d"])
        #expect(queue.jump(to: "d")?.videoId == "d")
        #expect(queue.current?.videoId == "d")
        #expect(queue.jump(to: "nope") == nil)
        #expect(queue.current?.videoId == "d")
        #expect(queue.jump(to: "b")?.videoId == "b")
        #expect(ids(queue.upcoming) == ["c", "d"])
    }

    @Test("needsMore: a continuation exists and three or fewer tracks are left")
    func needsMore() {
        var queue = makeQueue(["a", "b", "c", "d", "e"], continuation: "c1")
        #expect(queue.upcomingCount == 4)
        #expect(queue.needsMore == false)
        queue.advance()
        #expect(queue.upcomingCount == 3)
        #expect(queue.needsMore)
        queue.advance()
        #expect(queue.needsMore)
    }

    @Test("needsMore is false without a continuation however short the queue")
    func needsMoreWithoutContinuation() {
        #expect(makeQueue(["a"]).needsMore == false)
    }

    @Test("clear forgets everything")
    func clear() {
        var queue = makeQueue(["a", "b"], continuation: "c1")
        queue.clear()
        #expect(queue == MusicQueue())
    }
}
