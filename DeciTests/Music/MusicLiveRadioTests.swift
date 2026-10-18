// DeciTests/Music/MusicLiveRadioTests.swift
// Hits the real YouTube Music `next` endpoint through the real client and transport. The cookies
// are fake, so YouTube serves an anonymous radio; no account or Keychain item is involved.
// Skipped unless DECI_MUSIC_LIVE=1 (pass it to xcodebuild as TEST_RUNNER_DECI_MUSIC_LIVE=1).
// Prints counts only, never tokens, URLs or cookies.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite(
    "Music live radio",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["DECI_MUSIC_LIVE"] == "1")
)
struct MusicLiveRadioTests {

    private static let seed = "4D7u5KF7SP8"

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

    @Test("A real radio for a known song has 10+ tracks and a continuation, and moreRadio returns more")
    func radioAgainstTheRealEndpoint() async throws {
        let directory = makeTemporaryDirectory("deci-music-live-radio")
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = InnerTubeClient(transport: URLSessionTransport(), secretStore: MusicTestJar.signedInStore())
        let cache = PlayerCache(directory: directory)
        let resolver = StreamResolver(client: client, solver: FakeChallengeSolver(), cache: cache)
        let backend = MusicBackendLive(client: client, resolver: resolver)

        let first = try await backend.radio(seedVideoId: Self.seed)
        report("MUSIC_LIVE radio page1 tracks=\(first.tracks.count) hasContinuation=\(first.continuation != nil)")
        #expect(first.tracks.count >= 10)
        #expect(first.tracks.first?.videoId == Self.seed)
        #expect(first.tracks.allSatisfy { !$0.videoId.isEmpty && !$0.title.isEmpty })
        #expect(first.tracks.allSatisfy { $0.durationSeconds != nil })
        let token = try #require(first.continuation)

        let second = try await backend.moreRadio(seedVideoId: Self.seed, continuation: token)
        let fresh = Set(second.tracks.map(\.videoId)).subtracting(first.tracks.map(\.videoId))
        report("MUSIC_LIVE radio page2 tracks=\(second.tracks.count) new=\(fresh.count) hasContinuation=\(second.continuation != nil)")
        #expect(second.tracks.count >= 10)
        #expect(!fresh.isEmpty)
        #expect(second.continuation != nil)
        #expect(second.continuation != token)

        let third = try await backend.moreRadio(seedVideoId: Self.seed, continuation: try #require(second.continuation))
        report("MUSIC_LIVE radio page3 tracks=\(third.tracks.count)")
        #expect(!third.tracks.isEmpty)
    }

    @Test("A made-up continuation is an error, not a replay of the first page")
    func badTokenAgainstTheRealEndpoint() async throws {
        let client = InnerTubeClient(transport: URLSessionTransport(), secretStore: MusicTestJar.signedInStore())
        await #expect(throws: MusicError.self) { try await client.moreRadio(continuation: "not-a-real-token") }
        report("MUSIC_LIVE radio bad token rejected")
    }
}
