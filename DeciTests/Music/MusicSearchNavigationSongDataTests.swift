// DeciTests/Music/MusicSearchNavigationSongDataTests.swift
// The Song data panel as the right column's fourth panel: a song's menu opens it, it gives way to Lyrics, Up next and
// Related and they to it, and Escape, a tab, a page, a new search and a session that ends close it like the others.

import Foundation
import Testing
@testable import Deci

@MainActor
private struct SongDataNavHarness {
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

    var data: MusicSongDataStore { service.songData }

    func until(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<600 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }

    func settled() async {
        _ = await until { data.stream != .loading }
    }

    func play(_ id: String) async {
        service.play(MusicSamples.track(id, title: "Song \(id)"))
        await service.playTask?.value
        await service.radioTask?.value
    }
}

@MainActor
@Suite("MusicSearchNavigation song data")
struct MusicSearchNavigationSongDataTests {
    private func song(_ id: String) -> MusicTrack { MusicSamples.track(id, title: "Song \(id)") }

    // MARK: - The menu

    @Test("A song's menu opens Song data in the right column for that song")
    func menuOpens() async {
        let h = SongDataNavHarness()
        #expect(h.nav.showsSongData == false)
        #expect(h.nav.rightColumn == .browse)

        h.nav.perform(.songData, for: song("x"), in: .none)

        #expect(h.nav.showsSongData)
        #expect(h.nav.rightColumn == .songData)
        #expect(h.nav.isBrowsing == false)
        #expect(h.data.track?.videoId == "x")
        await h.settled()
        #expect(await h.backend.resolvedIDs == ["x"])
    }

    @Test("A menu on another song swaps the content of the one panel")
    func menuSwaps() async {
        let h = SongDataNavHarness()
        h.nav.perform(.songData, for: song("x"), in: .none)
        h.nav.perform(.songData, for: song("y"), in: .none)
        await h.settled()
        #expect(h.nav.rightColumn == .songData)
        #expect(h.data.track?.videoId == "y")
    }

    @Test("The song that plays is held, so its panel asks the backend for nothing")
    func playingSongIsHeld() async {
        let h = SongDataNavHarness()
        await h.play("a")
        let before = await h.backend.resolvedIDs.count
        h.nav.perform(.songData, for: song("a"), in: .none)
        if case .loaded(let stream) = h.data.stream {
            #expect(stream.videoId == "a")
        } else {
            Issue.record("expected the held stream, got \(h.data.stream)")
        }
        #expect(await h.backend.resolvedIDs.count == before)
    }

    @Test("Every single-song menu offers Song data, last")
    func menusOfferIt() {
        let h = SongDataNavHarness()
        #expect(h.nav.actions(for: MusicSamples.track("v1"), in: .none).last == .songData)
        #expect(h.nav.actions(for: MusicSamples.track("v1"), in: .upNext).last == .songData)
    }

    // MARK: - Giving way

    @Test("Song data closes Lyrics, Up next and Related, and each of them closes Song data")
    func exclusive() async {
        let h = SongDataNavHarness()
        await h.play("a")
        h.service.lyrics.trackChanged(MusicSamples.track("playing"), duration: 200)

        h.nav.toggleLyrics()
        h.nav.perform(.songData, for: song("x"), in: .none)
        #expect(h.nav.rightColumn == .songData)
        #expect(h.service.lyrics.isPanelOpen == false)

        h.nav.toggleQueue()
        #expect(h.nav.rightColumn == .queue)
        #expect(h.data.isOpen == false)

        h.nav.perform(.songData, for: song("x"), in: .none)
        #expect(h.nav.rightColumn == .songData)
        #expect(h.nav.queueForced == false)

        h.nav.toggleRelated()
        #expect(h.nav.rightColumn == .related)
        #expect(h.data.isOpen == false)

        h.nav.perform(.songData, for: song("x"), in: .none)
        #expect(h.nav.rightColumn == .songData)
        #expect(h.service.related.state == .idle)

        h.nav.toggleLyrics()
        #expect(h.nav.rightColumn == .lyrics)
        #expect(h.data.isOpen == false)

        h.nav.perform(.songData, for: song("x"), in: .none)
        h.nav.openLyrics()
        #expect(h.nav.rightColumn == .lyrics)
        #expect(h.data.isOpen == false)

        h.nav.perform(.songData, for: song("x"), in: .none)
        h.nav.perform(.related, for: song("x"), in: .none)
        #expect(h.nav.rightColumn == .related)
        #expect(h.data.isOpen == false)
    }

    @Test("Opening Song data from Up next leaves its field closed")
    func queueFieldCloses() async {
        let h = SongDataNavHarness()
        await h.play("a")
        h.nav.toggleQueue()
        h.nav.openField()
        #expect(h.nav.isQueueFieldOpen)

        h.nav.perform(.songData, for: song("x"), in: .none)

        #expect(h.nav.isQueueFieldOpen == false)
        #expect(h.nav.queueQuery.isEmpty)
    }

    @Test("Song data has no field to open")
    func noField() async {
        let h = SongDataNavHarness()
        h.nav.perform(.songData, for: song("x"), in: .none)
        #expect(h.nav.scope == .none)
        #expect(h.nav.scope.showsMagnifier == false)
        h.nav.openField()
        #expect(h.nav.isFieldOpen == false)
    }

