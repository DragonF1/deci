// DeciTests/Music/MusicServiceTests.swift
// Music tab logic with a fake backend and a fake AVPlayer seam: search, auth, play, the
// 30 s history ping, stream recovery, the sign-in cookie filter and the small formatters.

import Foundation
import Testing
@testable import Deci

// MARK: - Shared setup

@MainActor
private final class SignInProbe {
    var presentCount = 0
    var completion: (@MainActor ([StoredCookie]?) -> Void)?
}

@MainActor
private struct Harness {
    let backend: FakeMusicBackend
    let engine = FakePlaybackEngine()
    let probe = SignInProbe()
    let player: MusicPlayer
    let service: MusicService

    init(signedIn: Bool = true) {
        let backend = FakeMusicBackend(signedIn: signedIn)
        let engine = self.engine
        let probe = self.probe
        let player = MusicPlayer(engine: engine)
        self.backend = backend
        self.player = player
        self.service = MusicService(
            backend: backend,
            player: player,
            presentSignIn: { completion in
                probe.presentCount += 1
                probe.completion = completion
            },
            refreshOnCreate: false
        )
    }

    /// Plays `track` and waits until the player has loaded its stream.
    func startPlaying(_ track: MusicTrack = MusicSamples.track()) async {
        service.play(track)
        await service.playTask?.value
    }

    /// Feeds the 0.5 s position ticks the player would report: a baseline at `start`, then `seconds` of playback.
    func listen(seconds: TimeInterval, from start: TimeInterval = 0, playing: Bool = true) {
        engine.tick(start, playing: playing)
        var position = start
        for _ in 0..<Int(seconds / 0.5) {
            position += 0.5
            engine.tick(position, playing: playing)
        }
    }
}

private func isValidCPN(_ cpn: String) -> Bool {
    cpn.count == 16 && cpn.allSatisfy { CPN.alphabet.contains($0) }
}

// MARK: - Auth

@MainActor
@Suite("MusicService auth")
struct MusicServiceAuthTests {
    @Test("refreshAuth reflects the backend session")
    func refreshAuth() async {
        let signedIn = Harness(signedIn: true)
        #expect(signedIn.service.authState == .unknown)
        await signedIn.service.refreshAuth()
        #expect(signedIn.service.authState == .signedIn)

        let signedOut = Harness(signedIn: false)
        await signedOut.service.refreshAuth()
        #expect(signedOut.service.authState == .signedOut)
    }

    @Test("signIn opens the sign-in window and shows progress")
    func signInShowsProgress() async {
        let h = Harness(signedIn: false)
        h.service.signIn()
        #expect(h.service.authState == .signingIn)
        #expect(h.probe.presentCount == 1)
    }

    @Test("a second signIn while one is open is ignored")
    func signInIsNotReentrant() async {
        let h = Harness(signedIn: false)
        h.service.signIn()
        h.service.signIn()
        #expect(h.probe.presentCount == 1)
    }

    @Test("harvested cookies go to the backend and flip to signedIn")
    func signInSuccess() async {
        let h = Harness(signedIn: false)
        let cookies = [StoredCookie(MusicSamples.cookie("SAPISID", domain: ".youtube.com"))]
        h.service.signIn()
        h.probe.completion?(cookies)
        await h.service.signInTask?.value

        #expect(h.service.authState == .signedIn)
        let sent = await h.backend.signInCookies
        #expect(sent == [cookies])
        #expect(h.service.lastError == nil)
    }

    @Test("closing the window early returns to signedOut without calling the backend")
    func signInCancelled() async {
        let h = Harness(signedIn: false)
        h.service.signIn()
        h.probe.completion?(nil)

        #expect(h.service.authState == .signedOut)
        let sent = await h.backend.signInCookies
        #expect(sent.isEmpty)
    }

    @Test("an empty cookie list counts as cancelled")
    func signInEmptyCookies() async {
        let h = Harness(signedIn: false)
        h.service.signIn()
        h.probe.completion?([])
        #expect(h.service.authState == .signedOut)
    }

    @Test("a backend sign-in failure returns to signedOut with a message")
    func signInFailure() async {
        let h = Harness(signedIn: false)
        await h.backend.setSignInError(MusicError.http(403))
        h.service.signIn()
        h.probe.completion?([StoredCookie(MusicSamples.cookie("SAPISID", domain: ".youtube.com"))])
        await h.service.signInTask?.value

        #expect(h.service.authState == .signedOut)
        #expect(h.service.lastError?.contains("403") == true)
    }

