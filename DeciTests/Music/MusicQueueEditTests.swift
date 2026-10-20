// DeciTests/Music/MusicQueueEditTests.swift
// Play next, Add to queue and Remove from queue on the play order: where the song lands, that the queue never holds a
// song twice, and that an edit survives the Loop playlist laps, a shuffle toggle and the radio refill.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("MusicQueue edits")
struct MusicQueueEditTests {
    private static let letters = ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l"]

    private func ids(_ tracks: some Sequence<Deci.MusicTrack>) -> [String] { tracks.map(\.videoId) }

    private func song(_ id: String) -> Deci.MusicTrack { MusicSamples.track(id, title: "Song \(id)") }

    /// A radio-source queue of `list` standing on `current`.
    private func makeRadio(_ list: [String], current: Int = 0, continuation: String? = nil) -> MusicQueue {
        var queue = MusicQueue()
        let tracks = list.map { song($0) }
        queue.start(with: tracks[0])
        queue.append(Array(tracks.dropFirst()), continuation: continuation)
        for _ in 0..<current { queue.advance() }
        return queue
    }

    /// A page-source queue of `list` standing on `tap`.
    private func makePage(_ list: [String] = MusicQueueEditTests.letters, tap: String? = nil) -> MusicQueue {
        var queue = MusicQueue()
        queue.start(page: list.map { song($0) }, playing: song(tap ?? list[0]), browseId: "VLPL1", continuation: nil)
        return queue
    }

    private func shuffled(_ queue: MusicQueue, seed: UInt64 = 7, mixingEarlier: Bool = false) -> MusicQueue {
        var copy = queue
        var generator = MusicShuffleGenerator(seed: seed)
        copy.shuffle(mixingEarlier: mixingEarlier, using: &generator)
        return copy
    }

    // MARK: - Play next

    @Test("Play next puts the song right after the current one")
    func playNextAfterCurrent() {
        var queue = makeRadio(["a", "b", "c", "d"], current: 1)
        let done = queue.playNext(song("x"))
        #expect(done)
        #expect(ids(queue.tracks) == ["a", "b", "x", "c", "d"])
        #expect(queue.current?.videoId == "b")
    }

    @Test("Several Play next in a row: the latest plays first, as in YouTube Music")
    func latestPlayNextFirst() {
        var queue = makeRadio(["a", "b", "c"])
        queue.playNext(song("x"))
        queue.playNext(song("y"))
        #expect(ids(queue.upcoming) == ["y", "x", "b", "c"])
    }

    @Test("Play next is refused for the current song and on an empty queue")
    func playNextRefused() {
        var queue = makeRadio(["a", "b"])
        let current = queue.playNext(song("a"))
        #expect(current == false)
        #expect(ids(queue.tracks) == ["a", "b"])

        var empty = MusicQueue()
        let none = empty.playNext(song("x"))
        #expect(none == false)
        #expect(empty.isEmpty)
    }

    @Test("Play next moves a song that is already upcoming instead of doubling it")
    func playNextMovesUpcoming() {
        var queue = makeRadio(["a", "b", "c", "d", "e"])
        queue.playNext(song("d"))
        #expect(ids(queue.tracks) == ["a", "d", "b", "c", "e"])
    }

    @Test("Play next on a song that already played drops the old copy and keeps the current song current")
    func playNextDropsHistoryCopy() {
        var queue = makeRadio(["a", "b", "c", "d"], current: 2)
        queue.playNext(song("a"))
        #expect(ids(queue.tracks) == ["b", "c", "a", "d"])
        #expect(queue.current?.videoId == "c")
        #expect(queue.currentIndex == 1)
        #expect(queue.hasPrevious)
    }

    @Test("Play next on a song of the staged radio takes it out of the radio, so Up next lists it once")
    func playNextTakesFromStagedRadio() {
        var queue = makePage(["a", "b", "c"])
        queue.stageAutoplay(MusicSamples.tracks("r1", "r2", "r3"), continuation: "t", seed: "c")
        queue.playNext(song("r2"))
        #expect(ids(queue.tracks) == ["a", "r2", "b", "c"])
        #expect(ids(queue.autoplay) == ["r1", "r3"])
    }

    // MARK: - Add to queue

    @Test("Add to queue on a page goes after the rest of the playlist and before the staged radio")
    func addToQueueOnPage() {
        var queue = makePage(["a", "b", "c"])
        queue.stageAutoplay(MusicSamples.tracks("r1", "r2"), continuation: nil, seed: "c")
        queue.addToQueue(song("x"))
        queue.addToQueue(song("y"))
        #expect(ids(queue.tracks) == ["a", "b", "c", "x", "y"])
        #expect(ids(queue.autoplay) == ["r1", "r2"])
    }

    @Test("Add to queue on a radio goes after the songs the listener queued and before the radio's own")
    func addToQueueOnRadio() {
        var queue = makeRadio(["a", "r1", "r2", "r3"])
        queue.addToQueue(song("x"))
        #expect(ids(queue.tracks) == ["a", "x", "r1", "r2", "r3"])
        queue.playNext(song("p"))
        queue.addToQueue(song("y"))
        #expect(ids(queue.tracks) == ["a", "p", "x", "y", "r1", "r2", "r3"])
    }

