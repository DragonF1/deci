// DeciTests/Music/MusicServiceDownloadsTests.swift
// Playback of a downloaded song: playing it, restoring it from the saved session and prefetching it as the next
// track all start the file on disk at once; a song that is not downloaded still resolves before it plays; a file that
// fails to play is retried once through the network. The backend is still asked for a downloaded song's tracking URLs,
// in the background, so an online play reaches History as any other; offline the song plays on without pings. A fake
// backend, a fake AVPlayer seam, a fake transport for the downloads and folders under /Volumes/Storage/_test.

import Foundation
import Testing
@testable import Deci

/// The service with a download service on a folder of its own and a session store on another. A second rig on the same
/// download folder is the next launch.
@MainActor
private struct PlaybackRig {
    let backend: FakeMusicBackend
    let engine = FakePlaybackEngine()
    let clock = MutableClock()
    let downloadRig: DownloadServiceRig
    let sessionFolder = SessionTestFolder()
    let sessionStore: MusicSessionStore
    let player: MusicPlayer
    let service: MusicService

    var folder: DownloadTestFolder { downloadRig.folder }

    init(folder: DownloadTestFolder = DownloadTestFolder()) {
        let backend = FakeMusicBackend(signedIn: true)
        self.backend = backend
        let clock = clock
        let downloadRig = DownloadServiceRig(folder: folder)
        self.downloadRig = downloadRig
        sessionStore = MusicSessionStore(
            fileURL: sessionFolder.fileURL, now: { clock.now }, scheduler: ManualWriteScheduler(clock: clock)
        )
        let player = MusicPlayer(engine: engine)
        self.player = player
        service = MusicService(
            backend: backend,
            player: player,
            presentSignIn: { _ in },
            presentChannelPicker: { _, _ in },
            closeSignInWindow: {},
            raiseSignInWindow: {},
            nowPlaying: NowPlayingController(surface: FakeNowPlayingSurface(), fetchArtwork: { _ in nil }),
            now: { clock.now },
            shuffleSeed: 1,
            queueRetryDelay: .seconds(60),
            sessionStore: sessionStore,
            downloads: downloadRig.service,
            refreshOnCreate: false
        )
    }

    func cleanUp() {
        sessionStore.waitForWrites()
        sessionFolder.remove()
        downloadRig.cleanUp()
    }

    /// Downloads the song through the fake transport and waits until it is on disk.
    func download(_ id: String) async -> Bool {
        downloadRig.download(id)
        return await downloadRig.settles(id, as: .downloaded)
    }

    /// Waits for the background fetch of a downloaded song's tracking URLs, which a gate may be holding.
    func settleTracking() async {
        await service.trackingTask?.value
    }

    /// Feeds the 0.5 s position ticks the player would report: a baseline at `start`, then `seconds` of playback.
    func listen(seconds: TimeInterval, from start: TimeInterval = 0) {
        engine.tick(start, playing: true)
        var position = start
        for _ in 0..<Int(seconds / 0.5) {
            position += 0.5
            clock.advance(by: 0.5)
            engine.tick(position, playing: true)
        }
    }

    func song(_ id: String) -> Deci.MusicTrack { MusicSamples.track(id, title: "Song \(id)") }

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

    /// Plays the first of `ids` with the rest as its radio, and has the engine report it playing.
    func startQueue(_ ids: [String]) async {
        let tracks = ids.map(song)
        await backend.setRadio(seed: ids[0], tracks: tracks, continuation: nil)
        service.play(tracks[0])
        await settle()
        engine.emit(.playingChanged(true))
    }

    /// Writes the session file an earlier launch would have left, `current` of `ids` at `position` seconds.
    func seedSession(_ ids: [String], current: String, position: TimeInterval = 95) {
        var queue = MusicQueue()
        queue.start(with: song(ids[0]))
        queue.append(ids.dropFirst().map(song), continuation: nil)
        _ = queue.jump(to: current)
        let snapshot = MusicSessionSnapshot(
            savedAt: clock.now.addingTimeInterval(-60), channelKey: "channel-a", position: position, queue: queue
        )
        let seeder = MusicSessionStore(
            fileURL: sessionFolder.fileURL, now: { clock.now }, scheduler: ManualWriteScheduler(clock: clock)
        )
        seeder.save(snapshot)
        seeder.flush()
    }

    var loadedURLs: [URL] { engine.loads.map(\.stream.url) }
}

@MainActor
@Suite("MusicService downloads")
struct MusicServiceDownloadsTests {
    private let idA = DownloadSamples.idA
    private let idB = DownloadSamples.idB
    private let idC = DownloadSamples.idC

    // MARK: - Playing

