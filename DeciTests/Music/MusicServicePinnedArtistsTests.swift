// DeciTests/Music/MusicServicePinnedArtistsTests.swift
// Pinned artists wired into the Music tab: the service starts from the saved pins and saves changes, keeps them
// through sign-out and account switches (artists are public channels), and refreshes a pin when its page loads.

import Foundation
import Testing
@testable import Deci

@MainActor
private final class PinProbe {
    var saved: [[MusicPinnedArtist]] = []
    var savedPreferences: [MusicPlaybackPreferences] = []
    var presentCount = 0
    var signInCompletion: (@MainActor ([StoredCookie]?) -> Void)?
    var pickerCompletion: (@MainActor ([StoredCookie]?) -> Void)?
}

private let oldPhoto = "https://img.example.test/old.jpg"
private let newPhoto = "https://img.example.test/new.jpg"

@MainActor
private struct PinHarness {
    let backend: FakeMusicBackend
    let probe = PinProbe()
    let service: MusicService

    init(
        pins: [MusicPinnedArtist] = [],
        signedIn: Bool = true,
        preferences: MusicPlaybackPreferences = MusicPlaybackPreferences()
    ) {
        let backend = FakeMusicBackend(signedIn: signedIn)
        let probe = self.probe
        self.backend = backend
        self.service = MusicService(
            backend: backend,
            player: MusicPlayer(engine: FakePlaybackEngine()),
            presentSignIn: { completion in
                probe.presentCount += 1
                probe.signInCompletion = completion
            },
            presentChannelPicker: { _, completion in probe.pickerCompletion = completion },
            closeSignInWindow: {},
            raiseSignInWindow: {},
            nowPlaying: NowPlayingController(surface: FakeNowPlayingSurface(), fetchArtwork: { _ in nil }),
            preferences: preferences,
            savePreferences: { probe.savedPreferences.append($0) },
            pinnedArtists: pins,
            savePinnedArtists: { probe.saved.append($0) },
            refreshOnCreate: false
        )
    }

    /// Polls until `condition` holds, for at most two seconds.
    func until(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<400 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    /// Signed in with a session, as the account tests start.
    func signIn(cookies: [StoredCookie]) async {
        await backend.setSessionCookies(cookies)
        await backend.setChannelIdentity(false)
        await service.refreshAuth()
        await service.identityTask?.value
    }

    /// Opens an artist page and waits for it to load.
    func openArtist(_ opener: MusicCollection) async -> Bool {
        service.browse.open(opener)
        return await until { if case .loaded = service.browse.pageState(opener.browseId) { true } else { false } }
    }

    var pinnedIDs: [String] { service.pinnedArtists.artists.map(\.browseId) }
}

private func pin(_ id: String, title: String = "Name", photo: String? = oldPhoto) -> MusicPinnedArtist {
    MusicPinnedArtist(browseId: id, title: title, thumbnailURL: photo)
}

private func artistTile(_ id: String, title: String = "Tile name", photo: String? = nil) -> MusicCollection {
    MusicCollection(browseId: id, kind: .artist, title: title, subtitle: "Artist", thumbnailURL: photo.flatMap(URL.init(string:)))
}

private func artistPage(_ id: String, title: String, photo: String? = nil) -> MusicBrowsePage {
    MusicBrowsePage(
        browseId: id, title: title, subtitle: nil, thumbnailURL: photo.flatMap(URL.init(string:)),
        tracks: [], continuation: nil, shelves: []
    )
}

// MARK: - Service

@MainActor
@Suite("MusicService pinned artists")
struct MusicServicePinnedArtistsTests {
    private static let current = [StoredCookie(MusicSamples.cookie("SAPISID", domain: ".youtube.com"))]
    private static let other = [StoredCookie(MusicSamples.cookie("__Secure-3PAPISID", domain: ".youtube.com"))]

    @Test("a new service has no pins")
    func startsEmpty() {
        let h = PinHarness()
        #expect(h.service.pinnedArtists.artists.isEmpty)
        #expect(h.probe.saved.isEmpty)
    }

