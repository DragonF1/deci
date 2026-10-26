// DeciTests/Music/MusicQueueAutomixTests.swift
// What a page queue remembers for the playlist automix: the playlist id its page asks it of, and the song it asks it
// after, which is the last of the page's own songs in the play order: the song that plays right before the automix does.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("MusicQueue automix")
struct MusicQueueAutomixTests {
    private static let letters = ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l"]

    private func song(_ id: String) -> Deci.MusicTrack { MusicSamples.track(id, title: "Song \(id)") }

    private func makePage(
        _ list: [String] = MusicQueueAutomixTests.letters,
        tap: String? = nil,
        continuation: String? = nil,
        automixPlaylistId: String? = "PL1"
    ) -> MusicQueue {
        var queue = MusicQueue()
        queue.start(
            page: list.map { song($0) },
            playing: song(tap ?? list[0]),
            browseId: "VLPL1",
            continuation: continuation,
            automixPlaylistId: automixPlaylistId
        )
        return queue
    }

    private func shuffled(_ queue: MusicQueue, seed: UInt64 = 6, mixingEarlier: Bool = false) -> MusicQueue {
        var copy = queue
        var generator = MusicShuffleGenerator(seed: seed)
        copy.shuffle(mixingEarlier: mixingEarlier, using: &generator)
        return copy
    }

    /// Plays the queue through to its last track.
    private func atEnd(_ queue: MusicQueue) -> MusicQueue {
        var copy = queue
        while copy.advance() != nil {}
        return copy
    }

    // MARK: - The playlist id

    @Test("an empty queue has no automix playlist")
    func emptyQueue() {
        #expect(MusicQueue().automixPlaylistId == nil)
    }

    @Test("a page queue keeps the playlist id it was started with")
    func startedWithPage() {
        #expect(makePage(automixPlaylistId: "PL1").automixPlaylistId == "PL1")
        #expect(makePage(automixPlaylistId: "OLAK5uy_x").automixPlaylistId == "OLAK5uy_x")
    }

    @Test("a page started without one has none, and the id is optional in start")
    func startedWithoutId() {
        #expect(makePage(automixPlaylistId: nil).automixPlaylistId == nil)
        var queue = MusicQueue()
        queue.start(page: [song("a")], playing: song("a"), browseId: "VLPL1", continuation: nil)
        #expect(queue.automixPlaylistId == nil)
    }

    @Test("starting a page again replaces the id, and starting a lone song clears it")
    func replacedAndCleared() {
        var queue = makePage(automixPlaylistId: "PL1")
        queue.start(page: [song("a")], playing: song("a"), browseId: "VLPL2", continuation: nil, automixPlaylistId: "PL2")
        #expect(queue.automixPlaylistId == "PL2")
        queue.start(page: [song("a")], playing: song("a"), browseId: "UC1", continuation: nil, automixPlaylistId: nil)
        #expect(queue.automixPlaylistId == nil)

        var other = makePage(automixPlaylistId: "PL1")
        other.start(with: song("z"))
        #expect(other.automixPlaylistId == nil)
    }

    @Test("adopting a radio clears the id: a radio queue has no playlist to ask the automix of")
    func adoptClears() {
        var queue = makePage(["a", "b", "c"], tap: "c")
        queue.adoptRadio(seedVideoId: "c")
        #expect(queue.automixPlaylistId == nil)
        #expect(queue.source == .radio(seedVideoId: "c"))
    }

    @Test("the radio that takes over from a page clears the id too")
    func takeAutoplayClears() {
        var queue = makePage(["a", "b", "c"], tap: "c")
        queue.stageAutoplay([song("r1"), song("r2")], continuation: nil, seed: "c")
        #expect(queue.automixPlaylistId == "PL1", "staging the radio leaves the page a page, with its playlist")
        let took = queue.takeAutoplay()
        #expect(took)
        #expect(queue.automixPlaylistId == nil)
    }

