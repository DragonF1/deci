// DeciTests/Music/MusicServiceModesTests.swift
// The Music tab's playback modes with a fake backend and a fake AVPlayer seam: shuffle, Loop playlist and
// Loop song, and Autoplay (the radio that carries on after a playlist or an album has finished).

import Foundation
import Testing
@testable import Deci

// MARK: - Shared setup

@MainActor
private final class PreferenceSink {
    var saved: [MusicPlaybackPreferences] = []
}

@MainActor
private struct ModesHarness {
    let backend = FakeMusicBackend()
    let engine = FakePlaybackEngine()
    let surface = FakeNowPlayingSurface()
    let clock = MutableClock()
    let sink = PreferenceSink()
    let player: MusicPlayer
    let service: MusicService

    init(preferences: MusicPlaybackPreferences = MusicPlaybackPreferences(), seed: UInt64 = 1) {
        let engine = self.engine
        let clock = self.clock
        let sink = self.sink
        let player = MusicPlayer(engine: engine)
        self.player = player
        self.service = MusicService(
            backend: backend,
            player: player,
            presentSignIn: { _ in },
            presentChannelPicker: { _, _ in },
            closeSignInWindow: {},
            raiseSignInWindow: {},
            nowPlaying: NowPlayingController(surface: surface, fetchArtwork: { _ in nil }),
            now: { clock.now },
            preferences: preferences,
            savePreferences: { sink.saved.append($0) },
            shuffleSeed: seed,
            refreshOnCreate: false
        )
    }

    /// Waits until the play and radio work started so far, including follow-ups they start, has finished.
    func settle() async {
        while true {
            let play = service.playTask
            let radio = service.radioTask
            await play?.value
            await radio?.value
            if service.playTask == play, service.radioTask == radio { break }
        }
    }

    /// Polls until `condition` holds; for work that is held at a gate and cannot be awaited.
    func eventually(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<400 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    /// Plays the first of `ids` with a radio of all of them behind it and waits for both.
    func startRadio(_ ids: [String], continuation: String? = nil) async {
        let tracks = ids.map { MusicSamples.track($0, title: "Song \($0)") }
        await backend.setRadio(seed: ids[0], tracks: tracks, continuation: continuation)
        service.play(tracks[0])
        await settle()
        engine.emit(.playingChanged(true))
    }

    /// Plays `tap` (the first row by default) from a playlist page of `ids` and waits for the queue work.
    func startPage(_ ids: [String], tap: String? = nil, continuation: String? = nil) async {
        let id = tap ?? ids[0]
        service.play(MusicSamples.track(id, title: "Song \(id)"), in: page(ids, continuation: continuation))
        await settle()
        engine.emit(.playingChanged(true))
    }

    func page(_ ids: [String], continuation: String? = nil) -> MusicBrowsePage {
        MusicSamples.page("VLPL1", tracks: ids.map { MusicSamples.track($0, title: "Song \($0)") }, continuation: continuation)
    }

    /// A playlist of `pages` pages of `size` songs: the ids of the first page are returned, the later pages are
    /// the `moreTracks` chain "t1", "t2", and so on. Open the first page with `continuation: "t1"`.
    func longPlaylist(pages: Int, size: Int) async -> [String] {
        for index in 1..<pages {
            await backend.setMoreTracks(
                browseId: "VLPL1",
                continuation: "t\(index)",
                tracks: songs("p\(index)_", size).map { MusicSamples.track($0, title: "Song \($0)") },
                next: index + 1 < pages ? "t\(index + 1)" : nil
            )
        }
        return songs("p0_", size)
    }

    func songs(_ prefix: String, _ count: Int) -> [String] {
        (0..<count).map { "\(prefix)\($0)" }
    }

    /// Ends the playing track and lets the next one load, then reports it as playing.
    func finishTrack() async {
        engine.emit(.ended)
        await settle()
        engine.emit(.playingChanged(true))
    }

    var queuedIDs: [String] { service.queue.tracks.map(\.videoId) }
    var upcomingIDs: [String] { service.queue.upcoming.map(\.videoId) }
    var loadedIDs: [String] { engine.loads.map(\.stream.videoId) }
}

private let letters = ["a", "b", "c", "d", "e", "f", "g", "h"]

// MARK: - Preferences

@MainActor
@Suite("MusicService playback preferences")
struct MusicServicePreferencesTests {
    @Test("shuffle is off, loop is off and autoplay is on until the listener says otherwise")
    func defaults() {
        let h = ModesHarness()
        #expect(h.service.isShuffleOn == false)
        #expect(h.service.loopMode == .off)
        #expect(h.service.isAutoplayOn)
        #expect(MusicPlaybackPreferences() == MusicPlaybackPreferences(shuffle: false, loop: .off, autoplay: true))
    }

    @Test("saved preferences are the starting state")
    func startsFromSaved() {
        let h = ModesHarness(preferences: MusicPlaybackPreferences(shuffle: true, loop: .song, autoplay: false))
        #expect(h.service.isShuffleOn)
        #expect(h.service.loopMode == .song)
        #expect(h.service.isAutoplayOn == false)
        #expect(h.sink.saved.isEmpty)
    }

    @Test("every change saves all three preferences, and setting the same value again saves nothing")
    func changesAreSaved() {
        let h = ModesHarness()
        h.service.setShuffle(true)
        h.service.setLoopMode(.playlist)
        h.service.setAutoplay(false)
        h.service.setShuffle(true)
        h.service.setLoopMode(.playlist)
        h.service.setAutoplay(false)

        #expect(h.sink.saved == [
            MusicPlaybackPreferences(shuffle: true, loop: .off, autoplay: true),
            MusicPlaybackPreferences(shuffle: true, loop: .playlist, autoplay: true),
            MusicPlaybackPreferences(shuffle: true, loop: .playlist, autoplay: false)
        ])
    }

    @Test("the loop button cycles Off, Loop playlist, Loop song and back to Off")
    func loopCycle() {
        let h = ModesHarness()
        var seen: [MusicLoopMode] = []
        for _ in 0..<4 {
            h.service.cycleLoopMode()
            seen.append(h.service.loopMode)
        }
        #expect(seen == [.playlist, .song, .off, .playlist])
        #expect(MusicLoopMode.off.next == .playlist)
        #expect(MusicLoopMode.playlist.next == .song)
        #expect(MusicLoopMode.song.next == .off)
    }

    @Test("a preferences change does not touch what is playing")
    func changeLeavesPlaybackAlone() async {
        let h = ModesHarness()
        await h.startRadio(["a", "b", "c"])
        h.service.setLoopMode(.song)
        h.service.setAutoplay(false)
        #expect(h.loadedIDs == ["a"])
        #expect(h.service.queue.current?.videoId == "a")
    }
}

// MARK: - Shuffle