    @Test("the service starts with the pins it was given, in order, and does not save them again")
    func startsWithInjectedPins() {
        let h = PinHarness(pins: [pin("UCb"), pin("UCa")])
        #expect(h.pinnedIDs == ["UCb", "UCa"])
        #expect(h.probe.saved.isEmpty)
    }

    @Test("a pin and an unpin through the service reach the save closure; a repeat does not")
    func savesChanges() {
        let h = PinHarness()
        h.service.pinnedArtists.pin(pin("UCa"))
        h.service.pinnedArtists.pin(pin("UCa"))
        h.service.pinnedArtists.pin(pin("UCb"))
        h.service.pinnedArtists.unpin("UCa")
        h.service.pinnedArtists.unpin("UCa")
        #expect(h.probe.saved.map { $0.map(\.browseId) } == [["UCa"], ["UCa", "UCb"], ["UCb"]])
    }

    @Test("signing out keeps the pins and does not rewrite them")
    func survivesSignOut() async {
        let h = PinHarness(pins: [pin("UCa"), pin("UCb")])
        await h.service.refreshAuth()
        h.service.signOut()
        await h.service.signOutTask?.value

        #expect(h.service.authState == .signedOut)
        #expect(h.pinnedIDs == ["UCa", "UCb"])
        #expect(h.probe.saved.isEmpty)
    }

    @Test("a session that expires keeps the pins")
    func survivesExpiredSession() async {
        let h = PinHarness(pins: [pin("UCa")])
        await h.service.refreshAuth()
        await h.backend.setPageError("UCz", MusicError.signedOut)
        h.service.browse.open(artistTile("UCz"))
        let signedOut = await h.until { h.service.authState == .signedOut }
        await h.service.signOutTask?.value

        #expect(signedOut)
        #expect(h.pinnedIDs == ["UCa"])
    }

    @Test("using another account keeps the pins while Home and the pages are dropped")
    func survivesUseAnotherAccount() async {
        let h = PinHarness(pins: [pin("UCa")])
        await h.signIn(cookies: Self.current)
        await h.backend.setHome(shelves: [MusicSamples.shelf("Quick picks", "VLPL1")])
        h.service.browse.loadHomeIfNeeded()
        #expect(await h.until { h.service.browse.home != .loading })

        h.service.useAnotherAccount()
        h.probe.signInCompletion?(Self.other)
        await h.service.addAccountTask?.value

        #expect(h.service.browse.home == .idle)
        #expect(h.pinnedIDs == ["UCa"])
        #expect(h.probe.saved.isEmpty)
    }

    @Test("switching channel keeps the pins while Home is dropped")
    func survivesChannelSwitch() async {
        let h = PinHarness(pins: [pin("UCa")])
        await h.signIn(cookies: Self.current)
        await h.backend.setHome(shelves: [MusicSamples.shelf("Quick picks", "VLPL1")])
        h.service.browse.loadHomeIfNeeded()
        #expect(await h.until { h.service.browse.home != .loading })

        h.service.switchChannel()
        await h.service.channelSwitchTask?.value
        h.probe.pickerCompletion?(Self.other)
        await h.service.channelSwitchTask?.value

        #expect(h.service.browse.home == .idle)
        #expect(h.pinnedIDs == ["UCa"])
    }

    // MARK: Refreshing

    @Test("loading a pinned artist's page refreshes the stored title and keeps the photo it was pinned with")
    func pageLoadRefreshes() async {
        let h = PinHarness(pins: [pin("UCa", title: "Old name"), pin("UCb")])
        await h.backend.setPage(artistPage("UCa", title: "New name", photo: "https://img.example.test/banner.jpg"))

        // Opened from a Library row, whose small photo is not the avatar the pin was made with.
        #expect(await h.openArtist(artistTile("UCa", photo: newPhoto)))

        #expect(h.pinnedIDs == ["UCa", "UCb"])
        #expect(h.service.pinnedArtists.artists[0] == pin("UCa", title: "New name", photo: oldPhoto))
        #expect(h.service.pinnedArtists.artists[1] == pin("UCb"))
        #expect(h.probe.saved.count == 1)
    }