    @Test("clearing the queue clears the id")
    func cleared() {
        var queue = makePage()
        queue.clear()
        #expect(queue.automixPlaylistId == nil)
        #expect(queue == MusicQueue())
    }

    @Test("two queues that differ only in the id are not equal")
    func equality() {
        #expect(makePage(automixPlaylistId: "PL1") != makePage(automixPlaylistId: "PL2"))
        #expect(makePage(automixPlaylistId: "PL1") == makePage(automixPlaylistId: "PL1"))
    }

    @Test("the id survives shuffling, edits and paging, which never touch what the page is")
    func survivesEdits() {
        var queue = shuffled(makePage(tap: "a"))
        queue.addToQueue(song("z"))
        queue.playNext(song("y"))
        queue.append([song("m")], continuation: nil)
        queue.unshuffle()
        #expect(queue.automixPlaylistId == "PL1")
    }

    // MARK: - The song it asks after

    @Test("a fully loaded page seeds the automix with its last song, whatever the number of songs still to play")
    func lastSongInPageOrder() {
        #expect(makePage(["a", "b", "c"], tap: "c").refillSeed == "c")
        #expect(makePage(["a", "b", "c", "d", "e"], tap: "b").refillSeed == "e")
        #expect(makePage(["a", "b", "c", "d", "e", "f"], tap: "b").refillSeed == "f")
        #expect(makePage(tap: "a").refillSeed == "l")
        #expect(makePage(tap: "d").refillSeed == "l")
        #expect(makePage(["a"], tap: "a").refillSeed == "a")
    }

    @Test("a shuffled page seeds with the last song of the play order, the one that plays right before the automix")
    func shuffledSeedIsPlayOrderLast() {
        let queue = atEnd(shuffled(makePage(tap: "a")))
        #expect(queue.tracks.last?.videoId != "l", "the mix must not end where the page does, or this test shows nothing")
        #expect(queue.refillSeed == queue.tracks.last?.videoId)
    }

    @Test("a shuffled page seeds with the last song of the mix from the start, with the whole mix still to play")
    func shuffledSeedAtOnce() {
        let queue = shuffled(makePage(tap: "a"))
        #expect(queue.upcomingCount == 11)
        #expect(queue.tracks.last?.videoId != "l", "the mix must not end where the page does, or this test shows nothing")
        #expect(queue.refillSeed == queue.tracks.last?.videoId)
        let early = shuffled(makePage(tap: "d"), mixingEarlier: true)
        #expect(early.refillSeed == early.tracks.last?.videoId)
    }

    @Test("the seed follows the play order of every shuffle, and the natural last song comes back with the natural order")
    func shuffledSeedFollowsTheMix() {
        var differs = 0
        for seed in [1, 2, 3, 4, 5, 6, 7, 8, 9, 10] as [UInt64] {
            let queue = shuffled(makePage(tap: "a"), seed: seed)
            #expect(queue.refillSeed == queue.tracks.last?.videoId, "seed \(seed)")
            if queue.refillSeed != "l" { differs += 1 }
        }
        #expect(differs > 0, "no shuffle moved the last song, so this test shows nothing")
        var plain = shuffled(makePage(tap: "a"))
        plain.unshuffle()
        #expect(plain.refillSeed == "l")
        #expect(atEnd(plain).refillSeed == "l")
    }

    @Test("a page started from a middle row and mixed, with the earlier songs mixed in, seeds with the last song of the mix")
    func shuffledFromMiddle() {
        let queue = atEnd(shuffled(makePage(tap: "d"), mixingEarlier: true))
        #expect(queue.refillSeed == queue.tracks.last?.videoId)
    }

    @Test("a song added to the end of the page is not the page's last song")
    func skipsAddedToEnd() {
        var queue = makePage(["a", "b", "c"], tap: "c")
        queue.addToQueue(song("z"))
        #expect(queue.tracks.map(\.videoId) == ["a", "b", "c", "z"])
        #expect(queue.refillSeed == "c")
    }

