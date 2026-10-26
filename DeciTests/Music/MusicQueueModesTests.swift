// DeciTests/Music/MusicQueueModesTests.swift
// The queue's playback modes: shuffle (and getting the natural order back), wrapping to the start for
// Loop playlist, loading a page in full and the radio that follows a page or a radio that has run out.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("MusicQueue modes")
struct MusicQueueModesTests {
    private static let letters = ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l"]

    private func ids(_ tracks: some Sequence<MusicTrack>) -> [String] { tracks.map(\.videoId) }

    /// A radio-source queue of `list` standing on `current`.
    private func makeQueue(_ list: [String] = MusicQueueModesTests.letters, current: Int = 0, continuation: String? = nil) -> MusicQueue {
        var queue = MusicQueue()
        let tracks = list.map { MusicSamples.track($0) }
        queue.start(with: tracks[0])
        queue.append(Array(tracks.dropFirst()), continuation: continuation)
        for _ in 0..<current { queue.advance() }
        return queue
    }

    private func makePageQueue(_ list: [String] = MusicQueueModesTests.letters, tap: String, continuation: String? = nil) -> MusicQueue {
        var queue = MusicQueue()
        queue.start(page: list.map { MusicSamples.track($0) }, playing: MusicSamples.track(tap), browseId: "VLPL1", continuation: continuation)
        return queue
    }

    private func shuffled(_ queue: MusicQueue, seed: UInt64 = 7, mixingEarlier: Bool = false) -> MusicQueue {
        var copy = queue
        var generator = MusicShuffleGenerator(seed: seed)
        copy.shuffle(mixingEarlier: mixingEarlier, using: &generator)
        return copy
    }

    // MARK: - Shuffle

    @Test("a queue starts unshuffled")
    func startsUnshuffled() {
        #expect(MusicQueue().isShuffled == false)
        #expect(makeQueue().isShuffled == false)
    }

    @Test("shuffle keeps the current track and what already played, and permutes only what comes after")
    func shuffleKeepsHistory() {
        let queue = shuffled(makeQueue(current: 2))
        #expect(queue.isShuffled)
        #expect(ids(queue.tracks.prefix(3)) == ["a", "b", "c"])
        #expect(queue.current?.videoId == "c")
        #expect(Set(ids(queue.upcoming)) == Set(Self.letters.dropFirst(3)))
        #expect(queue.upcomingCount == 9)
        #expect(ids(queue.upcoming) != Array(Self.letters.dropFirst(3)))
    }

    @Test("the same seed shuffles the same way and another seed shuffles differently")
    func shuffleIsDeterministic() {
        let one = shuffled(makeQueue(), seed: 42)
        let again = shuffled(makeQueue(), seed: 42)
        let other = shuffled(makeQueue(), seed: 43)
        #expect(ids(one.tracks) == ids(again.tracks))
        #expect(ids(one.tracks) != ids(other.tracks))
    }

    @Test("shuffling an already shuffled queue changes nothing")
    func shuffleTwice() {
        let once = shuffled(makeQueue(), seed: 1)
        let twice = shuffled(once, seed: 2)
        #expect(once == twice)
    }

    @Test("shuffle on an empty or one-track queue only sets the flag")
    func shuffleSmallQueues() {
        var empty = MusicQueue()
        var generator = MusicShuffleGenerator(seed: 1)
        empty.shuffle(using: &generator)
        #expect(empty.isShuffled)
        #expect(empty.tracks.isEmpty)

        let single = shuffled(makeQueue(["a"]))
        #expect(single.isShuffled)
        #expect(ids(single.tracks) == ["a"])
    }

    @Test("turning shuffle off puts every track back in its natural order and stays on the current one")
    func unshuffleRestoresOrder() {
        var queue = shuffled(makeQueue(current: 2))
        queue.unshuffle()
        #expect(queue.isShuffled == false)
        #expect(ids(queue.tracks) == Self.letters)
        #expect(queue.current?.videoId == "c")
        #expect(ids(queue.upcoming) == Array(Self.letters.dropFirst(3)))
    }

