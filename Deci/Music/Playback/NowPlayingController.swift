// Deci/Music/Playback/NowPlayingController.swift
import AppKit
import Foundation
import MediaPlayer
import os

private let logger = Logger(subsystem: "com.abraham.Deci", category: "Music")

/// What the system Now Playing widget and the media keys should reflect.
struct NowPlayingState: Equatable {
    var track: MusicTrack
    var elapsed: TimeInterval
    var duration: TimeInterval
    var isPlaying: Bool
}

enum NowPlayingCommand: Equatable, Sendable {
    case play, pause, toggle, next, previous
    case seek(TimeInterval)
}

/// The MediaPlayer seam: the controller decides what to show, the surface talks to the system.
@MainActor
protocol NowPlayingSurface: AnyObject {
    func setInfo(_ info: [String: Any], isPlaying: Bool)
    func clearInfo()
    func registerCommands(_ handler: @escaping @MainActor (NowPlayingCommand) -> Void)
    func removeCommands()
}

/// Keeps the Now Playing widget and the media keys in step with native playback.
/// Nothing touches MediaPlayer until the first track plays, and everything is released when playback ends.
@MainActor
final class NowPlayingController {
    typealias ArtworkFetcher = @Sendable (URL) async -> Data?

    /// Media key and widget presses, delivered on the main actor.
    var onCommand: (@MainActor (NowPlayingCommand) -> Void)?

    private let surface: any NowPlayingSurface
    private let fetchArtwork: ArtworkFetcher
    private var isRegistered = false
    private var state: NowPlayingState?
    private var artworkCache: [(url: URL, artwork: MPMediaItemArtwork)] = []
    private var failedArtwork: Set<URL> = []
    private var fetchingArtwork: URL?
    /// Exposed read-only so tests can await a download in flight.
    private(set) var artworkTask: Task<Void, Never>?

    private static let artworkCacheLimit = 4

    init(
        surface: any NowPlayingSurface = SystemNowPlayingSurface(),
        fetchArtwork: @escaping ArtworkFetcher = NowPlayingController.fetchOverNetwork
    ) {
        self.surface = surface
        self.fetchArtwork = fetchArtwork
    }

    isolated deinit {
        artworkTask?.cancel()
    }

    /// Shows `state`, or releases the system when it is nil.
    func update(_ state: NowPlayingState?) {
        guard let state else {
            deactivate()
            return
        }
        if !isRegistered {
            surface.registerCommands { [weak self] command in self?.onCommand?(command) }
            isRegistered = true
        }
        guard state != self.state else { return }
        self.state = state
        publish()
        loadArtworkIfNeeded(for: state.track)
    }

    private func deactivate() {
        artworkTask?.cancel()
        artworkTask = nil
        fetchingArtwork = nil
        state = nil
        guard isRegistered else { return }
        isRegistered = false
        surface.removeCommands()
        surface.clearInfo()
    }

    private func publish() {
        guard let state else { return }
        surface.setInfo(
            NowPlayingInfo.dictionary(for: state, artwork: cachedArtwork(for: state.track.thumbnailURL)),
            isPlaying: state.isPlaying
        )
    }

    // MARK: - Artwork

    private func cachedArtwork(for url: URL?) -> MPMediaItemArtwork? {
        guard let url else { return nil }
        return artworkCache.first { $0.url == url }?.artwork
    }

    private func loadArtworkIfNeeded(for track: MusicTrack) {
        guard let url = track.thumbnailURL,
              cachedArtwork(for: url) == nil,
              !failedArtwork.contains(url),
              fetchingArtwork != url else { return }
        artworkTask?.cancel()
        fetchingArtwork = url
        let fetch = fetchArtwork
        artworkTask = Task { [weak self] in
            let data = await fetch(url)
            guard let self, !Task.isCancelled else { return }
            self.finishArtwork(url: url, data: data)
        }
    }

    private func finishArtwork(url: URL, data: Data?) {
        fetchingArtwork = nil
        guard let data, let image = NSImage(data: data), image.isValid else {
            failedArtwork.insert(url)
            logger.info("now playing artwork unavailable")
            return
        }
        artworkCache.append((url, ArtworkFactory.make(image: image)))
        if artworkCache.count > Self.artworkCacheLimit { artworkCache.removeFirst() }
        if state?.track.thumbnailURL == url { publish() }
    }

    /// Cover art comes without cookies or a shared cache: it is public and must not carry the account.
    private nonisolated static let artworkSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 10
        return URLSession(configuration: configuration)
    }()

    nonisolated static func fetchOverNetwork(_ url: URL) async -> Data? {
        guard url.scheme == "https" else { return nil }
        guard let (data, response) = try? await artworkSession.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }
}

