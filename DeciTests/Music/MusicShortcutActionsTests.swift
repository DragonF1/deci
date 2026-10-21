// DeciTests/Music/MusicShortcutActionsTests.swift
// The music side of the Save, Like and Dislike hotkeys: they act on the song playing now through the same calls the hover
// card's buttons make, Save then opens the Music popup, and with nothing playing, no sign-in or no player yet they say
// so and touch nothing.

import Foundation
import Testing
@testable import Deci

@MainActor
private struct ShortcutActionsHarness {
    let backend: FakeMusicBackend
    let engine = FakePlaybackEngine()
    let service: MusicService
    let host: MusicServiceHost
    let opener: FakePopupOpener
    let actions: MusicShortcutActions

    /// `loaded: false` is the app before the Music popup was ever opened: the host has no service yet.
    init(signedIn: Bool = true, loaded: Bool = true) {
        let backend = FakeMusicBackend(signedIn: signedIn)
        self.backend = backend
        let service = MusicService(
            backend: backend,
            player: MusicPlayer(engine: engine),
            presentSignIn: { _ in },
            presentChannelPicker: { _, _ in },
            closeSignInWindow: {},
            raiseSignInWindow: {},
            nowPlaying: NowPlayingController(surface: FakeNowPlayingSurface(), fetchArtwork: { _ in nil }),
            savePreferences: { _ in },
            shuffleSeed: 1,
            queueRetryDelay: .seconds(60),
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

    @Test("Dislike rates the playing song, skips it, and reports it")
    func dislikePlaying() async {
        let h = ShortcutActionsHarness()
        await h.service.refreshAuth()
        await h.startRadio(["a", "b", "c"])

        let outcome = await h.actions.dislike()
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
