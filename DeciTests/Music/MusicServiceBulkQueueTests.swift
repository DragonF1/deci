// DeciTests/Music/MusicServiceBulkQueueTests.swift
// Play next, Add to queue and Remove from queue for several songs at once, through the service with a fake backend and a
// fake AVPlayer seam: the order the songs land in, what is skipped (the song in the player, a song listed twice, a song
// that cannot play offline), the one short line each call says, and the one top-up and session save.

import Foundation
import Testing
@testable import Deci

@MainActor
private struct BulkQueueHarness {
    let backend = FakeMusicBackend()
    let engine = FakePlaybackEngine()
    let surface = FakeNowPlayingSurface()
    let clock = MutableClock()
    let scheduler: ManualWriteScheduler
    let folder = SessionTestFolder()
    let store: MusicSessionStore
    let service: MusicService

    init(preferences: MusicPlaybackPreferences = MusicPlaybackPreferences()) {
        let clock = self.clock
        let scheduler = ManualWriteScheduler(clock: clock)
        self.scheduler = scheduler
        let store = MusicSessionStore(fileURL: folder.fileURL, now: { clock.now }, scheduler: scheduler)
        self.store = store
        service = MusicService(
            backend: backend,
            player: MusicPlayer(engine: engine),
            presentSignIn: { _ in },
            presentChannelPicker: { _, _ in },
            closeSignInWindow: {},
            raiseSignInWindow: {},
            nowPlaying: NowPlayingController(surface: surface, fetchArtwork: { _ in nil }),
            now: { clock.now },
            preferences: preferences,
            savePreferences: { _ in },
            shuffleSeed: 1,
            queueRetryDelay: .seconds(60),
            sessionStore: store,
            refreshOnCreate: false
        )
    }

    func cleanUp() {
        store.waitForWrites()
        folder.remove()
    }

    /// Signed in, and the account's key known, so a save has everything it needs.
    func signIn() async {
        await service.refreshAuth()
        await service.sessionKeyTask?.value
    }

    func settle() async {
        while true {
            let play = service.playTask
            let radio = service.radioTask
            await play?.value
            await radio?.value
            if service.playTask == play, service.radioTask == radio { break }
        }
    }

    func settleWrites() {
        scheduler.advance(by: 1)
        store.waitForWrites()
    }

    func song(_ id: String) -> Deci.MusicTrack { MusicSamples.track(id, title: "Song \(id)") }

    func songs(_ ids: String...) -> [Deci.MusicTrack] { ids.map { song($0) } }

    func startPage(_ ids: [String], tap: String? = nil) async {
        let page = MusicSamples.page("VLPL1", tracks: ids.map { song($0) })
        service.play(song(tap ?? ids[0]), in: page)
        await settle()
        engine.emit(.playingChanged(true))
    }

    /// Plays the first of `ids` with a radio of the rest behind it (see the queue edit tests for the Autoplay detail).
    func startRadio(_ ids: [String]) async {
        await backend.setRadio(seed: ids[0], tracks: ids.map { song($0) })
        let putBack = !service.isAutoplayOn
        if putBack { service.setAutoplay(true) }
        service.play(song(ids[0]))
        if putBack { service.setAutoplay(false) }
        await settle()
        engine.emit(.playingChanged(true))
    }

    func finishTrack() async {
        engine.emit(.ended)
        await settle()
        engine.emit(.playingChanged(true))
    }

    var listing: MusicQueueListing {
        MusicQueueListing(
            queue: service.queue,
            listsNextLap: service.listsNextLap,
            listsAutoplay: service.playsAutoplay,
            autoplayIsOn: service.isAutoplayOn
        )
    }

    var queuedIDs: [String] { service.queue.tracks.map(\.videoId) }
    var upNextIDs: [String] { listing.upcoming.map(\.videoId) }
    var loadedIDs: [String] { engine.loads.map(\.stream.videoId) }
    var notice: String? { service.trackActions.notice?.text }
}

@MainActor
@Suite("MusicService bulk queue edits")
struct MusicServiceBulkQueueTests {

    // MARK: - Play next

    @Test("Play next of several songs puts them right after the current one, in the order given, and says how many")
    func playNextOrder() async {
        let h = BulkQueueHarness()
        await h.startPage(["a", "b", "c", "d", "e"])
        h.service.playNext(h.songs("x", "y", "z"))

        #expect(h.queuedIDs == ["a", "x", "y", "z", "b", "c", "d", "e"])
        #expect(h.notice == "Playing 3 songs next")

        await h.finishTrack()
        await h.finishTrack()
        await h.finishTrack()
        #expect(h.loadedIDs == ["a", "x", "y", "z"])
    }