/// Maps playback state to the MediaPlayer info dictionary. Pure.
enum NowPlayingInfo {
    static func dictionary(for state: NowPlayingState, artwork: MPMediaItemArtwork? = nil) -> [String: Any] {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: state.track.title,
            MPMediaItemPropertyArtist: state.track.artist,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyPlaybackRate: state.isPlaying ? 1.0 : 0.0
        ]
        if let album = state.track.album, !album.isEmpty {
            info[MPMediaItemPropertyAlbumTitle] = album
        }
        let duration = state.duration.isFinite && state.duration > 0 ? state.duration : 0
        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        let elapsed = state.elapsed.isFinite ? max(0, state.elapsed) : 0
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = duration > 0 ? min(elapsed, duration) : elapsed
        if let artwork {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        return info
    }
}

/// Builds MPMediaItemArtwork outside any actor: the system calls its size handler from its own queues.
enum ArtworkFactory {
    private final class Box: @unchecked Sendable {
        let image: NSImage
        init(_ image: NSImage) { self.image = image }
    }

    nonisolated static func make(image: NSImage) -> MPMediaItemArtwork {
        let box = Box(image)
        let natural = image.size.width > 0 && image.size.height > 0 ? image.size : CGSize(width: 300, height: 300)
        return MPMediaItemArtwork(boundsSize: natural) { requested in
            sized(box.image, to: requested)
        }
    }

    /// The image drawn at `requested`; the original when that size is unusable or already matches.
    nonisolated static func sized(_ image: NSImage, to requested: CGSize) -> NSImage {
        guard requested.width > 0, requested.height > 0, requested != image.size else { return image }
        let box = Box(image)
        return NSImage(size: requested, flipped: false) { rect in
            box.image.draw(in: rect)
            return true
        }
    }
}

/// The real MediaPlayer wiring. Commands are added on `registerCommands` and removed on `removeCommands`.
@MainActor
final class SystemNowPlayingSurface: NowPlayingSurface {
    private var registrations: [(command: MPRemoteCommand, token: Any)] = []

    func setInfo(_ info: [String: Any], isPlaying: Bool) {
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = info
        center.playbackState = isPlaying ? .playing : .paused
    }

    func clearInfo() {
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = nil
        center.playbackState = .stopped
    }

    func registerCommands(_ handler: @escaping @MainActor (NowPlayingCommand) -> Void) {
        removeCommands()
        let center = MPRemoteCommandCenter.shared()
        let simple: [(MPRemoteCommand, NowPlayingCommand)] = [
            (center.playCommand, .play),
            (center.pauseCommand, .pause),
            (center.togglePlayPauseCommand, .toggle),
            (center.nextTrackCommand, .next),
            (center.previousTrackCommand, .previous)
        ]
        for (command, mapped) in simple {
            command.isEnabled = true
            registrations.append((command, command.addTarget(handler: Self.target(for: mapped, handler: handler))))
        }
        let scrub = center.changePlaybackPositionCommand
        scrub.isEnabled = true
        registrations.append((scrub, scrub.addTarget(handler: Self.scrubTarget(handler: handler))))

        let unused: [MPRemoteCommand] = [
            center.skipForwardCommand, center.skipBackwardCommand,
            center.seekForwardCommand, center.seekBackwardCommand,
            center.changePlaybackRateCommand,
            center.likeCommand, center.dislikeCommand, center.bookmarkCommand,
            center.changeRepeatModeCommand, center.changeShuffleModeCommand
        ]
        for command in unused { command.isEnabled = false }
    }

    func removeCommands() {
        for registration in registrations {
            registration.command.removeTarget(registration.token)
            registration.command.isEnabled = false
        }
        registrations = []
    }

    // The system calls these from its own queue, so they are built outside the main actor and hop back.

    private nonisolated static func target(
        for command: NowPlayingCommand,
        handler: @escaping @MainActor (NowPlayingCommand) -> Void
    ) -> (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        { _ in
            deliver(command, to: handler)
            return .success
        }
    }

    private nonisolated static func scrubTarget(
        handler: @escaping @MainActor (NowPlayingCommand) -> Void
    ) -> (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        { event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            deliver(.seek(event.positionTime), to: handler)
            return .success
        }
    }

    private nonisolated static func deliver(
        _ command: NowPlayingCommand,
        to handler: @escaping @MainActor (NowPlayingCommand) -> Void
    ) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { handler(command) }
        } else {
            Task { @MainActor in handler(command) }
        }
    }
}
