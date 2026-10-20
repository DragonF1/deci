// Deci/Music/MusicCoverTintStore.swift
import CoreGraphics
import Foundation

/// The tint of a cover, found once per cover URL and kept for the session. The cover is fetched through the same
/// cookie-less, cache-less session the player's artwork uses, shrunk and averaged (`MusicCoverColor`), and only the
/// colour and a 64 pixel thumbnail are kept, in memory: no picture and no URL is written anywhere, and nothing here
/// logs one. The thumbnail comes out of the one fetch the tint needs, so the menu bar chip and the hover card have a
/// cover to draw without a second request.
///
/// A page asks `cachedTint` for what it can draw at once, then `tint(for:)`; until that answers, or when it cannot
/// (no network, not a picture), the page keeps the hash palette's tint of its id.
///
/// A cover that gave no tint (a dead link, data that is not a picture) is remembered for a few minutes, so opening the
/// page again does not fetch it again at once. Calls for one cover share a single fetch; when every one of them has
/// been cancelled (the page was left) the fetch is cancelled too, and that is not counted as a failure.
@MainActor
final class MusicCoverTintStore {
    static let shared = MusicCoverTintStore()

    /// The most covers kept. The oldest goes first.
    static let capacity = 64
    /// The most covers without a tint remembered, and for how long.
    static let failureCapacity = 32
    static let failureLifetime: TimeInterval = 300

    /// A decoded thumbnail that crosses from the decoding task to the main actor. A CGImage is immutable.
    private struct ThumbnailBox: @unchecked Sendable {
        let image: CGImage?
    }

    /// What one fetch came to.
    private enum Outcome {
        case tint(MusicTint, ThumbnailBox)
        /// The fetch failed or the data held no colour.
        case failed
        /// Everyone waiting for it gave up first.
        case cancelled

        var tint: MusicTint? {
            if case .tint(let tint, _) = self { tint } else { nil }
        }
    }

    /// A fetch in progress and how many callers still wait for it.
    private struct Flight {
        let id: UUID
        let task: Task<Outcome, Never>
        var waiters: Int
    }

    private let fetch: NowPlayingController.ArtworkFetcher
    private let capacity: Int
    private let failureCapacity: Int
    private let now: @MainActor () -> Date
    private var cache: [URL: MusicTint] = [:]
    /// The small picture of each cover in `cache` that had one, evicted with it.
    private var thumbnails: [URL: CGImage] = [:]
    /// Insertion order of `cache`, oldest first.
    private var order: [URL] = []
    /// When each cover without a tint was found to have none.
    private var failures: [URL: Date] = [:]
    private var failureOrder: [URL] = []
    private var inFlight: [URL: Flight] = [:]

    init(
        fetch: @escaping NowPlayingController.ArtworkFetcher = NowPlayingController.fetchOverNetwork,
        capacity: Int = MusicCoverTintStore.capacity,
        failureCapacity: Int = MusicCoverTintStore.failureCapacity,
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.fetch = fetch
        self.capacity = max(1, capacity)
        self.failureCapacity = max(1, failureCapacity)
        self.now = now
    }

    /// The tint of a cover that has been looked at already; nil when it has not, or when it had none.
    func cachedTint(for url: URL?) -> MusicTint? {
        url.flatMap { cache[$0] }
    }

    /// The thumbnail (at most 64 pixels) of a cover that has been looked at already; nil when it has not.
    func cachedThumbnail(for url: URL?) -> CGImage? {
        url.flatMap { thumbnails[$0] }
    }