@MainActor
@Suite("MusicService shuffle")
struct MusicServiceShuffleTests {
    @Test("turning shuffle on mixes what comes after the current track and leaves the rest alone")
    func shuffleOnMidQueue() async {
        let h = ModesHarness()
        await h.startRadio(letters)
        h.service.next()
        await h.settle()
        h.service.setShuffle(true)

        #expect(h.service.queue.isShuffled)
        #expect(Array(h.queuedIDs.prefix(2)) == ["a", "b"])
        #expect(h.service.queue.current?.videoId == "b")
        #expect(Set(h.upcomingIDs) == Set(letters.dropFirst(2)))
        #expect(h.upcomingIDs != Array(letters.dropFirst(2)))
    }

    @Test("turning shuffle off puts the order back and carries on from the current track")
    func shuffleOff() async {
        let h = ModesHarness()
        await h.startRadio(letters)
        h.service.setShuffle(true)
        h.service.next()
        h.service.next()
        await h.settle()
        let standingOn = h.service.queue.current!.videoId

        h.service.setShuffle(false)

        #expect(h.queuedIDs == letters)
        #expect(h.service.queue.current?.videoId == standingOn)
        #expect(h.service.queue.isShuffled == false)
    }

    @Test("next follows the shuffled order")
    func nextFollowsShuffle() async {
        let h = ModesHarness()
        await h.startRadio(letters)
        h.service.setShuffle(true)
        let order = h.queuedIDs
        for step in 1...3 {
            h.service.next()
            await h.settle()
            h.engine.emit(.playingChanged(true))
            #expect(h.service.queue.current?.videoId == order[step])
        }
        #expect(h.loadedIDs == Array(order.prefix(4)))
    }

    @Test("the same seed shuffles the same way")
    func seeded() async {
        let first = ModesHarness(seed: 99)
        let second = ModesHarness(seed: 99)
        let other = ModesHarness(seed: 100)
        for h in [first, second, other] {
            await h.startRadio(letters)
            h.service.setShuffle(true)
        }
        #expect(first.queuedIDs == second.queuedIDs)
        #expect(first.queuedIDs != other.queuedIDs)
    }

    @Test("a radio started with shuffle on mixes its pages into the queue")
    func radioWhileShuffled() async {
        let h = ModesHarness(preferences: MusicPlaybackPreferences(shuffle: true))
        await h.startRadio(letters, continuation: nil)

        #expect(h.service.queue.isShuffled)
        #expect(h.service.queue.current?.videoId == "a")
        #expect(Set(h.upcomingIDs) == Set(letters.dropFirst()))
        #expect(h.queuedIDs.count == letters.count)
    }

    @Test("a page tapped with shuffle on starts on that row and mixes in every other row, earlier ones too")
    func pageWhileShuffled() async {
        let h = ModesHarness(preferences: MusicPlaybackPreferences(shuffle: true))
        await h.startPage(letters, tap: "d")

        #expect(h.service.queue.current?.videoId == "d")
        #expect(h.service.queue.hasPrevious == false)
        #expect(Set(h.upcomingIDs) == Set(letters.filter { $0 != "d" }))
        #expect(h.loadedIDs == ["d"])
        #expect(await h.backend.radioSeeds.isEmpty)
    }

    @Test("turning shuffle off after a shuffled page tap brings the page order back")
    func pageShuffleOff() async {
        let h = ModesHarness(preferences: MusicPlaybackPreferences(shuffle: true))
        await h.startPage(letters, tap: "d")
        h.service.setShuffle(false)
        #expect(h.queuedIDs == letters)
        #expect(h.service.queue.current?.videoId == "d")
        #expect(h.service.queue.hasPrevious)
    }

    @Test("with shuffle off a page tap keeps the page order")
    func pageNotShuffled() async {
        let h = ModesHarness()
        await h.startPage(letters, tap: "d")
        #expect(h.queuedIDs == letters)
        #expect(h.service.queue.isShuffled == false)
    }

    @Test("a page of more tracks that lands while shuffled is mixed into the rest and the next track stays")
    func morePagesWhileShuffled() async {
        let h = ModesHarness(preferences: MusicPlaybackPreferences(shuffle: true))
        let gate = MusicTestGate()
        await h.backend.setMoreTracksGate(browseId: "VLPL1", continuation: "t1", gate)
        await h.backend.setMoreTracks(browseId: "VLPL1", continuation: "t1", tracks: MusicSamples.tracks("v", "w", "x", "y", "z"))
        // Three tracks after the current one is where the queue starts asking for more.
        h.service.play(MusicSamples.track("a"), in: h.page(["a", "b", "c", "d"], continuation: "t1"))
        await h.service.playTask?.value
        let held = await h.eventually { await h.backend.moreTracksCalls.count == 1 }
        #expect(held)
        let before = h.upcomingIDs

        await gate.open()
        await h.settle()

        let after = h.upcomingIDs
        #expect(Set(after) == Set(before + ["v", "w", "x", "y", "z"]))
        #expect(after.first == before.first)
        #expect(after.filter { before.contains($0) } == before)
    }

    @Test("Shuffle and start turns shuffle on, starts on a track of the page and mixes in the rest")
    func playShuffled() async {
        let h = ModesHarness()
        let page = h.page(letters)
        h.service.playShuffled(page)
        await h.settle()

        #expect(h.service.isShuffleOn)
        #expect(h.sink.saved.last?.shuffle == true)
        #expect(h.service.queue.isShuffled)
        let started = h.service.queue.current!.videoId
        #expect(letters.contains(started))
        #expect(h.loadedIDs == [started])
        #expect(Set(h.upcomingIDs) == Set(letters.filter { $0 != started }))
        #expect(h.service.queue.hasPrevious == false)
        #expect(h.service.queue.source == .page(browseId: "VLPL1"))
    }

    @Test("Shuffle and start picks the first track from the seed, so it can be replayed")
    func playShuffledSeeded() async {
        let first = ModesHarness(seed: 5)
        let second = ModesHarness(seed: 5)
        first.service.playShuffled(first.page(letters))
        second.service.playShuffled(second.page(letters))
        await first.settle()
        await second.settle()
        #expect(first.queuedIDs == second.queuedIDs)
    }

    @Test("Shuffle and start on an empty page does nothing")
    func playShuffledEmpty() async {
        let h = ModesHarness()
        h.service.playShuffled(h.page([]))
        await h.settle()
        #expect(h.service.isShuffleOn == false)
        #expect(h.service.queue.isEmpty)
        #expect(h.player.nowPlaying == nil)
        #expect(h.sink.saved.isEmpty)
    }

    @Test("shuffle stays on for the next queue and applies to it")
    func shuffleSurvivesNewQueue() async {
        let h = ModesHarness()
        await h.startRadio(["a", "b"])
        h.service.setShuffle(true)
        await h.backend.setRadio(seed: "z", tracks: MusicSamples.tracks("z", "y", "x", "w"))
        h.service.play(MusicSamples.track("z"))
        await h.settle()
        #expect(h.service.isShuffleOn)
        #expect(h.service.queue.isShuffled)
        #expect(Set(h.queuedIDs) == ["z", "y", "x", "w"])
    }