    @Test("a song queued with Play next on the last row is not the page's last song either")
    func skipsPlayNext() {
        var queue = makePage(["a", "b", "c"], tap: "c")
        queue.playNext(song("y"))
        #expect(queue.tracks.map(\.videoId) == ["a", "b", "c", "y"])
        #expect(queue.refillSeed == "c")
    }

    @Test("queued songs are skipped while shuffled too: the seed is the last of the page's own songs in the mix")
    func skipsQueuedWhileShuffled() {
        var queue = shuffled(makePage(tap: "a"))
        queue.addToQueue(song("z"))
        queue.playNext(song("y"))
        queue = atEnd(queue)
        #expect(queue.tracks.last?.videoId == "z")
        let ownLast = queue.tracks.last { !["y", "z"].contains($0.videoId) }?.videoId
        #expect(ownLast != "l", "the mix must not end where the page does, or this test shows nothing")
        #expect(queue.refillSeed == ownLast)
    }

    @Test("a seed that was asked already is passed over for the page's last song before it")
    func skipsAsked() {
        var queue = makePage(["a", "b", "c"], tap: "c")
        queue.noteAsked("c")
        #expect(queue.refillSeed == "b")
        queue.noteAsked("b")
        #expect(queue.refillSeed == "a")
    }

    @Test("asked seeds are passed over in the play order while shuffled")
    func skipsAskedWhileShuffled() {
        var queue = atEnd(shuffled(makePage(tap: "a")))
        let order = queue.tracks.map(\.videoId)
        queue.noteAsked(order[order.count - 1])
        #expect(queue.refillSeed == order[order.count - 2])
        queue.noteAsked(order[order.count - 2])
        #expect(queue.refillSeed == order[order.count - 3])
    }

    @Test("a song taken out of the page is not its last song, shuffled or not")
    func skipsRemoved() {
        var queue = shuffled(makePage(tap: "a"))
        let order = queue.tracks.map(\.videoId)
        let removed = queue.remove(videoId: order[order.count - 1])
        #expect(removed)
        queue = atEnd(queue)
        #expect(queue.refillSeed == order[order.count - 2])

        var plain = makePage(["a", "b", "c"], tap: "a")
        plain.remove(videoId: "c")
        #expect(plain.refillSeed == "b")
    }

    @Test("when every song of the page was asked, the last unasked song in play order is the seed, as before")
    func fallsBackToPlayOrder() {
        var queue = makePage(["a", "b"], tap: "b")
        queue.addToQueue(song("z"))
        queue.noteAsked("a")
        queue.noteAsked("b")
        #expect(queue.refillSeed == "z")
        queue.noteAsked("z")
        #expect(queue.refillSeed == nil)
    }

    @Test("a page with its radio staged offers no seed, and a radio queue still seeds with its last track")
    func stagedAndRadio() {
        var staged = makePage(["a", "b", "c"], tap: "c")
        staged.stageAutoplay([song("r1")], continuation: nil, seed: "c")
        #expect(staged.refillSeed == nil)

        var radio = makePage(["a", "b", "c"], tap: "b")
        radio.adoptRadio(seedVideoId: "c")
        #expect(radio.refillSeed == "b")
    }

    // MARK: - When it asks

    @Test("a page that still has pages of its own to load offers no seed, however few songs are left, until it is fully loaded")
    func pagingPageWaits() {
        var queue = atEnd(makePage(["a", "b", "c"], continuation: "t1"))
        #expect(queue.upcomingCount == 0)
        #expect(queue.refillSeed == nil)
        #expect(makePage(tap: "a", continuation: "t1").refillSeed == nil)

        queue.append([song("d"), song("e"), song("f"), song("g"), song("h")], continuation: nil)
        #expect(queue.upcomingCount == 5)
        #expect(queue.refillSeed == "h", "the last page landed: the seed is there with five songs still to play")
    }

    @Test("a page that stopped paging is fully loaded: ending its continuation makes the seed available")
    func clearedContinuation() {
        var queue = makePage(tap: "a", continuation: "t1")
        queue.clearContinuation()
        #expect(queue.refillSeed == "l")
    }

