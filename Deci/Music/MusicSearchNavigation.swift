// Deci/Music/MusicSearchNavigation.swift
import Foundation
import Observation

/// What the search results cover the right column with while the global field has words in it. Kept apart from the view
/// so each combination is tested.
nonisolated enum MusicSearchPanel: Equatable {
    /// Nothing typed: no results to show, the screen under the field stays.
    case invite
    /// Typed but not sent yet: Return runs the search.
    case pressReturn
    /// A search is running and has nothing to show yet.
    case searching
    /// The search came back with no songs, albums or artists.
    case noResults
    /// The search failed.
    case failed
    /// Songs, albums and artists to list.
    case results

    static func resolve(
        queryIsEmpty: Bool,
        showsResults: Bool,
        hasResults: Bool,
        isSearching: Bool,
        hasFailed: Bool
    ) -> MusicSearchPanel {
        guard showsResults else { return queryIsEmpty ? .invite : .pressReturn }
        if hasResults { return .results }
        if isSearching { return .searching }
        return hasFailed ? .failed : .noResults
    }

    /// What a card of this panel says; nil for the results, which are a list.
    var message: String? {
        switch self {
        case .invite: "Search YouTube Music for songs, albums and artists."
        case .pressReturn: "Press Return to search."
        case .searching: "Searching..."
        case .noResults: "No songs, albums or artists found."
        case .failed: "Search failed. Press Return to try again."
        case .results: nil
        }
    }
}

/// The blocks the global results are made of, in the order they are listed.
nonisolated enum MusicSearchSection: Equatable {
    case songs
    case albums
    case artists
}

/// Where the browse column is: a tab, how many pages are open on it and the one on top. A search field is opened at one
/// anchor and only counts while the column is still there.
struct MusicSearchAnchor: Equatable {
    let tab: MusicBrowseStore.Tab
    let depth: Int
    let pageId: String?
}

/// What the Music popup's right column shows (Home, Library and History, search results, Up next, Lyrics, Related, the
/// add-to-playlist picker), and the one way every artist, album name or tile opens its page, and every "..." menu
/// action runs. It lives here, not in the view, so the rules can be tested. One instance belongs to each
/// `MusicService` (`MusicServiceHost` makes it): the Music popup unmounts the player's view when the icon is hidden and
/// builds it again, and the view takes this one back, so what was open is still open.
@MainActor
@Observable
final class MusicSearchNavigation {
    /// The Up next button shows the queue in the right column in place of whatever is on screen.
    var queueForced = false
    /// The query last sent with Return, so a search that found nothing still shows its result.
    private(set) var submittedQuery: String?
    /// An artist opened from the results is on screen: the results step aside, keeping the query, and come back
    /// when the path is back at `resultsDepth` (Back). Only counts while the path is deeper than that, so a stale
    /// flag does nothing.
    private(set) var hidesResults = false
    /// How many pages were open under the results when an artist was opened from them. The results sit on those
    /// pages, so Back from the artist returns to the results, and clearing the query leaves the pages as they were.
    @ObservationIgnored private var resultsDepth = 0

    /// Where the YouTube Music field (Home, an artist page) was opened; nil while it is closed. A field belongs to the
    /// place it was opened on: it folds away, query and all, when the column is anywhere else, except while its
    /// results wait under a page opened from them.
    private(set) var searchAnchor: MusicSearchAnchor?
    /// Where the filter field of a Library tab, a playlist or an album was opened, and its words. Always dropped
    /// when the column moves on.
    private(set) var filterAnchor: MusicSearchAnchor?
    private(set) var filterQuery = ""
    /// The Up next field and its words. It closes with the queue.
    private(set) var isQueueFieldOpen = false
    private(set) var queueQuery = ""

