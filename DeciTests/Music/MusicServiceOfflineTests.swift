// DeciTests/Music/MusicServiceOfflineTests.swift
// The service with no network: a downloaded song plays from its file and asks the backend for nothing (no stream, no
// radio, no tracking URLs, no pings); a song that is not downloaded does not start; a page starts with its downloaded
// songs only; Next and Previous step over what cannot play; and the queue ends at the last downloaded song. Signed out,
// a downloaded song plays all the same. A launch with no network restores a downloaded song from its file. The things
// the network owes are asked once it returns. A fake backend, a fake AVPlayer seam, a fake transport and folders under
// /Volumes/Storage/_test.

import Foundation
import Testing
@testable import Deci

/// The service with a download service on a folder of its own, a session store on another and one connectivity both
/// share, so a test flips the network for the two at once.
@MainActor
struct OfflineRig {
    let backend: FakeMusicBackend
    let engine = FakePlaybackEngine()
    let clock = MutableClock()
    let connectivity: MusicConnectivity
    let downloadRig: DownloadServiceRig
    let sessionFolder = SessionTestFolder()
    let sessionStore: MusicSessionStore
    let player: MusicPlayer
    let service: MusicService

    var folder: DownloadTestFolder { downloadRig.folder }

    /// `pathReported` false is a launch the system has not reported the network for yet (the flag starts online).
    init(signedIn: Bool = true, pathReported: Bool = true) {
        let backend = FakeMusicBackend(signedIn: signedIn)
        self.backend = backend
        let clock = clock
        connectivity = MusicConnectivity(isOnline: true, reported: pathReported)
        downloadRig = DownloadServiceRig(folder: DownloadTestFolder(), connectivity: connectivity)
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
            connectivity: connectivity,
            refreshOnCreate: false
        )
    }

    func cleanUp() {
        sessionStore.waitForWrites()
        sessionFolder.remove()
        downloadRig.cleanUp()
    }

    func goOffline() { connectivity.update(isOnline: false) }
    func goOnline() { connectivity.update(isOnline: true) }

    /// Downloads the song through the fake transport and waits until it is on disk.
    func download(_ id: String) async -> Bool {
        downloadRig.download(id)
        return await downloadRig.settles(id, as: .downloaded)
    }

    func song(_ id: String) -> Deci.MusicTrack { MusicSamples.track(id, title: "Song \(id)") }

    func page(_ ids: [String], continuation: String? = nil) -> MusicBrowsePage {
        MusicBrowsePage(
            browseId: "VLPLoffline", title: "Road trip", subtitle: "Playlist", thumbnailURL: nil,
            tracks: ids.map(song), continuation: continuation, shelves: []
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

    func settleTracking() async {
        await service.trackingTask?.value
    }

    /// Plays the first of `ids` with the rest as its radio, and has the engine report it playing.
    func startQueue(_ ids: [String]) async {
        let tracks = ids.map(song)
        await backend.setRadio(seed: ids[0], tracks: tracks, continuation: nil)
        service.play(tracks[0])
        await settle()
        engine.emit(.playingChanged(true))
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

    var loadedIDs: [String] { engine.loads.map(\.stream.videoId) }
    var queuedIDs: [String] { service.queue.tracks.map(\.videoId) }

    /// Every request the backend could be asked for a queue, counted.
    func queueRequests() async -> Int {
        await backend.radioSeeds.count + backend.autoplayCalls.count + backend.mixCalls.count
            + backend.moreRadioCalls.count + backend.moreTracksCalls.count
    }
}

@MainActor
@Suite("MusicService offline")
struct MusicServiceOfflineTests {
    private let idA = DownloadSamples.idA
    private let idB = DownloadSamples.idB
    private let idC = DownloadSamples.idC
    private let idD = "DDDDDDDDDDD"

    // MARK: - The flag

    @Test("the service and its browse store follow the connectivity")
    func followsConnectivity() {
        let rig = OfflineRig()
        defer { rig.cleanUp() }
        #expect(!rig.service.isOffline)
        #expect(!rig.service.browse.isOffline)

        rig.goOffline()
        #expect(rig.service.isOffline)
        #expect(rig.service.browse.isOffline)

        rig.goOnline()
        #expect(!rig.service.isOffline)
        #expect(!rig.service.browse.isOffline)
    }

    @Test("a service built with no connectivity is online")
    func defaultsToOnline() {
        let service = MusicService(backend: FakeMusicBackend(), refreshOnCreate: false)

        #expect(!service.isOffline)
        #expect(!service.browse.isOffline)
    }

    // MARK: - Playing a downloaded song

    @Test("a downloaded song plays from its file offline, and the backend is asked for nothing")
    func downloadedSongPlaysOffline() async {
        let rig = OfflineRig()
        defer { rig.cleanUp() }
        #expect(await rig.download(idA))
        rig.goOffline()
        #expect(rig.service.isAutoplayOn)

        rig.service.play(rig.song(idA))
        await rig.settle()
        await rig.settleTracking()

        #expect(rig.engine.loads.count == 1)
        #expect(rig.engine.loads.first?.stream.url.path == rig.folder.audioURL(idA).path)
        #expect(await rig.backend.resolvedIDs.isEmpty)
        #expect(await rig.queueRequests() == 0)
        #expect(rig.service.trackingTask == nil)
        #expect(rig.service.radioTask == nil)
        #expect(rig.service.queueRetryTask == nil)
        #expect(rig.service.lastError == nil)
    }

    @Test("a lone downloaded song offline has nothing to go to next")
    func nothingNextOffline() async {
        let rig = OfflineRig()
        defer { rig.cleanUp() }
        #expect(await rig.download(idA))
        rig.goOffline()

        rig.service.play(rig.song(idA))
        await rig.settle()

        #expect(!rig.service.canGoNext)
        #expect(!rig.service.isFillingQueue)
    }

    @Test("a file that fails to play offline gets no retry through the network")
    func noNetworkRetryOffline() async {
        let rig = OfflineRig()
        defer { rig.cleanUp() }
        #expect(await rig.download(idA))
        rig.goOffline()
        rig.service.play(rig.song(idA))
        await rig.settle()

        rig.engine.emit(.failed)
        await rig.player.refreshTask?.value
        await rig.settle()

        #expect(rig.engine.loads.count == 1)
        #expect(await rig.backend.resolvedIDs.isEmpty)
    }

    @Test("a downloaded song whose file vanished does not reach for the network offline, and does not spin")
    func vanishedFileOffline() async throws {
        let rig = OfflineRig()
        defer { rig.cleanUp() }
        #expect(await rig.download(idA))
        try FileManager.default.removeItem(at: rig.folder.audioURL(idA))
        rig.goOffline()

        rig.service.play(rig.song(idA))
        await rig.settle()

        #expect(await rig.backend.resolvedIDs.isEmpty)
        #expect(rig.engine.loads.isEmpty)
        #expect(!rig.player.isLoading)
    }

    // MARK: - A song that is not downloaded

    @Test("a tap on a song that is not downloaded does nothing offline")
    func notDownloadedDoesNotStart() async {
        let rig = OfflineRig()
        defer { rig.cleanUp() }
        #expect(await rig.download(idA))
        rig.goOffline()

        rig.service.play(rig.song(idB))
        await rig.settle()

        #expect(rig.engine.loads.isEmpty)
        #expect(rig.player.nowPlaying == nil)
        #expect(rig.service.queue.isEmpty)
        #expect(await rig.backend.resolvedIDs.isEmpty)
        #expect(await rig.queueRequests() == 0)
    }

    @Test("a tap on a song that is not downloaded leaves the song that is playing alone")
    func notDownloadedLeavesCurrent() async {
        let rig = OfflineRig()
        defer { rig.cleanUp() }
        #expect(await rig.download(idA))
        rig.goOffline()
        rig.service.play(rig.song(idA))
        await rig.settle()

        rig.service.play(rig.song(idB))
        rig.service.play(rig.song(idB), in: rig.page([idB, idA]))
        rig.service.jump(to: rig.song(idB))
        await rig.settle()

        #expect(rig.player.nowPlaying?.videoId == idA)
        #expect(rig.loadedIDs == [idA])
        #expect(rig.service.queue.current?.videoId == idA)
    }

    // MARK: - Pages

    @Test("a page started offline queues only its downloaded songs, with no paging and no radio behind them")
    func pageQueuesDownloadedOnly() async {
        let rig = OfflineRig()
        defer { rig.cleanUp() }
        #expect(await rig.download(idA))
        #expect(await rig.download(idC))
        rig.goOffline()

        rig.service.play(rig.song(idA), in: rig.page([idA, idB, idC, idD], continuation: "more"))
        await rig.settle()

        #expect(rig.queuedIDs == [idA, idC])
        #expect(rig.loadedIDs == [idA])
        #expect(await rig.queueRequests() == 0)

        rig.engine.emit(.playingChanged(true))
        rig.engine.emit(.ended)
        await rig.settle()
        #expect(rig.loadedIDs == [idA, idC])

        rig.engine.emit(.ended)
        await rig.settle()
        #expect(rig.loadedIDs == [idA, idC])
        #expect(await rig.queueRequests() == 0)
        #expect(await rig.backend.resolvedIDs.isEmpty)
    }

    @Test("Shuffle on a page offline starts from one of its downloaded songs")
    func shuffleStartsDownloaded() async {
        let rig = OfflineRig()
        defer { rig.cleanUp() }
        #expect(await rig.download(idA))
        #expect(await rig.download(idC))
        rig.goOffline()

        rig.service.playShuffled(rig.page([idA, idB, idC, idD]))
        await rig.settle()

        #expect(Set(rig.queuedIDs) == [idA, idC])
        #expect([idA, idC].contains(rig.loadedIDs.first ?? ""))
        #expect(rig.loadedIDs.count == 1)
    }

    @Test("a page with nothing downloaded starts nothing offline")
    func pageWithNothingDownloaded() async {
        let rig = OfflineRig()
        defer { rig.cleanUp() }
        rig.goOffline()

        rig.service.playShuffled(rig.page([idA, idB]))
        rig.service.play(rig.song(idA), in: rig.page([idA, idB]))
        await rig.settle()

        #expect(rig.engine.loads.isEmpty)
        #expect(rig.service.queue.isEmpty)
        #expect(rig.player.nowPlaying == nil)
    }

    // MARK: - Next and Previous

    @Test("Next and Previous step over the songs that are not downloaded")
    func stepsOverNotDownloaded() async {
        let rig = OfflineRig()
        defer { rig.cleanUp() }
        #expect(await rig.download(idA))
        #expect(await rig.download(idC))
        await rig.startQueue([idA, idB, idC, idD])
        rig.goOffline()
        #expect(rig.service.canGoNext)

        rig.service.next()
        await rig.settle()
        #expect(rig.loadedIDs == [idA, idC])
        #expect(rig.service.queue.current?.videoId == idC)
        // Only D is left, and it is not downloaded.
        #expect(!rig.service.canGoNext)

        rig.service.previous()
        await rig.settle()
        #expect(rig.loadedIDs == [idA, idC, idA])
        #expect(await rig.backend.resolvedIDs.filter { $0 != idA && $0 != idC }.isEmpty)
    }

    @Test("Previous on the first downloaded song restarts it instead of landing on one that cannot play")
    func previousWithNothingPlayableBehind() async {
        let rig = OfflineRig()
        defer { rig.cleanUp() }
        #expect(await rig.download(idB))
        await rig.startQueue([idA, idB, idC])
        rig.service.next()
        await rig.settle()
        #expect(rig.service.queue.current?.videoId == idB)
        rig.goOffline()

        rig.service.previous()
        await rig.settle()

        #expect(rig.loadedIDs.last == idB)
        #expect(rig.service.queue.current?.videoId == idB)
        #expect(rig.engine.seeks.last == 0)
    }

    @Test("a song that ends offline moves on to the next downloaded song, and at the last one the queue ends there")
    func endsAtLastDownloaded() async {
        let rig = OfflineRig()
        defer { rig.cleanUp() }
        #expect(await rig.download(idA))
        #expect(await rig.download(idB))
        await rig.startQueue([idA, idC, idB, idD])
        let asked = await rig.queueRequests()
        rig.goOffline()

        rig.engine.emit(.ended)
        await rig.settle()
        #expect(rig.loadedIDs == [idA, idB])

        rig.engine.emit(.playingChanged(true))
        rig.engine.emit(.ended)
        await rig.settle()

        #expect(rig.loadedIDs == [idA, idB])
        #expect(rig.player.nowPlaying?.videoId == idB)
        #expect(await rig.queueRequests() == asked)
        #expect(rig.service.radioTask == nil)
    }

    @Test("Loop playlist offline starts over from the first downloaded song")
    func loopWrapsToFirstDownloaded() async {
        let rig = OfflineRig()
        defer { rig.cleanUp() }
        #expect(await rig.download(idB))
        #expect(await rig.download(idC))
        rig.service.setLoopMode(.playlist)
        await rig.startQueue([idA, idB, idC])
        rig.service.jump(to: rig.song(idC))
        await rig.settle()
        rig.goOffline()
        #expect(rig.service.canGoNext)

        rig.engine.emit(.ended)
        await rig.settle()

        #expect(rig.loadedIDs.last == idB)
        #expect(rig.service.queue.current?.videoId == idB)
    }

    // MARK: - Prefetch, radio and top-ups

    @Test("the next song is not prefetched offline when it is not downloaded")
    func noPrefetchOffline() async {
        let rig = OfflineRig()
        defer { rig.cleanUp() }
        #expect(await rig.download(idA))
        await rig.startQueue([idA, idB, idC])
        let resolved = await rig.backend.resolvedIDs
        rig.goOffline()

        rig.engine.tick(186, playing: true)
        await rig.service.prefetchTask?.value

        #expect(await rig.backend.resolvedIDs == resolved)
    }

    @Test("an ask for more songs that was cut by the network is not made again offline, and is made once it returns")
    func radioWaitsForTheNetwork() async {
        let rig = OfflineRig()
        defer { rig.cleanUp() }
        #expect(await rig.download(idA))
        await rig.backend.setRadio(seed: idA, tracks: [rig.song(idA), rig.song(idB)], continuation: nil)
        rig.goOffline()

        rig.service.play(rig.song(idA))
        await rig.settle()
        #expect(await rig.backend.radioSeeds.isEmpty)
        #expect(rig.queuedIDs == [idA])

        rig.goOnline()
        await rig.settle()

        // The radio's first ask is the song that was played; the one that follows, for the song it added, is the radio
        // running on as it always does.
        let seeds = await rig.backend.radioSeeds
        #expect(seeds.first == idA)
        #expect(rig.queuedIDs == [idA, idB])
    }

    // MARK: - History

    private let playbackURL = URL(string: "https://music.example.test/stats/playback?ev=offline")!
    private let watchtimeURL = URL(string: "https://music.example.test/stats/watchtime?ev=offline")!

    @Test("listening offline sends no pings, and no playback ping is kept to send when the network returns")
    func noPingsOffline() async {
        let rig = OfflineRig()
        defer { rig.cleanUp() }
        await rig.backend.setStream(MusicSamples.stream(videoId: idA, trackingURL: playbackURL, watchtimeURL: watchtimeURL))
        #expect(await rig.download(idA))
        rig.service.play(rig.song(idA))
        await rig.settle()
        await rig.settleTracking()
        rig.engine.emit(.playingChanged(true))
        rig.goOffline()

        rig.listen(seconds: 75)
        await rig.service.reportTask?.value
        #expect(await rig.backend.reportAttempts.isEmpty)

        rig.goOnline()
        await rig.service.reportTask?.value
        rig.engine.emit(.ended)
        await rig.service.reportTask?.value

        #expect(await rig.backend.reportAttempts.filter { $0.kind == .playback }.isEmpty)
    }

    // MARK: - Search

    @Test("a search offline asks nothing and does not spin, and runs once the network returns")
    func searchWaitsForTheNetwork() async {
        let rig = OfflineRig()
        defer { rig.cleanUp() }
        await rig.backend.setSearch("dua", results: [rig.song(idA)])
        rig.goOffline()

        rig.service.query = "dua"
        rig.service.search()
        await rig.service.searchTask?.value

        #expect(await rig.backend.searchedQueries.isEmpty)
        #expect(!rig.service.isSearching)
        #expect(rig.service.results.isEmpty)
        #expect(rig.service.lastError == nil)

        rig.goOnline()
        await rig.service.searchTask?.value

        #expect(await rig.backend.searchedQueries == ["dua"])
        #expect(rig.service.results.map(\.videoId) == [idA])
    }

    @Test("clearing the search offline forgets it: nothing runs when the network returns")
    func clearedSearchStaysForgotten() async {
        let rig = OfflineRig()
        defer { rig.cleanUp() }
        rig.goOffline()
        rig.service.query = "dua"
        rig.service.search()

        rig.service.query = ""
        rig.service.search()
        rig.goOnline()
        await rig.service.searchTask?.value

        #expect(await rig.backend.searchedQueries.isEmpty)
        #expect(rig.service.results.isEmpty)
    }

    @Test("a search made online is untouched by the network going")
    func onlineSearchUnaffected() async {
        let rig = OfflineRig()
        defer { rig.cleanUp() }
        await rig.backend.setSearch("dua", results: [rig.song(idA)])
        rig.service.query = "dua"
        rig.service.search()
        await rig.service.searchTask?.value

        rig.goOffline()
        rig.goOnline()
        await rig.service.searchTask?.value

        #expect(await rig.backend.searchedQueries == ["dua"])
        #expect(rig.service.results.map(\.videoId) == [idA])
    }

    // MARK: - Signed out

    @Test("signed out, a downloaded song plays from its file and asks the backend for nothing")
    func signedOutDownloadedPlays() async {
        let rig = OfflineRig()
        defer { rig.cleanUp() }
        #expect(await rig.download(idA))
        await rig.backend.setSignedIn(false)
        await rig.service.refreshAuth()
        #expect(rig.service.authState == .signedOut)
        rig.service.browse.open(MusicBrowseStore.downloadedSongs)

        rig.service.play(rig.song(idA))
        await rig.settle()
        await rig.settleTracking()

        #expect(rig.loadedIDs == [idA])
        #expect(rig.engine.loads.first?.stream.url.path == rig.folder.audioURL(idA).path)
        #expect(await rig.backend.resolvedIDs.isEmpty)
        #expect(await rig.queueRequests() == 0)
        #expect(rig.service.authState == .signedOut)
        // The Downloads page is still open: nothing reset the browse store.
        #expect(rig.service.browse.path.last?.browseId == MusicDownloadService.songsBrowseId)
    }

    @Test("signed out, a downloaded page plays its songs and moves on from file to file")
    func signedOutDownloadedPagePlays() async {
        let rig = OfflineRig()
        defer { rig.cleanUp() }
        #expect(await rig.download(idA))
        #expect(await rig.download(idB))
        await rig.backend.setSignedIn(false)
        await rig.service.refreshAuth()

        rig.service.play(rig.song(idA), in: rig.page([idA, idB]))
        await rig.settle()
        rig.engine.emit(.playingChanged(true))
        rig.engine.emit(.ended)
        await rig.settle()

        #expect(rig.loadedIDs == [idA, idB])
        #expect(await rig.backend.resolvedIDs.isEmpty)
        #expect(await rig.queueRequests() == 0)
    }

    @Test("signed out, a page started from a downloaded song queues only its downloaded songs")
    func signedOutPageQueuesDownloadedOnly() async {
        let rig = OfflineRig()
        defer { rig.cleanUp() }
        #expect(await rig.download(idA))
        #expect(await rig.download(idC))
        await rig.backend.setSignedIn(false)
        await rig.service.refreshAuth()

        rig.service.play(rig.song(idA), in: rig.page([idA, idB, idC, idD], continuation: "more"))
        await rig.settle()
        rig.engine.emit(.playingChanged(true))
        rig.engine.emit(.ended)
        await rig.settle()

        #expect(rig.queuedIDs == [idA, idC])
        #expect(rig.loadedIDs == [idA, idC])
        #expect(await rig.backend.resolvedIDs.isEmpty)
        #expect(await rig.queueRequests() == 0)
    }

    @Test("Play on a page starts from its first song that can play: the first downloaded one offline and signed out")
    func playFirstOfPage() async {
        let rig = OfflineRig()
        defer { rig.cleanUp() }
        #expect(await rig.download(idC))

        rig.goOffline()
        rig.service.playFirst(of: rig.page([idA, idB, idC, idD]))
        await rig.settle()
        #expect(rig.loadedIDs == [idC])
        #expect(rig.queuedIDs == [idC])

        rig.goOnline()
        rig.service.signOut()
        #expect(rig.service.authState == .signedOut)
        rig.service.playFirst(of: rig.page([idA, idB, idC, idD]))
        await rig.settle()
        #expect(rig.loadedIDs == [idC, idC])
        #expect(rig.queuedIDs == [idC])
    }

    @Test("Play on a page online, signed in, starts from the page's first song, downloaded or not")
    func playFirstOnline() async {
        let rig = OfflineRig()
        defer { rig.cleanUp() }
        #expect(await rig.download(idC))
        await rig.backend.setRadio(seed: idA, tracks: [rig.song(idA)], continuation: nil)

        rig.service.playFirst(of: rig.page([idA, idB, idC]))
        await rig.settle()

        #expect(rig.loadedIDs == [idA])
        #expect(rig.queuedIDs.prefix(3) == [idA, idB, idC])
    }

    @Test("Play on a page with nothing downloaded starts nothing offline, and does not crash on an empty page")
    func playFirstNothing() async {
        let rig = OfflineRig()
        defer { rig.cleanUp() }
        rig.goOffline()

        rig.service.playFirst(of: rig.page([idA, idB]))
        rig.service.playFirst(of: rig.page([]))
        await rig.settle()

        #expect(rig.engine.loads.isEmpty)
        #expect(rig.service.queue.isEmpty)
    }

    @Test("signed out, Shuffle on a page starts from one of its downloaded songs")
    func signedOutShuffleDownloaded() async {
        let rig = OfflineRig()
        defer { rig.cleanUp() }
        #expect(await rig.download(idA))
        #expect(await rig.download(idC))
        await rig.backend.setSignedIn(false)
        await rig.service.refreshAuth()

        rig.service.playShuffled(rig.page([idA, idB, idC, idD]))
        await rig.settle()

        #expect(Set(rig.queuedIDs) == [idA, idC])
        #expect([idA, idC].contains(rig.loadedIDs.first ?? ""))
    }

    @Test("the player column shows its controls signed in, and signed out only for a song that plays from its file")
    func showsPlayerControls() async {
        let rig = OfflineRig()
        defer { rig.cleanUp() }
        #expect(await rig.download(idA))
        await rig.service.refreshAuth()
        #expect(rig.service.showsPlayerControls)

        rig.service.signOut()
        #expect(rig.service.authState == .signedOut)
        #expect(!rig.service.showsPlayerControls)

        rig.service.play(rig.song(idA))
        await rig.settle()
        #expect(rig.service.showsPlayerControls)
    }

    @Test("the account returning while a downloaded song plays keeps the song and its queue")
    func signInKeepsPlayback() async {
        let rig = OfflineRig()
        defer { rig.cleanUp() }
        #expect(await rig.download(idA))
        await rig.backend.setSignedIn(false)
        await rig.service.refreshAuth()
        rig.service.play(rig.song(idA))
        await rig.settle()

        await rig.backend.setSignedIn(true)
        await rig.service.refreshAuth()

        #expect(rig.service.authState == .signedIn)
        #expect(rig.player.nowPlaying?.videoId == idA)
        #expect(rig.service.showsPlayerControls)
    }

    @Test("signed out, a song that is not downloaded behaves as it always did")
    func signedOutStreamingUnchanged() async {
        let rig = OfflineRig()
        defer { rig.cleanUp() }
        #expect(await rig.download(idA))
        await rig.backend.setSignedIn(false)
        await rig.service.refreshAuth()

        rig.service.play(rig.song(idB))
        await rig.settle()

        #expect(await rig.backend.resolvedIDs == [idB])
        #expect(await rig.backend.radioSeeds == [idB])
        #expect(rig.loadedIDs == [idB])
    }

    // MARK: - Launching offline

    @Test("a launch with no network restores a downloaded song from its file, paused, with no request at all")
    func restoreOffline() async {
        let rig = OfflineRig()
        defer { rig.cleanUp() }
        #expect(await rig.download(idB))
        rig.seedSession([idA, idB, idC], current: idB)
        // The account cannot be read without a network.
        await rig.backend.setSessionIdentity(nil)
        rig.goOffline()

        rig.service.restoreSession()
        await rig.service.restoreTask?.value
        await rig.settleTracking()

        #expect(rig.engine.loads.count == 1)
        #expect(rig.engine.loads.first?.stream.url.path == rig.folder.audioURL(idB).path)
        #expect(rig.engine.loads.first?.autoplay == false)
        #expect(rig.engine.loads.first?.startAt == 95)
        #expect(rig.service.queue.current?.videoId == idB)
        #expect(rig.service.queue.tracks.count == 3)
        #expect(await rig.backend.resolvedIDs.isEmpty)
        #expect(await rig.queueRequests() == 0)
    }

    @Test("restoring a song that is not downloaded offline loads the queue, and Play moves to the next downloaded song")
    func restoreNotDownloadedOffline() async {
        let rig = OfflineRig()
        defer { rig.cleanUp() }
        #expect(await rig.download(idC))
        rig.seedSession([idA, idB, idC], current: idB)
        await rig.backend.setSessionIdentity(nil)
        rig.goOffline()

        rig.service.restoreSession()
        await rig.service.restoreTask?.value

        #expect(rig.service.queue.current?.videoId == idB)
        #expect(rig.player.nowPlaying?.videoId == idB)
        #expect(!rig.player.isLoading)
        #expect(rig.engine.loads.isEmpty)
        #expect(await rig.backend.resolvedIDs.isEmpty)

        rig.service.resume()
        await rig.settle()

        #expect(rig.loadedIDs == [idC])
        #expect(rig.engine.loads.first?.stream.url.path == rig.folder.audioURL(idC).path)
        #expect(await rig.backend.resolvedIDs.isEmpty)
    }

    @Test("restoring a queue with nothing downloaded offline shows it, and Play finds nothing to play without spinning")
    func restoreNothingPlayableOffline() async {
        let rig = OfflineRig()
        defer { rig.cleanUp() }
        rig.seedSession([idA, idB], current: idA)
        await rig.backend.setSessionIdentity(nil)
        rig.goOffline()

        rig.service.restoreSession()
        await rig.service.restoreTask?.value
        rig.service.resume()
        await rig.settle()

        #expect(rig.engine.loads.isEmpty)
        #expect(!rig.player.isLoading)
        #expect(!rig.player.isPlaying)
        #expect(await rig.backend.resolvedIDs.isEmpty)
        #expect(await rig.queueRequests() == 0)
    }

    @Test("restoring online still resolves a song that is not downloaded")
    func restoreOnlineUnchanged() async {
        let rig = OfflineRig()
        defer { rig.cleanUp() }
        rig.seedSession([idA, idB], current: idB)

        rig.service.restoreSession()
        await rig.service.restoreTask?.value

        #expect(await rig.backend.resolvedIDs == [idB])
        #expect(rig.loadedIDs == [idB])
    }
}