    @Test("turning shuffle on with nothing queued only remembers the choice")
    func shuffleWithNothingQueued() {
        let h = ModesHarness()
        h.service.setShuffle(true)
        #expect(h.service.isShuffleOn)
        #expect(h.service.queue.isEmpty)
        #expect(h.sink.saved == [MusicPlaybackPreferences(shuffle: true, loop: .off, autoplay: true)])
    }

    @Test("shuffling does not restart or interrupt the playing track")
    func shuffleKeepsPlaying() async {
        let h = ModesHarness()
        await h.startRadio(letters)
        h.service.setShuffle(true)
        h.service.setShuffle(false)
        #expect(h.loadedIDs == ["a"])
        #expect(h.player.nowPlaying?.videoId == "a")
    }

    // MARK: Long playlists

    @Test("a shuffled playlist loads every page at once, so the whole playlist is mixed and not three songs of each page")
    func shuffledPlaylistLoadsEverything() async {
        let h = ModesHarness(preferences: MusicPlaybackPreferences(shuffle: true))
        let first = await h.longPlaylist(pages: 4, size: 10)
        await h.startPage(first, continuation: "t1")

        #expect(await h.backend.moreTracksCalls.map(\.continuation) == ["t1", "t2", "t3"])
        #expect(h.queuedIDs.count == 40)
        #expect(h.service.queue.continuation == nil)
        #expect(h.service.queue.current?.videoId == first[0])
        // Songs of the later pages are among the next ones to play, not all at the end.
        #expect(h.upcomingIDs.prefix(10).contains { !$0.hasPrefix("p0_") })
    }

    @Test("with shuffle off a playlist still loads its next page only when three songs are left")
    func unshuffledPagesWait() async {
        let h = ModesHarness()
        let first = await h.longPlaylist(pages: 3, size: 10)
        await h.startPage(first, continuation: "t1")
        #expect(await h.backend.moreTracksCalls.isEmpty)
        #expect(h.queuedIDs == first)
    }

    @Test("turning shuffle on in the middle of a playlist loads the rest and mixes it in, and turning it off restores the order")
    func shuffleOnLoadsTheRest() async {
        let h = ModesHarness()
        let first = await h.longPlaylist(pages: 4, size: 10)
        await h.startPage(first, continuation: "t1")
        #expect(await h.backend.moreTracksCalls.isEmpty)

        h.service.setShuffle(true)
        await h.settle()

        #expect(await h.backend.moreTracksCalls.map(\.continuation) == ["t1", "t2", "t3"])
        #expect(h.queuedIDs.count == 40)
        #expect(h.service.queue.current?.videoId == first[0])
        #expect(h.upcomingIDs.prefix(10).contains { !$0.hasPrefix("p0_") })

        h.service.setShuffle(false)
        #expect(h.queuedIDs == first + h.songs("p1_", 10) + h.songs("p2_", 10) + h.songs("p3_", 10))
    }

    @Test("Shuffle and start on a long playlist loads the other pages and mixes them in")
    func playShuffledLoadsEverything() async {
        let h = ModesHarness()
        let first = await h.longPlaylist(pages: 3, size: 10)
        h.service.playShuffled(h.page(first, continuation: "t1"))
        await h.settle()

        #expect(await h.backend.moreTracksCalls.map(\.continuation) == ["t1", "t2"])
        #expect(h.queuedIDs.count == 30)
        #expect(h.service.queue.isShuffled)
        #expect(h.upcomingIDs.prefix(10).contains { !$0.hasPrefix("p0_") })
    }

    @Test("a shuffled playlist stops loading pages once it holds 2000 songs")
    func shuffledPlaylistCap() async {
        let h = ModesHarness(preferences: MusicPlaybackPreferences(shuffle: true))
        let first = await h.longPlaylist(pages: 6, size: 600)
        await h.startPage(first, continuation: "t1")

        // 600, 1200, 1800 and 2400: the fourth page takes it over the cap, so the fifth is not asked for.
        #expect(await h.backend.moreTracksCalls.map(\.continuation) == ["t1", "t2", "t3"])
        #expect(h.queuedIDs.count == 2400)
        #expect(h.service.queue.continuation == "t4")
    }

    @Test("a shuffled radio still loads its next page only when three songs are left")
    func shuffledRadioWaits() async {
        let h = ModesHarness(preferences: MusicPlaybackPreferences(shuffle: true))
        await h.backend.setMoreRadio(seed: "a", continuation: "m1", tracks: MusicSamples.tracks("x"))
        await h.startRadio(letters, continuation: "m1")
        #expect(await h.backend.moreRadioCalls.isEmpty)
        #expect(h.queuedIDs.count == letters.count)
    }
}

// MARK: - Loop song

@MainActor
@Suite("MusicService loop song")
struct MusicServiceLoopSongTests {
    @Test("a track that ends plays again from the start instead of moving on")
    func replays() async {
        let h = ModesHarness()
        await h.startRadio(["a", "b", "c"])
        h.service.setLoopMode(.song)

        await h.finishTrack()
        await h.finishTrack()

        #expect(h.loadedIDs == ["a", "a", "a"])
        #expect(h.engine.loads.allSatisfy { $0.startAt == 0 })
        #expect(h.service.queue.current?.videoId == "a")
        #expect(h.queuedIDs == ["a", "b", "c"])
    }

    @Test("each replay is a fresh playback with its own history session and CPN")
    func replayIsAFreshSession() async {
        let h = ModesHarness()
        await h.backend.setStream(MusicSamples.stream(
            videoId: "a",
            trackingURL: URL(string: "https://music.example.test/stats/playback?ev=a")!
        ))
        await h.startRadio(["a"])
        h.service.setLoopMode(.song)
        listen(h, seconds: 31)
        await h.service.reportTask?.value

        await h.finishTrack()
        listen(h, seconds: 31)
        await h.service.reportTask?.value

        let reports = await h.backend.reportAttempts
        #expect(reports.count == 2)
        #expect(Set(reports.map(\.cpn)).count == 2)
        #expect(await h.backend.resolvedIDs == ["a", "a"])
    }

    @Test("next still moves on, previous still goes back, and Loop song stays on")
    func manualMovesStillWork() async {
        let h = ModesHarness()
        await h.startRadio(["a", "b", "c"])
        h.service.setLoopMode(.song)

        h.service.next()
        await h.settle()
        h.engine.emit(.playingChanged(true))
        #expect(h.service.queue.current?.videoId == "b")
        #expect(h.service.loopMode == .song)

        await h.finishTrack()
        #expect(h.loadedIDs == ["a", "b", "b"])

        h.service.previous()
        await h.settle()
        #expect(h.service.queue.current?.videoId == "a")
        #expect(h.service.loopMode == .song)
    }

    @Test("the same track is prefetched near its end, so the replay does not wait for a resolve")
    func prefetchesTheSameTrack() async {
        let h = ModesHarness()
        await h.startRadio(["a", "b"])
        h.service.setLoopMode(.song)
        h.engine.tick(186, playing: true)
        await h.service.prefetchTask?.value
        #expect(await h.backend.resolvedIDs == ["a", "a"])

        await h.finishTrack()

        #expect(await h.backend.resolvedIDs == ["a", "a"])
        #expect(h.loadedIDs == ["a", "a"])
    }

