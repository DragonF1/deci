// DeciTests/Music/MusicDownloadTestSupport.swift
// What the offline downloads tests share: a throwaway folder under /Volumes/Storage/_test, a scriptable transport
// that serves byte ranges from memory, a resolver that records its calls, and small fixtures. Nothing here touches the
// network.

import Foundation
import Testing
@testable import Deci

/// A fresh folder for one test's downloads, removed by `remove()`. The store creates it on its first write.
nonisolated struct DownloadTestFolder {
    let root: URL

    init() {
        root = URL(fileURLWithPath: "/Volumes/Storage/_test/deci/tmp", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    /// Deletes the folder. Permissions a test took away are given back first, or the delete would fail.
    func remove() {
        let fileManager = FileManager.default
        var urls = [root, audioDirectory, indexURL]
        urls += (try? fileManager.contentsOfDirectory(at: audioDirectory, includingPropertiesForKeys: nil)) ?? []
        for url in urls where fileManager.fileExists(atPath: url.path) {
            var isDirectory: ObjCBool = false
            _ = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            try? fileManager.setAttributes([.posixPermissions: isDirectory.boolValue ? 0o755 : 0o644], ofItemAtPath: url.path)
        }
        try? fileManager.removeItem(at: root)
    }

    var audioDirectory: URL { root.appendingPathComponent("audio", isDirectory: true) }
    var indexURL: URL { root.appendingPathComponent("downloads.json", isDirectory: false) }

    func audioURL(_ videoId: String) -> URL {
        audioDirectory.appendingPathComponent("\(videoId).m4a", isDirectory: false)
    }

    func partURL(_ videoId: String) -> URL {
        audioDirectory.appendingPathComponent("\(videoId).m4a.part", isDirectory: false)
    }

    func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// The names in the audio folder, sorted; empty when the folder does not exist.
    var audioFiles: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: audioDirectory.path)) ?? []).sorted()
    }

    /// Every name in the root, sorted, so a leftover temp file shows.
    var rootFiles: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).sorted()
    }

    func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    func read(_ url: URL) -> Data? {
        try? Data(contentsOf: url)
    }

    /// Takes every permission from the item, so that reading or writing it fails with a permission error.
    func lock(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
    }

    /// Gives the item back the permissions a file (`0o644`) or a folder (`0o755`) has.
    func unlock(_ url: URL, isDirectory: Bool = false) throws {
        try FileManager.default.setAttributes([.posixPermissions: isDirectory ? 0o755 : 0o644], ofItemAtPath: url.path)
    }
}

nonisolated enum DownloadSamples {
    /// Valid YouTube video ids: eleven characters from [A-Za-z0-9_-].
    static let idA = "AAAAAAAAAAA"
    static let idB = "BBBBBBBBBBB"
    static let idC = "CCCCCCCCCCC"

    static func track(_ id: String = idA, title: String = "Song", seconds: Int? = 200) -> MusicTrack {
        MusicTrack(videoId: id, title: title, artist: "Artist", album: "Album", durationSeconds: seconds, thumbnailURL: nil)
    }

    /// `count` bytes that differ from place to place, so a chunk in the wrong spot shows.
    static func payload(_ count: Int) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: ($0 * 7 + 3) % 251) })
    }

    static let fixedDate = Date(timeIntervalSince1970: 1_700_000_000.5)
}

