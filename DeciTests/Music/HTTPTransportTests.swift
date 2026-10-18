// DeciTests/Music/HTTPTransportTests.swift
// The URLSession-backed transport: no ambient cookies, cache or credentials, and a redirect
// guard that never carries auth headers off the host they were meant for.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("HTTPTransport")
struct HTTPTransportTests {

    @Test("The session configuration keeps cookies, cache and credentials out of the picture")
    func configurationIsIsolated() {
        let config = URLSessionTransport.makeConfiguration()
        #expect(config.httpShouldSetCookies == false)
        #expect(config.httpCookieStorage == nil)
        #expect(config.urlCache == nil)
        #expect(config.urlCredentialStorage == nil)
        #expect(config.requestCachePolicy == .reloadIgnoringLocalCacheData)
        #expect(config.httpCookieAcceptPolicy == .never)
        #expect(config.timeoutIntervalForRequest > 0)
    }

    @Test("The configuration is ephemeral, so nothing is written to disk")
    func configurationIsEphemeral() {
        // Ephemeral configurations have no persistent identifier.
        #expect(URLSessionTransport.makeConfiguration().identifier == nil)
    }

    @Test("A redirect to plain http is refused")
    func redirectToHTTPRefused() {
        let original = URL(string: "https://music.youtube.com/a")!
        var next = URLRequest(url: URL(string: "http://music.youtube.com/b")!)
        next.setValue("secret", forHTTPHeaderField: "Cookie")
        #expect(RedirectGuard.redirected(next, from: original) == nil)
    }

    @Test("A same-host https redirect keeps its headers")
    func redirectSameHostKeepsHeaders() throws {
        let original = URL(string: "https://music.youtube.com/a")!
        var next = URLRequest(url: URL(string: "https://music.youtube.com/b")!)
        next.setValue("c=1", forHTTPHeaderField: "Cookie")
        next.setValue("SAPISIDHASH x", forHTTPHeaderField: "Authorization")
        let kept = try #require(RedirectGuard.redirected(next, from: original))
        #expect(kept.value(forHTTPHeaderField: "Cookie") == "c=1")
        #expect(kept.value(forHTTPHeaderField: "Authorization") == "SAPISIDHASH x")
    }

    @Test("A cross-host redirect sheds every credential-bearing header")
    func redirectCrossHostStripsCredentials() throws {
        let original = URL(string: "https://music.youtube.com/a")!
        var next = URLRequest(url: URL(string: "https://example.com/b")!)
        for (name, value) in [
            "Cookie": "c=1", "Authorization": "SAPISIDHASH x", "X-Goog-AuthUser": "0",
            "X-Goog-Visitor-Id": "v", "X-Origin": "https://music.youtube.com",
            "Origin": "https://music.youtube.com", "User-Agent": "UA",
        ] {
            next.setValue(value, forHTTPHeaderField: name)
        }
        let kept = try #require(RedirectGuard.redirected(next, from: original))
        for name in ["Cookie", "Authorization", "X-Goog-AuthUser", "X-Goog-Visitor-Id", "X-Origin", "Origin"] {
            #expect(kept.value(forHTTPHeaderField: name) == nil, "\(name) leaked")
        }
        #expect(kept.value(forHTTPHeaderField: "User-Agent") == "UA")
    }

    @Test("Header stripping is case-insensitive")
    func redirectStripsCaseInsensitively() throws {
        let original = URL(string: "https://music.youtube.com/a")!
        var next = URLRequest(url: URL(string: "https://evil.test/b")!)
        next.setValue("c=1", forHTTPHeaderField: "cookie")
        let kept = try #require(RedirectGuard.redirected(next, from: original))
        #expect(kept.value(forHTTPHeaderField: "Cookie") == nil)
    }

    @Test("A request with no URL host is refused")
    func redirectWithoutHost() {
        let original = URL(string: "https://music.youtube.com/a")!
        let next = URLRequest(url: URL(string: "https:///path")!)
        #expect(RedirectGuard.redirected(next, from: original) == nil)
    }

    @Test("HTTPResponse header lookup ignores case")
    func responseHeaderLookup() {
        let response = HTTPResponse(statusCode: 200, headers: ["Content-Type": "text/html"], data: Data())
        #expect(response.header("content-type") == "text/html")
        #expect(response.header("missing") == nil)
    }

    @Test("A URLRequest is built from an HTTPRequest with method, headers and body")
    func urlRequestBuilding() {
        let request = HTTPRequest(
            url: URL(string: "https://music.youtube.com/youtubei/v1/search")!,
            method: "POST",
            headers: ["Content-Type": "application/json"],
            body: Data("{}".utf8)
        )
        let built = URLSessionTransport.urlRequest(for: request)
        #expect(built.httpMethod == "POST")
        #expect(built.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(built.httpBody == Data("{}".utf8))
        #expect(built.httpShouldHandleCookies == false)
    }
}
