// Deci/Music/MusicBrowseStore.swift
import Foundation
import Observation
import os

private let logger = Logger(subsystem: "com.abraham.Deci", category: "MusicBrowse")

/// Home, Library, History and the pages opened from them, for the Music tab. `MusicService` owns one
/// (`service.browse`). The state lives here, not in the views, because the popover panel hides
/// whenever it loses focus.
@MainActor
@Observable
final class MusicBrowseStore {
    enum Tab: Hashable, CaseIterable {
        case home
        case library
        case history
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

    /// Pinned at the top of Library's Downloads tab; opens the Downloaded songs page. The reserved browse id belongs to
    /// no page of YouTube Music: the store answers it from the download index and never lets it reach the backend.
    static let downloadedSongs = MusicCollection(
        browseId: MusicDownloadService.songsBrowseId, kind: .playlist, title: MusicDownloadService.songsTitle,
        subtitle: "", thumbnailURL: nil
    )

    var tab: Tab = .home

    /// The account list Playlists or Albums shows: the one the lists load for. Setting it shows that tab.
    var librarySection: MusicLibrarySection {
        get { pickedSection }
        set {
            pickedSection = newValue
            downloadsPicked = false
        }
    }

    private var pickedSection: MusicLibrarySection = .playlists
    /// Downloads was picked (online). Offline it is shown whatever was picked, and this is what comes back with the network.
    private var downloadsPicked = false

    private(set) var home: Load<[MusicShelf]> = .idle
    private(set) var isLoadingMoreHome = false
    /// Home has more shelves to load.
    private(set) var canLoadMoreHome = false
    /// `refreshHome` is asking for new shelves while the old ones stay on screen.
    private(set) var isRefreshingHome = false
    /// Counts refreshes that brought new shelves, so Home can go back to its top after one (not after a failure).
    private(set) var homeRefreshes = 0

    /// Home shelves the owner never wants, matched on the title in any case.
    static let hiddenHomeShelfTitles: Set<String> = [
        "from the community", "mixed for you", "mixes for you", "long listens", "live performances",
    ]

    /// The signed-in account's listening history: one shelf per day, newest first. Kept apart from Home's state.
    private(set) var history: Load<[MusicShelf]> = .idle
    private(set) var isLoadingMoreHistory = false
    /// History has more days to load.
    private(set) var canLoadMoreHistory = false
    /// `refreshHistory` is asking for the list again while the old one stays on screen.
    private(set) var isRefreshingHistory = false

    private(set) var library: [MusicLibrarySection: Load<[MusicCollection]>] = [:]
    private(set) var loadingMoreLibrary: Set<MusicLibrarySection> = []
    private(set) var libraryHasMore: Set<MusicLibrarySection> = []

    /// Pages opened from Home, Library or History, the one on screen last. Empty shows the tab's root.
    private(set) var path: [MusicCollection] = []
    private(set) var pages: [String: Load<MusicBrowsePage>] = [:]
    private(set) var loadingMoreTracks: Set<String> = []
    /// Playlists whose sort is loading every remaining page of songs first.
    private(set) var loadingAllTracks: Set<String> = []
    /// The sort picked for each playlist this session. A playlist missing here is at rest, where `sort(for:)` says.
    private(set) var sorts: [String: MusicPlaylistSort] = [:]
    /// The release years of an artist's songs list, by its browse id, once Release date has read them. A page missing here
    /// has not read them yet.
    private(set) var releaseYears: [String: MusicReleaseYears] = [:]
    /// Artist songs lists whose Release date is still reading the discography pages.
    private(set) var loadingReleaseYears: Set<String> = []

    /// A sort loads songs up to this many and sorts the first this-many songs of the playlist. A shuffled queue
    /// loads up to the same number.
    static let sortTrackCap = MusicQueue.fullLoadCap
    /// A sort asks for no more pages than this, whatever they hold.
    static let sortPageCeiling = 100
    /// A sort gives up after this many pages in a row that bring no new song.
    static let sortEmptyPageLimit = 3