    @Test("Add to queue after the staged radio joined: still before the radio's songs")
    func addToQueueAfterHandOver() {
        var queue = makePage(["a", "b"])
        queue.stageAutoplay(MusicSamples.tracks("r1", "r2", "r3"), continuation: "t", seed: "b")
        queue.advance()
        queue.takeAutoplay()
        queue.addToQueue(song("x"))
        #expect(ids(queue.tracks) == ["a", "b", "x", "r1", "r2", "r3"])
        #expect(queue.current?.videoId == "b")
    }

    @Test("Add to queue moves an upcoming song to the end of the queue's own songs")
    func addToQueueMovesUpcoming() {
        var queue = makePage(["a", "b", "c", "d"])
        queue.addToQueue(song("b"))
        #expect(ids(queue.tracks) == ["a", "c", "d", "b"])
    }

    @Test("A song added to a page that is still loading stays behind the pages that arrive later, a Play next song does not")
    func addToQueueOnLoadingPage() {
        var queue = MusicQueue()
        queue.start(page: MusicSamples.tracks("a", "b"), playing: song("a"), browseId: "VLPL1", continuation: "t1")
        queue.addToQueue(song("x"))
        queue.append(MusicSamples.tracks("c", "d"), continuation: "t2")
        queue.playNext(song("y"))
        queue.append(MusicSamples.tracks("e"), continuation: nil)
        #expect(ids(queue.tracks) == ["a", "y", "b", "c", "d", "e", "x"])
    }

    @Test("Add to queue on a song that already played drops the old copy, and refuses the current song")
    func addToQueueHistoryAndCurrent() {
        var queue = makePage(["a", "b", "c", "d"], tap: "c")
        queue.addToQueue(song("a"))
        #expect(ids(queue.tracks) == ["b", "c", "d", "a"])
        #expect(queue.current?.videoId == "c")
        let current = queue.addToQueue(song("c"))
        #expect(current == false)
        #expect(ids(queue.tracks) == ["b", "c", "d", "a"])
    }

    // MARK: - Laps, refill

    @Test("A queued song plays in every Loop playlist lap")
    func queuedSongInEveryLap() {
        var queue = makePage(["a", "b", "c"])
        queue.playNext(song("x"))
        queue.advance()
        queue.advance()
        queue.advance()
        #expect(queue.current?.videoId == "c")
        #expect(queue.upcomingCount == 0)
        queue.wrapToStart()
        #expect(queue.current?.videoId == "a")
        #expect(ids(queue.upcoming) == ["x", "b", "c"])
    }

    @Test("The radio refill and the hand-over never take a queued song away")
    func refillKeepsQueuedSongs() {
        var radio = makeRadio(["a", "b"])
        radio.playNext(song("x"))
        let added = radio.append(MusicSamples.tracks("x", "c", "d"), continuation: nil)
        #expect(added == 2)
        #expect(ids(radio.tracks) == ["a", "x", "b", "c", "d"])

        var page = makePage(["a", "b"])
        page.addToQueue(song("y"))
        page.stageAutoplay(MusicSamples.tracks("r1", "r2"), continuation: nil, seed: "b")
        page.takeAutoplay()
        #expect(ids(page.tracks) == ["a", "b", "y", "r1", "r2"])
    }

    // MARK: - Shuffle

    @Test("Shuffle on keeps the queued songs ahead of the mix in their order, and shuffle off puts them where they were placed")
    func shuffleKeepsQueuedAhead() {
        for mixing in [true, false] {
            var queue = mixing ? makePage() : makeRadio(Self.letters)
            queue.playNext(song("x"))
            queue.addToQueue(song("y"))
            let natural = ids(queue.tracks)
            var mixed = shuffled(queue, mixingEarlier: mixing)

            #expect(ids(mixed.tracks.prefix(3)) == ["a", "x", "y"])
            #expect(Set(ids(mixed.tracks)) == Set(natural))
            #expect(ids(mixed.tracks) != natural)

            mixed.unshuffle()
            #expect(ids(mixed.tracks) == natural)
            #expect(mixed.current?.videoId == "a")
        }
    }

    @Test("Play next while shuffled lands after the current song and, unshuffled, right after the song that was playing")
    func playNextWhileShuffled() {
        var queue = shuffled(makePage(), mixingEarlier: true)
        queue.advance()
        queue.advance()
        let playing = queue.current?.videoId ?? ""
        queue.playNext(song("x"))
        #expect(queue.upcoming.first?.videoId == "x")

        queue.unshuffle()
        var natural = Self.letters
        natural.insert("x", at: natural.firstIndex(of: playing)! + 1)
        #expect(ids(queue.tracks) == natural)
        #expect(queue.current?.videoId == playing)
    }