    /// Words were typed in the YouTube Music field and their search is waiting out the delay after the last keystroke.
    private(set) var isSearchPending = false
    @ObservationIgnored private var pendingSearch: Task<Void, Never>?
    /// How long after the last keystroke the typed words are searched.
    @ObservationIgnored private let searchDelay: Duration
    /// The trimmed words of the search last sent, by Return or by typing. Typing the same words again sends nothing.
    @ObservationIgnored private var lastSearchedQuery = ""
    /// The pages `startScopedLoad` asked for since the filter got its words. They were never opened, so nothing closes
    /// them: they are dropped when the filter empties or closes, and the next one fetches them fresh.
    @ObservationIgnored private var scopedLoads: Set<String> = []

    @ObservationIgnored private let service: MusicService
    /// Where a menu pick's rating outcome shows: the notice line while the Music popup is open, else the HUD, as for the
    /// hotkeys. The host sets it. Not held: the reporter holds the host, which holds this. Without one the outcome shows
    /// on the notice line.
    @ObservationIgnored weak var outcomes: (any MusicOutcomeReporting)?

    init(service: MusicService, searchDelay: Duration = .milliseconds(300)) {
        self.service = service
        self.searchDelay = searchDelay
    }

    // MARK: - What shows

    private var trimmedQuery: String {
        service.query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The queue shows only when the Up next button asks for it.
    var showsQueue: Bool {
        !service.queue.isEmpty && queueForced
    }

    /// The lyrics panel is open for the loaded track. The store owns the flag (it also gates the fetch), and
    /// Up next and Lyrics are never both on: turning one on turns the other off.
    var showsLyrics: Bool {
        service.lyrics.isPanelOpen && service.lyrics.track != nil
    }

    /// What the results list, top to bottom: the songs (the Top result first), the albums (the owner's first), then the
    /// artists. A block with nothing in it is left out.
    var sections: [MusicSearchSection] {
        var sections: [MusicSearchSection] = []
        if !service.results.isEmpty { sections.append(.songs) }
        if !service.albumResults.isEmpty { sections.append(.albums) }
        if !service.artistResults.isEmpty { sections.append(.artists) }
        return sections
    }

    /// The search found songs, albums or artists.
    var hasResults: Bool {
        !sections.isEmpty
    }

    /// Search results show while there is a query and a search for it is running, has results, or came back
    /// empty, unless an artist opened from them is on screen. Otherwise the tab or an open page shows.
    /// This says nothing about Up next or Lyrics, which sit on top of whichever of the two is under them.
    var showsResults: Bool {
        guard !trimmedQuery.isEmpty, !isHidingResults else { return false }
        return service.isSearching || hasResults || submittedQuery == trimmedQuery
    }

    /// The Related panel is open: its store is for something, the playing song or a seed a menu pinned. The store is
    /// the only record of that, so a sign-out that resets it closes the panel with nothing left to clear. Up next,
    /// Lyrics and Related are never two at once: turning one on turns the others off.
    var showsRelated: Bool {
        service.related.state != .idle
    }

    /// The save to playlist menu is open. The store owns it; it floats over the popup and leaves the column as it was.
    var showsPicker: Bool {
        service.trackActions.picker != nil
    }

    var isBrowsing: Bool {
        !showsQueue && !showsResults && !showsLyrics && !showsRelated
    }

    /// Home's root is on screen with nothing over it, so the header offers the refresh button.
    var showsHomeRefresh: Bool {
        isBrowsing && service.browse.tab == .home && service.browse.path.isEmpty
    }

    /// What fills the right column: browse, or Lyrics, Up next or Related in place of it.
    var rightColumn: MusicRightColumn {
        MusicRightColumn.resolve(showsLyrics: showsLyrics, showsQueue: showsQueue, showsRelated: showsRelated)
    }

    /// The header tab to highlight: the tab on screen, whether its root or a page opened from it.
    var headerTab: MusicHeaderTab {
        MusicHeaderTab.resolve(tab: service.browse.tab)
    }

    private var isHidingResults: Bool {
        hidesResults && service.browse.path.count > resultsDepth
    }

    /// What the results cover the column with.
    var panel: MusicSearchPanel {
        let panel = MusicSearchPanel.resolve(
            queryIsEmpty: trimmedQuery.isEmpty,
            showsResults: showsResults,
            hasResults: hasResults,
            isSearching: service.isSearching,
            hasFailed: service.lastError != nil
        )
        // Words that are about to be searched on their own do not ask for Return, nor show an answer to older words.
        switch panel {
        case .pressReturn, .noResults, .failed: return isSearchPending ? .searching : panel
        case .invite, .searching, .results: return panel
        }
    }

    // MARK: - Search field

    /// Where the browse column is now: the tab, how many pages are open and the one on top. The Library segment is not
    /// part of it, so a filter keeps its words from Playlists to Albums.
    var currentAnchor: MusicSearchAnchor {
        let path = service.browse.path
        return MusicSearchAnchor(tab: service.browse.tab, depth: path.count, pageId: path.last?.browseId)
    }

    private var pageKind: MusicPageKind? {
        service.browse.path.last.map { MusicPageKind.resolve(kind: $0.kind, browseId: $0.browseId) }
    }

    /// What a field on the browse screens searches, whatever covers the column.
    private var browseScope: MusicSearchScope {
        MusicSearchScope.resolve(column: .browse, tab: service.browse.tab, page: pageKind)
    }

    /// What the field of the screen on top searches. `.none` where there is no field to open (Lyrics, Related).
    var scope: MusicSearchScope {
        MusicSearchScope.resolve(column: rightColumn, tab: service.browse.tab, page: pageKind)
    }

    /// The field is open on the screen on top.
    var isFieldOpen: Bool {
        switch rightColumn {
        case .queue: isQueueFieldOpen
        case .browse: (browseScope.isLocal ? filterAnchor : searchAnchor) == currentAnchor
        case .lyrics, .related: false
        }
    }

    /// The words in the field. Typing into a YouTube Music field is the service's own query, which Return sends.
    var fieldQuery: String {
        get {
            switch scope {
            case .global: service.query
            case .library, .playlist, .album, .artist, .history: filterQuery
            case .queue: queueQuery
            case .none: ""
            }
        }
        set {
            switch scope {
            case .global: service.query = newValue
            case .library, .playlist, .album, .artist, .history:
                filterQuery = newValue
                startScopedLoad()
            case .queue: queueQuery = newValue
            case .none: break
            }
        }
    }

    /// The words Library, a playlist or an album is filtered by right now; none while its field is closed or elsewhere.
    var browseFilterTerms: [String] {
        guard browseScope.isLocal, filterAnchor == currentAnchor else { return [] }
        return MusicLocalSearch.terms(of: filterQuery)
    }

    // MARK: - Scoped searches

    /// The page a scoped search needs and has not asked for: Liked music for the Library filter, the artist's full songs
    /// list for the artist field. Nil while the field has no words, while the artist page is still loading, or when the
    /// screen asks for nothing more.
    var scopedLoadTarget: String? {
        guard !browseFilterTerms.isEmpty else { return nil }
        switch browseScope {
        case .library:
            return MusicBrowseStore.likedMusic.browseId
        case .artist:
            guard let artist = service.browse.path.last,
                  case .loaded(let page) = service.browse.pageState(artist.browseId) else { return nil }
            return page.allSongsBrowseId
        case .global, .playlist, .album, .history, .queue, .none:
            return nil
        }
    }

    /// Asks for the page of `scopedLoadTarget` through the store's own loader, once: a page that is loading, loaded or
    /// failed is left alone until the filter empties or closes, which drops it, so a failed page is asked for again at
    /// the next start. Run on every edit and when the artist page lands.
    func startScopedLoad() {
        guard !browseFilterTerms.isEmpty else { return endScopedLoads() }
        guard let target = scopedLoadTarget, service.browse.pageState(target) == .idle else { return }
        scopedLoads.insert(target)
        service.browse.reloadPage(target)
    }

    /// The filter emptied or closed: the pages it asked for are dropped, except one that is open on the path.
    private func endScopedLoads() {
        guard !scopedLoads.isEmpty else { return }
        service.browse.dropPages(scopedLoads)
        scopedLoads.removeAll()
    }

    /// The page a scoped search needs is not here yet, so an empty answer is not final: it is on its way, or about to be
    /// asked for (the view starts it a frame after the target appears).
    var isScopedLoadPending: Bool {
        guard let target = scopedLoadTarget else { return false }
        switch service.browse.pageState(target) {
        case .idle, .loading: return true
        case .loaded, .failed: return false
        }
    }

    /// The loaded page under `browseId`, or nil while it is idle, loading or failed.
    private func loadedPage(_ browseId: String?) -> MusicBrowsePage? {
        guard let browseId, case .loaded(let page) = service.browse.pageState(browseId) else { return nil }
        return page
    }

    /// What the artist field finds on the artist page on top; nil while it has no words or the page has not loaded.
    var artistSearch: MusicArtistSearch? {
        let terms = browseFilterTerms
        guard browseScope == .artist, !terms.isEmpty, let page = loadedPage(service.browse.path.last?.browseId) else { return nil }
        return MusicArtistSearch.resolve(page: page, songsPage: loadedPage(page.allSongsBrowseId), terms: terms)
    }

    /// The artist results cover the artist page.
    var showsArtistSearch: Bool {
        artistSearch != nil
    }

    /// The Songs block over the filtered Library: the matches in Liked music, loaded or not yet. Nil without words.
    var likedSongs: MusicLikedSongs? {
        let terms = browseFilterTerms
        guard browseScope == .library, !terms.isEmpty else { return nil }
        return MusicLikedSongs.resolve(page: loadedPage(MusicBrowseStore.likedMusic.browseId), terms: terms)
    }

    /// The Library filter found nothing anywhere: not in the segment, and not among the songs of Liked music, which
    /// are not given up on while they are still loading.
    func libraryHasNoMatch(_ filter: MusicLibraryFilter) -> Bool {
        guard filter.isEmpty, !isScopedLoadPending else { return false }
        return likedSongs?.isEmpty ?? true
    }

    /// "Show all N songs": Liked music opens with the Library filter's words as its own filter, field open.
    func showAllLikedSongs() {
        let words = filterQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard browseScope == .library, !words.isEmpty else { return }
        openCollection(MusicBrowseStore.likedMusic)
        filterAnchor = currentAnchor
        filterQuery = words
    }

    /// History under the field's words: the days with the items that match; nil while it has no words or History has
    /// not loaded.
    var historyFilter: MusicHistoryFilter? {
        let terms = browseFilterTerms
        guard browseScope == .history, !terms.isEmpty, case .loaded(let shelves) = service.browse.history else { return nil }
        return MusicHistoryFilter.resolve(shelves: shelves, terms: terms, isPartial: service.browse.canLoadMoreHistory)
    }

    /// The words Up next is filtered by right now.
    var queueFilterTerms: [String] {
        guard showsQueue, isQueueFieldOpen else { return [] }
        return MusicLocalSearch.terms(of: queueQuery)
    }

    /// The YouTube Music results (or the Return prompt) cover the browse content: the field is open here and has words.
    var showsSearchPanel: Bool {
        browseScope == .global && searchAnchor == currentAnchor && !trimmedQuery.isEmpty
    }

    /// The magnifier: the field opens, empty, on the screen on top.
    func openField() {
        guard !isFieldOpen else { return }
        switch scope {
        case .none:
            return
        case .queue:
            queueQuery = ""
            isQueueFieldOpen = true
        case .global:
            dropQuery()
            hidesResults = false
            searchAnchor = currentAnchor
        case .library, .playlist, .album, .artist, .history:
            filterQuery = ""
            filterAnchor = currentAnchor
        }
    }

    /// The clear button, and Clear filter: the words go, the field stays open.
    func clearField() {
        switch scope {
        case .global: dropQuery()
        case .library, .playlist, .album, .artist, .history:
            filterQuery = ""
            endScopedLoads()
        case .queue: queueQuery = ""
        case .none: break
        }
    }

    /// Return in the YouTube Music field: the words are searched at once, whatever was waiting out its delay.
    func submit() {
        hidesResults = false
        closePanels()
        cancelPendingSearch()
        // The same words are already on their way (typed, then Return): they are not started over. After a failure
        // nothing is in flight, so Return retries.
        guard !(trimmedQuery == lastSearchedQuery && service.isSearching) else { return }
        sendSearch()
    }

    /// The query was edited. An emptied field stops the search and drops its results, back to browsing. Other words are
    /// searched once the owner pauses. Typing closes the save to playlist menu, but never Lyrics or Up next: the field
    /// is under them, and a key that reaches it must not take them away.
    func queryChanged() {
        hidesResults = false
        service.trackActions.closePicker()
        guard !trimmedQuery.isEmpty else {
            cancelPendingSearch()
            lastSearchedQuery = ""
            submittedQuery = nil
            if service.isSearching || hasResults { service.search() }
            return
        }
        scheduleSearch()
    }

    /// Sends the trimmed query as a search and remembers it as the last one.
    private func sendSearch() {
        submittedQuery = trimmedQuery
        lastSearchedQuery = trimmedQuery
        service.search()
    }

    /// Waits `searchDelay` for another edit, then searches the words as they are by then. Each edit starts the wait
    /// again, and the search in flight keeps its own guard against a stale answer. Only the YouTube Music field is
    /// sent anywhere: the fields that filter what is on screen change nothing here, and words that trim to the last
    /// search, or to nothing, are not searched.
    private func scheduleSearch() {
        cancelPendingSearch()
        guard scope == .global, trimmedQuery != lastSearchedQuery else { return }
        isSearchPending = true
        let delay = searchDelay
        pendingSearch = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard !Task.isCancelled else { return }
            self?.searchTypedWords()
        }
    }

