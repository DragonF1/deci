// DeciTests/Music/MusicQueueParkTests.swift
// Autoplay off on a radio queue: the radio songs the listener has not reached are parked out of the play order, the songs
// the listener queued stay, and turning Autoplay back on returns the parked songs in order behind them.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("MusicQueue parked radio")
struct MusicQueueParkTests {
    private func ids(_ tracks: some Sequence<Deci.MusicTrack>) -> [String] { tracks.map(\.videoId) }

    private func song(_ id: String) -> Deci.MusicTrack { MusicSamples.track(id, title: "Song \(id)") }

    private func songs(_ list: [String]) -> [Deci.MusicTrack] { list.map { song($0) } }

    /// A radio queue of `list`: the first is the tapped song, the rest is what the radio answered. It stands on `current`.
    private func makeRadio(_ list: [String], current: Int = 0, continuation: String? = nil) -> MusicQueue {
        var queue = MusicQueue()
        queue.start(with: song(list[0]))
        queue.adoptRadio(seedVideoId: list[0])
        queue.append(songs(Array(list.dropFirst())), continuation: continuation)
        for _ in 0..<current { queue.advance() }
        return queue
    }

    private func shuffled(_ queue: MusicQueue, seed: UInt64 = 7) -> MusicQueue {
        var copy = queue
        var generator = MusicShuffleGenerator(seed: seed)
        copy.shuffle(using: &generator)
        return copy
    }

    // MARK: - Parking

    @Test("parking hides the radio songs after the current one, and the radio's next page with them")
    func parkHidesTheRadio() {
        var queue = makeRadio(["a", "r1", "r2", "r3"], continuation: "c1")
        queue.parkRadio()

        #expect(ids(queue.tracks) == ["a"])
        #expect(queue.current?.videoId == "a")
        #expect(queue.upcomingCount == 0)
        #expect(queue.hasNext == false)
        #expect(queue.continuation == nil)
        #expect(queue.needsMore == false)
        #expect(queue.radioIsParked)
        #expect(ids(queue.parked) == ["r1", "r2", "r3"])
        // A parked song cannot be jumped to: it is not in the queue.
        #expect(queue.jump(to: "r1") == nil)
    }

    @Test("parking keeps the songs before the current one, and the current one even when it came from the radio")
    func parkKeepsHistoryAndCurrent() {
        var queue = makeRadio(["a", "r1", "r2", "r3", "r4"], current: 2)
        queue.parkRadio()

        #expect(ids(queue.tracks) == ["a", "r1", "r2"])
        #expect(queue.current?.videoId == "r2")
        #expect(queue.hasPrevious)
        #expect(queue.playsRadioSong)
        #expect(ids(queue.parked) == ["r3", "r4"])
    }

    @Test("songs added with Play next or Add to queue are not parked, even when they came from the radio")
    func parkKeepsQueuedSongs() {
        var queue = makeRadio(["a", "r1", "r2", "r3", "r4"])
        queue.playNext(song("x"))
        queue.addToQueue(song("y"))
        queue.playNext(song("r4"))
        #expect(ids(queue.tracks) == ["a", "r4", "x", "y", "r1", "r2", "r3"])

        queue.parkRadio()

        #expect(ids(queue.tracks) == ["a", "r4", "x", "y"])
        #expect(ids(queue.parked) == ["r1", "r2", "r3"])
    }

    @Test("a page's own songs that are ahead of the radio are not parked")
    func parkKeepsPageSongs() {
        var queue = MusicQueue()
        queue.start(page: songs(["a", "b", "c"]), playing: song("a"), browseId: "VLPL1", continuation: nil)
        queue.adoptRadio(seedVideoId: "c")
        queue.append(songs(["r1", "r2"]), continuation: "c1")
        #expect(ids(queue.tracks) == ["a", "b", "c", "r1", "r2"])

        queue.parkRadio()

        #expect(ids(queue.tracks) == ["a", "b", "c"])
        #expect(ids(queue.parked) == ["r1", "r2"])

        queue.restoreRadio()
        #expect(ids(queue.tracks) == ["a", "b", "c", "r1", "r2"])
        #expect(queue.continuation == "c1")
    }

