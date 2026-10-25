// DeciTests/Music/MusicCollectionTestSupport.swift
// What the collection download tests share beyond the single-song support: a pause that never waits and writes down what
// it was asked for, a fetcher that serves cover images from memory, and the page a downloaded playlist is scripted as.
// Nothing here touches the network or the real clock.

import Foundation
import os
import Testing
@testable import Deci

/// Stands in for every wait the queue makes (the gap between songs, the back-off after a rate limit). It returns at once
/// and keeps the seconds it was asked for, so a test reads the waits instead of sitting through them. With
/// `blocksBackoff` a wait of a second or more parks until its task is cancelled, which holds the queue in a back-off
/// the way the real wait does.
nonisolated final class RecordingPause: Sendable {
    typealias Hook = @Sendable (Int, TimeInterval) async -> Void

    private struct State {
        var waits: [TimeInterval] = []
        var blocksBackoff = false
        var hook: Hook?
        var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Every wait asked for, in order.
    var waits: [TimeInterval] { state.withLock { $0.waits } }

    /// The waits of a second or more: the back-offs, without the half-second gaps between songs.
    var backoffs: [TimeInterval] { waits.filter { $0 >= 1 } }

    func blockBackoff(_ blocks: Bool = true) {
        state.withLock { $0.blocksBackoff = blocks }
    }

    /// Runs after each wait is written down, with its number (from 0) and its length.
    func onWait(_ hook: Hook?) {
        state.withLock { $0.hook = hook }
    }

    var closure: MusicDownloadService.Pause {
        { [self] seconds in try await wait(seconds) }
    }

    private func wait(_ seconds: TimeInterval) async throws {
        let (number, blocks, hook, ready) = state.withLock { state -> (Int, Bool, Hook?, [CheckedContinuation<Void, Never>]) in
            state.waits.append(seconds)
            let ready = state.waiters.filter { $0.count <= state.waits.count }.map(\.continuation)
            state.waiters.removeAll { $0.count <= state.waits.count }
            return (state.waits.count - 1, state.blocksBackoff, state.hook, ready)
        }
        for continuation in ready { continuation.resume() }
        await hook?(number, seconds)
        if blocks, seconds >= 1 { try await Task.sleep(for: .seconds(3_600)) }
        try Task.checkCancellation()
    }

    /// Returns once `count` waits have been asked for.
    func waitForCount(_ count: Int) async {
        await withCheckedContinuation { continuation in
            let done = state.withLock { state -> Bool in
                if state.waits.count >= count { return true }
                state.waiters.append((count, continuation))
                return false
            }
            if done { continuation.resume() }
        }
    }
}

/// Serves a cover image for any URL from memory: the bytes are the URL's own text, so two URLs give two different files.
/// `failing` says which URLs answer with an error instead. With a `gate`, every fetch waits there until it is opened, which
/// holds a cover in flight.
actor FakeCoverFetcher: MusicCoverFetching {
    typealias Rule = @Sendable (URL) -> Bool

    private(set) var requested: [URL] = []
    private let failing: Rule
    private let gate: MusicTestGate?

    init(failing: @escaping Rule = { _ in false }, gate: MusicTestGate? = nil) {
        self.failing = failing
        self.gate = gate
    }

    func fetch(_ url: URL) async throws -> Data {
        requested.append(url)
        if let gate { await gate.wait() }
        if failing(url) { throw URLError(.notConnectedToInternet) }
        return Self.image(for: url)
    }

    nonisolated static func image(for url: URL) -> Data {
        Data("image:\(url.absoluteString)".utf8)
    }
}

extension MusicTrack {
    /// The same track with a cover URL.
    func withCover(_ text: String) -> MusicTrack {
        MusicTrack(
            videoId: videoId, title: title, artist: artist, album: album, durationSeconds: durationSeconds,
            thumbnailURL: URL(string: text)
        )
    }
}

extension DownloadServiceRig {
    /// Scripts `browseId` on the rig's backend as a page of `tracks`, with the title and cover a header would have. The
    /// header states `tracks.count` songs unless `subtitle` says otherwise, and `unavailable` names the greyed-out rows.
    func script(
        _ browseId: String, tracks: [MusicTrack], title: String = "Page", cover: String? = nil, continuation: String? = nil,
        subtitle: String? = nil, unavailable: [String] = []
    ) async {
        await backend?.setPage(MusicBrowsePage(
            browseId: browseId,
            title: title,
            subtitle: subtitle ?? "Playlist \u{2022} \(tracks.count) songs",
            thumbnailURL: cover.flatMap(URL.init(string:)),
            tracks: tracks,
            continuation: continuation,
            shelves: [],
            unavailableVideoIds: unavailable
        ))
    }

    /// Polls until `condition` holds, for work parked at a gate that cannot be awaited.
    func eventually(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<2_000 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    /// The request a page's Download pill makes.
    func request(
        _ browseId: String, title: String = "Page", kind: MusicDownloadStore.Collection.Kind = .playlist, cover: String? = nil
    ) -> MusicCollectionRequest {
        MusicCollectionRequest(
            browseId: browseId, title: title, subtitle: "Playlist", kind: kind, coverURL: cover.flatMap(URL.init(string:))
        )
    }

    /// The video ids requested from the transport, each once, in the order they first went out.
    var requestedSongs: [String] {
        get async {
            var seen = Set<String>()
            return await requestedIDs.filter { seen.insert($0).inserted }
        }
    }

    /// How many requests the transport got for the song.
    func requestCount(for id: String) async -> Int {
        await requestedIDs.filter { $0 == id }.count
    }
}

/// Holds the store inside a change to one collection's record: the hook parks the store's thread there until `open()`, so a
/// test can act on the service while the store is mid-change. It holds one change to `browseId` only: the first, or with
/// `skipping` the one after that many others (a collection's first download is a change too).
nonisolated final class StoreBlocker: Sendable {
    private let browseId: String
    private let skipping: Int
    private let changes = OSAllocatedUnfairLock(initialState: 0)
    private let didEnter = OSAllocatedUnfairLock(initialState: false)
    private let release = DispatchSemaphore(value: 0)

    init(browseId: String, skipping: Int = 0) {
        self.browseId = browseId
        self.skipping = skipping
    }

    /// Passed to the store as `beforeCollectionChange`.
    var hook: @Sendable (String) -> Void {
        { [self] id in
            guard id == browseId else { return }
            let number = changes.withLock { (count: inout Int) -> Int in
                count += 1
                return count
            }
            guard number == skipping + 1 else { return }
            didEnter.withLock { $0 = true }
            release.wait()
        }
    }

    /// Whether the store is parked in the change.
    var hasEntered: Bool { didEnter.withLock { $0 } }

    /// Lets the store go on.
    func open() {
        release.signal()
    }
}
