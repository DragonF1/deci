// DeciTests/Music/MusicSearchNavigationTests.swift
// What the Music tab shows over Home and Library (search results, Up next, Lyrics) and the one path every artist
// name and tile takes to an artist page: from the results, from Up next or Lyrics, from a page, from Home.

import Foundation
import Testing
@testable import Deci

@MainActor
private struct NavHarness {
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

    static func artist(_ id: String, name: String? = nil) -> MusicCollection {
        MusicSamples.collection(id, kind: .artist, title: name ?? "Artist \(id)", subtitle: "Artist")
    }

    /// Types `query`, presses Return and waits for the search to land.
    func search(_ query: String, songs: [MusicTrack] = [MusicSamples.track("s1")], artists: [MusicCollection] = []) async {
        await backend.setSearch(query, results: songs)
        await backend.setArtistSearch(query, results: artists)
        service.query = query
        nav.submit()
        await service.searchTask?.value
    }

    /// Some page already open under whatever shows next, as if reached from Home or Library.
    func openPage(_ id: String) {
        service.browse.open(MusicSamples.collection(id, kind: .playlist))
    }

    /// Something in the queue, so the Up next button exists.
    func playSomething() {
        service.play(MusicSamples.track("playing"))
    }

    /// A loaded track, so the Lyrics button exists.
    func loadLyricsTrack() {
        service.lyrics.trackChanged(MusicSamples.track("playing"), duration: 200)
    }
}

@MainActor
@Suite("MusicSearchNavigation")
struct MusicSearchNavigationTests {

    // MARK: - What shows

    @Test("with no query nothing of search shows and the tab is browsing")
    func noQueryBrowses() {
        let h = NavHarness()
        #expect(h.nav.showsResults == false)
        #expect(h.nav.isBrowsing)
        #expect(h.nav.hidesResults == false)
        #expect(h.nav.showsQueue == false)
        #expect(h.nav.showsLyrics == false)
    }

    @Test("a submitted search with songs shows the results over browsing")
    func submittedShowsResults() async {
        let h = NavHarness()
        await h.search("q")
        #expect(h.nav.showsResults)
        #expect(h.nav.isBrowsing == false)
        #expect(h.nav.hasResults)
    }

    @Test("a submitted search that found nothing still shows its (empty) result")
    func emptySubmittedStillShows() async {
        let h = NavHarness()
        await h.search("nothing", songs: [])
        #expect(h.nav.showsResults)
        #expect(h.nav.hasResults == false)
    }

    @Test("a search that found only artists shows the results")
    func artistsOnlyShows() async {
        let h = NavHarness()
        await h.search("q", songs: [], artists: [NavHarness.artist("UCa")])
        #expect(h.nav.showsResults)
        #expect(h.nav.hasResults)
    }

    @Test("results show while the search is running, even with nothing yet")
    func showsWhileSearching() async {
        let h = NavHarness()
        let gate = MusicTestGate()
        await h.backend.setSearchGate("q", gate)
        h.service.query = "q"
        h.nav.submit()
        #expect(h.service.isSearching)
        #expect(h.nav.showsResults)
        await gate.open()
        await h.service.searchTask?.value
    }

    @Test("editing the query to one that was never submitted and has no results goes back to browsing")
    func unsubmittedWithoutResultsBrowses() {
        let h = NavHarness()
        h.service.query = "typing"
        h.nav.queryChanged()
        #expect(h.nav.showsResults == false)
        #expect(h.nav.isBrowsing)
    }

    @Test("a blank query never shows results, whatever is left in the lists")
    func blankQueryNeverShows() async {
        let h = NavHarness()
        await h.search("q", artists: [NavHarness.artist("UCa")])
        h.service.query = "  \n "
        #expect(h.nav.showsResults == false)
        #expect(h.nav.isBrowsing)
    }

    // MARK: - What the Search tab shows under the field

    @Test("the panel says no songs or artists, and the searching and failed states win over it")
    func panelStates() async {
        let h = NavHarness()
        await h.search("nothing", songs: [])
        #expect(h.nav.panel == .noResults)

        await h.backend.setSearchError("bad", MusicError.http(500))
        h.service.query = "bad"
        h.nav.submit()
        #expect(h.nav.panel == .searching)
        await h.service.searchTask?.value
        #expect(h.nav.panel == .failed)
    }