    @ObservationIgnored private let backend: any MusicBackend
    /// Whether the network is up; nil reads as always up. Observable, so what reads `isOffline` redraws when it moves.
    @ObservationIgnored private let connectivity: MusicConnectivity?
    /// Where the Downloads tab, the Downloaded songs page and the pages of downloaded collections are read from.
    @ObservationIgnored private let downloads: MusicDownloadService?
    /// Loads asked for while offline, or cut by the network going: each runs once when it returns. A request skipped offline
    /// leaves its list idle, so nothing shows a spinner that cannot end.
    @ObservationIgnored private var waitingHome = false
    @ObservationIgnored private var waitingHistory = false
    @ObservationIgnored private var waitingLibrary: Set<MusicLibrarySection> = []
    @ObservationIgnored private var waitingPages: Set<String> = []
    /// Pages on screen that were built from the download index because the network was down; the network's page replaces
    /// each when it returns.
    @ObservationIgnored private var storedPages: Set<String> = []
    /// A load names itself with the next number and only lands while it is still the current one for
    /// its list, so a reload, a reset or a slower earlier request can never overwrite newer data.
    @ObservationIgnored private var runCounter = 0
    @ObservationIgnored private var homeRun: Int?
    @ObservationIgnored private var homeToken: String?
    /// The token from before a refresh, put back when the refresh fails so scrolling still loads more.
    @ObservationIgnored private var tokenBeforeRefresh: String?
    @ObservationIgnored private var historyRun: Int?
    @ObservationIgnored private var historyToken: String?
    /// The token from before a history refresh, put back when the refresh fails so scrolling still loads more.
    @ObservationIgnored private var historyTokenBeforeRefresh: String?
    @ObservationIgnored private var libraryRuns: [MusicLibrarySection: Int] = [:]
    @ObservationIgnored private var libraryTokens: [MusicLibrarySection: String] = [:]
    @ObservationIgnored private var pageRuns: [String: Int] = [:]
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    /// The last sorted page per playlist, so reading it again while a song plays does not sort again.
    @ObservationIgnored private var sortedPages: [String: (sort: MusicPlaylistSort, page: MusicBrowsePage)] = [:]
    /// Told when a call says the session is gone, so the service can sign out.
    @ObservationIgnored var onSessionExpired: (@MainActor () -> Void)?
    /// Told when a page lands, with the page and the collection on the path that opened it, so the service can keep a
    /// pinned item's name and photo current. Not told for a page that was closed, reloaded or reset before it landed.
    @ObservationIgnored var onPageLoaded: (@MainActor (MusicBrowsePage, MusicCollection?) -> Void)?

    init(backend: any MusicBackend, connectivity: MusicConnectivity? = nil, downloads: MusicDownloadService? = nil) {
        self.backend = backend
        self.connectivity = connectivity
        self.downloads = downloads
        connectivity?.observe { [weak self] online in self?.connectivityChanged(online) }
        // A load that failed for the network before the system's first word waits for it; an online word runs what
        // waited. An offline word leaves them waiting for the network to return, as any other offline does.
        connectivity?.observeFirstReport { [weak self] online in
            if online { self?.connectivityChanged(true) }
        }
    }

    func libraryState(_ section: MusicLibrarySection) -> Load<[MusicCollection]> {
        library[section] ?? .idle
    }

    /// What a library list holds once it has loaded; nil while it is idle, loading or failed.
    func loadedLibrary(_ section: MusicLibrarySection) -> [MusicCollection]? {
        if case .loaded(let items) = libraryState(section) { items } else { nil }
    }

    func pageState(_ browseId: String) -> Load<MusicBrowsePage> {
        if browseId == MusicDownloadService.songsBrowseId { return .loaded(downloadedSongsPage()) }
        return pages[browseId] ?? .idle
    }

    // MARK: - Offline

    /// Whether the account is gone (signed out), as the service answers it; nil reads as never. What the closure reads is
    /// observable, so what reads `isOffline` redraws when the account goes and when it returns.
    @ObservationIgnored var accountGone: (@MainActor () -> Bool)?

    /// True while the network is down. Observable.
    var isNetworkDown: Bool {
        guard let connectivity else { return false }
        return !connectivity.isOnline
    }

    /// The system has not said yet whether there is a network (the first report of the path monitor comes a moment after
    /// launch), so a load that fails for the network may only have started on a path that was already gone. Such a load
    /// waits for the first report instead of failing; once it has come a failure is a failure.
    private var pathDoubt: Bool {
        guard let connectivity else { return false }
        return !connectivity.hasReported
    }

    /// Whether `error` is the network failing while the path is still in doubt: the load waits, it does not fail.
    private func cutByDoubtfulPath(_ error: any Error) -> Bool {
        pathDoubt && MusicConnectivity.isNetworkFailure(error)
    }

    /// The account is gone while the network is up: a signed-out listener, who can sign in, as opposed to one who is
    /// offline, who cannot. Offline notes then say signed out and carry the Sign in button.
    var offersSignIn: Bool {
        !isNetworkDown && accountGone?() == true
    }

    /// Only the downloads can be shown: the network is down, or there is no account to ask it with. Both read the same
    /// way: lists are not asked for, pages of downloaded collections are built from the index, songs that are not downloaded
    /// are dimmed and do not play.
    var isOffline: Bool {
        isNetworkDown || accountGone?() == true
    }

    /// The account came back (a sign-in finished): what was held back while it was gone runs, as it does when the network
    /// returns, unless the network is still down.
    func accountReturned() {
        guard !isOffline else { return }
        connectivityChanged(true)
    }

    /// Whether a song can play with no network: it is downloaded. Online every song can, as far as the network goes.
    /// Offline, the rows of the others are dimmed and do not play.
    func isDimmed(_ videoId: String) -> Bool {
        guard isOffline else { return false }
        guard let downloads else { return true }
        if case .downloaded = downloads.state(for: videoId) { return false }
        return true
    }

    /// The line that stands in for a feed or a page the network would fill, or nil when it should show as usual. Home and
    /// History show it offline whatever they hold (what was loaded is kept for when the network returns); a page shows it
    /// offline unless it is loaded or loading, which includes the pages built from the download index.
    /// The words depend on why: the network down says offline; the account gone with the network up says signed out.
    func offlineNote(for surface: MusicOfflineSurface) -> String? {
        guard isOffline else { return nil }
        let note = isNetworkDown ? MusicOfflineCopy.note : MusicOfflineCopy.signedOutNote
        switch surface {
        case .home, .history:
            return note
        case .page(let browseId):
            switch pageState(browseId) {
            case .idle, .failed: return note
            case .loading, .loaded: return nil
            }
        }
    }