    @Test("the staged radio of a page that joined the queue is parked, and the page stays")
    func parkTakesTheHandedOverRadio() {
        var queue = MusicQueue()
        queue.start(page: songs(["a", "b"]), playing: song("b"), browseId: "VLPL1", continuation: nil)
        queue.stageAutoplay(songs(["r1", "r2", "r3"]), continuation: "c1", seed: "b")
        queue.takeAutoplay()
        queue.advance()
        #expect(queue.current?.videoId == "r1")

        queue.parkRadio()

        #expect(ids(queue.tracks) == ["a", "b", "r1"])
        #expect(ids(queue.parked) == ["r2", "r3"])
        #expect(queue.playsRadioSong)

        queue.restoreRadio()
        #expect(ids(queue.tracks) == ["a", "b", "r1", "r2", "r3"])
        #expect(queue.continuation == "c1")
    }

    @Test("a page queue, a mix and an empty queue are not parked")
    func parkOnlyAPlainRadio() {
        var page = MusicQueue()
        page.start(page: songs(["a", "b", "c"]), playing: song("a"), browseId: "VLPL1", continuation: "t1")
        let pageBefore = page
        page.parkRadio()
        #expect(page == pageBefore)
        #expect(page.radioIsParked == false)
        #expect(page.isPlainRadio == false)

        var mix = MusicQueue()
        mix.start(page: songs(["a"]), playing: song("a"), browseId: "VLRDAMPL", continuation: nil, mixPlaylistId: "RDAMPL")
        mix.adoptRadio(seedVideoId: "a")
        mix.append(songs(["m1", "m2"]), continuation: "mc1")
        let mixBefore = mix
        mix.parkRadio()
        #expect(mix == mixBefore)
        #expect(mix.isPlainRadio == false)
        #expect(ids(mix.tracks) == ["a", "m1", "m2"])

        var empty = MusicQueue()
        empty.parkRadio()
        #expect(empty == MusicQueue())
    }

    @Test("a lone song with no radio answer yet is a plain radio queue and parks nothing")
    func parkOnALoneSong() {
        var queue = MusicQueue()
        queue.start(with: song("a"))
        #expect(queue.isPlainRadio)

        queue.parkRadio()
        #expect(ids(queue.tracks) == ["a"])
        #expect(queue.parked.isEmpty)
        #expect(queue.radioIsParked)

        queue.restoreRadio()
        #expect(queue.radioIsParked == false)
        var fresh = MusicQueue()
        fresh.start(with: song("a"))
        #expect(queue == fresh)
    }

    // MARK: - Songs already reached

    @Test("a radio song the listener already heard and went back from with Previous is not parked: Next plays it and then stops")
    func parkKeepsTheReachedSongAfterPrevious() {
        var queue = makeRadio(["a", "r1", "r2", "r3", "r4"], current: 3, continuation: "c1")
        #expect(queue.retreat()?.videoId == "r2")

        queue.parkRadio()

        #expect(ids(queue.tracks) == ["a", "r1", "r2", "r3"])
        #expect(ids(queue.parked) == ["r4"])
        #expect(queue.current?.videoId == "r2")
        #expect(queue.hasNext)
        #expect(queue.advance()?.videoId == "r3")
        #expect(queue.advance() == nil)
        #expect(queue.hasNext == false)
    }

    @Test("restoring after Previous keeps the order, with no song twice")
    func restoreAfterPrevious() {
        var queue = makeRadio(["a", "r1", "r2", "r3", "r4", "r5"], current: 3, continuation: "c1")
        queue.retreat()
        queue.parkRadio()
        #expect(ids(queue.parked) == ["r4", "r5"])

        queue.restoreRadio()

        #expect(ids(queue.tracks) == ["a", "r1", "r2", "r3", "r4", "r5"])
        #expect(queue.current?.videoId == "r2")
        #expect(queue.continuation == "c1")
        #expect(queue.parked.isEmpty)
    }

