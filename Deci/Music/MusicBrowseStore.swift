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
    enum Tab: Hashable {
        case home
        case library
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
    /// Told when a call says the session is gone, so the service can sign out.
    @ObservationIgnored var onSessionExpired: (@MainActor () -> Void)?

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
              let token = page.continuation, !loadingMoreTracks.contains(browseId) else { return }
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
    }

    private func failPage(_ error: any Error, browseId: String, run: Int) {
        guard pageRuns[browseId] == run else { return }
        pages[browseId] = .failed(describe(error))
        expireIfSignedOut(error)
    }

    private func landMoreTracks(_ more: MusicQueuePage, browseId: String, run: Int, token: String) {
        guard pageRuns[browseId] == run, case .loaded(let page)? = pages[browseId] else { return }
        loadingMoreTracks.remove(browseId)
        var seen = Set(page.tracks.map(\.videoId))
        let fresh = more.tracks.filter { seen.insert($0.videoId).inserted }
        pages[browseId] = .loaded(MusicBrowsePage(
            browseId: page.browseId,
            title: page.title,
            subtitle: page.subtitle,
            thumbnailURL: page.thumbnailURL,
            tracks: page.tracks + fresh,
            continuation: more.continuation == token ? nil : more.continuation,
            shelves: page.shelves
        ))
    }

    private func failMoreTracks(_ error: any Error, browseId: String, run: Int) {
        guard pageRuns[browseId] == run else { return }
        loadingMoreTracks.remove(browseId)
        logger.info("more tracks failed: \(MusicService.logDescription(of: error), privacy: .public)")
        expireIfSignedOut(error)
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
        for key in ["page:\(browseId)", "page+:\(browseId)"] { tasks.removeValue(forKey: key)?.cancel() }
        pageRuns[browseId] = nil
        pages[browseId] = nil
        loadingMoreTracks.remove(browseId)
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