    // MARK: - Downloads

    /// The pinned row of the Downloads tab: the reserved id, and the number of songs for a subtitle.
    var downloadedSongsRow: MusicCollection {
        MusicCollection(
            browseId: Self.downloadedSongs.browseId, kind: .playlist, title: Self.downloadedSongs.title,
            subtitle: MusicDownloadService.songCountText(downloads?.downloadedSongCount ?? 0), thumbnailURL: nil
        )
    }

    /// The downloaded playlists and albums under the pinned row, newest download first. A collection still downloading
    /// shows how far it has got in its subtitle.
    var downloadedCollectionRows: [MusicCollection] {
        (downloads?.downloadedCollections ?? []).map(Self.row(of:))
    }

    /// The browse ids of `downloadedCollectionRows`, in the same order, read without any download state. A list lays its
    /// rows out from these and each row reads its own (`downloadedCollectionRow`), so a download's progress redraws that
    /// row and not the list.
    var downloadedCollectionIds: [String] {
        downloads?.downloadedCollectionIds ?? []
    }

    /// One row of `downloadedCollectionRows`; nil when the collection is gone.
    func downloadedCollectionRow(_ browseId: String) -> MusicCollection? {
        downloads?.downloadedCollection(browseId: browseId).map(Self.row(of:))
    }

    private static func row(of collection: MusicDownloadedCollection) -> MusicCollection {
        MusicCollection(
            browseId: collection.browseId,
            kind: collection.kind == .album ? .album : .playlist,
            title: collection.title,
            subtitle: collection.subtitle,
            thumbnailURL: collection.thumbnailURL
        )
    }

    /// Whether there is anything to list on the Downloads tab: a downloaded song, or a collection downloaded or on its way.
    var hasDownloads: Bool {
        guard let downloads else { return false }
        return downloads.downloadedSongCount > 0 || !downloads.downloadedCollectionIds.isEmpty
    }

    /// The saved picture for a cover address, nil when none was saved (or no downloads here).
    func localCoverURL(for address: URL?) -> URL? {
        downloads?.localCoverURL(for: address)
    }

    /// The Downloaded songs page, read from the index each time (nothing of it is stored here, so it is current).
    private func downloadedSongsPage() -> MusicBrowsePage {
        downloads?.downloadedSongsPage() ?? MusicBrowsePage(
            browseId: MusicDownloadService.songsBrowseId, title: MusicDownloadService.songsTitle,
            subtitle: MusicDownloadService.songCountText(0), thumbnailURL: nil, tracks: [], continuation: nil, shelves: []
        )
    }

    // MARK: - Library tabs

    /// The tab Library shows. Offline it is Downloads, whatever was picked; online the last pick returns.
    var libraryTab: MusicLibraryTab {
        if isOffline || downloadsPicked { return .downloads }
        return MusicLibraryTab(pickedSection)
    }

    /// Offline the Playlists and Albums pills are disabled: their lists need the network.
    func isLibraryTabEnabled(_ tab: MusicLibraryTab) -> Bool {
        !isOffline || tab == .downloads
    }

    /// Picks a tab. Offline nothing changes: Downloads is already shown, and the pick that was made before the network
    /// went is kept for when it returns.
    func selectLibraryTab(_ tab: MusicLibraryTab) {
        guard !isOffline else { return }
        if let section = tab.section {
            librarySection = section
        } else {
            downloadsPicked = true
        }
    }

    /// The network went or came back. Coming back runs everything that was held back, once, unless the account is still
    /// gone: then nothing runs and nothing is forgotten, and the sign-in (`accountReturned`) runs it.
    private func connectivityChanged(_ online: Bool) {
        guard online, !isOffline else { return }
        if waitingHome {
            waitingHome = false
            loadHomeIfNeeded()
        }
        if waitingHistory {
            waitingHistory = false
            loadHistoryIfNeeded()
        }
        let sections = waitingLibrary
        waitingLibrary.removeAll()
        for section in MusicLibrarySection.allCases where sections.contains(section) { loadLibraryIfNeeded(section) }
        // A page that was built from the index is replaced by the network's, which is the fuller one, once that has
        // arrived: the stored page stays up meanwhile, so the list does not turn into a spinner under the listener.
        let stored = storedPages
        storedPages.removeAll()
        for browseId in stored.sorted() where pages[browseId] != nil { refreshStoredPage(browseId) }
        let waiting = waitingPages
        waitingPages.removeAll()
        for browseId in waiting.sorted() where path.contains(where: { $0.browseId == browseId }) {
            switch pageState(browseId) {
            case .idle, .failed: reloadPage(browseId)
            case .loading, .loaded: break
            }
        }
    }

    // MARK: - Home

    /// Loads Home when it has not loaded yet or the last try failed.
    func loadHomeIfNeeded() {
        switch home {
        case .idle, .failed: reloadHome()
        case .loading, .loaded: break
        }
    }