/// Stands in for the network. The handler gets each request and its number (the first is 0) and answers it; the
/// default handler serves ranges of a payload held in memory. Like the live transport, it tells `received` how many
/// bytes of an answer have arrived: by default all of them at once, or in the steps `steps` gives for the answer's size.
actor FakeDownloadTransport: MusicDownloadTransport {
    nonisolated struct Request: Equatable, Sendable {
        let url: URL
        let range: ClosedRange<Int64>
        let headers: [String: String]
    }

    typealias Handler = @Sendable (Request, Int) async throws -> MusicDownloadChunk
    typealias Steps = @Sendable (Int) -> [Int]
    typealias AfterStep = @Sendable (Int) async -> Void

    private(set) var requests: [Request] = []
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private let handler: Handler
    private let steps: Steps
    private let afterStep: AfterStep?

    /// `steps` turns the size of an answer into the running byte counts `received` is told, and `afterStep` is awaited
    /// after each (it gets the step's number, from 0), so a test can hold the transport until the app has seen it.
    init(handler: @escaping Handler, steps: @escaping Steps = { [$0] }, afterStep: AfterStep? = nil) {
        self.handler = handler
        self.steps = steps
        self.afterStep = afterStep
    }

    init(serving payload: Data) {
        handler = Self.serving(payload)
        steps = { [$0] }
        afterStep = nil
    }

    func fetch(
        url: URL, range: ClosedRange<Int64>, headers: [String: String], received: @escaping @Sendable (Int) -> Void
    ) async throws -> MusicDownloadChunk {
        let request = Request(url: url, range: range, headers: headers)
        let index = requests.count
        requests.append(request)
        wakeWaiters()
        let chunk = try await handler(request, index)
        if !chunk.data.isEmpty {
            for (number, step) in steps(chunk.data.count).enumerated() {
                received(step)
                await afterStep?(number)
            }
        }
        return chunk
    }

    var requestCount: Int { requests.count }

    /// Returns once `count` requests have gone out. A request is counted as it starts, so it may still be waiting in the
    /// handler for an answer.
    func waitForRequests(_ count: Int) async {
        if requests.count >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }

    private func wakeWaiters() {
        let ready = waiters.filter { $0.count <= requests.count }
        waiters.removeAll { $0.count <= requests.count }
        for waiter in ready { waiter.continuation.resume() }
    }

    /// A handler that answers every request from `payload`. `reportsTotal: false` leaves the Content-Range total out,
    /// and `limit` cuts each answer short, as a server may.
    nonisolated static func serving(_ payload: Data, reportsTotal: Bool = true, limit: Int? = nil) -> Handler {
        { request, _ in chunk(of: payload, request.range, reportsTotal: reportsTotal, limit: limit) }
    }

    nonisolated static func chunk(
        of payload: Data, _ range: ClosedRange<Int64>, reportsTotal: Bool = true, limit: Int? = nil
    ) -> MusicDownloadChunk {
        let total = Int64(payload.count)
        guard range.lowerBound < total else {
            return MusicDownloadChunk(data: Data(), status: 416, totalLength: reportsTotal ? total : nil)
        }
        var upper = min(range.upperBound, total - 1)
        if let limit { upper = min(upper, range.lowerBound + Int64(limit) - 1) }
        let data = payload.subdata(in: Int(range.lowerBound)..<Int(upper + 1))
        return MusicDownloadChunk(
            data: data, status: 206, totalLength: reportsTotal ? total : nil, byteRange: range.lowerBound...upper
        )
    }

    nonisolated static func status(_ code: Int) -> MusicDownloadChunk {
        MusicDownloadChunk(data: Data(), status: code, totalLength: nil)
    }
}

extension FakeDownloadTransport.Request {
    /// The video the request is for: the fake resolver puts the id in the first path component.
    nonisolated var videoId: String { url.pathComponents[1] }
}

/// Resolves a video to a stream and keeps every call. Each call gets its own address (`/<id>/<call>.m4a`), so a test
/// can tell which resolve a request belongs to.
actor FakeDownloadResolver {
    typealias Make = @Sendable (String, Int) throws -> ResolvedStream

    private(set) var calls: [String] = []
    private let make: Make

    init(make: @escaping Make = { id, call in FakeDownloadResolver.stream(videoId: id, call: call) }) {
        self.make = make
    }

    func resolve(_ videoId: String) throws -> ResolvedStream {
        let call = calls.count
        calls.append(videoId)
        return try make(videoId, call)
    }

    nonisolated var closure: @Sendable (String) async throws -> ResolvedStream {
        { id in try await self.resolve(id) }
    }

    nonisolated static func stream(
        videoId: String, call: Int, query: String? = nil, expiresAt: Date = .distantFuture, duration: Double? = 200
    ) -> ResolvedStream {
        let suffix = query.map { "?\($0)" } ?? ""
        return ResolvedStream(
            videoId: videoId,
            url: URL(string: "https://media.example.test/\(videoId)/\(call).m4a\(suffix)")!,
            itag: 140,
            durationSeconds: duration,
            expiresAt: expiresAt,
            playbackTrackingURL: URL(string: "https://music.example.test/stats?ev=1"),
            httpHeaders: ["User-Agent": "test-agent"]
        )
    }
}

extension FakeDownloadResolver {
    /// A resolver whose addresses carry `clen=<length>`, as YouTube's do, so the end of the file is known before the
    /// first request.
    nonisolated static func knowingLength(_ length: Int) -> FakeDownloadResolver {
        FakeDownloadResolver { id, call in stream(videoId: id, call: call, query: "clen=\(length)") }
    }
}

/// Counts up from 1, once per call, for a test that waits for the nth progress value across several answers.
nonisolated final class DownloadStepCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

/// The progress values a download reported, in order.
@MainActor
final class DownloadProgressLog {
    private(set) var values: [Double] = []
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func note(_ fraction: Double) {
        values.append(fraction)
        let ready = waiters.filter { $0.count <= values.count }
        waiters.removeAll { $0.count <= values.count }
        for waiter in ready { waiter.continuation.resume() }
    }

    /// Returns once `count` values have been reported.
    func waitForCount(_ count: Int) async {
        if values.count >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }
}
