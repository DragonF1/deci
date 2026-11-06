// DeciTests/Music/InnerTubeParserLoudnessTests.swift
// playerConfig.audioConfig sits at the root of the player response, next to streamingData.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("InnerTubeParser loudness")
struct InnerTubeParserLoudnessTests {

    private func parse(config: String) throws -> PlayerResponse {
        let json = #"{"playabilityStatus":{"status":"OK"},"playerConfig":\#(config)}"#
        return try InnerTubeParser.playerResponse(from: Data(json.utf8))
    }

    @Test("Both numbers are read from the root playerConfig.audioConfig")
    func bothPresent() throws {
        let response = try parse(config: #"{"audioConfig":{"loudnessDb":-6.3,"perceptualLoudnessDb":-4.1}}"#)
        #expect(response.loudnessDb == -6.3)
        #expect(response.perceptualLoudnessDb == -4.1)
    }

    @Test("Missing playerConfig, audioConfig or fields give nil")
    func missing() throws {
        #expect(try InnerTubeParser.playerResponse(from: Data(#"{"playabilityStatus":{"status":"OK"}}"#.utf8)).loudnessDb == nil)
        #expect(try parse(config: "{}").loudnessDb == nil)
        let onlyOne = try parse(config: #"{"audioConfig":{"loudnessDb":1.5}}"#)
        #expect(onlyOne.loudnessDb == 1.5)
        #expect(onlyOne.perceptualLoudnessDb == nil)
    }

    @Test("A numeric string is accepted")
    func numericString() throws {
        let response = try parse(config: #"{"audioConfig":{"loudnessDb":"-7.25","perceptualLoudnessDb":"-5"}}"#)
        #expect(response.loudnessDb == -7.25)
        #expect(response.perceptualLoudnessDb == -5)
    }

    @Test("Junk, booleans, nan, inf and wrong shapes are nil")
    func junk() throws {
        let response = try parse(config: #"{"audioConfig":{"loudnessDb":"loud","perceptualLoudnessDb":true}}"#)
        #expect(response.loudnessDb == nil)
        #expect(response.perceptualLoudnessDb == nil)
        let special = try parse(config: #"{"audioConfig":{"loudnessDb":"nan","perceptualLoudnessDb":"inf"}}"#)
        #expect(special.loudnessDb == nil)
        #expect(special.perceptualLoudnessDb == nil)
        #expect(try parse(config: #"{"audioConfig":[1,2]}"#).loudnessDb == nil)
        #expect(try parse(config: #""text""#).loudnessDb == nil)
    }

    @Test("A loudnessDb inside streamingData is not the root one and is ignored")
    func notInsideStreamingData() throws {
        let json = #"{"playabilityStatus":{"status":"OK"},"streamingData":{"audioConfig":{"loudnessDb":-1}}}"#
        #expect(try InnerTubeParser.playerResponse(from: Data(json.utf8)).loudnessDb == nil)
    }

    @Test("The codec is read from the mimeType")
    func codecs() {
        func format(_ mime: String) -> PlayerFormat {
            PlayerFormat(itag: 140, mimeType: mime, bitrate: nil, url: nil, signatureCipher: nil, approxDurationMs: nil)
        }
        #expect(format(#"audio/mp4; codecs="mp4a.40.2""#).codecs == "mp4a.40.2")
        #expect(format("audio/mp4").codecs == nil)
        #expect(format("").codecs == nil)
    }

    @Test("playingFrom(file:) keeps the exact duration, pings and loudness, and marks the stream as a track cache")
    func playingFromFile() {
        let network = ResolvedStream(
            videoId: "4D7u5KF7SP8", url: URL(string: "https://example.invalid/v")!, itag: 140, durationSeconds: 369.626,
            expiresAt: Date(timeIntervalSince1970: 5), playbackTrackingURL: URL(string: "https://s.example.invalid/p"),
            watchtimeTrackingURL: URL(string: "https://s.example.invalid/w"), viewCount: 9,
            httpHeaders: ["User-Agent": "x"], audioCodec: "mp4a.40.2", loudnessDb: -6.3, perceptualLoudnessDb: -4.1
        )
        let file = URL(fileURLWithPath: "/Volumes/Storage/_test/deci-2a/x.m4a")
        let cached = network.playingFrom(file: file)
        #expect(cached.url == file)
        #expect(cached.origin == .trackCache)
        #expect(cached.durationSeconds == 369.626)
        #expect(cached.expiresAt == .distantFuture)
        #expect(cached.httpHeaders.isEmpty)
        #expect(cached.playbackTrackingURL == network.playbackTrackingURL)
        #expect(cached.watchtimeTrackingURL == network.watchtimeTrackingURL)
        #expect(cached.viewCount == 9)
        #expect(cached.itag == 140 && cached.audioCodec == "mp4a.40.2" && cached.loudnessDb == -6.3)
        #expect(network.origin == .network)
    }
}
