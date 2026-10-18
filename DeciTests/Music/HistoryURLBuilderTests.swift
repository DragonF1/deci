// DeciTests/Music/HistoryURLBuilderTests.swift
// The history ping URL: the tracking URL plus the web client's parameters.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("HistoryURLBuilder")
struct HistoryURLBuilderTests {

    private func build(_ url: String, cpn: String = "AbCd_-0123456789", version: String = "1.20261013.15.00") -> URL {
        HistoryURLBuilder.url(trackingURL: URL(string: url)!, cpn: cpn, clientVersion: version)
    }

    @Test("The four client parameters are appended after the existing query")
    func appendsParameters() {
        let url = build("https://s.youtube.com/api/stats/playback?cl=1&docid=abc&ei=E")
        #expect(url.absoluteString == "https://s.youtube.com/api/stats/playback?cl=1&docid=abc&ei=E&ver=2&c=WEB_REMIX&cpn=AbCd_-0123456789&cver=1.20261013.15.00")
    }

    @Test("A URL with no query gets just the client parameters")
    func noExistingQuery() {
        let url = build("https://s.youtube.com/api/stats/playback")
        #expect(url.absoluteString == "https://s.youtube.com/api/stats/playback?ver=2&c=WEB_REMIX&cpn=AbCd_-0123456789&cver=1.20261013.15.00")
    }

    @Test("Existing percent-encoded values are preserved byte for byte")
    func preservesEncoding() {
        let url = build("https://s.youtube.com/api/stats/playback?fexp=1%2C2%2C3&plid=A%3D%3D")
        #expect(url.absoluteString.contains("fexp=1%2C2%2C3&plid=A%3D%3D&ver=2"))
    }

    @Test("A parameter that is already present is replaced, not repeated")
    func replacesDuplicates() {
        let url = build("https://s.youtube.com/api/stats/playback?ver=1&cpn=OLD&c=WEB&cver=0&docid=abc")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        for name in ["ver", "c", "cpn", "cver"] {
            #expect(items.filter { $0.name == name }.count == 1, "\(name) repeated")
        }
        #expect(items.first { $0.name == "ver" }?.value == "2")
        #expect(items.first { $0.name == "cpn" }?.value == "AbCd_-0123456789")
        #expect(items.first { $0.name == "docid" }?.value == "abc")
    }

    @Test("The cpn alphabet (dash and underscore) survives")
    func cpnAlphabet() {
        #expect(build("https://s.youtube.com/a?x=1", cpn: "-_-_-_-_-_-_-_-_").absoluteString.contains("cpn=-_-_-_-_-_-_-_-_"))
    }

    @Test("Characters outside the cpn alphabet are encoded, not injected")
    func cpnInjection() {
        let url = build("https://s.youtube.com/a?x=1", cpn: "a&b=c#d")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first { $0.name == "cpn" }?.value == "a&b=c#d")
        #expect(items.first { $0.name == "b" } == nil)
    }

    @Test("The scheme, host and path are unchanged")
    func hostPathUnchanged() {
        let url = build("https://s.youtube.com/api/stats/playback?x=1")
        #expect(url.scheme == "https")
        #expect(url.host == "s.youtube.com")
        #expect(url.path == "/api/stats/playback")
    }

    @Test("The fixture tracking URL keeps its docid and gains the parameters")
    func fixtureTrackingURL() throws {
        let response = try InnerTubeParser.playerResponse(from: MusicFixtures.data("player-ok.json"))
        let tracking = try #require(response.playbackTrackingURL)
        let url = HistoryURLBuilder.url(trackingURL: tracking, cpn: "AbCd_-0123456789", clientVersion: "1.2")
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(items["docid"] == "4D7u5KF7SP8")
        #expect(items["ver"] == "2")
        #expect(items["c"] == "WEB_REMIX")
        #expect(items["cver"] == "1.2")
    }
}
