// DeciTests/Music/MusicSearchNavigationRelatedTests.swift
// The Related panel as the right column's third panel: the player's button follows the playing song, a song, album,
// playlist, mix or artist menu pins a seed, the panel gives way to Lyrics and Up next and they to it, and Escape, a
// tab, a page, a new search and a session that ends close it like the others.

import Foundation
import Testing
@testable import Deci

@MainActor
private struct RelatedNavHarness {
    let backend = FakeMusicBackend(signedIn: true)
    let service: MusicService
    let nav: MusicSearchNavigation

    init() {
        service = MusicService(
            backend: backend,
            player: MusicPlayer(engine: FakePlaybackEngine()),
            presentSignIn: { _ in },
            presentChannelPicker: { _, _ in },
            closeSignInWindow: {},
            raiseSignInWindow: {},
            nowPlaying: NowPlayingController(surface: FakeNowPlayingSurface(), fetchArtwork: { _ in nil }),
            queueRetryDelay: .seconds(60),
            refreshOnCreate: false
        )
        nav = MusicSearchNavigation(service: service)
    }

    var related: MusicRelatedStore { service.related }

    func until(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<600 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }

    func settled() async {
        _ = await until { related.state != .loading }
    }

    func letLateWorkLand() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(40))
    }

    func script(_ seed: String, _ ids: String...) async {
        await backend.setRelated(videoId: seed, ids.map { MusicSamples.track($0, title: "Song \($0)") })
    }

    func relatedCalls() async -> [String] { await backend.relatedCalls }

    /// A song that plays, so the player has a now-playing song and the queue is not empty.
    func play(_ id: String) async {
        service.play(MusicSamples.track(id, title: "Song \(id)"))
        await service.playTask?.value
        await service.radioTask?.value
    }

    func loadLyricsTrack() {
        service.lyrics.trackChanged(MusicSamples.track("playing"), duration: 200)
    }
}

@MainActor
@Suite("MusicSearchNavigation related songs")
struct MusicSearchNavigationRelatedTests {
    private func song(_ id: String) -> MusicTrack { MusicSamples.track(id, title: "Song \(id)") }

    // MARK: - The player's button

    @Test("The button opens Related in the right column for the playing song, and the same button closes it")
    func toggleFollowsThePlayer() async {
        let h = RelatedNavHarness()
        await h.script("a", "r1")
        await h.play("a")
        #expect(h.nav.showsRelated == false)
        #expect(h.nav.rightColumn == .browse)

        h.nav.toggleRelated()
        #expect(h.nav.showsRelated)
        #expect(h.nav.rightColumn == .related)
        #expect(h.nav.isBrowsing == false)
        #expect(h.related.seed?.videoId == "a")
        await h.settled()
        #expect(await h.relatedCalls() == ["a"])

        h.nav.toggleRelated()
        #expect(h.nav.showsRelated == false)
        #expect(h.nav.rightColumn == .browse)
        #expect(h.nav.isBrowsing)
        #expect(h.related.state == .idle)
    }

    @Test("A panel opened by the button moves to the next song when the player does")
    func buttonFollows() async {
        let h = RelatedNavHarness()
        await h.script("a", "r1")
        await h.script("b", "r2")
        await h.play("a")
        h.nav.toggleRelated()
        await h.settled()

        await h.play("b")
        _ = await h.until { h.related.seed?.videoId == "b" && h.related.state != .loading }

        #expect(h.nav.rightColumn == .related)
        #expect(h.related.subline == "From Song b")
        #expect(await h.relatedCalls() == ["a", "b"])
    }

    @Test("With nothing playing the panel opens and says there is no song")
    func nothingPlaying() async {
        let h = RelatedNavHarness()
        h.nav.toggleRelated()
        #expect(h.nav.rightColumn == .related)
        #expect(h.related.state == .noSeed)
        #expect(await h.relatedCalls().isEmpty)
    }

    // MARK: - The menus

    @Test("A song's menu opens Related for that song, and the player's songs do not move it")
    func songMenuPins() async {
        let h = RelatedNavHarness()
        await h.script("x", "rx")
        await h.play("a")

        h.nav.perform(.related, for: song("x"), in: .none)
        #expect(h.nav.rightColumn == .related)
        #expect(h.related.seed?.videoId == "x")
        #expect(h.related.subline == "From Song x")
        await h.settled()

        await h.play("b")
        await h.letLateWorkLand()
        #expect(h.related.seed?.videoId == "x")
        #expect(await h.relatedCalls() == ["x"])
    }

