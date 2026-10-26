// DeciTests/Music/MusicShortcutActionsTests.swift
// The music side of the Save, Like and Dislike hotkeys: they act on the song playing now through the same calls the hover
// card's buttons make, Save then opens the Music popup, and with nothing playing, no sign-in or no player yet they say
// so and touch nothing.

import Foundation
import Testing
@testable import Deci

/// The sign-in window and the channel picker the service opened, held open so a test can finish them.
@MainActor
private final class AccountWindows {
    var signIn: (@MainActor ([StoredCookie]?) -> Void)?
    var channelPicker: (@MainActor ([StoredCookie]?) -> Void)?
}

@MainActor
private struct ShortcutActionsHarness {
    let backend: FakeMusicBackend
    let engine = FakePlaybackEngine()
    let service: MusicService
    let host: MusicServiceHost
    let opener: FakePopupOpener
    let actions: MusicShortcutActions
    let windows = AccountWindows()
    /// The wait before a disliked song is skipped: instant, so the skip runs as soon as it is scheduled.
    let skipSleep = DislikeSkipSleep()

    /// `loaded: false` is the app before the Music popup was ever opened: the host has no service yet.
    init(signedIn: Bool = true, loaded: Bool = true) {
        let backend = FakeMusicBackend(signedIn: signedIn)
        self.backend = backend
        let skipSleep = self.skipSleep
        let windows = self.windows
        let service = MusicService(
            backend: backend,
            player: MusicPlayer(engine: engine),
            presentSignIn: { windows.signIn = $0 },
            presentChannelPicker: { _, completion in windows.channelPicker = completion },
            closeSignInWindow: {},
            raiseSignInWindow: {},
            nowPlaying: NowPlayingController(surface: FakeNowPlayingSurface(), fetchArtwork: { _ in nil }),
            savePreferences: { _ in },
            shuffleSeed: 1,
            queueRetryDelay: .seconds(60),
            sleep: { seconds in await skipSleep.sleep(seconds) },
            refreshOnCreate: false
        )
        self.service = service
        let host = MusicServiceHost(makeService: { service })
        self.host = host
        let opener = FakePopupOpener()
        self.opener = opener
        actions = MusicShortcutActions(musicHost: host, popupOpener: opener)
        if loaded { host.loadIfNeeded() }
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

    func song(_ id: String) -> Deci.MusicTrack { MusicSamples.track(id, title: "Song \(id)") }

    /// Plays the first of `ids` with a radio of the rest behind it, and waits for the radio.
    func startRadio(_ ids: [String]) async {
        await backend.setRadio(seed: ids[0], tracks: ids.map { song($0) })
        service.play(song(ids[0]))
        await settle()
        engine.emit(.playingChanged(true))
    }

    func rateCalls() async -> [FakeMusicBackend.RateCall] { await backend.rateCalls }
}

@MainActor
final class FakePopupOpener: MusicPopupOpening {
    var isOnScreen = false
    var isOpen = false
    var canOpen = true
    private(set) var openCount = 0
    func open() { openCount += 1 }
}

@MainActor
@Suite("Music shortcut actions")
struct MusicShortcutActionsTests {

    // MARK: - Save to playlist

    @Test("Save opens the save menu for the playing song, as the card's button does, then the Music popup")
    func saveOpensTheMenuAndThePopup() async {
        let h = ShortcutActionsHarness()
        await h.service.refreshAuth()
        await h.startRadio(["a", "b"])

        let outcome = h.actions.saveToPlaylist()

        #expect(outcome == .quiet)
        #expect(h.service.trackActions.picker?.target == .track(h.song("a")))
        #expect(h.opener.openCount == 1)
    }

    @Test("Save follows the song that plays now")
    func saveFollowsTheSong() async {
        let h = ShortcutActionsHarness()
        await h.service.refreshAuth()
        await h.startRadio(["a", "b"])
        h.service.next()
        await h.settle()
        h.engine.emit(.playingChanged(true))

        _ = h.actions.saveToPlaylist()

        #expect(h.service.trackActions.picker?.target == .track(h.song("b")))
    }

    @Test("Save with nothing playing says so and opens neither the menu nor the popup")
    func saveNothingPlaying() {
        let h = ShortcutActionsHarness()

        #expect(h.actions.saveToPlaylist() == .nothingPlaying)
        #expect(h.service.trackActions.picker == nil)
        #expect(h.opener.openCount == 0)
    }

