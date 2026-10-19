// Deci/Music/MusicSearchNavigation.swift
import Foundation
import Observation

/// What the Music tab shows over Home and Library (search results, Up next, Lyrics), and the one way every artist
/// name and tile opens an artist page. It lives here, not in the view, so the rules can be tested. One instance
/// belongs to each `MusicService` (`MusicServiceHost` makes it): the popup unmounts the Music tab's view on a
/// switch to Mixer and builds it again, and the view takes this one back, so what was open is still open.
@MainActor
@Observable
final class MusicSearchNavigation {
    /// The Up next button shows the queue over whatever is on screen.
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

    var isBrowsing: Bool {
        !showsQueue && !showsResults && !showsLyrics
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

    /// The query was edited. An emptied field stops the search and drops its results, back to browsing.
    func queryChanged() {
        hidesResults = false
        closePanels()
        if trimmedQuery.isEmpty, service.isSearching || hasResults {
            service.search()
        }
    }

    // MARK: - Panels

    func toggleQueue() {
        service.lyrics.setPanelOpen(false)
        queueForced.toggle()
    }

    func toggleLyrics() {
        queueForced = false
        service.lyrics.setPanelOpen(!service.lyrics.isPanelOpen)
    }

    private func closePanels() {
        queueForced = false
        service.lyrics.setPanelOpen(false)
    }

    // MARK: - Opening pages

    /// Home or Library from the switch: leaves search, the queue and any page, and goes to the tab's root.
    func select(_ tab: MusicBrowseStore.Tab) {
        closePanels()
        if showsResults || isHidingResults { service.query = "" }
        hidesResults = false
        service.browse.tab = tab
        service.browse.popToRoot()
    }

    /// An artist name or tile was tapped, from anywhere. It opens on top of the pages already open. Over search
    /// results the results step aside, keeping the query and those pages, and Back returns to them. Up next and
    /// Lyrics close before the open, so the artist page is not hidden behind the panel.
    func openArtist(_ artist: MusicCollection) {
        let fromResults = showsResults
        closePanels()
        service.browse.open(artist)
        if fromResults {
            // Opening the page already on top adds nothing, so count from the end of the path, not the start.
            resultsDepth = service.browse.path.count - 1
            hidesResults = true
        }
    }
}