    @Test("the panel invites a search, then asks for Return, then lists what was found")
    func panelInviteAndResults() async {
        let h = NavHarness()
        #expect(h.nav.panel == .invite)
        h.service.query = "da"
        #expect(h.nav.panel == .pressReturn)
        await h.search("daft")
        #expect(h.nav.panel == .results)
    }

    @Test("each panel resolves from the search state, and only the list has no message")
    func panelResolve() {
        func resolve(
            empty: Bool = false, shows: Bool = true, has: Bool = false, searching: Bool = false, failed: Bool = false
        ) -> MusicSearchPanel {
            MusicSearchPanel.resolve(
                queryIsEmpty: empty, showsResults: shows, hasResults: has, isSearching: searching, hasFailed: failed
            )
        }
        #expect(resolve(empty: true, shows: false) == .invite)
        #expect(resolve(shows: false) == .pressReturn)
        #expect(resolve(has: true) == .results)
        #expect(resolve(has: true, searching: true) == .results)
        #expect(resolve(searching: true, failed: true) == .searching)
        #expect(resolve(failed: true) == .failed)
        #expect(resolve() == .noResults)

        let panels: [MusicSearchPanel] = [.invite, .pressReturn, .searching, .noResults, .failed]
        #expect(panels.allSatisfy { $0.message != nil })
        #expect(MusicSearchPanel.results.message == nil)
        #expect(MusicSearchPanel.failed.message == "Search failed. Press Return to try again.")
    }

    // MARK: - Return, typing and clearing

    @Test("Return sends the search with the trimmed query and remembers it")
    func submitSearches() async {
        let h = NavHarness()
        h.service.query = "  some band "
        h.nav.submit()
        await h.service.searchTask?.value
        #expect(await h.backend.searchedQueries == ["some band"])
        #expect(h.nav.submittedQuery == "some band")
    }

    @Test("Return closes Up next and Lyrics")
    func submitClosesPanels() {
        let h = NavHarness()
        h.playSomething()
        h.loadLyricsTrack()
        h.nav.toggleQueue()
        #expect(h.nav.showsQueue)
        h.service.lyrics.setPanelOpen(true)
        h.service.query = "q"

        h.nav.submit()

        #expect(h.nav.queueForced == false)
        #expect(h.service.lyrics.isPanelOpen == false)
    }

    @Test("emptying the field stops the search and drops the songs and the artists")
    func emptiedQueryDropsBoth() async {
        let h = NavHarness()
        await h.search("q", artists: [NavHarness.artist("UCa")])

        h.service.query = ""
        h.nav.queryChanged()

        #expect(h.service.results.isEmpty)
        #expect(h.service.artistResults.isEmpty)
        #expect(h.nav.showsResults == false)
    }

    @Test("emptying the field drops a list that has artists only")
    func emptiedQueryDropsArtistsOnly() async {
        let h = NavHarness()
        await h.search("q", songs: [], artists: [NavHarness.artist("UCa")])
        #expect(h.service.artistResults.count == 1)

        h.service.query = ""
        h.nav.queryChanged()

        #expect(h.service.artistResults.isEmpty)
    }

    @Test("typing leaves Up next, Lyrics and Now Playing open, and keeps the results that are there")
    func typingKeepsThePlayerScreens() async {
        let h = NavHarness()
        await h.search("q")
        h.playSomething()
        h.loadLyricsTrack()
        h.nav.toggleQueue()
        #expect(h.nav.screen == .queue)

        h.service.query = "qu"
        h.nav.queryChanged()

        #expect(h.nav.queueForced)
        #expect(h.nav.screen == .queue)
        #expect(h.service.results.count == 1)

        h.nav.toggleLyrics()
        h.service.query = "que"
        h.nav.queryChanged()
        #expect(h.service.lyrics.isPanelOpen)
        #expect(h.nav.screen == .lyrics)

        h.nav.dismissPlayer()
        h.nav.openNowPlaying()
        h.service.query = "quer"
        h.nav.queryChanged()
        #expect(h.nav.isNowPlayingOpen)
        #expect(h.nav.screen == .nowPlaying)
    }

    // MARK: - The panels

    @Test("Up next shows only while the queue has songs and the button asked for it")
    func queuePanel() {
        let h = NavHarness()
        h.nav.toggleQueue()
        #expect(h.nav.queueForced)
        #expect(h.nav.showsQueue == false)

        h.playSomething()
        #expect(h.nav.showsQueue)
        #expect(h.nav.isBrowsing == false)

        h.nav.toggleQueue()
        #expect(h.nav.showsQueue == false)
        #expect(h.nav.isBrowsing)
    }