    @Test("a page banner never replaces the stored avatar when the opener has no photo")
    func pageLoadKeepsAvatarOverBanner() async {
        let h = PinHarness(pins: [pin("UCa", title: "Name", photo: oldPhoto)])
        await h.backend.setPage(artistPage("UCa", title: "Name", photo: "https://img.example.test/banner.jpg"))

        #expect(await h.openArtist(artistTile("UCa")))

        #expect(h.service.pinnedArtists.artists == [pin("UCa", title: "Name", photo: oldPhoto)])
        #expect(h.probe.saved.isEmpty)
    }

    @Test("a page with no photo and a tile with none never wipes the stored photo")
    func pageLoadKeepsPhoto() async {
        let h = PinHarness(pins: [pin("UCa", title: "Old name", photo: oldPhoto)])
        await h.backend.setPage(artistPage("UCa", title: "New name"))

        #expect(await h.openArtist(artistTile("UCa")))

        #expect(h.service.pinnedArtists.artists == [pin("UCa", title: "New name", photo: oldPhoto)])
    }

    @Test("a page photo fills in for a pin that had none, when the tile has none either")
    func pageLoadFillsPhoto() async {
        let h = PinHarness(pins: [pin("UCa", photo: nil)])
        await h.backend.setPage(artistPage("UCa", title: "Name", photo: newPhoto))

        #expect(await h.openArtist(artistTile("UCa")))

        #expect(h.service.pinnedArtists.artists == [pin("UCa", title: "Name", photo: newPhoto)])
    }

    @Test("opening a pinned artist from its own tile with nothing new changes and saves nothing")
    func pageLoadUnchanged() async {
        let h = PinHarness(pins: [pin("UCa", title: "Name", photo: oldPhoto)])
        await h.backend.setPage(artistPage("UCa", title: "Name"))

        #expect(await h.openArtist(artistTile("UCa", title: "Name", photo: oldPhoto)))

        #expect(h.probe.saved.isEmpty)
    }

    @Test("loading the page of an artist that is not pinned pins nothing")
    func pageLoadOfUnpinnedArtist() async {
        let h = PinHarness(pins: [pin("UCa")])
        await h.backend.setPage(artistPage("UCz", title: "Stranger", photo: newPhoto))

        #expect(await h.openArtist(artistTile("UCz", photo: newPhoto)))

        #expect(h.pinnedIDs == ["UCa"])
        #expect(h.probe.saved.isEmpty)
    }

    @Test("a page that fails to load leaves the pin as it was")
    func failedPageLoad() async {
        let h = PinHarness(pins: [pin("UCa", title: "Name")])
        await h.backend.setPageError("UCa", MusicError.http(500))
        h.service.browse.open(artistTile("UCa", title: "Other", photo: newPhoto))
        let failed = await h.until { if case .failed = h.service.browse.pageState("UCa") { true } else { false } }

        #expect(failed)
        #expect(h.service.pinnedArtists.artists == [pin("UCa", title: "Name")])
        #expect(h.probe.saved.isEmpty)
    }

    @Test("a pinned id opened as something other than an artist is not refreshed")
    func nonArtistPageLoad() async {
        let h = PinHarness(pins: [pin("UCa", title: "Name")])
        await h.backend.setPage(artistPage("UCa", title: "Renamed"))
        let playlistTile = MusicCollection(browseId: "UCa", kind: .playlist, title: "T", subtitle: "", thumbnailURL: nil)

        #expect(await h.openArtist(playlistTile))

        #expect(h.service.pinnedArtists.artists == [pin("UCa", title: "Name")])
    }

    // MARK: Settings reset