    @Test("an answer that lands after Previous and a park leaves the reached songs where they are")
    func parkAnswerAfterPrevious() {
        var queue = makeRadio(["a", "r1", "r2", "r3"], current: 3)
        queue.retreat()
        queue.parkRadio()

        queue.parkAnswer(songs(["r3", "r4"]), continuation: nil)

        #expect(ids(queue.tracks) == ["a", "r1", "r2", "r3"])
        #expect(ids(queue.parked) == ["r4"])
    }

    @Test("a song reached by a jump stays when the listener then goes back")
    func parkKeepsTheJumpedToSong() {
        var queue = makeRadio(["a", "r1", "r2", "r3", "r4"])
        #expect(queue.jump(to: "r3")?.videoId == "r3")
        #expect(queue.retreat()?.videoId == "r2")

        queue.parkRadio()

        #expect(ids(queue.tracks) == ["a", "r1", "r2", "r3"])
        #expect(ids(queue.parked) == ["r4"])
    }

    @Test("songs reached before Loop playlist wrapped to the start stay")
    func parkKeepsWhatTheLapReached() {
        var queue = makeRadio(["a", "r1", "r2"], current: 2)
        #expect(queue.wrapToStart()?.videoId == "a")

        queue.parkRadio()

        #expect(ids(queue.tracks) == ["a", "r1", "r2"])
        #expect(queue.parked.isEmpty)
    }

    @Test("reached songs are told by id, so turning Shuffle on after Previous keeps them wherever they land")
    func reachedSurvivesShuffleOn() {
        var queue = makeRadio(["a", "r1", "r2", "r3", "r4", "r5", "r6"], current: 3)
        queue.retreat()
        queue = shuffled(queue)
        #expect(queue.current?.videoId == "r2")

        queue.parkRadio()

        // r3 is the only song after r2 that was heard; the rest of what follows r2 is parked, in the radio's order.
        #expect(Set(ids(queue.tracks)) == ["a", "r1", "r2", "r3"])
        #expect(ids(queue.tracks).last == "r3")
        #expect(ids(queue.parked) == ["r4", "r5", "r6"])
    }

    @Test("reached songs are told by id, so turning Shuffle off keeps the heard ones wherever unshuffling puts them")
    func reachedSurvivesShuffleOff() {
        let natural = ["a", "r1", "r2", "r3", "r4", "r5", "r6"]
        var queue = shuffled(makeRadio(natural), seed: 4)
        let order = ids(queue.tracks)
        queue.advance()
        queue.advance()
        queue.retreat()
        queue.unshuffle()
        let current = natural.firstIndex(of: order[1])!
        // The song heard last lies after the current one in the natural order: a place it did not have when it was heard.
        #expect(natural.firstIndex(of: order[2])! > current)

        queue.parkRadio()

        // The songs up to the current one stay, and so does the heard song after it; the rest of the radio is parked.
        let kept = natural.enumerated().filter { $0.offset <= current || $0.element == order[2] }.map(\.element)
        #expect(ids(queue.tracks) == kept)
        #expect(ids(queue.parked) == natural.filter { !kept.contains($0) })
    }

    @Test("a new tapped song and a new page forget what was reached")
    func replacingTheQueueForgetsTheReached() {
        var tapped = makeRadio(["a", "r1", "r2"], current: 2)
        tapped.start(with: song("a"))
        tapped.adoptRadio(seedVideoId: "a")
        tapped.append(songs(["r1", "r2"]), continuation: nil)
        tapped.parkRadio()
        #expect(ids(tapped.tracks) == ["a"])
        #expect(ids(tapped.parked) == ["r1", "r2"])

        var page = makeRadio(["a", "r1", "r2"], current: 2)
        page.start(page: songs(["p", "q"]), playing: song("p"), browseId: "VLPL1", continuation: nil)
        page.adoptRadio(seedVideoId: "q")
        page.append(songs(["r1", "r2"]), continuation: nil)
        page.parkRadio()
        #expect(ids(page.tracks) == ["p", "q"])
        #expect(ids(page.parked) == ["r1", "r2"])
    }

    // MARK: - Restoring