    @Test("Add to queue while shuffled goes to the end of the order, and to the end of the natural order after unshuffle")
    func addToQueueWhileShuffled() {
        var queue = shuffled(makePage(), mixingEarlier: true)
        queue.addToQueue(song("x"))
        #expect(queue.tracks.last?.videoId == "x")
        queue.unshuffle()
        #expect(ids(queue.tracks) == Self.letters + ["x"])
    }

    @Test("A page landing while shuffled never splits the queued songs or passes the songs added to the end")
    func shuffledAppendKeepsEdits() {
        for seed in UInt64(1)...20 {
            var queue = shuffled(makeRadio(["a", "b", "c", "d"]))
            queue.playNext(song("x"))
            queue.playNext(song("y"))
            var generator = MusicShuffleGenerator(seed: seed)
            queue.append(MusicSamples.tracks("r1", "r2", "r3", "r4"), continuation: nil, using: &generator)
            #expect(ids(queue.upcoming.prefix(2)) == ["y", "x"])

            var page = shuffled(makePage(["a", "b", "c", "d"]), mixingEarlier: true)
            page.addToQueue(song("z"))
            page.append(MusicSamples.tracks("e", "f", "g"), continuation: nil, using: &generator)
            #expect(page.tracks.last?.videoId == "z")
            page.unshuffle()
            #expect(ids(page.tracks) == ["a", "b", "c", "d", "e", "f", "g", "z"])
        }
    }

    // MARK: - Remove

    @Test("Remove takes an upcoming song out of the play order")
    func removeUpcoming() {
        var queue = makeRadio(["a", "b", "c", "d"])
        let done = queue.remove(videoId: "c")
        #expect(done)
        #expect(ids(queue.tracks) == ["a", "b", "d"])
        #expect(queue.current?.videoId == "a")
    }

    @Test("A removed song does not come back on the next Loop playlist lap")
    func removedNotInNextLap() {
        var queue = makePage(["a", "b", "c"])
        queue.remove(videoId: "b")
        queue.advance()
        queue.wrapToStart()
        #expect(ids(queue.upcoming) == ["c"])
    }

    @Test("Remove on a song that already played (a row of the next lap) keeps the current song current")
    func removeHistoryRow() {
        var queue = makeRadio(["a", "b", "c", "d"], current: 2)
        queue.remove(videoId: "a")
        #expect(ids(queue.tracks) == ["b", "c", "d"])
        #expect(queue.current?.videoId == "c")
        #expect(queue.currentIndex == 1)
    }

    @Test("Remove works on a song of the staged radio and leaves the queue's own songs alone")
    func removeFromStagedRadio() {
        var queue = makePage(["a", "b"])
        queue.stageAutoplay(MusicSamples.tracks("r1", "r2", "r3"), continuation: nil, seed: "b")
        let done = queue.remove(videoId: "r2")
        #expect(done)
        #expect(ids(queue.autoplay) == ["r1", "r3"])
        #expect(ids(queue.tracks) == ["a", "b"])
    }

    @Test("Remove refuses the current song and a song that is not queued")
    func removeRefused() {
        var queue = makeRadio(["a", "b"])
        let current = queue.remove(videoId: "a")
        let unknown = queue.remove(videoId: "zzz")
        #expect(current == false)
        #expect(unknown == false)
        #expect(ids(queue.tracks) == ["a", "b"])
    }

    @Test("A removed song stays out of later radio pages and a restaged radio until it is queued again")
    func removedStaysOut() {
        var queue = makeRadio(["a", "b", "c"])
        queue.remove(videoId: "b")
        let added = queue.append(MusicSamples.tracks("b", "d"), continuation: nil)
        #expect(added == 1)
        #expect(ids(queue.tracks) == ["a", "c", "d"])

        var page = makePage(["a", "b"])
        page.stageAutoplay(MusicSamples.tracks("r1", "r2"), continuation: nil, seed: "b")
        page.remove(videoId: "r1")
        page.stageAutoplay(MusicSamples.tracks("r1", "r3"), continuation: nil, seed: "a")
        #expect(ids(page.autoplay) == ["r3"])

        queue.playNext(song("b"))
        #expect(ids(queue.tracks) == ["a", "b", "c", "d"])
    }

    @Test("Remove on a shuffled queue still unshuffles cleanly")
    func removeWhileShuffled() {
        var queue = shuffled(makePage(), mixingEarlier: true)
        queue.remove(videoId: "e")
        queue.unshuffle()
        #expect(ids(queue.tracks) == Self.letters.filter { $0 != "e" })
    }

    @Test("Starting a new queue forgets what was queued and removed")
    func startForgetsEdits() {
        var queue = makeRadio(["a", "b", "c"])
        queue.playNext(song("p"))
        queue.remove(videoId: "c")
        queue.start(with: song("z"))
        queue.append(MusicSamples.tracks("c", "q1"), continuation: nil)
        queue.addToQueue(song("x"))
        #expect(ids(queue.tracks) == ["z", "x", "c", "q1"])
    }
}
