// DeciTests/Music/MusicSearchFieldNavigationTests.swift
// The contextual search field of the right column: where the magnifier opens it, what it searches on each screen,
// how Esc clears and then folds it, how a field is dropped when the column moves on, and the link that takes a filter's
// words to YouTube Music.

import Foundation
import Testing
@testable import Deci

@MainActor
private struct FieldNavHarness {
    let backend = FakeMusicBackend()
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
            refreshOnCreate: false
        )
        nav = MusicSearchNavigation(service: service)
    }

    var path: [String] { service.browse.path.map(\.browseId) }

    static func artist(_ id: String) -> MusicCollection {
        MusicSamples.collection(id, kind: .artist, title: "Artist \(id)", subtitle: "Artist")
    }

    func openPlaylist(_ id: String = "PL1") {
        service.browse.open(MusicSamples.collection(id, kind: .playlist))
        nav.reconcile()
    }

    func openAlbum(_ id: String = "MPRE1") {
        service.browse.open(MusicSamples.collection(id, kind: .album))
        nav.reconcile()
    }

    func openLiked() {
        service.browse.open(MusicBrowseStore.likedMusic)
        nav.reconcile()
    }

    func openArtistPage(_ id: String = "UCa") {
        service.browse.open(Self.artist(id))
        nav.reconcile()
    }

    /// Types into the field as the view does: through the navigation's own binding.
    func type(_ text: String) {
        nav.fieldQuery = text
    }

    /// Types `query`, presses Return and waits for the search to land.
    func search(_ query: String, songs: [MusicTrack] = [MusicSamples.track("s1")], artists: [MusicCollection] = []) async {
        await backend.setSearch(query, results: songs)
        await backend.setArtistSearch(query, results: artists)
        type(query)
        nav.submit()
        await service.searchTask?.value
    }

    func playSomething() {
        service.play(MusicSamples.track("playing"))
    }

    func loadLyricsTrack() {
        service.lyrics.trackChanged(MusicSamples.track("playing"), duration: 200)
    }

    func openQueueField() {
        playSomething()
        nav.toggleQueue()
        nav.openField()
    }
}

// MARK: - Scope and opening

@MainActor
@Suite("MusicSearchNavigation field scope")
struct MusicSearchFieldScopeTests {
    @Test("the scope follows the screen on top: Home, Library, each kind of page, Up next, Lyrics, and the save menu leaves it")
    func scopeFollowsTheScreen() {
        let h = FieldNavHarness()
        #expect(h.nav.scope == .global)

        h.nav.select(.library)
        #expect(h.nav.scope == .library)

        h.openPlaylist()
        #expect(h.nav.scope == .playlist)
        h.nav.select(.library)

        h.openLiked()
        #expect(h.nav.scope == .playlist)
        h.nav.select(.library)

        h.openAlbum()
        #expect(h.nav.scope == .album)
        h.nav.select(.home)

        h.openArtistPage()
        #expect(h.nav.scope == .artist)
        h.nav.select(.home)

        h.nav.select(.history)
        #expect(h.nav.scope == .history)
        h.nav.select(.home)

        h.playSomething()
        h.nav.toggleQueue()
        #expect(h.nav.scope == .queue)

        h.loadLyricsTrack()
        h.nav.toggleLyrics()
        #expect(h.nav.scope == .none)

        // The save menu floats over the popup: Lyrics stays the column under it.
        h.nav.perform(.saveToPlaylist, for: MusicSamples.track("picked"), in: .none)
        #expect(h.nav.rightColumn == .lyrics)
        #expect(h.nav.scope == .none)
    }

    @Test("the magnifier opens an empty field on Home, with the YouTube Music placeholder")
    func opensOnHome() {
        let h = FieldNavHarness()
        #expect(h.nav.isFieldOpen == false)
        h.nav.openField()
        #expect(h.nav.isFieldOpen)
        #expect(h.nav.fieldQuery.isEmpty)
        #expect(h.nav.scope.placeholder == "Search YouTube Music")
    }

