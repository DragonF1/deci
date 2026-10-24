// DeciTests/Music/MusicScopedSearchTests.swift
// Search phase 3, the scoped searches: an artist page searches that artist (Top songs, the full songs list and the
// shelves), Library adds a Songs block of Liked music above its filtered list, and History filters its loaded days.
// Everything is local: no test here may reach the search endpoints.

import Foundation
import Testing
@testable import Deci

@MainActor
private struct ScopedHarness {
    let backend = FakeMusicBackend()
    let service: MusicService
    let nav: MusicSearchNavigation

    static let likedId = MusicBrowseStore.likedMusic.browseId
    static let songsId = "VLartistsongs"

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
        nav = MusicSearchNavigation(service: service, searchDelay: .milliseconds(20))
    }

    var browse: MusicBrowseStore { service.browse }

    func type(_ text: String) {
        nav.fieldQuery = text
    }

    /// Polls until `condition` holds, for the loads that run on their own task.
    func until(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<400 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    func isLoaded(_ browseId: String) -> Bool {
        if case .loaded = browse.pageState(browseId) { return true }
        return false
    }

    func song(_ id: String, _ title: String, artist: String = "Aria") -> MusicTrack {
        MusicSamples.track(id, title: title, artist: artist)
    }

    func album(_ id: String, _ title: String) -> MusicCollection {
        MusicSamples.collection(id, kind: .album, title: title, subtitle: "Album \u{2022} Aria \u{2022} 2020")
    }

    /// Opens the artist page `UCa` with these Top songs and shelves, and waits for it.
    func openArtist(
        top: [MusicTrack] = [],
        shelves: [MusicShelf] = [],
        songsListId: String? = ScopedHarness.songsId
    ) async {
        await backend.setPage(MusicSamples.page(
            "UCa", tracks: top, title: "Aria", shelves: shelves, allSongsBrowseId: songsListId
        ))
        browse.open(MusicSamples.collection("UCa", kind: .artist, title: "Aria", subtitle: "Artist"))
        nav.reconcile()
        _ = await until { isLoaded("UCa") }
    }

    func setSongsList(_ tracks: [MusicTrack], continuation: String? = nil) async {
        await backend.setPage(MusicSamples.page(Self.songsId, tracks: tracks, continuation: continuation))
    }

    func setLiked(_ tracks: [MusicTrack]) async {
        await backend.setPage(MusicSamples.page(Self.likedId, tracks: tracks, title: "Liked music"))
    }

    /// Loads History with these days and waits for it, then opens its field.
    func openHistory(_ shelves: [MusicShelf], continuation: String? = nil) async {
        await backend.setHistory(shelves: shelves, continuation: continuation)
        nav.select(.history)
        _ = await until { if case .loaded = browse.history { true } else { false } }
        nav.openField()
    }

    func day(_ title: String, _ tracks: [MusicTrack]) -> MusicShelf {
        MusicShelf(title: title, items: tracks.map { .track($0) })
    }
}

// MARK: - Artist: the pure match

@MainActor
@Suite("MusicArtistSearch")
struct MusicArtistSearchTests {
    private func song(_ id: String, _ title: String) -> MusicTrack {
        MusicSamples.track(id, title: title, artist: "Aria")
    }

    private func album(_ id: String, _ title: String, kind: MusicCollection.Kind = .album) -> MusicCollection {
        MusicSamples.collection(id, kind: kind, title: title, subtitle: "Album \u{2022} Aria \u{2022} 2020")
    }

    private func artistPage(top: [MusicTrack], shelves: [MusicShelf] = []) -> MusicBrowsePage {
        MusicSamples.page("UCa", tracks: top, title: "Aria", shelves: shelves, allSongsBrowseId: "VLsongs")
    }

    @Test("songs are the Top songs that match, then the full list's, each song once, in that order")
    func songsOrderAndDedupe() {
        let page = artistPage(top: [song("t1", "Love Story"), song("t2", "Other"), song("t3", "Lovely")])
        let list = MusicSamples.page("VLsongs", tracks: [
            song("l1", "Love Me"), song("t3", "Lovely"), song("l2", "Nothing"), song("t1", "Love Story"), song("l3", "Beloved"),
        ])
        let result = MusicArtistSearch.resolve(page: page, songsPage: list, terms: ["love"])
        #expect(result.songs.map(\.videoId) == ["t1", "t3", "l1", "l3"])
    }