    private func searchTypedWords() {
        cancelPendingSearch()
        guard scope == .global, !trimmedQuery.isEmpty, trimmedQuery != lastSearchedQuery else { return }
        sendSearch()
    }

    private func cancelPendingSearch() {
        pendingSearch?.cancel()
        pendingSearch = nil
        isSearchPending = false
    }

    /// The "Search YouTube Music instead" link of a filter that found nothing: the same words go to Home's field and
    /// are sent.
    func searchYouTubeMusicInstead() {
        let words = (scope == .queue ? queueQuery : filterQuery).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        select(.home)
        searchAnchor = currentAnchor
        service.query = words
        submit()
    }

    /// The column moved (a tab, a page opened or closed): a field left behind folds away with its words. The YouTube
    /// Music field is the exception while its results wait under a page opened from them, which Back returns to.
    func reconcile() {
        let anchor = currentAnchor
        if filterAnchor != nil, filterAnchor != anchor {
            filterAnchor = nil
            filterQuery = ""
            endScopedLoads()
        }
        if searchAnchor != nil, searchAnchor != anchor, !isHidingResults {
            searchAnchor = nil
            dropQuery()
        }
    }

    /// Every field closes and forgets its words (a tab was picked, or the session ended).
    func resetFields() {
        cancelPendingSearch()
        // After a sign-out the query is already empty and no edit is seen, so what the last search left is forgotten here.
        lastSearchedQuery = ""
        submittedQuery = nil
        searchAnchor = nil
        filterAnchor = nil
        filterQuery = ""
        endScopedLoads()
        isQueueFieldOpen = false
        queueQuery = ""
        dropQuery()
    }