    @Test("the last track of a page keeps repeating while the radio waits behind it for Next")
    func lastTrackRepeats() async {
        let h = ModesHarness(preferences: MusicPlaybackPreferences(loop: .song))
        await h.backend.setRadio(seed: "b", tracks: MusicSamples.tracks("b", "r1"))
        await h.startPage(["a", "b"], tap: "b")
        await h.finishTrack()
        await h.finishTrack()
        #expect(h.loadedIDs == ["b", "b", "b"])
        #expect(await h.backend.radioSeeds == ["b"])
        #expect(h.queuedIDs == ["a", "b", "r1"])
    }

    @Test("a Next parked behind the radio survives the track ending: the radio's first track plays, the song is not repeated")
    func parkedNextSurvivesTheEnd() async {
        let h = ModesHarness(preferences: MusicPlaybackPreferences(loop: .song))
        let gate = MusicTestGate()
        await h.backend.setRadioGate(seed: "b", gate)
        await h.backend.setRadio(seed: "b", tracks: MusicSamples.tracks("b", "r1", "r2"))
        h.service.play(MusicSamples.track("b"), in: h.page(["a", "b"]))
        await h.service.playTask?.value
        let held = await h.eventually { await h.backend.radioSeeds.count == 1 }
        #expect(held)
        h.engine.emit(.playingChanged(true))

        h.service.next()
        h.engine.emit(.ended)
        await gate.open()
        await h.settle()

        #expect(h.loadedIDs == ["b", "r1"])
        #expect(h.service.queue.current?.videoId == "r1")
    }

    @Test("a Next parked behind a radio that then fails ends playback instead of repeating the song")
    func parkedNextWithoutRadio() async {
        let h = ModesHarness(preferences: MusicPlaybackPreferences(loop: .song))
        let gate = MusicTestGate()
        await h.backend.setRadioGate(seed: "b", gate)
        await h.backend.setRadioError(seed: "b", URLError(.notConnectedToInternet))
        h.service.play(MusicSamples.track("b"), in: h.page(["a", "b"]))
        await h.service.playTask?.value
        let held = await h.eventually { await h.backend.radioSeeds.count == 1 }
        #expect(held)
        h.engine.emit(.playingChanged(true))

        h.service.next()
        h.engine.emit(.ended)
        await gate.open()
        await h.settle()

        #expect(h.loadedIDs == ["b"])
        #expect(h.player.nowPlaying == nil)
        #expect(h.service.queue.isEmpty)
    }

    @Test("with Loop song off a track that ends moves on again")
    func loopSongOff() async {
        let h = ModesHarness()
        await h.startRadio(["a", "b"])
        h.service.setLoopMode(.song)
        h.service.setLoopMode(.off)
        await h.finishTrack()
        #expect(h.loadedIDs == ["a", "b"])
    }

    private func listen(_ h: ModesHarness, seconds: TimeInterval) {
        h.engine.tick(0, playing: true)
        var position = 0.0
        for _ in 0..<Int(seconds / 0.5) {
            position += 0.5
            h.clock.advance(by: 0.5)
            h.engine.tick(position, playing: true)
        }
    }
}

// MARK: - Loop playlist

@MainActor
@Suite("MusicService loop playlist")
struct MusicServiceLoopPlaylistTests {
    @Test("the last track of a page ending starts the page over from its first track")
    func wrapsAtPageEnd() async {
        let h = ModesHarness(preferences: MusicPlaybackPreferences(loop: .playlist))
        await h.startPage(["a", "b", "c"])
        await h.finishTrack()
        await h.finishTrack()
        await h.finishTrack()

        #expect(h.loadedIDs == ["a", "b", "c", "a"])
        #expect(h.service.queue.current?.videoId == "a")
        #expect(h.queuedIDs == ["a", "b", "c"])
        #expect(await h.backend.radioSeeds.isEmpty)
    }

    @Test("it wraps to the first track of the page, not to the row that was tapped")
    func wrapsToFirstRow() async {
        let h = ModesHarness(preferences: MusicPlaybackPreferences(loop: .playlist))
        await h.startPage(["a", "b", "c"], tap: "c")
        await h.finishTrack()
        #expect(h.loadedIDs == ["c", "a"])
    }

    @Test("next on the last track wraps too")
    func nextWraps() async {
        let h = ModesHarness(preferences: MusicPlaybackPreferences(loop: .playlist))
        await h.startPage(["a", "b"], tap: "b")
        h.service.next()
        await h.settle()
        #expect(h.loadedIDs == ["b", "a"])
        #expect(h.player.nowPlaying?.videoId == "a")
    }

    @Test("Next stays on at the last track so the button can wrap, and only Loop playlist does that")
    func nextButtonStaysOn() async {
        let looping = ModesHarness(preferences: MusicPlaybackPreferences(loop: .playlist))
        await looping.startPage(["a", "b"], tap: "b")
        #expect(looping.service.canGoNext)

        let plain = ModesHarness(preferences: MusicPlaybackPreferences(autoplay: false))
        await plain.startPage(["a", "b"], tap: "b")
        #expect(plain.service.canGoNext == false)

        let empty = ModesHarness(preferences: MusicPlaybackPreferences(loop: .playlist))
        #expect(empty.service.canGoNext == false)
    }

    @Test("Loop playlist wins over Autoplay: no radio is fetched at the end of a page")
    func winsOverAutoplay() async {
        let h = ModesHarness(preferences: MusicPlaybackPreferences(loop: .playlist, autoplay: true))
        await h.startPage(["a", "b"], tap: "b")
        await h.finishTrack()
        #expect(await h.backend.radioSeeds.isEmpty)
        #expect(await h.backend.moreRadioCalls.isEmpty)
        #expect(h.loadedIDs == ["b", "a"])
    }

    @Test("a radio queue that really runs out wraps to its first track")
    func radioRunsOut() async {
        let h = ModesHarness(preferences: MusicPlaybackPreferences(loop: .playlist))
        let gate = MusicTestGate()
        await h.backend.setMoreRadioGate(seed: "a", continuation: "c1", gate)
        await h.backend.setMoreRadio(seed: "a", continuation: "c1", tracks: [])
        await h.backend.setRadio(seed: "a", tracks: MusicSamples.tracks("a", "b"), continuation: "c1")
        h.service.play(MusicSamples.track("a"))
        await h.service.playTask?.value
        let held = await h.eventually { await h.backend.moreRadioCalls.count == 1 }
        #expect(held)
        h.engine.emit(.playingChanged(true))
        h.service.next()
        await h.service.playTask?.value
        #expect(h.service.queue.current?.videoId == "b")

        h.engine.emit(.ended)
        #expect(h.service.queue.current?.videoId == "b")
        await gate.open()
        await h.settle()

        #expect(h.loadedIDs == ["a", "b", "a"])
        #expect(h.service.queue.current?.videoId == "a")
    }