    @Test("signOut wipes the backend, results and playback")
    func signOut() async {
        let h = Harness()
        await h.service.refreshAuth()
        await h.backend.setSearch("q", results: [MusicSamples.track()])
        h.service.query = "q"
        h.service.search()
        await h.service.searchTask?.value
        await h.startPlaying()
        #expect(h.service.results.count == 1)

        h.service.signOut()
        await h.service.signOutTask?.value

        #expect(h.service.authState == .signedOut)
        #expect(h.service.results.isEmpty)
        #expect(h.service.query.isEmpty)
        #expect(h.player.nowPlaying == nil)
        #expect(await h.backend.signOutCount == 1)
    }

    @Test("ticks after signOut never reach the history ping")
    func noPingAfterSignOut() async {
        let h = Harness()
        await h.startPlaying()
        h.listen(seconds: 20)
        h.service.signOut()
        h.listen(seconds: 40, from: 20)
        await h.service.reportTask?.value

        #expect(await h.backend.reportAttempts.isEmpty)
    }
}

// MARK: - Search

@MainActor
@Suite("MusicService search")
struct MusicServiceSearchTests {
    @Test("search fills the results from the backend")
    func searchFillsResults() async {
        let h = Harness()
        let tracks = [MusicSamples.track("a", title: "A"), MusicSamples.track("b", title: "B")]
        await h.backend.setSearch("daft punk", results: tracks)

        h.service.query = "daft punk"
        h.service.search()
        #expect(h.service.isSearching)
        await h.service.searchTask?.value

        #expect(h.service.results == tracks)
        #expect(h.service.isSearching == false)
        #expect(await h.backend.searchedQueries == ["daft punk"])
    }

    @Test("the query is trimmed before it is sent")
    func queryIsTrimmed() async {
        let h = Harness()
        h.service.query = "  around the world \n"
        h.service.search()
        await h.service.searchTask?.value
        #expect(await h.backend.searchedQueries == ["around the world"])
    }

    @Test("an empty query clears the results and skips the backend")
    func emptyQueryClears() async {
        let h = Harness()
        await h.backend.setSearch("x", results: [MusicSamples.track()])
        h.service.query = "x"
        h.service.search()
        await h.service.searchTask?.value
        #expect(h.service.results.count == 1)

        h.service.query = "   "
        h.service.search()

        #expect(h.service.results.isEmpty)
        #expect(h.service.isSearching == false)
        #expect(await h.backend.searchedQueries == ["x"])
    }

    @Test("a newer search replaces one still in flight")
    func newerSearchWins() async {
        let h = Harness()
        let gate = MusicTestGate()
        let slow = [MusicSamples.track("slow")]
        let fast = [MusicSamples.track("fast")]
        await h.backend.setSearch("one", results: slow)
        await h.backend.setSearchGate("one", gate)
        await h.backend.setSearch("two", results: fast)

        h.service.query = "one"
        h.service.search()
        let first = h.service.searchTask
        h.service.query = "two"
        h.service.search()
        await h.service.searchTask?.value
        #expect(h.service.results == fast)

        await gate.open()
        await first?.value
        #expect(h.service.results == fast)
        #expect(h.service.isSearching == false)
    }

    @Test("a signedOut error wipes the backend session, flips authState and shows no error line")
    func searchSignedOut() async {
        let h = Harness()
        await h.service.refreshAuth()
        await h.backend.setSearchError("q", MusicError.signedOut)

        h.service.query = "q"
        h.service.search()
        await h.service.searchTask?.value
        await h.service.signOutTask?.value

        #expect(h.service.authState == .signedOut)
        #expect(h.service.lastError == nil)
        #expect(h.service.isSearching == false)
        #expect(await h.backend.signOutCount == 1)
        #expect(await h.backend.isSignedIn() == false)
    }

    @Test("a cancelled search is dropped without an error line")
    func searchCancelledIsSilent() async {
        let errors: [any Error] = [CancellationError(), URLError(.cancelled)]
        for error in errors {
            let h = Harness()
            await h.service.refreshAuth()
            await h.backend.setSearchError("q", error)

            h.service.query = "q"
            h.service.search()
            await h.service.searchTask?.value

            #expect(h.service.lastError == nil)
            #expect(h.service.isSearching == false)
            #expect(h.service.authState == .signedIn)
        }
    }

    @Test("other errors become one short line and keep the old results")
    func searchFailure() async {
        let h = Harness()
        await h.service.refreshAuth()
        let tracks = [MusicSamples.track()]
        await h.backend.setSearch("ok", results: tracks)
        h.service.query = "ok"
        h.service.search()
        await h.service.searchTask?.value

        await h.backend.setSearchError("bad", URLError(.notConnectedToInternet))
        h.service.query = "bad"
        h.service.search()
        await h.service.searchTask?.value

        #expect(h.service.authState == .signedIn)
        #expect(h.service.results == tracks)
        #expect(h.service.lastError == "Network problem. Check your connection.")
    }
}