    /// Loads Home again from the top. Offline nothing is asked: Home that has not loaded waits for the network, and one that
    /// has keeps what it shows.
    func reloadHome() {
        guard !isOffline else {
            if !isLoaded(home) { waitingHome = true }
            return
        }
        // Cut by a path in doubt: the first report decides, so a view that asks again as Home lands idle starts no loop.
        if pathDoubt, waitingHome { return }
        let run = newRun()
        homeRun = run
        homeToken = nil
        home = .loading
        isLoadingMoreHome = false
        canLoadMoreHome = false
        isRefreshingHome = false
        launch("home") { [weak self, backend] in
            do {
                let page = try await backend.home()
                self?.landHome(page, run: run)
            } catch {
                self?.failHome(error, run: run)
            }
        }
    }

    /// Asks for Home again while the shelves stay up, so new suggestions replace them in place. A failure keeps
    /// the old shelves. Loads from the top when nothing is up yet.
    func refreshHome() {
        guard case .loaded = home else { return reloadHome() }
        guard !isRefreshingHome, !isOffline else { return }
        let run = newRun()
        homeRun = run
        tokenBeforeRefresh = homeToken
        homeToken = nil
        tasks["home+"]?.cancel()
        isLoadingMoreHome = false
        canLoadMoreHome = false
        isRefreshingHome = true
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
        guard case .loaded = home, let run = homeRun, let token = homeToken, !isLoadingMoreHome, !isOffline else { return }
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
        if isRefreshingHome { homeRefreshes += 1 }
        isRefreshingHome = false
        tokenBeforeRefresh = nil
        let shelves = Self.uniqueShelves(page.shelves, after: [])
        home = .loaded(shelves)
        homeToken = page.continuation
        canLoadMoreHome = page.continuation != nil
        // A page of only hidden shelves leaves nothing to scroll to the end of, so ask for the next one here.
        if shelves.isEmpty { loadMoreHome() }
    }

    private func failHome(_ error: any Error, run: Int) {
        guard homeRun == run else { return }
        if isRefreshingHome {
            isRefreshingHome = false
            homeToken = tokenBeforeRefresh
            tokenBeforeRefresh = nil
            canLoadMoreHome = homeToken != nil
            logger.info("home refresh failed: \(MusicService.logDescription(of: error), privacy: .public)")
        } else if cutByDoubtfulPath(error) {
            home = .idle
            waitingHome = true
        } else {
            home = .failed(describe(error))
            // Cut by the network going: asked for again when it returns.
            if isOffline { waitingHome = true }
        }
        expireIfSignedOut(error)
    }

    private func landMoreHome(_ page: MusicHomePage, run: Int, token: String) {
        guard homeRun == run, case .loaded(let shelves) = home else { return }
        isLoadingMoreHome = false
        let added = Self.uniqueShelves(page.shelves, after: shelves)
        home = .loaded(shelves + added)
        // The same token again would ask for the same page forever.
        homeToken = page.continuation == token ? nil : page.continuation
        canLoadMoreHome = homeToken != nil
        // Nothing new to show (all hidden or seen): the end of the list was already reached, so go on from here.
        if added.isEmpty { loadMoreHome() }
    }

    /// A failed extra page leaves the shelves as they are; scrolling to the end tries again.
    private func failMoreHome(_ error: any Error, run: Int) {
        guard homeRun == run else { return }
        isLoadingMoreHome = false
        logger.info("more home failed: \(MusicService.logDescription(of: error), privacy: .public)")
        expireIfSignedOut(error)
    }

    /// Drops shelves already on screen and the hidden ones.
    private static func uniqueShelves(_ shelves: [MusicShelf], after existing: [MusicShelf]) -> [MusicShelf] {
        newShelves(shelves.filter { !isHiddenHomeShelf($0) }, after: existing)
    }

    /// Drops shelves already on screen, and repeats within `shelves`.
    private static func newShelves(_ shelves: [MusicShelf], after existing: [MusicShelf]) -> [MusicShelf] {
        var seen = Set(existing.map(\.id))
        return shelves.filter { seen.insert($0.id).inserted }
    }

