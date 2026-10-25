// Deci/Music/Downloads/MusicDownloader.swift
import Foundation

/// Downloads one song at a time into the store: resolves a stream, fetches it in ranged chunks, appends each chunk to
/// the song's `.part` file and commits the file when every byte is there.
///
/// The end of the file comes from the first Content-Range, else from the `clen` on the stream's address. A 403, or an
/// address about to expire, gets a fresh stream and the download carries on at the byte it reached; a song may ask for
/// three. Any other failure, and a cancel, deletes the `.part` file and leaves no entry.
///
/// Every answer must be a 206 whose Content-Range starts at the byte the part file ends on and covers exactly the bytes
/// it carries: anything else fails the song, so a part file is never a patchwork of ranges that do not line up.
///
/// An actor, so the file work runs off the main thread. One song is downloaded once at a time: a second call for an id
/// already running is refused, since both would write the same `.part` file.
actor MusicDownloader {
    /// Ten MiB: few enough requests for a song, small enough to restart cheaply.
    static let defaultChunkSize = 10 * 1_024 * 1_024
    /// How many fresh streams one song may ask for after the first.
    static let maxReResolves = 3
    /// A stream with less than this left is replaced before it is used, so a chunk never starts on an address that
    /// is about to stop working.
    static let expiryMargin: TimeInterval = 10

    private let store: MusicDownloadStore
    private let transport: any MusicDownloadTransport
    private let resolve: @Sendable (String) async throws -> ResolvedStream
    private let chunkSize: Int64
    private let now: @Sendable () -> Date
    /// The songs being downloaded right now.
    private var inFlight: Set<String> = []

    init(
        store: MusicDownloadStore,
        transport: any MusicDownloadTransport,
        resolve: @escaping @Sendable (String) async throws -> ResolvedStream,
        chunkSize: Int = MusicDownloader.defaultChunkSize,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.transport = transport
        self.resolve = resolve
        self.chunkSize = Int64(max(1, chunkSize))
        self.now = now
    }

    /// Downloads `track` and returns its entry. `progress` gets the fraction written, on the main actor: as the bytes of a
    /// chunk arrive once the size of the file is known, and when a chunk is on disk. A value equal to the last is not
    /// repeated.
    func download(
        _ track: MusicTrack, progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws -> MusicDownloadStore.Entry {
        let videoId = track.videoId
        guard MusicDownloadStore.isValidVideoId(videoId) else { throw MusicDownloadError.invalidVideoId }
        // Before the first suspension, and refused ahead of the cleanup below: the first call's part file is not this
        // call's to discard.
        guard inFlight.insert(videoId).inserted else { throw MusicDownloadError.alreadyDownloading }
        defer { inFlight.remove(videoId) }
        try Task.checkCancellation()

        let first = try await resolve(videoId)
        try Task.checkCancellation()
        let part = try await store.beginPart(videoId: videoId)
        do {
            let entry = try await fetchAll(track, firstStream: first, into: part, progress: progress)
            return entry
        } catch {
            await store.discardPart(videoId: videoId)
            throw error
        }
    }

    private func fetchAll(
        _ track: MusicTrack,
        firstStream: ResolvedStream,
        into part: URL,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws -> MusicDownloadStore.Entry {
        let handle = try FileHandle(forWritingTo: part)
        var isClosed = false
        defer { if !isClosed { try? handle.close() } }

        let relay = DownloadProgressRelay(progress)
        var stream = firstStream
        var duration = firstStream.durationSeconds
        var reResolves = 0
        var written: Int64 = 0
        var rangeTotal: Int64?
        var addressTotal = Self.contentLength(in: stream.url)

        while true {
            try Task.checkCancellation()
            if let total = rangeTotal ?? addressTotal, written >= total { break }

            if stream.expiresAt.timeIntervalSince(now()) <= Self.expiryMargin {
                reResolves += 1
                guard reResolves <= Self.maxReResolves else { throw MusicDownloadError.reResolveLimit }
                stream = try await resolve(track.videoId)
                duration = duration ?? stream.durationSeconds
                addressTotal = Self.contentLength(in: stream.url) ?? addressTotal
                continue
            }

            var upper = written + chunkSize - 1
            if let total = rangeTotal ?? addressTotal { upper = min(upper, total - 1) }
            let chunk = try await fetchChunk(
                from: stream, range: written...upper, total: rangeTotal ?? addressTotal, relay: relay
            )
            try Task.checkCancellation()

            if chunk.status == 403 {
                reResolves += 1
                guard reResolves <= Self.maxReResolves else { throw MusicDownloadError.reResolveLimit }
                stream = try await resolve(track.videoId)
                duration = duration ?? stream.durationSeconds
                addressTotal = Self.contentLength(in: stream.url) ?? addressTotal
                continue
            }
            guard chunk.status == 206 else { throw MusicDownloadError.badStatus(chunk.status) }
            guard !chunk.data.isEmpty else { throw MusicDownloadError.badResponse }
            guard let byteRange = chunk.byteRange else { throw MusicDownloadError.badResponse }

            if let reported = chunk.totalLength {
                if let known = rangeTotal, known != reported { throw MusicDownloadError.lengthMismatch }
                rangeTotal = reported
            }
            guard let total = rangeTotal ?? addressTotal else { throw MusicDownloadError.unknownLength }
            let count = Int64(chunk.data.count)
            // The bytes must be the ones that come next in the file, and the header must say how many there are.
            guard byteRange.lowerBound == written, byteRange.upperBound - byteRange.lowerBound + 1 == count else {
                throw MusicDownloadError.lengthMismatch
            }
            let asked = upper - written + 1
            guard count <= asked, written + count <= total else { throw MusicDownloadError.lengthMismatch }

            try handle.write(contentsOf: chunk.data)
            written += count
            await relay.report(Double(written) / Double(total))
        }

        // On the disk before the file is renamed into place, so a crash cannot leave a finished name on unwritten bytes.
        try handle.synchronize()
        isClosed = true
        try handle.close()
        return try await store.commit(track, expectedBytes: written, durationSeconds: duration)
    }

    /// One ranged GET. While its body arrives, and once `total` (the size of the whole file) is known, the share of the
    /// file on its way is shown as it grows. Returns after the last of those values has been shown, so they come ahead of
    /// the one the caller shows for the finished chunk.
    private func fetchChunk(
        from stream: ResolvedStream, range: ClosedRange<Int64>, total: Int64?, relay: DownloadProgressRelay
    ) async throws -> MusicDownloadChunk {
        let (updates, feed) = AsyncStream<Int>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let base = range.lowerBound
        let reporter: Task<Void, Never>? = total.map { total in
            Task { @MainActor in
                for await count in updates {
                    relay.report(min(1, Double(base + Int64(count)) / Double(total)))
                }
            }
        }
        do {
            let chunk = try await transport.fetch(
                url: stream.url, range: range, headers: stream.httpHeaders, received: { feed.yield($0) }
            )
            feed.finish()
            await reporter?.value
            return chunk
        } catch {
            feed.finish()
            reporter?.cancel()
            throw error
        }
    }

    /// The `clen` query item of a googlevideo address: the size of the file the address serves.
    static func contentLength(in url: URL) -> Int64? {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let value = items.first(where: { $0.name == "clen" })?.value,
              let length = Int64(value), length > 0
        else { return nil }
        return length
    }
}

/// Shows a download's progress on the main actor and skips a value equal to the one shown last.
@MainActor
private final class DownloadProgressRelay {
    private let show: @MainActor @Sendable (Double) -> Void
    private var last: Double?

    nonisolated init(_ show: @escaping @MainActor @Sendable (Double) -> Void) {
        self.show = show
    }

    func report(_ fraction: Double) {
        guard fraction != last else { return }
        last = fraction
        show(fraction)
    }
}
