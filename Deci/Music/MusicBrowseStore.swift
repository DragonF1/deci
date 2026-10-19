// Deci/Music/MusicBrowseStore.swift
import Foundation
import Observation
import os

private let logger = Logger(subsystem: "com.abraham.Deci", category: "MusicBrowse")

/// Home, Library and the pages opened from them, for the Music tab. `MusicService` owns one
/// (`service.browse`). The state lives here, not in the views, because the popover panel hides
/// whenever it loses focus.
@MainActor
@Observable
final class MusicBrowseStore {
    enum Tab: Hashable, CaseIterable {
        case home
        case library
        case search
    }

    enum Load<Value: Equatable>: Equatable {
        case idle
        case loading
        case loaded(Value)
        /// A short message for the user; the list shows it with a Retry button.
        case failed(String)
    }

    /// Pinned at the top of Library; opens the "VLLM" playlist page. Left out of the playlists list.
    static let likedMusic = MusicCollection(
        browseId: "VLLM", kind: .playlist, title: "Liked music", subtitle: "Auto playlist", thumbnailURL: nil
    )

    var tab: Tab = .home
    var librarySection: MusicLibrarySection = .playlists

    private(set) var home: Load<[MusicShelf]> = .idle
    private(set) var isLoadingMoreHome = false
    /// Home has more shelves to load.
    private(set) var canLoadMoreHome = false

    private(set) var library: [MusicLibrarySection: Load<[MusicCollection]>] = [:]
    private(set) var loadingMoreLibrary: Set<MusicLibrarySection> = []
    private(set) var libraryHasMore: Set<MusicLibrarySection> = []

    /// Pages opened from Home or Library, the one on screen last. Empty shows the tab's root.
    private(set) var path: [MusicCollection] = []
    private(set) var pages: [String: Load<MusicBrowsePage>] = [:]
    private(set) var loadingMoreTracks: Set<String> = []
    /// Playlists whose sort is loading every remaining page of songs first.
    private(set) var loadingAllTracks: Set<String> = []
    /// The sort picked for each playlist this session. A playlist missing here is in its default order.
    private(set) var sorts: [String: MusicPlaylistSort] = [:]

    /// A sort loads songs up to this many and sorts the first this-many songs of the playlist. A shuffled queue
    /// loads up to the same number.
    static let sortTrackCap = MusicQueue.fullLoadCap
    /// A sort asks for no more pages than this, whatever they hold.
    static let sortPageCeiling = 100
    /// A sort gives up after this many pages in a row that bring no new song.
    static let sortEmptyPageLimit = 3

    @ObservationIgnored private let backend: any MusicBackend
    /// A load names itself with the next number and only lands while it is still the current one for
    /// its list, so a reload, a reset or a slower earlier request can never overwrite newer data.
    @ObservationIgnored private var runCounter = 0
    @ObservationIgnored private var homeRun: Int?
    @ObservationIgnored private var homeToken: String?
    @ObservationIgnored private var libraryRuns: [MusicLibrarySection: Int] = [:]
    @ObservationIgnored private var libraryTokens: [MusicLibrarySection: String] = [:]
    @ObservationIgnored private var pageRuns: [String: Int] = [:]
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    /// The last sorted page per playlist, so reading it again while a song plays does not sort again.
    @ObservationIgnored private var sortedPages: [String: (sort: MusicPlaylistSort, page: MusicBrowsePage)] = [:]
    /// Told when a call says the session is gone, so the service can sign out.
    @ObservationIgnored var onSessionExpired: (@MainActor () -> Void)?
    /// Told when a page lands, with the page and the collection on the path that opened it, so the service can keep a
    /// pinned artist's name and photo current. Not told for a page that was closed, reloaded or reset before it landed.
    @ObservationIgnored var onPageLoaded: (@MainActor (MusicBrowsePage, MusicCollection?) -> Void)?

    init(backend: any MusicBackend) {
        self.backend = backend
    }

    func libraryState(_ section: MusicLibrarySection) -> Load<[MusicCollection]> {
        library[section] ?? .idle
    }

    func pageState(_ browseId: String) -> Load<MusicBrowsePage> {
        pages[browseId] ?? .idle
    }

    // MARK: - Home

    /// Loads Home when it has not loaded yet or the last try failed.
    func loadHomeIfNeeded() {
        switch home {
        case .idle, .failed: reloadHome()
        case .loading, .loaded: break
        }
    }

