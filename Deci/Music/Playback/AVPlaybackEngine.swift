// Deci/Music/Playback/AVPlaybackEngine.swift
import AVFoundation
import os

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
    /// Sends the audio to the output device with this UID. nil (or an empty UID) follows the system default output.
    func setOutputDevice(uid: String?)
}

/// AVPlayer-backed engine. Observers exist only while an item is loaded.
///
/// With a `MusicDSPChain` every item gets an `MTAudioProcessingTap` (volume, boost, EQ, AutoEQ, loudness). The tap is
/// carried by the item's audio mix, which has to be on the item before the player gets it: an item that is playing
/// cannot take a mix without a gap, and a sample that skipped the tap would be heard unprocessed. So loading an item
/// first loads its tracks, builds the mix, and only then hands the item to the player.
@MainActor
final class AVPlaybackEngine: PlaybackEngine {
    /// Builds the audio mix that carries the tap for an asset. nil: the asset cannot be tapped.
    typealias MixBuilder = @MainActor (AVAsset, MusicDSPChain) async -> AVAudioMix?

    var onTick: (@MainActor (TimeInterval, Bool) -> Void)?
    var onEvent: (@MainActor (PlaybackEngineEvent) -> Void)?

    /// Called with the item at the moment it is handed to the player, mix already attached. A test seam.
    var willInstall: ((AVPlayerItem) -> Void)?
    /// The item the player holds right now. nil while a load is still building its mix.
    var currentItem: AVPlayerItem? { player.currentItem }
    /// How many items played without the tap because it could not be built.
    private(set) var unprocessedLoadCount = 0
    /// The output device last asked for. nil is the system default.
    private(set) var outputDeviceUID: String?

    private static let logger = Logger(subsystem: "com.abraham.Deci", category: "AVPlaybackEngine")

    private let chain: MusicDSPChain?
    private let makeMix: MixBuilder
    private var installPending = false
    private var loggedUnprocessed = false
    private let player = AVPlayer()
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var controlObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var generation = 0
    private var wantsPlay = false
    private var pendingStart: TimeInterval = 0

    /// - Parameters:
    ///   - chain: The DSP to put on every item. nil plays items as they are (tests, and no mixer).
    ///   - makeMix: How a mix with the tap is built; replaced in tests.
    init(
        chain: MusicDSPChain? = nil,
        makeMix: @escaping MixBuilder = { asset, chain in await MusicAudioTap.makeAudioMix(for: asset, chain: chain) }
    ) {
        self.chain = chain
        self.makeMix = makeMix
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
        let asset = AVURLAsset(url: stream.url, options: options)
        let item = AVPlayerItem(asset: asset)
        let knownDuration = Self.knownDuration(of: stream)
        if let knownDuration {
            // Without this the item runs on through the bogus silent half (see `knownDuration(of:)`).
            item.forwardPlaybackEndTime = CMTime(seconds: knownDuration, preferredTimescale: 1000)
        }

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
            Task { @MainActor [weak self] in
                // Never the item's own duration: it is doubled. Unknown leaves the player on the track's listed length.
                self?.handleStatus(status, duration: knownDuration, token: token)
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

        guard let chain else {
            install(item)
            return
        }
        installPending = true
        let makeMix = makeMix
        Task { @MainActor [weak self] in
            let mix = await makeMix(asset, chain)
            // A newer load, an unload or a deinit may have happened while the tracks loaded: that item is dropped.
            guard let self, self.generation == token else { return }
            if let mix {
                item.audioMix = mix
            } else {
                self.noteUnprocessed()
            }
            self.install(item)
        }
    }

    private func install(_ item: AVPlayerItem) {
        installPending = false
        willInstall?(item)
        player.replaceCurrentItem(with: item)
    }

    /// The tap could not be built: the track still plays, without volume, EQ and the rest. Logged once, fixed text.
    private func noteUnprocessed() {
        unprocessedLoadCount += 1
        guard !loggedUnprocessed else { return }
        loggedUnprocessed = true
        Self.logger.error("Music audio tap unavailable, playing unprocessed")
    }

    func setOutputDevice(uid: String?) {
        let resolved = (uid?.isEmpty ?? true) ? nil : uid
        outputDeviceUID = resolved
        player.audioOutputDeviceUniqueID = resolved
    }

    /// The stream's own length (YouTube's approxDurationMs, exact to the millisecond), when it has one.
    /// AVFoundation reads YouTube's fragmented audio as twice its real length: the empty header still states the
    /// full duration and the fragments are added on top. Trusting it plays the song, then as long again of silence.
    nonisolated static func knownDuration(of stream: ResolvedStream) -> TimeInterval? {
        guard let seconds = stream.durationSeconds, seconds.isFinite, seconds > 0 else { return nil }
        return seconds
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
        if installPending {
            // The item is not on the player yet: the seek happens when it becomes ready.
            pendingStart = max(0, seconds)
            return
        }
        let target = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func unload() {
        detach()
        wantsPlay = false
    }

    private func handleStatus(_ status: AVPlayerItem.Status, duration: TimeInterval?, token: Int) {
        guard generation == token else { return }
        switch status {
        case .readyToPlay:
            onEvent?(.ready(duration: duration))
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
        installPending = false
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
