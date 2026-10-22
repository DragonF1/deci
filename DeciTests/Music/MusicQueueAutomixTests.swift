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

    @Test("a page near its end seeds the automix with its last song, as it always did")
    func lastSongInPageOrder() {
        #expect(makePage(["a", "b", "c"], tap: "c").refillSeed == "c")
        #expect(makePage(["a", "b", "c", "d", "e"], tap: "b").refillSeed == "e")
        #expect(makePage(["a", "b", "c", "d", "e", "f"], tap: "b").refillSeed == nil)
        #expect(makePage(["a", "b", "c"], tap: "c", continuation: "t1").refillSeed == nil)
    }

    @Test("a shuffled page seeds with the last song of the page's own order, not the last of the mix")
    func shuffledSeedIsNaturalLast() {
        let queue = atEnd(shuffled(makePage(tap: "a")))
        #expect(queue.tracks.last?.videoId != "l", "the mix must not end where the page does, or this test shows nothing")
        #expect(queue.refillSeed == "l")
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

    @Test("the seed is nothing while there are more songs than the threshold, shuffled or not")
    func notYet() {
        #expect(makePage(tap: "a").refillSeed == nil)
        #expect(shuffled(makePage(tap: "a")).refillSeed == nil)
    }
}
