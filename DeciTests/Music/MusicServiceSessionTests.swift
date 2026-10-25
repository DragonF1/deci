// DeciTests/Music/MusicServiceSessionTests.swift
// Reopening the app on the same song, queue and time, paused: when the service saves its session, when it deletes it,
// and how a launch puts it back. A fake backend and a fake AVPlayer seam; the session file lives in a folder of its own
// under /Volumes/Storage/_test, written by a store that runs on the test's clock.

import Foundation
import Testing
@testable import Deci

/// One launch of the service with a session store on a test folder. A second rig on the same folder and clock is the
/// next launch.
@MainActor
private struct SessionRig {
    let backend: FakeMusicBackend
    let engine = FakePlaybackEngine()
    let surface = FakeNowPlayingSurface()
    let clock: MutableClock
    let scheduler: ManualWriteScheduler
    let folder: SessionTestFolder
    let store: MusicSessionStore?
    let service: MusicService

    init(
        signedIn: Bool = true,
        folder: SessionTestFolder = SessionTestFolder(),
        clock: MutableClock = MutableClock(),
        hasStore: Bool = true,
        preferences: MusicPlaybackPreferences = MusicPlaybackPreferences()
    ) {
        let backend = FakeMusicBackend(signedIn: signedIn)
        self.backend = backend
        self.folder = folder
        self.clock = clock
        let scheduler = ManualWriteScheduler(clock: clock)
        self.scheduler = scheduler
        let store = hasStore ? MusicSessionStore(fileURL: folder.fileURL, now: { clock.now }, scheduler: scheduler) : nil
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
        store?.waitForWrites()
        folder.remove()
    }

