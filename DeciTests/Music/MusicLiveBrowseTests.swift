// DeciTests/Music/MusicLiveBrowseTests.swift
// Hits the real YouTube Music `browse` endpoint through the real client and transport, on the
// signed-in session in the Deci Keychain item: Home, the Library lists and the Liked music page
// only exist for a real account, so fake cookies cannot stand in here.
// Skipped unless DECI_MUSIC_LIVE=1 (pass it to xcodebuild as TEST_RUNNER_DECI_MUSIC_LIVE=1).
// Prints counts only, never titles, ids, tokens, URLs or cookies: the library is the owner's.
// Checks go through local Bools so a failed #expect cannot print a value either.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite(
    "Music live browse",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["DECI_MUSIC_LIVE"] == "1")
)
struct MusicLiveBrowseTests {

    /// Home pages to walk, the first included: enough to reach the end of a feed without paging forever.
    private static let homePageLimit = 8

    private func report(_ line: String) {
        print(line)
        guard let path = ProcessInfo.processInfo.environment["DECI_MUSIC_LIVE_LOG"],
              let data = (line + "\n").data(using: .utf8) else { return }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: path, contents: data)
        }
    }

    /// The real client on the owner's stored session, wrapped the way the app wraps it.
    private func makeBackend(directory: URL) -> MusicBackendLive {
        let client = InnerTubeClient(transport: URLSessionTransport(), secretStore: KeychainSecretStore())
        let cache = PlayerCache(directory: directory)
        let resolver = StreamResolver(client: client, solver: FakeChallengeSolver(), cache: cache)
        return MusicBackendLive(client: client, resolver: resolver)
    }

    @Test("A real Home has shelves with titled items, and its continuations walk to the end of the feed")
    func homeAgainstTheRealEndpoint() async throws {
        let directory = makeTemporaryDirectory("deci-music-live-browse")
        defer { try? FileManager.default.removeItem(at: directory) }
        let backend = makeBackend(directory: directory)

        let home = try await backend.home()
        let items = home.shelves.flatMap(\.items)
        report("MUSIC_LIVE home shelves=\(home.shelves.count) items=\(items.count) hasContinuation=\(home.continuation != nil)")
        #expect(!home.shelves.isEmpty)
        let shelvesFilled = home.shelves.allSatisfy { !$0.title.isEmpty && !$0.items.isEmpty }
        let itemsFilled = items.allSatisfy { item in
            switch item {
            case .track(let track): !track.videoId.isEmpty && !track.title.isEmpty
            case .collection(let collection): !collection.browseId.isEmpty && !collection.title.isEmpty
            }
        }
        #expect(shelvesFilled)
        #expect(itemsFilled)

        // Walk the feed (bounded). The last token can be answered with a bare page skeleton, which has to
        // read as the end of the feed and not as a parse error; a token that repeats would loop forever.
        var token = home.continuation
        var seenTokens = Set<String>()
        var tokensFresh = true
        var pageNumber = 1
        while let current = token, pageNumber < Self.homePageLimit {
            tokensFresh = tokensFresh && seenTokens.insert(current).inserted
            let more = try await backend.moreHome(continuation: current)
            pageNumber += 1
            report("MUSIC_LIVE home page\(pageNumber) shelves=\(more.shelves.count) items=\(more.shelves.flatMap(\.items).count) hasContinuation=\(more.continuation != nil)")
            if pageNumber == 2 { #expect(!more.shelves.isEmpty) }
            token = more.continuation
        }
        report("MUSIC_LIVE home walked pages=\(pageNumber) reachedEnd=\(token == nil)")
        #expect(tokensFresh)
    }

    @Test("A real Library has playlists, and albums and artists parse")
    func libraryAgainstTheRealEndpoint() async throws {
        let directory = makeTemporaryDirectory("deci-music-live-browse")
        defer { try? FileManager.default.removeItem(at: directory) }
        let backend = makeBackend(directory: directory)

        let playlists = try await backend.library(.playlists)
        let hasLiked = playlists.items.contains { $0.browseId == MusicBrowseStore.likedMusic.browseId }
        report("MUSIC_LIVE library playlists=\(playlists.items.count) hasLikedMusic=\(hasLiked) hasContinuation=\(playlists.continuation != nil)")
        #expect(!playlists.items.isEmpty)
        let playlistsFilled = playlists.items.allSatisfy { !$0.browseId.isEmpty && !$0.title.isEmpty }
        let playlistsUnique = Set(playlists.items.map(\.browseId)).count == playlists.items.count
        #expect(playlistsFilled)
        #expect(playlistsUnique)

        if let token = playlists.continuation {
            let more = try await backend.moreLibrary(.playlists, continuation: token)
            report("MUSIC_LIVE library playlists page2 items=\(more.items.count) hasContinuation=\(more.continuation != nil)")
            let tokenMoved = more.continuation != token
            #expect(!more.items.isEmpty)
            #expect(tokenMoved)
        }

        // The grid can lack a Liked music tile (the Library view pins its own row), and an account can have no
        // saved albums, so these only have to parse.
        for section in [MusicLibrarySection.albums] {
            let list = try await backend.library(section)
            report("MUSIC_LIVE library \(section.rawValue) items=\(list.items.count) hasContinuation=\(list.continuation != nil)")
            let listFilled = list.items.allSatisfy { !$0.browseId.isEmpty && !$0.title.isEmpty }
            #expect(listFilled)
        }
    }

    @Test("The real Liked music page has playable rows, or YouTube's own header count says there are none")
    func likedMusicAgainstTheRealEndpoint() async throws {
        let directory = makeTemporaryDirectory("deci-music-live-browse")
        defer { try? FileManager.default.removeItem(at: directory) }
        let backend = makeBackend(directory: directory)

        let page = try await backend.page(browseId: "VLLM")
        // No liked songs is an empty page, and the only way to tell that from a parse gap is the header's own count.
        let headerCountsZero = page.subtitle?.hasSuffix(" \u{2022} 0 songs") == true
        report("MUSIC_LIVE VLLM tracks=\(page.tracks.count) headerCountsZero=\(headerCountsZero) hasContinuation=\(page.continuation != nil)")
        let rowsOrZero = !page.tracks.isEmpty || headerCountsZero
        #expect(rowsOrZero)
        let tracksFilled = page.tracks.allSatisfy { !$0.videoId.isEmpty && !$0.title.isEmpty }
        let tracksUnique = Set(page.tracks.map(\.videoId)).count == page.tracks.count
        #expect(tracksFilled)
        #expect(tracksUnique)

        guard let token = page.continuation else { return report("MUSIC_LIVE VLLM has no continuation") }
        let more = try await backend.moreTracks(browseId: "VLLM", continuation: token)
        let fresh = Set(more.tracks.map(\.videoId)).subtracting(page.tracks.map(\.videoId))
        report("MUSIC_LIVE VLLM page2 tracks=\(more.tracks.count) new=\(fresh.count) hasContinuation=\(more.continuation != nil)")
        let tokenMoved = more.continuation != token
        #expect(!more.tracks.isEmpty)
        #expect(!fresh.isEmpty)
        #expect(tokenMoved)
    }
}
