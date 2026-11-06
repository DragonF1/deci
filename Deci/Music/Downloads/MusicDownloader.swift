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
    static let maxReResolves = MusicRangedFetch.maxReResolves
    /// A stream with less than this left is replaced before it is used, so a chunk never starts on an address that
    /// is about to stop working.
    static let expiryMargin: TimeInterval = MusicRangedFetch.expiryMargin

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

    /// Downloads `track` and returns its entry. `standalone` is whether the song was asked for on its own (the store keeps
    /// its file until that is withdrawn) or only as part of a downloaded playlist or album. `progress` gets the fraction
    /// written, on the main actor: as the bytes of a chunk arrive once the size of the file is known, and when a chunk is
    /// on disk. A value equal to the last is not repeated.
    func download(
        _ track: MusicTrack, standalone: Bool = true, progress: @escaping @MainActor @Sendable (Double) -> Void
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
            let entry = try await fetchAll(
                track, standalone: standalone, firstStream: first, into: part, progress: progress
            )
            return entry
        } catch {
            await store.discardPart(videoId: videoId)
            throw error
        }
    }

    private func fetchAll(
        _ track: MusicTrack,
        standalone: Bool,
        firstStream: ResolvedStream,
        into part: URL,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws -> MusicDownloadStore.Entry {
        let handle = try FileHandle(forWritingTo: part)
        var isClosed = false
        defer { if !isClosed { try? handle.close() } }

        let (written, duration) = try await MusicRangedFetch.run(
            videoId: track.videoId, stream: firstStream, transport: transport, chunkSize: chunkSize, handle: handle,
            now: now, resolve: resolve, progress: progress
        )

        // On the disk before the file is renamed into place, so a crash cannot leave a finished name on unwritten bytes.
        try handle.synchronize()
        isClosed = true
        try handle.close()
        return try await store.commit(track, expectedBytes: written, durationSeconds: duration, standalone: standalone)
    }

    /// The `clen` query item of a googlevideo address: the size of the file the address serves.
    static func contentLength(in url: URL) -> Int64? { MusicRangedFetch.contentLength(in: url) }
}
