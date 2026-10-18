// DeciTests/Music/StreamURLsTests.swift
// Format choice and stream URL assembly: signatureCipher, the n parameter, expiry.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("FormatPicker")
struct FormatPickerTests {

    private func format(_ itag: Int, _ mime: String, bitrate: Int? = 100_000, url: String? = "https://rr1.googlevideo.com/videoplayback", cipher: String? = nil) -> PlayerFormat {
        PlayerFormat(itag: itag, mimeType: mime, bitrate: bitrate, url: url, signatureCipher: cipher, approxDurationMs: nil)
    }

    @Test("itag 141 wins over everything")
    func prefers141() {
        let formats = [format(140, "audio/mp4", bitrate: 130_000), format(141, "audio/mp4", bitrate: 256_000), format(256, "audio/mp4", bitrate: 400_000)]
        #expect(FormatPicker.pick(from: formats)?.itag == 141)
    }

    @Test("itag 140 is next")
    func prefers140() {
        let formats = [format(139, "audio/mp4", bitrate: 48_000), format(140, "audio/mp4", bitrate: 130_000), format(256, "audio/mp4", bitrate: 400_000)]
        #expect(FormatPicker.pick(from: formats)?.itag == 140)
    }

    @Test("Otherwise the highest-bitrate audio/mp4 wins")
    func bestBitrate() {
        let formats = [format(139, "audio/mp4", bitrate: 48_000), format(256, "audio/mp4", bitrate: 192_000), format(258, "audio/mp4", bitrate: 384_000)]
        #expect(FormatPicker.pick(from: formats)?.itag == 258)
    }

    @Test("WebM is never chosen, even at a higher bitrate")
    func neverWebM() {
        let formats = [format(251, "audio/webm; codecs=\"opus\"", bitrate: 160_000), format(139, "audio/mp4; codecs=\"mp4a.40.5\"", bitrate: 48_000)]
        #expect(FormatPicker.pick(from: formats)?.itag == 139)
        #expect(FormatPicker.pick(from: [format(251, "audio/webm", bitrate: 160_000)]) == nil)
    }

    @Test("Video formats are never chosen")
    func neverVideo() {
        #expect(FormatPicker.pick(from: [format(137, "video/mp4; codecs=\"avc1.640020\"", bitrate: 5_000_000)]) == nil)
        #expect(FormatPicker.pick(from: [format(141, "video/mp4")]) == nil)
    }

    @Test("A preferred itag with no url or cipher is skipped")
    func skipsUnusable() {
        let formats = [format(141, "audio/mp4", url: nil, cipher: nil), format(140, "audio/mp4")]
        #expect(FormatPicker.pick(from: formats)?.itag == 140)
        let empty = [format(141, "audio/mp4", url: "", cipher: "")]
        #expect(FormatPicker.pick(from: empty) == nil)
    }

    @Test("A signatureCipher format is usable")
    func cipherCounts() {
        #expect(FormatPicker.pick(from: [format(140, "audio/mp4", url: nil, cipher: "s=a&sp=sig&url=b")])?.itag == 140)
    }

    @Test("The mime check ignores case")
    func mimeCase() {
        #expect(FormatPicker.pick(from: [format(140, "Audio/MP4; codecs=\"mp4a.40.2\"")])?.itag == 140)
    }

    @Test("Formats with no bitrate still rank")
    func missingBitrate() {
        let formats = [format(139, "audio/mp4", bitrate: nil), format(256, "audio/mp4", bitrate: 100_000)]
        #expect(FormatPicker.pick(from: formats)?.itag == 256)
    }

    @Test("Nothing in, nothing out")
    func empty() {
        #expect(FormatPicker.pick(from: []) == nil)
    }

    @Test("The player fixture yields itag 140")
    func fixture() throws {
        let response = try InnerTubeParser.playerResponse(from: MusicFixtures.data("player-ok.json"))
        #expect(FormatPicker.pick(from: response.formats)?.itag == 140)
    }
}

@MainActor
@Suite("StreamURLBuilder")
struct StreamURLBuilderTests {

    private func fixtureFormat() throws -> PlayerFormat {
        let response = try InnerTubeParser.playerResponse(from: MusicFixtures.data("player-ok.json"))
        return try #require(response.formats.first { $0.itag == 140 })
    }

