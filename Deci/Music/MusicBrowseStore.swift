// Deci/Music/MusicBrowseStore.swift
import Foundation
import Observation

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
    func loadHomeIfNeeded() {}

    /// Loads Home again from the top.
    func reloadHome() {}

    /// Loads the next shelves when the list scrolls to its end.
    func loadMoreHome() {}

    // MARK: - Library

    func loadLibraryIfNeeded(_ section: MusicLibrarySection) {}

    func reloadLibrary(_ section: MusicLibrarySection) {}

    /// Loads the next page of a library list when it scrolls to its end.
    func loadMoreLibrary(_ section: MusicLibrarySection) {}

    // MARK: - Pages

    /// Pushes the page and loads it unless it is already loaded.
    func open(_ collection: MusicCollection) {}

    func reloadPage(_ browseId: String) {}

    /// Loads more tracks of a long playlist when its list scrolls to its end.
    func loadMoreTracks(_ browseId: String) {}

    /// Back one page.
    func back() {}

    /// Back to the tab's root.
    func popToRoot() {}

    /// Drops everything loaded: on sign-out and after a channel switch (the library is per channel).
    func reset() {}
}
