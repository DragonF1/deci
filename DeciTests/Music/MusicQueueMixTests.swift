// DeciTests/Music/MusicQueueMixTests.swift
// What a queue remembers for an endless mix: the playlist id of the mix page it was started from, how that mark lives and
// dies (a page sets it, a tapped song or a clear drops it, adopting the radio keeps it), and when the mix can still grow.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("MusicQueue mix")
struct MusicQueueMixTests {
    private static let letters = ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l"]
    private static let mixId = "RDTMAK5uy_mix"

    private func song(_ id: String) -> Deci.MusicTrack { MusicSamples.track(id, title: "Song \(id)") }

    private func makePage(
        _ list: [String] = MusicQueueMixTests.letters,
        tap: String? = nil,
        continuation: String? = nil,
        mixPlaylistId: String? = MusicQueueMixTests.mixId,
        automixPlaylistId: String? = nil
    ) -> MusicQueue {
        var queue = MusicQueue()
        queue.start(
            page: list.map { song($0) },
            playing: song(tap ?? list[0]),
            browseId: "VL" + Self.mixId,
            continuation: continuation,
            automixPlaylistId: automixPlaylistId,
            mixPlaylistId: mixPlaylistId
        )
        return queue
    }

    private func shuffled(_ queue: MusicQueue, seed: UInt64 = 6) -> MusicQueue {
        var copy = queue
        var generator = MusicShuffleGenerator(seed: seed)
        copy.shuffle(using: &generator)
        return copy
    }

    /// Plays the queue through to its last track.
    private func atEnd(_ queue: MusicQueue) -> MusicQueue {
        var copy = queue
        while copy.advance() != nil {}
        return copy
    }

    // MARK: - The mark

    @Test("an empty queue has no mix")
    func emptyQueue() {
        #expect(MusicQueue().mixPlaylistId == nil)
        #expect(MusicQueue().pendingMixPlaylistId == nil)
        #expect(MusicQueue().mixHasMore == false)
    }

    @Test("a page queue keeps the mix playlist it was started with")
    func startedWithMix() {
        #expect(makePage().mixPlaylistId == Self.mixId)
        #expect(makePage(mixPlaylistId: "RDAMVM4D7u5KF7SP8").mixPlaylistId == "RDAMVM4D7u5KF7SP8")
    }

    @Test("a page started without one has none, and the mix is optional in start")
    func startedWithoutMix() {
        #expect(makePage(mixPlaylistId: nil).mixPlaylistId == nil)
        var queue = MusicQueue()
        queue.start(page: [song("a")], playing: song("a"), browseId: "VLPL1", continuation: nil)
        #expect(queue.mixPlaylistId == nil)
        queue.start(page: [song("a")], playing: song("a"), browseId: "VLPL1", continuation: nil, automixPlaylistId: "PL1")
        #expect(queue.mixPlaylistId == nil)
    }

    @Test("an empty mix id is no mix")
    func emptyIdIsNoMix() {
        let queue = makePage(mixPlaylistId: "")
        #expect(queue.mixPlaylistId == nil)
        #expect(queue.mixHasMore == false)
    }

    @Test("starting a page again replaces the mark, and starting a lone song clears it")
    func replacedAndCleared() {
        var queue = makePage()
        queue.start(page: [song("a")], playing: song("a"), browseId: "VLRDEM2", continuation: nil, mixPlaylistId: "RDEM2")
        #expect(queue.mixPlaylistId == "RDEM2")
        queue.start(page: [song("a")], playing: song("a"), browseId: "VLPL1", continuation: nil, automixPlaylistId: "PL1", mixPlaylistId: nil)
        #expect(queue.mixPlaylistId == nil)

        var other = makePage()
        other.start(with: song("z"))
        #expect(other.mixPlaylistId == nil)
        #expect(other.mixHasMore == false)
    }

    @Test("clearing the queue clears the mark")
    func cleared() {
        var queue = makePage()
        queue.clear()
        #expect(queue.mixPlaylistId == nil)
        #expect(queue == MusicQueue())
    }

    @Test("two queues that differ only in the mark are not equal")
    func equality() {
        #expect(makePage(mixPlaylistId: Self.mixId) != makePage(mixPlaylistId: nil))
        #expect(makePage(mixPlaylistId: "RDEM1") != makePage(mixPlaylistId: "RDEM2"))
        #expect(makePage(mixPlaylistId: Self.mixId) == makePage(mixPlaylistId: Self.mixId))
    }

    @Test("the mark survives shuffling, edits, paging and moving around, which never touch what the queue is")
    func survivesEdits() {
        var queue = shuffled(makePage(tap: "a"))
        queue.addToQueue(song("z"))
        queue.playNext(song("y"))
        queue.append([song("m")], continuation: nil)
        queue.advance()
        queue.retreat()
        queue.jump(to: "z")
        queue.wrapToStart()
        queue.unshuffle()
        queue.noteAsked("l")
        #expect(queue.mixPlaylistId == Self.mixId)
    }

    @Test("adopting the radio keeps the mark: the queue carries on as the mix's radio")
    func adoptKeepsMark() {
        var queue = makePage()
        queue.adoptRadio(seedVideoId: "l")
        #expect(queue.source == .radio(seedVideoId: "l"))
        #expect(queue.mixPlaylistId == Self.mixId)
    }

    @Test("forgetting the mix drops the mark and nothing else")
    func forgetMix() {
        var queue = makePage(tap: "c", automixPlaylistId: "PL1")
        let before = queue
        queue.forgetMix()
        #expect(queue.mixPlaylistId == nil)
        #expect(queue.automixPlaylistId == "PL1")
        #expect(queue.tracks == before.tracks)
        #expect(queue.current == before.current)
        #expect(queue.source == before.source)
        #expect(queue.continuation == before.continuation)
    }