// MARK: - Playback and history

@MainActor
@Suite("MusicService playback")
struct MusicServicePlaybackTests {
    @Test("play resolves the stream and hands it to the player")
    func playResolvesAndLoads() async {
        let h = Harness()
        let track = MusicSamples.track("abc", title: "Aerodynamic")
        h.service.play(track)
        #expect(h.player.nowPlaying == track)
        #expect(h.player.isLoading)

        await h.service.playTask?.value

        #expect(await h.backend.resolvedIDs == ["abc"])
        #expect(h.engine.loads.count == 1)
        #expect(h.engine.loads.first?.stream.videoId == "abc")
        #expect(h.engine.loads.first?.autoplay == true)
        #expect(h.player.nowPlaying == track)
    }

    @Test("a signedOut error from resolve wipes the backend session, flips authState and stops the player")
    func playSignedOut() async {
        let h = Harness()
        await h.service.refreshAuth()
        await h.backend.setResolveError("abc", MusicError.signedOut)

        await h.startPlaying(MusicSamples.track("abc"))
        await h.service.signOutTask?.value

        #expect(h.service.authState == .signedOut)
        #expect(h.player.nowPlaying == nil)
        #expect(h.engine.loads.isEmpty)
        #expect(await h.backend.signOutCount == 1)
        #expect(await h.backend.isSignedIn() == false)
    }

    @Test("a signedOut error while the stream is being refreshed signs out too")
    func refreshSignedOut() async {
        let h = Harness()
        await h.service.refreshAuth()
        await h.startPlaying(MusicSamples.track("abc"))
        await h.backend.setResolveError("abc", MusicError.signedOut)

        h.engine.emit(.failed)
        await h.player.refreshTask?.value
        await h.service.signOutTask?.value

        #expect(h.service.authState == .signedOut)
        #expect(await h.backend.signOutCount == 1)
    }

    @Test("a cancelled resolve is dropped without an error line")
    func playCancelledIsSilent() async {
        let errors: [any Error] = [CancellationError(), URLError(.cancelled)]
        for error in errors {
            let h = Harness()
            await h.backend.setResolveError("abc", error)

            await h.startPlaying(MusicSamples.track("abc"))

            #expect(h.service.lastError == nil)
            #expect(h.player.nowPlaying == nil)
        }
    }

    @Test("a cancelled stream refresh shows no error line")
    func refreshCancelledIsSilent() async {
        let h = Harness()
        await h.startPlaying(MusicSamples.track("abc"))
        await h.backend.setResolveError("abc", URLError(.cancelled))

        h.engine.emit(.failed)
        await h.player.refreshTask?.value

        #expect(h.service.lastError == nil)
    }

    @Test("an unplayable track shows YouTube's reason and clears the player")
    func playUnplayable() async {
        let h = Harness()
        await h.backend.setResolveError("abc", MusicError.unplayable("This video is private"))

        await h.startPlaying(MusicSamples.track("abc"))

        #expect(h.service.lastError == "This video is private")
        #expect(h.player.nowPlaying == nil)
        #expect(h.service.authState == .unknown)
    }

    @Test("a resolve that finishes after a newer play is dropped")
    func staleResolveIsIgnored() async {
        let h = Harness()
        let gate = MusicTestGate()
        await h.backend.setResolveGate("old", gate)

        h.service.play(MusicSamples.track("old"))
        let stale = h.service.playTask
        await h.startPlaying(MusicSamples.track("new"))
        await gate.open()
        await stale?.value

        #expect(h.engine.loads.map(\.stream.videoId) == ["new"])
        #expect(h.player.nowPlaying?.videoId == "new")
    }

    @Test("30 s of listening sends exactly one history ping with a valid CPN")
    func historyPingOnce() async {
        let h = Harness()
        let trackingURL = URL(string: "https://music.example.test/stats?ev=7")!
        await h.backend.setStream(MusicSamples.stream(videoId: "abc", trackingURL: trackingURL))
        await h.startPlaying(MusicSamples.track("abc"))

        h.listen(seconds: 29.5)
        #expect(h.service.reportTask == nil)

        h.listen(seconds: 90, from: 29.5)
        await h.service.reportTask?.value

        let reports = await h.backend.reportAttempts
        #expect(reports.count == 1)
        #expect(reports.first?.url == trackingURL)
        #expect(isValidCPN(reports.first?.cpn ?? ""))
    }

    @Test("no ping before 30 s")
    func noEarlyPing() async {
        let h = Harness()
        await h.startPlaying()
        h.listen(seconds: 29)
        #expect(h.service.reportTask == nil)
        #expect(await h.backend.reportAttempts.isEmpty)
    }