    @Test("Save while signed out asks to sign in and opens neither the menu nor the popup")
    func saveSignedOut() async {
        let h = ShortcutActionsHarness(signedIn: false)
        await h.service.refreshAuth()
        await h.startRadio(["a"])

        #expect(h.actions.saveToPlaylist() == .signedOut)
        #expect(h.service.trackActions.picker == nil)
        #expect(h.opener.openCount == 0)
    }

    @Test("Save before the Music popup was ever opened says nothing is playing and builds no player")
    func saveBeforeThePlayerExists() {
        let h = ShortcutActionsHarness(loaded: false)

        #expect(h.actions.saveToPlaylist() == .nothingPlaying)
        #expect(h.host.service == nil)
        #expect(h.opener.openCount == 0)
    }

    @Test("Save with the Music item hidden from the menu bar says so, and opens neither the menu nor the popup")
    func saveMusicItemHidden() async {
        let h = ShortcutActionsHarness()
        await h.service.refreshAuth()
        await h.startRadio(["a", "b"])
        h.opener.canOpen = false

        #expect(h.actions.saveToPlaylist() == .musicHidden)
        #expect(h.service.trackActions.picker == nil)
        #expect(h.opener.openCount == 0)
    }

    @Test("Nothing playing and a signed-out account are told first, even with the item hidden")
    func saveHiddenComesLast() async {
        let h = ShortcutActionsHarness(signedIn: false)
        h.opener.canOpen = false
        #expect(h.actions.saveToPlaylist() == .nothingPlaying)

        await h.service.refreshAuth()
        await h.startRadio(["a"])
        #expect(h.actions.saveToPlaylist() == .signedOut)
    }

    // MARK: - Like and Dislike

    @Test("Like rates the playing song and reports it")
    func likePlaying() async {
        let h = ShortcutActionsHarness()
        await h.service.refreshAuth()
        await h.startRadio(["a", "b"])

        let outcome = await h.actions.toggleLike()

        #expect(outcome == .liked)
        #expect(await h.rateCalls() == [.init(videoId: "a", status: .like)])
        #expect(h.opener.openCount == 0)
    }

    @Test("Like twice takes the like back")
    func likeTwice() async {
        let h = ShortcutActionsHarness()
        await h.service.refreshAuth()
        await h.startRadio(["a", "b"])

        #expect(await h.actions.toggleLike() == .liked)
        #expect(await h.actions.toggleLike() == .likeRemoved)
        #expect(await h.rateCalls() == [.init(videoId: "a", status: .like), .init(videoId: "a", status: .indifferent)])
    }

    @Test("Dislike rates the playing song, skips it once the dislike animation has played, and reports it")
    func dislikePlaying() async {
        let h = ShortcutActionsHarness()
        await h.service.refreshAuth()
        await h.startRadio(["a", "b", "c"])

        let outcome = await h.actions.dislike()
        await h.service.dislikeSkip?.value
        await h.settle()

        #expect(outcome == .disliked)
        #expect(await h.rateCalls() == [.init(videoId: "a", status: .dislike)])
        #expect(h.service.player.nowPlaying?.videoId == "b")
        #expect(h.opener.openCount == 0)
    }

    @Test("Like and Dislike with nothing playing say so and send nothing")
    func rateNothingPlaying() async {
        let h = ShortcutActionsHarness()
        await h.service.refreshAuth()

        #expect(await h.actions.toggleLike() == .nothingPlaying)
        #expect(await h.actions.dislike() == .nothingPlaying)
        #expect(await h.rateCalls().isEmpty)
    }

    @Test("Like and Dislike while signed out ask to sign in and send nothing")
    func rateSignedOut() async {
        let h = ShortcutActionsHarness(signedIn: false)
        await h.service.refreshAuth()
        await h.startRadio(["a"])

        #expect(await h.actions.toggleLike() == .signedOut)
        #expect(await h.actions.dislike() == .signedOut)
        #expect(await h.rateCalls().isEmpty)
    }

    @Test("Like and Dislike before the Music popup was ever opened say nothing is playing and build no player")
    func rateBeforeThePlayerExists() async {
        let h = ShortcutActionsHarness(loaded: false)

        #expect(await h.actions.toggleLike() == .nothingPlaying)
        #expect(await h.actions.dislike() == .nothingPlaying)
        #expect(h.host.service == nil)
        #expect(await h.rateCalls().isEmpty)
    }

