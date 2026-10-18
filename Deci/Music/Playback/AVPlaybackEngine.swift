// Deci/Music/Playback/AVPlaybackEngine.swift
import AVFoundation

/// What the engine reports back to `MusicPlayer`.
enum PlaybackEngineEvent: Equatable {
    case ready(duration: TimeInterval?)
    case playingChanged(Bool)
    case ended
    case failed
}

/// The AVPlayer seam: `MusicPlayer` drives it, tests replace it.
@MainActor
protocol PlaybackEngine: AnyObject {
    /// Position and play state every 0.5 s while an item is loaded, plus on seeks and play state changes.
    var onTick: (@MainActor (_ position: TimeInterval, _ isPlaying: Bool) -> Void)? { get set }
    var onEvent: (@MainActor (PlaybackEngineEvent) -> Void)? { get set }
    /// Position of the loaded item in seconds.
    var position: TimeInterval { get }

    /// Replaces the current item. Starts playing once ready when `autoplay` is set.
    func load(_ stream: ResolvedStream, startAt: TimeInterval, autoplay: Bool)
    func play()
    func pause()
    func seek(to seconds: TimeInterval)
    /// Drops the item and every observer.
    func unload()
}

/// AVPlayer-backed engine. Observers exist only while an item is loaded.
@MainActor
final class AVPlaybackEngine: PlaybackEngine {
    var onTick: (@MainActor (TimeInterval, Bool) -> Void)?
    var onEvent: (@MainActor (PlaybackEngineEvent) -> Void)?

    private let player = AVPlayer()
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var controlObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var generation = 0
    private var wantsPlay = false
    private var pendingStart: TimeInterval = 0

    init() {
        player.automaticallyWaitsToMinimizeStalling = true
    }

    isolated deinit {
        detach()
    }

    var position: TimeInterval {
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? seconds : 0
    }

    func load(_ stream: ResolvedStream, startAt: TimeInterval, autoplay: Bool) {
        detach()
        generation += 1
        let token = generation
        wantsPlay = autoplay
        pendingStart = startAt

        var options: [String: Any] = [:]
        if let userAgent = stream.httpHeaders["User-Agent"] {
            options[AVURLAssetHTTPUserAgentKey] = userAgent
        }
        let item = AVPlayerItem(asset: AVURLAsset(url: stream.url, options: options))

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.generation == token else { return }
                let seconds = time.seconds
                guard seconds.isFinite else { return }
                self.onTick?(seconds, self.player.timeControlStatus == .playing)
            }
        }

        statusObservation = item.observe(\.status, options: [.new]) { [weak self] observed, _ in
            let status = observed.status
            let duration = observed.duration.seconds
            Task { @MainActor [weak self] in
                self?.handleStatus(status, duration: duration, token: token)
            }
        }
        controlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] observed, _ in
            let playing = observed.timeControlStatus == .playing
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.onEvent?(.playingChanged(playing))
                self.onTick?(self.position, playing)
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.generation == token else { return }
                self.wantsPlay = false
                self.onEvent?(.ended)
            }
        }

        player.replaceCurrentItem(with: item)
    }

    func play() {
        wantsPlay = true
        if player.currentItem?.status == .readyToPlay { player.play() }
    }

    func pause() {
        wantsPlay = false
        player.pause()
    }

    func seek(to seconds: TimeInterval) {
        let target = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func unload() {
        detach()
        wantsPlay = false
    }

    private func handleStatus(_ status: AVPlayerItem.Status, duration: TimeInterval, token: Int) {
        guard generation == token else { return }
        switch status {
        case .readyToPlay:
            onEvent?(.ready(duration: duration.isFinite && duration > 0 ? duration : nil))
            let start = pendingStart
            pendingStart = 0
            if start > 0 {
                let target = CMTime(seconds: start, preferredTimescale: 600)
                player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == token, self.wantsPlay else { return }
                        self.player.play()
                    }
                }
            } else if wantsPlay {
                player.play()
            }
        case .failed:
            onEvent?(.failed)
        case .unknown:
            break
        @unknown default:
            break
        }
    }

    private func detach() {
        generation += 1
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        statusObservation?.invalidate()
        statusObservation = nil
        controlObservation?.invalidate()
        controlObservation = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        player.pause()
        player.replaceCurrentItem(with: nil)
    }
}