    @Test("a mix page keeps the refill threshold: no seed until three songs or fewer are left")
    func mixPageWaits() {
        var queue = MusicQueue()
        queue.start(
            page: MusicQueueAutomixTests.letters.map { song($0) },
            playing: song("a"),
            browseId: "VLRDTMAK5uy_mix",
            continuation: nil,
            mixPlaylistId: "RDTMAK5uy_mix"
        )
        #expect(queue.upcomingCount == 11)
        #expect(queue.refillSeed == nil)
        queue.jump(to: "h")
        #expect(queue.upcomingCount == 4)
        #expect(queue.refillSeed == nil)
        queue.jump(to: "i")
        #expect(queue.upcomingCount == 3)
        #expect(queue.refillSeed == "l")

        queue.jump(to: "a")
        queue.forgetMix()
        #expect(queue.refillSeed == "l", "a mix that was forgotten leaves a plain playlist, which seeds at once")
    }

    @Test("a radio queue keeps the refill threshold too: it seeds with its last track only when it runs out")
    func radioWaits() {
        var queue = MusicQueue()
        queue.start(with: song("a"))
        queue.append(MusicQueueAutomixTests.letters.dropFirst().map { song($0) }, continuation: nil)
        #expect(queue.upcomingCount == 11)
        #expect(queue.refillSeed == nil)
        queue.jump(to: "i")
        #expect(queue.refillSeed == "l")

        var lone = MusicQueue()
        lone.start(with: song("a"))
        #expect(lone.refillSeed == "a")

        var handedOver = makePage(tap: "a")
        handedOver.stageAutoplay(MusicQueueAutomixTests.letters.map { song("r\($0)") }, continuation: nil, seed: "l")
        handedOver.jump(to: "ra")
        #expect(handedOver.source == .radio(seedVideoId: "l"))
        #expect(handedOver.upcomingCount == 11)
        #expect(handedOver.refillSeed == nil, "a radio that took over from a page waits for the threshold again")
        handedOver.jump(to: "rj")
        #expect(handedOver.refillSeed == "rl")
    }

    @Test("a page with its radio staged offers no seed from the start either")
    func stagedFromTheStart() {
        var queue = makePage(tap: "a")
        queue.stageAutoplay([song("r1")], continuation: nil, seed: "l")
        #expect(queue.upcomingCount == 11)
        #expect(queue.refillSeed == nil)
        queue = atEnd(queue)
        #expect(queue.refillSeed == nil)
    }

    @Test("a page whose radio was turned down or came back empty walks back at most three seeds at once, then waits for the threshold")
    func eagerAsksAreBounded() {
        #expect(MusicQueue.eagerAskLimit == 3)
        var queue = makePage(tap: "a")
        #expect(queue.refillSeed == "l")
        queue.noteAsked("l")
        #expect(queue.refillSeed == "k")
        // An answer with nothing new counts as an ask, like a refusal.
        queue.stageAutoplay([song("a")], continuation: nil, seed: "k")
        #expect(queue.autoplay.isEmpty)
        #expect(queue.refillSeed == "j")
        queue.noteAsked("j")
        #expect(queue.upcomingCount == 11)
        #expect(queue.refillSeed == nil, "three seeds asked: the songs before them are not walked through")

        queue.jump(to: "g")
        #expect(queue.upcomingCount == 5)
        #expect(queue.refillSeed == nil)
        queue.jump(to: "i")
        #expect(queue.upcomingCount == 3)
        #expect(queue.refillSeed == "i", "near the end it carries on from the song before the asked ones, as before")
        queue.noteAsked("i")
        #expect(queue.refillSeed == "h")
    }

    // MARK: - A staged radio whose song is no longer the last

    /// `queue` with the radio of `seed` staged: two songs and a continuation, as an answer would bring.
    private func staged(_ queue: MusicQueue, seed: String) -> MusicQueue {
        var copy = queue
        copy.stageAutoplay([song("r1"), song("r2")], continuation: "m1", seed: seed)
        return copy
    }