    @Test("paused or stalled ticks never earn a ping")
    func pausedDoesNotPing() async {
        let h = Harness()
        await h.startPlaying()
        h.listen(seconds: 120, playing: false)
        #expect(h.service.reportTask == nil)
    }

    @Test("a seek does not count as listening")
    func seekDoesNotPing() async {
        let h = Harness()
        await h.startPlaying()
        for position in stride(from: 0.0, through: 600.0, by: 60.0) {
            h.engine.tick(position, playing: true)
        }
        #expect(h.service.reportTask == nil)
    }

    @Test("each play gets its own CPN and its own ping")
    func newCPNPerPlay() async {
        let h = Harness()
        await h.startPlaying(MusicSamples.track("a"))
        h.listen(seconds: 31)
        await h.service.reportTask?.value
        await h.startPlaying(MusicSamples.track("b"))
        h.listen(seconds: 31)
        await h.service.reportTask?.value

        let reports = await h.backend.reportAttempts
        #expect(reports.count == 2)
        #expect(reports.allSatisfy { isValidCPN($0.cpn) })
        #expect(Set(reports.map(\.cpn)).count == 2)
    }

    @Test("replaying the same track starts a fresh session")
    func replayStartsFreshSession() async {
        let h = Harness()
        let track = MusicSamples.track("a")
        await h.startPlaying(track)
        h.listen(seconds: 20)
        await h.startPlaying(track)
        h.listen(seconds: 20)
        #expect(h.service.reportTask == nil)
        h.listen(seconds: 20, from: 20)
        await h.service.reportTask?.value
        #expect(await h.backend.reportAttempts.count == 1)
    }

    @Test("a stream without a tracking URL sends no ping")
    func noTrackingURL() async {
        let h = Harness()
        await h.backend.setStream(MusicSamples.stream(videoId: "abc", trackingURL: nil))
        await h.startPlaying(MusicSamples.track("abc"))
        h.listen(seconds: 60)
        #expect(h.service.reportTask == nil)
        #expect(await h.backend.reportAttempts.isEmpty)
    }

    @Test("a tracking URL that arrives after 30 s still earns the one ping")
    func lateTrackingURLPings() async {
        let h = Harness()
        let trackingURL = URL(string: "https://music.example.test/stats?ev=9")!
        await h.backend.setStream(MusicSamples.stream(videoId: "abc", trackingURL: nil))
        await h.startPlaying(MusicSamples.track("abc"))
        h.listen(seconds: 40)
        #expect(h.service.reportTask == nil)

        await h.backend.setStream(MusicSamples.stream(videoId: "abc", trackingURL: trackingURL))
        h.engine.emit(.failed)
        await h.player.refreshTask?.value
        await h.service.reportTask?.value

        let reports = await h.backend.reportAttempts
        #expect(reports.count == 1)
        #expect(reports.first?.url == trackingURL)
        #expect(isValidCPN(reports.first?.cpn ?? ""))

        h.listen(seconds: 60, from: 40)
        await h.service.reportTask?.value
        #expect(await h.backend.reportAttempts.count == 1)
    }

    @Test("a tracking URL that arrives before 30 s waits for the threshold")
    func earlyTrackingURLWaits() async {
        let h = Harness()
        let trackingURL = URL(string: "https://music.example.test/stats?ev=9")!
        await h.backend.setStream(MusicSamples.stream(videoId: "abc", trackingURL: nil))
        await h.startPlaying(MusicSamples.track("abc"))
        h.listen(seconds: 10)

        await h.backend.setStream(MusicSamples.stream(videoId: "abc", trackingURL: trackingURL))
        h.engine.emit(.failed)
        await h.player.refreshTask?.value
        #expect(h.service.reportTask == nil)

        h.listen(seconds: 60, from: 10)
        await h.service.reportTask?.value
        let reports = await h.backend.reportAttempts
        #expect(reports.map(\.url) == [trackingURL])
    }

    @Test("a failing ping is not retried")
    func failedPingNotRetried() async {
        let h = Harness()
        await h.backend.setReportError(URLError(.timedOut))
        await h.startPlaying()
        h.listen(seconds: 120)
        await h.service.reportTask?.value
        #expect(await h.backend.reportAttempts.count == 1)
    }

    @Test("ticks with nothing playing are ignored")
    func ticksWithoutSession() async {
        let h = Harness()
        h.service.handlePlaybackTick(position: 1, isPlaying: true)
        h.service.handlePlaybackTick(position: 100, isPlaying: true)
        #expect(h.service.reportTask == nil)
    }

