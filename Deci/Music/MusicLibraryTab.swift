// Deci/Music/MusicLibraryTab.swift
// The three tabs of Library. Playlists and Albums are the two lists the account holds (`MusicLibrarySection`, loaded from
// YouTube Music); Downloads is the third and is read from the download index, so it works with no network and signed out.

import Foundation

nonisolated enum MusicLibraryTab: Hashable, CaseIterable, Sendable {
    case playlists
    case albums
    case downloads

    init(_ section: MusicLibrarySection) {
        switch section {
        case .playlists: self = .playlists
        case .albums: self = .albums
        }
    }

    /// The account list the tab shows; nil for Downloads, which is no list of the account's.
    var section: MusicLibrarySection? {
        switch self {
        case .playlists: .playlists
        case .albums: .albums
        case .downloads: nil
        }
    }

    var title: String {
        switch self {
        case .playlists: "Playlists"
        case .albums: "Albums"
        case .downloads: "Downloads"
        }
    }
}