    @Test("a radio staged for the page's last song is not stale, and dropping it does nothing")
    func freshStagedRadio() {
        var queue = staged(makePage(tap: "a"), seed: "l")
        #expect(queue.hasStaleAutoplay == false)
        #expect(queue.isStaleRadioSeed("l") == false)
        let dropped = queue.dropStaleAutoplay()
        #expect(dropped == false)
        #expect(queue.autoplay.map(\.videoId) == ["r1", "r2"])
        #expect(queue.refillSeed == nil)
    }

    @Test("a shuffle that moves the last song makes the staged radio stale; dropping it offers the new last song at once")
    func shuffleMakesTheStagedRadioStale() {
        var queue = shuffled(staged(makePage(tap: "a"), seed: "l"))
        let last = queue.tracks.last!.videoId
        #expect(last != "l", "the mix must not end where the page does, or this test shows nothing")
        #expect(queue.hasStaleAutoplay)
        #expect(queue.refillSeed == nil, "while it is staged the page offers no seed")

        let dropped = queue.dropStaleAutoplay()
        #expect(dropped)
        #expect(queue.autoplay.isEmpty)
        #expect(queue.hasStaleAutoplay == false)
        #expect(queue.refillSeed == last)
        #expect(queue.isStaleRadioSeed("l"))
        #expect(queue.isStaleRadioSeed(last) == false)
    }

    @Test("undoing the shuffle makes the radio staged for the mix's last song stale, and the natural last song is offered again")
    func unshuffleMakesTheStagedRadioStale() {
        var queue = shuffled(makePage(tap: "a"))
        let last = queue.tracks.last!.videoId
        queue.stageAutoplay([song("r1")], continuation: nil, seed: last)
        #expect(queue.hasStaleAutoplay == false)

        queue.unshuffle()
        #expect(queue.hasStaleAutoplay)
        queue.dropStaleAutoplay()
        #expect(queue.refillSeed == "l")
    }

    @Test("a staged radio that stays for the last song through the shuffle is kept")
    func sameLastSongThroughTheShuffle() {
        var queue = staged(makePage(["a", "b"], tap: "a"), seed: "b")
        queue = shuffled(queue, mixingEarlier: true)
        #expect(queue.tracks.map(\.videoId) == ["a", "b"])
        #expect(queue.hasStaleAutoplay == false)
        queue.unshuffle()
        #expect(queue.hasStaleAutoplay == false)
        #expect(queue.autoplay.map(\.videoId) == ["r1", "r2"])
    }

    @Test("the dropped seed leaves the asked ones, so the bound on eager asks does not count it")
    func droppedSeedLeavesTheAskedOnes() {
        var queue = makePage(tap: "a")
        queue.stageAutoplay([], continuation: nil, seed: "l")
        queue.stageAutoplay([], continuation: nil, seed: "k")
        queue.stageAutoplay([song("r1")], continuation: nil, seed: "j")
        queue = shuffled(queue)
        let next = queue.tracks.last { $0.videoId != "l" && $0.videoId != "k" }!.videoId
        #expect(next != "j", "the mix must not end where the page does, or this test shows nothing")
        #expect(queue.hasStaleAutoplay)

        queue.dropStaleAutoplay()
        #expect(queue.refillSeed == next, "two asked seeds are left, one under the bound of three")
        queue.noteAsked(next)
        #expect(queue.refillSeed == nil, "three asked seeds again: the bound holds")
    }

    @Test("a radio staged one song back because the last song came back empty is for the last song to ask, so it is not stale")
    func walkedBackSeedIsNotStale() {
        var queue = makePage(tap: "a")
        queue.stageAutoplay([], continuation: nil, seed: "l")
        queue.stageAutoplay([song("r1")], continuation: nil, seed: "k")
        #expect(queue.hasStaleAutoplay == false)
        #expect(queue.isStaleRadioSeed("k") == false)
        #expect(queue.isStaleRadioSeed("i"))
    }