    /// The words of the YouTube Music field go, and with them its results.
    private func dropQuery() {
        guard !service.query.isEmpty else { return }
        service.query = ""
        queryChanged()
    }

    // MARK: - Panels

    /// The Up next button: the queue takes the right column, or gives it back. Lyrics and Related close, since they are
    /// never on together.
    func toggleQueue() {
        service.lyrics.setPanelOpen(false)
        closeRelated()
        service.trackActions.closePicker()
        queueForced.toggle()
        // A queue opens with its field closed.
        closeQueueField()
    }

    /// The Lyrics button: the lyrics take the right column, or give it back. The lyrics panel is open exactly while its
    /// view is the right column.
    func toggleLyrics() {
        queueForced = false
        closeRelated()
        service.trackActions.closePicker()
        service.lyrics.setPanelOpen(!service.lyrics.isPanelOpen)
    }

    /// The hover card's Lyrics button: the lyrics take the right column whatever was there, and stay if they already
    /// had it (the popover opens on them, so a toggle would close them).
    func openLyrics() {
        queueForced = false
        closeRelated()
        service.trackActions.closePicker()
        service.lyrics.setPanelOpen(true)
    }

    /// The player's Related button: the related songs of the song that plays take the right column and follow the
    /// player from here on, or the panel gives the column back. Lyrics and Up next close, since they are never on
    /// together. A panel that a menu opened for another song is turned off by the button too, as any open panel is.
    func toggleRelated() {
        if showsRelated {
            closeRelated()
            return
        }
        makeRoomForRelated()
        service.related.follow(service.player.nowPlaying)
    }

