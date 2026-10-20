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
    /// The search came back with no songs or artists.
    case noResults
    /// The search failed.
    case failed
    /// Artists and songs to list.
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
        case .invite: "Search YouTube Music for songs and artists."
        case .pressReturn: "Press Return to search."
        case .searching: "Searching..."
        case .noResults: "No songs or artists found."
        case .failed: "Search failed. Press Return to try again."
        case .results: nil
        }
    }
}

/// Where the browse column is: a tab, how many pages are open on it and the one on top. A search field is opened at one
/// anchor and only counts while the column is still there.
struct MusicSearchAnchor: Equatable {
    let tab: MusicBrowseStore.Tab
    let depth: Int
    let pageId: String?
}

/// What the Music popup's right column shows (Home and Library, search results, Up next, Lyrics, the add-to-playlist
/// picker), and the one way every artist, album name or tile opens its page, and every "..." menu action runs. It lives
/// here, not in the view, so the rules can be tested. One instance belongs to each `MusicService` (`MusicServiceHost`
/// makes it): the Music popup unmounts the player's view when the icon is hidden and builds it again, and the view takes
/// this one back, so what was open is still open.
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

    @ObservationIgnored private let service: MusicService

    init(service: MusicService) {
        self.service = service
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

    /// The search found songs or artists.
    var hasResults: Bool {
        !service.results.isEmpty || !service.artistResults.isEmpty
    }

    /// Search results show while there is a query and a search for it is running, has results, or came back
    /// empty, unless an artist opened from them is on screen. Otherwise Home, Library or an open page shows.
    /// This says nothing about Up next or Lyrics, which sit on top of whichever of the two is under them.
    var showsResults: Bool {
        guard !trimmedQuery.isEmpty, !isHidingResults else { return false }
        return service.isSearching || hasResults || submittedQuery == trimmedQuery
    }

    /// The save to playlist menu is open. The store owns it; it floats over the popup and leaves the column as it was.
    var showsPicker: Bool {
        service.trackActions.picker != nil
    }

    var isBrowsing: Bool {
        !showsQueue && !showsResults && !showsLyrics
    }

    /// Home's root is on screen with nothing over it, so the header offers the refresh button.
    var showsHomeRefresh: Bool {
        isBrowsing && service.browse.tab == .home && service.browse.path.isEmpty
    }

    /// What fills the right column: browse, or Lyrics or Up next in place of it.
    var rightColumn: MusicRightColumn {
        MusicRightColumn.resolve(showsLyrics: showsLyrics, showsQueue: showsQueue)
    }

    /// The header tab to highlight: Library for Library and the pages opened from it, Home for everything else.
    var headerTab: MusicHeaderTab {
        MusicHeaderTab.resolve(tab: service.browse.tab)
    }

    private var isHidingResults: Bool {
        hidesResults && service.browse.path.count > resultsDepth
    }

    /// What the results cover the column with.
    var panel: MusicSearchPanel {
        MusicSearchPanel.resolve(
            queryIsEmpty: trimmedQuery.isEmpty,
            showsResults: showsResults,
            hasResults: hasResults,
            isSearching: service.isSearching,
            hasFailed: service.lastError != nil
        )
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

    /// What the field of the screen on top searches. `.none` where there is no field to open (Lyrics).
    var scope: MusicSearchScope {
        MusicSearchScope.resolve(column: rightColumn, tab: service.browse.tab, page: pageKind)
    }

    /// The field is open on the screen on top.
    var isFieldOpen: Bool {
        switch rightColumn {
        case .queue: isQueueFieldOpen
        case .browse: (browseScope.isLocal ? filterAnchor : searchAnchor) == currentAnchor
        case .lyrics: false
        }
    }

    /// The words in the field. Typing into a YouTube Music field is the service's own query, which Return sends.
    var fieldQuery: String {
        get {
            switch scope {
            case .global: service.query
            case .library, .playlist, .album: filterQuery
            case .queue: queueQuery
            case .none: ""
            }
        }
        set {
            switch scope {
            case .global: service.query = newValue
            case .library, .playlist, .album: filterQuery = newValue
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
        case .library, .playlist, .album:
            filterQuery = ""
            filterAnchor = currentAnchor
        }
    }

    /// The clear button, and Clear filter: the words go, the field stays open.
    func clearField() {
        switch scope {
        case .global: dropQuery()
        case .library, .playlist, .album: filterQuery = ""
        case .queue: queueQuery = ""
        case .none: break
        }
    }

    /// Return in the YouTube Music field.
    func submit() {
        hidesResults = false
        closePanels()
        submittedQuery = trimmedQuery
        service.search()
    }

    /// The query was edited. An emptied field stops the search and drops its results, back to browsing. Typing
    /// closes the save to playlist menu, but never Lyrics or Up next: the field is under them, and a key that reaches it
    /// must not take them away.
    func queryChanged() {
        hidesResults = false
        service.trackActions.closePicker()
        if trimmedQuery.isEmpty, service.isSearching || hasResults {
            service.search()
        }
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
        }
        if searchAnchor != nil, searchAnchor != anchor, !isHidingResults {
            searchAnchor = nil
            dropQuery()
        }
    }

    /// Every field closes and forgets its words (a tab was picked, or the session ended).
    func resetFields() {
        searchAnchor = nil
        filterAnchor = nil
        filterQuery = ""
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

    /// The Up next button: the queue takes the right column, or gives it back. Lyrics closes, since they are never both on.
    func toggleQueue() {
        service.lyrics.setPanelOpen(false)
        service.trackActions.closePicker()
        queueForced.toggle()
        // A queue opens with its field closed.
        closeQueueField()
    }

    /// The Lyrics button: the lyrics take the right column, or give it back. The lyrics panel is open exactly while its
    /// view is the right column.
    func toggleLyrics() {
        queueForced = false
        service.trackActions.closePicker()
        service.lyrics.setPanelOpen(!service.lyrics.isPanelOpen)
    }

    /// Lyrics or Up next goes back to browse, the screen under it.
    func closePanel() {
        queueForced = false
        closeQueueField()
        service.lyrics.setPanelOpen(false)
    }

    /// Everything that sits over the browse screens goes away.
    private func closePanels() {
        queueForced = false
        closeQueueField()
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
    /// leaves folds away, its words with it.
    func select(_ tab: MusicBrowseStore.Tab) {
        closePanels()
        resetFields()
        hidesResults = false
        service.browse.tab = tab
        service.browse.popToRoot()
    }

    /// Escape: closes the topmost thing over the browse screens and says whether there was one. The save menu first, then
    /// whatever covers the column (Lyrics or Up next, where an open field gives way first: its words, then the field),
    /// then the field of the screen on top, again its words first. Escape never pops the page stack. The account card is
    /// the popup's and closes before this is asked.
    func escape() -> Bool {
        if showsPicker {
            closePicker()
            return true
        }
        if showsLyrics {
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
    /// to them. Up next, Lyrics and the save menu close before the open, so the page is not hidden behind them.
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
        return MusicTrackActions.available(for: track, in: context, home: home, offersQueue: offersQueue)
    }

    /// Runs a menu item. Save to playlist opens the save menu over whatever shows, which stays as it was; Go to album
    /// and Go to artist open the page; Remove goes to the actions store, which shows what happened as a short line;
    /// Pin to Home is Deci's own list, changed on the spot; Play next, Add to queue and Remove from queue edit the play
    /// order and say so the same way.
    func perform(_ action: MusicTrackAction, for track: MusicTrack, in context: MusicTrackContext) {
        switch action {
        case .goToAlbum:
            if let album = MusicTrackActions.albumCollection(for: track) { openCollection(album) }
        case .goToArtist:
            if let artist = MusicTrackActions.artistCollection(for: track, in: context) { openArtist(artist) }
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
        }
    }
}