    /// The tint of the cover at `url`: from the cache, or by fetching and averaging it. Nil when there is no URL, the
    /// fetch fails or the data is not a picture, and nil at once for a cover that failed a moment ago. Calls for the
    /// same cover at once share one fetch, and a caller that is cancelled does not cancel it for the others.
    func tint(for url: URL?) async -> MusicTint? {
        guard let url else { return nil }
        if let cached = cache[url] { return cached }
        if hasRecentlyFailed(url) { return nil }

        let flight = join(url)
        let outcome = await withTaskCancellationHandler {
            await flight.task.value
        } onCancel: {
            // Runs on whatever thread cancels; the bookkeeping is the main actor's.
            Task { @MainActor [weak self] in self?.leave(url, flightID: flight.id) }
        }
        return outcome.tint
    }

    // MARK: - Fetching

    /// The fetch for `url`, started if none is running, with one more waiter on it.
    private func join(_ url: URL) -> (id: UUID, task: Task<Outcome, Never>) {
        if var running = inFlight[url] {
            running.waiters += 1
            inFlight[url] = running
            return (running.id, running.task)
        }
        let id = UUID()
        let fetch = fetch
        let task = Task<Outcome, Never> {
            let outcome = await Self.run(fetch, url)
            self.finish(url, flightID: id, outcome: outcome)
            return outcome
        }
        inFlight[url] = Flight(id: id, task: task, waiters: 1)
        return (id, task)
    }

    /// One fetch and its decoding. A cancellation is checked before the decode, so a page that was left costs no work.
    private nonisolated static func run(_ fetch: NowPlayingController.ArtworkFetcher, _ url: URL) async -> Outcome {
        guard let data = await fetch(url) else { return Task.isCancelled ? .cancelled : .failed }
        if Task.isCancelled { return .cancelled }
        // Decoding is off the main actor: the picture is a few hundred pixels wide, but still not UI work.
        let decoded = await Task.detached(priority: .utility) {
            (MusicCoverColor.tint(imageData: data), ThumbnailBox(image: MusicCoverColor.thumbnail(imageData: data)))
        }.value
        return decoded.0.map { Outcome.tint($0, decoded.1) } ?? .failed
    }

    /// A waiter was cancelled. The last one to go takes the fetch with it, and the cover is free to be asked for again.
    private func leave(_ url: URL, flightID: UUID) {
        guard var flight = inFlight[url], flight.id == flightID else { return }
        flight.waiters -= 1
        if flight.waiters <= 0 {
            flight.task.cancel()
            inFlight[url] = nil
        } else {
            inFlight[url] = flight
        }
    }

    private func finish(_ url: URL, flightID: UUID, outcome: Outcome) {
        switch outcome {
        case .tint(let tint, let thumbnail): remember(tint, thumbnail: thumbnail.image, for: url)
        case .failed: rememberFailure(for: url)
        case .cancelled: break
        }
        if inFlight[url]?.id == flightID { inFlight[url] = nil }
    }

    // MARK: - Memory

    private func remember(_ tint: MusicTint, thumbnail: CGImage?, for url: URL) {
        failures[url] = nil
        failureOrder.removeAll { $0 == url }
        if cache[url] == nil { order.append(url) }
        cache[url] = tint
        thumbnails[url] = thumbnail
        while order.count > capacity {
            let oldest = order.removeFirst()
            cache[oldest] = nil
            thumbnails[oldest] = nil
        }
    }

    private func rememberFailure(for url: URL) {
        if failures[url] == nil { failureOrder.append(url) }
        failures[url] = now()
        while failureOrder.count > failureCapacity {
            failures[failureOrder.removeFirst()] = nil
        }
    }

    /// Whether `url` gave no tint less than `failureLifetime` ago. An older entry is dropped.
    private func hasRecentlyFailed(_ url: URL) -> Bool {
        guard let failedAt = failures[url] else { return false }
        if now().timeIntervalSince(failedAt) < Self.failureLifetime { return true }
        failures[url] = nil
        failureOrder.removeAll { $0 == url }
        return false
    }

    /// How many covers are held, for tests.
    var count: Int { cache.count }

    /// How many covers without a tint are remembered, for tests.
    var failureCount: Int { failures.count }
}