    @Test("Lyrics shows only with a loaded track, and Up next gives way to it")
    func lyricsPanel() {
        let h = NavHarness()
        h.nav.toggleLyrics()
        #expect(h.service.lyrics.isPanelOpen)
        #expect(h.nav.showsLyrics == false)

        h.loadLyricsTrack()
        #expect(h.nav.showsLyrics)
        #expect(h.nav.isBrowsing == false)

        h.playSomething()
        h.nav.toggleQueue()
        #expect(h.service.lyrics.isPanelOpen == false)
        #expect(h.nav.showsQueue)
        #expect(h.nav.showsLyrics == false)

        h.nav.toggleLyrics()
        #expect(h.nav.queueForced == false)
        #expect(h.service.lyrics.isPanelOpen)
    }

    // MARK: - Opening an artist from the results

    @Test("an artist from the results over Home opens at the root, hides the results and keeps the query")
    func openFromResults() async {
        let h = NavHarness()
        let artist = NavHarness.artist("UCa", name: "Alpha")
        await h.search("alpha", artists: [artist])

        h.nav.openArtist(artist)

        #expect(h.path == ["UCa"])
        #expect(h.service.browse.path.last == artist)
        #expect(h.nav.hidesResults)
        #expect(h.nav.showsResults == false)
        #expect(h.nav.isBrowsing)
        #expect(h.service.query == "alpha")
        #expect(h.service.results.count == 1)
        #expect(h.service.artistResults == [artist])
    }

    @Test("an artist from the results over open pages opens on top of them and keeps the page stack")
    func openFromResultsKeepsThePages() async {
        let h = NavHarness()
        let artist = NavHarness.artist("UCa", name: "Alpha")
        h.openPage("PL1")
        h.openPage("PL2")
        await h.search("alpha", artists: [artist])
        #expect(h.nav.showsResults)

        h.nav.openArtist(artist)

        #expect(h.path == ["PL1", "PL2", "UCa"])
        #expect(h.nav.hidesResults)
        #expect(h.nav.showsResults == false)
        #expect(h.nav.isBrowsing)
        #expect(h.service.query == "alpha")
    }

    @Test("the artist page is requested from the backend")
    func openRequestsThePage() async {
        let h = NavHarness()
        let artist = NavHarness.artist("UCa")
        await h.backend.setPage(MusicSamples.page("UCa", tracks: [MusicSamples.track("top1")]))
        await h.search("alpha", artists: [artist])

        h.nav.openArtist(artist)

        let loaded = await eventually {
            if case .loaded = h.service.browse.pageState("UCa") { true } else { false }
        }
        #expect(loaded)
        if case .loaded(let page) = h.service.browse.pageState("UCa") {
            #expect(page.tracks.map(\.videoId) == ["top1"])
        }
    }

    @Test("Back from the artist page brings the results back")
    func backReturnsToResults() async {
        let h = NavHarness()
        let artist = NavHarness.artist("UCa")
        await h.search("alpha", artists: [artist])
        h.nav.openArtist(artist)
        #expect(h.nav.showsResults == false)

        h.service.browse.back()

        #expect(h.path.isEmpty)
        #expect(h.nav.showsResults)
        #expect(h.nav.isBrowsing == false)
        #expect(h.service.query == "alpha")
    }

    @Test("Back from an artist opened over pages returns to the results, with the pages still under them")
    func backReturnsToResultsOverPages() async {
        let h = NavHarness()
        let artist = NavHarness.artist("UCa")
        h.openPage("PL1")
        h.openPage("PL2")
        await h.search("alpha", artists: [artist])
        h.nav.openArtist(artist)

        h.service.browse.back()

        #expect(h.path == ["PL1", "PL2"])
        #expect(h.nav.showsResults)
        #expect(h.nav.isBrowsing == false)
        #expect(h.service.query == "alpha")
    }

    @Test("clearing the query after Back lands on the page the user was on before the search")
    func clearingTheQueryLandsOnTheEarlierPage() async {
        let h = NavHarness()
        let artist = NavHarness.artist("UCa")
        h.openPage("PL1")
        h.openPage("PL2")
        await h.search("alpha", artists: [artist])
        h.nav.openArtist(artist)
        h.service.browse.back()
        #expect(h.nav.showsResults)

        h.service.query = ""
        h.nav.queryChanged()

        #expect(h.nav.showsResults == false)
        #expect(h.nav.isBrowsing)
        #expect(h.path == ["PL1", "PL2"])
    }