    @Test("without the full list loaded yet only the Top songs are searched")
    func songsWithoutTheList() {
        let page = artistPage(top: [song("t1", "Love Story"), song("t2", "Other")])
        let result = MusicArtistSearch.resolve(page: page, songsPage: nil, terms: ["story"])
        #expect(result.songs.map(\.videoId) == ["t1"])
    }

    @Test("collections are the albums and playlists of every shelf that match, each once")
    func collectionsFromEveryShelf() {
        let shelves = [
            MusicShelf(title: "Albums", items: [.collection(album("a1", "Blue Hour")), .collection(album("a2", "Red"))]),
            MusicShelf(title: "Singles", items: [.collection(album("a3", "Blue Single")), .collection(album("a1", "Blue Hour"))]),
            MusicShelf(title: "Featured on", items: [
                .collection(MusicSamples.collection("VLp1", kind: .playlist, title: "Deep Blue", subtitle: "Playlist \u{2022} Sam")),
            ]),
        ]
        let page = artistPage(top: [], shelves: shelves)
        let result = MusicArtistSearch.resolve(page: page, songsPage: nil, terms: ["blue"])
        #expect(result.collections.map(\.browseId) == ["a1", "a3", "VLp1"])
    }

    @Test("related artists are not albums or playlists: they are left out")
    func relatedArtistsLeftOut() {
        let shelves = [
            MusicShelf(title: "Fans might also like", items: [.collection(album("UCb", "Aria Fan", kind: .artist))]),
        ]
        let result = MusicArtistSearch.resolve(page: artistPage(top: [], shelves: shelves), songsPage: nil, terms: ["aria"])
        #expect(result.collections.isEmpty)
    }

    @Test("every word has to match, in the title, the artist line or the album")
    func everyWord() {
        let page = artistPage(top: [song("t1", "Love Story"), song("t2", "Love Song")])
        #expect(MusicArtistSearch.resolve(page: page, songsPage: nil, terms: ["love", "song"]).songs.map(\.videoId) == ["t2"])
        #expect(MusicArtistSearch.resolve(page: page, songsPage: nil, terms: ["LOVE", "aria"]).songs.count == 2)
    }

    @Test("nothing matching is empty, and so is a page with nothing on it")
    func empty() {
        let page = artistPage(top: [song("t1", "Love Story")])
        #expect(MusicArtistSearch.resolve(page: page, songsPage: nil, terms: ["zzz"]).isEmpty)
        #expect(MusicArtistSearch.resolve(page: artistPage(top: []), songsPage: nil, terms: ["a"]).isEmpty)
        #expect(MusicArtistSearch.resolve(page: page, songsPage: nil, terms: ["love"]).isEmpty == false)
    }

    @Test("a song of the Top songs plays in the artist page, one only the full list holds plays in that list")
    func playPage() {
        let page = artistPage(top: [song("t1", "Love Story")])
        let list = MusicSamples.page("VLsongs", tracks: [song("l1", "Love Me")])
        let result = MusicArtistSearch.resolve(page: page, songsPage: list, terms: ["love"])
        #expect(result.playPage(for: song("t1", "Love Story")).browseId == "UCa")
        #expect(result.playPage(for: song("l1", "Love Me")).browseId == "VLsongs")
    }
}

// MARK: - Library: the pure match

@MainActor
@Suite("MusicLikedSongs")
struct MusicLikedSongsTests {
    private func page(_ titles: [String]) -> MusicBrowsePage {
        MusicSamples.page(
            "VLLM",
            tracks: titles.enumerated().map { MusicSamples.track("v\($0.offset)", title: $0.element) },
            title: "Liked music"
        )
    }

    @Test("up to five matches show, in the playlist's order, and the count is of all of them")
    func cap() {
        let titles = (1...8).map { "Night \($0)" } + ["Day"]
        let liked = MusicLikedSongs.resolve(page: page(titles), terms: ["night"])
        #expect(liked.songs.count == 5)
        #expect(liked.songs.map(\.title) == ["Night 1", "Night 2", "Night 3", "Night 4", "Night 5"])
        #expect(liked.matched == 8)
        #expect(liked.showAllTitle == "Show all 8 songs")
        #expect(liked.isEmpty == false)
    }