    @Test("turning shuffle off after playing on in the shuffle continues from the current track's natural place")
    func unshuffleAfterMoving() {
        var queue = shuffled(makeQueue())
        queue.advance()
        queue.advance()
        let standingOn = queue.current!.videoId
        queue.unshuffle()
        #expect(ids(queue.tracks) == Self.letters)
        #expect(queue.current?.videoId == standingOn)
        let natural = Self.letters.firstIndex(of: standingOn)!
        #expect(ids(queue.upcoming) == Array(Self.letters.dropFirst(natural + 1)))
    }

    @Test("turning shuffle off on an unshuffled queue changes nothing")
    func unshuffleWhenOff() {
        var queue = makeQueue(current: 1)
        let before = queue
        queue.unshuffle()
        #expect(queue == before)
    }

    @Test("shuffled again after being turned off, the order is mixed from the current track once more")
    func shuffleOffAndOn() {
        var queue = shuffled(makeQueue(), seed: 3)
        queue.unshuffle()
        var generator = MusicShuffleGenerator(seed: 9)
        queue.shuffle(using: &generator)
        #expect(queue.isShuffled)
        #expect(queue.current?.videoId == "a")
        queue.unshuffle()
        #expect(ids(queue.tracks) == Self.letters)
    }

    @Test("a page appended while shuffled is mixed into the remaining part and the next track stays")
    func appendWhileShuffled() {
        var queue = shuffled(makeQueue(["a", "b", "c", "d", "e"]), seed: 5)
        let before = ids(queue.upcoming)
        var generator = MusicShuffleGenerator(seed: 11)
        let added = queue.append(MusicSamples.tracks("v", "w", "x", "y", "z"), continuation: "c1", using: &generator)

        #expect(added == 5)
        #expect(queue.continuation == "c1")
        let after = ids(queue.upcoming)
        #expect(after.count == 9)
        #expect(Set(after) == Set(before + ["v", "w", "x", "y", "z"]))
        // The next track is never displaced, and the tracks that were already queued keep their relative order.
        #expect(after.first == before.first)
        #expect(after.filter { before.contains($0) } == before)
        // Mixed, not tacked on: with five new tracks over four slots at least one lands before an old one.
        #expect(Array(after.suffix(5)) != ["v", "w", "x", "y", "z"])
    }

    @Test("turning shuffle off after a page was appended puts the later page after the earlier ones")
    func unshuffleAfterAppend() {
        var queue = shuffled(makeQueue(["a", "b", "c"]), seed: 5)
        var generator = MusicShuffleGenerator(seed: 11)
        queue.append(MusicSamples.tracks("x", "y"), continuation: nil, using: &generator)
        queue.unshuffle()
        #expect(ids(queue.tracks) == ["a", "b", "c", "x", "y"])
    }

    @Test("an appended page still drops tracks that are already queued while shuffled")
    func appendWhileShuffledDedupes() {
        var queue = shuffled(makeQueue(["a", "b", "c"]))
        var generator = MusicShuffleGenerator(seed: 1)
        let added = queue.append(MusicSamples.tracks("c", "d", "d"), continuation: nil, using: &generator)
        #expect(added == 1)
        #expect(queue.tracks.count == 4)
    }

    @Test("a page appended to an unshuffled queue goes on the end in order")
    func appendUnshuffledKeepsOrder() {
        var queue = makeQueue(["a", "b"])
        var generator = MusicShuffleGenerator(seed: 1)
        queue.append(MusicSamples.tracks("c", "d"), continuation: nil, using: &generator)
        #expect(ids(queue.tracks) == ["a", "b", "c", "d"])
    }

    @Test("shuffle that mixes in the earlier tracks starts on the current one and pools everything else")
    func shuffleMixingEarlier() {
        let queue = shuffled(makePageQueue(["a", "b", "c", "d", "e", "f"], tap: "d"), mixingEarlier: true)
        #expect(queue.current?.videoId == "d")
        #expect(queue.hasPrevious == false)
        #expect(queue.tracks.first?.videoId == "d")
        #expect(Set(ids(queue.upcoming)) == ["a", "b", "c", "e", "f"])
    }

    @Test("turning shuffle off after a mixing shuffle brings the earlier tracks back before the current one")
    func unshuffleAfterMixingEarlier() {
        var queue = shuffled(makePageQueue(["a", "b", "c", "d", "e", "f"], tap: "d"), mixingEarlier: true)
        queue.unshuffle()
        #expect(ids(queue.tracks) == ["a", "b", "c", "d", "e", "f"])
        #expect(queue.current?.videoId == "d")
        #expect(queue.hasPrevious)
    }