    @Test("Play next of songs that are already upcoming moves them, the queue never lists one twice")
    func playNextMovesQueuedSongs() async {
        let h = BulkQueueHarness()
        await h.startPage(["a", "b", "c", "d", "e"])
        h.service.playNext(h.songs("d", "b"))

        #expect(h.queuedIDs == ["a", "d", "b", "c", "e"])
        #expect(Set(h.upNextIDs).count == h.upNextIDs.count)
    }

    @Test("Play next skips the song that is playing and queues the rest")
    func playNextSkipsCurrent() async {
        let h = BulkQueueHarness()
        await h.startPage(["a", "b", "c", "d", "e"])
        h.service.playNext(h.songs("x", "a", "y"))

        #expect(h.queuedIDs == ["a", "x", "y", "b", "c", "d", "e"])
        #expect(h.notice == "Playing 2 songs next")
    }

    @Test("When the song that plays is skipped and one song is left, the line is the single one")
    func playNextOneLeft() async {
        let h = BulkQueueHarness()
        await h.startPage(["a", "b", "c"])
        h.service.playNext(h.songs("a", "x"))

        #expect(h.queuedIDs == ["a", "x", "b", "c"])
        #expect(h.notice == "Playing next")
    }

    @Test("Play next of only the song that plays changes nothing and says nothing")
    func playNextOnlyCurrent() async {
        let h = BulkQueueHarness()
        await h.startPage(["a", "b", "c"])
        h.service.playNext(h.songs("a"))
        h.service.playNext([])

        #expect(h.queuedIDs == ["a", "b", "c"])
        #expect(h.notice == nil)
    }

    @Test("A song listed twice is queued once")
    func playNextDuplicates() async {
        let h = BulkQueueHarness()
        await h.startPage(["a", "b", "c"])
        h.service.playNext(h.songs("x", "x", "y"))

        #expect(h.queuedIDs == ["a", "x", "y", "b", "c"])
        #expect(h.notice == "Playing 2 songs next")
    }

    @Test("Play next of one song behaves exactly as the single entry does")
    func playNextOneSong() async {
        let h = BulkQueueHarness()
        await h.startPage(["a", "b", "c"])
        h.service.playNext(h.songs("x"))

        #expect(h.queuedIDs == ["a", "x", "b", "c"])
        #expect(h.notice == "Playing next")
    }

    @Test("With nothing queued Play next starts the first song and queues the rest behind it, with Autoplay off")
    func playNextEmptyQueue() async {
        let h = BulkQueueHarness(preferences: MusicPlaybackPreferences(autoplay: false))
        h.service.playNext(h.songs("x", "y", "z"))
        await h.settle()

        #expect(h.service.queue.current?.videoId == "x")
        #expect(h.loadedIDs == ["x"])
        #expect(h.queuedIDs == ["x", "y", "z"])
        // Three songs were put: the first started and two wait behind it, and the line counts all three.
        #expect(h.notice == "Playing 3 songs")
    }

    @Test("With nothing queued Play next keeps the songs ahead of the radio that follows the first one")
    func playNextEmptyQueueWithRadio() async {
        let h = BulkQueueHarness()
        await h.backend.setRadio(seed: "x", tracks: MusicSamples.tracks("x", "r1", "r2", "r3"))
        h.service.playNext(h.songs("x", "y", "z"))
        await h.settle()

        #expect(h.service.queue.current?.videoId == "x")
        #expect(Array(h.queuedIDs.prefix(3)) == ["x", "y", "z"])
        #expect(h.loadedIDs == ["x"])
    }

    @Test("Play next in shuffle keeps the songs in the order given")
    func playNextWhileShuffled() async {
        let h = BulkQueueHarness(preferences: MusicPlaybackPreferences(shuffle: true))
        await h.startPage(["a", "b", "c", "d", "e"])
        h.service.playNext(h.songs("x", "y", "z"))

        #expect(Array(h.queuedIDs.prefix(4)) == ["a", "x", "y", "z"])
    }

    // MARK: - Add to queue

    @Test("Add to queue of several songs appends them in order after the playlist, before the radio, and says how many")
    func addToQueueOrderAfterPage() async {
        let h = BulkQueueHarness()
        await h.backend.setRadio(seed: "c", tracks: MusicSamples.tracks("c", "r1", "r2", "r3", "r4", "r5"))
        await h.startPage(["a", "b", "c"])
        h.service.addToQueue(h.songs("x", "y"))

        #expect(h.queuedIDs == ["a", "b", "c", "x", "y"])
        #expect(h.upNextIDs == ["b", "c", "x", "y", "r1", "r2", "r3", "r4", "r5"])
        #expect(h.notice == "Added 2 songs to queue")
    }