    /// Loads Home again from the top.
    func reloadHome() {
        let run = newRun()
        homeRun = run
        homeToken = nil
        home = .loading
        isLoadingMoreHome = false
        canLoadMoreHome = false
        launch("home") { [weak self, backend] in
            do {
                let page = try await backend.home()
                self?.landHome(page, run: run)
            } catch {
                self?.failHome(error, run: run)
            }
        }
    }

    /// Loads the next shelves when the list scrolls to its end.
    func loadMoreHome() {
        guard case .loaded = home, let run = homeRun, let token = homeToken, !isLoadingMoreHome else { return }
        isLoadingMoreHome = true
        launch("home+") { [weak self, backend] in
            do {
                let page = try await backend.moreHome(continuation: token)
                self?.landMoreHome(page, run: run, token: token)
            } catch {
                self?.failMoreHome(error, run: run)
            }
        }
    }

    private func landHome(_ page: MusicHomePage, run: Int) {
        guard homeRun == run else { return }
        home = .loaded(Self.uniqueShelves(page.shelves, after: []))
        homeToken = page.continuation
        canLoadMoreHome = page.continuation != nil
    }

    private func failHome(_ error: any Error, run: Int) {
        guard homeRun == run else { return }
        home = .failed(describe(error))
        expireIfSignedOut(error)
    }

    private func landMoreHome(_ page: MusicHomePage, run: Int, token: String) {
        guard homeRun == run, case .loaded(let shelves) = home else { return }
        isLoadingMoreHome = false
        home = .loaded(shelves + Self.uniqueShelves(page.shelves, after: shelves))
        // The same token again would ask for the same page forever.
        homeToken = page.continuation == token ? nil : page.continuation
        canLoadMoreHome = homeToken != nil
    }

    /// A failed extra page leaves the shelves as they are; scrolling to the end tries again.
    private func failMoreHome(_ error: any Error, run: Int) {
        guard homeRun == run else { return }
        isLoadingMoreHome = false
        logger.info("more home failed: \(MusicService.logDescription(of: error), privacy: .public)")
        expireIfSignedOut(error)
    }

    private static func uniqueShelves(_ shelves: [MusicShelf], after existing: [MusicShelf]) -> [MusicShelf] {
        var seen = Set(existing.map(\.id))
        return shelves.filter { seen.insert($0.id).inserted }
    }

    // MARK: - Library

    func loadLibraryIfNeeded(_ section: MusicLibrarySection) {
        switch libraryState(section) {
        case .idle, .failed: reloadLibrary(section)
        case .loading, .loaded: break
        }
    }

    func reloadLibrary(_ section: MusicLibrarySection) {
        let run = newRun()
        libraryRuns[section] = run
        libraryTokens[section] = nil
        library[section] = .loading
        loadingMoreLibrary.remove(section)
        libraryHasMore.remove(section)
        launch("library:\(section.rawValue)") { [weak self, backend] in
            do {
                let list = try await backend.library(section)
                self?.landLibrary(list, section: section, run: run)
            } catch {
                self?.failLibrary(error, section: section, run: run)
            }
        }
    }

    /// Loads the next page of a library list when it scrolls to its end.
    func loadMoreLibrary(_ section: MusicLibrarySection) {
        guard case .loaded? = library[section], let run = libraryRuns[section],
              let token = libraryTokens[section], !loadingMoreLibrary.contains(section) else { return }
        loadingMoreLibrary.insert(section)
        launch("library+:\(section.rawValue)") { [weak self, backend] in
            do {
                let list = try await backend.moreLibrary(section, continuation: token)
                self?.landMoreLibrary(list, section: section, run: run, token: token)
            } catch {
                self?.failMoreLibrary(error, section: section, run: run)
            }
        }
    }

    private func landLibrary(_ list: MusicCollectionList, section: MusicLibrarySection, run: Int) {
        guard libraryRuns[section] == run else { return }
        library[section] = .loaded(Self.uniqueCollections(list.items, after: []))
        libraryTokens[section] = list.continuation
        setHasMore(list.continuation != nil, for: section)
    }

    private func failLibrary(_ error: any Error, section: MusicLibrarySection, run: Int) {
        guard libraryRuns[section] == run else { return }
        library[section] = .failed(describe(error))
        expireIfSignedOut(error)
    }