    static func isHiddenHomeShelf(_ shelf: MusicShelf) -> Bool {
        hiddenHomeShelfTitles.contains(shelf.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    // MARK: - History

    /// Loads History when it has not loaded yet or the last try failed.
    func loadHistoryIfNeeded() {
        switch history {
        case .idle, .failed: reloadHistory()
        case .loading, .loaded: break
        }
    }

    /// Loads History again from the top. Offline nothing is asked, as with Home.
    func reloadHistory() {
        guard !isOffline else {
            if !isLoaded(history) { waitingHistory = true }
            return
        }
        if pathDoubt, waitingHistory { return }
        let run = newRun()
        historyRun = run
        historyToken = nil
        history = .loading
        isLoadingMoreHistory = false
        canLoadMoreHistory = false
        isRefreshingHistory = false
        launchHistory(run: run)
    }

    /// For when the tab is opened: asks for History again while the list stays up, so a song played since shows
    /// at the top. A failure keeps the old list. Loads from the top when nothing is up yet, and does nothing
    /// while the first load is still coming.
    func refreshHistory() {
        switch history {
        case .idle, .failed:
            return reloadHistory()
        case .loading:
            return
        case .loaded:
            guard !isRefreshingHistory, !isOffline else { return }
        }
        let run = newRun()
        historyRun = run
        historyTokenBeforeRefresh = historyToken
        historyToken = nil
        tasks["history+"]?.cancel()
        isLoadingMoreHistory = false
        canLoadMoreHistory = false
        isRefreshingHistory = true
        launchHistory(run: run)
    }

    private func launchHistory(run: Int) {
        launch("history") { [weak self, backend] in
            do {
                let page = try await backend.history()
                self?.landHistory(page, run: run)
            } catch {
                self?.failHistory(error, run: run)
            }
        }
    }

    /// Loads the next days when the list scrolls to its end.
    func loadMoreHistory() {
        guard case .loaded = history, let run = historyRun, let token = historyToken, !isLoadingMoreHistory, !isOffline else { return }
        isLoadingMoreHistory = true
        launch("history+") { [weak self, backend] in
            do {
                let page = try await backend.moreHistory(continuation: token)
                self?.landMoreHistory(page, run: run, token: token)
            } catch {
                self?.failMoreHistory(error, run: run)
            }
        }
    }

    private func landHistory(_ page: MusicHomePage, run: Int) {
        guard historyRun == run else { return }
        isRefreshingHistory = false
        historyTokenBeforeRefresh = nil
        let shelves = Self.newShelves(page.shelves, after: [])
        history = .loaded(shelves)
        historyToken = page.continuation
        canLoadMoreHistory = page.continuation != nil
        // A page with no days but a next page leaves nothing to scroll to the end of, so ask for it here.
        if shelves.isEmpty { loadMoreHistory() }
    }

    private func failHistory(_ error: any Error, run: Int) {
        guard historyRun == run else { return }
        if isRefreshingHistory {
            isRefreshingHistory = false
            historyToken = historyTokenBeforeRefresh
            historyTokenBeforeRefresh = nil
            canLoadMoreHistory = historyToken != nil
            logger.info("history refresh failed: \(MusicService.logDescription(of: error), privacy: .public)")
        } else if cutByDoubtfulPath(error) {
            history = .idle
            waitingHistory = true
        } else {
            history = .failed(describe(error))
            if isOffline { waitingHistory = true }
        }
        expireIfSignedOut(error)
    }

    private func landMoreHistory(_ page: MusicHomePage, run: Int, token: String) {
        guard historyRun == run, case .loaded(let shelves) = history else { return }
        isLoadingMoreHistory = false
        let added = Self.newShelves(page.shelves, after: shelves)
        history = .loaded(shelves + added)
        // The same token again would ask for the same page forever.
        historyToken = page.continuation == token ? nil : page.continuation
        canLoadMoreHistory = historyToken != nil
        // Nothing new to show (all seen): the end of the list was already reached, so go on from here.
        if added.isEmpty { loadMoreHistory() }
    }

    /// A failed extra page leaves the days as they are; scrolling to the end tries again.
    private func failMoreHistory(_ error: any Error, run: Int) {
        guard historyRun == run else { return }
        isLoadingMoreHistory = false
        logger.info("more history failed: \(MusicService.logDescription(of: error), privacy: .public)")
        expireIfSignedOut(error)
    }

    // MARK: - Library

    func loadLibraryIfNeeded(_ section: MusicLibrarySection) {
        switch libraryState(section) {
        case .idle, .failed: reloadLibrary(section)
        case .loading, .loaded: break
        }
    }

    func reloadLibrary(_ section: MusicLibrarySection) {
        guard !isOffline else {
            if !isLoaded(libraryState(section)) { waitingLibrary.insert(section) }
            return
        }
        if pathDoubt, waitingLibrary.contains(section) { return }
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
              let token = libraryTokens[section], !loadingMoreLibrary.contains(section), !isOffline else { return }
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
        if cutByDoubtfulPath(error) {
            library[section] = .idle
            waitingLibrary.insert(section)
            return
        }
        library[section] = .failed(describe(error))
        if isOffline { waitingLibrary.insert(section) }
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
        // The Downloaded songs page is no page of YouTube Music: it is read from the index and its id goes nowhere.
        guard browseId != MusicDownloadService.songsBrowseId else { return }
        guard !isOffline else { return showStoredOrWait(browseId) }
        if pathDoubt, waitingPages.contains(browseId) || storedPages.contains(browseId) { return }
        storedPages.remove(browseId)
        waitingPages.remove(browseId)
        let run = newRun()
        pageRuns[browseId] = run
        pages[browseId] = .loading
        loadingMoreTracks.remove(browseId)
        loadingAllTracks.remove(browseId)
        sortedPages[browseId] = nil
        forgetReleaseYears(browseId)
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
              !loadingAllTracks.contains(browseId), !isOffline else { return }
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
        loadAllTracksIfReordering(browseId)
        loadReleaseYearsIfNeeded(browseId)
        onPageLoaded?(page, path.last { $0.browseId == browseId })
    }

    /// The network's page for one that the download index is showing. The stored page stays up while it is out (the
    /// list keeps its place) and is swapped for the network's only when it lands. A failure leaves the stored page up
    /// and keeps the page in line for the next time the network returns.
    private func refreshStoredPage(_ browseId: String) {
        guard browseId != MusicDownloadService.songsBrowseId else { return }
        guard isLoaded(pageState(browseId)) else { return reloadPage(browseId) }
        waitingPages.remove(browseId)
        let run = newRun()
        pageRuns[browseId] = run
        launch("page:\(browseId)") { [weak self, backend] in
            do {
                let page = try await backend.page(browseId: browseId)
                self?.landRefreshedPage(page, browseId: browseId, run: run)
            } catch {
                self?.failRefreshedPage(error, browseId: browseId, run: run)
            }
        }
    }

    private func landRefreshedPage(_ page: MusicBrowsePage, browseId: String, run: Int) {
        guard pageRuns[browseId] == run else { return }
        loadingMoreTracks.remove(browseId)
        loadingAllTracks.remove(browseId)
        sortedPages[browseId] = nil
        forgetReleaseYears(browseId)
        landPage(page, browseId: browseId, run: run)
    }

    private func failRefreshedPage(_ error: any Error, browseId: String, run: Int) {
        guard pageRuns[browseId] == run else { return }
        logger.info("stored page refresh failed: \(MusicService.logDescription(of: error), privacy: .public)")
        pageRuns[browseId] = nil
        storedPages.insert(browseId)
        expireIfSignedOut(error)
    }

    private func failPage(_ error: any Error, browseId: String, run: Int) {
        guard pageRuns[browseId] == run else { return }
        if cutByDoubtfulPath(error) {
            // The downloaded collection's own page when there is one, else nothing and a wait for the first report.
            return showStoredOrWait(browseId)
        }
        pages[browseId] = .failed(describe(error))
        if isOffline { waitingPages.insert(browseId) }
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
            audioPlaylistId: page.audioPlaylistId,
            allSongsBrowseId: page.allSongsBrowseId,
            discographyLinks: page.discographyLinks
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
            audioPlaylistId: page.audioPlaylistId,
            allSongsBrowseId: page.allSongsBrowseId,
            discographyLinks: page.discographyLinks
        ))
        return true
    }