    @Test("On a radio Add to queue goes after the songs queued before, ahead of the radio's")
    func addToQueueOnRadio() async {
        let h = BulkQueueHarness()
        await h.startRadio(["a", "r1", "r2"])
        h.service.addToQueue(h.songs("x"))
        h.service.addToQueue(h.songs("y", "z"))

        #expect(Array(h.queuedIDs.prefix(4)) == ["a", "x", "y", "z"])
        #expect(h.queuedIDs.contains("r1"))
    }

    @Test("Add to queue skips the song that is playing and a song listed twice")
    func addToQueueSkips() async {
        let h = BulkQueueHarness()
        await h.startPage(["a", "b"])
        h.service.addToQueue(h.songs("a", "x", "x", "y"))

        #expect(h.queuedIDs == ["a", "b", "x", "y"])
        #expect(h.notice == "Added 2 songs to queue")
    }

    @Test("Add to queue of one song left over is the single line")
    func addToQueueOneLeft() async {
        let h = BulkQueueHarness()
        await h.startPage(["a", "b"])
        h.service.addToQueue(h.songs("a", "x"))

        #expect(h.queuedIDs == ["a", "b", "x"])
        #expect(h.notice == "Added to queue")
    }

    @Test("Add to queue of songs that are queued already moves them to the end in the order given")
    func addToQueueMovesQueued() async {
        let h = BulkQueueHarness()
        await h.startPage(["a", "b", "c", "d", "e"])
        h.service.addToQueue(h.songs("b", "c"))

        #expect(h.queuedIDs == ["a", "d", "e", "b", "c"])
    }

    @Test("With nothing queued Add to queue starts the first song and appends the rest in order")
    func addToQueueEmptyQueue() async {
        let h = BulkQueueHarness(preferences: MusicPlaybackPreferences(autoplay: false))
        h.service.addToQueue(h.songs("x", "y", "z"))
        await h.settle()

        #expect(h.service.queue.current?.videoId == "x")
        #expect(h.queuedIDs == ["x", "y", "z"])
        #expect(h.notice == "Added 3 songs to queue")
    }

    @Test("With nothing queued and two songs picked, Play next says both were put, and Add to queue says the same")
    func emptyQueueTwoSongs() async {
        let play = BulkQueueHarness(preferences: MusicPlaybackPreferences(autoplay: false))
        play.service.playNext(play.songs("x", "y"))
        await play.settle()
        #expect(play.queuedIDs == ["x", "y"])
        #expect(play.notice == "Playing 2 songs")

        let add = BulkQueueHarness(preferences: MusicPlaybackPreferences(autoplay: false))
        add.service.addToQueue(add.songs("x", "y"))
        await add.settle()
        #expect(add.queuedIDs == ["x", "y"])
        #expect(add.notice == "Added 2 songs to queue")
    }

    // MARK: - Remove from queue

    @Test("Remove from queue takes several songs out, says how many went, and Next skips them")
    func removeSeveral() async {
        let h = BulkQueueHarness()
        await h.startPage(["a", "b", "c", "d", "e"])
        h.service.removeFromQueue(h.songs("b", "d"))

        #expect(h.queuedIDs == ["a", "c", "e"])
        #expect(h.notice == "Removed 2 songs from queue")
        await h.finishTrack()
        await h.finishTrack()
        #expect(h.loadedIDs == ["a", "c", "e"])
    }

    @Test("Remove from queue counts only the songs that were there, never takes the one that plays")
    func removeCountsRemoved() async {
        let h = BulkQueueHarness()
        await h.startPage(["a", "b", "c", "d"])
        h.service.removeFromQueue(h.songs("a", "b", "zzz", "c"))

        #expect(h.queuedIDs == ["a", "d"])
        #expect(h.notice == "Removed 2 songs from queue")
    }

    @Test("Remove from queue with one song gone is the single line")
    func removeOneLeft() async {
        let h = BulkQueueHarness()
        await h.startPage(["a", "b", "c"])
        h.service.removeFromQueue(h.songs("zzz", "b"))

        #expect(h.queuedIDs == ["a", "c"])
        #expect(h.notice == "Removed from queue")
    }

    @Test("Remove from queue of songs that are not there says nothing and changes nothing")
    func removeNothing() async {
        let h = BulkQueueHarness()
        await h.startPage(["a", "b", "c"])
        h.service.removeFromQueue(h.songs("zzz", "yyy", "a"))
        h.service.removeFromQueue([])

        #expect(h.queuedIDs == ["a", "b", "c"])
        #expect(h.notice == nil)
    }

