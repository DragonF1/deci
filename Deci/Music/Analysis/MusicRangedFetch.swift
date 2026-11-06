// Deci/Music/Analysis/MusicRangedFetch.swift
import Foundation

/// The ranged-download loop shared by the Downloads queue and the track cache (tier 2a P3). It was
/// `MusicDownloader.fetchAll`; the behaviour is unchanged.
///
/// The end of the file comes from the first Content-Range, else from the `clen` on the stream's address. A 403, or an
/// address about to expire, gets a fresh stream and the fetch carries on at the byte it reached; a song may ask for
/// `maxReResolves`. Every answer must be a 206 whose Content-Range starts at the byte the file ends on and covers
/// exactly the bytes it carries.
nonisolated enum MusicRangedFetch {
    /// How many fresh streams one song may ask for after the first.
    static let maxReResolves = 3
    /// A stream with less than this left is replaced before it is used.
    static let expiryMargin: TimeInterval = 10

    /// Writes the whole file behind `stream` to `handle` (which starts empty) and returns the bytes written and the
    /// duration (the first stream's, else a later one's). Does not sync or close `handle`. `progress` gets the fraction
    /// written, on the main actor, and never repeats a value.
    static func run(
        videoId: String,
        stream firstStream: ResolvedStream,
        transport: any MusicDownloadTransport,
        chunkSize: Int64,
        handle: FileHandle,
        now: @Sendable () -> Date,
        resolve: @Sendable (String) async throws -> ResolvedStream,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws -> (bytes: Int64, duration: Double?) {
        let relay = DownloadProgressRelay(progress)
        var stream = firstStream
        var duration = firstStream.durationSeconds
        var reResolves = 0
        var written: Int64 = 0
        var rangeTotal: Int64?
        var addressTotal = contentLength(in: stream.url)

        while true {
            try Task.checkCancellation()
            if let total = rangeTotal ?? addressTotal, written >= total { break }

            if stream.expiresAt.timeIntervalSince(now()) <= expiryMargin {
                reResolves += 1
                guard reResolves <= maxReResolves else { throw MusicDownloadError.reResolveLimit }
                stream = try await resolve(videoId)
                duration = duration ?? stream.durationSeconds
                addressTotal = contentLength(in: stream.url) ?? addressTotal
                continue
            }

            var upper = written + chunkSize - 1
            if let total = rangeTotal ?? addressTotal { upper = min(upper, total - 1) }
            let chunk = try await fetchChunk(
                transport: transport, from: stream, range: written...upper, total: rangeTotal ?? addressTotal, relay: relay
            )
            try Task.checkCancellation()

            if chunk.status == 403 {
                reResolves += 1
                guard reResolves <= maxReResolves else { throw MusicDownloadError.reResolveLimit }
                stream = try await resolve(videoId)
                duration = duration ?? stream.durationSeconds
                addressTotal = contentLength(in: stream.url) ?? addressTotal
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
        return (written, duration)
    }

    /// One ranged GET. While its body arrives, and once `total` (the size of the whole file) is known, the share of the
    /// file on its way is shown as it grows. Returns after the last of those values has been shown, so they come ahead of
    /// the one the caller shows for the finished chunk.
    private static func fetchChunk(
        transport: any MusicDownloadTransport,
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
final class DownloadProgressRelay {
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
