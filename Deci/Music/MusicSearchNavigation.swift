// Deci/Music/MusicSearchNavigation.swift
import Foundation
import Observation

/// What the Search tab shows under its field. Kept apart from the view so each combination is tested.
nonisolated enum MusicSearchPanel: Equatable {
    /// Nothing typed: the tab invites a search.
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
    /// The tab search was opened from, so closing it returns there. nil until search has been opened.
    private(set) var tabBeforeSearch: MusicBrowseStore.Tab?
    /// The query last sent with Return, so a search that found nothing still shows its result.
    private(set) var submittedQuery: String?
    /// An artist opened from the results is on screen: the results step aside, keeping the query, and come back
    /// when the path is back at `resultsDepth` (Back). Only counts while the path is deeper than that, so a stale
    /// flag does nothing.
    private(set) var hidesResults = false
    /// How many pages were open under the results when an artist was opened from them. The results sit on those
    /// pages, so Back from the artist returns to the results, and clearing the query leaves the pages as they were.
    @ObservationIgnored private var resultsDepth = 0

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

    /// The add-to-playlist picker is open. The store owns it; like Up next and Lyrics it sits over whatever is under
    /// it, and is never on together with either of them.
    var showsPicker: Bool {
        service.trackActions.picker != nil
    }

    var isBrowsing: Bool {
        !showsQueue && !showsResults && !showsLyrics && !showsPicker
    }

    /// What fills the right column: browse, or Lyrics, Up next or the picker in place of it.
    var rightColumn: MusicRightColumn {
        MusicRightColumn.resolve(showsPicker: showsPicker, showsLyrics: showsLyrics, showsQueue: showsQueue)
    }

    /// The header tab to highlight: Library for Library and the pages opened from it, Home for everything else. While
    /// search is open it keeps the tab it was opened from.
    var headerTab: MusicHeaderTab {
        MusicHeaderTab.resolve(tab: service.browse.tab, tabBeforeSearch: tabBeforeSearch)
    }

    /// The global search screen is the browse tab.
    var isSearchOpen: Bool {
        service.browse.tab == .search
    }

    private var isHidingResults: Bool {
        hidesResults && service.browse.path.count > resultsDepth
    }

    /// What the Search tab shows under the field.
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

    /// Return in the search field.
    func submit() {
        hidesResults = false
        closePanels()
        submittedQuery = trimmedQuery
        service.search()
    }

    /// The query was edited. An emptied field stops the search and drops its results, back to browsing. Typing
    /// closes the add-to-playlist picker, which sits over the results, but never Lyrics or Up next: the field is under
    /// them, and a key that reaches it must not take them away.
    func queryChanged() {
        hidesResults = false
        service.trackActions.closePicker()
        if trimmedQuery.isEmpty, service.isSearching || hasResults {
            service.search()
        }
    }

    // MARK: - Panels

    /// The Up next button: the queue takes the right column, or gives it back. Lyrics closes, since they are never both on.
    func toggleQueue() {
        service.lyrics.setPanelOpen(false)
        service.trackActions.closePicker()
        queueForced.toggle()
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
        service.lyrics.setPanelOpen(false)
    }

    /// Everything that sits over the browse screens goes away.
    private func closePanels() {
        queueForced = false
        service.lyrics.setPanelOpen(false)
        service.trackActions.closePicker()
    }

    /// Back from the picker, to whatever was under it.
    func closePicker() {
        service.trackActions.closePicker()
    }

    // MARK: - Opening pages

    /// A tab of the header, or search: leaves the panels and any page, and goes to the tab's root. Leaving search for
    /// another tab drops its query; picking search again keeps the query and shows its results again.
    func select(_ tab: MusicBrowseStore.Tab) {
        closePanels()
        if tab != .search, showsResults || isHidingResults { service.query = "" }
        hidesResults = false
        let current = service.browse.tab
        if tab == .search, current != .search { tabBeforeSearch = current }
        service.browse.tab = tab
        service.browse.popToRoot()
    }

    /// The magnifier: the global search screen takes the right column.
    func openSearch() {
        select(.search)
    }

    /// Leaves search for the tab it was opened from (Home when it was not opened from one).
    func closeSearch() {
        select(tabBeforeSearch ?? .home)
    }

    /// The magnifier is a toggle.
    func toggleSearch() {
        if isSearchOpen { closeSearch() } else { openSearch() }
    }

    /// Escape: closes the topmost thing over the browse screens and says whether there was one. The picker first, then
    /// whatever covers the column (Lyrics or Up next), then search. Search closes only at its own root: a page opened
    /// from its results is a page, and Escape never pops the page stack. The account card is the popup's and closes before
    /// this is asked.
    func escape() -> Bool {
        if showsPicker {
            closePicker()
            return true
        }
        if showsLyrics || showsQueue {
            closePanel()
            return true
        }
        if isSearchOpen, service.browse.path.isEmpty {
            closeSearch()
            return true
        }
        return false
    }

    /// An artist name or tile was tapped, from anywhere.
    func openArtist(_ artist: MusicCollection) {
        openCollection(artist)
    }

    /// An artist or an album (a name, a tile or Go to album) was opened, from anywhere. It opens on top of the pages
    /// already open. Over search results the results step aside, keeping the query and those pages, and Back returns
    /// to them. Up next, Lyrics and the picker close before the open, so the page is not hidden behind the panel.
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
        service.trackActions.actions(for: track, in: context)
    }

    /// Runs a menu item. Save to playlist opens the picker over whatever shows; Go to album opens the album page;
    /// Remove and Pin go to the actions store, which shows what happened as a short line.
    func perform(_ action: MusicTrackAction, for track: MusicTrack, in context: MusicTrackContext) {
        switch action {
        case .goToAlbum:
            if let album = MusicTrackActions.albumCollection(for: track) { openCollection(album) }
        case .saveToPlaylist:
            queueForced = false
            service.lyrics.setPanelOpen(false)
            service.trackActions.openPicker(for: track)
        case .removeFromPlaylist:
            service.trackActions.remove(track, in: context)
        case .pinToListenAgain, .unpinFromListenAgain:
            service.trackActions.togglePin(track)
        }
    }
}