    @Test("a downloaded song plays from its file, and the backend is asked only for its tracking URLs")
    func playsFromFile() async {
        let rig = PlaybackRig()
        defer { rig.cleanUp() }
        #expect(await rig.download(idA))

        rig.service.play(rig.song(idA))
        await rig.settle()
        await rig.settleTracking()

        #expect(rig.engine.loads.count == 1)
        #expect(rig.loadedURLs.first?.isFileURL == true)
        #expect(rig.loadedURLs.first?.path == rig.folder.audioURL(idA).path)
        #expect(rig.engine.loads.first?.stream.videoId == idA)
        // What the backend answered was read for its ping URLs only: the engine was not given a second stream.
        #expect(await rig.backend.resolvedIDs == [idA])
    }

    @Test("the file starts at once, while the backend's answer for the tracking URLs is still on its way")
    func fileStartsBeforeTrackingArrives() async {
        let rig = PlaybackRig()
        defer { rig.cleanUp() }
        #expect(await rig.download(idA))
        let gate = MusicTestGate()
        await rig.backend.setResolveGate(idA, gate)

        rig.service.play(rig.song(idA))
        await rig.settle()

        // The resolve is held at its gate, so everything below happened without it.
        #expect(rig.engine.loads.count == 1)
        #expect(rig.loadedURLs.first?.path == rig.folder.audioURL(idA).path)
        #expect(rig.service.trackingTask != nil)
        await gate.open()
        await rig.settleTracking()
    }

    @Test("a song that is not downloaded still resolves through the backend, whatever else is downloaded")
    func notDownloadedResolves() async {
        let rig = PlaybackRig()
        defer { rig.cleanUp() }
        #expect(await rig.download(idA))

        rig.service.play(rig.song(idB))
        await rig.settle()

        #expect(await rig.backend.resolvedIDs == [idB])
        #expect(rig.loadedURLs.first?.isFileURL == false)
    }

    @Test("the local stream carries the exact length, so the end-of-track guard has the right duration")
    func localStreamDuration() async {
        let rig = PlaybackRig()
        defer { rig.cleanUp() }
        #expect(await rig.download(idA))

        rig.service.play(rig.song(idA))
        await rig.settle()

        #expect(rig.engine.loads.first?.stream.durationSeconds == 200)
        #expect(rig.player.duration == 200)
    }

    @Test("a downloaded song is used even when the index of an earlier launch was still loading as play began")
    func earlierLaunchIsAwaited() async {
        let first = PlaybackRig()
        defer { first.cleanUp() }
        #expect(await first.download(idA))

        let second = PlaybackRig(folder: first.folder)
        second.service.play(second.song(idA))
        await second.settle()
        await second.settleTracking()

        #expect(second.loadedURLs.first?.path == first.folder.audioURL(idA).path)
        #expect(second.loadedURLs.count == 1)
        second.sessionFolder.remove()
    }

    @Test("a file that vanished from disk falls back to the network")
    func vanishedFileFallsBack() async throws {
        let rig = PlaybackRig()
        defer { rig.cleanUp() }
        #expect(await rig.download(idA))
        try FileManager.default.removeItem(at: rig.folder.audioURL(idA))

        rig.service.play(rig.song(idA))
        await rig.settle()

        #expect(await rig.backend.resolvedIDs == [idA])
        #expect(rig.loadedURLs.first?.isFileURL == false)
    }

    @Test("a song removed from downloads resolves again")
    func removedResolves() async {
        let rig = PlaybackRig()
        defer { rig.cleanUp() }
        #expect(await rig.download(idA))

        rig.downloadRig.service.remove(videoId: idA)
        rig.service.play(rig.song(idA))
        await rig.settle()

        #expect(await rig.backend.resolvedIDs == [idA])
    }

    // MARK: - A file that fails

    @Test("a local file that fails to play gets the network stream as its one retry")
    func localFailureRetriesThroughNetwork() async {
        let rig = PlaybackRig()
        defer { rig.cleanUp() }
        #expect(await rig.download(idA))
        rig.service.play(rig.song(idA))
        await rig.settle()
        await rig.settleTracking()
        #expect(await rig.backend.resolvedIDs == [idA])

        rig.engine.emit(.failed)
        await rig.player.refreshTask?.value

        #expect(rig.engine.loads.count == 2)
        #expect(rig.loadedURLs[0].isFileURL)
        #expect(rig.loadedURLs[1].isFileURL == false)
        #expect(await rig.backend.resolvedIDs == [idA, idA])
    }

    // MARK: - Restoring

    @Test("restoring a session whose song is downloaded loads the file paused, and asks the backend only for its tracking URLs")
    func restoreUsesFile() async {
        let rig = PlaybackRig()
        defer { rig.cleanUp() }
        #expect(await rig.download(idB))
        rig.seedSession([idA, idB, idC], current: idB)

        rig.service.restoreSession()
        await rig.service.restoreTask?.value
        await rig.settleTracking()

        #expect(rig.engine.loads.count == 1)
        #expect(rig.loadedURLs.first?.path == rig.folder.audioURL(idB).path)
        #expect(rig.engine.loads.first?.autoplay == false)
        #expect(rig.engine.loads.first?.startAt == 95)
        #expect(await rig.backend.resolvedIDs == [idB])
    }

