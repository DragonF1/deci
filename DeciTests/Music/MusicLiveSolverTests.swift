// DeciTests/Music/MusicLiveSolverTests.swift
// Hits the real YouTube with NO cookies: the music.youtube.com home page, the public player JS
// and one anonymous player call. Skipped unless DECI_MUSIC_LIVE=1 (pass it to xcodebuild as
// TEST_RUNNER_DECI_MUSIC_LIVE=1). Prints timings and status codes only, never URLs.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite(
    "Music live solver",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["DECI_MUSIC_LIVE"] == "1")
)
struct MusicLiveSolverTests {

    private static let videoId = "4D7u5KF7SP8"

    /// Prints a line and, when DECI_MUSIC_LIVE_LOG names a file, appends it there too (the test
    /// host's stdout does not reach the xcodebuild log).
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

    private func milliseconds(_ body: () async throws -> Void) async rethrows -> Int {
        let start = ContinuousClock.now
        try await body()
        let elapsed = start.duration(to: .now)
        return Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
    }

    @Test("Solves a real signature and n against the live player, cold then warm")
    func solvesAgainstTheRealPlayer() async throws {
        let transport = URLSessionTransport()

        // 1. Public bootstrap and player JS, no cookies.
        let home = try await transport.send(HTTPRequest(
            url: URL(string: "https://music.youtube.com/")!,
            headers: ["User-Agent": MusicAuthHeaders.userAgent, "Accept-Language": "en-US,en;q=0.9"]
        ))
        #expect(home.statusCode == 200)
        let config = InnerTubeParser.bootstrapConfig(fromHTML: String(decoding: home.data, as: UTF8.self))
        let jsURL = try #require(config.playerJSURL)
        let hash = try #require(InnerTubeParser.playerHash(fromPlayerJSURL: jsURL))
        let clientVersion = try #require(config.clientVersion)

        var playerJS = ""
        let downloadMs = try await milliseconds {
            let response = try await transport.send(HTTPRequest(url: jsURL, headers: ["User-Agent": MusicAuthHeaders.userAgent]))
            #expect(response.statusCode == 200)
            playerJS = String(decoding: response.data, as: UTF8.self)
        }
        let rawJS = playerJS
        let sts = try #require(InnerTubeParser.signatureTimestamp(fromPlayerJS: rawJS))
        report("MUSIC_LIVE player hash=\(hash) sts=\(sts) bytes=\(rawJS.utf8.count) download_ms=\(downloadMs) client=\(clientVersion)")

        // 2. One anonymous player call, to get a real n (and a real cipher when YouTube sends one).
        var nChallenge = "K7mvvqmnpyMV8KYX"
        var sigChallenge = try Self.fixtureSignature()
        var anonymousFormat: PlayerFormat?
        var visitor: [String: String] = [:]
        if let visitorData = config.visitorData { visitor["X-Goog-Visitor-Id"] = visitorData }
        let body: [String: Any] = [
            "videoId": Self.videoId,
            "playbackContext": ["contentPlaybackContext": ["signatureTimestamp": sts]],
            "racyCheckOk": true,
            "contentCheckOk": true,
            "context": ["client": [
                "clientName": "WEB_REMIX", "clientVersion": clientVersion, "hl": "en", "gl": "US",
                "visitorData": config.visitorData ?? "",
            ]],
        ]
        let playerResponse = try await transport.send(HTTPRequest(
            url: URL(string: "https://music.youtube.com/youtubei/v1/player?prettyPrint=false")!,
            method: "POST",
            headers: [
                "User-Agent": MusicAuthHeaders.userAgent,
                "Content-Type": "application/json",
                "Origin": MusicAuthHeaders.origin,
                "X-Origin": MusicAuthHeaders.origin,
                "Referer": MusicAuthHeaders.origin + "/",
                "X-YouTube-Client-Name": MusicAuthHeaders.clientName,
                "X-YouTube-Client-Version": clientVersion,
            ].merging(visitor) { $1 },
            body: try JSONSerialization.data(withJSONObject: body)
        ))
        report("MUSIC_LIVE anonymous player http=\(playerResponse.statusCode)")
        if playerResponse.statusCode == 200, let parsed = try? InnerTubeParser.playerResponse(from: playerResponse.data) {
            report("MUSIC_LIVE anonymous playability=\(parsed.status) formats=\(parsed.formats.count)")
            if parsed.status == "OK", let format = FormatPicker.pick(from: parsed.formats),
               let plan = try? StreamURLBuilder.plan(for: format) {
                anonymousFormat = format
                if let n = plan.nChallenge { nChallenge = n }
                if let s = plan.signatureChallenge { sigChallenge = s }
                report("MUSIC_LIVE anonymous itag=\(format.itag) hasCipher=\(format.signatureCipher != nil) hasN=\(plan.nChallenge != nil)")
            }
        }

        // 3. Solve: cold, warm on the same solver, warm on a new solver with the same cache.
        let directory = makeTemporaryDirectory("deci-music-live")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = PlayerCache(directory: directory)
        let request = ChallengeRequest(playerHash: hash, sigInputs: [sigChallenge], nInputs: [nChallenge])

        let solver = JSChallengeSolver(cache: cache)
        var cold: ChallengeSolutions?
        let coldMs = try await milliseconds {
            cold = try await solver.solve(request) { rawJS }
        }
        var warm: ChallengeSolutions?
        let warmMs = try await milliseconds {
            warm = try await solver.solve(request) { throw MusicError.solver("a warm solve must not download") }
        }
        let relaunched = JSChallengeSolver(cache: cache)
        var warmNew: ChallengeSolutions?
        let relaunchMs = try await milliseconds {
            warmNew = try await relaunched.solve(request) { throw MusicError.solver("a warm solve must not download") }
        }
        report("MUSIC_LIVE solve cold_ms=\(coldMs) warm_ms=\(warmMs) relaunch_warm_ms=\(relaunchMs) preprocessed_bytes=\(cache.preprocessedPlayer(forHash: hash)?.utf8.count ?? 0)")

        let coldSolutions = try #require(cold)
        #expect(warm == coldSolutions)
        #expect(warmNew == coldSolutions)

        let solvedN = try #require(coldSolutions.n[nChallenge])
        let solvedSig = try #require(coldSolutions.sig[sigChallenge])
        #expect(!solvedN.isEmpty)
        #expect(solvedN != nChallenge)
        #expect(!solvedN.hasPrefix("enhanced_except_"))
        #expect(!solvedSig.isEmpty)
        #expect(solvedSig != sigChallenge)
        report("MUSIC_LIVE solved n_len=\(solvedN.count) sig_len=\(solvedSig.count) sig_in_len=\(sigChallenge.count)")

        // 4. If the anonymous call gave a real stream, see whether GVS serves it without a PO token.
        if let format = anonymousFormat, let plan = try? StreamURLBuilder.plan(for: format) {
            let solutions = try await relaunched.solve(plan.challengeRequest(playerHash: hash)) { rawJS }
            let built = try StreamURLBuilder.build(plan, solutions: solutions)
            let probe = try await transport.send(HTTPRequest(
                url: built.url,
                headers: ["User-Agent": MusicAuthHeaders.userAgent, "Range": "bytes=0-1023", "Origin": MusicAuthHeaders.origin, "Referer": MusicAuthHeaders.origin + "/"]
            ))
            report("MUSIC_LIVE anonymous stream range http=\(probe.statusCode) bytes=\(probe.data.count) host_is_googlevideo=\(built.url.host?.hasSuffix(".googlevideo.com") == true)")
        } else {
            report("MUSIC_LIVE anonymous stream range skipped (no anonymous format)")
        }
    }

    private static func fixtureSignature() throws -> String {
        let response = try InnerTubeParser.playerResponse(from: MusicFixtures.data("player-ok.json"))
        let format = try #require(response.formats.first { $0.itag == 140 })
        return try #require(StreamURLBuilder.plan(for: format).signatureChallenge)
    }
}