    @Test("A like YouTube Music does not take reports that it failed")
    func likeFails() async {
        let h = ShortcutActionsHarness()
        await h.service.refreshAuth()
        await h.startRadio(["a", "b"])
        await h.backend.setRateError(videoId: "a", URLError(.notConnectedToInternet))

        #expect(await h.actions.toggleLike() == .failed)
    }

    @Test("Like and Dislike do not need the Music item in the menu bar")
    func rateWithItemHidden() async {
        let h = ShortcutActionsHarness()
        await h.service.refreshAuth()
        await h.startRadio(["a", "b"])
        h.opener.canOpen = false

        #expect(await h.actions.toggleLike() == .liked)
    }
}

// MARK: - Where an outcome is shown

@MainActor
@Suite("Music outcome reporter")
struct MusicOutcomeReporterTests {
    private struct Setup {
        let h: ShortcutActionsHarness
        let hud = RecordingMessageHUD()
        let reporter: MusicOutcomeReporter

        init(signedIn: Bool = true, loaded: Bool = true, popupOpen: Bool) async {
            h = ShortcutActionsHarness(signedIn: signedIn, loaded: loaded)
            await h.service.refreshAuth()
            h.opener.isOpen = popupOpen
            h.opener.isOnScreen = popupOpen
            reporter = MusicOutcomeReporter(musicHost: h.host, popupOpener: h.opener, hud: hud)
            // The app's wiring (DeciApp): the host hands the service's account failures to the reporter.
            h.host.outcomes = reporter
        }

        var notice: MusicTrackActionsStore.Notice? { h.service.trackActions.notice }
    }

    /// What fails or cannot be done: the outcomes that still show. A rating that went through is told by the animation.
    nonisolated private static let reported = MusicActionOutcome.allCases.filter { $0.hudMessage != nil }

    @Test("With the Music popup open the outcome shows in its notice line and not on the HUD", arguments: MusicOutcomeReporterTests.reported)
    func popupOpenUsesTheNoticeLine(outcome: MusicActionOutcome) async {
        let s = await Setup(popupOpen: true)

        s.reporter.report(outcome)

        #expect(s.notice?.text == outcome.noticeText)
        #expect(s.notice?.isError == outcome.isFailure)
        #expect(s.hud.messages.isEmpty)
    }

    @Test("With the Music popup closed the outcome shows on the HUD and not in the notice line", arguments: MusicOutcomeReporterTests.reported)
    func popupClosedUsesTheHud(outcome: MusicActionOutcome) async {
        let s = await Setup(popupOpen: false)

        s.reporter.report(outcome)

        #expect(s.hud.messages == [outcome.hudMessage].compactMap { $0 })
        #expect(s.notice == nil)
    }

    @Test("The reported outcomes are the refusals and the failures, and the table is not empty")
    func reportedAreTheFailures() {
        #expect(Self.reported == [.nothingPlaying, .signedOut, .failed, .musicHidden])
    }

    @Test("A rating that went through shows nowhere, popup open or not: the animation is its answer", arguments: [
        MusicActionOutcome.liked, .likeRemoved, .disliked, .dislikeRemoved,
    ], [true, false])
    func successfulRatingsShowNowhere(outcome: MusicActionOutcome, popupOpen: Bool) async {
        let s = await Setup(popupOpen: popupOpen)

        s.reporter.report(outcome)

        #expect(s.hud.messages.isEmpty)
        #expect(s.notice == nil)
    }

    @Test("A Music popup that is fading out is not open: the outcome goes to the HUD")
    func closingPopupUsesTheHud() async {
        let s = await Setup(popupOpen: false)
        s.h.opener.isOnScreen = true

        s.reporter.report(.failed)

        #expect(s.hud.messages == [MusicActionOutcome.failed.hudMessage].compactMap { $0 })
        #expect(s.notice == nil)
    }

    @Test("Another Deci popup open does not matter: with the Music popup closed the HUD shows")
    func otherPopupOpen() async {
        let s = await Setup(popupOpen: false)
        let popups = PopupVisibilityService()
        popups.setOpen(.mixer, true)

        s.reporter.report(.failed)

        #expect(popups.isVisible)
        #expect(s.hud.messages == [MusicActionOutcome.failed.hudMessage].compactMap { $0 })
    }