    @Test("clearing the query while the artist is open keeps the whole stack, and Back lands on the earlier page")
    func clearingTheQueryOverTheArtist() async {
        let h = NavHarness()
        let artist = NavHarness.artist("UCa")
        h.openPage("PL1")
        h.openPage("PL2")
        await h.search("alpha", artists: [artist])
        h.nav.openArtist(artist)

        h.service.query = ""
        h.nav.queryChanged()

        #expect(h.nav.hidesResults == false)
        #expect(h.nav.showsResults == false)
        #expect(h.path == ["PL1", "PL2", "UCa"])
        h.service.browse.back()
        #expect(h.path == ["PL1", "PL2"])
        #expect(h.nav.isBrowsing)
    }

    @Test("an artist that is already the top page opens from the results with one Back to return")
    func openFromResultsOverTheSameArtist() async {
        let h = NavHarness()
        let artist = NavHarness.artist("UCa")
        h.openPage("PL1")
        h.nav.openArtist(artist)
        await h.search("alpha", artists: [artist])
        #expect(h.nav.showsResults)

        h.nav.openArtist(artist)

        #expect(h.path == ["PL1", "UCa"])
        #expect(h.nav.showsResults == false)
        h.service.browse.back()
        #expect(h.path == ["PL1"])
        #expect(h.nav.showsResults)
    }

    @Test("results come back only when the whole path is closed, not on the first Back")
    func resultsWaitForTheRoot() async {
        let h = NavHarness()
        let first = NavHarness.artist("UCa")
        let second = NavHarness.artist("UCb")
        await h.search("alpha", artists: [first])
        h.nav.openArtist(first)
        h.nav.openArtist(second)
        #expect(h.path == ["UCa", "UCb"])
        #expect(h.nav.showsResults == false)

        h.service.browse.back()
        #expect(h.path == ["UCa"])
        #expect(h.nav.showsResults == false)

        h.service.browse.back()
        #expect(h.path.isEmpty)
        #expect(h.nav.showsResults)
    }

    @Test("a nested artist from the open artist page needs two Backs to return to the results, over pages too")
    func nestedArtistBackTwiceOverPages() async {
        let h = NavHarness()
        let first = NavHarness.artist("UCa")
        let second = NavHarness.artist("UCb")
        h.openPage("PL1")
        h.openPage("PL2")
        await h.search("alpha", artists: [first])
        h.nav.openArtist(first)

        h.nav.openArtist(second)
        #expect(h.path == ["PL1", "PL2", "UCa", "UCb"])
        #expect(h.nav.showsResults == false)

        h.service.browse.back()
        #expect(h.path == ["PL1", "PL2", "UCa"])
        #expect(h.nav.showsResults == false)

        h.service.browse.back()
        #expect(h.path == ["PL1", "PL2"])
        #expect(h.nav.showsResults)
    }

    @Test("a second search tile after Back opens just the same way")
    func reopenAfterBack() async {
        let h = NavHarness()
        let a = NavHarness.artist("UCa")
        let b = NavHarness.artist("UCb")
        await h.search("alpha", artists: [a, b])
        h.nav.openArtist(a)
        h.service.browse.back()

        h.nav.openArtist(b)

        #expect(h.path == ["UCb"])
        #expect(h.nav.showsResults == false)
        h.service.browse.back()
        #expect(h.nav.showsResults)
    }

    @Test("tapping the same artist twice opens one page")
    func doubleTap() async {
        let h = NavHarness()
        let artist = NavHarness.artist("UCa")
        await h.search("alpha", artists: [artist])
        h.nav.openArtist(artist)
        h.nav.openArtist(artist)
        #expect(h.path == ["UCa"])
        h.service.browse.back()
        #expect(h.nav.showsResults)
    }

    @Test("Return while an artist from the results is open brings the results back")
    func returnClearsHide() async {
        let h = NavHarness()
        let artist = NavHarness.artist("UCa")
        await h.search("alpha", artists: [artist])
        h.nav.openArtist(artist)

        h.nav.submit()
        await h.service.searchTask?.value

        #expect(h.nav.hidesResults == false)
        #expect(h.nav.showsResults)
    }