    @Test("five or fewer matches have no Show all link")
    func noLinkAtFive() {
        let five = MusicLikedSongs.resolve(page: page((1...5).map { "Night \($0)" }), terms: ["night"])
        #expect(five.songs.count == 5)
        #expect(five.showAllTitle == nil)
        let one = MusicLikedSongs.resolve(page: page(["Night", "Day"]), terms: ["night"])
        #expect(one.songs.count == 1)
        #expect(one.showAllTitle == nil)
    }

    @Test("a page that is not loaded, or nothing that matches, is empty")
    func empty() {
        #expect(MusicLikedSongs.resolve(page: nil, terms: ["night"]).isEmpty)
        #expect(MusicLikedSongs.resolve(page: page(["Day"]), terms: ["night"]).isEmpty)
        #expect(MusicLikedSongs.resolve(page: page([]), terms: ["night"]).showAllTitle == nil)
    }

    @Test("the link counts a hundred matches, not the five shown")
    func largeCount() {
        let liked = MusicLikedSongs.resolve(page: page((1...100).map { "Night \($0)" }), terms: ["night"])
        #expect(liked.songs.count == 5)
        #expect(liked.showAllTitle == "Show all 100 songs")
    }
}

// MARK: - History: the pure filter

@MainActor
@Suite("MusicHistoryFilter")
struct MusicHistoryFilterTests {
    private func shelf(_ title: String, _ titles: [String], prefix: String) -> MusicShelf {
        MusicShelf(
            title: title,
            items: titles.enumerated().map { .track(MusicSamples.track("\(prefix)\($0.offset)", title: $0.element)) }
        )
    }

    private var days: [MusicShelf] {
        [
            shelf("Today", ["Blue Monday", "Red", "Blue Moon"], prefix: "a"),
            shelf("Yesterday", ["Green", "Yellow"], prefix: "b"),
            shelf("This week", ["Blue Sky", "Gray", "Pink", "Black"], prefix: "c"),
        ]
    }

    @Test("items that do not match are hidden, and a day left with none is hidden too")
    func hidesItemsAndDays() {
        let filter = MusicHistoryFilter.resolve(shelves: days, terms: ["blue"], isPartial: false)
        #expect(filter.shelves.map(\.title) == ["Today", "This week"])
        #expect(filter.shelves[0].items.count == 2)
        #expect(filter.shelves[1].items.count == 1)
        #expect(filter.isEmpty == false)
    }

    @Test("the count line is the songs that match of the songs loaded")
    func countLine() {
        let filter = MusicHistoryFilter.resolve(shelves: days, terms: ["blue"], isPartial: false)
        #expect(filter.matched == 3)
        #expect(filter.total == 9)
        #expect(filter.countLine == "3 OF 9 SONGS")
    }

    @Test("a history with more days to load says the count is of what is loaded")
    func partialCount() {
        let filter = MusicHistoryFilter.resolve(shelves: days, terms: ["blue"], isPartial: true)
        #expect(filter.countLine == "3 OF 9 SONGS LOADED")
    }

    @Test("a collection in a day is matched like a song")
    func collectionsMatch() {
        let mixed = MusicShelf(title: "Today", items: [
            .track(MusicSamples.track("a", title: "Blue")),
            .collection(MusicSamples.collection("VLx", kind: .playlist, title: "Blue Mix", subtitle: "Playlist \u{2022} Sam")),
            .collection(MusicSamples.collection("VLy", kind: .playlist, title: "Red Mix", subtitle: "Playlist \u{2022} Sam")),
        ])
        let filter = MusicHistoryFilter.resolve(shelves: [mixed], terms: ["blue"], isPartial: false)
        #expect(filter.shelves.first?.items.count == 2)
        #expect(filter.matched == 1)
    }

