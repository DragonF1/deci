// Deci/Music/MusicSearchNavigation.swift
import Foundation
import Observation

/// What the Music tab shows over Home and Library (search results, Up next, Lyrics, the add-to-playlist picker), and
/// the one way every artist, album name or tile opens its page, and every "..." menu action runs. It lives here, not
/// in the view, so the rules can be tested. One instance
/// belongs to each `MusicService` (`MusicServiceHost` makes it): the Music popup unmounts the player's view when the
/// icon is hidden and builds it again, and the view takes this one back, so what was open is still open.
@MainActor
@Observable
final class MusicSearchNavigation {
    /// The Up next button shows the queue over whatever is on screen.
    var queueForced = false
    /// Now Playing is open: the player screen fills the popover over whichever browse screen is under it. Lyrics and
    /// Up next are player screens too, so they open it as well; Back from them goes to the browse screen.
    var isNowPlayingOpen = false
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

    /// The screen the shell shows: a browse screen with the tab bar, or one of the player screens.
    var screen: MusicShellScreen {
        MusicShellScreen.resolve(
            isNowPlayingOpen: isNowPlayingOpen,
            hasTrack: service.player.nowPlaying != nil,
            showsLyrics: showsLyrics,
            showsQueue: showsQueue,
            showsPicker: showsPicker
        )
    }

    private var isHidingResults: Bool {
        hidesResults && service.browse.path.count > resultsDepth
    }

    /// The Artists shelf above the songs; nil when the search found no artists.
    var artistsShelf: MusicShelf? {
        guard !service.artistResults.isEmpty else { return nil }
        return MusicShelf(title: "Artists", items: service.artistResults.map { .collection($0) })
    }

    /// What the results area says when it has nothing to list.
    var emptyResultsText: String {
        if service.isSearching { return "Searching..." }
        return service.lastError == nil ? "No songs or artists found." : "Search failed. Press Return to try again."
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
    /// closes the add-to-playlist picker, which sits over the results, but never a player screen: the field is on the
    /// Search tab, under them, and a key that reaches it must not take Now Playing, Lyrics or Up next away.
    func queryChanged() {
        hidesResults = false
        service.trackActions.closePicker()
        if trimmedQuery.isEmpty, service.isSearching || hasResults {
            service.search()
        }
    }

    // MARK: - Panels

    func toggleQueue() {
        service.lyrics.setPanelOpen(false)
        service.trackActions.closePicker()
        queueForced.toggle()
        if queueForced { isNowPlayingOpen = true }
    }

    func toggleLyrics() {
        queueForced = false
        service.trackActions.closePicker()
        service.lyrics.setPanelOpen(!service.lyrics.isPanelOpen)
        if service.lyrics.isPanelOpen { isNowPlayingOpen = true }
    }

    /// The mini player was tapped: Now Playing opens over the browse screen.
    func openNowPlaying() {
        guard service.player.nowPlaying != nil else { return }
        service.trackActions.closePicker()
        isNowPlayingOpen = true
    }

    /// Leaves Now Playing, Lyrics and Up next, back to the browse screen under them.
    func dismissPlayer() {
        queueForced = false
        service.lyrics.setPanelOpen(false)
        isNowPlayingOpen = false
    }

    /// Everything that sits over the browse screens goes away, the player screens included.
    private func closePanels() {
        queueForced = false
        isNowPlayingOpen = false
        service.lyrics.setPanelOpen(false)
        service.trackActions.closePicker()
    }

    /// Back from the picker, to whatever was under it.
    func closePicker() {
        service.trackActions.closePicker()
    }

    // MARK: - Opening pages

    /// A tab of the tab bar: leaves the queue, the player and any page, and goes to the tab's root. Leaving Search
    /// for another tab drops its query; the Search tab keeps the query and shows its results again.
    func select(_ tab: MusicBrowseStore.Tab) {
        closePanels()
        if tab != .search, showsResults || isHidingResults { service.query = "" }
        hidesResults = false
        service.browse.tab = tab
        service.browse.popToRoot()
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