    @Test("the magnifier opens a field on Library, a playlist, Liked music, an album, an artist page and History")
    func opensOnEveryScreen() {
        let h = FieldNavHarness()
        h.nav.select(.library)
        h.nav.openField()
        #expect(h.nav.isFieldOpen)
        #expect(h.nav.scope.placeholder == "Search your library")

        h.openPlaylist()
        #expect(h.nav.isFieldOpen == false)
        h.nav.openField()
        #expect(h.nav.isFieldOpen)
        #expect(h.nav.scope.placeholder == "Search in this playlist")

        h.nav.select(.library)
        h.openLiked()
        h.nav.openField()
        #expect(h.nav.isFieldOpen)
        #expect(h.nav.scope == .playlist)

        h.nav.select(.library)
        h.openAlbum()
        h.nav.openField()
        #expect(h.nav.isFieldOpen)
        #expect(h.nav.scope.placeholder == "Search in this album")

        h.nav.select(.home)
        h.openArtistPage()
        h.nav.openField()
        #expect(h.nav.isFieldOpen)
        #expect(h.nav.scope.placeholder == "Search this artist")

        h.nav.select(.history)
        h.nav.openField()
        #expect(h.nav.isFieldOpen)
        #expect(h.nav.scope.placeholder == "Search your history")
    }

    @Test("the magnifier opens the Up next field, empty, with the queue placeholder")
    func opensOnQueue() {
        let h = FieldNavHarness()
        h.playSomething()
        h.nav.toggleQueue()
        #expect(h.nav.isFieldOpen == false)
        h.nav.openField()
        #expect(h.nav.isFieldOpen)
        #expect(h.nav.isQueueFieldOpen)
        #expect(h.nav.scope.placeholder == "Search the queue")
    }

    @Test("Lyrics has no field: opening does nothing, and nothing is left open behind it, nor behind the save menu")
    func lyricsAndPickerHaveNoField() {
        let h = FieldNavHarness()
        h.playSomething()
        h.loadLyricsTrack()
        h.nav.toggleLyrics()
        #expect(h.nav.scope.showsMagnifier == false)
        h.nav.openField()
        #expect(h.nav.isFieldOpen == false)
        h.nav.closePanel()
        #expect(h.nav.isFieldOpen == false)
        #expect(h.nav.isQueueFieldOpen == false)

        h.nav.perform(.saveToPlaylist, for: MusicSamples.track("picked"), in: .none)
        #expect(h.nav.isFieldOpen == false)
        h.nav.closePicker()
        #expect(h.nav.isFieldOpen == false)
        #expect(h.nav.fieldQuery.isEmpty)
    }

    @Test("the field is opened on the screen it was opened on, not on the next one")
    func fieldBelongsToItsScreen() {
        let h = FieldNavHarness()
        h.nav.select(.library)
        h.nav.openField()
        h.openPlaylist()
        #expect(h.nav.isFieldOpen == false)
    }

    @Test("opening a field that is already open leaves its words alone")
    func reopenKeepsWords() {
        let h = FieldNavHarness()
        h.nav.select(.library)
        h.nav.openField()
        h.type("late")
        h.nav.openField()
        #expect(h.nav.fieldQuery == "late")
    }
}

// MARK: - Words

@MainActor
@Suite("MusicSearchNavigation field words")
struct MusicSearchFieldWordsTests {
    @Test("typing on Home is the service's own query, which Return sends")
    func globalWords() {
        let h = FieldNavHarness()
        h.nav.openField()
        h.type("daft")
        #expect(h.service.query == "daft")
        #expect(h.nav.fieldQuery == "daft")
        #expect(h.nav.browseFilterTerms.isEmpty)
    }

    @Test("typing in a filter keeps the words in the navigation and sends nothing")
    func localWords() async {
        let h = FieldNavHarness()
        h.nav.select(.library)
        h.nav.openField()
        h.type("late night")
        #expect(h.nav.fieldQuery == "late night")
        #expect(h.service.query.isEmpty)
        #expect(h.nav.browseFilterTerms == ["late", "night"])
        #expect(await h.backend.searchedQueries.isEmpty)
    }