    @Test("nothing matching leaves no days and an empty filter")
    func empty() {
        let filter = MusicHistoryFilter.resolve(shelves: days, terms: ["zzz"], isPartial: false)
        #expect(filter.shelves.isEmpty)
        #expect(filter.isEmpty)
        #expect(filter.matched == 0)
        #expect(filter.countLine == "0 OF 9 SONGS")
        #expect(MusicHistoryFilter.resolve(shelves: [], terms: ["a"], isPartial: false).isEmpty)
    }

    @Test("every word has to match, and the kind of search ignores case and accents")
    func wordsAndAccents() {
        let shelves = [shelf("Today", ["Caf\u{00E9} Blue", "Cafe Red"], prefix: "a")]
        #expect(MusicHistoryFilter.resolve(shelves: shelves, terms: ["cafe", "BLUE"], isPartial: false).matched == 1)
    }
}

// MARK: - Navigation: artist

@MainActor
@Suite("MusicSearchNavigation artist scope")
struct MusicSearchArtistScopeTests {
    @Test("the results come from the Top songs, the shelves and the full list once it is here")
    func resultsFromThePage() async {
        let h = ScopedHarness()
        await h.setSongsList([h.song("l1", "Love Me"), h.song("l2", "Nothing")])
        await h.openArtist(
            top: [h.song("t1", "Love Story"), h.song("t2", "Other")],
            shelves: [MusicShelf(title: "Albums", items: [.collection(h.album("a1", "Love Notes")), .collection(h.album("a2", "Red"))])]
        )
        h.nav.openField()
        #expect(h.nav.artistSearch == nil)

        h.type("love")
        let first = h.nav.artistSearch
        #expect(first?.songs.map(\.videoId) == ["t1"])
        #expect(first?.collections.map(\.browseId) == ["a1"])

        #expect(await h.until { h.isLoaded(ScopedHarness.songsId) })
        #expect(h.nav.artistSearch?.songs.map(\.videoId) == ["t1", "l1"])
    }

    @Test("the first words start the full songs list, once, and later words and a cleared field do not ask again")
    func loadsTheListOnce() async {
        let h = ScopedHarness()
        await h.setSongsList([h.song("l1", "Love Me")])
        await h.openArtist(top: [h.song("t1", "Love Story")])
        h.nav.openField()

        h.type("   ")
        #expect(h.browse.pageState(ScopedHarness.songsId) == .idle)

        h.type("l")
        #expect(h.browse.pageState(ScopedHarness.songsId) == .loading)
        h.type("lo")
        h.type("lov")
        #expect(await h.until { h.isLoaded(ScopedHarness.songsId) })
        h.nav.clearField()
        h.type("love")
        h.type("love me")
        #expect(await h.backend.pageCalls == ["UCa", ScopedHarness.songsId])
    }

    @Test("results grow live while the list is still arriving")
    func updatesWhenTheListLands() async {
        let h = ScopedHarness()
        let gate = MusicTestGate()
        await h.backend.setPageGate(ScopedHarness.songsId, gate)
        await h.setSongsList([h.song("l1", "Love Me"), h.song("l2", "Lovely")])
        await h.openArtist(top: [h.song("t1", "Love Story")])
        h.nav.openField()
        h.type("love")
        #expect(h.nav.artistSearch?.songs.map(\.videoId) == ["t1"])

        await gate.open()
        #expect(await h.until { h.isLoaded(ScopedHarness.songsId) })
        #expect(h.nav.artistSearch?.songs.map(\.videoId) == ["t1", "l1", "l2"])
    }

    @Test("words typed before the artist page lands start the list when it does")
    func listStartsWhenThePageLands() async {
        let h = ScopedHarness()
        let gate = MusicTestGate()
        await h.backend.setPageGate("UCa", gate)
        await h.backend.setPage(MusicSamples.page("UCa", tracks: [h.song("t1", "Love Story")], title: "Aria", allSongsBrowseId: ScopedHarness.songsId))
        await h.setSongsList([h.song("l1", "Love Me")])
        h.browse.open(MusicSamples.collection("UCa", kind: .artist, title: "Aria", subtitle: "Artist"))
        h.nav.reconcile()
        h.nav.openField()
        h.type("love")
        #expect(h.nav.artistSearch == nil)
        #expect(h.nav.scopedLoadTarget == nil)

        await gate.open()
        #expect(await h.until { h.isLoaded("UCa") })
        #expect(h.nav.scopedLoadTarget == ScopedHarness.songsId)
        h.nav.startScopedLoad()
        #expect(await h.until { h.isLoaded(ScopedHarness.songsId) })
        #expect(h.nav.artistSearch?.songs.map(\.videoId) == ["t1", "l1"])
    }