    @Test("an ask in flight for a song other than the one to ask is stale, an ask for the song to ask is not")
    func staleAskInFlight() {
        let queue = makePage(tap: "a")
        #expect(queue.isStaleRadioSeed("l") == false)
        #expect(queue.isStaleRadioSeed("k"))
        var asked = queue
        asked.noteAsked("l")
        #expect(asked.isStaleRadioSeed("k") == false)
        #expect(asked.isStaleRadioSeed("j"))
    }

    @Test("moving the page's last song ahead, or taking it out, makes the radio staged for it stale; adding a song does not")
    func editsMakeItStale() {
        var played = staged(makePage(["a", "b", "c", "d"], tap: "a"), seed: "d")
        played.playNext(song("d"))
        #expect(played.hasStaleAutoplay)
        played.dropStaleAutoplay()
        #expect(played.refillSeed == "c")

        var queued = staged(makePage(["a", "b", "c", "d"], tap: "a"), seed: "d")
        queued.addToQueue(song("d"))
        #expect(queued.hasStaleAutoplay)

        var removed = staged(makePage(["a", "b", "c", "d"], tap: "a"), seed: "d")
        removed.remove(videoId: "d")
        #expect(removed.hasStaleAutoplay)
        removed.dropStaleAutoplay()
        #expect(removed.refillSeed == "c")

        var added = staged(makePage(["a", "b", "c", "d"], tap: "a"), seed: "d")
        added.addToQueue(song("z"))
        added.playNext(song("y"))
        #expect(added.hasStaleAutoplay == false)
        var inner = staged(makePage(["a", "b", "c", "d"], tap: "a"), seed: "d")
        inner.remove(videoId: "b")
        #expect(inner.hasStaleAutoplay == false)
    }

    @Test("a mix page, a radio queue and a queue that took the radio over have no stale radio")
    func notStaleElsewhere() {
        var mix = MusicQueue()
        mix.start(
            page: MusicQueueAutomixTests.letters.map { song($0) }, playing: song("a"), browseId: "VLRDTMAK5uy_mix",
            continuation: nil, mixPlaylistId: "RDTMAK5uy_mix"
        )
        mix.stageAutoplay([song("r1")], continuation: nil, seed: "l")
        mix = shuffled(mix)
        #expect(mix.hasStaleAutoplay == false)
        #expect(mix.isStaleRadioSeed("l") == false)
        let droppedFromMix = mix.dropStaleAutoplay()
        #expect(droppedFromMix == false)
        #expect(mix.autoplay.map(\.videoId) == ["r1"])

        var radio = MusicQueue()
        radio.start(with: song("a"))
        radio.append(MusicQueueAutomixTests.letters.dropFirst().map { song($0) }, continuation: nil)
        radio = shuffled(radio)
        #expect(radio.hasStaleAutoplay == false)
        #expect(radio.isStaleRadioSeed("k") == false)

        var handedOver = staged(makePage(tap: "a"), seed: "l")
        handedOver.takeAutoplay()
        handedOver = shuffled(handedOver)
        #expect(handedOver.hasStaleAutoplay == false)
        #expect(handedOver.isStaleRadioSeed("l") == false)
    }

    @Test("an empty queue and a page without a staged radio have nothing stale")
    func nothingStaged() {
        var empty = MusicQueue()
        #expect(empty.hasStaleAutoplay == false)
        #expect(empty.isStaleRadioSeed("a") == false)
        let dropped = empty.dropStaleAutoplay()
        #expect(dropped == false)
        #expect(makePage(tap: "a").hasStaleAutoplay == false)
    }

    @Test("every seed of a page is asked at most once, however many walk back through the page")
    func eachSeedOnce() {
        var queue = atEnd(makePage(tap: "a"))
        var asked: [String] = []
        while let seed = queue.refillSeed {
            asked.append(seed)
            queue.noteAsked(seed)
        }
        #expect(asked == Array(MusicQueueAutomixTests.letters.reversed()))
    }
}