    @Test("A menu on another song replaces the seed in the one panel")
    func menuReplaces() async {
        let h = RelatedNavHarness()
        await h.script("x", "rx")
        await h.script("y", "ry")
        h.nav.perform(.related, for: song("x"), in: .none)
        await h.settled()

        h.nav.perform(.related, for: song("y"), in: .none)
        await h.settled()

        #expect(h.nav.rightColumn == .related)
        #expect(h.related.seed?.videoId == "y")
        #expect(h.related.state == .loaded([song("ry")]))
    }

    @Test("An album, playlist, mix or artist menu opens Related for the first song of its page")
    func collectionMenuPins() async {
        for kind in [MusicCollection.Kind.album, .playlist, .artist] {
            let h = RelatedNavHarness()
            let collection = MusicSamples.collection("page-\(kind)", kind: kind, title: "The \(kind)")
            await h.backend.setPage(MusicSamples.page(collection.browseId, tracks: [song("t1"), song("t2")]))
            await h.script("t1", "r1")

            h.nav.perform(.related, for: collection, in: .none)
            #expect(h.nav.rightColumn == .related)
            #expect(h.related.subline == "From The \(kind)")
            await h.settled()

            #expect(h.related.seed?.videoId == "t1")
            #expect(h.related.state == .loaded([song("r1")]))
            // The page was read for its first song and was not opened.
            #expect(h.service.browse.path.isEmpty)
        }
    }

    @Test("A collection with no song to start from still opens the panel, and the panel says so")
    func collectionWithoutSong() async {
        let h = RelatedNavHarness()
        let collection = MusicSamples.collection("UC1", kind: .artist, title: "Quiet Artist")
        await h.backend.setPage(MusicSamples.page(collection.browseId))

        h.nav.perform(.related, for: collection, in: .none)
        await h.settled()

        #expect(h.nav.rightColumn == .related)
        #expect(h.related.state == .noSeed)
    }

    @Test("Song and collection menus offer Related songs, after Go to artist")
    func menusOfferIt() {
        let h = RelatedNavHarness()
        var credited = MusicSamples.track("v1")
        credited.albumBrowseId = "MPREb1"
        credited.artistLinks = [MusicArtistLink(name: "Band", browseId: "UC1")]
        #expect(h.nav.actions(for: credited, in: .none).suffix(2) == [.goToArtist, .related])

        let artist = MusicSamples.collection("UC1", kind: .artist, title: "Band")
        #expect(h.nav.actions(for: artist, in: .none).last == .related)
        let mix = MusicSamples.collection("VLRDx", kind: .playlist, title: "Mix")
        #expect(h.nav.actions(for: mix, in: .none).last == .related)
    }

    // MARK: - Giving way

    @Test("Related closes Lyrics and Up next, and each of them closes Related")
    func exclusive() async {
        let h = RelatedNavHarness()
        await h.script("a", "r1")
        await h.play("a")
        h.loadLyricsTrack()

        h.nav.toggleLyrics()
        #expect(h.nav.rightColumn == .lyrics)
        h.nav.toggleRelated()
        #expect(h.nav.rightColumn == .related)
        #expect(h.service.lyrics.isPanelOpen == false)

        h.nav.toggleQueue()
        #expect(h.nav.rightColumn == .queue)
        #expect(h.related.state == .idle)
        h.nav.toggleRelated()
        #expect(h.nav.rightColumn == .related)
        #expect(h.nav.queueForced == false)

        h.nav.toggleLyrics()
        #expect(h.nav.rightColumn == .lyrics)
        #expect(h.related.state == .idle)
        h.nav.toggleRelated()
        h.nav.openLyrics()
        #expect(h.nav.rightColumn == .lyrics)
        #expect(h.related.state == .idle)
    }

    @Test("Opening Related from Up next leaves its field closed and its words gone")
    func queueFieldCloses() async {
        let h = RelatedNavHarness()
        await h.play("a")
        h.nav.toggleQueue()
        h.nav.openField()
        #expect(h.nav.isQueueFieldOpen)

        h.nav.toggleRelated()

        #expect(h.nav.isQueueFieldOpen == false)
        #expect(h.nav.queueQuery.isEmpty)
    }

    @Test("Related has no field to open")
    func noField() async {
        let h = RelatedNavHarness()
        await h.play("a")
        h.nav.toggleRelated()
        #expect(h.nav.scope == .none)
        #expect(h.nav.scope.showsMagnifier == false)
        h.nav.openField()
        #expect(h.nav.isFieldOpen == false)
        #expect(h.nav.fieldQuery.isEmpty)
    }

