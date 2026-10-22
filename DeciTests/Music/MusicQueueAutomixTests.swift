// DeciTests/Music/MusicQueueAutomixTests.swift
// What a page queue remembers for the playlist automix: the playlist id its page asks it of, and the song it asks it
// after, which is the last of the page's own songs in the page's order, however the play order is mixed.

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

    @Test("a shuffled page seeds with the last song of the page's own order, not the last of the mix")
    func shuffledSeedIsNaturalLast() {
        let queue = atEnd(shuffled(makePage(tap: "a")))
        #expect(queue.tracks.last?.videoId != "l", "the mix must not end where the page does, or this test shows nothing")
        #expect(queue.refillSeed == "l")
    }

    @Test("a shuffled page seeds with the page's last song from the start, with the whole mix still to play")
    func shuffledSeedAtOnce() {
        let queue = shuffled(makePage(tap: "a"))
        #expect(queue.upcomingCount == 11)
        #expect(queue.tracks.last?.videoId != "l", "the mix must not end where the page does, or this test shows nothing")
        #expect(queue.refillSeed == "l")
        #expect(shuffled(makePage(tap: "d"), mixingEarlier: true).refillSeed == "l")
    }

    @Test("the natural seed is the same for every shuffle and for the shuffled and unshuffled queue")
    func shuffledSeedIsStable() {
        for seed in [1, 2, 3, 4, 5, 6, 7, 8, 9, 10] as [UInt64] {
            let queue = atEnd(shuffled(makePage(tap: "a"), seed: seed))
            #expect(queue.refillSeed == "l", "seed \(seed)")
        }
        var plain = shuffled(makePage(tap: "a"))
        plain.unshuffle()
        #expect(atEnd(plain).refillSeed == "l")
    }

    @Test("a page started from a middle row and mixed, with the earlier songs mixed in, still seeds with the page's last")
    func shuffledFromMiddle() {
        let queue = atEnd(shuffled(makePage(tap: "d"), mixingEarlier: true))
        #expect(queue.refillSeed == "l")
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

    @Test("queued songs are skipped while shuffled too")
    func skipsQueuedWhileShuffled() {
        var queue = shuffled(makePage(tap: "a"))
        queue.addToQueue(song("z"))
        queue.playNext(song("y"))
        queue = atEnd(queue)
        #expect(queue.refillSeed == "l")
    }

    @Test("a seed that was asked already is passed over for the page's last song before it")
    func skipsAsked() {
        var queue = makePage(["a", "b", "c"], tap: "c")
        queue.noteAsked("c")
        #expect(queue.refillSeed == "b")
        queue.noteAsked("b")
        #expect(queue.refillSeed == "a")
    }

    @Test("asked seeds are passed over in the page's own order while shuffled")
    func skipsAskedWhileShuffled() {
        var queue = atEnd(shuffled(makePage(tap: "a")))
        queue.noteAsked("l")
        #expect(queue.refillSeed == "k")
    }

    @Test("a song taken out of the page is not its last song")
    func skipsRemoved() {
        var queue = shuffled(makePage(tap: "a"))
        let removed = queue.remove(videoId: "l")
        #expect(removed)
        queue = atEnd(queue)
        #expect(queue.refillSeed == "k")
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
