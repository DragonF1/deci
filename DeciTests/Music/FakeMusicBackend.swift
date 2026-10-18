// DeciTests/Music/FakeMusicBackend.swift
// Test doubles for the Music tab: a scriptable backend, a fake AVPlayer seam and small fixtures.

import Foundation
import MediaPlayer
@testable import Deci

// MediaPlayer re-exports AudioToolbox, whose `MusicTrack` and `MusicPlayer` clash with ours: spell them `Deci.MusicTrack` in files that import it.

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
        let kind: HistoryPing.Kind
        let url: URL
        let cpn: String
        let mediaTime: TimeInterval
    }

    nonisolated struct MoreRadioCall: Hashable, Sendable {
        let seed: String
        let continuation: String
    }

    private var signedIn: Bool
    private var signInError: (any Error)?
    private var searchResults: [String: [Deci.MusicTrack]] = [:]
    private var searchErrors: [String: any Error] = [:]
    private var searchGates: [String: MusicTestGate] = [:]
    private var streams: [String: ResolvedStream] = [:]
    private var resolveErrors: [String: any Error] = [:]
    private var resolveGates: [String: MusicTestGate] = [:]
    private var reportErrors: [HistoryPing.Kind: any Error] = [:]
    private var reportStatus = 204
    private var radioPages: [String: MusicQueuePage] = [:]
    private var radioErrors: [String: any Error] = [:]
    private var radioGates: [String: MusicTestGate] = [:]
    private var morePages: [MoreRadioCall: MusicQueuePage] = [:]
    private var moreErrors: [MoreRadioCall: any Error] = [:]
    private var moreGates: [MoreRadioCall: MusicTestGate] = [:]

    private(set) var radioSeeds: [String] = []
    private(set) var moreRadioCalls: [MoreRadioCall] = []
    private(set) var searchedQueries: [String] = []
    private(set) var resolvedIDs: [String] = []
    private(set) var reportAttempts: [Report] = []
    private(set) var signInCookies: [[StoredCookie]] = []
    private var identity: Bool?
    private var currentCookies: [StoredCookie] = []
    private(set) var signOutCount = 0

    init(signedIn: Bool = true) {
        self.signedIn = signedIn
    }

    // MARK: Scripting

    func setSignedIn(_ value: Bool) { signedIn = value }
    func setChannelIdentity(_ value: Bool?) { identity = value }
    func setSessionCookies(_ value: [StoredCookie]) { currentCookies = value }
    func setSignInError(_ error: (any Error)?) { signInError = error }
    func setSearch(_ query: String, results: [Deci.MusicTrack]) { searchResults[query] = results }
    func setSearchError(_ query: String, _ error: any Error) { searchErrors[query] = error }
    func setSearchGate(_ query: String, _ gate: MusicTestGate) { searchGates[query] = gate }
    func setStream(_ stream: ResolvedStream) { streams[stream.videoId] = stream }
    func setResolveError(_ videoId: String, _ error: any Error) { resolveErrors[videoId] = error }
    func clearResolveError(_ videoId: String) { resolveErrors[videoId] = nil }
    func setResolveGate(_ videoId: String, _ gate: MusicTestGate) { resolveGates[videoId] = gate }
    /// Makes history pings throw `error`: both kinds, or just `kind` when given. Nil clears.
    func setReportError(_ error: (any Error)?, kind: HistoryPing.Kind? = nil) {
        for each in kind.map({ [$0] }) ?? [.playback, .watchtime] { reportErrors[each] = error }
    }
    func setReportStatus(_ status: Int) { reportStatus = status }
    func setRadio(seed: String, tracks: [Deci.MusicTrack], continuation: String? = nil) {
        radioPages[seed] = MusicQueuePage(tracks: tracks, continuation: continuation)
    }
    func setRadioError(seed: String, _ error: any Error) { radioErrors[seed] = error }
    func setRadioGate(seed: String, _ gate: MusicTestGate) { radioGates[seed] = gate }
    func setMoreRadio(seed: String, continuation: String, tracks: [Deci.MusicTrack], next: String? = nil) {
        morePages[MoreRadioCall(seed: seed, continuation: continuation)] = MusicQueuePage(tracks: tracks, continuation: next)
    }
    func setMoreRadioError(seed: String, continuation: String, _ error: any Error) {
        moreErrors[MoreRadioCall(seed: seed, continuation: continuation)] = error
    }
    func setMoreRadioGate(seed: String, continuation: String, _ gate: MusicTestGate) {
        moreGates[MoreRadioCall(seed: seed, continuation: continuation)] = gate
    }

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

    func channelIdentity() async -> Bool? { signedIn ? identity : nil }

    func sessionCookies() async -> [StoredCookie] { currentCookies }

    func search(_ query: String) async throws -> [Deci.MusicTrack] {
        searchedQueries.append(query)
        if let gate = searchGates[query] { await gate.wait() }
        if let error = searchErrors[query] { throw error }
        return searchResults[query] ?? []
    }

    func resolve(videoId: String) async throws -> ResolvedStream {
        resolvedIDs.append(videoId)
        if let gate = resolveGates[videoId] { await gate.wait() }
        if let error = resolveErrors[videoId] { throw error }
        return streams[videoId] ?? MusicSamples.stream(videoId: videoId)
    }

    func radio(seedVideoId: String) async throws -> MusicQueuePage {
        radioSeeds.append(seedVideoId)
        if let gate = radioGates[seedVideoId] { await gate.wait() }
        if let error = radioErrors[seedVideoId] { throw error }
        return radioPages[seedVideoId] ?? MusicQueuePage(tracks: [], continuation: nil)
    }

    func moreRadio(seedVideoId: String, continuation: String) async throws -> MusicQueuePage {
        let call = MoreRadioCall(seed: seedVideoId, continuation: continuation)
        moreRadioCalls.append(call)
        if let gate = moreGates[call] { await gate.wait() }
        if let error = moreErrors[call] { throw error }
        return morePages[call] ?? MusicQueuePage(tracks: [], continuation: nil)
    }

    func reportHistory(_ ping: HistoryPing) async throws -> Int {
        reportAttempts.append(Report(kind: ping.kind, url: ping.url, cpn: ping.cpn, mediaTime: ping.mediaTime))
        if let error = reportErrors[ping.kind] { throw error }
        return reportStatus
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

/// Stands in for MPNowPlayingInfoCenter and MPRemoteCommandCenter: records what the controller asked for.
@MainActor
final class FakeNowPlayingSurface: NowPlayingSurface {
    struct Published {
        let info: [String: Any]
        let isPlaying: Bool

        var title: String? { info[MPMediaItemPropertyTitle] as? String }
        var elapsed: Double? { info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double }
        var duration: Double? { info[MPMediaItemPropertyPlaybackDuration] as? Double }
        var rate: Double? { info[MPNowPlayingInfoPropertyPlaybackRate] as? Double }
    }

    private(set) var published: [Published] = []
    private(set) var clearCount = 0
    private(set) var registerCount = 0
    private(set) var removeCount = 0
    private var handler: (@MainActor (NowPlayingCommand) -> Void)?

    var last: Published? { published.last }
    var hasCommands: Bool { handler != nil }

    func setInfo(_ info: [String: Any], isPlaying: Bool) {
        published.append(Published(info: info, isPlaying: isPlaying))
    }

    func clearInfo() { clearCount += 1 }

    func registerCommands(_ handler: @escaping @MainActor (NowPlayingCommand) -> Void) {
        registerCount += 1
        self.handler = handler
    }

    func removeCommands() {
        removeCount += 1
        handler = nil
    }

    /// What a media key press does.
    func send(_ command: NowPlayingCommand) { handler?(command) }
}

nonisolated enum MusicSamples {
    static func track(_ id: String = "vid1", title: String = "Song", artist: String = "Artist", seconds: Int? = 200) -> Deci.MusicTrack {
        Deci.MusicTrack(videoId: id, title: title, artist: artist, album: nil, durationSeconds: seconds, thumbnailURL: nil)
    }

    static func tracks(_ ids: String...) -> [Deci.MusicTrack] {
        ids.map { track($0, title: "Song \($0)") }
    }

    static func stream(
        videoId: String = "vid1",
        expiresAt: Date = Date(timeIntervalSinceNow: 6 * 3600),
        trackingURL: URL? = URL(string: "https://music.example.test/stats?ev=1"),
        watchtimeURL: URL? = nil,
        duration: Double? = 200
    ) -> ResolvedStream {
        ResolvedStream(
            videoId: videoId,
            url: URL(string: "https://media.example.test/\(videoId).m4a")!,
            itag: 140,
            durationSeconds: duration,
            expiresAt: expiresAt,
            playbackTrackingURL: trackingURL,
            watchtimeTrackingURL: watchtimeURL,
            httpHeaders: ["User-Agent": "test-agent"]
        )
    }

    static func cookie(_ name: String, domain: String) -> HTTPCookie {
        HTTPCookie(properties: [.name: name, .value: "v", .domain: domain, .path: "/"])!
    }
}