    private func landMoreLibrary(_ list: MusicCollectionList, section: MusicLibrarySection, run: Int, token: String) {
        guard libraryRuns[section] == run, case .loaded(let items)? = library[section] else { return }
        loadingMoreLibrary.remove(section)
        library[section] = .loaded(items + Self.uniqueCollections(list.items, after: items))
        let next = list.continuation == token ? nil : list.continuation
        libraryTokens[section] = next
        setHasMore(next != nil, for: section)
    }

    private func failMoreLibrary(_ error: any Error, section: MusicLibrarySection, run: Int) {
        guard libraryRuns[section] == run else { return }
        loadingMoreLibrary.remove(section)
        logger.info("more library failed: \(MusicService.logDescription(of: error), privacy: .public)")
        expireIfSignedOut(error)
    }

    private func setHasMore(_ hasMore: Bool, for section: MusicLibrarySection) {
        if hasMore { libraryHasMore.insert(section) } else { libraryHasMore.remove(section) }
    }

    /// Liked music is pinned above the lists and opens as its own page, so the playlists list leaves it out.
    private static func uniqueCollections(_ items: [MusicCollection], after existing: [MusicCollection]) -> [MusicCollection] {
        var seen = Set(existing.map(\.browseId))
        return items.filter { $0.browseId != likedMusic.browseId && seen.insert($0.browseId).inserted }
    }

    // MARK: - Pages

    /// Pushes the page and loads it unless it is already loaded.
    func open(_ collection: MusicCollection) {
        // A double tap must not push the same page twice.
        if path.last?.browseId != collection.browseId { path.append(collection) }
        switch pageState(collection.browseId) {
        case .idle, .failed: reloadPage(collection.browseId)
        case .loading, .loaded: break
        }
    }

    func reloadPage(_ browseId: String) {
        let run = newRun()
        pageRuns[browseId] = run
        pages[browseId] = .loading
        loadingMoreTracks.remove(browseId)
        loadingAllTracks.remove(browseId)
        sortedPages[browseId] = nil
        tasks.removeValue(forKey: "page*:\(browseId)")?.cancel()
        launch("page:\(browseId)") { [weak self, backend] in
            do {
                let page = try await backend.page(browseId: browseId)
                self?.landPage(page, browseId: browseId, run: run)
            } catch {
                self?.failPage(error, browseId: browseId, run: run)
            }
        }
    }

    /// Loads more tracks of a long playlist when its list scrolls to its end.
    func loadMoreTracks(_ browseId: String) {
        guard case .loaded(let page)? = pages[browseId], let run = pageRuns[browseId],
              let token = page.continuation, !loadingMoreTracks.contains(browseId),
              !loadingAllTracks.contains(browseId) else { return }
        loadingMoreTracks.insert(browseId)
        launch("page+:\(browseId)") { [weak self, backend] in
            do {
                let more = try await backend.moreTracks(browseId: browseId, continuation: token)
                self?.landMoreTracks(more, browseId: browseId, run: run, token: token)
            } catch {
                self?.failMoreTracks(error, browseId: browseId, run: run)
            }
        }
    }

    private func landPage(_ page: MusicBrowsePage, browseId: String, run: Int) {
        guard pageRuns[browseId] == run else { return }
        pages[browseId] = .loaded(page)
        loadAllTracksIfSorted(browseId)
        onPageLoaded?(page, path.last { $0.browseId == browseId })
    }

    private func failPage(_ error: any Error, browseId: String, run: Int) {
        guard pageRuns[browseId] == run else { return }
        pages[browseId] = .failed(describe(error))
        expireIfSignedOut(error)
    }

    private func landMoreTracks(_ more: MusicQueuePage, browseId: String, run: Int, token: String) {
        guard pageRuns[browseId] == run, case .loaded(let page)? = pages[browseId] else { return }
        loadingMoreTracks.remove(browseId)
        sortedPages[browseId] = nil
        var seen = Set(page.tracks.map(\.videoId))
        let fresh = more.tracks.filter { seen.insert($0.videoId).inserted }
        pages[browseId] = .loaded(MusicBrowsePage(
            browseId: page.browseId,
            title: page.title,
            subtitle: page.subtitle,
            thumbnailURL: page.thumbnailURL,
            tracks: page.tracks + fresh,
            continuation: more.continuation == token ? nil : more.continuation,
            shelves: page.shelves,
            isEditable: page.isEditable,
            listenAgainPin: page.listenAgainPin
        ))
    }