    @Test("an artist page that names no songs list asks for none")
    func noList() async {
        let h = ScopedHarness()
        await h.openArtist(top: [h.song("t1", "Love Story")], songsListId: nil)
        h.nav.openField()
        h.type("love")
        #expect(h.nav.scopedLoadTarget == nil)
        #expect(h.nav.artistSearch?.songs.map(\.videoId) == ["t1"])
        #expect(await h.backend.pageCalls == ["UCa"])
    }

    @Test("a search on the artist page never reaches the search endpoints or the service's query")
    func noBackendSearch() async {
        let h = ScopedHarness()
        await h.openArtist(top: [h.song("t1", "Love Story")])
        h.nav.openField()
        h.type("love")
        h.type("love story")
        try? await Task.sleep(for: .milliseconds(80))
        #expect(await h.backend.searchedQueries.isEmpty)
        #expect(await h.backend.searchedArtistQueries.isEmpty)
        #expect(await h.backend.searchedAlbumsQueries.isEmpty)
        #expect(await h.backend.searchedTopResultQueries.isEmpty)
        #expect(h.service.query.isEmpty)
        #expect(h.nav.isSearchPending == false)
        #expect(h.nav.showsSearchPanel == false)
    }

    @Test("the results are for the artist page the field was opened on, and fold away with it")
    func belongsToThePage() async {
        let h = ScopedHarness()
        await h.openArtist(top: [h.song("t1", "Love Story")])
        #expect(h.nav.artistSearch == nil)
        h.nav.openField()
        h.type("love")
        #expect(h.nav.artistSearch != nil)

        h.nav.select(.library)
        #expect(h.nav.artistSearch == nil)
        #expect(h.nav.filterQuery.isEmpty)
    }

    @Test("nothing found keeps the page's answer empty, and the link sends the words to YouTube Music")
    func nothingFoundAndInstead() async {
        let h = ScopedHarness()
        await h.openArtist(top: [h.song("t1", "Love Story")])
        h.nav.openField()
        h.type("zzz")
        #expect(h.nav.artistSearch?.isEmpty == true)

        h.nav.searchYouTubeMusicInstead()
        await h.service.searchTask?.value
        #expect(h.service.browse.tab == .home)
        #expect(h.service.query == "zzz")
        #expect(await h.backend.searchedQueries == ["zzz"])
    }

    @Test("Return in the artist field does nothing extra: no search goes out")
    func returnIsNothing() async {
        let h = ScopedHarness()
        await h.openArtist(top: [h.song("t1", "Love Story")])
        h.nav.openField()
        h.type("love")
        #expect(h.nav.scope == .artist)
        #expect(h.nav.scope.isLocal)
        #expect(await h.backend.searchedQueries.isEmpty)
    }
}

// MARK: - Navigation: Library songs

@MainActor
@Suite("MusicSearchNavigation library songs")
struct MusicSearchLibrarySongsTests {
    private func likedTitles(_ count: Int, word: String = "Night") -> [String] {
        (1...count).map { "\(word) \($0)" }
    }

    private func liked(_ h: ScopedHarness, _ titles: [String]) async {
        await h.setLiked(titles.enumerated().map { h.song("v\($0.offset)", $0.element) })
    }

    @Test("the first words start Liked music, once, and blank words and more typing do not ask again")
    func loadsLikedOnce() async {
        let h = ScopedHarness()
        await liked(h, ["Night Drive"])
        h.nav.select(.library)
        h.nav.openField()

        h.type("  ")
        #expect(h.browse.pageState(ScopedHarness.likedId) == .idle)

        h.type("n")
        #expect(h.browse.pageState(ScopedHarness.likedId) == .loading)
        h.type("ni")
        h.type("night")
        #expect(await h.until { h.isLoaded(ScopedHarness.likedId) })
        h.nav.clearField()
        h.type("night drive")
        #expect(await h.backend.pageCalls == [ScopedHarness.likedId])
        #expect(await h.backend.searchedQueries.isEmpty)
    }

