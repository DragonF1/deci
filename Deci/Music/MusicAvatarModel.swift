// Deci/Music/MusicAvatarModel.swift
import AppKit
import Observation
import os

private let logger = Logger(subsystem: "com.abraham.Deci", category: "Music")

/// The account photo behind the avatar views. The photo URL is personal, so it is fetched through the
/// cookie-less, cache-less session cover art uses (never `URLCache.shared`, which keeps it in Cache.db after
/// a sign-out) and held in memory only. Never logs the URL.
@MainActor
@Observable
final class MusicAvatarModel {
    /// The decoded photo; nil while it loads, when it fails and when there is no URL.
    private(set) var image: NSImage?

    @ObservationIgnored private let fetch: NowPlayingController.ArtworkFetcher
    /// Each load names itself with the next number and only lands while it is still the latest.
    @ObservationIgnored private var generation = 0

    init(fetch: @escaping NowPlayingController.ArtworkFetcher = NowPlayingController.fetchOverNetwork) {
        self.fetch = fetch
    }

    /// Shows the photo at `url`. The photo shown before goes first, so after a swap the old account's photo
    /// is never on screen under the new one, even when the new one cannot be loaded. A load cancelled by
    /// the next one, or by the view leaving, leaves nothing behind.
    func load(_ url: URL?) async {
        generation += 1
        let mine = generation
        image = nil
        guard let url else { return }
        let data = await fetch(url)
        guard !Task.isCancelled, mine == generation else { return }
        guard let data, let decoded = NSImage(data: data), decoded.isValid else {
            logger.notice("account photo unavailable")
            return
        }
        image = decoded
    }
}