    @Test("A signed-out popup draws no notice line, so the outcome goes to the HUD")
    func signedOutPopupUsesTheHud() async {
        let s = await Setup(signedIn: false, popupOpen: true)

        s.reporter.report(.signedOut)

        #expect(s.hud.messages == [MusicActionOutcome.signedOut.hudMessage].compactMap { $0 })
        #expect(s.notice == nil)
    }

    @Test("With no player built yet there is no notice line, so the outcome goes to the HUD")
    func noPlayerUsesTheHud() async {
        let s = await Setup(loaded: false, popupOpen: true)

        s.reporter.report(.nothingPlaying)

        #expect(s.hud.messages == [MusicActionOutcome.nothingPlaying.hudMessage].compactMap { $0 })
        #expect(s.h.host.service == nil)
    }

    @Test("A quiet outcome shows nowhere, popup open or not", arguments: [true, false])
    func quietShowsNowhere(popupOpen: Bool) async {
        let s = await Setup(popupOpen: popupOpen)

        s.reporter.report(.quiet)

        #expect(s.hud.messages.isEmpty)
        #expect(s.notice == nil)
    }

    @Test("Several outcomes in a row each show, the newest line replacing the older")
    func severalOutcomes() async {
        let s = await Setup(popupOpen: true)

        s.reporter.report(.failed)
        s.reporter.report(.nothingPlaying)

        #expect(s.notice?.text == "Nothing is playing")
        #expect(s.hud.messages.isEmpty)
    }

    @Test("A success after a failure leaves the failure's line as it was, and adds nothing")
    func successLeavesTheFailureLine() async {
        let s = await Setup(popupOpen: true)

        s.reporter.report(.failed)
        s.reporter.report(.liked)

        #expect(s.notice?.text == "Couldn't reach YouTube Music")
        #expect(s.notice?.isError == true)
        #expect(s.hud.messages.isEmpty)
    }

    // MARK: Failures with their own words

    /// What a failed Add account and a failed Switch channel say. Longer than the outcomes' lines, so the HUD wraps them.
    nonisolated private static let accountFailures = [
        "Couldn't add the account. Still signed in as before.",
        "Couldn't switch the channel. Still playing as before.",
    ]

    @Test("A failure with its own words shows in the open popup's notice line, as an error, and not on the HUD", arguments: MusicOutcomeReporterTests.accountFailures)
    func failureTextUsesTheNoticeLine(text: String) async {
        let s = await Setup(popupOpen: true)

        s.reporter.reportFailure(text)

        #expect(s.notice?.text == text)
        #expect(s.notice?.isError == true)
        #expect(s.hud.messages.isEmpty)
        #expect(!text.contains("\u{2014}"))
    }

    @Test("With the popup closed a failure with its own words shows on the HUD and not in the notice line", arguments: MusicOutcomeReporterTests.accountFailures)
    func failureTextUsesTheHud(text: String) async {
        let s = await Setup(popupOpen: false)

        s.reporter.reportFailure(text)

        #expect(s.hud.messages == [HUDMessage(symbol: "exclamationmark.triangle", text: text)])
        #expect(s.notice == nil)
    }

    @Test("A signed-out popup draws no notice line, so a failure with its own words goes to the HUD")
    func failureTextSignedOutUsesTheHud() async {
        let s = await Setup(signedIn: false, popupOpen: true)

        s.reporter.reportFailure(Self.accountFailures[0])

        #expect(s.hud.messages == [HUDMessage(symbol: "exclamationmark.triangle", text: Self.accountFailures[0])])
        #expect(s.notice == nil)
    }

    @Test("A channel switch that failed shows in the open popup's notice line and leaves lastError alone")
    func failedSwitchShowsInTheNoticeLine() async {
        let s = await Setup(popupOpen: true)
        await s.h.backend.setSessionCookies([StoredCookie(MusicSamples.cookie("SAPISID", domain: ".youtube.com"))])
        await s.h.backend.setSignInError(MusicError.signedOut)

        s.h.service.switchChannel()
        await s.h.service.channelSwitchTask?.value
        s.h.windows.channelPicker?([StoredCookie(MusicSamples.cookie("__Secure-3PAPISID", domain: ".youtube.com"))])
        await s.h.service.channelSwitchTask?.value

        #expect(s.notice?.text == "Couldn't switch the channel. Still playing as before.")
        #expect(s.notice?.isError == true)
        #expect(s.hud.messages.isEmpty)
        #expect(s.h.service.lastError == nil)
        #expect(s.h.service.authState == .signedIn)
    }