    @Test("a settings reset drops the pins and the playback options in memory without writing anything")
    func settingsReset() {
        let h = PinHarness(
            pins: [pin("UCa"), pin("UCb")],
            preferences: MusicPlaybackPreferences(shuffle: true, loop: .song, autoplay: false)
        )

        h.service.settingsDidReset()

        #expect(h.service.pinnedArtists.artists.isEmpty)
        #expect(!h.service.isShuffleOn)
        #expect(h.service.loopMode == .off)
        #expect(h.service.isAutoplayOn)
        #expect(h.probe.saved.isEmpty)
        #expect(h.probe.savedPreferences.isEmpty)
    }

    @Test("after a settings reset the next change writes only what was changed since, never the old pins or options")
    func changeAfterSettingsReset() {
        let h = PinHarness(
            pins: [pin("UCa"), pin("UCb")],
            preferences: MusicPlaybackPreferences(shuffle: true, loop: .song, autoplay: false)
        )
        h.service.settingsDidReset()

        h.service.pinnedArtists.pin(pin("UCc"))
        h.service.cycleLoopMode()

        #expect(h.probe.saved.map { $0.map(\.browseId) } == [["UCc"]])
        #expect(h.probe.savedPreferences == [MusicPlaybackPreferences(shuffle: false, loop: .playlist, autoplay: true)])
    }

    @Test("a pin made from the page just opened carries the page's title and the opener's photo")
    func pinFromOpenedPage() async {
        let h = PinHarness()
        await h.backend.setPage(artistPage("UCa", title: "Full name", photo: "https://img.example.test/banner.jpg"))
        let opener = artistTile("UCa", title: "Short", photo: newPhoto)
        #expect(await h.openArtist(opener))
        guard case .loaded(let page) = h.service.browse.pageState("UCa") else {
            Issue.record("the page did not load")
            return
        }

        h.service.pinnedArtists.toggle(MusicPinnedArtist(page: page, opener: opener))

        #expect(h.service.pinnedArtists.artists == [pin("UCa", title: "Full name", photo: newPhoto)])
        #expect(h.service.pinnedArtists.shelf?.items.count == 1)
    }
}

// MARK: - Browse store hook

@MainActor
private final class LandingProbe {
    var landings: [(page: MusicBrowsePage, opener: MusicCollection?)] = []
}

@MainActor
@Suite("MusicBrowseStore page landings")
struct MusicBrowseStorePageLandingTests {
    private func until(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<400 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    @Test("a page that lands is reported with the collection that opened it")
    func reportsLanding() async {
        let backend = FakeMusicBackend()
        let store = MusicBrowseStore(backend: backend)
        let probe = LandingProbe()
        store.onPageLoaded = { page, opener in probe.landings.append((page, opener)) }
        let page = artistPage("UCa", title: "Name", photo: newPhoto)
        await backend.setPage(page)
        let tile = artistTile("UCa", photo: oldPhoto)

        store.open(tile)
        #expect(await until { probe.landings.count == 1 })

        #expect(probe.landings.first?.page == page)
        #expect(probe.landings.first?.opener == tile)
    }

    @Test("a page closed before it lands is not reported")
    func staleLandingIsSilent() async {
        let backend = FakeMusicBackend()
        let store = MusicBrowseStore(backend: backend)
        let probe = LandingProbe()
        store.onPageLoaded = { page, opener in probe.landings.append((page, opener)) }
        let gate = MusicTestGate()
        await backend.setPage(artistPage("UCa", title: "Name"))
        await backend.setPageGate("UCa", gate)

        store.open(artistTile("UCa"))
        store.back()
        await gate.open()
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(40))

        #expect(probe.landings.isEmpty)
    }

    @Test("a page that fails is not reported")
    func failureIsSilent() async {
        let backend = FakeMusicBackend()
        let store = MusicBrowseStore(backend: backend)
        let probe = LandingProbe()
        store.onPageLoaded = { page, opener in probe.landings.append((page, opener)) }
        await backend.setPageError("UCa", MusicError.http(500))

        store.open(artistTile("UCa"))
        #expect(await until { if case .failed = store.pageState("UCa") { true } else { false } })

        #expect(probe.landings.isEmpty)
    }
}