    /// A song's menu, Related songs: the panel shows that song's related songs and stays on it, whatever the player
    /// does. A panel that is already open moves to the song.
    func openRelated(for track: MusicTrack) {
        makeRoomForRelated()
        service.related.show(track)
    }

    /// An album, playlist, mix or artist menu, Related songs: the panel shows the related songs of the first song on
    /// its page and stays on it. The page is read for that song only; it is not opened.
    func openRelated(for collection: MusicCollection) {
        makeRoomForRelated()
        service.related.show(collection)
    }

    /// The Related panel goes back to browse, the screen under it, and its store stops asking. Does nothing when it is
    /// closed already.
    func closeRelated() {
        guard showsRelated else { return }
        service.related.close()
    }

    /// What Related takes the column from: Up next (its field with it), Lyrics and the save menu.
    private func makeRoomForRelated() {
        queueForced = false
        closeQueueField()
        service.lyrics.setPanelOpen(false)
        service.trackActions.closePicker()
    }

    /// Lyrics, Up next or Related goes back to browse, the screen under it.
    func closePanel() {
        queueForced = false
        closeQueueField()
        closeRelated()
        service.lyrics.setPanelOpen(false)
    }

    /// The player was stopped: Lyrics and Up next have nothing to show, so they close, and so does a Related panel
    /// that follows the player. A panel a menu pinned is for a seed of its own and stays.
    func playerStopped() {
        queueForced = false
        closeQueueField()
        service.lyrics.setPanelOpen(false)
        if service.related.isFollowing { closeRelated() }
    }