    @Test("a radio queue that still has pages to load plays on instead of wrapping")
    func radioWithMorePagesDoesNotWrap() async {
        let h = ModesHarness(preferences: MusicPlaybackPreferences(loop: .playlist))
        await h.backend.setMoreRadio(seed: "a", continuation: "c1", tracks: MusicSamples.tracks("c", "d"))
        await h.startRadio(["a", "b"], continuation: "c1")
        h.service.next()
        await h.settle()
        h.engine.emit(.playingChanged(true))
        await h.finishTrack()
        #expect(h.service.queue.current?.videoId == "c")
        #expect(h.loadedIDs == ["a", "b", "c"])
    }

    @Test("a single track wraps onto itself")
    func singleTrack() async {
        let h = ModesHarness(preferences: MusicPlaybackPreferences(loop: .playlist))
        await h.startRadio(["a"])
        await h.finishTrack()
        #expect(h.loadedIDs == ["a", "a"])
    }

    @Test("with shuffle on every lap is a new mix of the same songs, and it does not open on the song that just played")
    func wrapsShuffled() async {
        let h = ModesHarness(preferences: MusicPlaybackPreferences(shuffle: true, loop: .playlist))
        await h.startPage(letters)
        let lap = h.queuedIDs
        for _ in 0..<(letters.count - 1) {
            await h.finishTrack()
        }
        #expect(h.service.queue.current?.videoId == lap.last)
        await h.finishTrack()

        #expect(h.loadedIDs.count == letters.count + 1)
        #expect(Set(h.queuedIDs) == Set(letters))
        #expect(h.queuedIDs != lap)
        #expect(h.service.queue.current?.videoId == h.queuedIDs.first)
        #expect(h.service.queue.current?.videoId != lap.last)
        #expect(h.service.queue.isShuffled)
    }

    @Test("the second lap plays in its own new order, and turning shuffle off afterwards restores the playlist order")
    func secondLapFollowsTheNewMix() async {
        let h = ModesHarness(preferences: MusicPlaybackPreferences(shuffle: true, loop: .playlist))
        await h.startPage(letters)
        for _ in 0..<letters.count {
            await h.finishTrack()
        }
        let secondLap = h.queuedIDs
        for _ in 0..<(letters.count - 1) {
            await h.finishTrack()
        }

        #expect(Array(h.loadedIDs.suffix(letters.count)) == secondLap)
        #expect(Array(h.loadedIDs.prefix(letters.count)) != secondLap)

        h.service.setShuffle(false)
        #expect(h.queuedIDs == letters)
        #expect(h.service.queue.current?.videoId == secondLap.last)
    }

    @Test("with shuffle off the loop plays the same order every lap")
    func unshuffledLapsRepeat() async {
        let h = ModesHarness(preferences: MusicPlaybackPreferences(loop: .playlist))
        await h.startPage(["a", "b", "c"])
        for _ in 0..<5 { await h.finishTrack() }
        #expect(h.loadedIDs == ["a", "b", "c", "a", "b", "c"])
        #expect(h.queuedIDs == ["a", "b", "c"])
    }

    @Test("a last track that cannot be played wraps to the first track instead of ending the loop")
    func unplayableLastTrackWraps() async {
        let h = ModesHarness(preferences: MusicPlaybackPreferences(loop: .playlist))
        await h.backend.setResolveError("c", MusicError.unplayable("Private"))
        await h.startPage(["a", "b", "c"], tap: "b")
        h.service.next()
        await h.settle()

        #expect(await h.backend.resolvedIDs == ["b", "c", "a"])
        #expect(h.service.queue.current?.videoId == "a")
        #expect(h.player.nowPlaying?.videoId == "a")
        #expect(h.queuedIDs == ["a", "b", "c"])
    }

    @Test("a last track that cannot be played wraps when it ends a lap by itself too")
    func unplayableLastTrackAtLapEnd() async {
        let h = ModesHarness(preferences: MusicPlaybackPreferences(loop: .playlist))
        await h.backend.setResolveError("c", MusicError.unplayable("Private"))
        await h.startPage(["a", "b", "c"])
        await h.finishTrack()
        await h.finishTrack()
        #expect(await h.backend.resolvedIDs == ["a", "b", "c", "a"])
        #expect(h.service.queue.current?.videoId == "a")
    }

    @Test("a playlist of nothing but unplayable songs gives up after three failures in a row")
    func allUnplayableStops() async {
        let h = ModesHarness(preferences: MusicPlaybackPreferences(loop: .playlist))
        for id in ["a", "b", "c"] {
            await h.backend.setResolveError(id, MusicError.unplayable("Private"))
        }
        await h.startPage(["a", "b", "c"])
        await h.settle()

        #expect(await h.backend.resolvedIDs == ["a", "b", "c"])
        #expect(h.player.nowPlaying == nil)
        // The queue stays so Next still works.
        #expect(h.queuedIDs == ["a", "b", "c"])
    }

    @Test("a single unplayable song looping onto itself gives up after three failures in a row")
    func singleUnplayableStops() async {
        let h = ModesHarness(preferences: MusicPlaybackPreferences(loop: .playlist))
        await h.backend.setResolveError("a", MusicError.unplayable("Private"))
        await h.startPage(["a"])
        await h.settle()
        #expect(await h.backend.resolvedIDs == ["a", "a", "a"])
        #expect(h.player.nowPlaying == nil)
    }

    @Test("without Loop playlist an unplayable last track still ends the queue")
    func unplayableLastTrackWithoutLoop() async {
        let h = ModesHarness(preferences: MusicPlaybackPreferences(autoplay: false))
        await h.backend.setResolveError("c", MusicError.unplayable("Private"))
        await h.startPage(["a", "b", "c"], tap: "b")
        h.service.next()
        await h.settle()
        #expect(await h.backend.resolvedIDs == ["b", "c"])
        #expect(h.service.queue.isEmpty)
    }

    @Test("with Loop playlist off the page ends as before")
    func off() async {
        let h = ModesHarness(preferences: MusicPlaybackPreferences(autoplay: false))
        await h.startPage(["a", "b"], tap: "b")
        h.engine.emit(.ended)
        await h.settle()
        #expect(h.loadedIDs == ["b"])
        #expect(h.player.hasEnded)
    }
}

// MARK: - Autoplay

@MainActor
@Suite("MusicService autoplay")
struct MusicServiceAutoplayTests {
    @Test("a page that reaches its last track fetches the radio of that track and appends it")
    func handsOverToRadio() async {
        let h = ModesHarness()
        await h.backend.setRadio(seed: "c", tracks: MusicSamples.tracks("c", "r1", "r2"))
        await h.startPage(["a", "b", "c"])
        #expect(await h.backend.radioSeeds.isEmpty)

        h.service.next()
        await h.settle()
        #expect(await h.backend.radioSeeds.isEmpty)
        h.service.next()
        await h.settle()

        #expect(await h.backend.radioSeeds == ["c"])
        #expect(h.queuedIDs == ["a", "b", "c", "r1", "r2"])
        #expect(h.service.queue.source == .radio(seedVideoId: "c"))
        #expect(h.service.queue.current?.videoId == "c")
    }