    @Test("The save menu floats over Related, which stays open under it, and opening Related closes the menu")
    func pickerFloats() async {
        let h = RelatedNavHarness()
        await h.script("a", "r1")
        await h.play("a")
        h.nav.toggleRelated()

        h.nav.perform(.saveToPlaylist, for: song("picked"), in: .none)
        #expect(h.nav.showsPicker)
        #expect(h.nav.rightColumn == .related)
        h.nav.closePicker()
        #expect(h.nav.rightColumn == .related)

        h.nav.perform(.saveToPlaylist, for: song("picked"), in: .none)
        h.nav.perform(.related, for: song("x"), in: .none)
        #expect(h.nav.showsPicker == false)
    }

    // MARK: - Closing

    @Test("Closing the panel, a tab, a page, a new search and Escape each give the column back")
    func closers() async {
        let h = RelatedNavHarness()
        await h.play("a")

        h.nav.toggleRelated()
        h.nav.closePanel()
        #expect(h.nav.rightColumn == .browse)
        #expect(h.related.state == .idle)

        h.nav.toggleRelated()
        h.nav.select(.library)
        #expect(h.nav.rightColumn == .browse)
        #expect(h.related.state == .idle)

        h.nav.toggleRelated()
        h.nav.openArtist(MusicSamples.collection("UCa", kind: .artist, title: "Artist"))
        #expect(h.nav.rightColumn == .browse)
        #expect(h.related.state == .idle)
        #expect(h.service.browse.path.map(\.browseId) == ["UCa"])

        h.nav.toggleRelated()
        h.service.query = "q"
        h.nav.submit()
        #expect(h.nav.rightColumn != .related)
        #expect(h.related.state == .idle)
    }

    @Test("Escape closes Related and says so, then has nothing left to close")
    func escapeCloses() async {
        let h = RelatedNavHarness()
        await h.play("a")
        h.nav.toggleRelated()

        #expect(h.nav.escape())
        #expect(h.nav.rightColumn == .browse)
        #expect(h.related.state == .idle)
        #expect(h.nav.escape() == false)
    }

    @Test("Escape closes the save menu first and Related after it")
    func escapeOrder() async {
        let h = RelatedNavHarness()
        await h.play("a")
        h.nav.toggleRelated()
        h.nav.perform(.saveToPlaylist, for: song("picked"), in: .none)

        #expect(h.nav.escape())
        #expect(h.nav.showsPicker == false)
        #expect(h.nav.rightColumn == .related)
        #expect(h.nav.escape())
        #expect(h.nav.rightColumn == .browse)
    }

    @Test("Typing in a field leaves Related open")
    func typingKeepsIt() async {
        let h = RelatedNavHarness()
        await h.play("a")
        h.nav.toggleRelated()

        h.service.query = "qu"
        h.nav.queryChanged()

        #expect(h.nav.rightColumn == .related)
    }

    @Test("The panel goes with the session: signing out closes it, and the button opens it fresh after")
    func sessionEnds() async {
        let h = RelatedNavHarness()
        await h.script("a", "r1")
        await h.play("a")
        h.nav.toggleRelated()
        await h.settled()

        h.service.signOut()

        #expect(h.nav.showsRelated == false)
        #expect(h.nav.rightColumn == .browse)
        // Nothing of the old panel is left over: the button opens a fresh one.
        h.nav.toggleRelated()
        #expect(h.nav.rightColumn == .related)
        #expect(h.related.isFollowing)
    }

    @Test("Related is closed for good when the view that hosts it goes away")
    func closeRelatedOnDisappear() async {
        let h = RelatedNavHarness()
        await h.play("a")
        h.nav.toggleRelated()

        h.nav.closeRelated()

        #expect(h.nav.showsRelated == false)
        #expect(h.related.state == .idle)
        #expect(h.nav.rightColumn == .browse)
    }

    // MARK: - One source of truth

    @Test("Whether Related is open is the store's state alone: opened or closed through the store, the panel agrees")
    func storeIsTheOnlySourceOfTruth() async {
        let h = RelatedNavHarness()
        #expect(h.nav.showsRelated == false)

        h.related.show(song("x"))
        #expect(h.nav.showsRelated)
        #expect(h.nav.rightColumn == .related)

        h.related.close()
        #expect(h.nav.showsRelated == false)
        #expect(h.nav.rightColumn == .browse)

        h.related.follow(nil)
        #expect(h.nav.showsRelated)
        h.related.reset()
        #expect(h.nav.showsRelated == false)
    }

    // MARK: - The player stops