    @Test("starting a new queue forgets the shuffle")
    func startForgetsShuffle() {
        var queue = shuffled(makeQueue())
        queue.start(with: MusicSamples.track("z"))
        #expect(queue.isShuffled == false)
        queue = shuffled(makeQueue())
        queue.start(page: MusicSamples.tracks("p", "q"), playing: MusicSamples.track("p"), browseId: "VLPL2", continuation: nil)
        #expect(queue.isShuffled == false)
        #expect(ids(queue.tracks) == ["p", "q"])
    }

    @Test("clear forgets the shuffle too")
    func clearForgetsShuffle() {
        var queue = shuffled(makeQueue())
        queue.clear()
        #expect(queue == MusicQueue())
        #expect(queue.isShuffled == false)
    }

    @Test("jumping around a shuffled queue keeps the shuffle and the order")
    func jumpWhileShuffled() {
        var queue = shuffled(makeQueue())
        let order = ids(queue.tracks)
        let target = order[5]
        #expect(queue.jump(to: target)?.videoId == target)
        #expect(ids(queue.tracks) == order)
        #expect(queue.isShuffled)
    }

    // MARK: - Wrapping for Loop playlist

    @Test("wrapping goes back to the first track of the play order")
    func wrapToStart() {
        var queue = makeQueue(["a", "b", "c"], current: 2)
        #expect(queue.wrapToStart()?.videoId == "a")
        #expect(queue.current?.videoId == "a")
        #expect(queue.hasPrevious == false)
        #expect(ids(queue.tracks) == ["a", "b", "c"])
    }

    @Test("wrapping a shuffled queue keeps its mix: the next lap starts from the shuffled start")
    func wrapKeepsTheShuffle() {
        var queue = shuffled(makePageQueue(tap: "e"), seed: 4, mixingEarlier: true)
        let lap = ids(queue.tracks)
        #expect(lap.first == "e")
        for _ in 0..<(Self.letters.count - 1) { queue.advance() }
        #expect(queue.wrapToStart()?.videoId == "e")
        #expect(queue.currentIndex == 0)
        #expect(queue.isShuffled)
        #expect(ids(queue.tracks) == lap)
        // Every lap is the same order.
        for _ in 0..<(Self.letters.count - 1) { queue.advance() }
        queue.wrapToStart()
        #expect(ids(queue.tracks) == lap)
    }

    @Test("after a wrap, unshuffling still gives the natural order and stays on the current track")
    func unshuffleAfterWrap() {
        var queue = shuffled(makeQueue(), seed: 9)
        for _ in 0..<(Self.letters.count - 1) { queue.advance() }
        queue.wrapToStart()
        let current = queue.current?.videoId
        queue.unshuffle()
        #expect(ids(queue.tracks) == Self.letters)
        #expect(queue.current?.videoId == current)
        #expect(queue.isShuffled == false)
    }

    @Test("wrapping a one-track queue stays on that track and an empty queue has nowhere to wrap to")
    func wrapSmallQueues() {
        var single = makeQueue(["a"])
        #expect(single.wrapToStart()?.videoId == "a")
        var empty = MusicQueue()
        #expect(empty.wrapToStart() == nil)
        #expect(empty.current == nil)
    }

    // MARK: - The radio that follows

    @Test("a page with no page left to load offers its last track as the radio seed, however many songs are left")
    func pageRefillSeed() {
        #expect(makePageQueue(["a", "b", "c"], tap: "c").refillSeed == "c")
        #expect(makePageQueue(["a", "b", "c", "d", "e"], tap: "b").refillSeed == "e")
        #expect(makePageQueue(["a", "b", "c", "d", "e", "f"], tap: "b").refillSeed == "f")
        #expect(makePageQueue(["a", "b", "c"], tap: "c", continuation: "t1").refillSeed == nil)
        #expect(MusicQueue().refillSeed == nil)
    }