    /// Signed in, and the account's key known, so the first save has everything it needs.
    func signIn() async {
        await service.refreshAuth()
        await service.sessionKeyTask?.value
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

    /// Lets the write held back by the one-a-second rule go, and waits for the file.
    func settleWrites() {
        scheduler.advance(by: 1)
        store?.waitForWrites()
    }

    func song(_ id: String) -> Deci.MusicTrack { MusicSamples.track(id, title: "Song \(id)") }

    /// Plays `tap` from a playlist page of `ids`, waits for the queue work, and has the engine report it playing.
    func startPage(_ ids: [String], tap: String? = nil) async {
        let page = MusicSamples.page("VLPL1", tracks: ids.map { song($0) })
        service.play(song(tap ?? ids[0]), in: page)
        await settle()
        engine.emit(.playingChanged(true))
    }

    /// The 0.5 s position ticks the player would report: a baseline at `start`, then `seconds` of playback.
    func listen(seconds: TimeInterval, from start: TimeInterval = 0, playing: Bool = true) {
        engine.tick(start, playing: playing)
        var position = start
        for _ in 0..<Int(seconds / 0.5) {
            position += 0.5
            clock.advance(by: 0.5)
            engine.tick(position, playing: playing)
        }
    }

    /// Writes a session file as an earlier launch would have left it: `ids` in order with `current` playing, `age`
    /// seconds old.
    @discardableResult
    func seed(
        _ ids: [String] = ["a", "b", "c", "d"], current: String = "b", position: TimeInterval = 95,
        channel: String = "channel-a", age: TimeInterval = 60
    ) -> MusicSessionSnapshot {
        var queue = MusicQueue()
        queue.start(with: song(ids[0]))
        queue.append(ids.dropFirst().map { song($0) }, continuation: nil)
        _ = queue.jump(to: current)
        let snapshot = MusicSessionSnapshot(
            savedAt: clock.now.addingTimeInterval(-age), channelKey: channel, position: position, queue: queue
        )
        let seeder = MusicSessionStore(fileURL: folder.fileURL, now: { clock.now }, scheduler: ManualWriteScheduler(clock: clock))
        seeder.save(snapshot)
        seeder.flush()
        return snapshot
    }

    /// The launch step: restores what the file holds and waits for it to land.
    func restore() async {
        service.restoreSession()
        await service.restoreTask?.value
    }

    /// Polls until `condition` holds; for work that is held at a gate and cannot be awaited.
    func eventually(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<400 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    var saved: MusicSessionSnapshot? { folder.readSnapshot() }

    func requireSaved(sourceLocation: SourceLocation = #_sourceLocation) throws -> MusicSessionSnapshot {
        try #require(saved, sourceLocation: sourceLocation)
    }

    func requireStore(sourceLocation: SourceLocation = #_sourceLocation) throws -> MusicSessionStore {
        try #require(store, sourceLocation: sourceLocation)
    }

    var queuedIDs: [String] { service.queue.tracks.map(\.videoId) }
    var loadedIDs: [String] { engine.loads.map(\.stream.videoId) }
}

/// What `onNativePlayingChange` was told.
private final class NativeReports {
    var values: [Bool] = []
}

// MARK: - Saving

@MainActor
@Suite("MusicService session saving")
struct MusicServiceSessionSavingTests {

    @Test("A song that starts is saved with its queue and the account it was played under")
    func trackChangeSaves() async throws {
        let rig = SessionRig()
        defer { rig.cleanUp() }
        await rig.signIn()
        await rig.startPage(["a", "b", "c"])
        rig.settleWrites()

        let snapshot = try rig.requireSaved()
        #expect(snapshot.queue.current?.videoId == "a")
        #expect(snapshot.queue.tracks.map(\.videoId) == ["a", "b", "c"])
        #expect(snapshot.channelKey == "channel-a")
        #expect(snapshot.position == 0)
    }

    @Test("Next saves the song it moved to, with the one before it kept for Previous")
    func nextSaves() async throws {
        let rig = SessionRig()
        defer { rig.cleanUp() }
        await rig.signIn()
        await rig.startPage(["a", "b", "c"])
        rig.settleWrites()

        rig.service.next()
        await rig.settle()
        rig.settleWrites()

        let snapshot = try rig.requireSaved()
        #expect(snapshot.queue.current?.videoId == "b")
        #expect(snapshot.queue.hasPrevious)
        #expect(snapshot.queue.upcoming.map(\.videoId) == ["c"])
    }

    @Test("A radio page that lands is saved, so Up next comes back whole")
    func radioPageSaves() async throws {
        let rig = SessionRig()
        defer { rig.cleanUp() }
        await rig.signIn()
        await rig.backend.setRadio(seed: "a", tracks: MusicSamples.tracks("a", "r1", "r2", "r3", "r4"))
        rig.service.play(rig.song("a"))
        await rig.settle()
        rig.engine.emit(.playingChanged(true))
        rig.settleWrites()

        let snapshot = try rig.requireSaved()
        #expect(snapshot.queue.tracks.map(\.videoId) == ["a", "r1", "r2", "r3", "r4"])
    }

    @Test("A pause saves the exact place it stopped at")
    func pauseSavesThePosition() async throws {
        let rig = SessionRig()
        defer { rig.cleanUp() }
        await rig.signIn()
        await rig.startPage(["a", "b"])
        rig.listen(seconds: 9)
        rig.engine.emit(.playingChanged(false))
        rig.settleWrites()

        #expect(try rig.requireSaved().position == 9)
    }

    @Test("A seek saves the place it landed on")
    func seekSaves() async throws {
        let rig = SessionRig()
        defer { rig.cleanUp() }
        await rig.signIn()
        await rig.startPage(["a", "b"])
        rig.listen(seconds: 3)
        rig.service.seek(to: 120)
        rig.settleWrites()

        #expect(try rig.requireSaved().position == 120)
    }

    @Test("Play next, Add to queue, Remove and the shuffle each save the queue as it is then")
    func queueEditsSave() async throws {
        let rig = SessionRig()
        defer { rig.cleanUp() }
        await rig.signIn()
        await rig.startPage(["a", "b", "c", "d"])
        rig.settleWrites()

        rig.service.playNext(rig.song("x"))
        rig.settleWrites()
        #expect(try rig.requireSaved().queue.upcoming.map(\.videoId).prefix(2) == ["x", "b"])

        rig.service.addToQueue(rig.song("y"))
        rig.settleWrites()
        #expect(try rig.requireSaved().queue.upcoming.map(\.videoId).contains("y"))

        rig.service.removeFromQueue(rig.song("b"))
        rig.settleWrites()
        #expect(!(try rig.requireSaved().queue.tracks.map(\.videoId).contains("b")))

        rig.service.setShuffle(true)
        rig.settleWrites()
        #expect(try rig.requireSaved().queue.isShuffled)

        rig.service.setShuffle(false)
        rig.settleWrites()
        #expect(!(try rig.requireSaved().queue.isShuffled))
    }

    @Test("Turning Autoplay off saves the radio as parked")
    func autoplayToggleSaves() async throws {
        let rig = SessionRig()
        defer { rig.cleanUp() }
        await rig.signIn()
        await rig.backend.setRadio(seed: "a", tracks: MusicSamples.tracks("a", "r1", "r2", "r3", "r4", "r5"))
        rig.service.play(rig.song("a"))
        await rig.settle()
        rig.engine.emit(.playingChanged(true))
        rig.settleWrites()
        #expect(try rig.requireSaved().queue.tracks.count == 6)

        rig.service.setAutoplay(false)
        rig.settleWrites()
        let snapshot = try rig.requireSaved()
        #expect(snapshot.queue.radioIsParked)
        #expect(snapshot.queue.tracks.map(\.videoId) == ["a"])
    }

    @Test("While a song plays the place is saved about every 10 seconds, and not while it is paused")
    func periodicSave() async throws {
        let rig = SessionRig()
        defer { rig.cleanUp() }
        await rig.signIn()
        await rig.startPage(["a", "b"])
        rig.listen(seconds: 25)
        rig.settleWrites()
        #expect(try rig.requireSaved().position == 20)

        rig.engine.emit(.playingChanged(false))
        rig.settleWrites()
        let writes = try rig.requireStore().writeCount
        #expect(try rig.requireSaved().position == 25)

        rig.listen(seconds: 60, from: 25, playing: false)
        rig.settleWrites()
        #expect(try rig.requireStore().writeCount == writes)
    }

    @Test("Playing does not write more than once a second")
    func writesAreCoalesced() async throws {
        let rig = SessionRig()
        defer { rig.cleanUp() }
        await rig.signIn()
        await rig.startPage(["a", "b", "c", "d", "e"])
        let store = try rig.requireStore()
        let before = store.writeCount
        for index in 0..<6 { rig.service.playNext(rig.song("x\(index)")) }
        store.waitForWrites()
        #expect(store.writeCount - before <= 1)
        #expect(rig.scheduler.pendingCount <= 1)
    }

    @Test("Quitting saves at once, with the position the song had, and the file stays")
    func terminateSaves() async throws {
        let rig = SessionRig()
        defer { rig.cleanUp() }
        await rig.signIn()
        await rig.startPage(["a", "b", "c"])
        rig.listen(seconds: 7)

        rig.service.stop()

        let snapshot = try rig.requireSaved()
        #expect(snapshot.position == 7)
        #expect(snapshot.queue.current?.videoId == "a")
        #expect(snapshot.queue.tracks.map(\.videoId) == ["a", "b", "c"])
    }

    @Test("Nothing is saved before the account is known, and the song is saved the moment it is")
    func waitsForTheAccountKey() async throws {
        let rig = SessionRig()
        defer { rig.cleanUp() }
        await rig.backend.setSessionIdentity(nil)
        await rig.signIn()
        await rig.startPage(["a", "b"])
        rig.settleWrites()
        #expect(rig.saved == nil)

        await rig.backend.setSessionIdentity("channel-a")
        await rig.service.refreshAuth()
        await rig.service.sessionKeyTask?.value
        rig.settleWrites()
        #expect(try rig.requireSaved().channelKey == "channel-a")
    }

    @Test("Nothing is saved while signed out")
    func signedOutSavesNothing() async {
        let rig = SessionRig(signedIn: false)
        defer { rig.cleanUp() }
        await rig.signIn()
        await rig.startPage(["a", "b"])
        rig.listen(seconds: 15)
        rig.service.stop()
        #expect(rig.saved == nil)
    }

    @Test("A service without a store saves nothing and plays as before")
    func noStore() async {
        let rig = SessionRig(hasStore: false)
        defer { rig.cleanUp() }
        await rig.signIn()
        await rig.startPage(["a", "b"])
        rig.listen(seconds: 15)
        rig.service.stop()
        #expect(!rig.folder.fileExists)
        #expect(rig.loadedIDs == ["a"])
    }

    // MARK: Deleting

    @Test("A queue that ends deletes the file")
    func queueEndDeletes() async {
        let rig = SessionRig(preferences: MusicPlaybackPreferences(autoplay: false))
        defer { rig.cleanUp() }
        await rig.signIn()
        await rig.startPage(["a"])
        rig.settleWrites()
        #expect(rig.saved != nil)

        rig.service.next()
        rig.store?.waitForWrites()

        #expect(rig.service.queue.isEmpty)
        #expect(!rig.folder.fileExists)
    }

    @Test("Signing out deletes the file, and what still ticks does not bring it back")
    func signOutDeletes() async {
        let rig = SessionRig()
        defer { rig.cleanUp() }
        await rig.signIn()
        await rig.startPage(["a", "b"])
        rig.settleWrites()
        #expect(rig.saved != nil)

        rig.service.signOut()
        rig.store?.waitForWrites()
        #expect(!rig.folder.fileExists)

        rig.listen(seconds: 30)
        rig.settleWrites()
        #expect(!rig.folder.fileExists)
    }

    @Test("A session YouTube Music ended deletes the file while the song plays on, and ticks do not bring it back")
    func expiredSessionDeletes() async {
        let rig = SessionRig()
        defer { rig.cleanUp() }
        await rig.signIn()
        await rig.startPage(["a", "b"])
        rig.settleWrites()
        #expect(rig.saved != nil)

        rig.service.browse.onSessionExpired?()
        rig.store?.waitForWrites()
        #expect(rig.service.authState == .signedOut)
        #expect(!rig.folder.fileExists)

        rig.listen(seconds: 30)
        rig.service.playNext(rig.song("x"))
        rig.settleWrites()
        #expect(!rig.folder.fileExists)
    }

    @Test("Playing a different song replaces the file with the new queue")
    func newQueueReplacesTheFile() async throws {
        let rig = SessionRig()
        defer { rig.cleanUp() }
        await rig.signIn()
        await rig.startPage(["a", "b"])
        rig.settleWrites()

        await rig.startPage(["p", "q", "r"], tap: "q")
        rig.settleWrites()

        let snapshot = try rig.requireSaved()
        #expect(snapshot.queue.tracks.map(\.videoId) == ["p", "q", "r"])
        #expect(snapshot.queue.current?.videoId == "q")
    }
}

// MARK: - Restoring

@MainActor
@Suite("MusicService session restore")
struct MusicServiceSessionRestoreTests {

    @Test("A fresh session comes back as the same queue, on the same song, loaded paused at the saved place and never played")
    func restoresPaused() async {
        let rig = SessionRig()
        defer { rig.cleanUp() }
        rig.seed(["a", "b", "c", "d"], current: "b", position: 95)
        await rig.restore()

        #expect(rig.queuedIDs == ["a", "b", "c", "d"])
        #expect(rig.service.queue.current?.videoId == "b")
        #expect(rig.service.queue.hasPrevious)
        #expect(rig.service.player.nowPlaying?.videoId == "b")
        #expect(rig.engine.loads.count == 1)
        #expect(rig.engine.loads.first?.stream.videoId == "b")
        #expect(rig.engine.loads.first?.startAt == 95)
        #expect(rig.engine.loads.first?.autoplay == false)
        #expect(rig.engine.playCount == 0)
        #expect(!rig.service.player.isPlaying)
        #expect(await rig.backend.resolvedIDs == ["b"])
        #expect(rig.service.authState == .signedIn)
    }

    @Test("The menu bar chip's inputs show the paused song: it is loaded in the player and has a stream")
    func chipSeesThePausedSong() async {
        let rig = SessionRig()
        defer { rig.cleanUp() }
        rig.seed()
        await rig.restore()
        rig.engine.emit(.ready(duration: 200))

        #expect(rig.service.player.nowPlaying?.videoId == "b")
        #expect(rig.service.player.hasStream)
        #expect(!rig.service.player.isActive)
        #expect(rig.service.player.currentTime == 95)
    }

    @Test("The restored song never reports itself as playing or loading, so nothing else reacts to it")
    func neverLooksActive() async {
        let rig = SessionRig()
        defer { rig.cleanUp() }
        rig.seed()
        let reports = NativeReports()
        rig.service.onNativePlayingChange = { reports.values.append($0) }

        await rig.restore()
        #expect(!rig.service.player.isLoading)
        #expect(!rig.service.player.isActive)

        rig.engine.emit(.ready(duration: 200))
        #expect(!rig.service.player.isActive)
        #expect(reports.values.isEmpty)
    }

    @Test("Up next shows the restored queue after the song")
    func upNextIsRestored() async {
        let rig = SessionRig()
        defer { rig.cleanUp() }
        rig.seed(["a", "b", "c", "d"], current: "b")
        await rig.restore()

        #expect(rig.service.queue.upcoming.map(\.videoId) == ["c", "d"])
    }

    @Test("The shuffled order, a song queued with Play next and a staged radio all come back")
    func modesComeBack() async throws {
        let first = SessionRig()
        defer { first.cleanUp() }
        await first.signIn()
        await first.backend.setRadio(seed: "e", tracks: MusicSamples.tracks("e", "s1", "s2"))
        await first.startPage(["a", "b", "c", "d", "e"])
        first.service.setShuffle(true)
        first.service.playNext(first.song("x"))
        await first.settle()
        let order = first.queuedIDs
        let staged = first.service.queue.autoplay.map(\.videoId)
        #expect(staged == ["s1", "s2"])
        first.service.stop()

        let second = SessionRig(folder: first.folder, clock: first.clock)
        await second.restore()

        #expect(second.queuedIDs == order)
        #expect(second.service.queue.isShuffled)
        #expect(second.service.queue.autoplay.map(\.videoId) == staged)
        #expect(second.service.queue.upcoming.first?.videoId == "x")
    }

    @Test("A place near the end is held back from it, and a place inside the song is kept")
    func positionIsClamped() async {
        let near = SessionRig()
        defer { near.cleanUp() }
        near.seed(position: 199)
        await near.restore()
        #expect(near.engine.loads.first?.startAt == 198)

        let inside = SessionRig()
        defer { inside.cleanUp() }
        inside.seed(position: 50)
        await inside.restore()
        #expect(inside.engine.loads.first?.startAt == 50)
    }

    @Test("A song with no length known anywhere starts from the beginning")
    func unknownLengthStartsOver() async {
        let rig = SessionRig()
        defer { rig.cleanUp() }
        var queue = MusicQueue()
        queue.start(with: MusicSamples.track("b", seconds: nil))
        let snapshot = MusicSessionSnapshot(savedAt: rig.clock.now, channelKey: "channel-a", position: 50, queue: queue)
        let seeder = MusicSessionStore(fileURL: rig.folder.fileURL, now: { rig.clock.now }, scheduler: ManualWriteScheduler(clock: rig.clock))
        seeder.save(snapshot)
        seeder.flush()
        await rig.backend.setStream(MusicSamples.stream(videoId: "b", duration: nil))
        await rig.restore()

        #expect(rig.engine.loads.first?.startAt == 0)
    }

    @Test("Restoring writes nothing and leaves the hour running from the last real save, also across a quit")
    func restoreKeepsTheOriginalTime() async throws {
        let rig = SessionRig()
        defer { rig.cleanUp() }
        let seeded = rig.seed(age: 30 * 60)
        await rig.restore()
        await rig.service.sessionKeyTask?.value
        rig.settleWrites()

        #expect(rig.store?.writeCount == 0)
        #expect(try rig.requireSaved().savedAt == seeded.savedAt)

        rig.service.stop()
        #expect(rig.store?.writeCount == 0)
        #expect(try rig.requireSaved().savedAt == seeded.savedAt)
    }

    @Test("Once the listener plays it, the session is theirs again and a quit saves it with a fresh time")
    func touchedRestoreSavesAgain() async throws {
        let rig = SessionRig()
        defer { rig.cleanUp() }
        let seeded = rig.seed(age: 30 * 60)
        await rig.restore()
        rig.service.resume()
        rig.engine.emit(.playingChanged(true))
        rig.listen(seconds: 5, from: 95)

        rig.service.stop()

        let snapshot = try rig.requireSaved()
        #expect(snapshot.savedAt > seeded.savedAt)
        #expect(snapshot.position == 100)
        #expect(snapshot.queue.current?.videoId == "b")
    }

    @Test("Restoring sends no history ping, however long it sits paused, and a quit sends none either")
    func restoreSendsNoHistory() async throws {
        let rig = SessionRig()
        defer { rig.cleanUp() }
        await rig.backend.setStream(MusicSamples.stream(
            videoId: "b",
            trackingURL: URL(string: "https://music.example.test/stats/playback?ev=old"),
            watchtimeURL: URL(string: "https://music.example.test/stats/watchtime?ev=old")
        ))
        rig.seed()
        await rig.restore()
        rig.listen(seconds: 40, from: 95, playing: false)
        rig.service.stop()
        await rig.service.reportTask?.value

        #expect(await rig.backend.reportAttempts.isEmpty)
    }

    @Test("Play after a restore resumes the loaded song once, without loading or resolving it again")
    func playResumesTheRestoredSong() async {
        let rig = SessionRig()
        defer { rig.cleanUp() }
        rig.seed()
        await rig.restore()
        rig.engine.emit(.ready(duration: 200))

        rig.service.resume()

        #expect(rig.engine.playCount == 1)
        #expect(rig.engine.loads.count == 1)
        #expect(await rig.backend.resolvedIDs == ["b"])
    }

    @Test("A song the listener plays before the restore lands wins: the restore is dropped, and the file follows the new song")
    func playBeforeRestoreDropsIt() async throws {
        let rig = SessionRig()
        defer { rig.cleanUp() }
        rig.seed(["a", "b", "c", "d"], current: "b")
        let gate = MusicTestGate()
        await rig.backend.setResolveGate("b", gate)

        rig.service.restoreSession()
        let reached = await rig.eventually { await rig.backend.resolvedIDs.contains("b") }
        #expect(reached)

        rig.service.play(rig.song("z"))
        await rig.settle()
        await gate.open()
        await rig.service.restoreTask?.value
        await rig.settle()

        #expect(rig.loadedIDs == ["z"])
        #expect(rig.service.queue.current?.videoId == "z")
        #expect(rig.service.player.nowPlaying?.videoId == "z")
        #expect(!rig.queuedIDs.contains("c"))
        rig.settleWrites()
        #expect(try rig.requireSaved().queue.current?.videoId == "z")
    }

    @Test("A song that cannot be loaded leaves nothing playing, no error line, and deletes the file")
    func resolveFailureDeletes() async {
        let rig = SessionRig()
        defer { rig.cleanUp() }
        rig.seed()
        await rig.backend.setResolveError("b", MusicError.unplayable("gone"))
        await rig.restore()
        rig.store?.waitForWrites()

        #expect(rig.service.player.nowPlaying == nil)
        #expect(rig.service.queue.isEmpty)
        #expect(rig.engine.loads.isEmpty)
        #expect(rig.service.lastError == nil)
        #expect(!rig.folder.fileExists)
        // The neighbour is not tried: nothing plays, however the song failed.
        #expect(await rig.backend.resolvedIDs == ["b"])
    }

    @Test("A network failure while loading also leaves nothing playing and deletes the file")
    func networkFailureDeletes() async {
        let rig = SessionRig()
        defer { rig.cleanUp() }
        rig.seed()
        await rig.backend.setResolveError("b", URLError(.notConnectedToInternet))
        await rig.restore()
        rig.store?.waitForWrites()

        #expect(rig.service.queue.isEmpty)
        #expect(rig.service.player.nowPlaying == nil)
        #expect(!rig.folder.fileExists)
    }

    @Test("A restored song the engine then fails on ends the queue instead of playing the next one")
    func failureAfterRestoreEnds() async {
        let rig = SessionRig()
        defer { rig.cleanUp() }
        rig.seed()
        await rig.restore()
        await rig.backend.setResolveError("b", MusicError.unplayable("gone"))

        rig.engine.emit(.failed)
        await rig.service.player.refreshTask?.value
        rig.store?.waitForWrites()

        #expect(rig.engine.loads.count == 1)
        #expect(rig.service.queue.isEmpty)
        #expect(rig.service.player.nowPlaying == nil)
        #expect(!rig.folder.fileExists)
        #expect(rig.engine.playCount == 0)
    }

    @Test("Another account's session is deleted and nothing is resolved")
    func otherAccountDeletes() async {
        let rig = SessionRig()
        defer { rig.cleanUp() }
        rig.seed(channel: "channel-b")
        await rig.restore()
        rig.store?.waitForWrites()

        #expect(await rig.backend.resolvedIDs.isEmpty)
        #expect(rig.service.queue.isEmpty)
        #expect(rig.service.player.nowPlaying == nil)
        #expect(!rig.folder.fileExists)
    }

    @Test("A launch that is signed out deletes the file and resolves nothing")
    func signedOutLaunchDeletes() async {
        let rig = SessionRig(signedIn: false)
        defer { rig.cleanUp() }
        rig.seed()
        await rig.restore()
        rig.store?.waitForWrites()

        #expect(await rig.backend.resolvedIDs.isEmpty)
        #expect(rig.service.queue.isEmpty)
        #expect(!rig.folder.fileExists)
    }

    @Test("A session over an hour old is deleted and nothing is resolved, one just inside the hour comes back")
    func expiryAtTheService() async {
        let old = SessionRig()
        defer { old.cleanUp() }
        old.seed(age: 61 * 60)
        await old.restore()
        old.store?.waitForWrites()
        #expect(await old.backend.resolvedIDs.isEmpty)
        #expect(old.service.queue.isEmpty)
        #expect(!old.folder.fileExists)

        let fresh = SessionRig()
        defer { fresh.cleanUp() }
        fresh.seed(age: 59 * 60)
        await fresh.restore()
        #expect(fresh.service.player.nowPlaying?.videoId == "b")
    }

    @Test("When the account cannot be told, nothing is restored and the file is left for the next launch")
    func unknownAccountKeepsTheFile() async {
        let rig = SessionRig()
        defer { rig.cleanUp() }
        rig.seed()
        await rig.backend.setSessionIdentity(nil)
        await rig.restore()
        rig.store?.waitForWrites()

        #expect(await rig.backend.resolvedIDs.isEmpty)
        #expect(rig.service.queue.isEmpty)
        #expect(rig.folder.fileExists)
    }

    @Test("There is nothing to restore without a file, and nothing is created")
    func noFile() async {
        let rig = SessionRig()
        defer { rig.cleanUp() }
        await rig.restore()

        #expect(await rig.backend.resolvedIDs.isEmpty)
        #expect(rig.service.player.nowPlaying == nil)
        #expect(!rig.folder.fileExists)
    }

    @Test("A service without a store has nothing to restore")
    func noStoreNoRestore() async {
        let rig = SessionRig(hasStore: false)
        defer { rig.cleanUp() }
        rig.seed()
        rig.service.restoreSession()

        #expect(rig.service.restoreTask == nil)
        #expect(rig.service.player.nowPlaying == nil)
        #expect(rig.folder.fileExists)
    }

    @Test("A restore asked for while a song already plays is ignored, and so is a second one")
    func restoreIsOnce() async {
        let busy = SessionRig()
        defer { busy.cleanUp() }
        await busy.signIn()
        await busy.startPage(["p", "q"])
        busy.seed()
        busy.service.restoreSession()
        #expect(busy.service.restoreTask == nil)
        #expect(busy.loadedIDs == ["p"])

        let twice = SessionRig()
        defer { twice.cleanUp() }
        twice.seed()
        twice.service.restoreSession()
        let task = twice.service.restoreTask
        twice.service.restoreSession()
        await task?.value
        #expect(twice.loadedIDs == ["b"])
    }

    @Test("What one launch leaves at quit the next puts back, on the same song at the same second")
    func twoLaunchesRoundTrip() async throws {
        let first = SessionRig()
        defer { first.cleanUp() }
        await first.signIn()
        await first.startPage(["a", "b", "c", "d"])
        first.service.next()
        await first.settle()
        first.engine.emit(.playingChanged(true))
        first.listen(seconds: 12)
        first.service.stop()

        let second = SessionRig(folder: first.folder, clock: first.clock)
        first.clock.advance(by: 10 * 60)
        await second.restore()

        #expect(second.queuedIDs == ["a", "b", "c", "d"])
        #expect(second.service.queue.current?.videoId == "b")
        #expect(second.engine.loads.first?.startAt == 12)
        #expect(second.engine.loads.first?.autoplay == false)
        #expect(second.engine.playCount == 0)
        #expect(second.service.queue.hasPrevious)
    }
}

// MARK: - Host

@MainActor
@Suite("MusicServiceHost session restore")
struct MusicServiceHostSessionTests {

    private final class Built {
        var count = 0
    }

    /// A host whose service is the rig's. `built` counts how many services the host made.
    private func makeHost(_ rig: SessionRig, built: Built) -> MusicServiceHost {
        MusicServiceHost(sessionStore: rig.store, makeService: {
            built.count += 1
            return rig.service
        })
    }

    @Test("With no session saved the Music service is not started")
    func noSnapshotStaysLazy() {
        let rig = SessionRig()
        defer { rig.cleanUp() }
        let built = Built()
        let host = makeHost(rig, built: built)

        host.restoreSessionIfAny()

        #expect(host.service == nil)
        #expect(built.count == 0)
    }

    @Test("A fresh session starts the service once and restores it")
    func freshSnapshotStartsAndRestores() async {
        let rig = SessionRig()
        defer { rig.cleanUp() }
        rig.seed()
        let built = Built()
        let host = makeHost(rig, built: built)

        host.restoreSessionIfAny()
        await host.service?.restoreTask?.value

        #expect(built.count == 1)
        #expect(host.service === rig.service)
        #expect(rig.service.player.nowPlaying?.videoId == "b")
        #expect(host.hasLoadedTrack)
        #expect(rig.engine.playCount == 0)
    }

    @Test("A session that ran out is deleted without starting the service")
    func staleSnapshotStaysLazy() {
        let rig = SessionRig()
        defer { rig.cleanUp() }
        rig.seed(age: 2 * 3600)
        let built = Built()
        let host = makeHost(rig, built: built)

        host.restoreSessionIfAny()
        rig.store?.waitForWrites()

        #expect(host.service == nil)
        #expect(built.count == 0)
        #expect(!rig.folder.fileExists)
    }

    @Test("A service the listener already opened is left alone")
    func existingServiceIsKept() {
        let rig = SessionRig()
        defer { rig.cleanUp() }
        rig.seed()
        let built = Built()
        let host = makeHost(rig, built: built)
        host.loadIfNeeded()

        host.restoreSessionIfAny()

        #expect(built.count == 1)
        #expect(rig.service.restoreTask == nil)
        #expect(rig.service.player.nowPlaying == nil)
    }

    @Test("A host with no store never starts the service by itself")
    func noStoreStaysLazy() {
        let rig = SessionRig(hasStore: false)
        defer { rig.cleanUp() }
        rig.seed()
        let built = Built()
        let host = MusicServiceHost(makeService: {
            built.count += 1
            return rig.service
        })

        host.restoreSessionIfAny()

        #expect(host.service == nil)
        #expect(built.count == 0)
    }
}