    @Test("the Songs block is up to five matches of Liked music, and counts all of them")
    func songsBlock() async {
        let h = ScopedHarness()
        await liked(h, likedTitles(7) + ["Day"])
        h.nav.select(.library)
        h.nav.openField()
        h.type("night")
        #expect(h.nav.likedSongs?.songs.isEmpty == true)

        #expect(await h.until { h.isLoaded(ScopedHarness.likedId) })
        #expect(h.nav.likedSongs?.songs.count == 5)
        #expect(h.nav.likedSongs?.matched == 7)
        #expect(h.nav.likedSongs?.showAllTitle == "Show all 7 songs")
    }

    @Test("the Songs block exists only while the Library filter has words")
    func onlyWithWords() async {
        let h = ScopedHarness()
        await liked(h, ["Night Drive"])
        h.nav.select(.library)
        #expect(h.nav.likedSongs == nil)
        h.nav.openField()
        #expect(h.nav.likedSongs == nil)
        h.type("night")
        #expect(await h.until { h.isLoaded(ScopedHarness.likedId) })
        #expect(h.nav.likedSongs?.songs.count == 1)
        h.nav.clearField()
        #expect(h.nav.likedSongs == nil)
    }

    @Test("no results shows only when neither the songs nor the segment match")
    func noResultsNeedsBothEmpty() async {
        let h = ScopedHarness()
        await liked(h, ["Night Drive"])
        h.nav.select(.library)
        h.nav.openField()
        let loaded = [MusicLibrarySection.playlists: [MusicSamples.collection("p1", title: "Focus", subtitle: "Playlist \u{2022} Sam")]]
        let nothing = MusicLibraryFilter.resolve(section: .playlists, loaded: loaded, hasMore: [], terms: ["night"])
        #expect(nothing.isEmpty)

        h.type("night")
        // Liked music is still on its way: an empty answer is not final yet.
        #expect(h.nav.isScopedLoadPending)
        #expect(h.nav.libraryHasNoMatch(nothing) == false)
        #expect(await h.until { h.isLoaded(ScopedHarness.likedId) })
        #expect(h.nav.isScopedLoadPending == false)
        // The segment has nothing, the songs do: not empty.
        #expect(h.nav.libraryHasNoMatch(nothing) == false)

        // Neither has anything.
        h.type("zzz")
        let none = MusicLibraryFilter.resolve(section: .playlists, loaded: loaded, hasMore: [], terms: ["zzz"])
        #expect(h.nav.libraryHasNoMatch(none))

        // The segment has a row, the songs do not: not empty either.
        h.type("focus")
        let some = MusicLibraryFilter.resolve(section: .playlists, loaded: loaded, hasMore: [], terms: ["focus"])
        #expect(some.isEmpty == false)
        #expect(h.nav.libraryHasNoMatch(some) == false)
    }

    @Test("Show all opens Liked music with the words as its filter, field open")
    func showAll() async {
        let h = ScopedHarness()
        await liked(h, likedTitles(7))
        h.nav.select(.library)
        h.nav.openField()
        h.type("night")
        #expect(await h.until { h.isLoaded(ScopedHarness.likedId) })

        h.nav.showAllLikedSongs()
        h.nav.reconcile()

        #expect(h.service.browse.path.map(\.browseId) == [ScopedHarness.likedId])
        #expect(h.nav.scope == .playlist)
        #expect(h.nav.isFieldOpen)
        #expect(h.nav.fieldQuery == "night")
        #expect(h.nav.browseFilterTerms == ["night"])
        // The page was loaded for the search: opening it asks for nothing more.
        #expect(await h.backend.pageCalls == [ScopedHarness.likedId])
    }

    @Test("the filter of the current segment is untouched: its words, terms and the link to YouTube Music")
    func segmentFilterStays() async {
        let h = ScopedHarness()
        await liked(h, ["Night Drive"])
        h.nav.select(.library)
        h.nav.openField()
        h.type("night")
        #expect(h.nav.scope == .library)
        #expect(h.nav.browseFilterTerms == ["night"])
        #expect(h.nav.filterQuery == "night")
        #expect(h.nav.showsSearchPanel == false)
    }
}