    @Test("restoring puts the parked songs behind the queued ones, in their order, with the continuation")
    func restoreOrder() {
        var queue = makeRadio(["a", "r1", "r2", "r3"], continuation: "c1")
        queue.playNext(song("x"))
        queue.parkRadio()
        // Songs added while the radio is parked go in front of it when it returns.
        queue.addToQueue(song("y"))
        queue.playNext(song("z"))
        #expect(ids(queue.tracks) == ["a", "z", "x", "y"])

        let count = queue.restoreRadio()

        #expect(count == 3)
        #expect(ids(queue.tracks) == ["a", "z", "x", "y", "r1", "r2", "r3"])
        #expect(queue.continuation == "c1")
        #expect(queue.radioIsParked == false)
        #expect(queue.parked.isEmpty)
        #expect(queue.current?.videoId == "a")
    }

    @Test("park then restore brings back the queue it was")
    func roundTrip() {
        let original = makeRadio(["a", "r1", "r2", "r3", "r4"], current: 1, continuation: "c1")
        var queue = original
        queue.parkRadio()
        queue.restoreRadio()
        #expect(queue == original)
    }

    @Test("restoring a queue that was never parked changes nothing")
    func restoreWithoutPark() {
        let original = makeRadio(["a", "r1", "r2"], continuation: "c1")
        var queue = original
        #expect(queue.restoreRadio() == 0)
        #expect(queue == original)
    }

    @Test("a parked song the listener adds with Play next plays there and is not queued twice when the radio returns")
    func parkedSongPlayedNext() {
        var queue = makeRadio(["a", "r1", "r2", "r3"])
        queue.parkRadio()
        queue.playNext(song("r2"))
        #expect(ids(queue.tracks) == ["a", "r2"])

        queue.restoreRadio()

        #expect(ids(queue.tracks) == ["a", "r2", "r1", "r3"])
    }

    @Test("a song the listener took out before parking does not come back with the parked radio")
    func removedStaysRemoved() {
        var queue = makeRadio(["a", "r1", "r2", "r3"])
        queue.remove(videoId: "r2")
        queue.parkRadio()
        queue.parkAnswer(songs(["r2", "r9"]), continuation: nil)

        queue.restoreRadio()

        #expect(ids(queue.tracks) == ["a", "r1", "r3", "r9"])
    }

    // MARK: - Answers that land while parked

    @Test("an answer that lands while the radio is parked joins the parked songs, without repeats, and brings its continuation")
    func parkAnswerJoinsTheParked() {
        var queue = makeRadio(["a", "r1", "r2"], continuation: "c1")
        queue.playNext(song("x"))
        queue.parkRadio()

        let added = queue.parkAnswer(songs(["r2", "r3", "x", "a", "r4", "r4"]), continuation: "c2")

        #expect(added == 2)
        #expect(ids(queue.tracks) == ["a", "x"])
        #expect(ids(queue.parked) == ["r1", "r2", "r3", "r4"])
        #expect(queue.continuation == nil)
        #expect(queue.needsMore == false)

        queue.restoreRadio()
        #expect(ids(queue.tracks) == ["a", "x", "r1", "r2", "r3", "r4"])
        #expect(queue.continuation == "c2")
    }

    @Test("the first radio answer, landing while parked, is parked and the tapped song's radio counts as asked")
    func parkAnswerOnALoneSong() {
        var queue = MusicQueue()
        queue.start(with: song("a"))
        queue.parkRadio()
        queue.adoptRadio(seedVideoId: "a")

        queue.parkAnswer(songs(["a", "r1", "r2"]), continuation: "c1")

        #expect(ids(queue.tracks) == ["a"])
        #expect(queue.awaitsFirstRadioPage == false)
        #expect(queue.radioIsParked)

        queue.restoreRadio()
        #expect(ids(queue.tracks) == ["a", "r1", "r2"])
        #expect(queue.continuation == "c1")
    }

    @Test("an answer parked on a queue that was not parked yet parks the radio")
    func parkAnswerParksTheRadio() {
        var queue = MusicQueue()
        queue.start(with: song("a"))
        queue.parkAnswer(songs(["r1"]), continuation: nil)
        #expect(queue.radioIsParked)
        #expect(ids(queue.tracks) == ["a"])
    }