    @Test("editing the query while an artist from the results is open brings the results back")
    func editClearsHide() async {
        let h = NavHarness()
        let artist = NavHarness.artist("UCa")
        await h.search("alpha", artists: [artist])
        h.nav.openArtist(artist)

        h.service.query = "alph"
        h.nav.queryChanged()

        #expect(h.nav.hidesResults == false)
        #expect(h.nav.showsResults)
    }

    @Test("Home from the switch while a search-opened artist is open clears the query and the hide")
    func homeClearsEverything() async {
        let h = NavHarness()
        let artist = NavHarness.artist("UCa")
        await h.search("alpha", artists: [artist])
        h.service.browse.tab = .library
        h.nav.openArtist(artist)

        h.nav.select(.home)

        #expect(h.service.query.isEmpty)
        #expect(h.nav.hidesResults == false)
        #expect(h.path.isEmpty)
        #expect(h.service.browse.tab == .home)
        #expect(h.nav.showsResults == false)
        #expect(h.nav.isBrowsing)
    }

    @Test("Library from the switch while a search-opened artist is open clears the query and the hide")
    func libraryClearsEverything() async {
        let h = NavHarness()
        let artist = NavHarness.artist("UCa")
        await h.search("alpha", artists: [artist])
        h.nav.openArtist(artist)

        h.nav.select(.library)

        #expect(h.service.query.isEmpty)
        #expect(h.nav.hidesResults == false)
        #expect(h.path.isEmpty)
        #expect(h.service.browse.tab == .library)
        #expect(h.nav.isBrowsing)
        #expect(h.nav.showsResults == false)
    }

    @Test("a tab pick while an artist opened from the results is open over pages clears the query, the hide and the pages")
    func selectOverArtistOpenedOverPages() async {
        let h = NavHarness()
        let artist = NavHarness.artist("UCa")
        h.openPage("PL1")
        h.openPage("PL2")
        await h.search("alpha", artists: [artist])
        h.nav.openArtist(artist)
        #expect(h.path == ["PL1", "PL2", "UCa"])

        h.nav.select(.library)

        #expect(h.service.query.isEmpty)
        #expect(h.nav.hidesResults == false)
        #expect(h.path.isEmpty)
        #expect(h.service.browse.tab == .library)
        #expect(h.nav.isBrowsing)
        #expect(h.nav.showsResults == false)
    }

    @Test("a tab pick over results that sit on pages clears the query and the pages")
    func selectOverResultsOverPages() async {
        let h = NavHarness()
        h.openPage("PL1")
        await h.search("alpha")
        #expect(h.nav.showsResults)

        h.nav.select(.home)

        #expect(h.service.query.isEmpty)
        #expect(h.nav.hidesResults == false)
        #expect(h.path.isEmpty)
        #expect(h.nav.isBrowsing)
    }

    @Test("Home from the switch over plain results clears the query, as before")
    func homeOverResults() async {
        let h = NavHarness()
        await h.search("alpha")
        h.nav.select(.home)
        #expect(h.service.query.isEmpty)
        #expect(h.nav.isBrowsing)
    }

    @Test("a tab pick while browsing closes the pages and leaves a blank query alone")
    func selectWhileBrowsing() {
        let h = NavHarness()
        h.openPage("PL1")
        h.openPage("PL2")
        h.nav.select(.library)
        #expect(h.path.isEmpty)
        #expect(h.service.browse.tab == .library)
        #expect(h.service.query.isEmpty)
    }

    @Test("a tab pick closes Up next and Lyrics")
    func selectClosesPanels() {
        let h = NavHarness()
        h.playSomething()
        h.loadLyricsTrack()
        h.nav.toggleQueue()
        h.nav.select(.home)
        #expect(h.nav.queueForced == false)
        #expect(h.service.lyrics.isPanelOpen == false)

        h.nav.toggleLyrics()
        #expect(h.service.lyrics.isPanelOpen)
        h.nav.select(.library)
        #expect(h.service.lyrics.isPanelOpen == false)
    }

    @Test("a stale hide does not keep the query once the artist page is closed and Home is picked")
    func staleHideThenHome() async {
        let h = NavHarness()
        let artist = NavHarness.artist("UCa")
        await h.search("alpha", artists: [artist])
        h.nav.openArtist(artist)
        h.service.browse.back()

        h.nav.select(.home)

        #expect(h.service.query.isEmpty)
        #expect(h.nav.hidesResults == false)
        #expect(h.nav.isBrowsing)
    }