    @Test("The save menu floats over Song data, and opening Song data closes the menu")
    func pickerFloats() async {
        let h = SongDataNavHarness()
        h.nav.perform(.songData, for: song("x"), in: .none)
        h.nav.perform(.saveToPlaylist, for: song("picked"), in: .none)
        #expect(h.nav.showsPicker)
        #expect(h.nav.rightColumn == .songData)
        h.nav.closePicker()
        h.nav.perform(.saveToPlaylist, for: song("picked"), in: .none)
        h.nav.perform(.songData, for: song("y"), in: .none)
        #expect(h.nav.showsPicker == false)
    }

    // MARK: - Closing

    @Test("Closing the panel, a tab, a page and a new search each give the column back")
    func closers() async {
        let h = SongDataNavHarness()

        h.nav.perform(.songData, for: song("x"), in: .none)
        h.nav.closePanel()
        #expect(h.nav.rightColumn == .browse)
        #expect(h.data.isOpen == false)

        h.nav.perform(.songData, for: song("x"), in: .none)
        h.nav.select(.library)
        #expect(h.nav.rightColumn == .browse)
        #expect(h.data.isOpen == false)

        h.nav.perform(.songData, for: song("x"), in: .none)
        h.nav.openArtist(MusicSamples.collection("UCa", kind: .artist, title: "Artist"))
        #expect(h.nav.rightColumn == .browse)
        #expect(h.data.isOpen == false)

        h.nav.perform(.songData, for: song("x"), in: .none)
        h.service.query = "q"
        h.nav.submit()
        #expect(h.nav.rightColumn != .songData)
        #expect(h.data.isOpen == false)
    }

    @Test("Escape closes Song data and says so, then has nothing left to close")
    func escapeCloses() {
        let h = SongDataNavHarness()
        h.nav.perform(.songData, for: song("x"), in: .none)

        #expect(h.nav.escape())
        #expect(h.nav.rightColumn == .browse)
        #expect(h.data.isOpen == false)
        #expect(h.nav.escape() == false)
    }

    @Test("Escape closes the save menu first and Song data after it")
    func escapeOrder() {
        let h = SongDataNavHarness()
        h.nav.perform(.songData, for: song("x"), in: .none)
        h.nav.perform(.saveToPlaylist, for: song("picked"), in: .none)

        #expect(h.nav.escape())
        #expect(h.nav.showsPicker == false)
        #expect(h.nav.rightColumn == .songData)
        #expect(h.nav.escape())
        #expect(h.nav.rightColumn == .browse)
    }

    @Test("Typing in a field leaves Song data open")
    func typingKeepsIt() {
        let h = SongDataNavHarness()
        h.nav.perform(.songData, for: song("x"), in: .none)
        h.service.query = "qu"
        h.nav.queryChanged()
        #expect(h.nav.rightColumn == .songData)
    }

    @Test("Playback stopping leaves Song data open: it is for a song of its own, as a pinned Related panel is")
    func playerStopped() async {
        let h = SongDataNavHarness()
        await h.play("a")
        h.nav.perform(.songData, for: song("x"), in: .none)
        h.nav.playerStopped()
        #expect(h.nav.rightColumn == .songData)
        #expect(h.data.track?.videoId == "x")
    }

    @Test("The panel goes with the session: signing out closes it")
    func sessionEnds() async {
        let h = SongDataNavHarness()
        h.nav.perform(.songData, for: song("x"), in: .none)
        await h.settled()

        h.service.signOut()

        #expect(h.nav.showsSongData == false)
        #expect(h.nav.rightColumn == .browse)
    }

    @Test("Whether Song data is open is the store's state alone")
    func storeIsTheOnlySourceOfTruth() {
        let h = SongDataNavHarness()
        h.data.show(song("x"))
        #expect(h.nav.showsSongData)
        #expect(h.nav.rightColumn == .songData)
        h.data.close()
        #expect(h.nav.showsSongData == false)
        #expect(h.nav.rightColumn == .browse)
    }
}

@MainActor
@Suite("MusicRightColumn song data")
struct MusicRightColumnSongDataTests {
    @Test("Song data resolves to its own column, with its own header and the wash")
    func resolves() {
        let column = MusicRightColumn.resolve(showsLyrics: false, showsQueue: false, showsRelated: false, showsSongData: true)
        #expect(column == .songData)
        #expect(column.header == .songData)
        #expect(column.hasWash)
    }

    @Test("two panels on at once resolve Lyrics, then Up next, then Related, then Song data")
    func priority() {
        #expect(MusicRightColumn.resolve(showsLyrics: true, showsQueue: false, showsRelated: false, showsSongData: true) == .lyrics)
        #expect(MusicRightColumn.resolve(showsLyrics: false, showsQueue: true, showsRelated: false, showsSongData: true) == .queue)
        #expect(MusicRightColumn.resolve(showsLyrics: false, showsQueue: false, showsRelated: true, showsSongData: true) == .related)
    }

    @Test("the three-flag call still resolves, with Song data off")
    func defaultOff() {
        #expect(MusicRightColumn.resolve(showsLyrics: false, showsQueue: false, showsRelated: false) == .browse)
    }
}