    /// The queue ended: the next song played must not pop Up next open again. Lyrics and Related are not Up next's.
    func queueEnded() {
        queueForced = false
    }

    /// Everything that sits over the browse screens goes away.
    private func closePanels() {
        queueForced = false
        closeQueueField()
        closeRelated()
        service.lyrics.setPanelOpen(false)
        service.trackActions.closePicker()
    }

    private func closeQueueField() {
        isQueueFieldOpen = false
        queueQuery = ""
    }

    /// The save to playlist menu closes; nothing under it moved.
    func closePicker() {
        service.trackActions.closePicker()
    }

    // MARK: - Opening pages

    /// A tab of the header: leaves the panels and any page, and goes to the tab's root. A field open on the screen it
    /// leaves folds away, its words with it. History is what was played, so coming to it from another tab asks for it
    /// again while the old list stays up; picking it while on it does not.
    func select(_ tab: MusicBrowseStore.Tab) {
        let previous = service.browse.tab
        closePanels()
        resetFields()
        hidesResults = false
        service.browse.tab = tab
        service.browse.popToRoot()
        if tab == .history, previous != .history { service.browse.refreshHistory() }
    }

    /// Escape: closes the topmost thing over the browse screens and says whether there was one. The save menu first, then
    /// whatever covers the column (Lyrics, Related or Up next, where an open field gives way first: its words, then the
    /// field), then the field of the screen on top, again its words first. Escape never pops the page stack. The
    /// account card is the popup's and closes before this is asked.
    func escape() -> Bool {
        if showsPicker {
            closePicker()
            return true
        }
        if showsLyrics || showsRelated {
            closePanel()
            return true
        }
        if showsQueue {
            if isQueueFieldOpen {
                if queueQuery.isEmpty { isQueueFieldOpen = false } else { queueQuery = "" }
            } else {
                closePanel()
            }
            return true
        }
        guard isFieldOpen else { return false }
        if browseScope.isLocal {
            if filterQuery.isEmpty { filterAnchor = nil } else { filterQuery = "" }
            endScopedLoads()
        } else if service.query.isEmpty {
            searchAnchor = nil
        } else {
            dropQuery()
        }
        return true
    }