    @Test("a filter is by its words only while its field is open on that screen")
    func filterTermsNeedTheField() {
        let h = FieldNavHarness()
        h.nav.select(.library)
        #expect(h.nav.browseFilterTerms.isEmpty)
        h.nav.openField()
        h.type("late")
        #expect(h.nav.browseFilterTerms == ["late"])

        // A page opened on top is another screen, even before the field has folded.
        h.service.browse.open(MusicSamples.collection("PL1", kind: .playlist))
        #expect(h.nav.browseFilterTerms.isEmpty)
    }

    @Test("a filter keeps its words from one Library segment to the next")
    func segmentKeepsWords() {
        let h = FieldNavHarness()
        h.nav.select(.library)
        h.nav.openField()
        h.type("late")
        h.service.browse.librarySection = .albums
        h.nav.reconcile()
        #expect(h.nav.isFieldOpen)
        #expect(h.nav.fieldQuery == "late")
        #expect(h.nav.browseFilterTerms == ["late"])
    }

    @Test("the Up next field holds its own words, and filters only while Up next shows")
    func queueWords() {
        let h = FieldNavHarness()
        h.openQueueField()
        h.type("blue")
        #expect(h.nav.queueQuery == "blue")
        #expect(h.nav.queueFilterTerms == ["blue"])
        #expect(h.service.query.isEmpty)

        h.nav.closePanel()
        #expect(h.nav.queueFilterTerms.isEmpty)
    }

    @Test("words typed where there is no field go nowhere")
    func noFieldNoWords() {
        let h = FieldNavHarness()
        h.playSomething()
        h.loadLyricsTrack()
        h.nav.toggleLyrics()
        h.type("lost")
        #expect(h.nav.fieldQuery.isEmpty)
        #expect(h.service.query.isEmpty)
        #expect(h.nav.filterQuery.isEmpty)
        #expect(h.nav.queueQuery.isEmpty)
    }

    @Test("the clear button empties the words and keeps the field open, on each scope")
    func clearKeepsTheFieldOpen() async {
        let h = FieldNavHarness()
        h.nav.openField()
        await h.search("alpha")
        h.nav.clearField()
        #expect(h.service.query.isEmpty)
        #expect(h.service.results.isEmpty)
        #expect(h.nav.isFieldOpen)
        #expect(h.nav.showsResults == false)

        h.nav.select(.library)
        h.nav.openField()
        h.type("x")
        h.nav.clearField()
        #expect(h.nav.filterQuery.isEmpty)
        #expect(h.nav.isFieldOpen)

        h.openPlaylist()
        h.nav.openField()
        h.type("x")
        h.nav.clearField()
        #expect(h.nav.filterQuery.isEmpty)
        #expect(h.nav.isFieldOpen)

        h.nav.select(.home)
        h.openQueueField()
        h.type("x")
        h.nav.clearField()
        #expect(h.nav.queueQuery.isEmpty)
        #expect(h.nav.isQueueFieldOpen)
    }
}

// MARK: - Escape

@MainActor
@Suite("MusicSearchNavigation field escape")
struct MusicSearchFieldEscapeTests {
    @Test("on Home Esc clears the words and the results, a second Esc folds the field, a third finds nothing")
    func globalEscapeTwice() async {
        let h = FieldNavHarness()
        h.nav.openField()
        await h.search("alpha")
        #expect(h.nav.showsSearchPanel)

        #expect(h.nav.escape())
        #expect(h.service.query.isEmpty)
        #expect(h.service.results.isEmpty)
        #expect(h.nav.showsSearchPanel == false)
        #expect(h.nav.isFieldOpen)

        #expect(h.nav.escape())
        #expect(h.nav.isFieldOpen == false)

        #expect(h.nav.escape() == false)
    }

    @Test("words typed but not sent are cleared by the first Esc too")
    func globalEscapeUnsent() {
        let h = FieldNavHarness()
        h.nav.openField()
        h.type("typing")
        #expect(h.nav.escape())
        #expect(h.service.query.isEmpty)
        #expect(h.nav.isFieldOpen)
        #expect(h.nav.escape())
        #expect(h.nav.isFieldOpen == false)
    }

    @Test("an empty field folds on the first Esc")
    func globalEscapeEmpty() {
        let h = FieldNavHarness()
        h.nav.openField()
        #expect(h.nav.escape())
        #expect(h.nav.isFieldOpen == false)
    }