    @Test("tapping the last row of a page hands over at once")
    func tapLastRow() async {
        let h = ModesHarness()
        await h.backend.setRadio(seed: "c", tracks: MusicSamples.tracks("c", "r1"))
        await h.startPage(["a", "b", "c"], tap: "c")
        #expect(h.queuedIDs == ["a", "b", "c", "r1"])
    }

    @Test("a page with more tracks to load loads them first and only then hands over")
    func morePagesFirst() async {
        let h = ModesHarness()
        await h.backend.setMoreTracks(browseId: "VLPL1", continuation: "t1", tracks: MusicSamples.tracks("c", "d"))
        await h.backend.setRadio(seed: "d", tracks: MusicSamples.tracks("d", "r1"))
        await h.startPage(["a", "b"], continuation: "t1")
        #expect(h.queuedIDs == ["a", "b", "c", "d"])
        #expect(await h.backend.radioSeeds.isEmpty)

        for _ in 0..<3 { h.service.next() }
        await h.settle()

        #expect(await h.backend.radioSeeds == ["d"])
        #expect(h.queuedIDs == ["a", "b", "c", "d", "r1"])
    }

    @Test("the hand-over is gapless: the last track ending while the radio loads starts the radio's first track when it lands")
    func gapless() async {
        let h = ModesHarness()
        let gate = MusicTestGate()
        await h.backend.setRadioGate(seed: "b", gate)
        await h.backend.setRadio(seed: "b", tracks: MusicSamples.tracks("b", "r1", "r2"))
        h.service.play(MusicSamples.track("b"), in: h.page(["a", "b"]))
        await h.service.playTask?.value
        let held = await h.eventually { await h.backend.radioSeeds.count == 1 }
        #expect(held)
        h.engine.emit(.playingChanged(true))

        h.engine.emit(.ended)
        #expect(h.service.queue.current?.videoId == "b")
        #expect(h.player.hasEnded)
        await gate.open()
        await h.settle()

        #expect(h.loadedIDs == ["b", "r1"])
        #expect(h.service.queue.current?.videoId == "r1")
    }

    @Test("after the hand-over the radio keeps loading pages like a radio queue does")
    func radioKeepsPaging() async {
        let h = ModesHarness()
        await h.backend.setRadio(seed: "b", tracks: MusicSamples.tracks("b", "r1", "r2"), continuation: "m1")
        await h.backend.setMoreRadio(seed: "b", continuation: "m1", tracks: MusicSamples.tracks("r3", "r4"))
        await h.startPage(["a", "b"], tap: "b")

        #expect(await h.backend.moreRadioCalls == [FakeMusicBackend.MoreRadioCall(seed: "b", continuation: "m1")])
        #expect(h.queuedIDs == ["a", "b", "r1", "r2", "r3", "r4"])
        #expect(h.service.queue.continuation == nil)
    }

    @Test("the hand-over asks for the radio once however many tracks follow")
    func onlyOnce() async {
        let h = ModesHarness()
        await h.backend.setRadio(seed: "b", tracks: MusicSamples.tracks("b", "r1", "r2"))
        await h.startPage(["a", "b"], tap: "b")
        await h.finishTrack()
        await h.finishTrack()
        await h.finishTrack()
        #expect(await h.backend.radioSeeds == ["b"])
        #expect(h.loadedIDs == ["b", "r1", "r2"])
    }

    @Test("with Autoplay off the page ends as before and nothing is fetched")
    func off() async {
        let h = ModesHarness(preferences: MusicPlaybackPreferences(autoplay: false))
        await h.startPage(["a", "b"], tap: "b")
        h.engine.emit(.ended)
        await h.settle()

        #expect(h.loadedIDs == ["b"])
        #expect(h.player.hasEnded)
        #expect(await h.backend.radioSeeds.isEmpty)
        #expect(await h.backend.moreRadioCalls.isEmpty)
        #expect(await h.backend.moreTracksCalls.isEmpty)
    }

    @Test("with Autoplay off Next on the last track of a page stops playback")
    func offNext() async {
        let h = ModesHarness(preferences: MusicPlaybackPreferences(autoplay: false))
        await h.startPage(["a", "b"], tap: "b")
        h.service.next()
        #expect(h.player.nowPlaying == nil)
        #expect(h.service.queue.isEmpty)
        #expect(await h.backend.radioSeeds.isEmpty)
    }

    @Test("with Autoplay off a radio queue keeps the page it loaded and fetches no more")
    func offRadioQueue() async {
        let h = ModesHarness(preferences: MusicPlaybackPreferences(autoplay: false))
        await h.backend.setMoreRadio(seed: "a", continuation: "c1", tracks: MusicSamples.tracks("x", "y"))
        await h.startRadio(["a", "b", "c"], continuation: "c1")
        #expect(h.queuedIDs == ["a", "b", "c"])
        #expect(await h.backend.moreRadioCalls.isEmpty)

        h.service.next()
        await h.settle()
        h.service.next()
        await h.settle()
        h.engine.emit(.ended)
        await h.settle()

        #expect(await h.backend.moreRadioCalls.isEmpty)
        #expect(h.loadedIDs == ["a", "b", "c"])
        #expect(h.player.hasEnded)
        #expect(h.service.queue.continuation == "c1")
    }

    @Test("with Autoplay off a playlist still loads its own later pages")
    func offStillPagesThePlaylist() async {
        let h = ModesHarness(preferences: MusicPlaybackPreferences(autoplay: false))
        await h.backend.setMoreTracks(browseId: "VLPL1", continuation: "t1", tracks: MusicSamples.tracks("c", "d"))
        await h.startPage(["a", "b"], continuation: "t1")
        #expect(h.queuedIDs == ["a", "b", "c", "d"])
    }

    @Test("turning Autoplay on while the last track of a page plays hands over then")
    func turnedOnAtTheEnd() async {
        let h = ModesHarness(preferences: MusicPlaybackPreferences(autoplay: false))
        await h.backend.setRadio(seed: "b", tracks: MusicSamples.tracks("b", "r1"))
        await h.startPage(["a", "b"], tap: "b")
        #expect(await h.backend.radioSeeds.isEmpty)

        h.service.setAutoplay(true)
        await h.settle()

        #expect(await h.backend.radioSeeds == ["b"])
        #expect(h.queuedIDs == ["a", "b", "r1"])
    }

    @Test("turning Autoplay on lets a radio queue that was held back load its next page")
    func turnedOnRadio() async {
        let h = ModesHarness(preferences: MusicPlaybackPreferences(autoplay: false))
        await h.backend.setMoreRadio(seed: "a", continuation: "c1", tracks: MusicSamples.tracks("x", "y"))
        await h.startRadio(["a", "b"], continuation: "c1")
        #expect(await h.backend.moreRadioCalls.isEmpty)

        h.service.setAutoplay(true)
        await h.settle()

        #expect(h.queuedIDs == ["a", "b", "x", "y"])
    }