    @Test("a dead stream is re-resolved through the backend once")
    func recoveryResolvesAgain() async {
        let h = Harness()
        await h.startPlaying(MusicSamples.track("abc"))
        h.engine.tick(12, playing: true)

        h.engine.emit(.failed)
        await h.player.refreshTask?.value

        #expect(await h.backend.resolvedIDs == ["abc", "abc"])
        #expect(h.engine.loads.count == 2)
        #expect(h.engine.loads.last?.startAt == 12)
    }

    @Test("stop silences the player and drops the session")
    func stopEndsPlayback() async {
        let h = Harness()
        await h.startPlaying()
        h.service.stop()
        h.listen(seconds: 60)
        #expect(h.player.nowPlaying == nil)
        #expect(h.service.reportTask == nil)
    }
}

// MARK: - Host

@MainActor
@Suite("MusicServiceHost")
struct MusicServiceHostTests {
    @MainActor
    private final class Counter {
        var builds = 0
        var engine: FakePlaybackEngine?
    }

    private func makeHost(_ counter: Counter) -> MusicServiceHost {
        MusicServiceHost(makeService: {
            counter.builds += 1
            let engine = FakePlaybackEngine()
            counter.engine = engine
            return MusicService(
                backend: FakeMusicBackend(),
                player: MusicPlayer(engine: engine),
                presentSignIn: { _ in },
                refreshOnCreate: false
            )
        })
    }

    @Test("nothing is built until the Music tab is opened")
    func lazy() {
        let counter = Counter()
        let host = makeHost(counter)
        #expect(host.service == nil)
        #expect(counter.builds == 0)
    }

    @Test("loadIfNeeded builds the service once")
    func buildsOnce() {
        let counter = Counter()
        let host = makeHost(counter)
        host.loadIfNeeded()
        let first = host.service
        host.loadIfNeeded()
        #expect(first != nil)
        #expect(host.service === first)
        #expect(counter.builds == 1)
    }

    @Test("shutdown before the tab was ever opened is a no-op")
    func shutdownWithoutService() {
        let counter = Counter()
        let host = makeHost(counter)
        host.shutdown()
        #expect(host.service == nil)
        #expect(counter.builds == 0)
    }

    @Test("shutdown stops playback")
    func shutdownStopsPlayback() async throws {
        let counter = Counter()
        let host = makeHost(counter)
        host.loadIfNeeded()
        let service = try #require(host.service)
        service.play(MusicSamples.track())
        await service.playTask?.value
        #expect(service.player.nowPlaying != nil)

        host.shutdown()

        #expect(service.player.nowPlaying == nil)
        #expect((counter.engine?.unloadCount ?? 0) > 0)
    }
}

// MARK: - Player

@MainActor
@Suite("MusicPlayer")
struct MusicPlayerTests {
    @MainActor
    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    @MainActor
    private final class FreshStreams {
        var calls: [String] = []
        var result: Result<ResolvedStream, any Error>
        var gate: MusicTestGate?

        init(_ result: Result<ResolvedStream, any Error>) {
            self.result = result
        }
    }

    private struct Rig {
        let engine = FakePlaybackEngine()
        let clock = Clock()
        let fresh: FreshStreams
        let player: MusicPlayer

        init(fresh: Result<ResolvedStream, any Error>? = nil) {
            let engine = self.engine
            let clock = self.clock
            let streams = FreshStreams(fresh ?? .success(MusicSamples.stream(expiresAt: clock.now.addingTimeInterval(3600))))
            self.fresh = streams
            let player = MusicPlayer(engine: engine, now: { clock.now })
            player.onNeedsFreshStream = { track in
                streams.calls.append(track.videoId)
                if let gate = streams.gate { await gate.wait() }
                return try streams.result.get()
            }
            self.player = player
        }

        func load(_ track: MusicTrack = MusicSamples.track(), expiresIn seconds: TimeInterval = 3600) {
            let stream = MusicSamples.stream(videoId: track.videoId, expiresAt: clock.now.addingTimeInterval(seconds))
            player.load(stream: stream, track: track)
        }
    }

    @Test("load starts playback and shows loading until the engine is playing")
    func loadShowsLoading() {
        let rig = Rig()
        rig.load()
        #expect(rig.engine.loads.count == 1)
        #expect(rig.engine.loads.first?.autoplay == true)
        #expect(rig.engine.loads.first?.startAt == 0)
        #expect(rig.player.isLoading)
        #expect(rig.player.isPlaying == false)

        rig.engine.emit(.playingChanged(true))
        #expect(rig.player.isPlaying)
        #expect(rig.player.isLoading == false)
    }

    @Test("the engine's duration replaces the estimate and ticks move the clock")
    func durationAndTicks() {
        let rig = Rig()
        rig.load()
        rig.engine.emit(.ready(duration: 187))
        rig.engine.tick(42.5, playing: true)
        #expect(rig.player.duration == 187)
        #expect(rig.player.currentTime == 42.5)
    }