// MARK: - Navigation: History

@MainActor
@Suite("MusicSearchNavigation history scope")
struct MusicSearchHistoryScopeTests {
    private func days(_ h: ScopedHarness) -> [MusicShelf] {
        [
            h.day("Today", [h.song("a1", "Blue Monday"), h.song("a2", "Red")]),
            h.day("Yesterday", [h.song("b1", "Green")]),
            h.day("This week", [h.song("c1", "Blue Sky"), h.song("c2", "Pink")]),
        ]
    }

    @Test("the filter shows the matching songs, hides the days left empty and counts what matched")
    func filtersTheDays() async {
        let h = ScopedHarness()
        await h.openHistory(days(h))
        #expect(h.nav.historyFilter == nil)

        h.type("blue")
        let filter = h.nav.historyFilter
        #expect(filter?.shelves.map(\.title) == ["Today", "This week"])
        #expect(filter?.countLine == "2 OF 5 SONGS")
        #expect(MusicHistoryView.days(in: filter?.shelves ?? []).map { $0.tracks.map(\.videoId) } == [["a1"], ["c1"]])
    }

    @Test("it filters on every keystroke and sends nothing, however long it waits")
    func noNetwork() async {
        let h = ScopedHarness()
        await h.openHistory(days(h))
        let historyCalls = await h.backend.historyCallCount

        h.type("b")
        #expect(h.nav.historyFilter?.matched == 2)
        h.type("bl")
        h.type("blue")
        h.type("blue s")
        #expect(h.nav.historyFilter?.matched == 1)
        try? await Task.sleep(for: .milliseconds(80))

        #expect(h.nav.isSearchPending == false)
        #expect(h.service.query.isEmpty)
        #expect(await h.backend.searchedQueries.isEmpty)
        #expect(await h.backend.historyCallCount == historyCalls)
        #expect(await h.backend.moreHistoryCalls.isEmpty)
        #expect(await h.backend.pageCalls.isEmpty)
    }

    @Test("nothing found leaves an empty filter, and the link sends the words to YouTube Music")
    func nothingFound() async {
        let h = ScopedHarness()
        await h.openHistory(days(h))
        h.type("zzz")
        #expect(h.nav.historyFilter?.isEmpty == true)
        #expect(h.nav.historyFilter?.countLine == "0 OF 5 SONGS")

        h.nav.searchYouTubeMusicInstead()
        await h.service.searchTask?.value
        #expect(h.service.browse.tab == .home)
        #expect(await h.backend.searchedQueries == ["zzz"])
    }

    @Test("a history with more days to load says so in the count")
    func partial() async {
        let h = ScopedHarness()
        await h.openHistory(days(h), continuation: "more")
        h.type("blue")
        #expect(h.nav.historyFilter?.countLine == "2 OF 5 SONGS LOADED")
    }

    @Test("clearing the words, Esc and leaving the tab give the whole history back")
    func clearingShowsEverything() async {
        let h = ScopedHarness()
        await h.openHistory(days(h))
        h.type("blue")
        #expect(h.nav.historyFilter != nil)

        h.nav.clearField()
        #expect(h.nav.historyFilter == nil)
        h.type("blue")
        #expect(h.nav.escape())
        #expect(h.nav.historyFilter == nil)
        h.type("blue")
        h.nav.select(.home)
        #expect(h.nav.historyFilter == nil)
        #expect(h.nav.filterQuery.isEmpty)
    }

    @Test("there is no filter until History has loaded")
    func needsTheList() {
        let h = ScopedHarness()
        h.nav.select(.history)
        h.nav.openField()
        h.type("blue")
        #expect(h.nav.historyFilter == nil)
    }
}

// MARK: - Copy

@Suite("MusicSearchCopy scoped")
struct MusicScopedCopyTests {
    @Test("the Show all link counts the songs")
    func showAll() {
        #expect(MusicSearchCopy.showAllSongs(count: 12) == "Show all 12 songs")
        #expect(MusicSearchCopy.showAllSongs(count: 6) == "Show all 6 songs")
    }
}
