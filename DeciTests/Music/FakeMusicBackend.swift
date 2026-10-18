// DeciTests/Music/FakeMusicBackend.swift
// Test doubles for the Music tab: a scriptable backend, a fake AVPlayer seam and small fixtures.

import Foundation
@testable import Deci

/// Suspends callers until `open()`; lets a test hold a request in flight.
actor MusicTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }
}

actor FakeMusicBackend: MusicBackend {
    nonisolated struct Report: Equatable, Sendable {
        let url: URL
        let cpn: String
    }

    private var signedIn: Bool
    private var signInError: (any Error)?
    private var searchResults: [String: [MusicTrack]] = [:]
    private var searchErrors: [String: any Error] = [:]
    private var searchGates: [String: MusicTestGate] = [:]
    private var streams: [String: ResolvedStream] = [:]
    private var resolveErrors: [String: any Error] = [:]
    private var resolveGates: [String: MusicTestGate] = [:]
    private var reportError: (any Error)?

    private(set) var searchedQueries: [String] = []
    private(set) var resolvedIDs: [String] = []
    private(set) var reportAttempts: [Report] = []
    private(set) var signInCookies: [[StoredCookie]] = []
    private(set) var signOutCount = 0

    init(signedIn: Bool = true) {
        self.signedIn = signedIn
    }

    // MARK: Scripting

    func setSignedIn(_ value: Bool) { signedIn = value }
    func setSignInError(_ error: (any Error)?) { signInError = error }
    func setSearch(_ query: String, results: [MusicTrack]) { searchResults[query] = results }
    func setSearchError(_ query: String, _ error: any Error) { searchErrors[query] = error }
    func setSearchGate(_ query: String, _ gate: MusicTestGate) { searchGates[query] = gate }
    func setStream(_ stream: ResolvedStream) { streams[stream.videoId] = stream }
    func setResolveError(_ videoId: String, _ error: any Error) { resolveErrors[videoId] = error }
    func setResolveGate(_ videoId: String, _ gate: MusicTestGate) { resolveGates[videoId] = gate }
    func setReportError(_ error: (any Error)?) { reportError = error }

    // MARK: MusicBackend

    func isSignedIn() async -> Bool { signedIn }

    func signIn(with cookies: [StoredCookie]) async throws {
        signInCookies.append(cookies)
        if let signInError { throw signInError }
        signedIn = true
    }

    func signOut() async {
        signOutCount += 1
        signedIn = false
    }

    func search(_ query: String) async throws -> [MusicTrack] {
        searchedQueries.append(query)
        if let gate = searchGates[query] { await gate.wait() }
        if let error = searchErrors[query] { throw error }
        return searchResults[query] ?? []
    }

    func resolve(videoId: String) async throws -> ResolvedStream {
        resolvedIDs.append(videoId)
        if let gate = resolveGates[videoId] { await gate.wait() }
        if let error = resolveErrors[videoId] { throw error }
        return streams[videoId] ?? MusicFixtures.stream(videoId: videoId)
    }

    func reportPlayback(trackingURL: URL, cpn: String) async throws {
        reportAttempts.append(Report(url: trackingURL, cpn: cpn))
        if let reportError { throw reportError }
    }
}

/// Stands in for AVPlayer: records what the player asked for and lets a test fire engine events.
@MainActor
final class FakePlaybackEngine: PlaybackEngine {
    struct Load {
        let stream: ResolvedStream
        let startAt: TimeInterval
        let autoplay: Bool
    }

    var onTick: (@MainActor (TimeInterval, Bool) -> Void)?
    var onEvent: (@MainActor (PlaybackEngineEvent) -> Void)?
    var position: TimeInterval = 0

    private(set) var loads: [Load] = []
    private(set) var playCount = 0
    private(set) var pauseCount = 0
    private(set) var seeks: [TimeInterval] = []
    private(set) var unloadCount = 0

    func load(_ stream: ResolvedStream, startAt: TimeInterval, autoplay: Bool) {
        loads.append(Load(stream: stream, startAt: startAt, autoplay: autoplay))
    }

    func play() { playCount += 1 }
    func pause() { pauseCount += 1 }
    func seek(to seconds: TimeInterval) { seeks.append(seconds) }
    func unload() { unloadCount += 1 }

    func emit(_ event: PlaybackEngineEvent) { onEvent?(event) }
    func tick(_ position: TimeInterval, playing: Bool) {
        self.position = position
        onTick?(position, playing)
    }
}

nonisolated enum MusicFixtures {
    static func track(_ id: String = "vid1", title: String = "Song", artist: String = "Artist", seconds: Int? = 200) -> MusicTrack {
        MusicTrack(videoId: id, title: title, artist: artist, album: nil, durationSeconds: seconds, thumbnailURL: nil)
    }

    static func stream(
        videoId: String = "vid1",
        expiresAt: Date = Date(timeIntervalSinceNow: 6 * 3600),
        trackingURL: URL? = URL(string: "https://music.example.test/stats?ev=1"),
        duration: Double? = 200
    ) -> ResolvedStream {
        ResolvedStream(
            videoId: videoId,
            url: URL(string: "https://media.example.test/\(videoId).m4a")!,
            itag: 140,
            durationSeconds: duration,
            expiresAt: expiresAt,
            playbackTrackingURL: trackingURL,
            httpHeaders: ["User-Agent": "test-agent"]
        )
    }

    static func cookie(_ name: String, domain: String) -> HTTPCookie {
        HTTPCookie(properties: [.name: name, .value: "v", .domain: domain, .path: "/"])!
    }
}