    /// An artist name or tile was tapped, from anywhere.
    func openArtist(_ artist: MusicCollection) {
        openCollection(artist)
    }

    /// An artist or an album (a name, a tile or Go to album) was opened, from anywhere. It opens on top of the pages
    /// already open. Over search results the results step aside, keeping the query and those pages, and Back returns
    /// to them. Up next, Lyrics, Related and the save menu close before the open, so the page is not hidden behind
    /// them.
    func openCollection(_ collection: MusicCollection) {
        let fromResults = showsResults
        closePanels()
        service.browse.open(collection)
        if fromResults {
            // Opening the page already on top adds nothing, so count from the end of the path, not the start.
            resultsDepth = service.browse.path.count - 1
            hidesResults = true
        }
    }

    // MARK: - Song actions

    /// The "..." menu of a song: what it offers here, in menu order.
    func actions(for track: MusicTrack, in context: MusicTrackContext) -> [MusicTrackAction] {
        let home = MusicPinnedItem(track: track).map { service.pinnedItems.state(for: $0) }
        // The song in the player is already playing: it is not queued behind itself.
        let playing = service.queue.current ?? service.player.nowPlaying
        let offersQueue = track.videoId != playing?.videoId
        return MusicTrackActions.available(
            for: track, in: context, home: home, offersQueue: offersQueue,
            canRate: service.authState == .signedIn, likeStatus: likeStatus(of: track, in: context),
            download: service.downloads?.state(for: track.videoId)
        )
    }

    /// What the menu knows of a song's rating: what the app has (read, or set here), else Liked for a row of the Liked
    /// music page, whose songs are all liked, so that page's rows offer Remove like with no read.
    private func likeStatus(of track: MusicTrack, in context: MusicTrackContext) -> MusicLikeStatus? {
        service.likes.status(of: track.videoId) ?? (context.isLikedMusic ? .like : nil)
    }

    /// The pointer reached a song's row, or its "..." menu is about to open: reads the song's rating so the menu words
    /// Like and Dislike for it. A song is read once; one row after another asks once each. A row of the Liked music page
    /// is known to be liked and is not read. Never call it while a view builds its body.
    func revealLikeStatus(of track: MusicTrack, in context: MusicTrackContext) {
        guard !context.isLikedMusic else { return }
        service.loadLikeStatus(of: track)
    }

