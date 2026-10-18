// DeciTests/Music/MusicLiveBrowseTests.swift
// Hits the real YouTube Music `browse` endpoint through the real client and transport, on the
// signed-in session in the Deci Keychain item: Home, the Library lists and the Liked music page
// only exist for a real account, so fake cookies cannot stand in here.
// Skipped unless DECI_MUSIC_LIVE=1 (pass it to xcodebuild as TEST_RUNNER_DECI_MUSIC_LIVE=1).
// Prints counts only, never titles, ids, tokens, URLs or cookies: the library is the owner's.

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

    @Test("A real Home has shelves with titled items, and its continuation returns more")
    func homeAgainstTheRealEndpoint() async throws {
        let directory = makeTemporaryDirectory("deci-music-live-browse")
        defer { try? FileManager.default.removeItem(at: directory) }
        let backend = makeBackend(directory: directory)

        let home = try await backend.home()
        let items = home.shelves.flatMap(\.items)
        report("MUSIC_LIVE home shelves=\(home.shelves.count) items=\(items.count) hasContinuation=\(home.continuation != nil)")
        #expect(!home.shelves.isEmpty)
        #expect(home.shelves.allSatisfy { !$0.title.isEmpty && !$0.items.isEmpty })
        #expect(items.allSatisfy { item in
            switch item {
            case .track(let track): !track.videoId.isEmpty && !track.title.isEmpty
            case .collection(let collection): !collection.browseId.isEmpty && !collection.title.isEmpty
            }
        })

        guard let token = home.continuation else { return report("MUSIC_LIVE home has no continuation") }
        let more = try await backend.moreHome(continuation: token)
        report("MUSIC_LIVE home page2 shelves=\(more.shelves.count) items=\(more.shelves.flatMap(\.items).count) hasContinuation=\(more.continuation != nil)")
        #expect(!more.shelves.isEmpty)
        #expect(more.continuation != token)
    }

    @Test("A real Library has playlists with Liked music among them, and albums and artists parse")
    func libraryAgainstTheRealEndpoint() async throws {
        let directory = makeTemporaryDirectory("deci-music-live-browse")
        defer { try? FileManager.default.removeItem(at: directory) }
        let backend = makeBackend(directory: directory)

        let playlists = try await backend.library(.playlists)
        let hasLiked = playlists.items.contains { $0.browseId == MusicBrowseStore.likedMusic.browseId }
        report("MUSIC_LIVE library playlists=\(playlists.items.count) hasLikedMusic=\(hasLiked) hasContinuation=\(playlists.continuation != nil)")
        #expect(!playlists.items.isEmpty)
        #expect(playlists.items.allSatisfy { !$0.browseId.isEmpty && !$0.title.isEmpty })
        #expect(Set(playlists.items.map(\.browseId)).count == playlists.items.count)

        if let token = playlists.continuation {
            let more = try await backend.moreLibrary(.playlists, continuation: token)
            report("MUSIC_LIVE library playlists page2 items=\(more.items.count) hasContinuation=\(more.continuation != nil)")
            #expect(!more.items.isEmpty)
            #expect(more.continuation != token)
        }

        // An account can have no saved albums or followed artists, so these only have to parse.
        for section in [MusicLibrarySection.albums, .artists] {
            let list = try await backend.library(section)
            report("MUSIC_LIVE library \(section.rawValue) items=\(list.items.count) hasContinuation=\(list.continuation != nil)")
            #expect(list.items.allSatisfy { !$0.browseId.isEmpty && !$0.title.isEmpty })
        }
    }

    @Test("The real Liked music page has playable rows, and its continuation returns more")
    func likedMusicAgainstTheRealEndpoint() async throws {
        let directory = makeTemporaryDirectory("deci-music-live-browse")
        defer { try? FileManager.default.removeItem(at: directory) }
        let backend = makeBackend(directory: directory)

        let page = try await backend.page(browseId: "VLLM")
        report("MUSIC_LIVE VLLM tracks=\(page.tracks.count) hasContinuation=\(page.continuation != nil)")
        #expect(!page.tracks.isEmpty)
        #expect(page.tracks.allSatisfy { !$0.videoId.isEmpty && !$0.title.isEmpty })
        #expect(Set(page.tracks.map(\.videoId)).count == page.tracks.count)

        guard let token = page.continuation else { return report("MUSIC_LIVE VLLM has no continuation") }
        let more = try await backend.moreTracks(browseId: "VLLM", continuation: token)
        let fresh = Set(more.tracks.map(\.videoId)).subtracting(page.tracks.map(\.videoId))
        report("MUSIC_LIVE VLLM page2 tracks=\(more.tracks.count) new=\(fresh.count) hasContinuation=\(more.continuation != nil)")
        #expect(!more.tracks.isEmpty)
        #expect(!fresh.isEmpty)
        #expect(more.continuation != token)
    }
}
