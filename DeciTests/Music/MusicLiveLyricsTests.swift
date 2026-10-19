// DeciTests/Music/MusicLiveLyricsTests.swift
// Hits the real lrclib.net through the real client and transport, behind the chain's temporary cache. No
// Keychain item, YouTube client or account is involved.
// Skipped unless DECI_MUSIC_LIVE=1 (pass it to xcodebuild as TEST_RUNNER_DECI_MUSIC_LIVE=1).
// Prints counts only, never lyric text.

import Foundation
import Testing
@testable import Deci

@Suite(
    "Music live lyrics",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["DECI_MUSIC_LIVE"] == "1")
)
struct MusicLiveLyricsTests {

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

    @Test("A well-known song has synced lyrics on the real LRCLIB, and a second ask is served from disk")
    func syncedLyricsAgainstTheRealService() async throws {
        let directory = makeTemporaryDirectory("deci-music-live-lyrics")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = LyricsDiskCache(directory: directory.appendingPathComponent("Lyrics", isDirectory: true))
        // LRCLIB alone behind the disk cache: YouTube Music is switched off so this stays a test of LRCLIB.
        let client = LyricsChain(
            primary: NoLyricsProvider(),
            fallback: LRCLibClient(
                transport: URLSessionTransport(configuration: LRCLibClient.makeConfiguration()),
                userAgent: LRCLibClient.userAgent(version: "test")
            ),
            cache: cache
        )
        let query = LyricsQuery(
            videoId: "dQw4w9WgXcQ",
            title: "Never Gonna Give You Up",
            artist: "Rick Astley",
            album: "Whenever You Need Somebody",
            duration: 213
        )

        let result = try await client.lyrics(for: query)
        guard case .synced(let lines) = result else {
            report("MUSIC_LIVE lyrics synced=false")
            Issue.record("expected synced lyrics")
            return
        }
        report("MUSIC_LIVE lyrics synced=true lines=\(lines.count)")
        #expect(lines.count > 10)
        #expect(LRCParser.sungLineCount(lines) > 10)
        #expect(zip(lines, lines.dropFirst()).allSatisfy { $0.time <= $1.time })
        #expect(lines.allSatisfy { $0.time >= 0 && $0.time < 600 })

        let again = try await client.lyrics(for: query)
        #expect(again == result)
        report("MUSIC_LIVE lyrics cached=\(again == result)")
    }
}