    @Test("restoring a song that is not downloaded resolves it as before")
    func restoreResolves() async {
        let rig = PlaybackRig()
        defer { rig.cleanUp() }
        #expect(await rig.download(idA))
        rig.seedSession([idA, idB, idC], current: idB)

        rig.service.restoreSession()
        await rig.service.restoreTask?.value

        #expect(await rig.backend.resolvedIDs == [idB])
        #expect(rig.loadedURLs.first?.isFileURL == false)
    }

    // MARK: - Prefetch

    @Test("the next song is prefetched from its file when it is downloaded, with no resolve, and plays from it")
    func prefetchUsesFile() async {
        let rig = PlaybackRig()
        defer { rig.cleanUp() }
        #expect(await rig.download(idB))
        await rig.startQueue([idA, idB, idC])
        #expect(await rig.backend.resolvedIDs == [idA])

        rig.engine.tick(186, playing: true)
        await rig.service.prefetchTask?.value
        // Prefetching the file asks for nothing: the tracking URLs are fetched when the song begins.
        #expect(await rig.backend.resolvedIDs == [idA])
        rig.engine.emit(.ended)
        await rig.settle()
        await rig.settleTracking()

        #expect(await rig.backend.resolvedIDs == [idA, idB])
        #expect(rig.engine.loads.map(\.stream.videoId) == [idA, idB])
        #expect(rig.loadedURLs[0].isFileURL == false)
        #expect(rig.loadedURLs[1].path == rig.folder.audioURL(idB).path)
    }

    @Test("a next song that is not downloaded is prefetched through the backend as before")
    func prefetchResolves() async {
        let rig = PlaybackRig()
        defer { rig.cleanUp() }
        await rig.startQueue([idA, idB, idC])

        rig.engine.tick(186, playing: true)
        await rig.service.prefetchTask?.value

        #expect(await rig.backend.resolvedIDs == [idA, idB])
    }

    @Test("a song downloaded after it was prefetched from the network plays from the file")
    func downloadedAfterPrefetch() async {
        let rig = PlaybackRig()
        defer { rig.cleanUp() }
        await rig.startQueue([idA, idB, idC])
        rig.engine.tick(186, playing: true)
        await rig.service.prefetchTask?.value
        #expect(await rig.backend.resolvedIDs == [idA, idB])

        #expect(await rig.download(idB))
        rig.engine.emit(.ended)
        await rig.settle()

        #expect(rig.loadedURLs.last?.path == rig.folder.audioURL(idB).path)
    }

    // MARK: - History

    private let playbackURL = URL(string: "https://music.example.test/stats/playback?ev=late")!
    private let watchtimeURL = URL(string: "https://music.example.test/stats/watchtime?ev=late")!

    @Test("a downloaded song played online reaches History once its tracking URLs arrive, though they came after the 30 s")
    func lateTrackingURLsReachHistory() async {
        let rig = PlaybackRig()
        defer { rig.cleanUp() }
        await rig.backend.setStream(MusicSamples.stream(videoId: idA, trackingURL: playbackURL, watchtimeURL: watchtimeURL))
        #expect(await rig.download(idA))
        let gate = MusicTestGate()
        await rig.backend.setResolveGate(idA, gate)
        rig.service.play(rig.song(idA))
        await rig.settle()
        rig.engine.emit(.playingChanged(true))

        rig.listen(seconds: 31)
        // Nowhere to send a ping yet.
        #expect(await rig.backend.reportAttempts.isEmpty)
        await gate.open()
        await rig.settleTracking()
        await rig.service.reportTask?.value

        let reports = await rig.backend.reportAttempts
        #expect(reports.map(\.kind) == [.playback, .watchtime])
        #expect(reports.map(\.url) == [playbackURL, watchtimeURL])
        #expect(Set(reports.map(\.cpn)).count == 1)
        #expect(rig.engine.loads.count == 1)
    }

    @Test("tracking URLs that arrive before the 30 s are up send the pings at 30 s as for any song")
    func trackingURLsBeforeThirtySeconds() async {
        let rig = PlaybackRig()
        defer { rig.cleanUp() }
        await rig.backend.setStream(MusicSamples.stream(videoId: idA, trackingURL: playbackURL, watchtimeURL: watchtimeURL))
        #expect(await rig.download(idA))
        rig.service.play(rig.song(idA))
        await rig.settle()
        await rig.settleTracking()
        rig.engine.emit(.playingChanged(true))

        rig.listen(seconds: 29.5)
        #expect(await rig.backend.reportAttempts.isEmpty)
        rig.listen(seconds: 5, from: 29.5)
        await rig.service.reportTask?.value

        let reports = await rig.backend.reportAttempts
        #expect(reports.map(\.kind) == [.playback, .watchtime])
        #expect(reports.map(\.url) == [playbackURL, watchtimeURL])
    }