    @Test("asking for the seed changes nothing: the queue stays a page")
    func refillSeedChangesNothing() {
        let queue = makePageQueue(["a", "b", "c"], tap: "c")
        #expect(queue.refillSeed == "c")
        #expect(queue.source == .page(browseId: "VLPL1"))
        #expect(queue.seedVideoId == nil)
    }

    @Test("the seed of a shuffled page is the last track of the shuffled order, the one that plays before the radio")
    func refillSeedShuffled() {
        var queue = shuffled(makePageQueue(tap: "a"), seed: 6)
        for _ in 0..<(Self.letters.count - 1) { queue.advance() }
        #expect(queue.tracks.last?.videoId != Self.letters.last, "the mix must not end where the page does, or this test shows nothing")
        #expect(queue.refillSeed == queue.tracks.last?.videoId)
        queue.unshuffle()
        #expect(queue.refillSeed == Self.letters.last)
    }

    @Test("a radio offers its last track once it has nothing more to load, never a seed it asked already")
    func radioRefillSeed() {
        var queue = makeQueue(["a", "b", "c"], current: 1)
        queue.adoptRadio(seedVideoId: "a")
        #expect(queue.refillSeed == "c")
        queue.noteAsked("c")
        #expect(queue.refillSeed == "b")
        #expect(makeQueue(["a", "b", "c"], current: 1, continuation: "m1").refillSeed == nil)
    }

    @Test("a fresh radio waits for its first page; once it answered it no longer does")
    func awaitsFirstRadioPage() {
        var queue = MusicQueue()
        queue.start(with: MusicSamples.track("a"))
        #expect(queue.awaitsFirstRadioPage)
        #expect(queue.refillSeed == "a")
        queue.adoptRadio(seedVideoId: "a")
        #expect(queue.awaitsFirstRadioPage == false)
        #expect(queue.refillSeed == nil)
        #expect(makePageQueue(tap: "a").awaitsFirstRadioPage == false)
    }

    @Test("adopting the radio seeds it, keeps the tracks and the position and has no continuation yet")
    func adoptRadio() {
        var queue = makePageQueue(["a", "b", "c"], tap: "c")
        queue.adoptRadio(seedVideoId: "c")
        #expect(queue.source == .radio(seedVideoId: "c"))
        #expect(queue.seedVideoId == "c")
        #expect(queue.continuation == nil)
        #expect(ids(queue.tracks) == ["a", "b", "c"])
        #expect(queue.current?.videoId == "c")
        #expect(queue.refillSeed == "b")
    }

    @Test("pages appended after adopting the radio page on like a radio queue")
    func adoptedRadioPages() {
        var queue = makePageQueue(["a", "b"], tap: "b")
        queue.adoptRadio(seedVideoId: "b")
        queue.append(MusicSamples.tracks("b", "r1", "r2", "r3"), continuation: "m1")
        #expect(ids(queue.tracks) == ["a", "b", "r1", "r2", "r3"])
        #expect(queue.needsMore)
        #expect(queue.source == .radio(seedVideoId: "b"))
    }

    @Test("a staged radio waits beside the page without the page's tracks, and the page offers no second seed")
    func stageAutoplay() {
        var queue = makePageQueue(["a", "b", "c"], tap: "b")
        #expect(queue.stageAutoplay(MusicSamples.tracks("c", "r1", "a", "r2"), continuation: "m1", seed: "c") == 2)
        #expect(ids(queue.autoplay) == ["r1", "r2"])
        #expect(ids(queue.tracks) == ["a", "b", "c"])
        #expect(queue.source == .page(browseId: "VLPL1"))
        #expect(queue.refillSeed == nil)
        #expect(queue.upcomingCount == 1)
    }

    @Test("taking the staged radio puts it after the page and the queue carries on as that radio")
    func takeAutoplay() {
        var queue = makePageQueue(["a", "b", "c"], tap: "c")
        queue.stageAutoplay(MusicSamples.tracks("r1", "r2"), continuation: "m1", seed: "c")
        let merged = queue.takeAutoplay()
        #expect(merged)
        #expect(ids(queue.tracks) == ["a", "b", "c", "r1", "r2"])
        #expect(queue.autoplay.isEmpty)
        #expect(queue.source == .radio(seedVideoId: "c"))
        #expect(queue.seedVideoId == "c")
        #expect(queue.continuation == "m1")
        #expect(queue.advance()?.videoId == "r1")
        let again = queue.takeAutoplay()
        #expect(again == false)
    }