    @Test("on Library Esc clears the filter, a second Esc folds the field")
    func libraryEscapeTwice() {
        let h = FieldNavHarness()
        h.nav.select(.library)
        h.nav.openField()
        h.type("late")

        #expect(h.nav.escape())
        #expect(h.nav.filterQuery.isEmpty)
        #expect(h.nav.browseFilterTerms.isEmpty)
        #expect(h.nav.isFieldOpen)

        #expect(h.nav.escape())
        #expect(h.nav.isFieldOpen == false)
        #expect(h.service.browse.tab == .library)
        #expect(h.nav.escape() == false)
    }

    @Test("on a playlist, Liked music and an album Esc clears the filter, then folds the field, and keeps the page")
    func pageEscapeTwice() {
        let h = FieldNavHarness()
        let opens: [() -> Void] = [{ h.openPlaylist("PL1") }, { h.openLiked() }, { h.openAlbum("MPRE1") }]
        for open in opens {
            h.nav.select(.library)
            open()
            let page = h.path
            h.nav.openField()
            h.type("night")

            #expect(h.nav.escape())
            #expect(h.nav.filterQuery.isEmpty)
            #expect(h.nav.isFieldOpen)
            #expect(h.path == page)

            #expect(h.nav.escape())
            #expect(h.nav.isFieldOpen == false)
            #expect(h.path == page)
            #expect(h.nav.escape() == false)
        }
    }

    @Test("on an artist page and on History Esc clears the filter, then folds the field, and keeps the page")
    func artistAndHistoryEscapeTwice() {
        let h = FieldNavHarness()
        h.openArtistPage()
        h.nav.openField()
        h.type("night")

        #expect(h.nav.escape())
        #expect(h.nav.filterQuery.isEmpty)
        #expect(h.service.query.isEmpty)
        #expect(h.nav.isFieldOpen)
        #expect(h.nav.escape())
        #expect(h.nav.isFieldOpen == false)
        #expect(h.path == ["UCa"])
        #expect(h.nav.escape() == false)

        h.nav.select(.history)
        h.nav.openField()
        h.type("night")
        #expect(h.nav.escape())
        #expect(h.nav.filterQuery.isEmpty)
        #expect(h.nav.isFieldOpen)
        #expect(h.nav.escape())
        #expect(h.nav.isFieldOpen == false)
        #expect(h.service.browse.tab == .history)
    }

    @Test("on Up next Esc clears the words, then folds the field, and only then closes Up next")
    func queueEscape() {
        let h = FieldNavHarness()
        h.openQueueField()
        h.type("blue")

        #expect(h.nav.escape())
        #expect(h.nav.queueQuery.isEmpty)
        #expect(h.nav.isQueueFieldOpen)
        #expect(h.nav.showsQueue)

        #expect(h.nav.escape())
        #expect(h.nav.isQueueFieldOpen == false)
        #expect(h.nav.showsQueue)

        #expect(h.nav.escape())
        #expect(h.nav.showsQueue == false)
        #expect(h.nav.rightColumn == .browse)

        #expect(h.nav.escape() == false)
    }

    @Test("the picker and Lyrics take Esc before a field under them")
    func pickerAndLyricsFirst() {
        let h = FieldNavHarness()
        h.nav.select(.library)
        h.nav.openField()
        h.type("late")
        h.playSomething()
        h.loadLyricsTrack()
        h.nav.toggleLyrics()

        #expect(h.nav.escape())
        #expect(h.nav.showsLyrics == false)
        #expect(h.nav.filterQuery == "late")
        #expect(h.nav.isFieldOpen)

        #expect(h.nav.escape())
        #expect(h.nav.filterQuery.isEmpty)
    }
}

// MARK: - Dropping a field

@MainActor
@Suite("MusicSearchNavigation field reconcile")
struct MusicSearchFieldReconcileTests {
    @Test("a tab pick folds a Home field and drops its words")
    func tabDropsGlobal() {
        let h = FieldNavHarness()
        h.nav.openField()
        h.type("alpha")
        h.nav.select(.library)
        #expect(h.nav.isFieldOpen == false)
        #expect(h.service.query.isEmpty)
    }

