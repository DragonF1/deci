// Deci/Music/Downloads/MusicCollectionEnumerator.swift
import Foundation

/// What downloading a whole playlist or album asks of the backend, as closures so tests serve pages from memory and the
/// service never holds the backend itself.
struct MusicCollectionSource: Sendable {
    let page: @Sendable (String) async throws -> MusicBrowsePage
    let moreTracks: @Sendable (String, String) async throws -> MusicQueuePage
    let isSignedIn: @Sendable () async -> Bool
    /// The key of the signed-in channel, nil when signed out or when the session does not say.
    let identity: @Sendable () async -> String?

    init(
        page: @escaping @Sendable (String) async throws -> MusicBrowsePage,
        moreTracks: @escaping @Sendable (String, String) async throws -> MusicQueuePage,
        isSignedIn: @escaping @Sendable () async -> Bool,
        identity: @escaping @Sendable () async -> String?
    ) {
        self.page = page
        self.moreTracks = moreTracks
        self.isSignedIn = isSignedIn
        self.identity = identity
    }

    init(backend: any MusicBackend) {
        self.init(
            page: { try await backend.page(browseId: $0) },
            moreTracks: { try await backend.moreTracks(browseId: $0, continuation: $1) },
            isSignedIn: { await backend.isSignedIn() },
            identity: { await backend.sessionIdentity() }
        )
    }
}

/// Lists every song of a playlist or album, in the page's own order. It reads the first page and then each continuation,
/// and ends the chain on the same guards as the sort's loading of a long playlist (`MusicBrowseStore`): a token seen
/// before and pages that add nothing several times in a row, with a ceiling on pages of its own, since a download reads
/// lists far longer than a sort does. Unlike a sort it has no cap on songs, and a chain that a guard ended is not a short
/// list: it throws `Failure.incomplete`, because a sync that took a cut-off list for the whole page would delete the
/// songs past the cut.
///
/// Each page is read with the back-off a song download uses: a rate limit on one page waits and asks for that page again,
/// so a long list is not read from its start after every 429.
///
/// The order never depends on how a page is shown (sorted, filtered): it is the order the pages came in.
nonisolated enum MusicCollectionEnumerator {
    /// The most continuation pages one listing asks for: five hundred, which is far past the longest playlist.
    static let pageCeiling = 500
    /// How many pages in a row may add no new song before the chain is given up on. The same number the sort uses.
    static let emptyPageLimit = 3

    enum Failure: Error, Equatable, Sendable {
        /// A guard ended the chain while YouTube still named a next page.
        case incomplete
    }

    struct Listing: Sendable {
        let title: String
        let subtitle: String
        let coverURL: URL?
        /// Each song once, where it first appears, in page order.
        let tracks: [MusicTrack]
        /// The rows the page lists but shows no song for (greyed out, podcast episodes), each once, in page order, without
        /// any song in `tracks`. Still part of the playlist.
        let unavailableVideoIds: [String]
        /// The number of songs the header states, nil when it states none.
        let statedCount: Int?
    }

    /// The songs of the page `browseId`, or the error the backend threw. Rows without a usable video id are skipped.
    static func enumerate(
        _ browseId: String,
        source: MusicCollectionSource,
        emptyPageLimit: Int = MusicCollectionEnumerator.emptyPageLimit,
        pageCeiling: Int = MusicCollectionEnumerator.pageCeiling,
        pause: MusicDownloadService.Pause = { seconds in try await Task.sleep(for: .seconds(seconds)) },
        delays: [TimeInterval] = MusicDownloadService.backoffDelays
    ) async throws -> Listing {
        try Task.checkCancellation()
        let first = try await MusicDownloadService.withBackoff(pause: pause, delays: delays) {
            try await source.page(browseId)
        }
        try Task.checkCancellation()

        var tracks: [MusicTrack] = []
        var listed = Set<String>()
        func add(_ rows: [MusicTrack]) -> Int {
            var added = 0
            for row in rows where MusicDownloadStore.isValidVideoId(row.videoId) {
                if listed.insert(row.videoId).inserted {
                    tracks.append(row)
                    added += 1
                }
            }
            return added
        }
        _ = add(first.tracks)
        var unavailable = first.unavailableVideoIds

        var seenTokens = Set<String>()
        var emptyPagesInARow = 0
        var pagesAsked = 0
        var token = nonEmpty(first.continuation)
        while let current = token {
            guard pagesAsked < pageCeiling, emptyPagesInARow < emptyPageLimit, seenTokens.insert(current).inserted else {
                throw Failure.incomplete
            }
            pagesAsked += 1
            let more = try await MusicDownloadService.withBackoff(pause: pause, delays: delays) {
                try await source.moreTracks(browseId, current)
            }
            try Task.checkCancellation()
            emptyPagesInARow = add(more.tracks) == 0 ? emptyPagesInARow + 1 : 0
            unavailable.append(contentsOf: more.unavailableVideoIds)
            token = nonEmpty(more.continuation)
        }
        var unavailableSeen = Set<String>()
        let greyed = unavailable.filter {
            MusicDownloadStore.isValidVideoId($0) && !listed.contains($0) && unavailableSeen.insert($0).inserted
        }
        let subtitle = first.subtitle ?? ""
        return Listing(
            title: first.title,
            subtitle: subtitle,
            coverURL: first.thumbnailURL,
            tracks: tracks,
            unavailableVideoIds: greyed,
            statedCount: MusicCollectionSyncRules.statedCount(inSubtitle: subtitle)
        )
    }

    private static func nonEmpty(_ token: String?) -> String? {
        guard let token, !token.isEmpty else { return nil }
        return token
    }

    // MARK: - Which pages

    /// Whether the page can be downloaded whole: a playlist ("VL..."), Liked music ("VLLM"), a curated playlist and an
    /// album ("MPRE..."). Not an artist, a mix (it never ends) or any other page.
    static func isDownloadable(browseId: String) -> Bool {
        if browseId.hasPrefix("MPRE") { return browseId.count > "MPRE".count }
        guard browseId.hasPrefix("VL"), browseId.count > "VL".count else { return false }
        return MusicBrowsePage.mixPlaylistId(ofBrowseId: browseId) == nil
    }

    /// An album is told by its "MPRE" id; every other page that can be downloaded is a playlist.
    static func kind(ofBrowseId browseId: String) -> MusicDownloadStore.Collection.Kind {
        browseId.hasPrefix("MPRE") ? .album : .playlist
    }
}