    @Test("An account that could not be added shows on the HUD when the popup is closed by then, and leaves lastError alone")
    func failedAddShowsOnTheHud() async {
        let s = await Setup(popupOpen: false)
        await s.h.backend.setSignInError(MusicError.signedOut)

        s.h.service.useAnotherAccount()
        s.h.windows.signIn?([StoredCookie(MusicSamples.cookie("__Secure-3PAPISID", domain: ".youtube.com"))])
        await s.h.service.addAccountTask?.value

        #expect(s.hud.messages == [HUDMessage(symbol: "exclamationmark.triangle", text: Self.accountFailures[0])])
        #expect(s.notice == nil)
        #expect(s.h.service.lastError == nil)
        #expect(s.h.service.authState == .signedIn)
        // The line wraps on the tile, so it stays up longer than the short ones.
        #expect(s.hud.messages.first?.hideDelay(base: .milliseconds(1100)) == .milliseconds(2500))
    }
}

// MARK: - The popup opener

@MainActor
@Suite("Music popup opener")
struct MusicPopupOpenerTests {
    private final class Probe {
        var state = MusicPopupOpener.State.closed
        var itemShown = true
        var toggles = 0
    }

    private func makeOpener(_ probe: Probe) -> MusicPopupOpener {
        MusicPopupOpener(
            state: { probe.state },
            isItemShown: { probe.itemShown },
            toggle: { probe.toggles += 1 },
            closeWait: .milliseconds(150),
            pollInterval: .milliseconds(5)
        )
    }

    private func until(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<400 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    private func letLateWorkLand() async {
        try? await Task.sleep(for: .milliseconds(250))
    }

    @Test("It opens the popup like a click on the item when it is closed")
    func opensWhenClosed() {
        let probe = Probe()
        makeOpener(probe).open()
        #expect(probe.toggles == 1)
    }

    @Test("It does nothing when the popup is open, since the toggle would close it")
    func leavesAnOpenPopupAlone() async {
        let probe = Probe()
        probe.state = .open
        makeOpener(probe).open()
        await letLateWorkLand()
        #expect(probe.toggles == 0)
    }

    @Test("It reports whether the popup is on screen, open or fading out")
    func reportsVisibility() {
        let probe = Probe()
        let opener = makeOpener(probe)
        #expect(!opener.isOnScreen)
        probe.state = .open
        #expect(opener.isOnScreen)
        probe.state = .closing
        #expect(opener.isOnScreen)
    }

    @Test("It reports whether the popup is open: key and on screen, which a popup fading out is not")
    func reportsOpen() {
        let probe = Probe()
        let opener = makeOpener(probe)
        #expect(!opener.isOpen)
        probe.state = .open
        #expect(opener.isOpen)
        probe.state = .closing
        #expect(!opener.isOpen)
    }

    @Test("It reports whether the Music item is in the menu bar, the only place the popup opens from")
    func reportsTheItem() {
        let probe = Probe()
        let opener = makeOpener(probe)
        #expect(opener.canOpen)
        probe.itemShown = false
        #expect(!opener.canOpen)
    }

    @Test("A popup fading out is opened again once it has closed, not toggled shut mid-fade")
    func reopensAfterTheFade() async {
        let probe = Probe()
        probe.state = .closing
        let opener = makeOpener(probe)

        opener.open()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(probe.toggles == 0)

        probe.state = .closed
        let opened = await until { probe.toggles == 1 }

        #expect(opened)
    }

    @Test("Two opens during one fade toggle once")
    func opensOncePerFade() async {
        let probe = Probe()
        probe.state = .closing
        let opener = makeOpener(probe)

        opener.open()
        opener.open()
        probe.state = .closed
        _ = await until { probe.toggles >= 1 }
        await letLateWorkLand()

        #expect(probe.toggles == 1)
    }

    @Test("A popup that someone opened again during the fade is left alone")
    func leavesAPopupOpenedMeanwhile() async {
        let probe = Probe()
        probe.state = .closing
        let opener = makeOpener(probe)

        opener.open()
        probe.state = .open
        await letLateWorkLand()

        #expect(probe.toggles == 0)
    }

    @Test("A popup that never finishes closing is not toggled")
    func givesUpWhenItNeverCloses() async {
        let probe = Probe()
        probe.state = .closing
        let opener = makeOpener(probe)

        opener.open()
        await letLateWorkLand()

        #expect(probe.toggles == 0)
    }
}