    private func failMoreTracks(_ error: any Error, browseId: String, run: Int) {
        guard pageRuns[browseId] == run else { return }
        loadingMoreTracks.remove(browseId)
        logger.info("more tracks failed: \(MusicService.logDescription(of: error), privacy: .public)")
        expireIfSignedOut(error)
    }

    /// Takes one row out of a loaded playlist page after YouTube removed it from the playlist. The row is named by its
    /// `setVideoId`, since the same song can sit in a playlist twice. A page that is not loaded, or has no such row,
    /// is left as it is. Returns whether a row went. The playing queue is not touched.
    @discardableResult
    func removeTrack(setVideoId: String, from browseId: String) -> Bool {
        guard !setVideoId.isEmpty, case .loaded(let page)? = pages[browseId],
              let index = page.tracks.firstIndex(where: { $0.playlistSetVideoId == setVideoId }) else { return false }
        var tracks = page.tracks
        tracks.remove(at: index)
        sortedPages[browseId] = nil
        pages[browseId] = .loaded(MusicBrowsePage(
            browseId: page.browseId,
            title: page.title,
            subtitle: page.subtitle,
            thumbnailURL: page.thumbnailURL,
            tracks: tracks,
            continuation: page.continuation,
            shelves: page.shelves,
            isEditable: page.isEditable,
            listenAgainPin: page.listenAgainPin
        ))
        return true
    }

    // MARK: - Sorting

    /// Only playlist pages sort; albums keep their track order and artists have no list of songs to sort.
    static func canSort(_ browseId: String) -> Bool {
        browseId.hasPrefix("VL")
    }

    /// The sort picked for this playlist; Default order until one is picked.
    func sort(for browseId: String) -> MusicPlaylistSort {
        sorts[browseId] ?? .default
    }

    /// Picks a sort option for a playlist: a new option sorts ascending, the same one again flips the direction.
    /// A sort first loads every remaining page of songs (up to `sortTrackCap`), and the list keeps its order until then.
    func pickSort(_ field: MusicSortField, for browseId: String) {
        guard Self.canSort(browseId) else { return }
        let picked = sort(for: browseId).picking(field)
        sorts[browseId] = picked.isDefault ? nil : picked
        sortedPages[browseId] = nil
        loadAllTracksIfSorted(browseId)
    }

    /// The page as the list shows it and as Play queues it: in the playlist's sort once all its songs are here
    /// (with no more to load, so a queue made from it ends where the sorted list does), else as loaded.
    func displayedPage(_ browseId: String) -> MusicBrowsePage? {
        guard case .loaded(let page)? = pages[browseId] else { return nil }
        let sort = sort(for: browseId)
        guard !sort.isDefault, !loadingAllTracks.contains(browseId) else { return page }
        if let cached = sortedPages[browseId], cached.sort == sort { return cached.page }
        let sorted = MusicBrowsePage(
            browseId: page.browseId,
            title: page.title,
            subtitle: page.subtitle,
            thumbnailURL: page.thumbnailURL,
            tracks: sort.sorted(Array(page.tracks.prefix(Self.sortTrackCap))),
            continuation: nil,
            shelves: page.shelves,
            isEditable: page.isEditable,
            listenAgainPin: page.listenAgainPin
        )
        sortedPages[browseId] = (sort, sorted)
        return sorted
    }

    /// How many songs a sort covers when that is only the start of a longer playlist: the loading stopped at the cap,
    /// or gave up on pages that went nowhere. Nil when the sort covers every song, when there is no sort, and while
    /// the songs are still loading.
    func sortedSongLimit(_ browseId: String) -> Int? {
        guard !sort(for: browseId).isDefault, !loadingAllTracks.contains(browseId),
              case .loaded(let page)? = pages[browseId] else { return nil }
        guard page.continuation != nil || page.tracks.count > Self.sortTrackCap else { return nil }
        return min(page.tracks.count, Self.sortTrackCap)
    }

    /// Starts loading what is left of a sorted playlist, unless it is all here already or loading has started.
    private func loadAllTracksIfSorted(_ browseId: String) {
        guard !sort(for: browseId).isDefault, case .loaded(let page)? = pages[browseId], let run = pageRuns[browseId],
              page.continuation != nil, page.tracks.count < Self.sortTrackCap,
              !loadingAllTracks.contains(browseId) else { return }
        loadingAllTracks.insert(browseId)
        launch("page*:\(browseId)") { [weak self] in
            await self?.loadRemainingTracks(browseId, run: run)
        }
    }

