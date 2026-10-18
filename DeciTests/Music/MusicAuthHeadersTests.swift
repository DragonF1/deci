// DeciTests/Music/MusicAuthHeadersTests.swift
// SAPISIDHASH authorization and the InnerTube request headers. The hashes were computed
// independently with `shasum -a 1`.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("MusicAuthHeaders")
struct MusicAuthHeadersTests {

    private let timestamp = 1_700_000_000
    private let musicURL = URL(string: "https://music.youtube.com/youtubei/v1/search")!

    // sha1("1700000000 <sid> https://music.youtube.com")
    private let hashABC = "2f3ec011e870f3fbd0238c090c2062c208cead32"
    private let hashDEF = "b38b56d67b7362e62fd452ce74b55b7cce306020"
    private let hashGHI = "83e4bb2a61ac1b8e1f945d8c9e88cd4d417136b1"

    private func cookie(_ name: String, _ value: String, domain: String = ".youtube.com") -> StoredCookie {
        StoredCookie(
            name: name, value: value, domain: domain, path: "/",
            expires: nil, isSecure: true, isHTTPOnly: false
        )
    }

    // MARK: - Authorization

    @Test("All three cookies produce the three-scheme header with the known SHA-1 vectors")
    func fullAuthorization() {
        let value = MusicAuthHeaders.authorization(
            sapisid: "abc", secure1PAPISID: "def", secure3PAPISID: "ghi", timestamp: timestamp
        )
        #expect(value == "SAPISIDHASH 1700000000_\(hashABC) SAPISID1PHASH 1700000000_\(hashDEF) SAPISID3PHASH 1700000000_\(hashGHI)")
    }

    @Test("Only the schemes whose cookie exists are included")
    func partialAuthorization() {
        let value = MusicAuthHeaders.authorization(
            sapisid: "abc", secure1PAPISID: nil, secure3PAPISID: "ghi", timestamp: timestamp
        )
        #expect(value == "SAPISIDHASH 1700000000_\(hashABC) SAPISID3PHASH 1700000000_\(hashGHI)")
    }

    @Test("SAPISID falls back to __Secure-3PAPISID when it is missing")
    func sapisidFallsBack() {
        let jar = MusicCookieJar(cookies: [cookie("__Secure-3PAPISID", "ghi")])
        let value = MusicAuthHeaders.authorization(jar: jar, url: musicURL, now: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(value == "SAPISIDHASH 1700000000_\(hashGHI) SAPISID3PHASH 1700000000_\(hashGHI)")
    }

    @Test("The jar's SAPISID, 1P and 3P cookies feed the header")
    func authorizationFromJar() {
        let jar = MusicCookieJar(cookies: [
            cookie("SAPISID", "abc"),
            cookie("__Secure-1PAPISID", "def"),
            cookie("__Secure-3PAPISID", "ghi"),
        ])
        let value = MusicAuthHeaders.authorization(jar: jar, url: musicURL, now: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(value == "SAPISIDHASH 1700000000_\(hashABC) SAPISID1PHASH 1700000000_\(hashDEF) SAPISID3PHASH 1700000000_\(hashGHI)")
    }

    @Test("No SAPISID or __Secure-3PAPISID means no authorization at all")
    func noAuthorization() {
        #expect(MusicAuthHeaders.authorization(sapisid: nil, secure1PAPISID: "def", secure3PAPISID: nil, timestamp: timestamp) == nil)
        let jar = MusicCookieJar(cookies: [cookie("SID", "x"), cookie("__Secure-1PAPISID", "def")])
        #expect(MusicAuthHeaders.authorization(jar: jar, url: musicURL, now: Date()) == nil)
        #expect(MusicAuthHeaders.authorization(jar: MusicCookieJar(), url: musicURL, now: Date()) == nil)
    }

    @Test("The timestamp is whole seconds")
    func timestampIsSeconds() {
        let jar = MusicCookieJar(cookies: [cookie("SAPISID", "abc")])
        let value = MusicAuthHeaders.authorization(jar: jar, url: musicURL, now: Date(timeIntervalSince1970: 1_700_000_000.9))
        #expect(value?.hasPrefix("SAPISIDHASH 1700000000_") == true)
    }

    // MARK: - API headers

    @Test("API headers carry the WEB_REMIX client identity, origin and auth")
    func apiHeaders() throws {
        let jar = MusicCookieJar(cookies: [cookie("SAPISID", "abc")])
        let headers = try #require(MusicAuthHeaders.apiHeaders(
            jar: jar, url: musicURL, clientVersion: "1.20261013.15.00",
            visitorData: "VISITOR", now: Date(timeIntervalSince1970: 1_700_000_000)
        ))
        #expect(headers["Authorization"] == "SAPISIDHASH 1700000000_\(hashABC)")
        #expect(headers["X-Goog-AuthUser"] == "0")
        #expect(headers["X-Goog-Visitor-Id"] == "VISITOR")
        #expect(headers["X-YouTube-Client-Name"] == "67")
        #expect(headers["X-YouTube-Client-Version"] == "1.20261013.15.00")
        #expect(headers["Origin"] == "https://music.youtube.com")
        #expect(headers["X-Origin"] == "https://music.youtube.com")
        #expect(headers["Referer"] == "https://music.youtube.com/")
        #expect(headers["Content-Type"] == "application/json")
        #expect(headers["User-Agent"] == MusicAuthHeaders.userAgent)
    }

    @Test("A missing visitor id leaves the header out")
    func noVisitorHeader() throws {
        let jar = MusicCookieJar(cookies: [cookie("SAPISID", "abc")])
        let headers = try #require(MusicAuthHeaders.apiHeaders(
            jar: jar, url: musicURL, clientVersion: "1.0", visitorData: nil, now: Date()
        ))
        #expect(headers["X-Goog-Visitor-Id"] == nil)
    }

    @Test("API headers are nil when signed out")
    func apiHeadersSignedOut() {
        #expect(MusicAuthHeaders.apiHeaders(
            jar: MusicCookieJar(), url: musicURL, clientVersion: "1.0", visitorData: "V", now: Date()
        ) == nil)
    }

    @Test("The user agent is a Safari on macOS string")
    func userAgentShape() {
        let agent = MusicAuthHeaders.userAgent
        #expect(agent.contains("Macintosh"))
        #expect(agent.contains("Version/"))
        #expect(agent.hasSuffix("Safari/605.1.15"))
        #expect(!agent.contains("Chrome"))
    }
}