    @Test("forgetting a mix that is not there changes nothing")
    func forgetNothing() {
        var queue = makePage(mixPlaylistId: nil)
        let before = queue
        queue.forgetMix()
        #expect(queue == before)

        var empty = MusicQueue()
        empty.forgetMix()
        #expect(empty == MusicQueue())
    }

    // MARK: - What an answer would add

    @Test("an answer adds the songs the queue does not have, each once")
    func addableCountsNewSongs() {
        let queue = makePage(["a", "b", "c"], tap: "c")
        #expect(queue.addableCount(of: [song("c"), song("a"), song("m1"), song("m1"), song("m2")]) == 2)
        #expect(queue.addableCount(of: [song("m1")]) == 1)
    }

    @Test("an answer of songs the queue has, or of none, adds nothing")
    func addableCountsNothing() {
        let queue = makePage(["a", "b", "c"], tap: "c")
        #expect(queue.addableCount(of: [song("c"), song("a"), song("b")]) == 0)
        #expect(queue.addableCount(of: []) == 0)
    }

    @Test("a song the listener took out does not count: it does not come back")
    func addableSkipsRemoved() {
        var queue = makePage(["a", "b", "c"], tap: "a")
        queue.remove(videoId: "b")
        #expect(queue.addableCount(of: [song("b")]) == 0)
        #expect(queue.addableCount(of: [song("b"), song("m1")]) == 1)
    }

    @Test("counting an answer changes nothing, and matches what appending it adds")
    func addableMatchesAppend() {
        let page = [song("c"), song("a"), song("m1"), song("m1"), song("m2")]
        var queue = makePage(["a", "b", "c"], tap: "c")
        let before = queue
        let count = queue.addableCount(of: page)
        #expect(queue == before)
        let added = queue.append(page, continuation: nil)
        #expect(added == count)
    }

    // MARK: - Which ask is pending

    @Test("the first ask is pending while the queue is still the page")
    func pendingOnPage() {
        #expect(makePage().pendingMixPlaylistId == Self.mixId)
        #expect(makePage(mixPlaylistId: nil).pendingMixPlaylistId == nil)
    }

    @Test("once the mix answered and the queue is its radio, no first ask is pending")
    func nothingPendingOnRadio() {
        var queue = makePage()
        queue.adoptRadio(seedVideoId: "l")
        #expect(queue.pendingMixPlaylistId == nil)
    }

    @Test("a forgotten mix has no ask pending")
    func nothingPendingAfterForget() {
        var queue = makePage()
        queue.forgetMix()
        #expect(queue.pendingMixPlaylistId == nil)
    }

    // MARK: - Whether the mix can grow

    @Test("a mix page can grow until its first answer, with a continuation of its own or not")
    func growsOnPage() {
        #expect(makePage().mixHasMore)
        #expect(makePage(continuation: "t1").mixHasMore)
        #expect(makePage(mixPlaylistId: nil).mixHasMore == false)
    }

    @Test("an answered mix can grow while it has a continuation, and is dry without one")
    func growsOnRadio() {
        var queue = makePage()
        queue.adoptRadio(seedVideoId: "l")
        queue.append([song("m1")], continuation: "t2")
        #expect(queue.mixHasMore)
        queue.append([song("m2")], continuation: nil)
        #expect(queue.mixHasMore == false)
        #expect(queue.mixPlaylistId == Self.mixId, "the queue is still the mix's, only dry")
    }

    @Test("ending the paging dries the mix up, and forgetting it ends it for good")
    func driesUp() {
        var queue = makePage()
        queue.adoptRadio(seedVideoId: "l")
        queue.append([song("m1")], continuation: "t2")
        queue.clearContinuation()
        #expect(queue.mixHasMore == false)
        #expect(queue.mixPlaylistId == Self.mixId)

        var other = makePage()
        other.forgetMix()
        #expect(other.mixHasMore == false)
    }

    @Test("a tapped lone song after a mix has nothing to grow")
    func lonelySong() {
        var queue = makePage()
        queue.start(with: song("z"))
        #expect(queue.mixHasMore == false)
    }

    // MARK: - The song it asks after

    @Test("a mix page near its end offers the page's last song as the seed, like any page")
    func lastSongInPageOrder() {
        #expect(makePage(["a", "b", "c"], tap: "c").refillSeed == "c")
        #expect(makePage(["a", "b", "c", "d", "e"], tap: "b").refillSeed == "e")
        #expect(makePage(["a", "b", "c", "d", "e", "f"], tap: "b").refillSeed == nil)
        #expect(makePage(["a", "b", "c"], tap: "c", continuation: "t1").refillSeed == nil)
    }

    @Test("a shuffled mix page seeds with the last song of the play order, like any page")
    func shuffledSeedIsPlayOrderLast() {
        let queue = atEnd(shuffled(makePage(tap: "a")))
        #expect(queue.tracks.last?.videoId != "l", "the mix must not end where the page does, or this test shows nothing")
        #expect(queue.refillSeed == queue.tracks.last?.videoId)
    }

    @Test("a mix that was forgotten leaves the page free to stage a radio, as any page does")
    func forgottenMixStagesRadio() {
        var queue = makePage(["a", "b", "c"], tap: "c")
        queue.forgetMix()
        #expect(queue.refillSeed == "c")
        queue.stageAutoplay([song("r1"), song("r2")], continuation: nil, seed: "c")
        #expect(queue.autoplay.map(\.videoId) == ["r1", "r2"])
        #expect(queue.isPage)
        let took = queue.takeAutoplay()
        #expect(took)
        #expect(queue.source == .radio(seedVideoId: "c"))
        #expect(queue.mixPlaylistId == nil)
    }
}