    @Test("a shuffled page takes the staged radio on its end, never mixed in, and unshuffling keeps it last")
    func takeAutoplayShuffled() {
        var queue = shuffled(makePageQueue(["a", "b", "c", "d"], tap: "b"), seed: 3, mixingEarlier: true)
        let mix = ids(queue.tracks)
        queue.stageAutoplay(MusicSamples.tracks("r1", "r2"), continuation: nil, seed: mix.last!)
        queue.takeAutoplay()
        #expect(ids(queue.tracks) == mix + ["r1", "r2"])
        queue.unshuffle()
        #expect(ids(queue.tracks) == ["a", "b", "c", "d", "r1", "r2"])
    }

    @Test("jumping to a staged radio track takes the radio in first")
    func jumpIntoAutoplay() {
        var queue = makePageQueue(["a", "b", "c"], tap: "a")
        queue.stageAutoplay(MusicSamples.tracks("r1", "r2"), continuation: nil, seed: "c")
        #expect(queue.jump(to: "r2")?.videoId == "r2")
        #expect(ids(queue.tracks) == ["a", "b", "c", "r1", "r2"])
        #expect(queue.source == .radio(seedVideoId: "c"))
        #expect(queue.jump(to: "zz") == nil)
    }

    @Test("staging on a radio queue keeps nothing; a new queue forgets the staged radio and the asked seeds")
    func stagingResets() {
        var radio = makeQueue(["a", "b"])
        #expect(radio.stageAutoplay(MusicSamples.tracks("r1"), continuation: nil, seed: "b") == 0)
        #expect(radio.autoplay.isEmpty)

        var queue = makePageQueue(["a", "b", "c"], tap: "c")
        queue.stageAutoplay(MusicSamples.tracks("r1"), continuation: nil, seed: "c")
        queue.start(page: MusicSamples.tracks("a", "b", "c"), playing: MusicSamples.track("c"), browseId: "VLPL1", continuation: nil)
        #expect(queue.autoplay.isEmpty)
        #expect(queue.refillSeed == "c")
    }

    // MARK: - Loading a page in full

    @Test("a page queue asks for its next page whatever is left, shuffled or not")
    func pageNeedsMore() {
        let queue = makePageQueue(tap: "a", continuation: "t1")
        #expect(queue.needsMore)
        var mixed = shuffled(queue)
        #expect(mixed.needsMore)
        mixed.unshuffle()
        #expect(mixed.needsMore)
    }

    @Test("a page queue without a continuation has nothing to ask for")
    func pageWithoutContinuation() {
        #expect(makePageQueue(tap: "a").needsMore == false)
        #expect(shuffled(makePageQueue(tap: "a")).needsMore == false)
    }

    @Test("a page queue stops asking once it holds the cap")
    func pageCap() {
        func queue(count: Int) -> MusicQueue {
            let list = (0..<count).map { "p\($0)" }
            return makePageQueue(list, tap: "p0", continuation: "t1")
        }
        #expect(MusicQueue.fullLoadCap == 2000)
        #expect(queue(count: MusicQueue.fullLoadCap - 1).needsMore)
        #expect(queue(count: MusicQueue.fullLoadCap).needsMore == false)
        #expect(queue(count: MusicQueue.fullLoadCap + 1).needsMore == false)
    }

    @Test("past the cap a page queue falls back to asking when three tracks are left")
    func pagePastTheCap() {
        let list = (0..<MusicQueue.fullLoadCap).map { "p\($0)" }
        var queue = shuffled(makePageQueue(list, tap: "p0", continuation: "t1"))
        #expect(queue.needsMore == false)
        for _ in 0..<(MusicQueue.fullLoadCap - 4) { queue.advance() }
        #expect(queue.upcomingCount == 3)
        #expect(queue.needsMore)
    }

    @Test("a radio queue, shuffled or not, still waits for three tracks to be left")
    func radioNeedsMore() {
        #expect(makeQueue(continuation: "m1").needsMore == false)
        #expect(shuffled(makeQueue(continuation: "m1")).needsMore == false)
        #expect(makeQueue(current: 8, continuation: "m1").needsMore)
    }
}