    @Test("beginLoading shows the track and silences the previous one")
    func beginLoading() {
        let rig = Rig()
        rig.load(MusicSamples.track("old"))
        rig.engine.tick(30, playing: true)
        let before = rig.engine.unloadCount

        rig.player.beginLoading(MusicSamples.track("next", seconds: 245))

        #expect(rig.engine.unloadCount == before + 1)
        #expect(rig.player.nowPlaying?.videoId == "next")
        #expect(rig.player.isLoading)
        #expect(rig.player.currentTime == 0)
        #expect(rig.player.duration == 245)
    }

    @Test("a failed stream is re-resolved once and resumes at the same position")
    func failureRecovers() async {
        let rig = Rig()
        rig.load()
        rig.engine.emit(.playingChanged(true))
        rig.engine.tick(42, playing: true)

        rig.engine.emit(.failed)
        #expect(rig.player.isLoading)
        await rig.player.refreshTask?.value

        #expect(rig.fresh.calls == ["vid1"])
        #expect(rig.engine.loads.count == 2)
        #expect(rig.engine.loads.last?.startAt == 42)
        #expect(rig.engine.loads.last?.autoplay == true)
        #expect(rig.player.error == nil)
    }

    @Test("a second failure on the recovered stream gives up")
    func secondFailureGivesUp() async {
        let rig = Rig()
        rig.load()
        rig.engine.emit(.failed)
        await rig.player.refreshTask?.value

        rig.engine.emit(.failed)

        #expect(rig.fresh.calls.count == 1)
        #expect(rig.engine.loads.count == 2)
        #expect(rig.player.error == "Couldn't play this track.")
        #expect(rig.player.isLoading == false)
        #expect(rig.player.isPlaying == false)
    }

    @Test("a failed refresh surfaces an error instead of looping")
    func refreshFailureSurfaces() async {
        let rig = Rig(fresh: .failure(MusicError.http(500)))
        rig.load()
        rig.engine.emit(.failed)
        await rig.player.refreshTask?.value

        #expect(rig.fresh.calls.count == 1)
        #expect(rig.engine.loads.count == 1)
        #expect(rig.player.error == "Couldn't reload this track.")
        #expect(rig.player.isLoading == false)
    }

    @Test("a failure while a refresh is in flight does not start a second one")
    func failureDuringRefresh() async {
        let rig = Rig()
        let gate = MusicTestGate()
        rig.fresh.gate = gate
        rig.load()
        rig.engine.emit(.failed)
        let inFlight = rig.player.refreshTask
        rig.engine.emit(.failed)
        await gate.open()
        await inFlight?.value

        #expect(rig.fresh.calls.count == 1)
        #expect(rig.engine.loads.count == 2)
        #expect(rig.player.error == nil)
    }

    @Test("resuming after the stream expired fetches a fresh one first")
    func expiredStreamIsRefreshedOnResume() async {
        let rig = Rig()
        rig.load(expiresIn: 100)
        rig.engine.emit(.playingChanged(true))
        rig.engine.tick(10, playing: true)
        rig.player.pause()
        rig.clock.now = rig.clock.now.addingTimeInterval(500)

        rig.player.play()
        await rig.player.refreshTask?.value

        #expect(rig.fresh.calls == ["vid1"])
        #expect(rig.engine.loads.count == 2)
        #expect(rig.engine.loads.last?.startAt == 10)
        #expect(rig.engine.loads.last?.autoplay == true)
        #expect(rig.engine.playCount == 0)
    }

    @Test("resuming a still-valid stream just plays")
    func validStreamResumes() {
        let rig = Rig()
        rig.load()
        rig.player.pause()
        rig.player.play()

        #expect(rig.fresh.calls.isEmpty)
        #expect(rig.engine.loads.count == 1)
        #expect(rig.engine.playCount == 1)
    }

    @Test("pressing play after an error retries with a fresh stream")
    func playAfterErrorRetries() async {
        let rig = Rig()
        rig.load()
        rig.engine.emit(.failed)
        await rig.player.refreshTask?.value
        rig.engine.emit(.failed)
        #expect(rig.player.error != nil)

        rig.player.play()
        await rig.player.refreshTask?.value

        #expect(rig.fresh.calls.count == 2)
        #expect(rig.engine.loads.count == 3)
        #expect(rig.player.error == nil)
    }