    @Test("a tab pick folds a Library filter and drops its words")
    func tabDropsLibrary() {
        let h = FieldNavHarness()
        h.nav.select(.library)
        h.nav.openField()
        h.type("late")

        h.nav.select(.home)
        #expect(h.nav.filterQuery.isEmpty)
        #expect(h.nav.browseFilterTerms.isEmpty)

        h.nav.select(.library)
        #expect(h.nav.isFieldOpen == false)
        #expect(h.nav.fieldQuery.isEmpty)
    }

    @Test("picking the tab already on folds a field too")
    func sameTabDrops() {
        let h = FieldNavHarness()
        h.nav.select(.library)
        h.nav.openField()
        h.type("late")
        h.nav.select(.library)
        #expect(h.nav.isFieldOpen == false)
        #expect(h.nav.filterQuery.isEmpty)
    }

    @Test("opening a page folds a Library filter and drops its words")
    func pageDropsLibrary() {
        let h = FieldNavHarness()
        h.nav.select(.library)
        h.nav.openField()
        h.type("late")

        h.openPlaylist()
        #expect(h.nav.filterQuery.isEmpty)
        #expect(h.nav.isFieldOpen == false)

        h.service.browse.back()
        h.nav.reconcile()
        #expect(h.nav.isFieldOpen == false)
        #expect(h.nav.fieldQuery.isEmpty)
    }

    @Test("opening a page folds a Home field and drops the words that were typed")
    func pageDropsGlobal() {
        let h = FieldNavHarness()
        h.nav.openField()
        h.type("alpha")
        h.openPlaylist()
        #expect(h.nav.isFieldOpen == false)
        #expect(h.service.query.isEmpty)
    }

    @Test("going Back from a page folds the filter that was open on it")
    func backDropsPageFilter() {
        let h = FieldNavHarness()
        h.nav.select(.library)
        h.openPlaylist()
        h.nav.openField()
        h.type("night")

        h.service.browse.back()
        h.nav.reconcile()
        #expect(h.nav.filterQuery.isEmpty)
        #expect(h.nav.isFieldOpen == false)
        #expect(h.service.browse.tab == .library)
    }

    @Test("a page deeper in the path is another screen: the filter of the page under it is dropped")
    func deeperPageDropsFilter() {
        let h = FieldNavHarness()
        h.openPlaylist("PL1")
        h.nav.openField()
        h.type("night")
        h.openAlbum("MPRE1")
        #expect(h.nav.filterQuery.isEmpty)
        #expect(h.nav.isFieldOpen == false)
    }

    @Test("a field that is still where it was opened stays, words and all")
    func reconcileKeepsAFieldInPlace() {
        let h = FieldNavHarness()
        h.nav.select(.library)
        h.nav.openField()
        h.type("late")
        h.nav.reconcile()
        #expect(h.nav.isFieldOpen)
        #expect(h.nav.filterQuery == "late")
    }

    @Test("the Up next field closes with Up next, and a queue opens with its field closed")
    func queueFieldClosesWithTheQueue() {
        let h = FieldNavHarness()
        h.openQueueField()
        h.type("blue")
        h.nav.toggleQueue()
        #expect(h.nav.isQueueFieldOpen == false)
        #expect(h.nav.queueQuery.isEmpty)

        h.nav.toggleQueue()
        #expect(h.nav.showsQueue)
        #expect(h.nav.isFieldOpen == false)
        #expect(h.nav.queueFilterTerms.isEmpty)

        h.nav.openField()
        h.type("blue")
        h.nav.closePanel()
        #expect(h.nav.isQueueFieldOpen == false)
        #expect(h.nav.queueQuery.isEmpty)
    }

    @Test("opening an artist from Up next closes the queue and its field")
    func queueFieldClosesOnOpen() {
        let h = FieldNavHarness()
        h.openQueueField()
        h.type("blue")
        h.nav.openArtist(FieldNavHarness.artist("UCa"))
        #expect(h.nav.isQueueFieldOpen == false)
        #expect(h.nav.queueQuery.isEmpty)
        #expect(h.nav.showsQueue == false)
    }

