// DeciTests/Music/MusicQueueModesTests.swift
// The queue's playback modes: shuffle (and getting the natural order back), wrapping to the start for
// Loop playlist and handing a finished page over to the radio of its last track.

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

    @Test("wrapping a shuffled queue goes to the first track of the shuffled order")
    func wrapToStartShuffled() {
        var queue = shuffled(makeQueue(), seed: 4)
        let first = queue.tracks[0].videoId
        for _ in 0..<(Self.letters.count - 1) { queue.advance() }
        #expect(queue.wrapToStart()?.videoId == first)
        #expect(queue.currentIndex == 0)
    }

    @Test("wrapping a one-track queue stays on that track and an empty queue has nowhere to wrap to")
    func wrapSmallQueues() {
        var single = makeQueue(["a"])
        #expect(single.wrapToStart()?.videoId == "a")
        var empty = MusicQueue()
        #expect(empty.wrapToStart() == nil)
        #expect(empty.current == nil)
    }

    // MARK: - Handing a page over to the radio

    @Test("a page queue on its last track with no page left is at its end")
    func pageEnd() {
        #expect(makePageQueue(["a", "b", "c"], tap: "c").hasReachedPageEnd)
        #expect(makePageQueue(["a", "b", "c"], tap: "b").hasReachedPageEnd == false)
        #expect(makePageQueue(["a", "b", "c"], tap: "c", continuation: "t1").hasReachedPageEnd == false)
        #expect(makeQueue(["a", "b"], current: 1).hasReachedPageEnd == false)
        #expect(MusicQueue().hasReachedPageEnd == false)
    }

    @Test("adopting the radio seeds it with the last track, keeps the tracks and the position and has no continuation yet")
    func adoptRadio() {
        var queue = makePageQueue(["a", "b", "c"], tap: "c")
        let seed = queue.adoptRadioOfLastTrack()
        #expect(seed == "c")
        #expect(queue.source == .radio(seedVideoId: "c"))
        #expect(queue.seedVideoId == "c")
        #expect(queue.continuation == nil)
        #expect(ids(queue.tracks) == ["a", "b", "c"])
        #expect(queue.current?.videoId == "c")
        #expect(queue.hasReachedPageEnd == false)
    }

    @Test("adopting seeds the radio with the last track of a shuffled order")
    func adoptRadioShuffled() {
        var queue = shuffled(makePageQueue(tap: "a"), seed: 6)
        for _ in 0..<(Self.letters.count - 1) { queue.advance() }
        let last = queue.tracks.last!.videoId
        #expect(queue.adoptRadioOfLastTrack() == last)
    }

    @Test("a radio queue, a page with more to load and an empty queue are not adopted")
    func adoptRadioRefused() {
        var radio = makeQueue(["a", "b"], current: 1)
        #expect(radio.adoptRadioOfLastTrack() == nil)
        var more = makePageQueue(["a", "b"], tap: "b", continuation: "t1")
        #expect(more.adoptRadioOfLastTrack() == nil)
        #expect(more.source == .page(browseId: "VLPL1"))
        var middle = makePageQueue(["a", "b", "c"], tap: "b")
        #expect(middle.adoptRadioOfLastTrack() == nil)
        var empty = MusicQueue()
        #expect(empty.adoptRadioOfLastTrack() == nil)
    }

    @Test("pages appended after adopting the radio page on like a radio queue")
    func adoptedRadioPages() {
        var queue = makePageQueue(["a", "b"], tap: "b")
        queue.adoptRadioOfLastTrack()
        queue.append(MusicSamples.tracks("b", "r1", "r2", "r3"), continuation: "m1")
        #expect(ids(queue.tracks) == ["a", "b", "r1", "r2", "r3"])
        #expect(queue.needsMore)
        #expect(queue.source == .radio(seedVideoId: "b"))
    }
}
