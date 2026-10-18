// DeciTests/Music/MusicCookieJarTests.swift
// The Google sign-in cookie jar: Set-Cookie merging, rotation, deletion, and which cookies
// go to which host.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("MusicCookieJar")
struct MusicCookieJarTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let musicURL = URL(string: "https://music.youtube.com/youtubei/v1/search")!

    private func cookie(
        _ name: String,
        _ value: String,
        domain: String = ".youtube.com",
        path: String = "/",
        expires: Date? = nil,
        secure: Bool = true
    ) -> StoredCookie {
        StoredCookie(
            name: name, value: value, domain: domain, path: path,
            expires: expires, isSecure: secure, isHTTPOnly: false
        )
    }

    // MARK: - Merging Set-Cookie

    @Test("Set-Cookie headers are parsed into the jar")
    func mergesSetCookie() {
        var jar = MusicCookieJar()
        let changed = jar.merge(
            headerFields: ["Set-Cookie": "VISITOR_INFO1_LIVE=abc; Domain=.youtube.com; Path=/; Secure; HttpOnly"],
            for: musicURL, now: now
        )
        #expect(changed)
        #expect(jar.cookies.count == 1)
        #expect(jar.cookies[0].name == "VISITOR_INFO1_LIVE")
        #expect(jar.cookies[0].value == "abc")
        #expect(jar.cookies[0].domain == ".youtube.com")
        #expect(jar.cookies[0].isSecure)
        #expect(jar.cookies[0].isHTTPOnly)
    }

    @Test("A host-only Set-Cookie takes the request host as its domain")
    func hostOnlyCookieDomain() {
        var jar = MusicCookieJar()
        _ = jar.merge(headerFields: ["Set-Cookie": "YSC=xyz; Path=/; Secure"], for: musicURL, now: now)
        #expect(jar.cookies.first?.domain == "music.youtube.com")
    }

    @Test("Several cookies joined in one header are all merged")
    func mergesMultipleCookies() {
        var jar = MusicCookieJar()
        let header = "A=1; Domain=.youtube.com; Path=/; Secure, B=2; Domain=.youtube.com; Path=/; Secure"
        _ = jar.merge(headerFields: ["Set-Cookie": header], for: musicURL, now: now)
        #expect(Set(jar.cookies.map(\.name)) == ["A", "B"])
    }

    @Test("A rotated cookie replaces the old one with the same name, domain and path")
    func rotationReplaces() {
        var jar = MusicCookieJar(cookies: [cookie("__Secure-1PSIDTS", "old"), cookie("SAPISID", "keep")])
        let changed = jar.merge(
            headerFields: ["Set-Cookie": "__Secure-1PSIDTS=new; Domain=.youtube.com; Path=/; Secure"],
            for: musicURL, now: now
        )
        #expect(changed)
        #expect(jar.value(named: "__Secure-1PSIDTS") == "new")
        #expect(jar.value(named: "SAPISID") == "keep")
        #expect(jar.cookies.count == 2)
    }

    @Test("The same cookie name on a different domain or path is kept separately")
    func differentDomainKept() {
        var jar = MusicCookieJar(cookies: [cookie("NID", "google", domain: ".google.com")])
        _ = jar.merge(
            headerFields: ["Set-Cookie": "NID=youtube; Domain=.youtube.com; Path=/; Secure"],
            for: musicURL, now: now
        )
        _ = jar.merge(
            headerFields: ["Set-Cookie": "NID=scoped; Domain=.youtube.com; Path=/youtubei; Secure"],
            for: musicURL, now: now
        )
        #expect(jar.cookies.count == 3)
    }

    @Test("Merging an identical cookie reports no change")
    func identicalMergeIsNoChange() {
        var jar = MusicCookieJar()
        let header = ["Set-Cookie": "A=1; Domain=.youtube.com; Path=/; Secure"]
        let first = jar.merge(headerFields: header, for: musicURL, now: now)
        let second = jar.merge(headerFields: header, for: musicURL, now: now)
        #expect(first)
        #expect(!second)
    }

    @Test("Max-Age=0 deletes the cookie")
    func maxAgeZeroDeletes() {
        var jar = MusicCookieJar(cookies: [cookie("LOGIN_INFO", "x")])
        let changed = jar.merge(
            headerFields: ["Set-Cookie": "LOGIN_INFO=; Domain=.youtube.com; Path=/; Max-Age=0; Secure"],
            for: musicURL, now: now
        )
        #expect(changed)
        #expect(jar.value(named: "LOGIN_INFO") == nil)
        #expect(jar.cookies.isEmpty)
    }

    @Test("A past Expires deletes the cookie")
    func pastExpiresDeletes() {
        var jar = MusicCookieJar(cookies: [cookie("LOGIN_INFO", "x")])
        _ = jar.merge(
            headerFields: [
                "Set-Cookie": "LOGIN_INFO=; Domain=.youtube.com; Path=/; Expires=Thu, 01 Jan 1970 00:00:00 GMT; Secure"
            ],
            for: musicURL, now: now
        )
        #expect(jar.cookies.isEmpty)
    }

    @Test("Deleting a cookie that is not in the jar is no change")
    func deleteMissingIsNoChange() {
        var jar = MusicCookieJar(cookies: [cookie("A", "1")])
        let changed = jar.merge(
            headerFields: ["Set-Cookie": "B=; Domain=.youtube.com; Path=/; Max-Age=0"],
            for: musicURL, now: now
        )
        #expect(!changed)
        #expect(jar.cookies.count == 1)
    }

    @Test("A cookie for a domain the response host does not belong to is ignored")
    func foreignDomainRejected() {
        var jar = MusicCookieJar()
        let changed = jar.merge(
            headerFields: ["Set-Cookie": "EVIL=1; Domain=.example.com; Path=/; Secure"],
            for: musicURL, now: now
        )
        #expect(!changed)
        #expect(jar.cookies.isEmpty)
    }

    @Test("Header fields with no Set-Cookie leave the jar alone, whatever the key case")
    func noSetCookie() {
        var jar = MusicCookieJar()
        let unrelated = jar.merge(headerFields: ["Content-Type": "text/html"], for: musicURL, now: now)
        let lowercase = jar.merge(
            headerFields: ["set-cookie": "A=1; Domain=.youtube.com; Path=/"],
            for: musicURL, now: now
        )
        #expect(!unrelated)
        #expect(lowercase)
    }

    // MARK: - Expiry

    @Test("prune drops expired cookies and keeps session and future cookies")
    func pruneExpired() {
        var jar = MusicCookieJar(cookies: [
            cookie("old", "1", expires: now.addingTimeInterval(-1)),
            cookie("edge", "2", expires: now),
            cookie("future", "3", expires: now.addingTimeInterval(60)),
            cookie("session", "4"),
        ])
        let changed = jar.prune(now: now)
        #expect(changed)
        #expect(Set(jar.cookies.map(\.name)) == ["future", "session"])
        let again = jar.prune(now: now)
        #expect(!again)
    }

    @Test("cookieHeader never sends an expired cookie")
    func expiredNotSent() {
        let jar = MusicCookieJar(cookies: [cookie("old", "1", expires: now.addingTimeInterval(-5))])
        #expect(jar.cookieHeader(for: musicURL, now: now) == nil)
    }

    // MARK: - Which cookies go where

    @Test("A leading-dot domain matches the domain itself and every subdomain")
    func leadingDotDomain() {
        let jar = MusicCookieJar(cookies: [cookie("SID", "1", domain: ".youtube.com")])
        #expect(jar.cookieHeader(for: URL(string: "https://music.youtube.com/")!, now: now) == "SID=1")
        #expect(jar.cookieHeader(for: URL(string: "https://www.youtube.com/")!, now: now) == "SID=1")
        #expect(jar.cookieHeader(for: URL(string: "https://youtube.com/")!, now: now) == "SID=1")
        #expect(jar.cookieHeader(for: URL(string: "https://s.youtube.com/api/stats/playback")!, now: now) == "SID=1")
    }

    @Test("A domain never matches a lookalike that only shares the suffix text")
    func lookalikeDomainRejected() {
        let jar = MusicCookieJar(cookies: [cookie("SID", "1", domain: ".youtube.com")])
        #expect(jar.cookieHeader(for: URL(string: "https://evilyoutube.com/")!, now: now) == nil)
        #expect(jar.cookieHeader(for: URL(string: "https://youtube.com.evil.net/")!, now: now) == nil)
    }

    @Test("Google cookies go to google.com hosts, not to YouTube")
    func googleAndYouTubeAreSeparate() {
        let jar = MusicCookieJar(cookies: [
            cookie("SID", "g", domain: ".google.com"),
            cookie("SAPISID", "y", domain: ".youtube.com"),
        ])
        #expect(jar.cookieHeader(for: URL(string: "https://accounts.google.com/")!, now: now) == "SID=g")
        #expect(jar.cookieHeader(for: musicURL, now: now) == "SAPISID=y")
    }

    @Test("A host-only cookie matches only its own host")
    func hostOnlyDomain() {
        let jar = MusicCookieJar(cookies: [cookie("YSC", "1", domain: "music.youtube.com")])
        #expect(jar.cookieHeader(for: musicURL, now: now) == "YSC=1")
        #expect(jar.cookieHeader(for: URL(string: "https://www.youtube.com/")!, now: now) == nil)
        #expect(jar.cookieHeader(for: URL(string: "https://a.music.youtube.com/")!, now: now) == nil)
    }

    @Test("Domain matching ignores case")
    func domainCase() {
        let jar = MusicCookieJar(cookies: [cookie("SID", "1", domain: ".YouTube.com")])
        #expect(jar.cookieHeader(for: musicURL, now: now) == "SID=1")
    }

    @Test("Path matching follows the cookie path prefix rules")
    func pathMatching() {
        let jar = MusicCookieJar(cookies: [cookie("P", "1", path: "/youtubei")])
        #expect(jar.cookieHeader(for: URL(string: "https://music.youtube.com/youtubei")!, now: now) == "P=1")
        #expect(jar.cookieHeader(for: URL(string: "https://music.youtube.com/youtubei/v1/player")!, now: now) == "P=1")
        #expect(jar.cookieHeader(for: URL(string: "https://music.youtube.com/youtubeix")!, now: now) == nil)
        #expect(jar.cookieHeader(for: URL(string: "https://music.youtube.com/")!, now: now) == nil)
    }

    @Test("A root-path cookie matches every path, including none")
    func rootPath() {
        let jar = MusicCookieJar(cookies: [cookie("R", "1")])
        #expect(jar.cookieHeader(for: URL(string: "https://music.youtube.com")!, now: now) == "R=1")
        #expect(jar.cookieHeader(for: URL(string: "https://music.youtube.com/a/b?x=1")!, now: now) == "R=1")
    }

    @Test("Secure cookies are not sent over plain http")
    func secureOnlyOverHTTPS() {
        let jar = MusicCookieJar(cookies: [cookie("S", "1", secure: true), cookie("L", "2", secure: false)])
        #expect(jar.cookieHeader(for: URL(string: "http://music.youtube.com/")!, now: now) == "L=2")
        #expect(jar.cookieHeader(for: musicURL, now: now) == "S=1; L=2")
    }

    @Test("The most specific path is sent first")
    func longerPathFirst() {
        let jar = MusicCookieJar(cookies: [cookie("A", "1", path: "/"), cookie("B", "2", path: "/youtubei")])
        #expect(jar.cookieHeader(for: musicURL, now: now) == "B=2; A=1")
    }

    @Test("Same-named cookies from different domains are both sent when both match")
    func duplicateNamesBothSent() {
        let jar = MusicCookieJar(cookies: [
            cookie("X", "wide", domain: ".youtube.com"),
            cookie("X", "narrow", domain: "music.youtube.com"),
        ])
        #expect(jar.cookieHeader(for: musicURL, now: now) == "X=wide; X=narrow")
    }

    @Test("cookieHeader is nil when nothing matches")
    func emptyHeaderIsNil() {
        #expect(MusicCookieJar().cookieHeader(for: musicURL, now: now) == nil)
    }

    // MARK: - Lookup

    @Test("value(named:for:) reads only the cookie that would be sent to the URL")
    func valueLookup() {
        let jar = MusicCookieJar(cookies: [
            cookie("SAPISID", "google", domain: ".google.com"),
            cookie("SAPISID", "youtube", domain: ".youtube.com"),
            cookie("ONLY_GOOGLE", "g", domain: ".google.com"),
        ])
        #expect(jar.value(named: "SAPISID", for: musicURL, now: now) == "youtube")
        #expect(jar.value(named: "ONLY_GOOGLE", for: musicURL, now: now) == nil)
        #expect(jar.value(named: "missing", for: musicURL, now: now) == nil)
    }

    @Test("value(named:) reads only youtube.com cookies")
    func valueIgnoresGoogleCookies() {
        let jar = MusicCookieJar(cookies: [
            cookie("SAPISID", "google", domain: ".google.com"),
            cookie("ONLY_GOOGLE", "g", domain: "accounts.google.com"),
            cookie("SAPISID", "music", domain: "music.youtube.com"),
        ])
        #expect(jar.value(named: "SAPISID") == "music")
        #expect(jar.value(named: "ONLY_GOOGLE") == nil)
        #expect(MusicCookieJar(cookies: [cookie("SAPISID", "google", domain: ".google.com")]).value(named: "SAPISID") == nil)
    }

    @Test("isYouTubeDomain accepts youtube.com and its subdomains only")
    func youTubeDomainCheck() {
        for domain in [".youtube.com", "youtube.com", "music.youtube.com", ".MUSIC.YouTube.com"] {
            #expect(MusicCookieJar.isYouTubeDomain(domain), "\(domain)")
        }
        for domain in [".google.com", "accounts.google.com", "notyoutube.com", ".evil-youtube.com", "youtube.com.evil.net", "", "."] {
            #expect(!MusicCookieJar.isYouTubeDomain(domain), "\(domain)")
        }
    }

    @Test("value(named:) skips an empty value")
    func emptyValueIsMissing() {
        let jar = MusicCookieJar(cookies: [cookie("SAPISID", "")])
        #expect(jar.value(named: "SAPISID") == nil)
    }

    // MARK: - Codable

    @Test("The jar encodes as a plain array of stored cookies and round-trips")
    func codableRoundTrip() throws {
        let jar = MusicCookieJar(cookies: [
            cookie("SAPISID", "a", expires: now.addingTimeInterval(1000)),
            cookie("SID", "b", domain: ".google.com", path: "/accounts", secure: false),
        ])
        let data = try JSONEncoder().encode(jar)
        let plain = try JSONDecoder().decode([StoredCookie].self, from: data)
        #expect(plain == jar.cookies)
        let decoded = try JSONDecoder().decode(MusicCookieJar.self, from: data)
        #expect(decoded == jar)
    }

    @Test("Init from the sign-in window's cookies drops expired ones")
    func initFromSignInCookies() {
        let jar = MusicCookieJar(signInCookies: [
            cookie("live", "1", expires: now.addingTimeInterval(5)),
            cookie("dead", "2", expires: now.addingTimeInterval(-5)),
        ], now: now)
        #expect(jar.cookies.map(\.name) == ["live"])
    }

    @Test("Sign-in cookies with the same identity collapse to the last one")
    func initDeduplicates() {
        let jar = MusicCookieJar(signInCookies: [cookie("A", "1"), cookie("A", "2")], now: now)
        #expect(jar.cookies.count == 1)
        #expect(jar.value(named: "A") == "2")
    }

    @Test("Signed-in means a SAPISID or __Secure-3PAPISID is present")
    func signedInDetection() {
        #expect(!MusicCookieJar().hasSignInCookies)
        #expect(!MusicCookieJar(cookies: [cookie("SID", "1")]).hasSignInCookies)
        #expect(MusicCookieJar(cookies: [cookie("SAPISID", "1")]).hasSignInCookies)
        #expect(MusicCookieJar(cookies: [cookie("__Secure-3PAPISID", "1")]).hasSignInCookies)
    }

    @Test("A SAPISID on google.com is not a sign-in")
    func googleSapisidIsNotSignedIn() {
        #expect(!MusicCookieJar(cookies: [cookie("SAPISID", "1", domain: ".google.com")]).hasSignInCookies)
        #expect(!MusicCookieJar(cookies: [cookie("__Secure-3PAPISID", "1", domain: "accounts.google.com")]).hasSignInCookies)
        #expect(MusicCookieJar(cookies: [cookie("SAPISID", "1", domain: "music.youtube.com")]).hasSignInCookies)
    }

    // MARK: - Sign-in snapshot

    @Test("The sign-in snapshot ignores an expiry-only difference")
    func snapshotIgnoresExpiry() {
        let early = MusicCookieJar(cookies: [cookie("SAPISID", "v", expires: now.addingTimeInterval(1_000))])
        let late = MusicCookieJar(cookies: [cookie("SAPISID", "v", expires: now.addingTimeInterval(9_000_000))])
        let session = MusicCookieJar(cookies: [cookie("SAPISID", "v", expires: nil)])
        #expect(early.signInSnapshot == late.signInSnapshot)
        #expect(early.signInSnapshot == session.signInSnapshot)
    }

    @Test("The sign-in snapshot changes with a value, the secure flag, the domain, the path, an addition or a removal")
    func snapshotSeesEverythingElse() {
        let base = MusicCookieJar(cookies: [cookie("SAPISID", "v")])
        let changed: [MusicCookieJar] = [
            MusicCookieJar(cookies: [cookie("SAPISID", "other")]),
            MusicCookieJar(cookies: [cookie("SAPISID", "v", secure: false)]),
            MusicCookieJar(cookies: [cookie("SAPISID", "v", domain: ".music.youtube.com")]),
            MusicCookieJar(cookies: [cookie("SAPISID", "v", path: "/youtubei")]),
            MusicCookieJar(cookies: [cookie("SAPISID", "v"), cookie("LOGIN_INFO", "x")]),
            MusicCookieJar(cookies: []),
        ]
        for jar in changed {
            #expect(jar.signInSnapshot != base.signInSnapshot)
        }
    }

    @Test("The sign-in snapshot reads domain case and an empty path the way the jar matches them")
    func snapshotNormalisesIdentity() {
        let plain = MusicCookieJar(cookies: [cookie("SAPISID", "v", domain: ".youtube.com", path: "/")])
        let shouty = MusicCookieJar(cookies: [cookie("SAPISID", "v", domain: ".YouTube.COM", path: "")])
        #expect(plain.signInSnapshot == shouty.signInSnapshot)
    }

    @Test("The sign-in snapshot leaves every other cookie out")
    func snapshotIgnoresOtherCookies() {
        let base = MusicCookieJar(cookies: [cookie("SAPISID", "v")])
        let busy = MusicCookieJar(cookies: [cookie("SAPISID", "v"), cookie("YSC", "1"), cookie("PREF", "2")])
        #expect(base.signInSnapshot == busy.signInSnapshot)
    }
}