    @Test("turning Loop off at the end of a page hands over to the radio")
    func loopTurnedOffAtTheEnd() async {
        let h = ModesHarness(preferences: MusicPlaybackPreferences(loop: .playlist))
        await h.backend.setRadio(seed: "b", tracks: MusicSamples.tracks("b", "r1"))
        await h.startPage(["a", "b"], tap: "b")
        #expect(await h.backend.radioSeeds.isEmpty)

        h.service.setLoopMode(.song)
        h.service.setLoopMode(.off)
        await h.settle()

        #expect(await h.backend.radioSeeds == ["b"])
        #expect(h.queuedIDs == ["a", "b", "r1"])
    }

    @Test("Loop song still hands over: only Loop playlist keeps Autoplay from the radio")
    func loopSongStillHandsOver() async {
        let h = ModesHarness(preferences: MusicPlaybackPreferences(loop: .song))
        await h.backend.setRadio(seed: "b", tracks: MusicSamples.tracks("b", "r1", "r2"))
        await h.startPage(["a", "b"], tap: "b")
        #expect(await h.backend.radioSeeds == ["b"])
        #expect(h.queuedIDs == ["a", "b", "r1", "r2"])
        #expect(h.service.queue.source == .radio(seedVideoId: "b"))
    }

    @Test("Loop song with Autoplay off fetches no radio")
    func loopSongAutoplayOff() async {
        let h = ModesHarness(preferences: MusicPlaybackPreferences(loop: .song, autoplay: false))
        await h.startPage(["a", "b"], tap: "b")
        #expect(await h.backend.radioSeeds.isEmpty)
        #expect(h.queuedIDs == ["a", "b"])
    }

    @Test("Loop song plus Next on the last track of a page plays the radio's first track")
    func loopSongNext() async {
        let h = ModesHarness(preferences: MusicPlaybackPreferences(loop: .song))
        await h.backend.setRadio(seed: "b", tracks: MusicSamples.tracks("b", "r1", "r2"))
        await h.startPage(["a", "b"], tap: "b")
        #expect(h.service.canGoNext)

        h.service.next()
        await h.settle()

        #expect(h.loadedIDs == ["b", "r1"])
        #expect(h.service.queue.current?.videoId == "r1")
        #expect(h.service.loopMode == .song)
    }

    @Test("Loop off plus Autoplay on plus Next on the last track of a page goes to the radio, waiting for it if it is still loading")
    func loopOffNextWaitsForTheRadio() async {
        let h = ModesHarness()
        let gate = MusicTestGate()
        await h.backend.setRadioGate(seed: "b", gate)
        await h.backend.setRadio(seed: "b", tracks: MusicSamples.tracks("b", "r1"))
        h.service.play(MusicSamples.track("b"), in: h.page(["a", "b"]))
        await h.service.playTask?.value
        let held = await h.eventually { await h.backend.radioSeeds.count == 1 }
        #expect(held)
        h.engine.emit(.playingChanged(true))
        #expect(h.service.canGoNext)

        h.service.next()
        #expect(h.service.queue.current?.videoId == "b")
        await gate.open()
        await h.settle()

        #expect(h.loadedIDs == ["b", "r1"])
        #expect(h.service.queue.current?.videoId == "r1")
    }

    @Test("Next is on at the last track of a page when Autoplay can hand over, and off when it cannot")
    func nextButtonAtThePageEnd() async {
        for loop in [MusicLoopMode.off, .song, .playlist] {
            let on = ModesHarness(preferences: MusicPlaybackPreferences(loop: loop, autoplay: true))
            // The radio is held back, so the page is still the queue when Next is asked about.
            let gate = MusicTestGate()
            await on.backend.setRadioGate(seed: "b", gate)
            await on.backend.setRadio(seed: "b", tracks: MusicSamples.tracks("b", "r1"))
            on.service.play(MusicSamples.track("b"), in: on.page(["a", "b"]))
            await on.service.playTask?.value
            if loop != .playlist {
                // Loop playlist never hands over: the lap wraps instead, so there is no radio to wait for.
                let held = await on.eventually { await on.backend.radioSeeds.count == 1 }
                #expect(held, "autoplay on, loop \(loop)")
            }
            #expect(on.service.queue.hasNext == false)
            #expect(on.service.canGoNext, "autoplay on, loop \(loop)")
            await gate.open()
            await on.settle()
        }
        for loop in [MusicLoopMode.off, .song] {
            let off = ModesHarness(preferences: MusicPlaybackPreferences(loop: loop, autoplay: false))
            await off.startPage(["a", "b"], tap: "b")
            #expect(off.service.canGoNext == false, "autoplay off, loop \(loop)")
        }
    }

    @Test("Next is on at the last loaded track of a page that still has pages to load, and off on a radio that has run out")
    func nextButtonOtherQueues() async {
        let more = ModesHarness()
        let gate = MusicTestGate()
        await more.backend.setMoreTracksGate(browseId: "VLPL1", continuation: "t1", gate)
        more.service.play(MusicSamples.track("b"), in: more.page(["a", "b"], continuation: "t1"))
        await more.service.playTask?.value
        #expect(more.service.canGoNext)
        await gate.open()
        await more.settle()

        let radio = ModesHarness()
        await radio.startRadio(["a", "b"])
        radio.service.next()
        await radio.settle()
        #expect(radio.service.queue.hasNext == false)
        #expect(radio.service.canGoNext == false)

        let empty = ModesHarness()
        #expect(empty.service.canGoNext == false)
    }

    @Test("a radio that cannot be fetched leaves the page ended, silently")
    func handOverFails() async {
        let h = ModesHarness()
        await h.backend.setRadioError(seed: "b", URLError(.notConnectedToInternet))
        await h.startPage(["a", "b"], tap: "b")
        h.engine.emit(.ended)
        await h.settle()

        #expect(h.service.lastError == nil)
        #expect(h.queuedIDs == ["a", "b"])
        #expect(h.player.hasEnded)
        #expect(h.loadedIDs == ["b"])
    }

    @Test("a hand-over that failed keeps the page as it was, so Next tries the radio again and plays it")
    func failedHandOverRetriesOnNext() async {
        let h = ModesHarness()
        await h.backend.setRadioError(seed: "b", URLError(.notConnectedToInternet))
        await h.startPage(["a", "b"], tap: "b")
        #expect(h.service.queue.source == .page(browseId: "VLPL1"))
        #expect(await h.backend.radioSeeds == ["b"])

        await h.backend.setRadioError(seed: "b", nil)
        await h.backend.setRadio(seed: "b", tracks: MusicSamples.tracks("b", "r1", "r2"))
        #expect(h.service.canGoNext)
        h.service.next()
        await h.settle()

        #expect(await h.backend.radioSeeds == ["b", "b"])
        #expect(h.loadedIDs == ["b", "r1"])
        #expect(h.queuedIDs == ["a", "b", "r1", "r2"])
        #expect(h.service.queue.source == .radio(seedVideoId: "b"))
    }