    /// Fetches page after page while the playlist is sorted and has more, up to the cap. A page that is already
    /// loading for the list footer is waited for, not asked for twice. A failure goes back to the default order.
    /// Three more ways end it with what is loaded, so a chain that never ends cannot keep the sort loading: pages
    /// that bring no new song several times in a row, a continuation that comes round again, and a ceiling on pages.
    private func loadRemainingTracks(_ browseId: String, run: Int) async {
        var seenTokens = Set<String>()
        var emptyPagesInARow = 0
        var pagesAsked = 0
        while pageRuns[browseId] == run, !sort(for: browseId).isDefault,
              case .loaded(let page)? = pages[browseId], let token = page.continuation,
              page.tracks.count < Self.sortTrackCap {
            if loadingMoreTracks.contains(browseId) {
                await tasks["page+:\(browseId)"]?.value
                if loadingMoreTracks.contains(browseId) { break }
                continue
            }
            guard pagesAsked < Self.sortPageCeiling, emptyPagesInARow < Self.sortEmptyPageLimit,
                  seenTokens.insert(token).inserted else { break }
            pagesAsked += 1
            do {
                let more = try await backend.moreTracks(browseId: browseId, continuation: token)
                guard pageRuns[browseId] == run else { return }
                landMoreTracks(more, browseId: browseId, run: run, token: token)
                if case .loaded(let landed)? = pages[browseId], landed.tracks.count > page.tracks.count {
                    emptyPagesInARow = 0
                } else {
                    emptyPagesInARow += 1
                }
            } catch {
                guard pageRuns[browseId] == run else { return }
                logger.info("sort load failed: \(MusicService.logDescription(of: error), privacy: .public)")
                sorts[browseId] = nil
                sortedPages[browseId] = nil
                loadingAllTracks.remove(browseId)
                expireIfSignedOut(error)
                return
            }
        }
        guard pageRuns[browseId] == run else { return }
        loadingAllTracks.remove(browseId)
    }

    /// Back one page.
    func back() {
        guard let closed = path.popLast() else { return }
        drop(closed.browseId)
    }

    /// Back to the tab's root.
    func popToRoot() {
        let closed = path
        path.removeAll()
        for collection in closed { drop(collection.browseId) }
    }

    /// A closed page is dropped unless it is still further down the path, so opening it again
    /// fetches it fresh (a song just liked shows in Liked music) and closed pages do not pile up.
    private func drop(_ browseId: String) {
        guard !path.contains(where: { $0.browseId == browseId }) else { return }
        for key in ["page:\(browseId)", "page+:\(browseId)", "page*:\(browseId)"] { tasks.removeValue(forKey: key)?.cancel() }
        pageRuns[browseId] = nil
        pages[browseId] = nil
        loadingMoreTracks.remove(browseId)
        loadingAllTracks.remove(browseId)
        sortedPages[browseId] = nil
    }

    // MARK: - Reset

    /// Drops everything loaded: on sign-out and after a channel switch (the library is per channel).
    /// The selected tab and library section are the user's choice, not loaded data, and stay.
    func reset() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        homeRun = nil
        homeToken = nil
        libraryRuns.removeAll()
        libraryTokens.removeAll()
        pageRuns.removeAll()
        home = .idle
        isLoadingMoreHome = false
        canLoadMoreHome = false
        library.removeAll()
        loadingMoreLibrary.removeAll()
        libraryHasMore.removeAll()
        path.removeAll()
        pages.removeAll()
        loadingMoreTracks.removeAll()
        loadingAllTracks.removeAll()
        sorts.removeAll()
        sortedPages.removeAll()
    }

    // MARK: - Helpers

    private func newRun() -> Int {
        runCounter += 1
        return runCounter
    }

    /// Starts `work` under `key`, cancelling the one before it. Cancelling only saves effort: what
    /// still arrives late is dropped by its run number.
    private func launch(_ key: String, _ work: @escaping @MainActor @Sendable () async -> Void) {
        tasks[key]?.cancel()
        tasks[key] = Task { await work() }
    }

    private func describe(_ error: any Error) -> String {
        logger.error("browse failed: \(MusicService.logDescription(of: error), privacy: .public)")
        return MusicService.message(for: error)
    }

    /// Always the last thing a failure does: the service signs out and resets this store.
    private func expireIfSignedOut(_ error: any Error) {
        if (error as? MusicError) == .signedOut { onSessionExpired?() }
    }
}