    @Test("a refresh that finishes after a newer load is dropped")
    func staleRefreshIsIgnored() async {
        let rig = Rig()
        let gate = MusicTestGate()
        rig.fresh.gate = gate
        rig.load(MusicSamples.track("old"))
        rig.engine.emit(.failed)
        let stale = rig.player.refreshTask

        rig.load(MusicSamples.track("new"))
        await gate.open()
        await stale?.value

        #expect(rig.engine.loads.map(\.stream.videoId) == ["old", "new"])
        #expect(rig.player.nowPlaying?.videoId == "new")
    }

    @Test("toggle pauses while playing and resumes when paused")
    func toggle() {
        let rig = Rig()
        rig.load()
        rig.engine.emit(.playingChanged(true))

        rig.player.toggle()
        #expect(rig.engine.pauseCount == 1)
        rig.engine.emit(.playingChanged(false))

        rig.player.toggle()
        #expect(rig.engine.playCount == 1)
    }

    @Test("play at the end of a track restarts it")
    func replayAfterEnd() {
        let rig = Rig()
        rig.load()
        rig.engine.emit(.ready(duration: 200))
        rig.engine.emit(.playingChanged(true))
        rig.engine.emit(.ended)

        #expect(rig.player.isPlaying == false)
        #expect(rig.player.currentTime == 200)

        rig.player.play()

        #expect(rig.engine.seeks == [0])
        #expect(rig.engine.playCount == 1)
        #expect(rig.player.currentTime == 0)
    }

    @Test("stop unloads the engine and clears the state")
    func stop() {
        let rig = Rig()
        rig.load()
        rig.engine.emit(.playingChanged(true))
        let before = rig.engine.unloadCount

        rig.player.stop()

        #expect(rig.engine.unloadCount == before + 1)
        #expect(rig.player.nowPlaying == nil)
        #expect(rig.player.isPlaying == false)
        #expect(rig.player.isLoading == false)
        #expect(rig.player.error == nil)
    }

    @Test("ticks reach the service callback with the play state")
    func ticksForwarded() {
        let rig = Rig()
        var seen: [(TimeInterval, Bool)] = []
        rig.player.onTick = { position, playing in seen.append((position, playing)) }
        rig.load()
        rig.engine.tick(1, playing: true)
        rig.engine.tick(1.5, playing: false)

        #expect(seen.count == 2)
        #expect(seen.first?.0 == 1)
        #expect(seen.first?.1 == true)
        #expect(seen.last?.1 == false)
    }
}

// MARK: - Messages

@MainActor
@Suite("MusicService messages")
struct MusicServiceMessageTests {
    @Test("errors map to short human lines")
    func messages() {
        #expect(MusicService.message(for: MusicError.signedOut) == "Signed out. Sign in again.")
        #expect(MusicService.message(for: MusicError.http(503)).contains("503"))
        #expect(MusicService.message(for: MusicError.parse("anything")) == "Couldn't read YouTube Music's response.")
        #expect(MusicService.message(for: MusicError.noAudioFormat) == "No audio stream for this track.")
        #expect(MusicService.message(for: MusicError.solver("detail")) == "Couldn't prepare the stream. Try again.")
        #expect(MusicService.message(for: URLError(.timedOut)) == "Network problem. Check your connection.")
        #expect(MusicService.message(for: CocoaError(.fileNoSuchFile)) == "Something went wrong. Try again.")
    }

    @Test("an unplayable reason is shown, trimmed and capped")
    func unplayableReason() {
        #expect(MusicService.message(for: MusicError.unplayable("  Private video \n")) == "Private video")
        #expect(MusicService.message(for: MusicError.unplayable("   ")) == "This track can't be played.")
        let long = String(repeating: "x", count: 300)
        #expect(MusicService.message(for: MusicError.unplayable(long)).count == 80)
    }

    @Test("log descriptions carry the kind only, never payloads")
    func logDescriptionsAreSafe() {
        let secret = "https://example.test/watch?v=abc SAPISID=hunter2"
        #expect(MusicService.logDescription(of: MusicError.unplayable(secret)) == "unplayable")
        #expect(MusicService.logDescription(of: MusicError.parse(secret)) == "parse")
        #expect(MusicService.logDescription(of: MusicError.solver(secret)) == "solver")
        #expect(MusicService.logDescription(of: MusicError.http(429)) == "http 429")
        #expect(MusicService.logDescription(of: MusicError.signedOut) == "signedOut")
    }
}

// MARK: - Sign-in window helpers

@MainActor
@Suite("MusicSignInWindowController helpers")
struct MusicSignInHelperTests {
    typealias Controller = MusicSignInWindowController

    @Test("the sign-in URL lands on music.youtube.com after login")
    func signInURL() throws {
        let components = try #require(URLComponents(url: Controller.signInURL, resolvingAgainstBaseURL: false))
        #expect(components.host == "accounts.google.com")
        let target = components.queryItems?.first { $0.name == "continue" }?.value
        #expect(target == "https://music.youtube.com/")
    }