    @Test("a tracking fetch that fails leaves the song playing without pings, and shows nothing")
    func trackingFetchFails() async {
        let rig = PlaybackRig()
        defer { rig.cleanUp() }
        #expect(await rig.download(idA))
        await rig.backend.setResolveError(idA, MusicError.signedOut)

        rig.service.play(rig.song(idA))
        await rig.settle()
        await rig.settleTracking()
        rig.engine.emit(.playingChanged(true))
        rig.listen(seconds: 60)
        await rig.service.reportTask?.value

        #expect(await rig.backend.resolvedIDs == [idA])
        #expect(rig.engine.loads.count == 1)
        #expect(rig.player.nowPlaying?.videoId == idA)
        #expect(rig.service.lastError == nil)
        #expect(rig.service.authState == .unknown)
        #expect(await rig.backend.reportAttempts.isEmpty)
    }

    @Test("a tracking fetch that finishes after another song began attaches nothing to the new song")
    func staleTrackingIsDropped() async {
        let rig = PlaybackRig()
        defer { rig.cleanUp() }
        await rig.backend.setStream(MusicSamples.stream(videoId: idA, trackingURL: playbackURL, watchtimeURL: watchtimeURL))
        await rig.backend.setStream(MusicSamples.stream(videoId: idB, trackingURL: nil))
        #expect(await rig.download(idA))
        let gate = MusicTestGate()
        await rig.backend.setResolveGate(idA, gate)
        rig.service.play(rig.song(idA))
        await rig.settle()
        let stale = rig.service.trackingTask

        rig.service.play(rig.song(idB))
        await rig.settle()
        rig.engine.emit(.playingChanged(true))
        rig.listen(seconds: 40)
        await gate.open()
        await stale?.value
        rig.listen(seconds: 40, from: 40)
        await rig.service.reportTask?.value

        #expect(await rig.backend.reportAttempts.isEmpty)
        #expect(rig.player.nowPlaying?.videoId == idB)
    }

    @Test("a song that is not downloaded fetches no tracking URLs of its own: the one resolve gives them")
    func networkSongResolvesOnce() async {
        let rig = PlaybackRig()
        defer { rig.cleanUp() }

        rig.service.play(rig.song(idB))
        await rig.settle()
        await rig.settleTracking()

        #expect(await rig.backend.resolvedIDs == [idB])
        #expect(rig.service.trackingTask == nil)
    }

    // MARK: - Removing the song that plays

    @Test("removing the downloaded song that is playing keeps its file until the next song starts")
    func removePlayingKeepsFile() async {
        let rig = PlaybackRig()
        defer { rig.cleanUp() }
        #expect(await rig.download(idA))
        #expect(await rig.download(idB))
        rig.service.play(rig.song(idA))
        await rig.settle()

        rig.downloadRig.service.remove(videoId: idA)
        await rig.downloadRig.service.waitUntilIdle()

        #expect(rig.downloadRig.service.state(for: idA) == .none)
        #expect(rig.folder.exists(rig.folder.audioURL(idA)))

        rig.service.play(rig.song(idB))
        await rig.settle()
        await rig.downloadRig.service.waitUntilIdle()

        #expect(!rig.folder.exists(rig.folder.audioURL(idA)))
        #expect(rig.folder.exists(rig.folder.audioURL(idB)))
    }

    @Test("a song downloaded and playing from its file is not deleted by removing another")
    func removingAnotherKeepsPlayingFile() async {
        let rig = PlaybackRig()
        defer { rig.cleanUp() }
        #expect(await rig.download(idA))
        #expect(await rig.download(idB))
        rig.service.play(rig.song(idA))
        await rig.settle()

        rig.downloadRig.service.remove(videoId: idB)
        await rig.downloadRig.service.waitUntilIdle()

        #expect(rig.folder.audioFiles == ["\(idA).m4a"])
        #expect(rig.downloadRig.service.state(for: idA) == .downloaded)
    }

    @Test("the kept file goes when playback stops")
    func removePlayingThenStop() async {
        let rig = PlaybackRig()
        defer { rig.cleanUp() }
        #expect(await rig.download(idA))
        rig.service.play(rig.song(idA))
        await rig.settle()
        rig.downloadRig.service.remove(videoId: idA)
        await rig.downloadRig.service.waitUntilIdle()
        #expect(rig.folder.exists(rig.folder.audioURL(idA)))

        rig.service.stop()
        await rig.downloadRig.service.waitUntilIdle()

        #expect(rig.folder.audioFiles.isEmpty)
    }
}
