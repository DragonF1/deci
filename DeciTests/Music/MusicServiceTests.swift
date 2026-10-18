// DeciTests/Music/MusicServiceTests.swift
// Music tab logic with a fake backend and a fake AVPlayer seam: search, auth, play, the
// 30 s history ping, stream recovery, the radio queue, seek, Now Playing, the sign-in cookie
// filter and the small formatters.

import Foundation
import Testing
@testable import Deci

// MARK: - Shared setup

@MainActor
private final class SignInProbe {
    var presentCount = 0
    var completion: (@MainActor ([StoredCookie]?) -> Void)?
    /// The session each channel picker opened on, and the last picker's completion.
    var pickerSessions: [[StoredCookie]] = []
    var pickerCompletion: (@MainActor ([StoredCookie]?) -> Void)?
    var windowCloses = 0
    /// Every value `onNativePlayingChange` reported, in order.
    var nativeChanges: [Bool] = []
}

@MainActor
private struct Harness {
    let backend: FakeMusicBackend
    let engine = FakePlaybackEngine()
    let probe = SignInProbe()
    let surface = FakeNowPlayingSurface()
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
            presentChannelPicker: { session, completion in
                probe.pickerSessions.append(session)
                probe.pickerCompletion = completion
            },
            closeSignInWindow: { probe.windowCloses += 1 },
            nowPlaying: NowPlayingController(surface: surface, fetchArtwork: { _ in nil }),
            refreshOnCreate: false
        )
        service.onNativePlayingChange = { probe.nativeChanges.append($0) }
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

    /// Plays `track` with its radio and waits for both. The engine reports the track as playing.
    func startQueue(_ ids: [String], continuation: String? = nil) async {
        let tracks = ids.map { MusicSamples.track($0, title: "Song \($0)") }
        await backend.setRadio(seed: ids[0], tracks: tracks, continuation: continuation)
        service.play(tracks[0])
        await settle()
        engine.emit(.playingChanged(true))
    }

    var queuedIDs: [String] { service.queue.tracks.map(\.videoId) }
    var loadedIDs: [String] { engine.loads.map(\.stream.videoId) }

    /// Polls until `condition` holds; for work that is held at a gate and cannot be awaited.
    func eventually(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<400 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
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

    @Test("refreshAuth and sign-in read which channel the session plays as")
    func channelIdentity() async {
        let h = Harness(signedIn: true)
        await h.backend.setChannelIdentity(false)
        await h.service.refreshAuth()
        await h.service.identityTask?.value
        #expect(h.service.isBrandChannel == false)

        h.service.signOut()
        #expect(h.service.isBrandChannel == nil)

        await h.backend.setChannelIdentity(true)
        h.service.signIn()
        h.probe.completion?([StoredCookie(MusicSamples.cookie("SAPISID", domain: ".youtube.com"))])
        await h.service.signInTask?.value
        await h.service.identityTask?.value
        #expect(h.service.isBrandChannel == true)
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


// MARK: - Channel switch

@MainActor
@Suite("MusicService channel switch")
struct MusicServiceChannelSwitchTests {
    private static let current = [StoredCookie(MusicSamples.cookie("SAPISID", domain: ".youtube.com"))]
    private static let picked = [StoredCookie(MusicSamples.cookie("__Secure-3PAPISID", domain: ".youtube.com"))]

    private func signedInHarness() async -> Harness {
        let h = Harness(signedIn: true)
        await h.backend.setSessionCookies(Self.current)
        await h.backend.setChannelIdentity(false)
        await h.service.refreshAuth()
        await h.service.identityTask?.value
        return h
    }

    @Test("switchChannel opens the picker on the current session and keeps the picked one")
    func switchKeepsPick() async {
        let h = await signedInHarness()
        h.service.channelNoticeDismissed = true
        h.service.switchChannel()
        await h.service.channelSwitchTask?.value
        #expect(h.probe.pickerSessions == [Self.current])
        #expect(h.service.isSwitchingChannel)

        await h.backend.setChannelIdentity(true)
        h.probe.pickerCompletion?(Self.picked)
        await h.service.channelSwitchTask?.value
        await h.service.identityTask?.value

        #expect(await h.backend.signInCookies == [Self.picked])
        #expect(h.service.authState == .signedIn)
        #expect(h.service.isBrandChannel == true)
        #expect(!h.service.isSwitchingChannel)
        #expect(!h.service.channelNoticeDismissed)
        #expect(h.service.lastError == nil)
    }

    @Test("closing the picker keeps the session as it was")
    func closeKeepsSession() async {
        let h = await signedInHarness()
        h.service.switchChannel()
        await h.service.channelSwitchTask?.value
        h.probe.pickerCompletion?(nil)

        #expect(await h.backend.signInCookies.isEmpty)
        #expect(h.service.authState == .signedIn)
        #expect(h.service.isBrandChannel == false)
        #expect(!h.service.isSwitchingChannel)
    }

    @Test("a second switchChannel while the picker is open is ignored")
    func secondSwitchIgnored() async {
        let h = await signedInHarness()
        h.service.switchChannel()
        await h.service.channelSwitchTask?.value
        h.service.switchChannel()
        await h.service.channelSwitchTask?.value
        #expect(h.probe.pickerSessions.count == 1)
    }

    @Test("a failed switch keeps the session and says so")
    func failedSwitch() async {
        let h = await signedInHarness()
        await h.backend.setSignInError(MusicError.signedOut)
        h.service.switchChannel()
        await h.service.channelSwitchTask?.value
        h.probe.pickerCompletion?(Self.picked)
        await h.service.channelSwitchTask?.value

        #expect(h.service.authState == .signedIn)
        #expect(h.service.lastError?.contains("Still playing as before") == true)
        #expect(!h.service.isSwitchingChannel)
    }

    @Test("a sign-out while the picker is open drops the pick")
    func signOutDropsPick() async {
        let h = await signedInHarness()
        h.service.switchChannel()
        await h.service.channelSwitchTask?.value
        h.service.signOut()
        #expect(h.probe.windowCloses == 1)
        h.probe.pickerCompletion?(Self.picked)
        await h.service.channelSwitchTask?.value

        #expect(await h.backend.signInCookies.isEmpty)
        #expect(h.service.authState == .signedOut)
        #expect(!h.service.isSwitchingChannel)
    }

    @Test("switchChannel does nothing while signed out")
    func signedOutIgnored() async {
        let h = Harness(signedIn: false)
        await h.service.refreshAuth()
        h.service.switchChannel()
        await h.service.channelSwitchTask?.value
        #expect(h.probe.pickerSessions.isEmpty)
        #expect(!h.service.isSwitchingChannel)
    }
}
// MARK: - Account

@MainActor
@Suite("MusicService account")
struct MusicServiceAccountTests {
    private static let alice = MusicAccount(
        name: "Test Listener", handle: "@testlistener", photoURL: URL(string: "https://photos.example.test/alice")
    )
    private static let brand = MusicAccount(name: "Test Brand", handle: "@testbrand", photoURL: nil)
    private static let current = [StoredCookie(MusicSamples.cookie("SAPISID", domain: ".youtube.com"))]
    private static let picked = [StoredCookie(MusicSamples.cookie("__Secure-3PAPISID", domain: ".youtube.com"))]

    /// Signed in, with the account menu answering `alice` and everything refreshed.
    private func signedInHarness(account: MusicAccount? = alice) async -> Harness {
        let h = Harness(signedIn: true)
        await h.backend.setSessionCookies(Self.current)
        await h.backend.setChannelIdentity(false)
        await h.backend.setAccount(account)
        await h.service.refreshAuth()
        await h.service.identityTask?.value
        await h.service.accountTask?.value
        #expect(h.service.account == account)
        return h
    }

    // MARK: Loading

    @Test("the account loads where the channel identity does: refreshAuth")
    func loadsOnRefreshAuth() async {
        let h = Harness(signedIn: true)
        await h.backend.setAccount(Self.alice)
        #expect(h.service.account == nil)
        await h.service.refreshAuth()
        await h.service.accountTask?.value
        #expect(h.service.account == Self.alice)
        #expect(h.service.lastError == nil)
    }

    @Test("the account loads after a sign-in")
    func loadsAfterSignIn() async {
        let h = Harness(signedIn: false)
        await h.service.refreshAuth()
        await h.backend.setAccount(Self.alice)
        h.service.signIn()
        h.probe.completion?(Self.current)
        await h.service.signInTask?.value
        await h.service.accountTask?.value
        #expect(h.service.account == Self.alice)
    }

    @Test("signed out never asks for the account")
    func signedOutAsksNothing() async {
        let h = Harness(signedIn: false)
        await h.backend.setAccount(Self.alice)
        await h.service.refreshAuth()
        await h.service.accountTask?.value
        #expect(h.service.account == nil)
        #expect(await h.backend.accountCallCount == 0)
    }

    @Test("a menu with no account header leaves the account nil")
    func nilAccount() async {
        let h = await signedInHarness(account: nil)
        #expect(h.service.account == nil)
        #expect(h.service.lastError == nil)
        #expect(h.service.authState == .signedIn)
    }

    // MARK: Failures stay quiet

    @Test("a failed fetch leaves the account nil with no banner, for every kind of error")
    func failedFetchIsQuiet() async {
        let errors: [any Error] = [MusicError.http(500), MusicError.parse("x"), MusicError.signedOut, URLError(.notConnectedToInternet)]
        for error in errors {
            let h = Harness(signedIn: true)
            await h.backend.setAccount(Self.alice)
            await h.backend.setAccountError(error)
            await h.service.refreshAuth()
            await h.service.accountTask?.value
            #expect(h.service.account == nil)
            #expect(h.service.lastError == nil)
            #expect(h.service.authState == .signedIn)
        }
    }

    @Test("a failed refresh keeps the account that was already loaded")
    func failedRefreshKeepsAccount() async {
        let h = await signedInHarness()
        await h.backend.setAccountError(MusicError.http(503))
        await h.service.refreshAuth()
        await h.service.accountTask?.value
        #expect(h.service.account == Self.alice)
        #expect(h.service.lastError == nil)
    }

    // MARK: Switching channel

    @Test("the account reloads after a successful switchChannel")
    func reloadsAfterChannelSwitch() async {
        let h = await signedInHarness()
        #expect(h.service.account == Self.alice)
        h.service.switchChannel()
        await h.service.channelSwitchTask?.value
        await h.backend.setAccount(Self.brand)
        await h.backend.setChannelIdentity(true)
        h.probe.pickerCompletion?(Self.picked)
        await h.service.channelSwitchTask?.value
        await h.service.accountTask?.value

        #expect(h.service.account == Self.brand)
        #expect(h.service.isBrandChannel == true)
        #expect(await h.backend.accountCallCount == 2)
    }

    @Test("after a switch the old channel's account is not shown while the new one is unknown")
    func switchDropsOldAccountWhenFetchFails() async {
        let h = await signedInHarness()
        await h.backend.setAccountError(MusicError.http(500))
        h.service.switchChannel()
        await h.service.channelSwitchTask?.value
        h.probe.pickerCompletion?(Self.picked)
        await h.service.channelSwitchTask?.value
        await h.service.accountTask?.value

        #expect(h.service.account == nil)
        #expect(h.service.lastError == nil)
        #expect(h.service.authState == .signedIn)
    }

    @Test("closing the channel picker keeps the account as it was")
    func closedPickerKeepsAccount() async {
        let h = await signedInHarness()
        h.service.switchChannel()
        await h.service.channelSwitchTask?.value
        h.probe.pickerCompletion?(nil)
        #expect(h.service.account == Self.alice)
        #expect(await h.backend.accountCallCount == 1)
    }

    @Test("a failed channel switch keeps the account as it was")
    func failedSwitchKeepsAccount() async {
        let h = await signedInHarness()
        await h.backend.setSignInError(MusicError.signedOut)
        h.service.switchChannel()
        await h.service.channelSwitchTask?.value
        h.probe.pickerCompletion?(Self.picked)
        await h.service.channelSwitchTask?.value
        #expect(h.service.account == Self.alice)
        #expect(await h.backend.accountCallCount == 1)
    }

    // MARK: Clearing

    @Test("signOut clears the account")
    func signOutClears() async {
        let h = await signedInHarness()
        h.service.signOut()
        #expect(h.service.account == nil)
        await h.service.signOutTask?.value
        #expect(h.service.account == nil)
    }

    @Test("a dead session found by any request clears the account")
    func deadSessionClears() async {
        let h = await signedInHarness()
        await h.backend.setSearchError("q", MusicError.signedOut)
        h.service.query = "q"
        h.service.search()
        await h.service.searchTask?.value
        #expect(h.service.authState == .signedOut)
        #expect(h.service.account == nil)
    }

    @Test("a dead session found by Home or Library clears the account too")
    func deadBrowseSessionClears() async {
        let h = await signedInHarness()
        await h.backend.setHomeError(MusicError.signedOut)
        h.service.browse.loadHomeIfNeeded()
        let signedOut = await h.eventually { h.service.authState == .signedOut }
        #expect(signedOut)
        #expect(h.service.account == nil)
    }

    // MARK: Stale responses

    @Test("a response that lands after signOut is dropped")
    func lateAfterSignOut() async {
        let h = Harness(signedIn: true)
        let gate = MusicTestGate()
        await h.backend.setAccount(Self.alice)
        await h.backend.setAccountGate(gate)
        await h.service.refreshAuth()
        let task = h.service.accountTask
        let called = await h.eventually { await h.backend.accountCallCount == 1 }
        #expect(called)

        h.service.signOut()
        await gate.open()
        await task?.value
        #expect(h.service.account == nil)
        #expect(h.service.authState == .signedOut)
    }

    @Test("a response that lands after a dead session is dropped")
    func lateAfterDeadSession() async {
        let h = Harness(signedIn: true)
        let gate = MusicTestGate()
        await h.backend.setAccount(Self.alice)
        await h.backend.setAccountGate(gate)
        await h.backend.setSearchError("q", MusicError.signedOut)
        await h.service.refreshAuth()
        let task = h.service.accountTask
        let called = await h.eventually { await h.backend.accountCallCount == 1 }
        #expect(called)

        h.service.query = "q"
        h.service.search()
        await h.service.searchTask?.value
        await gate.open()
        await task?.value
        #expect(h.service.account == nil)
    }

    @Test("the old session's response does not land on the next session")
    func lateAfterNewSignIn() async {
        let h = Harness(signedIn: true)
        let gate = MusicTestGate()
        await h.backend.setAccount(Self.alice)
        await h.backend.setAccountGate(gate)
        await h.service.refreshAuth()
        let stale = h.service.accountTask
        let called = await h.eventually { await h.backend.accountCallCount == 1 }
        #expect(called)

        h.service.signOut()
        await h.service.signOutTask?.value
        await h.backend.setAccountGate(nil)
        await h.backend.setAccount(Self.brand)
        h.service.signIn()
        h.probe.completion?(Self.picked)
        await h.service.signInTask?.value
        await h.service.accountTask?.value
        #expect(h.service.account == Self.brand)

        await gate.open()
        await stale?.value
        #expect(h.service.account == Self.brand)
    }

    @Test("a slower earlier refresh never overwrites a newer one")
    func slowerRefreshLoses() async {
        let h = Harness(signedIn: true)
        let gate = MusicTestGate()
        await h.backend.setAccount(Self.alice)
        await h.backend.setAccountGate(gate)
        await h.service.refreshAuth()
        let first = h.service.accountTask
        let called = await h.eventually { await h.backend.accountCallCount == 1 }
        #expect(called)

        await h.backend.setAccountGate(nil)
        await h.backend.setAccount(Self.brand)
        await h.service.refreshAuth()
        await h.service.accountTask?.value
        #expect(h.service.account == Self.brand)

        await gate.open()
        await first?.value
        #expect(h.service.account == Self.brand)
    }
}

// MARK: - Use another account

@MainActor
@Suite("MusicService use another account")
struct MusicServiceUseAnotherAccountTests {
    private static let alice = MusicAccount(name: "Test Listener", handle: "@testlistener", photoURL: nil)
    private static let bob = MusicAccount(name: "Other Person", handle: "@otherperson", photoURL: nil)
    private static let current = [StoredCookie(MusicSamples.cookie("SAPISID", domain: ".youtube.com"))]
    private static let other = [StoredCookie(MusicSamples.cookie("__Secure-3PAPISID", domain: ".youtube.com"))]

    /// Signed in as alice, playing a queue, with Home loaded.
    private func signedInHarness() async -> Harness {
        let h = Harness(signedIn: true)
        await h.backend.setSessionCookies(Self.current)
        await h.backend.setChannelIdentity(false)
        await h.backend.setAccount(Self.alice)
        await h.backend.setHome(shelves: [MusicSamples.shelf("Quick picks", "VLPL1")])
        await h.service.refreshAuth()
        await h.service.identityTask?.value
        await h.service.accountTask?.value
        h.service.browse.loadHomeIfNeeded()
        let homeLoaded = await h.eventually { h.service.browse.home == .loaded([MusicSamples.shelf("Quick picks", "VLPL1")]) }
        #expect(homeLoaded)
        #expect(h.service.account == Self.alice)
        await h.startQueue(["a", "b", "c"])
        return h
    }

    // MARK: Opening

    @Test("it opens the sign-in window and leaves everything else as it was")
    func opensWindowOnly() async {
        let h = await signedInHarness()
        h.service.useAnotherAccount()

        #expect(h.probe.presentCount == 1)
        #expect(h.service.isAddingAccount)
        #expect(h.service.authState == .signedIn)
        #expect(h.service.account == Self.alice)
        #expect(await h.backend.signOutCount == 0)
        #expect(await h.backend.signInCookies.isEmpty)
        #expect(h.service.browse.home == .loaded([MusicSamples.shelf("Quick picks", "VLPL1")]))
        #expect(h.player.nowPlaying?.videoId == "a")
        #expect(h.queuedIDs == ["a", "b", "c"])
    }

    @Test("a second call while the window is open is ignored")
    func notReentrant() async {
        let h = await signedInHarness()
        h.service.useAnotherAccount()
        h.service.useAnotherAccount()
        #expect(h.probe.presentCount == 1)
    }

    @Test("it does nothing while signed out, signing in, or switching channel")
    func guards() async {
        let out = Harness(signedIn: false)
        await out.service.refreshAuth()
        out.service.useAnotherAccount()
        #expect(out.probe.presentCount == 0)
        #expect(!out.service.isAddingAccount)

        let signingIn = Harness(signedIn: false)
        signingIn.service.signIn()
        signingIn.service.useAnotherAccount()
        #expect(signingIn.probe.presentCount == 1)
        #expect(!signingIn.service.isAddingAccount)

        let switching = await signedInHarness()
        switching.service.switchChannel()
        await switching.service.channelSwitchTask?.value
        switching.service.useAnotherAccount()
        #expect(switching.probe.presentCount == 0)
        #expect(!switching.service.isAddingAccount)
    }

    // MARK: Cancelling

    @Test("closing the window leaves the session, account, browse and playback exactly as they were")
    func cancelChangesNothing() async {
        let h = await signedInHarness()
        h.service.useAnotherAccount()
        h.probe.completion?(nil)

        #expect(!h.service.isAddingAccount)
        #expect(h.service.authState == .signedIn)
        #expect(h.service.account == Self.alice)
        #expect(h.service.isBrandChannel == false)
        #expect(h.service.lastError == nil)
        #expect(h.service.browse.home == .loaded([MusicSamples.shelf("Quick picks", "VLPL1")]))
        #expect(h.player.nowPlaying?.videoId == "a")
        #expect(h.queuedIDs == ["a", "b", "c"])
        #expect(await h.backend.signInCookies.isEmpty)
        #expect(await h.backend.signOutCount == 0)
        #expect(await h.backend.accountCallCount == 1)
    }

    @Test("an empty cookie list counts as closing the window")
    func emptyCookiesCancel() async {
        let h = await signedInHarness()
        h.service.useAnotherAccount()
        h.probe.completion?([])
        #expect(!h.service.isAddingAccount)
        #expect(h.service.account == Self.alice)
        #expect(await h.backend.signInCookies.isEmpty)
    }

    @Test("after a cancel the next call opens the window again")
    func reopenAfterCancel() async {
        let h = await signedInHarness()
        h.service.useAnotherAccount()
        h.probe.completion?(nil)
        h.service.useAnotherAccount()
        #expect(h.probe.presentCount == 2)
        #expect(h.service.isAddingAccount)
    }

    // MARK: Success

    @Test("a successful sign-in replaces the session: new cookies, Home reset, new account, playback stopped")
    func swapsTheSession() async {
        let h = await signedInHarness()
        await h.backend.setAccount(Self.bob)
        await h.backend.setChannelIdentity(true)
        h.service.useAnotherAccount()
        h.probe.completion?(Self.other)
        await h.service.addAccountTask?.value
        await h.service.identityTask?.value
        await h.service.accountTask?.value

        #expect(await h.backend.signInCookies == [Self.other])
        #expect(await h.backend.signOutCount == 0)
        #expect(h.service.authState == .signedIn)
        #expect(!h.service.isAddingAccount)
        #expect(h.service.account == Self.bob)
        #expect(h.service.isBrandChannel == true)
        #expect(h.service.browse.home == .idle)
        #expect(h.service.browse.path.isEmpty)
        #expect(h.service.lastError == nil)
        // The old account's playback must not carry on under the new one.
        #expect(h.player.nowPlaying == nil)
        #expect(h.service.queue.tracks.isEmpty)
        #expect(h.service.results.isEmpty)
    }

    @Test("a swap throws the old account's search away and ticks never reach the history ping")
    func swapClearsSearchAndPings() async {
        let h = await signedInHarness()
        await h.backend.setSearch("q", results: [MusicSamples.track("s1")])
        h.service.query = "q"
        h.service.search()
        await h.service.searchTask?.value
        #expect(h.service.results.count == 1)

        h.service.useAnotherAccount()
        h.probe.completion?(Self.other)
        await h.service.addAccountTask?.value
        h.listen(seconds: 40)
        await h.service.reportTask?.value

        #expect(h.service.results.isEmpty)
        #expect(h.service.query.isEmpty)
        #expect(await h.backend.reportAttempts.isEmpty)
    }

    @Test("the card's notice state resets for the new account")
    func swapResetsNotice() async {
        let h = await signedInHarness()
        h.service.channelNoticeDismissed = true
        h.service.useAnotherAccount()
        h.probe.completion?(Self.other)
        await h.service.addAccountTask?.value
        #expect(!h.service.channelNoticeDismissed)
    }

    @Test("the new session keeps working: Home loads again under it")
    func homeLoadsAgain() async {
        let h = await signedInHarness()
        await h.backend.setHome(shelves: [MusicSamples.shelf("Other account", "VLPL9")])
        h.service.useAnotherAccount()
        h.probe.completion?(Self.other)
        await h.service.addAccountTask?.value
        h.service.browse.loadHomeIfNeeded()
        let loaded = await h.eventually { h.service.browse.home == .loaded([MusicSamples.shelf("Other account", "VLPL9")]) }
        #expect(loaded)
    }

    // MARK: Failure

    @Test("a refused sign-in keeps the old session, account and playback, and says so")
    func failureKeepsSession() async {
        let h = await signedInHarness()
        await h.backend.setSignInError(MusicError.signedOut)
        h.service.useAnotherAccount()
        h.probe.completion?(Self.other)
        await h.service.addAccountTask?.value

        #expect(h.service.authState == .signedIn)
        #expect(!h.service.isAddingAccount)
        #expect(h.service.account == Self.alice)
        #expect(h.service.browse.home == .loaded([MusicSamples.shelf("Quick picks", "VLPL1")]))
        #expect(h.player.nowPlaying?.videoId == "a")
        #expect(h.queuedIDs == ["a", "b", "c"])
        #expect(h.service.lastError?.contains("Still signed in as before") == true)
    }

    // MARK: Races

    @Test("a sign-out while the window is open closes it and drops a late pick")
    func signOutDropsPick() async {
        let h = await signedInHarness()
        h.service.useAnotherAccount()
        h.service.signOut()
        #expect(h.probe.windowCloses == 1)
        #expect(!h.service.isAddingAccount)

        h.probe.completion?(Self.other)
        await h.service.addAccountTask?.value
        #expect(await h.backend.signInCookies.isEmpty)
        #expect(h.service.authState == .signedOut)
        #expect(h.service.account == nil)
    }

    @Test("a sign-out while the new session is being stored wins")
    func signOutWinsOverSwap() async {
        let h = await signedInHarness()
        h.service.useAnotherAccount()
        h.probe.completion?(Self.other)
        h.service.signOut()
        await h.service.addAccountTask?.value
        await h.service.signOutTask?.value

        #expect(h.service.authState == .signedOut)
        #expect(h.service.account == nil)
        #expect(!h.service.isAddingAccount)
    }

    @Test("a dead session while the window is open still takes the account that was signed in")
    func deadSessionStillTakesPick() async {
        let h = await signedInHarness()
        await h.backend.setSearchError("q", MusicError.signedOut)
        h.service.useAnotherAccount()
        h.service.query = "q"
        h.service.search()
        await h.service.searchTask?.value
        await h.service.signOutTask?.value
        #expect(h.service.authState == .signedOut)

        await h.backend.setAccount(Self.bob)
        h.probe.completion?(Self.other)
        await h.service.addAccountTask?.value
        await h.service.accountTask?.value

        #expect(h.service.authState == .signedIn)
        #expect(h.service.account == Self.bob)
        #expect(!h.service.isAddingAccount)
        #expect(await h.backend.signInCookies == [Self.other])
    }

    @Test("a regular sign-in started over an open add-account window takes over from it")
    func signInTakesOver() async {
        let h = await signedInHarness()
        await h.backend.setSearchError("q", MusicError.signedOut)
        h.service.useAnotherAccount()
        let staleCompletion = h.probe.completion
        h.service.query = "q"
        h.service.search()
        await h.service.searchTask?.value
        await h.service.signOutTask?.value

        h.service.signIn()
        #expect(!h.service.isAddingAccount)
        #expect(h.service.authState == .signingIn)

        staleCompletion?(Self.other)
        await h.service.addAccountTask?.value
        #expect(await h.backend.signInCookies.isEmpty)
        #expect(h.service.authState == .signingIn)
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

    @Test("a refresh that fails after another track started leaves the new track's error line alone")
    func staleRefreshErrorIgnored() async {
        let h = Harness()
        let gate = MusicTestGate()
        await h.startPlaying(MusicSamples.track("old"))
        await h.backend.setResolveGate("old", gate)
        await h.backend.setResolveError("old", URLError(.timedOut))

        h.engine.emit(.failed)
        let stale = h.player.refreshTask
        let parked = await h.eventually { await h.backend.resolvedIDs.count == 2 }
        #expect(parked)

        await h.startPlaying(MusicSamples.track("new"))
        await gate.open()
        await stale?.value

        #expect(h.service.lastError == nil)
        #expect(h.player.nowPlaying?.videoId == "new")
    }

    @Test("a refresh that lands after another track started does not give its tracking URL to the new session")
    func staleRefreshTrackingURL() async {
        let h = Harness()
        let gate = MusicTestGate()
        await h.backend.setStream(MusicSamples.stream(videoId: "old", trackingURL: nil))
        await h.backend.setStream(MusicSamples.stream(videoId: "new", trackingURL: nil))
        await h.startPlaying(MusicSamples.track("old"))
        await h.backend.setStream(MusicSamples.stream(videoId: "old", trackingURL: URL(string: "https://music.example.test/stats?ev=old")))
        await h.backend.setResolveGate("old", gate)

        h.engine.emit(.failed)
        let stale = h.player.refreshTask
        let parked = await h.eventually { await h.backend.resolvedIDs.count == 2 }
        #expect(parked)

        await h.startPlaying(MusicSamples.track("new"))
        await gate.open()
        await stale?.value
        h.listen(seconds: 40)
        await h.service.reportTask?.value

        #expect(await h.backend.reportAttempts.isEmpty)
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
        #expect(reports.first?.kind == .playback)
        #expect(reports.first?.url == trackingURL)
        #expect(isValidCPN(reports.first?.cpn ?? ""))
        #expect(reports.first?.mediaTime == 30)
    }

    @Test("at 30 s the playback ping goes first, then the watchtime ping, both once with the same CPN and media time")
    func bothPingsOnce() async {
        let h = Harness()
        let playbackURL = URL(string: "https://music.example.test/stats/playback?ev=7")!
        let watchtimeURL = URL(string: "https://music.example.test/stats/watchtime?ev=7")!
        await h.backend.setStream(MusicSamples.stream(videoId: "abc", trackingURL: playbackURL, watchtimeURL: watchtimeURL))
        await h.startPlaying(MusicSamples.track("abc"))

        h.listen(seconds: 29.5)
        #expect(h.service.reportTask == nil)
        #expect(await h.backend.reportAttempts.isEmpty)

        h.listen(seconds: 90, from: 29.5)
        await h.service.reportTask?.value

        let reports = await h.backend.reportAttempts
        #expect(reports.map(\.kind) == [.playback, .watchtime])
        #expect(reports.map(\.url) == [playbackURL, watchtimeURL])
        #expect(isValidCPN(reports.first?.cpn ?? ""))
        #expect(Set(reports.map(\.cpn)).count == 1)
        #expect(reports.map(\.mediaTime) == [30, 30])
    }

    @Test("a stream without a watchtime URL sends only the playback ping")
    func playbackOnlyWithoutWatchtimeURL() async {
        let h = Harness()
        await h.backend.setStream(MusicSamples.stream(videoId: "abc", watchtimeURL: nil))
        await h.startPlaying(MusicSamples.track("abc"))
        h.listen(seconds: 90)
        await h.service.reportTask?.value

        #expect(await h.backend.reportAttempts.map(\.kind) == [.playback])
    }

    @Test("a failing playback ping does not stop the watchtime ping")
    func playbackFailureStillSendsWatchtime() async {
        let h = Harness()
        let watchtimeURL = URL(string: "https://music.example.test/stats/watchtime?ev=1")!
        await h.backend.setStream(MusicSamples.stream(videoId: "abc", watchtimeURL: watchtimeURL))
        await h.backend.setReportError(URLError(.timedOut), kind: .playback)
        await h.startPlaying(MusicSamples.track("abc"))
        h.listen(seconds: 90)
        await h.service.reportTask?.value

        let reports = await h.backend.reportAttempts
        #expect(reports.map(\.kind) == [.playback, .watchtime])
        #expect(reports.last?.url == watchtimeURL)
    }

    @Test("a failing watchtime ping leaves the playback ping sent and is not retried")
    func watchtimeFailureIsContained() async {
        let h = Harness()
        let watchtimeURL = URL(string: "https://music.example.test/stats/watchtime?ev=1")!
        await h.backend.setStream(MusicSamples.stream(videoId: "abc", watchtimeURL: watchtimeURL))
        await h.backend.setReportError(MusicError.http(500), kind: .watchtime)
        await h.startPlaying(MusicSamples.track("abc"))
        h.listen(seconds: 120)
        await h.service.reportTask?.value

        #expect(await h.backend.reportAttempts.map(\.kind) == [.playback, .watchtime])
    }

    @Test("both pings failing is survived and neither is retried")
    func bothFailing() async {
        let h = Harness()
        let watchtimeURL = URL(string: "https://music.example.test/stats/watchtime?ev=1")!
        await h.backend.setStream(MusicSamples.stream(videoId: "abc", watchtimeURL: watchtimeURL))
        await h.backend.setReportError(URLError(.notConnectedToInternet))
        await h.startPlaying(MusicSamples.track("abc"))
        h.listen(seconds: 120)
        await h.service.reportTask?.value

        #expect(await h.backend.reportAttempts.count == 2)
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

    @Test("a stream refresh after 30 s that brings both URLs sends both pings at the current media time")
    func lateURLsSendBothPings() async {
        let h = Harness()
        let playbackURL = URL(string: "https://music.example.test/stats/playback?ev=9")!
        let watchtimeURL = URL(string: "https://music.example.test/stats/watchtime?ev=9")!
        await h.backend.setStream(MusicSamples.stream(videoId: "abc", trackingURL: nil))
        await h.startPlaying(MusicSamples.track("abc"))
        h.listen(seconds: 40)
        #expect(h.service.reportTask == nil)

        await h.backend.setStream(MusicSamples.stream(videoId: "abc", trackingURL: playbackURL, watchtimeURL: watchtimeURL))
        h.engine.emit(.failed)
        await h.player.refreshTask?.value
        await h.service.reportTask?.value

        let reports = await h.backend.reportAttempts
        #expect(reports.map(\.kind) == [.playback, .watchtime])
        #expect(reports.map(\.url) == [playbackURL, watchtimeURL])
        #expect(Set(reports.map(\.cpn)).count == 1)
        #expect(reports.map(\.mediaTime) == [40, 40])
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

// MARK: - Queue and radio

@MainActor
@Suite("MusicService queue")
struct MusicServiceQueueTests {
    @Test("a tapped track starts a queue of one, then the radio's tracks follow it")
    func tapThenRadio() async {
        let h = Harness()
        await h.backend.setRadio(seed: "a", tracks: MusicSamples.tracks("a", "b", "c"))
        h.service.play(MusicSamples.track("a"))
        #expect(h.queuedIDs == ["a"])

        await h.settle()

        #expect(h.queuedIDs == ["a", "b", "c"])
        #expect(await h.backend.radioSeeds == ["a"])
        #expect(h.service.queue.current?.videoId == "a")
        #expect(h.service.canGoNext)
    }

    @Test("the seed and repeated tracks are dropped from the radio page")
    func radioDedupes() async {
        let h = Harness()
        await h.backend.setRadio(seed: "a", tracks: MusicSamples.tracks("a", "b", "b", "c", "a"))
        h.service.play(MusicSamples.track("a"))
        await h.settle()
        #expect(h.queuedIDs == ["a", "b", "c"])
    }

    @Test("a radio error leaves the song playing and shows nothing")
    func radioErrorIsSilent() async {
        let h = Harness()
        await h.backend.setRadioError(seed: "a", URLError(.notConnectedToInternet))
        h.service.play(MusicSamples.track("a"))
        await h.settle()

        #expect(h.queuedIDs == ["a"])
        #expect(h.service.lastError == nil)
        #expect(h.service.radioTask == nil)
        #expect(h.player.nowPlaying?.videoId == "a")
        #expect(h.loadedIDs == ["a"])
    }

    @Test("a new seed ignores the page its predecessor was still fetching")
    func staleRadioIgnored() async {
        let h = Harness()
        let gate = MusicTestGate()
        await h.backend.setRadioGate(seed: "a", gate)
        await h.backend.setRadio(seed: "a", tracks: MusicSamples.tracks("a", "old1", "old2"))
        await h.backend.setRadio(seed: "b", tracks: MusicSamples.tracks("b", "new1"))

        h.service.play(MusicSamples.track("a"))
        let stale = h.service.radioTask
        h.service.play(MusicSamples.track("b"))
        await h.settle()
        #expect(h.queuedIDs == ["b", "new1"])

        await gate.open()
        await stale?.value

        #expect(h.queuedIDs == ["b", "new1"])
        #expect(h.service.queue.seedVideoId == "b")
    }

    @Test("more radio is fetched once three or fewer tracks are left, and not before")
    func topUpAtThree() async {
        let h = Harness()
        let call = FakeMusicBackend.MoreRadioCall(seed: "a", continuation: "c1")
        await h.backend.setMoreRadio(seed: "a", continuation: "c1", tracks: MusicSamples.tracks("i", "j", "k"))
        await h.startQueue(["a", "b", "c", "d", "e", "f", "g", "h"], continuation: "c1")
        #expect(await h.backend.moreRadioCalls.isEmpty)

        for _ in 0..<3 { h.service.next() }
        await h.settle()
        #expect(h.service.queue.upcomingCount == 4)
        #expect(await h.backend.moreRadioCalls.isEmpty)

        h.service.next()
        await h.settle()

        #expect(await h.backend.moreRadioCalls == [call])
        #expect(h.queuedIDs == ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k"])
        #expect(h.service.queue.continuation == nil)
    }

    @Test("only one more-radio fetch runs at a time")
    func oneFetchAtATime() async {
        let h = Harness()
        let gate = MusicTestGate()
        await h.backend.setMoreRadioGate(seed: "a", continuation: "c1", gate)
        await h.backend.setMoreRadio(seed: "a", continuation: "c1", tracks: MusicSamples.tracks("f", "g"))
        await h.startQueue(["a", "b", "c", "d", "e"], continuation: "c1")
        #expect(h.service.radioTask == nil)

        h.service.next()
        let inFlight = h.service.radioTask
        #expect(inFlight != nil)
        h.service.next()
        h.service.next()
        #expect(h.service.radioTask == inFlight)

        await gate.open()
        await inFlight?.value
        await h.settle()

        #expect(await h.backend.moreRadioCalls.count == 1)
        #expect(h.queuedIDs == ["a", "b", "c", "d", "e", "f", "g"])
    }

    @Test("a queue without a continuation never asks for more")
    func noContinuation() async {
        let h = Harness()
        await h.startQueue(["a", "b", "c"])
        h.service.next()
        h.service.next()
        await h.settle()
        #expect(await h.backend.moreRadioCalls.isEmpty)
        #expect(h.service.radioTask == nil)
    }

    @Test("a failed more-radio fetch is silent and tried again on the next track")
    func moreRadioErrorRetries() async {
        let h = Harness()
        await h.backend.setMoreRadioError(seed: "a", continuation: "c1", URLError(.timedOut))
        await h.startQueue(["a", "b", "c"], continuation: "c1")
        #expect(await h.backend.moreRadioCalls.count == 1)
        #expect(h.service.lastError == nil)

        h.service.next()
        await h.settle()

        #expect(await h.backend.moreRadioCalls.count == 2)
        #expect(h.service.lastError == nil)
        #expect(h.queuedIDs == ["a", "b", "c"])
    }

    @Test("a page that adds nothing new but has a continuation is followed by the next page at once")
    func emptyPageFetchesNext() async {
        let h = Harness()
        await h.backend.setMoreRadio(seed: "a", continuation: "c1", tracks: MusicSamples.tracks("b", "c"), next: "c2")
        await h.backend.setMoreRadio(seed: "a", continuation: "c2", tracks: MusicSamples.tracks("d", "e"))
        await h.startQueue(["a", "b", "c"], continuation: "c1")

        let calls = await h.backend.moreRadioCalls
        #expect(calls.map(\.continuation) == ["c1", "c2"])
        #expect(h.queuedIDs == ["a", "b", "c", "d", "e"])
        #expect(h.service.radioTask == nil)
    }

    @Test("a first page that is only the seed still leads on to the next page")
    func emptyFirstPageFetchesNext() async {
        let h = Harness()
        await h.backend.setMoreRadio(seed: "a", continuation: "c1", tracks: MusicSamples.tracks("b"))
        await h.startQueue(["a"], continuation: "c1")
        #expect(h.queuedIDs == ["a", "b"])
    }

    @Test("three empty pages in a row end the top-up, and the next track change tries again")
    func emptyPagesCapped() async {
        let h = Harness()
        let repeats = MusicSamples.tracks("b", "c")
        await h.backend.setMoreRadio(seed: "a", continuation: "c1", tracks: repeats, next: "c2")
        await h.backend.setMoreRadio(seed: "a", continuation: "c2", tracks: repeats, next: "c3")
        await h.backend.setMoreRadio(seed: "a", continuation: "c3", tracks: repeats, next: "c4")
        await h.backend.setMoreRadio(seed: "a", continuation: "c4", tracks: MusicSamples.tracks("z"))
        await h.startQueue(["a", "b", "c"], continuation: "c1")

        let first = await h.backend.moreRadioCalls
        #expect(first.map(\.continuation) == ["c1", "c2", "c3"])
        #expect(h.queuedIDs == ["a", "b", "c"])
        #expect(h.service.queue.continuation == "c4")
        #expect(h.service.radioTask == nil)

        h.service.next()
        await h.settle()

        #expect(await h.backend.moreRadioCalls.map(\.continuation) == ["c1", "c2", "c3", "c4"])
        #expect(h.queuedIDs == ["a", "b", "c", "z"])
    }

    @Test("a page that adds tracks resets the empty-page count")
    func progressResetsEmptyCount() async {
        let h = Harness()
        let repeats = MusicSamples.tracks("b", "c")
        await h.backend.setMoreRadio(seed: "a", continuation: "c1", tracks: repeats, next: "c2")
        await h.backend.setMoreRadio(seed: "a", continuation: "c2", tracks: repeats, next: "c3")
        await h.backend.setMoreRadio(seed: "a", continuation: "c3", tracks: MusicSamples.tracks("d"), next: "c4")
        await h.backend.setMoreRadio(seed: "a", continuation: "c4", tracks: repeats, next: "c5")
        await h.backend.setMoreRadio(seed: "a", continuation: "c5", tracks: repeats, next: "c6")
        await h.backend.setMoreRadio(seed: "a", continuation: "c6", tracks: MusicSamples.tracks("e"))
        await h.startQueue(["a", "b", "c"], continuation: "c1")

        #expect(await h.backend.moreRadioCalls.count == 6)
        #expect(h.queuedIDs == ["a", "b", "c", "d", "e"])
    }

    @Test("a new seed ends an empty-page chain that was still running")
    func newSeedEndsEmptyChain() async {
        let h = Harness()
        let gate = MusicTestGate()
        await h.backend.setRadio(seed: "a", tracks: MusicSamples.tracks("a", "b", "c"), continuation: "c1")
        await h.backend.setMoreRadio(seed: "a", continuation: "c1", tracks: MusicSamples.tracks("b", "c"), next: "c2")
        await h.backend.setMoreRadioGate(seed: "a", continuation: "c2", gate)
        await h.backend.setMoreRadio(seed: "a", continuation: "c2", tracks: MusicSamples.tracks("d"), next: "c3")
        await h.backend.setRadio(seed: "x", tracks: MusicSamples.tracks("x", "y"))

        h.service.play(MusicSamples.track("a"))
        let reachedSecondPage = await h.eventually { await h.backend.moreRadioCalls.count == 2 }
        #expect(reachedSecondPage)
        let stale = h.service.radioTask

        h.service.play(MusicSamples.track("x"))
        await h.settle()
        #expect(h.queuedIDs == ["x", "y"])

        await gate.open()
        await stale?.value

        #expect(await h.backend.moreRadioCalls.count == 2)
        #expect(h.queuedIDs == ["x", "y"])
        #expect(h.service.queue.seedVideoId == "x")
    }

    @Test("a page that cannot be read or that the server rejects ends paging, so it is not retried on every track")
    func hopelessPageEndsPaging() async {
        let errors: [any Error] = [MusicError.parse("x"), MusicError.http(400), MusicError.http(404)]
        for error in errors {
            let h = Harness()
            await h.backend.setMoreRadioError(seed: "a", continuation: "c1", error)
            await h.startQueue(["a", "b", "c"], continuation: "c1")
            #expect(await h.backend.moreRadioCalls.count == 1)
            #expect(h.service.queue.continuation == nil)

            h.service.next()
            await h.settle()

            #expect(await h.backend.moreRadioCalls.count == 1)
            #expect(h.service.lastError == nil)
            #expect(h.queuedIDs == ["a", "b", "c"])
        }
    }

    @Test("a server error or a dropped connection keeps the continuation for the next track")
    func transientPageKeepsPaging() async {
        let errors: [any Error] = [MusicError.http(503), MusicError.solver("x"), URLError(.timedOut)]
        for error in errors {
            let h = Harness()
            await h.backend.setMoreRadioError(seed: "a", continuation: "c1", error)
            await h.startQueue(["a", "b", "c"], continuation: "c1")
            #expect(h.service.queue.continuation == "c1")

            h.service.next()
            await h.settle()

            #expect(await h.backend.moreRadioCalls.count == 2)
            #expect(h.service.lastError == nil)
        }
    }

    @Test("a radio page that finds the session dead signs out and stops paging")
    func radioSignedOut() async {
        let h = Harness()
        await h.backend.setMoreRadioError(seed: "a", continuation: "c1", MusicError.signedOut)
        await h.startQueue(["a", "b", "c"], continuation: "c1")
        await h.service.signOutTask?.value

        #expect(h.service.authState == .signedOut)
        #expect(await h.backend.signOutCount == 1)
        #expect(h.service.lastError == nil)
        #expect(h.service.queue.continuation == nil)
    }
}

// MARK: - Page queue

@MainActor
@Suite("MusicService page queue")
struct MusicServicePageQueueTests {
    private static let browseId = "VLPL1"

    private func page(_ ids: [String], continuation: String? = nil, browseId: String = Self.browseId) -> MusicBrowsePage {
        MusicSamples.page(browseId, tracks: ids.map { MusicSamples.track($0, title: "Song \($0)") }, continuation: continuation)
    }

    /// Plays `tap` (the first row by default) from a page of `ids` and waits for the queue work.
    private func startPage(_ h: Harness, _ ids: [String], tap: String? = nil, continuation: String? = nil) async {
        let id = tap ?? ids[0]
        h.service.play(MusicSamples.track(id, title: "Song \(id)"), in: page(ids, continuation: continuation))
        await h.settle()
        h.engine.emit(.playingChanged(true))
    }

    private func call(_ continuation: String, browseId: String = Self.browseId) -> FakeMusicBackend.MoreTracksCall {
        FakeMusicBackend.MoreTracksCall(browseId: browseId, continuation: continuation)
    }

    @Test("a tapped row queues the page in its order, starts on that row and asks for no radio")
    func pageOrder() async {
        let h = Harness()
        await startPage(h, ["a", "b", "c", "d", "e"], tap: "c")

        #expect(h.queuedIDs == ["a", "b", "c", "d", "e"])
        #expect(h.service.queue.current?.videoId == "c")
        #expect(h.service.queue.source == .page(browseId: Self.browseId))
        #expect(h.service.queue.seedVideoId == nil)
        #expect(h.loadedIDs == ["c"])
        #expect(h.player.nowPlaying?.videoId == "c")
        #expect(h.service.canGoNext)
        #expect(await h.backend.radioSeeds.isEmpty)
        #expect(await h.backend.moreRadioCalls.isEmpty)
    }

    @Test("next and a track ending walk down the page")
    func nextWalksPage() async {
        let h = Harness()
        await startPage(h, ["a", "b", "c"])
        h.service.next()
        await h.settle()
        h.engine.emit(.ended)
        await h.settle()

        #expect(h.loadedIDs == ["a", "b", "c"])
        #expect(h.service.queue.current?.videoId == "c")
        #expect(await h.backend.radioSeeds.isEmpty)
    }

    @Test("previous goes back into the page rows above the tapped one")
    func previousGoesBack() async {
        let h = Harness()
        await startPage(h, ["a", "b", "c", "d"], tap: "c")
        #expect(h.service.queue.hasPrevious)

        h.service.previous()
        await h.settle()
        h.engine.emit(.playingChanged(true))
        h.service.previous()
        await h.settle()

        #expect(h.loadedIDs == ["c", "b", "a"])
        #expect(h.service.queue.current?.videoId == "a")
        #expect(h.service.queue.hasPrevious == false)
        #expect(h.queuedIDs == ["a", "b", "c", "d"])
    }

    @Test("the queue stops at the end of the page and nothing else is asked for")
    func stopsAtPageEnd() async {
        let h = Harness()
        await startPage(h, ["a", "b"], tap: "b")
        #expect(h.service.canGoNext == false)

        h.service.next()

        #expect(h.player.nowPlaying == nil)
        #expect(h.service.queue.isEmpty)
        #expect(h.loadedIDs == ["b"])
        #expect(await h.backend.radioSeeds.isEmpty)
        #expect(await h.backend.moreRadioCalls.isEmpty)
        #expect(await h.backend.moreTracksCalls.isEmpty)
    }

    @Test("a track ending at the end of the page leaves the player on the finished song")
    func endsAtPageEnd() async {
        let h = Harness()
        await startPage(h, ["a", "b"], tap: "b")
        h.engine.emit(.ended)
        await h.settle()

        #expect(h.loadedIDs == ["b"])
        #expect(h.player.hasEnded)
        #expect(await h.backend.radioSeeds.isEmpty)
    }

    @Test("a tapped row the page does not list is played first and the page follows it")
    func unlistedRow() async {
        let h = Harness()
        await startPage(h, ["a", "b"], tap: "z")
        #expect(h.queuedIDs == ["z", "a", "b"])
        #expect(h.service.queue.current?.videoId == "z")
        #expect(h.loadedIDs == ["z"])
    }

    @Test("more tracks are fetched once three or fewer are left, and not before")
    func moreTracksAtThree() async {
        let h = Harness()
        await h.backend.setMoreTracks(browseId: Self.browseId, continuation: "t1", tracks: MusicSamples.tracks("i", "j", "k"))
        await startPage(h, ["a", "b", "c", "d", "e", "f", "g", "h"], continuation: "t1")
        #expect(await h.backend.moreTracksCalls.isEmpty)

        for _ in 0..<3 { h.service.next() }
        await h.settle()
        #expect(h.service.queue.upcomingCount == 4)
        #expect(await h.backend.moreTracksCalls.isEmpty)

        h.service.next()
        await h.settle()

        #expect(await h.backend.moreTracksCalls == [call("t1")])
        #expect(h.queuedIDs == ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k"])
        #expect(h.service.queue.continuation == nil)
        #expect(await h.backend.radioSeeds.isEmpty)
    }

    @Test("a short page with a continuation asks for more tracks at once")
    func shortPageFetchesAtOnce() async {
        let h = Harness()
        await h.backend.setMoreTracks(browseId: Self.browseId, continuation: "t1", tracks: MusicSamples.tracks("d", "e"))
        await startPage(h, ["a", "b", "c"], continuation: "t1")

        #expect(await h.backend.moreTracksCalls == [call("t1")])
        #expect(h.queuedIDs == ["a", "b", "c", "d", "e"])
        #expect(h.service.radioTask == nil)
    }

    @Test("a page without a continuation never asks for more tracks")
    func noContinuation() async {
        let h = Harness()
        await startPage(h, ["a", "b", "c"])
        h.service.next()
        h.service.next()
        await h.settle()
        #expect(await h.backend.moreTracksCalls.isEmpty)
        #expect(h.service.radioTask == nil)
    }

    @Test("a page of repeats is followed by the next page at once, and repeats are not queued twice")
    func repeatsAreDropped() async {
        let h = Harness()
        await h.backend.setMoreTracks(browseId: Self.browseId, continuation: "t1", tracks: MusicSamples.tracks("b", "c"), next: "t2")
        await h.backend.setMoreTracks(browseId: Self.browseId, continuation: "t2", tracks: MusicSamples.tracks("c", "d"))
        await startPage(h, ["a", "b", "c"], continuation: "t1")

        #expect(await h.backend.moreTracksCalls == [call("t1"), call("t2")])
        #expect(h.queuedIDs == ["a", "b", "c", "d"])
        #expect(h.service.queue.continuation == nil)
    }

    @Test("only one more-tracks fetch runs at a time")
    func oneFetchAtATime() async {
        let h = Harness()
        let gate = MusicTestGate()
        await h.backend.setMoreTracksGate(browseId: Self.browseId, continuation: "t1", gate)
        await h.backend.setMoreTracks(browseId: Self.browseId, continuation: "t1", tracks: MusicSamples.tracks("f", "g"))
        await startPage(h, ["a", "b", "c", "d", "e"], continuation: "t1")
        #expect(h.service.radioTask == nil)

        h.service.next()
        let inFlight = h.service.radioTask
        #expect(inFlight != nil)
        h.service.next()
        h.service.next()
        #expect(h.service.radioTask == inFlight)

        await gate.open()
        await inFlight?.value
        await h.settle()

        #expect(await h.backend.moreTracksCalls == [call("t1")])
        #expect(h.queuedIDs == ["a", "b", "c", "d", "e", "f", "g"])
    }

    @Test("a page that cannot be read or that the server rejects ends paging")
    func hopelessPageEndsPaging() async {
        let errors: [any Error] = [MusicError.parse("x"), MusicError.http(400), MusicError.http(404)]
        for error in errors {
            let h = Harness()
            await h.backend.setMoreTracksError(browseId: Self.browseId, continuation: "t1", error)
            await startPage(h, ["a", "b", "c"], continuation: "t1")
            #expect(await h.backend.moreTracksCalls.count == 1)
            #expect(h.service.queue.continuation == nil)

            h.service.next()
            await h.settle()

            #expect(await h.backend.moreTracksCalls.count == 1)
            #expect(h.service.lastError == nil)
            #expect(h.queuedIDs == ["a", "b", "c"])
        }
    }

    @Test("a server error or a dropped connection keeps the continuation for the next track")
    func transientPageKeepsPaging() async {
        let errors: [any Error] = [MusicError.http(503), URLError(.timedOut)]
        for error in errors {
            let h = Harness()
            await h.backend.setMoreTracksError(browseId: Self.browseId, continuation: "t1", error)
            await startPage(h, ["a", "b", "c"], continuation: "t1")
            #expect(h.service.queue.continuation == "t1")

            h.service.next()
            await h.settle()

            #expect(await h.backend.moreTracksCalls.count == 2)
            #expect(h.service.lastError == nil)
        }
    }

    @Test("a more-tracks fetch that finds the session dead signs out and stops paging")
    func signedOutWhilePaging() async {
        let h = Harness()
        await h.backend.setMoreTracksError(browseId: Self.browseId, continuation: "t1", MusicError.signedOut)
        await startPage(h, ["a", "b", "c"], continuation: "t1")
        await h.service.signOutTask?.value

        #expect(h.service.authState == .signedOut)
        #expect(await h.backend.signOutCount == 1)
        #expect(h.service.lastError == nil)
        #expect(h.service.queue.continuation == nil)
    }

    @Test("tracks a replaced page was still fetching are ignored")
    func staleMoreTracksIgnored() async {
        let h = Harness()
        let gate = MusicTestGate()
        await h.backend.setMoreTracksGate(browseId: Self.browseId, continuation: "t1", gate)
        await h.backend.setMoreTracks(browseId: Self.browseId, continuation: "t1", tracks: MusicSamples.tracks("old1", "old2"))

        h.service.play(MusicSamples.track("a"), in: page(["a", "b", "c"], continuation: "t1"))
        let stale = h.service.radioTask
        #expect(stale != nil)
        h.service.play(MusicSamples.track("x"), in: page(["x", "y"], browseId: "VLPL2"))
        await h.settle()
        #expect(h.queuedIDs == ["x", "y"])

        await gate.open()
        await stale?.value

        #expect(h.queuedIDs == ["x", "y"])
        #expect(h.service.queue.source == .page(browseId: "VLPL2"))
        #expect(h.service.queue.continuation == nil)
    }

    @Test("a radio the last queue was still fetching does not add to a page queue")
    func staleRadioIgnored() async {
        let h = Harness()
        let gate = MusicTestGate()
        await h.backend.setRadioGate(seed: "a", gate)
        await h.backend.setRadio(seed: "a", tracks: MusicSamples.tracks("a", "r1", "r2"))

        h.service.play(MusicSamples.track("a"))
        let stale = h.service.radioTask
        h.service.play(MusicSamples.track("p1"), in: page(["p1", "p2"]))
        await h.settle()

        await gate.open()
        await stale?.value

        #expect(h.queuedIDs == ["p1", "p2"])
        #expect(h.service.queue.source == .page(browseId: Self.browseId))
    }

    @Test("playing a single track after a page goes back to a radio queue")
    func radioAfterPage() async {
        let h = Harness()
        await h.backend.setRadio(seed: "z", tracks: MusicSamples.tracks("z", "r1"))
        await startPage(h, ["a", "b", "c"], continuation: "t1")

        h.service.play(MusicSamples.track("z"))
        await h.settle()

        #expect(h.queuedIDs == ["z", "r1"])
        #expect(h.service.queue.source == .radio(seedVideoId: "z"))
        #expect(await h.backend.radioSeeds == ["z"])
    }

    @Test("tapping another row of the same page restarts the queue on that row")
    func tapAnotherRow() async {
        let h = Harness()
        await startPage(h, ["a", "b", "c", "d"], tap: "b")
        await startPage(h, ["a", "b", "c", "d"], tap: "d")

        #expect(h.queuedIDs == ["a", "b", "c", "d"])
        #expect(h.service.queue.current?.videoId == "d")
        #expect(h.loadedIDs == ["b", "d"])
        #expect(await h.backend.radioSeeds.isEmpty)
    }
}

// MARK: - Browse reset

@MainActor
@Suite("MusicService browse")
struct MusicServiceBrowseTests {
    private static let current = [StoredCookie(MusicSamples.cookie("SAPISID", domain: ".youtube.com"))]
    private static let picked = [StoredCookie(MusicSamples.cookie("__Secure-3PAPISID", domain: ".youtube.com"))]

    /// A signed-in service whose Home has loaded one shelf and whose Library has opened one page.
    private func loadedHarness() async -> Harness {
        let h = Harness(signedIn: true)
        await h.backend.setSessionCookies(Self.current)
        await h.backend.setChannelIdentity(false)
        await h.backend.setHome(shelves: [MusicSamples.shelf("Quick picks", "VLPL1")])
        await h.backend.setLibrary(.playlists, items: MusicSamples.collections("VLPL2"))
        await h.service.refreshAuth()
        await h.service.identityTask?.value
        h.service.browse.loadHomeIfNeeded()
        h.service.browse.loadLibraryIfNeeded(.playlists)
        let loaded = await h.eventually {
            h.service.browse.home == .loaded([MusicSamples.shelf("Quick picks", "VLPL1")])
                && h.service.browse.libraryState(.playlists) == .loaded(MusicSamples.collections("VLPL2"))
        }
        #expect(loaded)
        h.service.browse.tab = .library
        h.service.browse.librarySection = .albums
        return h
    }

    private func isEmpty(_ browse: MusicBrowseStore) -> Bool {
        browse.home == .idle && browse.libraryState(.playlists) == .idle && browse.path.isEmpty && browse.pages.isEmpty
    }

    @Test("the service owns a store that loads through its backend")
    func storeLoads() async {
        let h = await loadedHarness()
        #expect(await h.backend.homeCallCount == 1)
        #expect(await h.backend.libraryCalls == [.playlists])
    }

    @Test("signOut empties Home, Library and the open pages but keeps the chosen tab")
    func signOutResetsBrowse() async {
        let h = await loadedHarness()
        h.service.browse.open(MusicSamples.collection("VLPL1"))
        #expect(await h.eventually { h.service.browse.pages["VLPL1"] != nil })

        h.service.signOut()
        await h.service.signOutTask?.value

        #expect(h.service.authState == .signedOut)
        #expect(isEmpty(h.service.browse))
        #expect(h.service.browse.tab == .library)
        #expect(h.service.browse.librarySection == .albums)
    }

    @Test("a search that finds the session gone empties Home, Library and the open pages")
    func deadSessionFromSearchResetsBrowse() async {
        let h = await loadedHarness()
        h.service.browse.open(MusicSamples.collection("VLPL1"))
        #expect(await h.eventually { h.service.browse.pages["VLPL1"] != nil })
        await h.backend.setSearchError("q", MusicError.signedOut)

        h.service.query = "q"
        h.service.search()
        await h.service.searchTask?.value
        await h.service.signOutTask?.value

        #expect(h.service.authState == .signedOut)
        #expect(isEmpty(h.service.browse))
    }

    @Test("a loaded Home is not shown again after signing out and back in")
    func signOutThenLoadAgain() async {
        let h = await loadedHarness()
        h.service.signOut()
        await h.service.signOutTask?.value
        await h.backend.setHome(shelves: [MusicSamples.shelf("Other account", "VLPL9")])

        h.service.browse.loadHomeIfNeeded()
        let reloaded = await h.eventually { h.service.browse.home == .loaded([MusicSamples.shelf("Other account", "VLPL9")]) }

        #expect(reloaded)
        #expect(await h.backend.homeCallCount == 2)
    }

    @Test("a channel switch empties what the old channel loaded")
    func channelSwitchResetsBrowse() async {
        let h = await loadedHarness()
        h.service.switchChannel()
        await h.service.channelSwitchTask?.value
        #expect(isEmpty(h.service.browse) == false)

        h.probe.pickerCompletion?(Self.picked)
        await h.service.channelSwitchTask?.value
        await h.service.identityTask?.value

        #expect(await h.backend.signInCookies == [Self.picked])
        #expect(h.service.authState == .signedIn)
        #expect(isEmpty(h.service.browse))
        #expect(h.service.browse.tab == .library)
    }

    @Test("a closed channel picker keeps what is loaded")
    func closedPickerKeepsBrowse() async {
        let h = await loadedHarness()
        h.service.switchChannel()
        await h.service.channelSwitchTask?.value
        h.probe.pickerCompletion?(nil)
        await h.service.channelSwitchTask?.value

        #expect(isEmpty(h.service.browse) == false)
    }

    @Test("a failed channel switch keeps what is loaded")
    func failedSwitchKeepsBrowse() async {
        let h = await loadedHarness()
        await h.backend.setSignInError(MusicError.signedOut)
        h.service.switchChannel()
        await h.service.channelSwitchTask?.value
        h.probe.pickerCompletion?(Self.picked)
        await h.service.channelSwitchTask?.value

        #expect(h.service.authState == .signedIn)
        #expect(isEmpty(h.service.browse) == false)
    }

    @Test("a Home that finds the session dead signs the service out and empties the store")
    func browseSignedOut() async {
        let h = await loadedHarness()
        await h.backend.setHomeError(MusicError.signedOut)
        h.service.browse.reloadHome()
        #expect(await h.eventually { h.service.authState == .signedOut })
        await h.service.signOutTask?.value

        #expect(await h.backend.signOutCount == 1)
        #expect(h.service.lastError == nil)
        #expect(isEmpty(h.service.browse))
    }

    @Test("a Library page that finds the session dead signs the service out too")
    func libraryPageSignedOut() async {
        let h = await loadedHarness()
        await h.backend.setPageError("VLPL1", MusicError.signedOut)
        h.service.browse.open(MusicSamples.collection("VLPL1"))
        #expect(await h.eventually { h.service.authState == .signedOut })
        await h.service.signOutTask?.value

        #expect(isEmpty(h.service.browse))
    }

    @Test("a Home that fails for any other reason leaves the session and the store's error alone")
    func otherBrowseErrorKeepsSession() async {
        let h = await loadedHarness()
        await h.backend.setHomeError(URLError(.notConnectedToInternet))
        h.service.browse.reloadHome()
        #expect(await h.eventually {
            if case .failed = h.service.browse.home { return true }
            return false
        })

        #expect(h.service.authState == .signedIn)
        #expect(await h.backend.signOutCount == 0)
        #expect(h.service.browse.libraryState(.playlists) == .loaded(MusicSamples.collections("VLPL2")))
    }

    @Test("a service with no sign-in never asks the backend for Home on its own")
    func noAutoLoad() async {
        let h = Harness(signedIn: false)
        await h.service.refreshAuth()
        #expect(await h.backend.homeCallCount == 0)
        #expect(h.service.browse.home == .idle)
    }
}

// MARK: - Waiting for the radio

@MainActor
@Suite("MusicService waiting for radio")
struct MusicServiceRadioWaitTests {
    /// Plays `a` with nothing queued behind it and the next radio page held at `gate`.
    private func startHeld(_ h: Harness, gate: MusicTestGate, page: [MusicTrack] = MusicSamples.tracks("b")) async {
        await h.backend.setRadio(seed: "a", tracks: MusicSamples.tracks("a"), continuation: "c1")
        await h.backend.setMoreRadioGate(seed: "a", continuation: "c1", gate)
        await h.backend.setMoreRadio(seed: "a", continuation: "c1", tracks: page)
        h.service.play(MusicSamples.track("a"))
        await h.service.playTask?.value
        let held = await h.eventually { await h.backend.moreRadioCalls.count == 1 }
        #expect(held)
        h.engine.emit(.playingChanged(true))
    }

    @Test("a track that ends while the radio is still loading starts the next one when the page lands")
    func endedWaits() async {
        let h = Harness()
        let gate = MusicTestGate()
        await startHeld(h, gate: gate)

        h.engine.emit(.ended)
        #expect(h.service.queue.current?.videoId == "a")
        #expect(h.player.hasEnded)

        await gate.open()
        await h.settle()

        #expect(h.loadedIDs == ["a", "b"])
        #expect(h.service.queue.current?.videoId == "b")
        #expect(h.player.nowPlaying?.videoId == "b")
    }

    @Test("next while the radio is still loading keeps playing and moves on when the page lands")
    func nextWaits() async {
        let h = Harness()
        let gate = MusicTestGate()
        await startHeld(h, gate: gate)

        h.service.next()
        #expect(h.player.nowPlaying?.videoId == "a")
        #expect(h.queuedIDs == ["a"])
        #expect(h.probe.nativeChanges == [true])

        await gate.open()
        await h.settle()

        #expect(h.loadedIDs == ["a", "b"])
        #expect(h.service.queue.current?.videoId == "b")
    }

    @Test("next stops as before when the radio has nothing more")
    func nextEndsWhenRadioRunsDry() async {
        let h = Harness()
        let gate = MusicTestGate()
        await startHeld(h, gate: gate, page: [])

        h.service.next()
        await gate.open()
        await h.settle()

        #expect(h.service.queue.isEmpty)
        #expect(h.player.nowPlaying == nil)
        #expect(h.probe.nativeChanges == [true, false])
    }

    @Test("next stops as before when the radio fetch fails")
    func nextEndsWhenRadioFails() async {
        let h = Harness()
        let gate = MusicTestGate()
        await startHeld(h, gate: gate)
        await h.backend.setMoreRadioError(seed: "a", continuation: "c1", URLError(.timedOut))

        h.service.next()
        await gate.open()
        await h.settle()

        #expect(h.service.queue.isEmpty)
        #expect(h.player.nowPlaying == nil)
        #expect(h.loadedIDs == ["a"])
    }

    @Test("a track that ended stays on the finished song when the radio has nothing more")
    func endedStaysWhenRadioRunsDry() async {
        let h = Harness()
        let gate = MusicTestGate()
        await startHeld(h, gate: gate, page: [])

        h.engine.emit(.ended)
        await gate.open()
        await h.settle()

        #expect(h.player.nowPlaying?.videoId == "a")
        #expect(h.player.hasEnded)
        #expect(h.queuedIDs == ["a"])
        #expect(h.loadedIDs == ["a"])
    }

    @Test("a stream that dies while the radio is still loading waits for it instead of giving up the queue")
    func playerFailureWaits() async {
        let h = Harness()
        let gate = MusicTestGate()
        await startHeld(h, gate: gate)

        h.engine.emit(.failed)
        await h.player.refreshTask?.value
        h.engine.emit(.failed)
        #expect(h.queuedIDs == ["a"])
        #expect(h.player.error == "Couldn't play this track.")

        await gate.open()
        await h.settle()

        #expect(h.loadedIDs == ["a", "a", "b"])
        #expect(h.player.nowPlaying?.videoId == "b")
        #expect(h.player.error == nil)
    }

    @Test("a stream that dies keeps its error and ends the queue when the radio has nothing more")
    func playerFailureEndsWhenRadioRunsDry() async {
        let h = Harness()
        let gate = MusicTestGate()
        await startHeld(h, gate: gate, page: [])

        h.engine.emit(.failed)
        await h.player.refreshTask?.value
        h.engine.emit(.failed)
        await gate.open()
        await h.settle()

        #expect(h.player.error == "Couldn't play this track.")
        #expect(h.service.queue.isEmpty)
    }

    @Test("starting another track cancels the wait")
    func beginCancelsWait() async {
        let h = Harness()
        let gate = MusicTestGate()
        await h.backend.setRadio(seed: "a", tracks: MusicSamples.tracks("a", "b"), continuation: "c1")
        await h.backend.setMoreRadioGate(seed: "a", continuation: "c1", gate)
        await h.backend.setMoreRadio(seed: "a", continuation: "c1", tracks: MusicSamples.tracks("c"))
        h.service.play(MusicSamples.track("a"))
        await h.service.playTask?.value
        let held = await h.eventually { await h.backend.moreRadioCalls.count == 1 }
        #expect(held)

        h.service.next()
        await h.service.playTask?.value
        h.service.next()
        h.service.previous()
        await h.service.playTask?.value
        await gate.open()
        await h.settle()

        #expect(h.loadedIDs == ["a", "b", "a"])
        #expect(h.service.queue.current?.videoId == "a")
        #expect(h.queuedIDs == ["a", "b", "c"])
    }

    @Test("a wait gets a fresh attempt even when the last top-up ended on the empty-page cap")
    func waitAfterCap() async {
        let h = Harness()
        let repeats = MusicSamples.tracks("b", "c")
        for (index, continuation) in ["c1", "c2", "c3", "c4", "c5", "c6"].enumerated() {
            await h.backend.setMoreRadio(seed: "a", continuation: continuation, tracks: repeats, next: "c\(index + 2)")
        }
        await h.backend.setMoreRadio(seed: "a", continuation: "c7", tracks: MusicSamples.tracks("z"))
        await h.startQueue(["a", "b", "c"], continuation: "c1")
        h.service.jump(to: h.service.queue.tracks[2])
        await h.settle()
        #expect(await h.backend.moreRadioCalls.count == 6)

        h.engine.emit(.playingChanged(true))
        h.engine.emit(.ended)
        await h.settle()

        #expect(await h.backend.moreRadioCalls.last?.continuation == "c7")
        #expect(h.queuedIDs == ["a", "b", "c", "z"])
        #expect(h.player.nowPlaying?.videoId == "z")
    }
}

// MARK: - Moving through the queue

@MainActor
@Suite("MusicService queue navigation")
struct MusicServiceNavigationTests {
    @Test("a track that ends starts the next one")
    func autoplay() async {
        let h = Harness()
        await h.startQueue(["a", "b", "c"])
        h.engine.emit(.ended)
        await h.settle()

        #expect(h.loadedIDs == ["a", "b"])
        #expect(h.service.queue.current?.videoId == "b")
        #expect(h.player.nowPlaying?.videoId == "b")
    }

    @Test("the last track ending leaves the player on the finished song and releases Now Playing")
    func endOfQueue() async {
        let h = Harness()
        await h.startQueue(["a"])
        h.engine.emit(.ended)
        await h.settle()

        #expect(h.loadedIDs == ["a"])
        #expect(h.player.nowPlaying?.videoId == "a")
        #expect(h.player.hasEnded)
        #expect(h.probe.nativeChanges == [true, false])
        #expect(h.surface.clearCount == 1)
        #expect(h.surface.hasCommands == false)
    }

    @Test("next moves on, and at the end of the queue stops playback")
    func nextAndEnd() async {
        let h = Harness()
        await h.startQueue(["a", "b"])
        #expect(h.service.canGoNext)
        h.service.next()
        await h.settle()
        #expect(h.loadedIDs == ["a", "b"])
        #expect(h.service.canGoNext == false)

        h.service.next()

        #expect(h.player.nowPlaying == nil)
        #expect(h.service.queue.isEmpty)
        #expect(h.loadedIDs == ["a", "b"])
    }

    @Test("previous restarts a track past three seconds and otherwise goes back", arguments: [
        (3.1, true), (3.0, false), (0.0, false),
    ])
    func previousRule(position: Double, restarts: Bool) async {
        let h = Harness()
        await h.startQueue(["a", "b"])
        h.service.next()
        await h.settle()
        h.engine.emit(.playingChanged(true))
        h.engine.tick(position, playing: true)

        h.service.previous()
        await h.settle()

        if restarts {
            #expect(h.engine.seeks == [0])
            #expect(h.loadedIDs == ["a", "b"])
            #expect(h.service.queue.current?.videoId == "b")
        } else {
            #expect(h.engine.seeks.isEmpty)
            #expect(h.loadedIDs == ["a", "b", "a"])
            #expect(h.service.queue.current?.videoId == "a")
        }
    }

    @Test("previous on the first track restarts it however little has played")
    func previousAtFirst() async {
        let h = Harness()
        await h.startQueue(["a", "b"])
        h.engine.tick(1, playing: true)

        h.service.previous()
        await h.settle()

        #expect(h.engine.seeks == [0])
        #expect(h.loadedIDs == ["a"])
        #expect(h.service.queue.current?.videoId == "a")
    }

    @Test("previous after the track ended replays it")
    func previousAfterEnd() async {
        let h = Harness()
        await h.startQueue(["a"])
        h.engine.emit(.ended)

        h.service.previous()

        #expect(h.engine.seeks == [0])
        #expect(h.engine.playCount == 1)
        #expect(h.player.hasEnded == false)
    }

    @Test("previous with nothing loaded does nothing")
    func previousIdle() {
        let h = Harness()
        h.service.previous()
        #expect(h.engine.seeks.isEmpty)
        #expect(h.engine.loads.isEmpty)
    }

    @Test("jumping to a queued track plays it, and an unknown track is ignored")
    func jump() async {
        let h = Harness()
        await h.startQueue(["a", "b", "c", "d"])
        let tracks = h.service.queue.tracks

        h.service.jump(to: tracks[3])
        await h.settle()
        #expect(h.loadedIDs == ["a", "d"])
        #expect(h.service.queue.upcomingCount == 0)

        h.service.jump(to: MusicSamples.track("zzz"))
        await h.settle()
        #expect(h.loadedIDs == ["a", "d"])

        h.service.jump(to: tracks[1])
        await h.settle()
        #expect(h.loadedIDs == ["a", "d", "b"])
        #expect(h.queuedIDs == ["a", "b", "c", "d"])
        #expect(h.service.queue.current?.videoId == "b")
    }
}

// MARK: - Failures

@MainActor
@Suite("MusicService skipping")
struct MusicServiceSkipTests {
    @Test("a track that cannot be resolved is skipped")
    func resolveFailureSkips() async {
        let h = Harness()
        await h.startQueue(["a", "b", "c"])
        await h.backend.setResolveError("b", MusicError.unplayable("Private"))

        h.service.next()
        await h.settle()

        #expect(h.loadedIDs == ["a", "c"])
        #expect(h.service.queue.current?.videoId == "c")
        #expect(h.service.lastError == nil)
    }

    @Test("going back skips a failed track backwards")
    func skipDirection() async {
        let h = Harness()
        await h.startQueue(["a", "b", "c", "d"])
        h.service.jump(to: h.service.queue.tracks[3])
        await h.settle()
        h.engine.emit(.playingChanged(true))
        await h.backend.setResolveError("c", MusicError.unplayable("Private"))

        h.service.previous()
        await h.settle()

        #expect(h.loadedIDs == ["a", "d", "b"])
        #expect(h.service.queue.current?.videoId == "b")
    }

    @Test("two failures in a row still reach the next playable track")
    func twoFailuresRecover() async {
        let h = Harness()
        await h.startQueue(["a", "b", "c", "d"])
        await h.backend.setResolveError("b", MusicError.noAudioFormat)
        await h.backend.setResolveError("c", MusicError.noAudioFormat)

        h.service.next()
        await h.settle()

        #expect(h.loadedIDs == ["a", "d"])
        #expect(h.service.lastError == nil)
    }

    @Test("the third failure in a row stops playback with an error but keeps the queue, so next still works")
    func threeFailuresStop() async {
        let h = Harness()
        await h.startQueue(["a", "b", "c", "d", "e"])
        for id in ["b", "c", "d"] {
            await h.backend.setResolveError(id, MusicError.noAudioFormat)
        }

        h.service.next()
        await h.settle()

        #expect(await h.backend.resolvedIDs == ["a", "b", "c", "d"])
        #expect(h.service.lastError == "No audio stream for this track.")
        #expect(h.player.nowPlaying == nil)
        #expect(h.queuedIDs == ["a", "b", "c", "d", "e"])
        #expect(h.service.queue.current?.videoId == "d")
        #expect(h.probe.nativeChanges == [true, false])

        h.service.next()
        await h.settle()

        #expect(h.loadedIDs == ["a", "e"])
        #expect(h.player.nowPlaying?.videoId == "e")
        #expect(h.service.lastError == nil)
    }

    @Test("a failure that says nothing about the track keeps it and the queue, and does not skip")
    func transientResolveFailureKeepsQueue() async {
        let errors: [any Error] = [
            URLError(.notConnectedToInternet), MusicError.http(503), MusicError.solver("x"), MusicError.parse("x"),
        ]
        for error in errors {
            let h = Harness()
            await h.startQueue(["a", "b", "c"])
            await h.backend.setResolveError("b", error)

            h.service.next()
            await h.settle()

            #expect(await h.backend.resolvedIDs == ["a", "b"])
            #expect(h.loadedIDs == ["a"])
            #expect(h.queuedIDs == ["a", "b", "c"])
            #expect(h.service.queue.current?.videoId == "b")
            #expect(h.player.nowPlaying?.videoId == "b")
            #expect(h.player.isActive == false)
            #expect(h.service.lastError == MusicService.message(for: error))
            #expect(h.probe.nativeChanges == [true, false])

            h.service.next()
            await h.settle()

            #expect(h.loadedIDs == ["a", "c"])
            #expect(h.player.nowPlaying?.videoId == "c")
            #expect(h.service.lastError == nil)
        }
    }

    @Test("Play after a failure that says nothing about the track tries it again, from the transport or a media key")
    func playRetriesUnresolvedTrack() async {
        for command in [NowPlayingCommand.toggle, .play] {
            let h = Harness()
            await h.startQueue(["a", "b", "c"])
            await h.backend.setResolveError("b", URLError(.notConnectedToInternet))
            h.service.next()
            await h.settle()
            #expect(h.loadedIDs == ["a"])

            await h.backend.clearResolveError("b")
            h.service.togglePlayback()
            await h.settle()

            #expect(await h.backend.resolvedIDs == ["a", "b", "b"])
            #expect(h.loadedIDs == ["a", "b"])
            #expect(h.queuedIDs == ["a", "b", "c"])
            #expect(h.service.lastError == nil)

            // The same through Now Playing, after another failure.
            await h.backend.setResolveError("c", URLError(.timedOut))
            h.service.next()
            await h.settle()
            await h.backend.clearResolveError("c")
            h.surface.send(command)
            await h.settle()

            #expect(h.loadedIDs == ["a", "b", "c"])
            #expect(h.player.nowPlaying?.videoId == "c")
        }
    }

    @Test("a first track that cannot be resolved over the network stays selected with the error line")
    func transientFirstTrack() async {
        let h = Harness()
        await h.backend.setResolveError("abc", URLError(.timedOut))

        await h.startPlaying(MusicSamples.track("abc"))

        #expect(h.service.lastError == "Network problem. Check your connection.")
        #expect(h.player.nowPlaying?.videoId == "abc")
        #expect(h.player.isActive == false)
        #expect(h.queuedIDs == ["abc"])
    }

    @Test("a network failure as the third failure in a row stops playback and keeps the queue")
    func thirdTransientStops() async {
        let h = Harness()
        await h.startQueue(["a", "b", "c", "d", "e"])
        await h.backend.setResolveError("b", MusicError.noAudioFormat)
        await h.backend.setResolveError("c", MusicError.noAudioFormat)
        await h.backend.setResolveError("d", URLError(.timedOut))

        h.engine.emit(.ended)
        await h.settle()

        #expect(await h.backend.resolvedIDs == ["a", "b", "c", "d"])
        #expect(h.player.nowPlaying == nil)
        #expect(h.queuedIDs == ["a", "b", "c", "d", "e"])
        #expect(h.service.queue.current?.videoId == "d")
        #expect(h.service.lastError == "Network problem. Check your connection.")
    }

    @Test("a stream that cannot be reloaded because of the network keeps the track and the queue")
    func playerFailureTransient() async {
        let h = Harness()
        await h.startQueue(["a", "b", "c"])
        await h.backend.setResolveError("a", URLError(.notConnectedToInternet))

        h.engine.emit(.failed)
        await h.player.refreshTask?.value
        await h.settle()

        #expect(h.loadedIDs == ["a"])
        #expect(h.queuedIDs == ["a", "b", "c"])
        #expect(h.service.queue.current?.videoId == "a")
        #expect(h.player.nowPlaying?.videoId == "a")
        #expect(h.player.error == "Couldn't reload this track.")
        #expect(h.service.lastError == "Network problem. Check your connection.")
    }

    @Test("a stream that cannot be reloaded because the track is unplayable skips to the next one")
    func playerFailureUnplayableSkips() async {
        let h = Harness()
        await h.startQueue(["a", "b", "c"])
        await h.backend.setResolveError("a", MusicError.unplayable("Gone"))

        h.engine.emit(.failed)
        await h.player.refreshTask?.value
        await h.settle()

        #expect(h.loadedIDs == ["a", "b"])
        #expect(h.player.nowPlaying?.videoId == "b")
        #expect(h.service.lastError == nil)
    }

    @Test("a track that plays resets the failure count")
    func playingResetsStreak() async {
        let h = Harness()
        await h.startQueue(["a", "b", "c", "d", "e", "f", "g"])
        for id in ["b", "d", "e"] {
            await h.backend.setResolveError(id, MusicError.noAudioFormat)
        }

        h.engine.emit(.ended)
        await h.settle()
        #expect(h.loadedIDs == ["a", "c"])

        h.engine.emit(.playingChanged(true))
        h.engine.emit(.ended)
        await h.settle()

        #expect(h.loadedIDs == ["a", "c", "f"])
        #expect(h.player.nowPlaying?.videoId == "f")
        #expect(h.service.lastError == nil)
    }

    @Test("a stream that dies twice skips to the next track")
    func playerFailureSkips() async {
        let h = Harness()
        await h.startQueue(["a", "b", "c"])
        h.engine.emit(.failed)
        await h.player.refreshTask?.value
        h.engine.emit(.failed)
        await h.settle()

        #expect(h.loadedIDs == ["a", "a", "b"])
        #expect(h.player.nowPlaying?.videoId == "b")
        #expect(h.player.error == nil)
    }

    @Test("a stream that dies with nothing queued behind it keeps the error")
    func playerFailureLast() async {
        let h = Harness()
        await h.startQueue(["a"])
        h.engine.emit(.failed)
        await h.player.refreshTask?.value
        h.engine.emit(.failed)
        await h.settle()

        #expect(h.player.error == "Couldn't play this track.")
        #expect(h.service.queue.isEmpty)
        #expect(h.probe.nativeChanges == [true, false])
    }

    @Test("a sign-out found while advancing ends the queue and signs out")
    func signedOutWhileAdvancing() async {
        let h = Harness()
        await h.service.refreshAuth()
        await h.startQueue(["a", "b"])
        await h.backend.setResolveError("b", MusicError.signedOut)

        h.service.next()
        await h.settle()
        await h.service.signOutTask?.value

        #expect(h.service.authState == .signedOut)
        #expect(h.service.queue.isEmpty)
        #expect(h.player.nowPlaying == nil)
        #expect(await h.backend.signOutCount == 1)
        #expect(h.loadedIDs == ["a"])
    }
}

// MARK: - Sessions

@MainActor
@Suite("MusicService per-track sessions")
struct MusicServiceSessionTests {
    @Test("every queued track gets its own CPN and its own history ping")
    func perTrackPing() async {
        let h = Harness()
        let urlA = URL(string: "https://music.example.test/stats?ev=a")!
        let urlB = URL(string: "https://music.example.test/stats?ev=b")!
        await h.backend.setStream(MusicSamples.stream(videoId: "a", trackingURL: urlA))
        await h.backend.setStream(MusicSamples.stream(videoId: "b", trackingURL: urlB))
        await h.startQueue(["a", "b"])
        h.listen(seconds: 31)
        await h.service.reportTask?.value

        h.engine.emit(.ended)
        await h.settle()
        h.engine.emit(.playingChanged(true))
        h.listen(seconds: 31)
        await h.service.reportTask?.value

        let reports = await h.backend.reportAttempts
        #expect(reports.map(\.url) == [urlA, urlB])
        #expect(reports.allSatisfy { isValidCPN($0.cpn) })
        #expect(Set(reports.map(\.cpn)).count == 2)
    }

    @Test("each track's watchtime ping shares its own playback ping's CPN and not the other track's")
    func perTrackWatchtimeCPN() async {
        let h = Harness()
        for id in ["a", "b"] {
            await h.backend.setStream(MusicSamples.stream(
                videoId: id,
                trackingURL: URL(string: "https://music.example.test/stats/playback?ev=\(id)")!,
                watchtimeURL: URL(string: "https://music.example.test/stats/watchtime?ev=\(id)")!
            ))
        }
        await h.startQueue(["a", "b"])
        h.listen(seconds: 31)
        await h.service.reportTask?.value

        h.engine.emit(.ended)
        await h.settle()
        h.engine.emit(.playingChanged(true))
        h.listen(seconds: 31)
        await h.service.reportTask?.value

        let reports = await h.backend.reportAttempts
        #expect(reports.map(\.kind) == [.playback, .watchtime, .playback, .watchtime])
        #expect(reports[0].cpn == reports[1].cpn)
        #expect(reports[2].cpn == reports[3].cpn)
        #expect(reports[0].cpn != reports[2].cpn)
    }

    @Test("listening time does not carry over to the next track")
    func noCarryOver() async {
        let h = Harness()
        await h.startQueue(["a", "b"])
        h.listen(seconds: 20)
        h.service.next()
        await h.settle()
        h.engine.emit(.playingChanged(true))
        h.listen(seconds: 20)

        #expect(h.service.reportTask == nil)
    }
}

// MARK: - Seek

@MainActor
@Suite("MusicService seek")
struct MusicServiceSeekTests {
    @Test("seek goes through the engine")
    func seekForwarded() async {
        let h = Harness()
        await h.startQueue(["a"])
        h.service.seek(to: 120)
        #expect(h.engine.seeks == [120])
        #expect(h.player.currentTime == 120)
    }

    @Test("seek with nothing playing does nothing")
    func seekIdle() {
        let h = Harness()
        h.service.seek(to: 10)
        #expect(h.engine.seeks.isEmpty)
    }

    @Test("a short seek forward is not counted as listening")
    func shortSeekNotCounted() async {
        let h = Harness()
        await h.startQueue(["a"])
        h.listen(seconds: 29)

        h.service.seek(to: 30)
        h.engine.tick(30.5, playing: true)

        #expect(h.service.reportTask == nil)
        #expect(await h.backend.reportAttempts.isEmpty)
    }
}

// MARK: - Prefetch

@MainActor
@Suite("MusicService prefetch")
struct MusicServicePrefetchTests {
    @Test("the next track is resolved shortly before the end and used when it starts")
    func prefetchesNearEnd() async {
        let h = Harness()
        await h.startQueue(["a", "b", "c"])
        h.engine.tick(150, playing: true)
        await h.service.prefetchTask?.value
        #expect(await h.backend.resolvedIDs == ["a"])

        h.engine.tick(186, playing: true)
        await h.service.prefetchTask?.value
        h.engine.tick(187, playing: true)
        await h.service.prefetchTask?.value
        #expect(await h.backend.resolvedIDs == ["a", "b"])

        h.engine.emit(.ended)
        await h.settle()

        #expect(h.loadedIDs == ["a", "b"])
        #expect(await h.backend.resolvedIDs == ["a", "b"])
    }

    @Test("a prefetched stream about to expire is not used")
    func expiringPrefetchNotUsed() async {
        let h = Harness()
        await h.backend.setStream(MusicSamples.stream(videoId: "b", expiresAt: Date().addingTimeInterval(30)))
        await h.startQueue(["a", "b"])
        h.engine.tick(186, playing: true)
        await h.service.prefetchTask?.value

        h.engine.emit(.ended)
        await h.settle()

        #expect(await h.backend.resolvedIDs == ["a", "b", "b"])
        #expect(h.loadedIDs == ["a", "b"])
    }

    @Test("jumping elsewhere resolves the chosen track itself")
    func jumpIgnoresPrefetch() async {
        let h = Harness()
        await h.startQueue(["a", "b", "c"])
        h.engine.tick(186, playing: true)
        await h.service.prefetchTask?.value

        h.service.jump(to: h.service.queue.tracks[2])
        await h.settle()

        #expect(await h.backend.resolvedIDs == ["a", "b", "c"])
        #expect(h.loadedIDs == ["a", "c"])
    }

    @Test("a short track is never prefetched")
    func shortTrackSkipped() async {
        let h = Harness()
        await h.backend.setStream(MusicSamples.stream(videoId: "a", duration: 20))
        await h.startQueue(["a", "b"])
        h.engine.tick(10, playing: true)
        #expect(h.service.prefetchTask == nil)
        #expect(await h.backend.resolvedIDs == ["a"])
    }
}

// MARK: - Native playing flag

@MainActor
@Suite("MusicService native playing flag")
struct MusicServiceNativeFlagTests {
    @Test("it turns on with a play, off with a pause, and on again")
    func flips() async {
        let h = Harness()
        #expect(h.probe.nativeChanges.isEmpty)

        h.service.play(MusicSamples.track("a"))
        await h.settle()
        h.engine.emit(.playingChanged(true))
        #expect(h.probe.nativeChanges == [true])

        h.player.pause()
        h.engine.emit(.playingChanged(false))
        #expect(h.probe.nativeChanges == [true, false])

        h.player.play()
        #expect(h.probe.nativeChanges == [true, false, true])
    }

    @Test("a stall does not flip it")
    func stallKeepsFlag() async {
        let h = Harness()
        await h.startQueue(["a"])
        h.engine.emit(.playingChanged(false))
        h.engine.emit(.playingChanged(true))
        #expect(h.probe.nativeChanges == [true])
    }

    @Test("moving between tracks does not flip it")
    func autoplayKeepsFlag() async {
        let h = Harness()
        await h.startQueue(["a", "b", "c"])
        h.engine.emit(.ended)
        await h.settle()
        h.engine.emit(.playingChanged(true))
        h.service.next()
        await h.settle()
        h.engine.emit(.playingChanged(true))
        #expect(h.probe.nativeChanges == [true])
    }

    @Test("it turns off when the queue ends and when the user signs out")
    func endsAndSignOut() async {
        let ended = Harness()
        await ended.startQueue(["a", "b"])
        ended.engine.emit(.ended)
        await ended.settle()
        ended.engine.emit(.playingChanged(true))
        ended.engine.emit(.ended)
        #expect(ended.probe.nativeChanges == [true, false])

        let signedOut = Harness()
        await signedOut.startQueue(["a"])
        signedOut.service.signOut()
        #expect(signedOut.probe.nativeChanges == [true, false])
    }
}

// MARK: - Now Playing and media keys

@MainActor
@Suite("MusicService Now Playing")
struct MusicServiceNowPlayingTests {
    @Test("nothing is registered until the first native play")
    func lazyRegistration() async {
        let h = Harness()
        await h.backend.setSearch("q", results: [MusicSamples.track()])
        await h.service.refreshAuth()
        h.service.query = "q"
        h.service.search()
        await h.service.searchTask?.value
        #expect(h.surface.registerCount == 0)
        #expect(h.surface.published.isEmpty)

        h.service.play(MusicSamples.track())

        #expect(h.surface.registerCount == 1)
        #expect(h.surface.hasCommands)
    }

    @Test("one registration serves the whole queue")
    func registeredOnce() async {
        let h = Harness()
        await h.startQueue(["a", "b", "c"])
        h.service.next()
        await h.settle()
        h.service.next()
        await h.settle()

        #expect(h.surface.registerCount == 1)
        #expect(h.surface.removeCount == 0)
        #expect(h.surface.last?.title == "Song c")
    }

    @Test("sign-out releases the commands and the widget, and the next play registers again")
    func signOutReleases() async {
        let h = Harness()
        await h.startQueue(["a"])
        h.service.signOut()

        #expect(h.surface.removeCount == 1)
        #expect(h.surface.clearCount == 1)
        #expect(h.surface.hasCommands == false)

        h.service.play(MusicSamples.track("z"))
        #expect(h.surface.registerCount == 2)
    }

    @Test("the widget follows duration, play state and seeks, but not every tick")
    func infoFollowsPlayer() async {
        let h = Harness()
        await h.startQueue(["a"])
        h.engine.emit(.ready(duration: 187))
        #expect(h.surface.last?.duration == 187)
        #expect(h.surface.last?.rate == 1)

        let published = h.surface.published.count
        for position in [40.0, 41.0, 42.0] { h.engine.tick(position, playing: true) }
        #expect(h.surface.published.count == published)

        h.player.pause()
        h.engine.emit(.playingChanged(false))
        #expect(h.surface.last?.isPlaying == false)
        #expect(h.surface.last?.rate == 0)
        #expect(h.surface.last?.elapsed == 42)

        h.service.seek(to: 100)
        #expect(h.surface.last?.elapsed == 100)
    }

    @Test("a pause publishes where playback stopped, not the last half-second tick")
    func pauseElapsedIsExact() async {
        let h = Harness()
        await h.startQueue(["a"])
        h.engine.emit(.ready(duration: 187))
        h.engine.tick(60, playing: true)
        h.engine.position = 61.6

        h.engine.emit(.playingChanged(false))

        #expect(h.surface.last?.elapsed == 61.6)
        #expect(h.surface.last?.rate == 0)
    }

    @Test("next and previous keys move through the queue")
    func remoteNextPrevious() async {
        let h = Harness()
        await h.startQueue(["a", "b", "c"])

        h.surface.send(.next)
        await h.settle()
        #expect(h.service.queue.current?.videoId == "b")

        h.surface.send(.previous)
        await h.settle()
        #expect(h.service.queue.current?.videoId == "a")
        #expect(h.loadedIDs == ["a", "b", "a"])
    }

    @Test("play, pause, toggle and the scrubber reach the player")
    func remotePlaybackKeys() async {
        let h = Harness()
        await h.startQueue(["a"])

        h.surface.send(.toggle)
        #expect(h.engine.pauseCount == 1)
        h.engine.emit(.playingChanged(false))

        h.surface.send(.play)
        #expect(h.engine.playCount == 1)

        h.surface.send(.pause)
        #expect(h.engine.pauseCount == 2)

        h.surface.send(.seek(90))
        #expect(h.engine.seeks == [90])
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
                nowPlaying: NowPlayingController(surface: FakeNowPlayingSurface(), fetchArtwork: { _ in nil }),
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

    @Test("the account card starts closed")
    func accountCardStartsClosed() {
        #expect(makeHost(Counter()).isAccountCardOpen == false)
    }

    @Test("closeAccountCard closes an open card and says it used the key")
    func closeAccountCardWhenOpen() {
        let host = makeHost(Counter())
        host.isAccountCardOpen = true
        #expect(host.closeAccountCard() == true)
        #expect(host.isAccountCardOpen == false)
    }

    @Test("closeAccountCard on a closed card does nothing and lets the key pass")
    func closeAccountCardWhenClosed() {
        let host = makeHost(Counter())
        #expect(host.closeAccountCard() == false)
        #expect(host.isAccountCardOpen == false)
    }

    @Test("shutdown before the tab was ever opened is a no-op")
    func shutdownWithoutService() {
        let counter = Counter()
        let host = makeHost(counter)
        host.shutdown()
        #expect(host.service == nil)
        #expect(counter.builds == 0)
    }

    @Test("the native playing callback reaches the host, set before or after the service exists")
    func nativePlayingForwarded() async throws {
        let counter = Counter()
        let host = makeHost(counter)
        var seen: [Bool] = []
        host.onNativePlayingChange = { seen.append($0) }
        #expect(seen.isEmpty)

        host.loadIfNeeded()
        let service = try #require(host.service)
        service.play(MusicSamples.track())
        await service.playTask?.value
        #expect(seen == [true])

        host.shutdown()
        #expect(seen == [true, false])
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

    @Test("a play state change takes the exact position from the engine, not the last tick")
    func playingChangedReadsPosition() {
        let rig = Rig()
        rig.load()
        rig.engine.emit(.playingChanged(true))
        rig.engine.tick(42, playing: true)
        rig.engine.position = 42.4

        rig.engine.emit(.playingChanged(false))

        #expect(rig.player.currentTime == 42.4)
    }

    @Test("a play state change while the stream is still loading leaves the position alone")
    func playingChangedWhileLoading() {
        let rig = Rig()
        rig.load()
        rig.engine.position = 99

        rig.engine.emit(.playingChanged(false))

        #expect(rig.player.isLoading)
        #expect(rig.player.currentTime == 0)
    }

    @Test("a play state change after the track ended keeps the finished time")
    func playingChangedAfterEnd() {
        let rig = Rig()
        rig.load()
        rig.engine.emit(.playingChanged(true))
        rig.engine.emit(.ready(duration: 100))
        rig.engine.emit(.ended)
        rig.engine.position = 3

        rig.engine.emit(.playingChanged(false))

        #expect(rig.player.currentTime == 100)
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

    // MARK: Seek and state callbacks

    @Test("seek moves the clock and the engine, clamped to the track")
    func seekClamps() {
        let rig = Rig()
        rig.load()
        rig.engine.emit(.ready(duration: 187))
        rig.player.seek(to: 100)
        rig.player.seek(to: 999)
        rig.player.seek(to: -4)
        #expect(rig.engine.seeks == [100, 187, 0])
        #expect(rig.player.currentTime == 0)
    }

    @Test("seek is ignored with nothing loaded, during a refresh and for non-finite input")
    func seekIgnored() async {
        let rig = Rig()
        rig.player.seek(to: 10)
        #expect(rig.engine.seeks.isEmpty)

        rig.load()
        rig.player.seek(to: .nan)
        rig.player.seek(to: .infinity)
        #expect(rig.engine.seeks.isEmpty)

        let gate = MusicTestGate()
        rig.fresh.gate = gate
        rig.engine.emit(.failed)
        rig.player.seek(to: 10)
        #expect(rig.engine.seeks.isEmpty)
        await gate.open()
        await rig.player.refreshTask?.value
    }

    @Test("seeking after the track ended makes it live again")
    func seekAfterEnd() {
        let rig = Rig()
        rig.load()
        rig.engine.emit(.ready(duration: 200))
        rig.engine.emit(.playingChanged(true))
        rig.engine.emit(.ended)
        #expect(rig.player.hasEnded)

        rig.player.seek(to: 10)

        #expect(rig.player.hasEnded == false)
        #expect(rig.player.currentTime == 10)
    }

    @Test("onEnded fires before the state change that follows it")
    func endedOrdering() {
        let rig = Rig()
        rig.load()
        rig.engine.emit(.playingChanged(true))
        var events: [String] = []
        rig.player.onEnded = { events.append("ended") }
        rig.player.onStateChange = { events.append("state") }

        rig.engine.emit(.ended)

        #expect(events == ["ended", "state"])
    }

    @Test("onFailed fires when recovery is spent or the refresh fails, not on the first retry")
    func failedCallback() async {
        let spent = Rig()
        var spentCount = 0
        spent.player.onFailed = { spentCount += 1 }
        spent.load()
        spent.engine.emit(.failed)
        await spent.player.refreshTask?.value
        #expect(spentCount == 0)
        spent.engine.emit(.failed)
        #expect(spentCount == 1)

        let broken = Rig(fresh: .failure(MusicError.http(500)))
        var brokenCount = 0
        broken.player.onFailed = { brokenCount += 1 }
        broken.load()
        broken.engine.emit(.failed)
        await broken.player.refreshTask?.value
        #expect(brokenCount == 1)
    }

    @Test("isActive means a track that is playing, loading or wants to play")
    func isActiveRules() {
        let rig = Rig()
        #expect(rig.player.isActive == false)

        rig.player.beginLoading(MusicSamples.track())
        #expect(rig.player.isActive)

        rig.load()
        rig.engine.emit(.playingChanged(true))
        #expect(rig.player.isActive)

        rig.engine.emit(.playingChanged(false))
        #expect(rig.player.isActive)

        rig.player.pause()
        #expect(rig.player.isActive == false)

        rig.player.play()
        #expect(rig.player.isActive)

        rig.engine.emit(.ended)
        #expect(rig.player.isActive == false)

        rig.player.stop()
        #expect(rig.player.isActive == false)
    }

    @Test("every state-changing call tells onStateChange")
    func stateChangeCallbacks() {
        let rig = Rig()
        var count = 0
        rig.player.onStateChange = { count += 1 }
        func changed(_ step: () -> Void) -> Bool {
            let before = count
            step()
            return count > before
        }

        #expect(changed { rig.player.beginLoading(MusicSamples.track()) })
        #expect(changed { rig.load() })
        #expect(changed { rig.engine.emit(.playingChanged(true)) })
        #expect(changed { rig.player.pause() })
        #expect(changed { rig.player.play() })
        #expect(changed { rig.player.seek(to: 5) })
        #expect(changed { rig.player.stop() })
    }

    @Test("beginLoading clears the previous track's error")
    func beginLoadingClearsError() async {
        let rig = Rig()
        rig.load()
        rig.engine.emit(.failed)
        await rig.player.refreshTask?.value
        rig.engine.emit(.failed)
        #expect(rig.player.error != nil)

        rig.player.beginLoading(MusicSamples.track("next"))

        #expect(rig.player.error == nil)
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

    @Test("a touch position maps to a clamped fraction")
    func fraction() {
        #expect(MusicTimeFormat.fraction(x: 50, width: 200) == 0.25)
        #expect(MusicTimeFormat.fraction(x: -10, width: 200) == 0)
        #expect(MusicTimeFormat.fraction(x: 300, width: 200) == 1)
        #expect(MusicTimeFormat.fraction(x: 10, width: 0) == 0)
        #expect(MusicTimeFormat.fraction(x: .nan, width: 200) == 0)
    }

    @Test("time left counts down and reads -0:00 when unknown")
    func remaining() {
        #expect(MusicTimeFormat.remaining(current: 42, duration: 187) == "-2:25")
        #expect(MusicTimeFormat.remaining(current: 0, duration: 3725) == "-1:02:05")
        #expect(MusicTimeFormat.remaining(current: 10, duration: 0) == "-0:00")
        #expect(MusicTimeFormat.remaining(current: 200, duration: 187) == "-0:00")
        #expect(MusicTimeFormat.remaining(current: .nan, duration: 187) == "-0:00")
    }
}