    @Test("resetting folds every field, drops every set of words and the YouTube Music query")
    func resetFields() {
        let h = FieldNavHarness()
        h.nav.openField()
        h.type("alpha")
        h.nav.resetFields()
        #expect(h.nav.isFieldOpen == false)
        #expect(h.service.query.isEmpty)

        h.nav.select(.library)
        h.nav.openField()
        h.type("late")
        h.nav.resetFields()
        #expect(h.nav.filterQuery.isEmpty)
        #expect(h.nav.isFieldOpen == false)

        h.openQueueField()
        h.type("blue")
        h.nav.resetFields()
        #expect(h.nav.isQueueFieldOpen == false)
        #expect(h.nav.queueQuery.isEmpty)
    }
}

// MARK: - Results

@MainActor
@Suite("MusicSearchNavigation field results")
struct MusicSearchFieldResultsTests {
    @Test("the results cover the browse content only while the Home field is open and has words")
    func showsSearchPanel() async {
        let h = FieldNavHarness()
        #expect(h.nav.showsSearchPanel == false)

        h.nav.openField()
        #expect(h.nav.showsSearchPanel == false)

        h.type("alpha")
        #expect(h.nav.showsSearchPanel)

        await h.search("alpha")
        #expect(h.nav.showsSearchPanel)
        #expect(h.nav.panel == .results)

        h.type("")
        #expect(h.nav.showsSearchPanel == false)
    }

    @Test("a filter never shows the YouTube Music results")
    func filterNeverShowsResults() {
        let h = FieldNavHarness()
        h.nav.select(.library)
        h.nav.openField()
        h.type("late")
        #expect(h.nav.showsSearchPanel == false)

        h.openPlaylist()
        h.nav.openField()
        h.type("late")
        #expect(h.nav.showsSearchPanel == false)
    }

    @Test("an artist page's field filters that artist: the YouTube Music results never cover the page")
    func artistPageNeverShowsResults() async {
        let h = FieldNavHarness()
        h.openArtistPage()
        h.nav.openField()
        h.type("alpha")
        #expect(h.nav.showsSearchPanel == false)
        #expect(h.nav.browseFilterTerms == ["alpha"])
        #expect(h.service.query.isEmpty)
        #expect(await h.backend.searchedQueries.isEmpty)
        #expect(h.path == ["UCa"])
    }

    @Test("results from Home do not cover another screen")
    func resultsStayOnTheirScreen() async {
        let h = FieldNavHarness()
        h.nav.openField()
        await h.search("alpha")
        h.nav.select(.library)
        #expect(h.nav.showsSearchPanel == false)
        #expect(h.service.query.isEmpty)
    }

    @Test("an artist opened from the results hides them, and Back brings them and the field back")
    func backReturnsToResults() async {
        let h = FieldNavHarness()
        let artist = FieldNavHarness.artist("UCa")
        h.nav.openField()
        await h.search("alpha", artists: [artist])
        #expect(h.nav.showsSearchPanel)

        h.nav.openArtist(artist)
        h.nav.reconcile()
        #expect(h.nav.hidesResults)
        #expect(h.nav.showsResults == false)
        #expect(h.nav.showsSearchPanel == false)
        #expect(h.service.query == "alpha")

        h.service.browse.back()
        h.nav.reconcile()
        #expect(h.nav.showsResults)
        #expect(h.nav.showsSearchPanel)
        #expect(h.nav.isFieldOpen)
        #expect(h.nav.fieldQuery == "alpha")
        #expect(h.service.results.count == 1)
    }

    @Test("the results of a field are dropped when the path is left some other way than Back")
    func resultsDroppedOnTabPick() async {
        let h = FieldNavHarness()
        let artist = FieldNavHarness.artist("UCa")
        h.nav.openField()
        await h.search("alpha", artists: [artist])
        h.nav.openArtist(artist)
        h.nav.reconcile()

        h.nav.select(.home)
        #expect(h.service.query.isEmpty)
        #expect(h.nav.isFieldOpen == false)
        #expect(h.nav.showsSearchPanel == false)
        #expect(h.nav.hidesResults == false)
    }