    // MARK: - Sorting

    /// Only playlist pages sort; albums keep their track order and artists have no list of songs to sort.
    static func canSort(_ browseId: String) -> Bool {
        browseId.hasPrefix("VL")
    }

    /// The sort of a playlist that has none picked: Date added with the newest song first on a playlist the user made
    /// and on Liked music, else Playlist order. Whether a playlist is the user's is told by its page, so one that has
    /// not landed yet rests on Playlist order, except Liked music, which is known by its browse id.
    private func restingSort(for browseId: String) -> MusicPlaylistSort {
        guard Self.canSort(browseId) else { return .playlistOrder }
        if listsNewestFirst(browseId) { return .dateAddedNewestFirst }
        if case .loaded(let page)? = pages[browseId], page.isEditable { return .dateAddedNewestFirst }
        return .playlistOrder
    }

    /// Whether YouTube lists the playlist with its newest song first. Liked music is the one that does; every other
    /// playlist adds a new song at its end.
    private func listsNewestFirst(_ browseId: String) -> Bool {
        browseId == Self.likedMusic.browseId
    }

    /// The sort of this playlist: the one picked, else where it rests. A pick the page's menu does not offer rests
    /// instead, so Plays picked on an artist's songs never follows the same id opened as a plain playlist.
    func sort(for browseId: String) -> MusicPlaylistSort {
        if let picked = sorts[browseId], sortOptions(for: browseId).contains(picked.field) { return picked }
        return restingSort(for: browseId)
    }

    /// Whether the sort puts the songs in another order than YouTube lists them. Only then do all the songs have to be
    /// loaded before the list shows them in order; a playlist in YouTube's order, Liked music at rest among them,
    /// shows its songs as they come.
    func needsReorder(_ browseId: String) -> Bool {
        sort(for: browseId).reorders(newestFirst: listsNewestFirst(browseId))
    }

    /// Whether the list has to wait: the sort reorders the songs and the rest of them are still loading, so showing
    /// the songs loaded so far would show an order that changes as the pages land.
    func isOrderPending(_ browseId: String) -> Bool {
        (loadingAllTracks.contains(browseId) && needsReorder(browseId)) || waitsForReleaseYears(browseId)
    }

    /// Whether Release date is picked and the years it sorts by are still being read.
    private func waitsForReleaseYears(_ browseId: String) -> Bool {
        loadingReleaseYears.contains(browseId) && sort(for: browseId).field == .releaseDate
    }

    /// Whether the page is an artist's list of all their songs, as the collection that opened it says. The latest one
    /// opened on the path counts, and a page that is not on it is a plain playlist.
    func isArtistSongs(_ browseId: String) -> Bool {
        path.last { $0.browseId == browseId }?.isArtistSongs ?? false
    }

    /// The options the page's sort menu offers: an artist's songs list has Popular, Album, Release date and Plays, any other
    /// playlist and Liked music the usual ones.
    func sortOptions(for browseId: String) -> [MusicSortField] {
        MusicSortField.options(artistSongs: isArtistSongs(browseId))
    }

    /// Picks a sort option for a playlist: a new option sorts ascending (Date added, newest first; Plays, most played
    /// first), the same one again flips the direction, and Playlist order is stored as a pick too, so a playlist that
    /// rests on Date added stays in YouTube's order once the user asks for it. An option the page's menu does not offer
    /// is ignored. A sort that reorders first loads every remaining page of songs (up to `sortTrackCap`), and the
    /// list waits for them.
    func pickSort(_ field: MusicSortField, for browseId: String) {
        guard Self.canSort(browseId), sortOptions(for: browseId).contains(field) else { return }
        sorts[browseId] = sort(for: browseId).picking(field)
        sortedPages[browseId] = nil
        loadAllTracksIfReordering(browseId)
        loadReleaseYearsIfNeeded(browseId)
    }

