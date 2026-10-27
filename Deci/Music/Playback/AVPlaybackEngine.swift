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
    /// The volume (0...1, boost left out) and mute the player itself applies to an item the tap is not on.
    func setFallbackLevel(volume: Float, muted: Bool)
}

/// AVPlayer-backed engine. Observers exist only while an item is loaded.
///
/// With a `MusicDSPChain` every item gets an `MTAudioProcessingTap` (volume, boost, EQ, AutoEQ, loudness). The tap is
/// carried by the item's audio mix, which has to be on the item before the player gets it: an item that is playing
/// cannot take a mix without a gap, and a sample that skipped the tap would be heard unprocessed. So loading an item
/// first loads its tracks, builds the mix, and only then hands the item to the player. That wait is bounded: past
/// `mixTimeout` the item plays without the tap rather than not at all.
///
/// An item without the tap would ignore the row's volume and mute, so then the player's own volume and mute carry the
/// level (`setFallbackLevel`). With the tap the player stays at unity: the tap already applies it.
@MainActor
final class AVPlaybackEngine: PlaybackEngine {
    /// Builds the audio mix that carries the tap for an asset. nil: the asset cannot be tapped.
    /// `onPassThrough` is for the tap to call, from any thread, if it ends up not processing the audio.
    typealias MixBuilder = @MainActor (
        AVAsset, MusicDSPChain, _ onPassThrough: @escaping @Sendable () -> Void
    ) async -> AVAudioMix?

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
    /// How many times the loaded items ran out of buffered audio and stalled (each is logged as a `[GLITCH]` line).
    private(set) var stallCount = 0
    /// Receives each `[GLITCH]` stall line this engine writes to the log. A test seam.
    var onGlitchLine: (@MainActor (String) -> Void)?

    private static let logger = Logger(subsystem: "com.abraham.Deci", category: "AVPlaybackEngine")

    private let chain: MusicDSPChain?
    private let makeMix: MixBuilder
    private let mixTimeout: Duration
    private var installPending = false
    private var loggedUnprocessed = false
    /// Whether the item on the player (or being installed) has a working tap, which applies volume and mute itself.
    private var itemIsTapped = false
    private var fallbackVolume: Float = 1
    private var fallbackMuted = false
    /// The mix build and its timeout, for the item being loaded.
    private var loadTasks: [Task<Void, Never>] = []
    private let player = AVPlayer()
    /// The player itself, for tests to read what the engine really set on it.
    var avPlayer: AVPlayer { player }
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var controlObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var stallObserver: NSObjectProtocol?
    private var generation = 0
    private var wantsPlay = false
    private var pendingStart: TimeInterval = 0

    /// - Parameters:
    ///   - chain: The DSP to put on every item. nil plays items as they are (tests, and no mixer).
    ///   - makeMix: How a mix with the tap is built; replaced in tests.
    ///   - mixTimeout: How long an item waits for its mix before it plays without the tap.
    init(
        chain: MusicDSPChain? = nil,
        makeMix: @escaping MixBuilder = { asset, chain, onPassThrough in
            await MusicAudioTap.makeAudioMix(for: asset, chain: chain, onPassThrough: onPassThrough)
        },
        mixTimeout: Duration = .seconds(5)
    ) {
        self.chain = chain
        self.makeMix = makeMix
        self.mixTimeout = mixTimeout
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
        // The player ran out of buffered audio: audible as a gap, and a glitch the log should show.
        stallObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.playbackStalledNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.generation == token else { return }
                self.noteStall()
            }
        }

        guard let chain else {
            install(item, tapped: false)
            return
        }
        installPending = true
        let makeMix = makeMix
        // Called from the tap's thread: only the hop to the main actor touches the engine.
        let onPassThrough: @Sendable () -> Void = { [weak self] in
            Task { @MainActor [weak self] in self?.tapPassesThrough(token: token) }
        }
        let build = Task { @MainActor [weak self] in
            let mix = await makeMix(asset, chain, onPassThrough)
            self?.finishLoad(item, mix: mix, token: token, timedOut: false)
        }
        let timeout = Task { @MainActor [weak self, mixTimeout] in
            try? await Task.sleep(for: mixTimeout)
            guard !Task.isCancelled else { return }
            self?.finishLoad(item, mix: nil, token: token, timedOut: true)
        }
        loadTasks = [build, timeout]
    }

    /// The mix is built or gave up waiting for. A newer load, an unload or a deinit may have happened meanwhile, and
    /// whichever of the build and the timeout comes second finds the item installed already: that one is dropped.
    private func finishLoad(_ item: AVPlayerItem, mix: AVAudioMix?, token: Int, timedOut: Bool) {
        guard generation == token, installPending else { return }
        cancelLoadTasks()
        if let mix {
            item.audioMix = mix
        } else {
            noteUnprocessed(timedOut: timedOut)
        }
        install(item, tapped: mix != nil)
    }

    private func cancelLoadTasks() {
        for task in loadTasks { task.cancel() }
        loadTasks = []
    }

    private func install(_ item: AVPlayerItem, tapped: Bool) {
        installPending = false
        itemIsTapped = tapped
        applyPlayerLevel()
        willInstall?(item)
        player.replaceCurrentItem(with: item)
    }

    /// The tap met a format it cannot process and lets the audio through untouched. Only the item the report came from
    /// matters. The report runs from the tap's prepare, before its first buffer, but it reaches the main actor through
    /// a hop, so a buffer or two can still play at full level.
    private func tapPassesThrough(token: Int) {
        guard generation == token, itemIsTapped else { return }
        itemIsTapped = false
        noteUnprocessed(timedOut: false)
        applyPlayerLevel()
    }

    /// The item stalled. One persisted line per stall, in the format the glitch report reads.
    private func noteStall() {
        stallCount += 1
        let line = GlitchLogLine.makeStall(appName: GlitchLogLine.musicAppName, load: GlitchLogLine.loadAverage())
        if GlitchLogLine.isPersisted { Self.logger.notice("\(line, privacy: .public)") }
        onGlitchLine?(line)
    }

    /// The tap could not be built or did not come in time: the track still plays, without EQ and the rest, at the
    /// player's own volume and mute. Logged once, fixed text.
    private func noteUnprocessed(timedOut: Bool) {
        unprocessedLoadCount += 1
        guard !loggedUnprocessed else { return }
        loggedUnprocessed = true
        if timedOut {
            Self.logger.error("Music audio tap took too long, playing unprocessed")
        } else {
            Self.logger.error("Music audio tap unavailable, playing unprocessed")
        }
    }

    func setFallbackLevel(volume: Float, muted: Bool) {
        if volume.isFinite { fallbackVolume = min(1, max(0, volume)) }
        fallbackMuted = muted
        applyPlayerLevel()
    }

    /// With the tap on the item, the tap does the volume and mute and the player stays out of it, or the level would
    /// be applied twice. Without it the player's own volume and mute are all there is.
    private func applyPlayerLevel() {
        player.volume = itemIsTapped ? 1 : fallbackVolume
        player.isMuted = itemIsTapped ? false : fallbackMuted
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
        cancelLoadTasks()
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
        if let stallObserver {
            NotificationCenter.default.removeObserver(stallObserver)
            self.stallObserver = nil
        }
        player.pause()
        player.replaceCurrentItem(with: nil)
    }
}