    @Test("The player stopping closes a Related panel that follows it")
    func stopClosesAFollowedPanel() async {
        let h = RelatedNavHarness()
        await h.script("a", "r1")
        await h.play("a")
        h.nav.toggleRelated()
        await h.settled()

        h.service.player.stop()
        h.nav.playerStopped()

        #expect(h.nav.showsRelated == false)
        #expect(h.related.state == .idle)
        #expect(h.related.isFollowing == false)
        #expect(h.nav.rightColumn == .browse)
    }

    @Test("The player stopping leaves a panel a song's menu pinned open, with its songs")
    func stopKeepsAPinnedSongPanel() async {
        let h = RelatedNavHarness()
        await h.script("x", "rx")
        await h.play("a")
        h.nav.perform(.related, for: song("x"), in: .none)
        await h.settled()

        h.service.player.stop()
        h.nav.playerStopped()

        #expect(h.nav.showsRelated)
        #expect(h.nav.rightColumn == .related)
        #expect(h.related.seed?.videoId == "x")
        #expect(h.related.state == .loaded([song("rx")]))
    }

    @Test("The player stopping leaves a panel a collection's menu pinned open, with its songs")
    func stopKeepsAPinnedCollectionPanel() async {
        let h = RelatedNavHarness()
        let collection = MusicSamples.collection("MPREb1", kind: .album, title: "Album")
        await h.backend.setPage(MusicSamples.page(collection.browseId, tracks: [song("t1")]))
        await h.script("t1", "r1")
        await h.play("a")
        h.nav.perform(.related, for: collection, in: .none)
        await h.settled()

        h.service.player.stop()
        h.nav.playerStopped()

        #expect(h.nav.showsRelated)
        #expect(h.related.state == .loaded([song("r1")]))
        #expect(h.related.subline == "From Album")
    }

    @Test("The player stopping still closes Up next and Lyrics")
    func stopClosesTheOtherPanels() async {
        let h = RelatedNavHarness()
        await h.play("a")
        h.nav.toggleQueue()
        h.nav.openField()
        h.service.player.stop()
        h.nav.playerStopped()
        #expect(h.nav.queueForced == false)
        #expect(h.nav.isQueueFieldOpen == false)
        #expect(h.nav.rightColumn == .browse)

        h.loadLyricsTrack()
        h.nav.toggleLyrics()
        #expect(h.service.lyrics.isPanelOpen)
        h.nav.playerStopped()
        #expect(h.service.lyrics.isPanelOpen == false)
    }

    @Test("The queue ending takes Up next off the column's request and leaves Related alone, followed or pinned")
    func queueEndedLeavesRelated() async {
        let h = RelatedNavHarness()
        await h.play("a")
        h.nav.toggleQueue()
        #expect(h.nav.queueForced)
        h.nav.queueEnded()
        #expect(h.nav.queueForced == false)

        h.nav.toggleRelated()
        h.nav.queueEnded()
        #expect(h.nav.showsRelated)
        #expect(h.related.isFollowing)

        h.nav.perform(.related, for: song("x"), in: .none)
        h.nav.queueEnded()
        #expect(h.nav.showsRelated)
        #expect(h.related.seed?.videoId == "x")
    }

    // MARK: - The button and a pinned panel

    /// What the code does today, pinned so a change to it is a decision: the player's Related button is a toggle on
    /// whatever panel is open. With a menu's panel open it closes that panel; it does not turn it into one that follows
    /// the player. A second press then opens the followed panel.
    @Test("The button closes a panel a menu pinned, and the next press opens the one that follows the player")
    func buttonClosesAPinnedPanel() async {
        let h = RelatedNavHarness()
        await h.script("x", "rx")
        await h.script("a", "ra")
        await h.play("a")
        h.nav.perform(.related, for: song("x"), in: .none)
        await h.settled()
        #expect(h.related.isFollowing == false)

        h.nav.toggleRelated()
        #expect(h.nav.showsRelated == false)
        #expect(h.related.state == .idle)
        #expect(h.nav.rightColumn == .browse)

        h.nav.toggleRelated()
        await h.settled()
        #expect(h.related.isFollowing)
        #expect(h.related.seed?.videoId == "a")
        #expect(h.related.state == .loaded([song("ra")]))
    }

    @Test("With nothing playing the button still closes a pinned panel, which is what its highlight promises")
    func buttonClosesAPinnedPanelWithNothingPlaying() async {
        let h = RelatedNavHarness()
        await h.script("x", "rx")
        h.nav.perform(.related, for: song("x"), in: .none)
        await h.settled()

        h.nav.toggleRelated()

        #expect(h.nav.showsRelated == false)
        #expect(h.related.state == .idle)
    }
}