    /// Runs a menu item. Save to playlist opens the save menu over whatever shows, which stays as it was; Go to album
    /// and Go to artist open the page; Related songs opens the Related panel for the song; Remove goes to the actions
    /// store, which shows what happened as a short line; Pin to Home is Deci's own list, changed on the spot; Play
    /// next, Add to queue and Remove from queue edit the play order and say so the same way. Like, Remove like, Dislike
    /// and Remove dislike set the song's rating and say what came of it where the hotkeys' outcome shows (`rate`).
    /// Download queues the song's audio for saving on this Mac; Remove download deletes it, or stops it while it runs.
    func perform(_ action: MusicTrackAction, for track: MusicTrack, in context: MusicTrackContext) {
        switch action {
        case .goToAlbum:
            if let album = MusicTrackActions.albumCollection(for: track) { openCollection(album) }
        case .goToArtist:
            if let artist = MusicTrackActions.artistCollection(for: track, in: context) { openArtist(artist) }
        case .related:
            openRelated(for: track)
        case .saveToPlaylist:
            service.trackActions.openPicker(for: track)
        case .removeFromPlaylist:
            service.trackActions.remove(track, in: context)
        case .playNext:
            service.playNext(track)
        case .addToQueue:
            service.addToQueue(track)
        case .removeFromQueue:
            service.removeFromQueue(track)
        case .pinHome:
            if let item = MusicPinnedItem(track: track) { service.pinnedItems.toggle(item) }
        case .download:
            service.downloads?.download(track)
        case .removeDownload:
            service.downloads?.remove(videoId: track.videoId)
        case .like, .dislike:
            if let status = action.ratingStatus { rate(status, track) }
        }
    }

    /// Sets a song's rating and reports the outcome. Only a failure shows: a rating of the playing song is shown by the
    /// like animation, and one of any other song shows nowhere (a row shows no rating); the song's menu words Like and
    /// Dislike by it the next time it opens. The report goes where the hotkeys' goes (`outcomes`): the notice line while
    /// the popup is open, the HUD when it closed during the call. Disliking the song that plays skips it; any other song
    /// leaves the player alone.
    @discardableResult
    func rate(_ status: MusicLikeStatus, _ track: MusicTrack) -> Task<Void, Never> {
        Task { [service, weak self] in
            let outcome = await service.setLike(status, of: track)
            if let outcomes = self?.outcomes {
                outcomes.report(outcome)
            } else {
                service.trackActions.post(outcome)
            }
        }
    }

    // MARK: - Tile actions

    /// The "..." menu of an album, playlist or artist tile: what it offers here, in menu order.
    func actions(for collection: MusicCollection, in context: MusicTrackContext) -> [MusicTrackAction] {
        let home = MusicPinnedItem(collection: collection).map { service.pinnedItems.state(for: $0) }
        return MusicTrackActions.available(for: collection, in: context, home: home)
    }

    /// Runs a tile's menu item, with the same effects as the song menu's: Save to playlist opens the save menu for the
    /// whole album or playlist, Go to album and Go to artist open the page, Related songs opens the Related panel for
    /// the first song of the tile's page, Pin to Home changes Deci's own list. The song-only entries, and the downloads
    /// (an album or playlist has none yet), do nothing on a tile.
    func perform(_ action: MusicTrackAction, for collection: MusicCollection, in context: MusicTrackContext) {
        switch action {
        case .goToAlbum:
            if let album = MusicTrackActions.albumCollection(for: collection) { openCollection(album) }
        case .goToArtist:
            if let artist = MusicTrackActions.artistCollection(for: collection, in: context) { openArtist(artist) }
        case .related:
            openRelated(for: collection)
        case .saveToPlaylist:
            service.trackActions.openPicker(for: collection)
        case .pinHome:
            if let item = MusicPinnedItem(collection: collection) { service.pinnedItems.toggle(item) }
        case .playNext, .addToQueue, .removeFromQueue, .removeFromPlaylist, .like, .dislike, .download, .removeDownload:
            break
        }
    }
}