    @Test("Return while the results are hidden by an artist brings them back")
    func returnBringsResultsBack() async {
        let h = FieldNavHarness()
        let artist = FieldNavHarness.artist("UCa")
        h.nav.openField()
        await h.search("alpha", artists: [artist])
        h.nav.openArtist(artist)
        h.nav.reconcile()

        h.nav.submit()
        await h.service.searchTask?.value
        #expect(h.nav.hidesResults == false)
        #expect(h.nav.showsResults)
    }
}

// MARK: - Search YouTube Music instead

@MainActor
@Suite("MusicSearchNavigation search instead")
struct MusicSearchFieldInsteadTests {
    @Test("from a Library filter the words go to Home's field and are sent")
    func fromLibrary() async {
        let h = FieldNavHarness()
        h.nav.select(.library)
        h.nav.openField()
        h.type("  zzz ")

        h.nav.searchYouTubeMusicInstead()
        await h.service.searchTask?.value

        #expect(h.service.browse.tab == .home)
        #expect(h.path.isEmpty)
        #expect(h.nav.scope == .global)
        #expect(h.nav.isFieldOpen)
        #expect(h.service.query == "zzz")
        #expect(h.nav.fieldQuery == "zzz")
        #expect(h.nav.submittedQuery == "zzz")
        #expect(h.nav.showsSearchPanel)
        #expect(await h.backend.searchedQueries == ["zzz"])
        #expect(h.nav.filterQuery.isEmpty)
    }

    @Test("from a playlist filter the page is left and the words go to Home's field")
    func fromPlaylist() async {
        let h = FieldNavHarness()
        h.nav.select(.library)
        h.openPlaylist()
        h.nav.openField()
        h.type("zzz")

        h.nav.searchYouTubeMusicInstead()
        await h.service.searchTask?.value

        #expect(h.service.browse.tab == .home)
        #expect(h.path.isEmpty)
        #expect(h.nav.isFieldOpen)
        #expect(h.service.query == "zzz")
        #expect(h.nav.showsSearchPanel)
        #expect(await h.backend.searchedQueries == ["zzz"])
    }

    @Test("from an album filter the words go to Home's field")
    func fromAlbum() async {
        let h = FieldNavHarness()
        h.openAlbum()
        h.nav.openField()
        h.type("zzz")

        h.nav.searchYouTubeMusicInstead()
        await h.service.searchTask?.value

        #expect(h.path.isEmpty)
        #expect(h.service.query == "zzz")
        #expect(h.nav.showsSearchPanel)
    }

    @Test("from Up next the queue closes and the words go to Home's field")
    func fromQueue() async {
        let h = FieldNavHarness()
        h.openQueueField()
        h.type("zzz")

        h.nav.searchYouTubeMusicInstead()
        await h.service.searchTask?.value

        #expect(h.nav.showsQueue == false)
        #expect(h.nav.isQueueFieldOpen == false)
        #expect(h.nav.queueQuery.isEmpty)
        #expect(h.service.browse.tab == .home)
        #expect(h.service.query == "zzz")
        #expect(h.nav.isFieldOpen)
        #expect(h.nav.showsSearchPanel)
    }

    @Test("blank words do nothing")
    func blankDoesNothing() async {
        let h = FieldNavHarness()
        h.nav.select(.library)
        h.nav.openField()
        h.type("   ")

        h.nav.searchYouTubeMusicInstead()

        #expect(h.service.browse.tab == .library)
        #expect(h.service.query.isEmpty)
        #expect(await h.backend.searchedQueries.isEmpty)
        #expect(h.nav.isFieldOpen)
    }

    @Test("Esc after it clears the YouTube Music words, then folds Home's field")
    func escapeAfterwards() async {
        let h = FieldNavHarness()
        h.nav.select(.library)
        h.nav.openField()
        h.type("zzz")
        h.nav.searchYouTubeMusicInstead()
        await h.service.searchTask?.value

        #expect(h.nav.escape())
        #expect(h.service.query.isEmpty)
        #expect(h.nav.isFieldOpen)
        #expect(h.nav.escape())
        #expect(h.nav.isFieldOpen == false)
    }
}