    @Test("the browser identity looks like current Safari on macOS")
    func userAgent() {
        #expect(Controller.userAgent.contains("Macintosh"))
        #expect(Controller.userAgent.contains("Safari/"))
        #expect(Controller.userAgent.contains("Version/26"))
    }

    @Test("the document-start script hides WebAuthn")
    func passkeyScript() {
        #expect(Controller.hidePasskeysScript.contains("PublicKeyCredential"))
        #expect(Controller.hidePasskeysScript.contains("delete window.PublicKeyCredential"))
    }

    @Test("only music.youtube.com counts as the signed-in landing page")
    func musicHost() {
        #expect(Controller.isMusicHost(URL(string: "https://music.youtube.com/")))
        #expect(Controller.isMusicHost(URL(string: "https://MUSIC.youtube.com/watch?v=1")))
        #expect(Controller.isMusicHost(URL(string: "https://accounts.google.com/signin")) == false)
        #expect(Controller.isMusicHost(URL(string: "https://www.youtube.com/")) == false)
        #expect(Controller.isMusicHost(URL(string: "https://music.youtube.com.evil.test/")) == false)
        #expect(Controller.isMusicHost(nil) == false)
    }

    @Test("SAPISID or __Secure-3PAPISID on a youtube.com domain marks a session")
    func sessionCookie() {
        let sapisid = MusicSamples.cookie("SAPISID", domain: ".youtube.com")
        let secure = MusicSamples.cookie("__Secure-3PAPISID", domain: "music.youtube.com")
        let other = MusicSamples.cookie("NID", domain: ".youtube.com")
        #expect(Controller.hasSessionCookie([sapisid]))
        #expect(Controller.hasSessionCookie([other, secure]))
        #expect(Controller.hasSessionCookie([other]) == false)
        #expect(Controller.hasSessionCookie([]) == false)
    }

    @Test("a SAPISID that only exists on google.com is not a session yet")
    func googleSessionCookieIsNotEnough() {
        let google = MusicSamples.cookie("SAPISID", domain: ".google.com")
        let googleSecure = MusicSamples.cookie("__Secure-3PAPISID", domain: "accounts.google.com")
        #expect(Controller.hasSessionCookie([google, googleSecure]) == false)
        #expect(Controller.hasSessionCookie([google, MusicSamples.cookie("SAPISID", domain: ".youtube.com")]))
    }

    @Test("harvest keeps only YouTube cookies and maps every field")
    func harvest() throws {
        let keep = MusicSamples.cookie("SAPISID", domain: ".youtube.com")
        let keepMusic = MusicSamples.cookie("VISITOR_INFO1_LIVE", domain: "music.youtube.com")
        let dropGoogle = MusicSamples.cookie("SID", domain: ".google.com")
        let dropAccounts = MusicSamples.cookie("NID", domain: "accounts.google.com")
        let drop = MusicSamples.cookie("tracker", domain: ".ads.example.com")

        let stored = Controller.harvest([dropGoogle, keep, drop, dropAccounts, keepMusic])

        #expect(stored.map(\.name) == ["SAPISID", "VISITOR_INFO1_LIVE"])
        let first = try #require(stored.first)
        #expect(first.value == "v")
        #expect(first.domain == ".youtube.com")
        #expect(first.path == "/")
    }
}

// MARK: - Formatters

@MainActor
@Suite("MusicTimeFormat")
struct MusicTimeFormatTests {
    @Test("m:ss and h:mm:ss", arguments: [
        (0.0, "0:00"), (5.0, "0:05"), (59.9, "0:59"), (65.0, "1:05"), (600.0, "10:00"),
        (3599.0, "59:59"), (3600.0, "1:00:00"), (3725.0, "1:02:05"),
    ])
    func formatting(seconds: Double, expected: String) {
        #expect(MusicTimeFormat.string(seconds) == expected)
    }

    @Test("negative and non-finite values read as zero")
    func invalid() {
        #expect(MusicTimeFormat.string(-4) == "0:00")
        #expect(MusicTimeFormat.string(.nan) == "0:00")
        #expect(MusicTimeFormat.string(.infinity) == "0:00")
    }

    @Test("progress is clamped and zero without a duration")
    func progress() {
        #expect(MusicTimeFormat.progress(current: 50, duration: 200) == 0.25)
        #expect(MusicTimeFormat.progress(current: 250, duration: 200) == 1)
        #expect(MusicTimeFormat.progress(current: -5, duration: 200) == 0)
        #expect(MusicTimeFormat.progress(current: 10, duration: 0) == 0)
        #expect(MusicTimeFormat.progress(current: .nan, duration: 200) == 0)
    }
}