    /// The page as the list shows it and as Play queues it: in the playlist's sort once all its songs are here
    /// (with no more to load, so a queue made from it ends where the sorted list does), else as loaded.
    func displayedPage(_ browseId: String) -> MusicBrowsePage? {
        guard case .loaded(let page) = pageState(browseId) else { return nil }
        let sort = sort(for: browseId)
        guard needsReorder(browseId), !loadingAllTracks.contains(browseId), !waitsForReleaseYears(browseId) else { return page }
        if let cached = sortedPages[browseId], cached.sort == sort { return cached.page }
        let sorted = MusicBrowsePage(
            browseId: page.browseId,
            title: page.title,
            subtitle: page.subtitle,
            thumbnailURL: page.thumbnailURL,
            tracks: sort.sorted(
                Array(page.tracks.prefix(Self.sortTrackCap)),
                newestFirst: listsNewestFirst(browseId),
                releaseYears: releaseYears[browseId] ?? .empty
            ),
            continuation: nil,
            shelves: page.shelves,
            isEditable: page.isEditable,
            audioPlaylistId: page.audioPlaylistId,
            allSongsBrowseId: page.allSongsBrowseId,
            discographyLinks: page.discographyLinks
        )
        sortedPages[browseId] = (sort, sorted)
        return sorted
    }

    /// How many songs a sort covers when that is only the start of a longer playlist: the loading stopped at the cap,
    /// or gave up on pages that went nowhere. Nil when the sort covers every song, when the songs stay in YouTube's
    /// order, and while the songs are still loading.
    func sortedSongLimit(_ browseId: String) -> Int? {
        guard needsReorder(browseId), !loadingAllTracks.contains(browseId),
              case .loaded(let page)? = pages[browseId] else { return nil }
        guard page.continuation != nil || page.tracks.count > Self.sortTrackCap else { return nil }
        return min(page.tracks.count, Self.sortTrackCap)
    }

    /// Starts loading what is left of a playlist whose sort reorders its songs, unless it is all here already or
    /// loading has started.
    private func loadAllTracksIfReordering(_ browseId: String) {
        guard needsReorder(browseId), case .loaded(let page)? = pages[browseId], let run = pageRuns[browseId],
              page.continuation != nil, page.tracks.count < Self.sortTrackCap,
              !loadingAllTracks.contains(browseId), !isOffline else { return }
        loadingAllTracks.insert(browseId)
        launch("page*:\(browseId)") { [weak self] in
            await self?.loadRemainingTracks(browseId, run: run)
        }
    }