    @Test("ending paging forgets the parked radio's next page too")
    func clearContinuationReachesTheParked() {
        var queue = makeRadio(["a", "r1", "r2"], continuation: "c1")
        queue.parkRadio()
        queue.clearContinuation()
        queue.restoreRadio()
        #expect(ids(queue.tracks) == ["a", "r1", "r2"])
        #expect(queue.continuation == nil)
    }

    // MARK: - Dropping

    @Test("a new tapped song, a new page and clearing the queue drop the parked radio")
    func replacingTheQueueDropsIt() {
        func parkedQueue() -> MusicQueue {
            var queue = makeRadio(["a", "r1", "r2"], continuation: "c1")
            queue.parkRadio()
            return queue
        }

        var tapped = parkedQueue()
        tapped.start(with: song("z"))
        #expect(tapped.parked.isEmpty)
        #expect(tapped.radioIsParked == false)
        tapped.restoreRadio()
        #expect(ids(tapped.tracks) == ["z"])
        #expect(tapped.continuation == nil)

        var page = parkedQueue()
        page.start(page: songs(["p", "q"]), playing: song("p"), browseId: "VLPL1", continuation: nil)
        page.restoreRadio()
        #expect(ids(page.tracks) == ["p", "q"])
        #expect(page.radioIsParked == false)

        var cleared = parkedQueue()
        cleared.clear()
        cleared.restoreRadio()
        #expect(cleared == MusicQueue())
    }

    // MARK: - Shuffle

    @Test("while shuffled the parked radio comes back mixed in after the next song, as a radio page would")
    func restoreWhileShuffled() {
        let radio = ["r1", "r2", "r3", "r4", "r5", "r6"]
        var queue = shuffled(makeRadio(["a"] + radio, continuation: "c1"))
        #expect(queue.isShuffled)
        queue.parkRadio()
        #expect(ids(queue.tracks) == ["a"])

        var generator = MusicShuffleGenerator(seed: 11)
        queue.restoreRadio(using: &generator)

        // The same as a shuffled lone song that gets the radio page appended with that generator.
        var fresh = shuffled(makeRadio(["a"]))
        var freshGenerator = MusicShuffleGenerator(seed: 11)
        fresh.append(songs(radio), continuation: "c1", using: &freshGenerator)
        #expect(ids(queue.tracks) == ids(fresh.tracks))
        #expect(queue.continuation == "c1")
        #expect(Set(ids(queue.tracks)) == Set(["a"] + radio))
        // Shuffle off puts the radio back in the order it was answered in.
        queue.unshuffle()
        #expect(ids(queue.tracks) == ["a"] + radio)
    }

    @Test("parking a shuffled queue takes the radio songs in their natural order, not the shuffled one")
    func parkWhileShuffledKeepsTheNaturalOrder() {
        let radio = ["r1", "r2", "r3", "r4", "r5", "r6"]
        var queue = shuffled(makeRadio(["a"] + radio))
        queue.parkRadio()
        #expect(ids(queue.parked) == radio)
    }

    @Test("turning Shuffle on while the radio is parked still mixes the radio in when it returns")
    func shuffleTurnedOnWhileParked() {
        var queue = makeRadio(["a", "r1", "r2", "r3", "r4"])
        queue.parkRadio()
        queue = shuffled(queue)

        queue.restoreRadio()

        #expect(queue.current?.videoId == "a")
        #expect(Set(ids(queue.tracks)) == ["a", "r1", "r2", "r3", "r4"])
        queue.unshuffle()
        #expect(ids(queue.tracks) == ["a", "r1", "r2", "r3", "r4"])
    }

    // MARK: - Playing what is left

    @Test("a parked queue plays the songs the listener queued and then has nothing next")
    func parkedQueuePlaysOutTheQueuedSongs() {
        var queue = makeRadio(["a", "r1", "r2"], continuation: "c1")
        queue.playNext(song("x"))
        queue.parkRadio()

        #expect(queue.advance()?.videoId == "x")
        #expect(queue.advance() == nil)
        #expect(queue.hasNext == false)
        // The radio that was parked is not the radio of the last song: nothing asks for its page.
        #expect(queue.needsMore == false)
    }
}