    @Test("a sign-out clears the query and the hide, so a new session starts at browsing")
    func signOutClears() async {
        let h = NavHarness()
        let artist = NavHarness.artist("UCa")
        await h.search("alpha", artists: [artist])
        h.nav.openArtist(artist)

        h.service.signOut()
        h.nav.queryChanged()
        await h.service.signOutTask?.value

        #expect(h.service.query.isEmpty)
        #expect(h.nav.hidesResults == false)
        #expect(h.path.isEmpty)
        #expect(h.nav.isBrowsing)
    }

    @Test("a search that lands while the artist page is open updates the lists but not the screen")
    func searchLandingBehindThePage() async {
        let h = NavHarness()
        let artist = NavHarness.artist("UCa")
        let gate = MusicTestGate()
        await h.search("alpha", artists: [artist])
        await h.backend.setSearch("alpha", results: [MusicSamples.track("s2")])
        await h.backend.setSearchGate("alpha", gate)
        h.service.query = "alpha"
        h.service.search()
        #expect(h.service.isSearching)

        h.nav.openArtist(artist)
        await gate.open()
        await h.service.searchTask?.value

        #expect(h.service.results.map(\.videoId) == ["s2"])
        #expect(h.nav.showsResults == false)
        h.service.browse.back()
        #expect(h.nav.showsResults)
    }

    // MARK: - Opening an artist from everywhere else

    @Test("from Home an artist opens at the root of the path, and Back returns to Home")
    func openFromHome() {
        let h = NavHarness()
        let artist = NavHarness.artist("UCa")

        h.nav.openArtist(artist)

        #expect(h.path == ["UCa"])
        #expect(h.nav.hidesResults == false)
        #expect(h.nav.isBrowsing)
        h.service.browse.back()
        #expect(h.path.isEmpty)
        #expect(h.nav.isBrowsing)
    }

    @Test("from a page an artist opens on top and Back returns to that page")
    func openFromPage() {
        let h = NavHarness()
        h.openPage("PL1")
        h.openPage("PL2")

        h.nav.openArtist(NavHarness.artist("UCa"))

        #expect(h.path == ["PL1", "PL2", "UCa"])
        #expect(h.nav.hidesResults == false)
        h.service.browse.back()
        #expect(h.path == ["PL1", "PL2"])
    }

    @Test("from a page that was itself opened from the results the path grows and the results stay hidden")
    func openFromSearchOpenedPage() async {
        let h = NavHarness()
        let first = NavHarness.artist("UCa")
        await h.search("alpha", artists: [first])
        h.nav.openArtist(first)

        h.nav.openArtist(NavHarness.artist("UCb"))

        #expect(h.path == ["UCa", "UCb"])
        #expect(h.nav.showsResults == false)
        #expect(h.nav.hidesResults)
    }

    @Test("from Up next over browsing it closes the panel and opens on top of the current path")
    func openFromQueueWhileBrowsing() {
        let h = NavHarness()
        h.openPage("PL1")
        h.playSomething()
        h.nav.toggleQueue()
        #expect(h.nav.showsQueue)

        h.nav.openArtist(NavHarness.artist("UCa"))

        #expect(h.nav.queueForced == false)
        #expect(h.nav.showsQueue == false)
        #expect(h.path == ["PL1", "UCa"])
        #expect(h.nav.isBrowsing)
    }

    @Test("from Lyrics over browsing it closes the panel and opens on top of the current path")
    func openFromLyricsWhileBrowsing() {
        let h = NavHarness()
        h.openPage("PL1")
        h.loadLyricsTrack()
        h.nav.toggleLyrics()
        #expect(h.nav.showsLyrics)

        h.nav.openArtist(NavHarness.artist("UCa"))

        #expect(h.service.lyrics.isPanelOpen == false)
        #expect(h.nav.showsLyrics == false)
        #expect(h.path == ["PL1", "UCa"])
        #expect(h.nav.isBrowsing)
    }

    @Test("from Up next over search results it closes the panel, shows the artist and Back returns to the results")
    func openFromQueueOverResults() async {
        let h = NavHarness()
        await h.search("alpha")
        h.playSomething()
        h.nav.toggleQueue()
        #expect(h.nav.showsQueue)

        h.nav.openArtist(NavHarness.artist("UCa"))

        #expect(h.nav.showsQueue == false)
        #expect(h.nav.showsResults == false)
        #expect(h.nav.isBrowsing)
        #expect(h.path == ["UCa"])
        h.service.browse.back()
        #expect(h.nav.showsResults)
    }

