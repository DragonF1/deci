// DeciTests/Music/MixShuffle/MusicQueueMixOrderTests.swift
// Tier 4 P3: the queue side of Mix. Entering it moves no song, ordering lays the unqueued upcoming songs into their own
// slots, and Off still puts the natural order back.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("MusicQueue Mix")
struct MusicQueueMixOrderTests {
    private func ids(_ tracks: some Sequence<MusicTrack>) -> [String] { tracks.map(\.videoId) }

    private func makeQueue(_ list: [String], current: Int = 0) -> MusicQueue {
        var queue = MusicQueue()
        let tracks = list.map { MusicSamples.track($0) }
        queue.start(with: tracks[0])
        queue.append(Array(tracks.dropFirst()), continuation: nil)
        for _ in 0..<current { queue.advance() }
        return queue
    }

    @Test("beginMix marks the queue shuffled and moves nothing")
    func beginMixMovesNothing() {
        var queue = makeQueue(["a", "b", "c", "d"], current: 1)
        queue.beginMix()
        #expect(queue.isShuffled)
        #expect(ids(queue.tracks) == ["a", "b", "c", "d"])
        #expect(queue.current?.videoId == "b")
    }

    @Test("beginMix on a page started mid-way puts the tapped song first and wraps the rows above it behind")
    func beginMixMixingEarlier() {
        var queue = makeQueue(["a", "b", "c", "d", "e"], current: 2)
        queue.beginMix(mixingEarlier: true)
        #expect(ids(queue.tracks) == ["c", "d", "e", "a", "b"])
        #expect(queue.currentIndex == 0)
    }

    @Test("beginMix keeps the songs the listener queued right after the current one")
    func beginMixKeepsQueued() {
        var queue = makeQueue(["a", "b", "c", "d", "e"], current: 2)
        queue.playNext(MusicSamples.track("a"))
        queue.beginMix(mixingEarlier: true)
        #expect(ids(queue.upcoming).first == "a")
        #expect(Set(ids(queue.tracks)) == ["a", "b", "c", "d", "e"])
    }

    @Test("beginMix does nothing to a queue that is already shuffled")
    func beginMixTwice() {
        var queue = makeQueue(["a", "b", "c", "d"])
        var generator = MusicShuffleGenerator(seed: 3)
        queue.shuffle(using: &generator)
        let before = ids(queue.tracks)
        queue.beginMix(mixingEarlier: true)
        #expect(ids(queue.tracks) == before)
    }

    @Test("mixOrder lays the songs after the current one in the order given")
    func mixOrderLaysOut() {
        var queue = makeQueue(["a", "b", "c", "d", "e"])
        queue.mixOrder(["d", "b", "e", "c"])
        #expect(ids(queue.tracks) == ["a", "d", "b", "e", "c"])
        #expect(queue.current?.videoId == "a")
        #expect(queue.isShuffled)
    }

    @Test("mixOrder never moves the played songs or the current one")
    func mixOrderKeepsPast() {
        var queue = makeQueue(["a", "b", "c", "d", "e"], current: 2)
        queue.mixOrder(["e", "d"])
        #expect(ids(queue.tracks) == ["a", "b", "c", "e", "d"])
        #expect(queue.currentIndex == 2)
    }

    @Test("mixOrder leaves the listener's queued songs where they are")
    func mixOrderSkipsQueued() {
        var queue = makeQueue(["a", "b", "c", "d", "e"])
        queue.playNext(MusicSamples.track("e"))
        #expect(ids(queue.upcoming).first == "e")
        queue.mixOrder(["e", "d", "c", "b"])
        #expect(ids(queue.tracks) == ["a", "e", "d", "c", "b"])
    }

    @Test("an id that is not an upcoming song is ignored and a song the order leaves out keeps its slot")
    func mixOrderIgnoresStrangers() {
        var queue = makeQueue(["a", "b", "c", "d"])
        queue.mixOrder(["zzz", "c", "b"])
        #expect(ids(queue.tracks) == ["a", "c", "b", "d"])
        queue.mixOrder(["d", "d", "c"])
        #expect(Set(ids(queue.tracks)) == ["a", "b", "c", "d"])
        #expect(queue.tracks.count == 4)
    }

    @Test("mixOrder on an empty queue does nothing")
    func mixOrderEmpty() {
        var queue = MusicQueue()
        queue.mixOrder(["a"])
        #expect(queue.isEmpty)
    }

    @Test("Off after Mix puts the natural order back and stays on the current song")
    func unshuffleAfterMix() {
        var queue = makeQueue(["a", "b", "c", "d", "e"], current: 1)
        queue.beginMix()
        queue.mixOrder(["e", "d", "c"])
        #expect(ids(queue.tracks) == ["a", "b", "e", "d", "c"])
        queue.unshuffle()
        #expect(ids(queue.tracks) == ["a", "b", "c", "d", "e"])
        #expect(queue.current?.videoId == "b")
        #expect(!queue.isShuffled)
    }

    @Test("unqueuedUpcoming lists the upcoming songs the listener did not queue")
    func unqueuedUpcoming() {
        var queue = makeQueue(["a", "b", "c", "d"])
        queue.playNext(MusicSamples.track("d"))
        #expect(ids(queue.unqueuedUpcoming) == ["b", "c"])
        #expect(MusicQueue().unqueuedUpcoming.isEmpty)
    }
}