    @Test("a hand-over that failed is tried again when the track ends")
    func failedHandOverRetriesOnEnd() async {
        let h = ModesHarness()
        await h.backend.setRadioError(seed: "b", URLError(.timedOut))
        await h.startPage(["a", "b"], tap: "b")

        await h.backend.setRadioError(seed: "b", nil)
        await h.backend.setRadio(seed: "b", tracks: MusicSamples.tracks("b", "r1"))
        await h.finishTrack()

        #expect(h.loadedIDs == ["b", "r1"])
    }

    @Test("a hand-over that failed is tried again when Autoplay is switched off and on")
    func failedHandOverRetriesOnToggle() async {
        let h = ModesHarness()
        await h.backend.setRadioError(seed: "b", URLError(.networkConnectionLost))
        await h.startPage(["a", "b"], tap: "b")

        await h.backend.setRadioError(seed: "b", nil)
        await h.backend.setRadio(seed: "b", tracks: MusicSamples.tracks("b", "r1"))
        h.service.setAutoplay(false)
        h.service.setAutoplay(true)
        await h.settle()

        #expect(h.queuedIDs == ["a", "b", "r1"])
    }

    @Test("a radio the server rejects is not asked for again")
    func rejectedHandOverIsNotRetried() async {
        let h = ModesHarness()
        await h.backend.setRadioError(seed: "b", MusicError.http(404))
        await h.startPage(["a", "b"], tap: "b")
        await h.finishTrack()
        h.service.setAutoplay(false)
        h.service.setAutoplay(true)
        await h.settle()
        #expect(await h.backend.radioSeeds == ["b"])
        #expect(h.queuedIDs == ["a", "b"])
    }

    @Test("a hand-over that fails over and over only asks again on the listener's own actions")
    func failedHandOverDoesNotLoop() async {
        let h = ModesHarness()
        await h.backend.setRadioError(seed: "b", URLError(.notConnectedToInternet))
        await h.startPage(["a", "b"], tap: "b")
        await h.settle()
        #expect(await h.backend.radioSeeds == ["b"])
    }

    // MARK: A page that stops paging hands over too

    @Test("a page whose next page the server rejects hands over to the radio from its last loaded track")
    func rejectedContinuationHandsOver() async {
        let h = ModesHarness()
        await h.backend.setMoreTracksError(browseId: "VLPL1", continuation: "t1", MusicError.http(404))
        await h.backend.setRadio(seed: "b", tracks: MusicSamples.tracks("b", "r1", "r2"))
        await h.startPage(["a", "b"], tap: "b", continuation: "t1")

        #expect(await h.backend.radioSeeds == ["b"])
        #expect(h.queuedIDs == ["a", "b", "r1", "r2"])
        #expect(h.service.queue.continuation == nil)
    }

    @Test("a track that ends while the next page is loading plays the radio's first track when that page turns out unreadable")
    func parkedEndHandsOverAfterAFailedPage() async {
        let h = ModesHarness()
        let gate = MusicTestGate()
        await h.backend.setMoreTracksGate(browseId: "VLPL1", continuation: "t1", gate)
        await h.backend.setMoreTracksError(browseId: "VLPL1", continuation: "t1", MusicError.parse("bad page"))
        await h.backend.setRadio(seed: "b", tracks: MusicSamples.tracks("b", "r1"))
        h.service.play(MusicSamples.track("b"), in: h.page(["a", "b"], continuation: "t1"))
        await h.service.playTask?.value
        let held = await h.eventually { await h.backend.moreTracksCalls.count == 1 }
        #expect(held)
        h.engine.emit(.playingChanged(true))

        h.engine.emit(.ended)
        #expect(h.service.queue.current?.videoId == "b")
        await gate.open()
        await h.settle()

        #expect(await h.backend.radioSeeds == ["b"])
        #expect(h.loadedIDs == ["b", "r1"])
        #expect(h.service.queue.current?.videoId == "r1")
    }

    @Test("with Autoplay off a page whose next page fails simply ends")
    func rejectedContinuationAutoplayOff() async {
        let h = ModesHarness(preferences: MusicPlaybackPreferences(autoplay: false))
        await h.backend.setMoreTracksError(browseId: "VLPL1", continuation: "t1", MusicError.http(404))
        await h.startPage(["a", "b"], tap: "b", continuation: "t1")
        h.engine.emit(.ended)
        await h.settle()

        #expect(await h.backend.radioSeeds.isEmpty)
        #expect(h.player.hasEnded)
        #expect(h.queuedIDs == ["a", "b"])
    }

    @Test("a track that ends while the next page is loading still ends there when the page fails and no radio follows")
    func parkedEndSettlesWithoutRadio() async {
        let h = ModesHarness(preferences: MusicPlaybackPreferences(autoplay: false))
        let gate = MusicTestGate()
        await h.backend.setMoreTracksGate(browseId: "VLPL1", continuation: "t1", gate)
        await h.backend.setMoreTracksError(browseId: "VLPL1", continuation: "t1", MusicError.http(404))
        h.service.play(MusicSamples.track("b"), in: h.page(["a", "b"], continuation: "t1"))
        await h.service.playTask?.value
        let held = await h.eventually { await h.backend.moreTracksCalls.count == 1 }
        #expect(held)
        h.engine.emit(.playingChanged(true))
        h.engine.emit(.ended)
        await gate.open()
        await h.settle()

        #expect(h.player.hasEnded)
        #expect(h.loadedIDs == ["b"])
    }

    @Test("a radio that adds nothing new leaves the page ended")
    func handOverAddsNothing() async {
        let h = ModesHarness()
        await h.backend.setRadio(seed: "b", tracks: MusicSamples.tracks("b", "a"))
        await h.startPage(["a", "b"], tap: "b")
        h.engine.emit(.ended)
        await h.settle()
        #expect(h.queuedIDs == ["a", "b"])
        #expect(h.loadedIDs == ["b"])
        #expect(h.player.hasEnded)
        #expect(await h.backend.radioSeeds == ["b"])
    }

    @Test("with shuffle on the radio is seeded with the last track of the shuffled order")
    func shuffledHandOver() async {
        let h = ModesHarness(preferences: MusicPlaybackPreferences(shuffle: true))
        await h.startPage(["a", "b", "c"], tap: "a")
        let last = h.queuedIDs.last!
        await h.backend.setRadio(seed: last, tracks: MusicSamples.tracks(last, "r1"))
        h.service.next()
        await h.settle()
        h.service.next()
        await h.settle()
        #expect(await h.backend.radioSeeds == [last])
        #expect(h.queuedIDs.last == "r1")
    }

    @Test("a radio queue that runs out of pages simply ends with Autoplay on")
    func radioQueueEnds() async {
        let h = ModesHarness()
        await h.startRadio(["a", "b"])
        h.service.next()
        await h.settle()
        h.engine.emit(.ended)
        await h.settle()
        #expect(h.player.hasEnded)
        #expect(await h.backend.radioSeeds == ["a"])
    }
}