    @Test("Removing the staged radio's songs in one call tops the queue up once, never leaving Up next empty")
    func removeTopsUpOnce() async {
        let h = BulkQueueHarness()
        await h.backend.setRadio(seed: "b", tracks: MusicSamples.tracks("r1", "r2", "r3", "r4"))
        await h.backend.setRadio(seed: "a", tracks: MusicSamples.tracks("r1", "s1", "s2"))
        await h.startPage(["a", "b"])
        #expect(h.upNextIDs == ["b", "r1", "r2", "r3", "r4"])

        h.service.removeFromQueue(h.songs("r1", "r2", "r3", "r4"))
        await h.settle()

        #expect(await h.backend.radioSeeds == ["b", "a"])
        #expect(h.upNextIDs == ["b", "s1", "s2"])
    }

    // MARK: - One effect per call

    @Test("A bulk edit leaves one line, the last call's, and the saved session holds the final order")
    func oneLineAndFinalSession() async throws {
        let h = BulkQueueHarness()
        defer { h.cleanUp() }
        await h.signIn()
        await h.startPage(["a", "b", "c", "d", "e"])
        h.settleWrites()
        let saves = h.store.saveCount

        h.service.playNext(h.songs("x", "y", "z"))
        h.store.waitForWrites()

        #expect(h.notice == "Playing 3 songs next")
        // The scheduler would fold three saves into one write, so the writes cannot tell: count the calls. One call per
        // edit, not one per song.
        #expect(h.store.saveCount - saves == 1)
        h.settleWrites()
        let saved = try #require(h.folder.readSnapshot())
        #expect(saved.queue.tracks.map(\.videoId) == ["a", "x", "y", "z", "b", "c", "d", "e"])
    }

    @Test("Add to queue and Remove from queue each save the session once for the whole selection")
    func oneSavePerEdit() async {
        let h = BulkQueueHarness()
        defer { h.cleanUp() }
        await h.signIn()
        await h.startPage(["a", "b", "c", "d", "e"])
        h.settleWrites()

        let beforeAdd = h.store.saveCount
        h.service.addToQueue(h.songs("x", "y", "z"))
        #expect(h.store.saveCount - beforeAdd == 1)

        let beforeRemove = h.store.saveCount
        h.service.removeFromQueue(h.songs("x", "y", "b"))
        #expect(h.store.saveCount - beforeRemove == 1)
    }

    @Test("A bulk edit that changes nothing writes no session and posts no line")
    func noChangeNoSave() async throws {
        let h = BulkQueueHarness()
        defer { h.cleanUp() }
        await h.signIn()
        await h.startPage(["a", "b"])
        h.settleWrites()
        let before = h.store.writeCount
        let saves = h.store.saveCount

        h.service.playNext(h.songs("a", "a"))
        h.service.removeFromQueue(h.songs("q", "r"))
        h.store.waitForWrites()

        #expect(h.store.writeCount == before)
        #expect(h.store.saveCount == saves)
        #expect(h.notice == nil)
    }

    // MARK: - Large selections

    @Test("A selection of a thousand songs lands whole and in order")
    func thousandSongs() async {
        let h = BulkQueueHarness()
        await h.startPage(["a", "b"])
        let ids = (0..<1_000).map { "v\($0)" }
        h.service.playNext(ids.map { h.song($0) })

        #expect(Array(h.queuedIDs.prefix(1_002)) == ["a"] + ids + ["b"])
        #expect(h.notice == "Playing 1000 songs next")
    }

    // MARK: - Offline

    @Test("Offline only the downloaded songs of a selection are queued")
    func offlineQueuesDownloadedOnly() async {
        let rig = OfflineRig()
        defer { rig.cleanUp() }
        #expect(await rig.download(DownloadSamples.idA))
        #expect(await rig.download(DownloadSamples.idB))
        #expect(await rig.download(DownloadSamples.idC))
        rig.goOffline()
        rig.service.play(rig.song(DownloadSamples.idA))
        await rig.settle()
        rig.engine.emit(.playingChanged(true))

        rig.service.playNext([rig.song(DownloadSamples.idB), rig.song("notDownloaded"), rig.song(DownloadSamples.idC)])

        #expect(rig.service.queue.tracks.map(\.videoId) == [DownloadSamples.idA, DownloadSamples.idB, DownloadSamples.idC])
        #expect(rig.service.trackActions.notice?.text == "Playing 2 songs next")
    }
}