    private func items(_ url: URL) -> [String: String] {
        Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    private func direct(_ url: String) -> PlayerFormat {
        PlayerFormat(itag: 140, mimeType: "audio/mp4", bitrate: nil, url: url, signatureCipher: nil, approxDurationMs: nil)
    }

    private func cipher(_ value: String) -> PlayerFormat {
        PlayerFormat(itag: 140, mimeType: "audio/mp4", bitrate: nil, url: nil, signatureCipher: value, approxDurationMs: nil)
    }

    // MARK: - Plan

    @Test("The fixture cipher splits into signature, parameter, n and a decoded URL")
    func planFromFixture() throws {
        let plan = try StreamURLBuilder.plan(for: fixtureFormat())
        #expect(plan.baseURL.host == "rr1---sn-fixture.googlevideo.com")
        #expect(plan.baseURL.path == "/videoplayback")
        #expect(plan.signatureChallenge?.hasPrefix("==QQV") == true)
        #expect(plan.signatureParameter == "sig")
        #expect(plan.nChallenge == "K7mvvqmnpyMV8KYX")
        #expect(plan.needsSolving)
        #expect(items(plan.baseURL)["itag"] == "140")
        #expect(items(plan.baseURL)["expire"] == "1792305256")
    }

    @Test("The solver request names the hash, the signature and the n value")
    func challengeRequest() throws {
        let plan = try StreamURLBuilder.plan(for: fixtureFormat())
        let request = plan.challengeRequest(playerHash: "abcd1234")
        #expect(request.playerHash == "abcd1234")
        #expect(request.sigInputs == [plan.signatureChallenge ?? ""])
        #expect(request.nInputs == ["K7mvvqmnpyMV8KYX"])
    }

    @Test("A direct URL without n needs no solving")
    func directNoN() throws {
        let plan = try StreamURLBuilder.plan(for: direct("https://rr1.googlevideo.com/videoplayback?itag=140&expire=5"))
        #expect(plan.needsSolving == false)
        #expect(plan.signatureChallenge == nil)
        #expect(plan.nChallenge == nil)
    }

    @Test("A cipher without sp defaults the parameter to signature")
    func defaultSP() throws {
        let plan = try StreamURLBuilder.plan(for: cipher("s=SCRAMBLED&url=https%3A%2F%2Frr1.googlevideo.com%2Fvideoplayback%3Fitag%3D140"))
        #expect(plan.signatureParameter == "signature")
        #expect(plan.signatureChallenge == "SCRAMBLED")
    }

    @Test("An unsafe sp name falls back to signature")
    func unsafeSP() throws {
        let plan = try StreamURLBuilder.plan(for: cipher("s=X&sp=a%26evil%3D1&url=https%3A%2F%2Frr1.googlevideo.com%2Fv%3Fitag%3D140"))
        #expect(plan.signatureParameter == "signature")
    }

    @Test("A cipher with a plus in s reads it as a space, like a form decoder")
    func plusIsSpace() throws {
        let plan = try StreamURLBuilder.plan(for: cipher("s=A+B%2BC&sp=sig&url=https%3A%2F%2Frr1.googlevideo.com%2Fv%3Fitag%3D140"))
        #expect(plan.signatureChallenge == "A B+C")
    }

    @Test("A cipher with no url is a parse error")
    func cipherWithoutURL() {
        #expect(throws: MusicError.self) { try StreamURLBuilder.plan(for: cipher("s=X&sp=sig")) }
    }

    @Test("A format with neither url nor cipher is a parse error")
    func formatWithNothing() {
        let bare = PlayerFormat(itag: 140, mimeType: "audio/mp4", bitrate: nil, url: nil, signatureCipher: nil, approxDurationMs: nil)
        #expect(throws: MusicError.self) { try StreamURLBuilder.plan(for: bare) }
    }

    @Test("Only https URLs on YouTube hosts are accepted")
    func hostGuard() {
        for url in ["http://rr1.googlevideo.com/videoplayback?itag=140", "https://evil.example/videoplayback?itag=140", "https://googlevideo.com.evil.example/x", "not a url"] {
            #expect(throws: MusicError.self, "\(url)") { try StreamURLBuilder.plan(for: direct(url)) }
        }
    }

    // MARK: - Build

    @Test("Build applies the solved signature and n and keeps every other parameter")
    func buildFixture() throws {
        let format = try fixtureFormat()
        let plan = try StreamURLBuilder.plan(for: format)
        let solutions = ChallengeSolutions(
            sig: [plan.signatureChallenge ?? "": "SOLVEDSIG"],
            n: ["K7mvvqmnpyMV8KYX": "SOLVEDN"]
        )
        let built = try StreamURLBuilder.build(plan, solutions: solutions)
        let result = items(built.url)
        #expect(result["n"] == "SOLVEDN")
        #expect(result["sig"] == "SOLVEDSIG")
        #expect(result["itag"] == "140")
        #expect(result["id"] == items(plan.baseURL)["id"])
        #expect(result["lsig"] == "LSIG_SCRUBBED")
        #expect(built.expiresAt == Date(timeIntervalSince1970: 1_792_305_256))
        #expect(built.url.host == plan.baseURL.host)
        // Every original parameter other than n is still there.
        for (name, value) in items(plan.baseURL) where name != "n" {
            #expect(result[name] == value, "\(name) changed")
        }
    }

    @Test("The solved signature is percent-encoded")
    func signatureEncoding() throws {
        let plan = try StreamURLBuilder.plan(for: cipher("s=X&sp=sig&url=https%3A%2F%2Frr1.googlevideo.com%2Fv%3Fitag%3D140"))
        let built = try StreamURLBuilder.build(plan, solutions: ChallengeSolutions(sig: ["X": "a=b&c+d/e"], n: [:]))
        #expect(built.url.absoluteString.hasSuffix("&sig=a%3Db%26c%2Bd%2Fe"))
        #expect(items(built.url)["sig"] == "a=b&c+d/e")
    }

    @Test("A solved n is percent-encoded in place and the order of parameters is kept")
    func nReplacedInPlace() throws {
        let plan = try StreamURLBuilder.plan(for: direct("https://rr1.googlevideo.com/videoplayback?a=1&n=OLD&b=2"))
        let built = try StreamURLBuilder.build(plan, solutions: ChallengeSolutions(sig: [:], n: ["OLD": "x y"]))
        #expect(built.url.absoluteString == "https://rr1.googlevideo.com/videoplayback?a=1&n=x%20y&b=2")
    }

    @Test("Existing percent-encoding in other parameters is untouched")
    func otherEncodingKept() throws {
        let plan = try StreamURLBuilder.plan(for: direct("https://rr1.googlevideo.com/videoplayback?sparams=expire%2Cei%2Cip&n=OLD&mn=sn-a%2Csn-b"))
        let built = try StreamURLBuilder.build(plan, solutions: ChallengeSolutions(sig: [:], n: ["OLD": "NEW"]))
        #expect(built.url.absoluteString == "https://rr1.googlevideo.com/videoplayback?sparams=expire%2Cei%2Cip&n=NEW&mn=sn-a%2Csn-b")
    }

    @Test("A direct URL without n or signature passes through unchanged")
    func passThrough() throws {
        let url = "https://rr1.googlevideo.com/videoplayback?itag=140&expire=1792305256&sig=abc"
        let plan = try StreamURLBuilder.plan(for: direct(url))
        let built = try StreamURLBuilder.build(plan, solutions: ChallengeSolutions(sig: [:], n: [:]))
        #expect(built.url.absoluteString == url)
        #expect(built.expiresAt == Date(timeIntervalSince1970: 1_792_305_256))
    }

    @Test("A repeated signature parameter is replaced, not duplicated")
    func signatureReplaced() throws {
        let plan = try StreamURLBuilder.plan(for: cipher("s=X&sp=sig&url=https%3A%2F%2Frr1.googlevideo.com%2Fv%3Fsig%3Dstale%26itag%3D140"))
        let built = try StreamURLBuilder.build(plan, solutions: ChallengeSolutions(sig: ["X": "fresh"], n: [:]))
        let sigs = (URLComponents(url: built.url, resolvingAgainstBaseURL: false)?.queryItems ?? []).filter { $0.name == "sig" }
        #expect(sigs.map(\.value) == ["fresh"])
    }

    @Test("A missing expire parameter gives no expiry")
    func noExpiry() throws {
        let plan = try StreamURLBuilder.plan(for: direct("https://rr1.googlevideo.com/videoplayback?itag=140"))
        #expect(try StreamURLBuilder.build(plan, solutions: ChallengeSolutions(sig: [:], n: [:])).expiresAt == nil)
    }

    @Test("A non-numeric expire parameter gives no expiry")
    func badExpiry() throws {
        let plan = try StreamURLBuilder.plan(for: direct("https://rr1.googlevideo.com/videoplayback?expire=soon"))
        #expect(try StreamURLBuilder.build(plan, solutions: ChallengeSolutions(sig: [:], n: [:])).expiresAt == nil)
    }

    @Test("An unsolved n is a solver error")
    func unsolvedN() throws {
        let plan = try StreamURLBuilder.plan(for: direct("https://rr1.googlevideo.com/videoplayback?n=OLD"))
        #expect(throws: MusicError.self) { try StreamURLBuilder.build(plan, solutions: ChallengeSolutions(sig: [:], n: [:])) }
        #expect(throws: MusicError.self) { try StreamURLBuilder.build(plan, solutions: ChallengeSolutions(sig: [:], n: ["OLD": ""])) }
    }

    @Test("An unsolved signature is a solver error")
    func unsolvedSignature() throws {
        let plan = try StreamURLBuilder.plan(for: cipher("s=X&sp=sig&url=https%3A%2F%2Frr1.googlevideo.com%2Fv%3Fitag%3D140"))
        #expect(throws: MusicError.self) { try StreamURLBuilder.build(plan, solutions: ChallengeSolutions(sig: [:], n: [:])) }
    }
}