    /// Fetches page after page while the playlist's sort reorders its songs and it has more, up to the cap. A page that
    /// is already loading for the list footer is waited for, not asked for twice. A failure goes back to Playlist
    /// order, picked rather than at rest, so the playlist does not start the load again.
    /// Three more ways end it with what is loaded, so a chain that never ends cannot keep the sort loading: pages
    /// that bring no new song several times in a row, a continuation that comes round again, and a ceiling on pages.
    private func loadRemainingTracks(_ browseId: String, run: Int) async {
        var seenTokens = Set<String>()
        var emptyPagesInARow = 0
        var pagesAsked = 0
        while pageRuns[browseId] == run, needsReorder(browseId),
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
                sorts[browseId] = .playlistOrder
                sortedPages[browseId] = nil
                loadingAllTracks.remove(browseId)
                expireIfSignedOut(error)
                return
            }
        }
        guard pageRuns[browseId] == run else { return }
        // A playlist at rest on Date added that stopped short would show its oldest songs as its newest: it goes back
        // to Playlist order, where the footer still reaches every song.
        if sorts[browseId] == nil, case .loaded(let page)? = pages[browseId],
           page.continuation != nil || page.tracks.count > Self.sortTrackCap {
            sorts[browseId] = .playlistOrder
            sortedPages[browseId] = nil
        }
        loadingAllTracks.remove(browseId)
    }

    /// Starts reading the release years of an artist's songs list once, when its sort is Release date: the albums on the
    /// artist page's shelves give a first set at once, and each discography page the artist page links to adds more. A
    /// songs list opened with no artist page behind it, or one whose page links none, sorts by the shelves' albums alone.
    /// A discography page that fails is logged and left out until the next pick of Release date asks again.
    private func loadReleaseYearsIfNeeded(_ browseId: String) {
        guard sort(for: browseId).field == .releaseDate, releaseYears[browseId]?.isComplete != true,
              !loadingReleaseYears.contains(browseId), let run = pageRuns[browseId], !isOffline else { return }
        let artist = artistPage(listing: browseId)
        var seed = MusicReleaseYears()
        seed.add((artist?.shelves ?? []).flatMap(\.items).compactMap { item in
            if case .collection(let collection) = item, collection.kind == .album { collection } else { nil }
        })
        let links = artist?.discographyLinks ?? []
        sortedPages[browseId] = nil
        guard !links.isEmpty else {
            releaseYears[browseId] = seed
            return
        }
        loadingReleaseYears.insert(browseId)
        launch("years:\(browseId)") { [weak self, backend] in
            let answers = await withTaskGroup(of: (Int, Result<[MusicCollection], any Error>).self) { group in
                for (index, link) in links.enumerated() {
                    group.addTask {
                        do {
                            return (index, .success(try await backend.discography(browseId: link.browseId, params: link.params)))
                        } catch {
                            return (index, .failure(error))
                        }
                    }
                }
                var collected: [(Int, Result<[MusicCollection], any Error>)] = []
                for await answer in group { collected.append(answer) }
                return collected.sorted { $0.0 < $1.0 }.map { $0.1 }
            }
            self?.landReleaseYears(answers, seed: seed, browseId: browseId, run: run)
        }
    }

    private func landReleaseYears(_ answers: [Result<[MusicCollection], any Error>], seed: MusicReleaseYears, browseId: String, run: Int) {
        guard pageRuns[browseId] == run else { return }
        var years = seed
        var signedOut = false
        for answer in answers {
            switch answer {
            case .success(let albums):
                years.add(albums)
            case .failure(let error):
                logger.info("release years failed: \(MusicService.logDescription(of: error), privacy: .public)")
                years.isComplete = false
                signedOut = signedOut || (error as? MusicError) == .signedOut
            }
        }
        releaseYears[browseId] = years
        loadingReleaseYears.remove(browseId)
        sortedPages[browseId] = nil
        // Once, and last: signing out resets this store.
        if signedOut { expireIfSignedOut(MusicError.signedOut) }
    }

    /// The loaded artist page whose Top songs link opens this songs list.
    private func artistPage(listing songsBrowseId: String) -> MusicBrowsePage? {
        for case .loaded(let page) in pages.values where page.allSongsBrowseId == songsBrowseId { return page }
        return nil
    }

    /// Forgets the years and the work reading them, so a reopened or reloaded page reads them again and a late answer
    /// finds nothing to land on.
    private func forgetReleaseYears(_ browseId: String) {
        tasks.removeValue(forKey: "years:\(browseId)")?.cancel()
        releaseYears[browseId] = nil
        loadingReleaseYears.remove(browseId)
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

    /// Drops pages that were loaded without being opened (a search asked for them), with the guard `drop` has: one that
    /// is on the path stays.
    func dropPages(_ browseIds: some Sequence<String>) {
        for browseId in browseIds { drop(browseId) }
    }

    /// A closed page is dropped unless it is still further down the path, so opening it again
    /// fetches it fresh (a song just liked shows in Liked music) and closed pages do not pile up.
    private func drop(_ browseId: String) {
        guard !path.contains(where: { $0.browseId == browseId }) else { return }
        for key in ["page:\(browseId)", "page+:\(browseId)", "page*:\(browseId)"] { tasks.removeValue(forKey: key)?.cancel() }
        pageRuns[browseId] = nil
        pages[browseId] = nil
        storedPages.remove(browseId)
        waitingPages.remove(browseId)
        loadingMoreTracks.remove(browseId)
        loadingAllTracks.remove(browseId)
        sortedPages[browseId] = nil
        forgetReleaseYears(browseId)
    }

    // MARK: - Reset

    /// Drops everything loaded: on sign-out and after a channel switch (the library is per channel).
    /// The selected tab and library section are the user's choice, not loaded data, and stay.
    func reset() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        homeRun = nil
        homeToken = nil
        historyRun = nil
        historyToken = nil
        libraryRuns.removeAll()
        libraryTokens.removeAll()
        pageRuns.removeAll()
        waitingHome = false
        waitingHistory = false
        waitingLibrary.removeAll()
        waitingPages.removeAll()
        storedPages.removeAll()
        home = .idle
        isLoadingMoreHome = false
        canLoadMoreHome = false
        isRefreshingHome = false
        tokenBeforeRefresh = nil
        history = .idle
        isLoadingMoreHistory = false
        canLoadMoreHistory = false
        isRefreshingHistory = false
        historyTokenBeforeRefresh = nil
        library.removeAll()
        loadingMoreLibrary.removeAll()
        libraryHasMore.removeAll()
        path.removeAll()
        pages.removeAll()
        loadingMoreTracks.removeAll()
        loadingAllTracks.removeAll()
        sorts.removeAll()
        sortedPages.removeAll()
        releaseYears.removeAll()
        loadingReleaseYears.removeAll()
    }

    // MARK: - Helpers

    private func isLoaded<Value>(_ load: Load<Value>) -> Bool {
        if case .loaded = load { true } else { false }
    }

    /// A page opened with no network: the downloaded collection's own page, built from the index, or nothing (the page
    /// shows the offline note) and a wait for the network. Nothing is sent, and a page that already shows is left alone.
    private func showStoredOrWait(_ browseId: String) {
        if isLoaded(pageState(browseId)) { return }
        if let page = downloads?.downloadedPage(browseId: browseId) {
            pages[browseId] = .loaded(page)
            pageRuns[browseId] = nil
            storedPages.insert(browseId)
            waitingPages.remove(browseId)
        } else {
            pages[browseId] = nil
            waitingPages.insert(browseId)
        }
    }

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