    @Test("from Lyrics over search results it closes the panel, shows the artist and Back returns to the results")
    func openFromLyricsOverResults() async {
        let h = NavHarness()
        await h.search("alpha")
        h.loadLyricsTrack()
        h.nav.toggleLyrics()
        #expect(h.nav.showsLyrics)

        h.nav.openArtist(NavHarness.artist("UCa"))

        #expect(h.service.lyrics.isPanelOpen == false)
        #expect(h.nav.showsResults == false)
        #expect(h.nav.isBrowsing)
        #expect(h.path == ["UCa"])
        h.service.browse.back()
        #expect(h.nav.showsResults)
    }

    @Test("an artist link's opener is an artist with the link's name and no photo")
    func openFromALink() async {
        let h = NavHarness()
        await h.search("alpha")
        let link = MusicArtistLink(name: "Alpha", browseId: "UCa")

        h.nav.openArtist(link.opener)

        let opened = h.service.browse.path.last
        #expect(opened?.browseId == "UCa")
        #expect(opened?.kind == .artist)
        #expect(opened?.title == "Alpha")
        #expect(opened?.thumbnailURL == nil)
        #expect(h.nav.showsResults == false)
    }
}

@MainActor
@Suite("MusicSearchNavigation shell")
struct MusicSearchNavigationShellTests {
    @Test("Search keeps its query when it is picked again, and every other tab drops it")
    func searchTabKeepsTheQuery() async {
        let h = NavHarness()
        await h.search("alpha")
        h.nav.select(.search)
        #expect(h.service.query == "alpha")
        #expect(h.service.browse.tab == .search)
        #expect(h.nav.showsResults)

        h.nav.select(.home)
        #expect(h.service.query.isEmpty)
        #expect(h.service.browse.tab == .home)
    }

    @Test("Now Playing needs a loaded track to open")
    func openNowPlayingNeedsATrack() {
        let h = NavHarness()
        h.nav.openNowPlaying()
        #expect(h.nav.isNowPlayingOpen == false)
        #expect(h.nav.screen == .browse)

        h.playSomething()
        h.nav.openNowPlaying()
        #expect(h.nav.isNowPlayingOpen)
        #expect(h.nav.screen == .nowPlaying)
    }

    @Test("dismissing the player goes back to the browse screen and closes Up next and Lyrics")
    func dismissPlayer() {
        let h = NavHarness()
        h.playSomething()
        h.loadLyricsTrack()
        h.nav.openNowPlaying()
        h.nav.toggleLyrics()
        #expect(h.nav.screen == .lyrics)

        h.nav.dismissPlayer()
        #expect(h.nav.screen == .browse)
        #expect(h.nav.isNowPlayingOpen == false)
        #expect(h.service.lyrics.isPanelOpen == false)
        #expect(h.nav.queueForced == false)
    }

    @Test("turning Lyrics or Up next on opens the player, and Back from them leaves it")
    func panelsOpenThePlayer() {
        let h = NavHarness()
        h.playSomething()
        h.loadLyricsTrack()

        h.nav.toggleQueue()
        #expect(h.nav.isNowPlayingOpen)
        #expect(h.nav.screen == .queue)

        h.nav.toggleLyrics()
        #expect(h.nav.screen == .lyrics)
        #expect(h.nav.queueForced == false)

        h.nav.toggleLyrics()
        #expect(h.nav.screen == .nowPlaying)
    }

    @Test("opening an artist from the player leaves it for the page")
    func openCollectionDismissesThePlayer() {
        let h = NavHarness()
        h.playSomething()
        h.nav.openNowPlaying()

        h.nav.openArtist(NavHarness.artist("UCa"))

        #expect(h.nav.isNowPlayingOpen == false)
        #expect(h.nav.screen == .browse)
        #expect(h.path == ["UCa"])
    }

    @Test("a tab pick closes the player screens too")
    func selectClosesThePlayer() {
        let h = NavHarness()
        h.playSomething()
        h.nav.openNowPlaying()
        h.nav.select(.library)
        #expect(h.nav.screen == .browse)
        #expect(h.service.browse.tab == .library)
    }
}
