// Deci/Music/Playback/AVPlaybackEngine.swift
import AVFoundation
import CoreMedia
import os

/// What the engine reports back to `MusicPlayer`.
enum PlaybackEngineEvent: Equatable {
    case ready(duration: TimeInterval?)
    case playingChanged(Bool)
    case ended
    case failed
    /// The active item ended and the preloaded one (this video id) plays on: no gap, no `ended`. The engine now holds
    /// the new item as its active one and nothing is preloaded any more.
    case advanced(videoId: String)
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

    /// The video id of the item held ready for the active one's end, nil when nothing is preloaded.
    var preloadedVideoId: String? { get }
    /// Prepares `stream` on the standby deck (item, tap, preroll) so it can start the instant the active item ends.
    /// Replaces an earlier preload. Never disturbs the item that is playing. With a plan (Tier 2b) the standby is parked
    /// at `plan.incomingStartSec` before it prerolls, the active item ends at the plan's trimmed end, and the plan drives
    /// the fade start, its length and the loudness offsets. nil is exactly the Tier 1 behaviour.
    func preload(_ stream: ResolvedStream, plan: TransitionPlan?)
    /// Replaces the plan of the current preload. Ignored when nothing is preloaded, when a fade is already running, or
    /// when `incomingStartSec` differs (the standby is already parked).
    func updateTransitionPlan(_ plan: TransitionPlan?)
    /// The plan of the current preload, nil without one. `incomingStartSec` is where the standby really is parked: 0 when
    /// the seek to the planned offset could not be done.
    var transitionPlan: TransitionPlan? { get }
    /// Drops the preload, whether it is still loading, ready or already scheduled to start.
    func cancelPreload()

    /// How long the next track fades in over the end of the active one, in seconds. 0 (the default) is the gapless
    /// switch. Read when the standby's start is scheduled: a fade already running finishes, the next transition follows
    /// the new value.
    var crossfadeSeconds: TimeInterval { get set }
    /// The preload is built and prerolled, so it can start the moment it is asked to.
    var preloadIsReady: Bool { get }
    /// Starts the preloaded track now and fades it in over `seconds` while the active one fades out, for a manual skip.
    /// The preloaded track becomes the active one and no `advanced` event is sent. False (and nothing changes) when the
    /// preload is not ready or the decks cannot crossfade.
    func crossfadeToPreloaded(seconds: TimeInterval) -> Bool
    /// Whether `crossfadeToPreloaded` would be accepted now (mirrors its guards), so a caller can decide before it acts.
    var canCrossfadeToPreloaded: Bool { get }
    /// Where the outgoing track really was when the last crossfade started, nil after a gapless hand-over or a load.
    var outgoingPositionAtCrossfade: TimeInterval? { get }
}

extension PlaybackEngine {
    /// A preload without a plan: the Tier 1 behaviour.
    func preload(_ stream: ResolvedStream) { preload(stream, plan: nil) }
}

/// AVPlayer-backed engine with two decks. Observers exist only while an item is loaded.
///
/// With a `MusicDSPChain` every item gets an `MTAudioProcessingTap` (volume, boost, EQ, AutoEQ, loudness). The tap is
/// carried by the item's audio mix, which has to be on the item before the player gets it: an item that is playing
/// cannot take a mix without a gap, and a sample that skipped the tap would be heard unprocessed. So loading an item
/// first loads its tracks, builds the mix, and only then hands the item to the player. That wait is bounded: past
/// `mixTimeout` the item plays without the tap rather than not at all.
///
/// An item without the tap would ignore the row's volume and mute, so then the player's own volume and mute carry the
/// level (`setFallbackLevel`). With the tap the player stays at unity: the tap already applies it.
///
/// Gapless: the engine owns an active and a standby deck, each its own `AVPlayer`. `load` always goes to the active
/// deck. `preload` builds the next item on the standby deck the same way (same mix path, same end-time rule), waits for
/// it to be ready and prerolls it paused. Shortly before the active item's end the standby is scheduled to start on the
/// exact host time of that end (`setRate(_:time:atHostTime:)`), so the next track's first sample follows the last of
/// the old one. The schedule is dropped and redone when the active deck pauses, seeks, stalls or changes rate. The end
/// notification stays the fallback: if the standby is ready it is started right there (and becomes the active deck),
/// and if no preload matches the engine reports `ended` as it always did.
@MainActor
final class AVPlaybackEngine: PlaybackEngine {
    /// Builds the audio mix that carries the tap for an asset. nil: the asset cannot be tapped.
    /// `onPassThrough` is for the tap to call, from any thread, if it ends up not processing the audio.
    typealias MixBuilder = @MainActor (
        AVAsset, MusicDSPChain, _ onPassThrough: @escaping @Sendable () -> Void
    ) async -> AVAudioMix?

    var onTick: (@MainActor (TimeInterval, Bool) -> Void)?
    var onEvent: (@MainActor (PlaybackEngineEvent) -> Void)?

    /// Called with the item at the moment it is handed to a player, mix already attached. A test seam.
    var willInstall: ((AVPlayerItem) -> Void)?
    /// The item the active player holds right now. nil while a load is still building its mix.
    var currentItem: AVPlayerItem? { active.player.currentItem }
    /// How many items played without the tap because it could not be built.
    private(set) var unprocessedLoadCount = 0
    /// The output device last asked for. nil is the system default.
    private(set) var outputDeviceUID: String?
    /// How many times the loaded items ran out of buffered audio and stalled (each is logged as a `[GLITCH]` line).
    private(set) var stallCount = 0
    /// Receives each `[GLITCH]` stall line this engine writes to the log. A test seam.
    var onGlitchLine: (@MainActor (String) -> Void)?

    private static let logger = Logger(subsystem: "com.abraham.Deci", category: "AVPlaybackEngine")
    /// The standby is scheduled once the active item has this long left, and re-scheduled while the estimate of its end moves.
    private static let scheduleWindow: TimeInterval = 6
    /// How far the end estimate may drift before the standby's start is moved.
    private static let scheduleTolerance: TimeInterval = 0.04
    /// The standby's tap is armed this long before its scheduled start.
    private static let armLead: TimeInterval = 0.25
    /// The crossfade starts this long before the standby's start host time, so the incoming fade is already running when
    /// its first frame is heard.
    private static let fadeLead: TimeInterval = 0.05
    /// A fade shorter than this is not worth it: the switch is gapless instead.
    private static let minimumFade: TimeInterval = 1
    /// Tier 3b: seconds added to the incoming start host time so two beats land together (measured in the 3a spike).
    nonisolated static let beatCalibrationSec = -0.007
    /// Never schedule a fade start closer than this to now.
    private static let fadeGuard: TimeInterval = 0.25
    /// A scheduled start stays this far (more than the 0.05 s the scheduler needs) from the item's end.
    private static let latestLeadMargin: TimeInterval = 0.1
    /// The outgoing deck of a seek, skip or quick fade is gone within this.
    private static let quickDrain: TimeInterval = 0.03

    /// One AVPlayer and everything that belongs to the item it holds.
    @MainActor
    private final class Deck {
        let player = AVPlayer()
        /// Bumped on every load and teardown: an observer or a late task from before it finds a different value and quits.
        var token = 0
        var videoId: String?
        /// The item time a standby is parked at before it prerolls (0 = untouched).
        var startOffset: TimeInterval = 0
        /// The item's end from the stream's own duration (never the item's doubled one), nil when unknown.
        var naturalEnd: TimeInterval?
        var tap: MusicTapDeck?
        /// Whether the item on the player (or being installed) has a working tap, which applies volume and mute itself.
        var itemIsTapped = false
        var installPending = false
        /// The mix build and its timeout, for the item being loaded.
        var loadTasks: [Task<Void, Never>] = []
        var timeObserver: Any?
        var statusObservation: NSKeyValueObservation?
        var controlObservation: NSKeyValueObservation?
        var rateObservation: NSKeyValueObservation?
        var endObserver: NSObjectProtocol?
        var stallObserver: NSObjectProtocol?

        func cancelLoadTasks() {
            for task in loadTasks { task.cancel() }
            loadTasks = []
        }

        /// Drops the item and every observer; the player stays for the next item.
        func tearDown() {
            token += 1
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
            rateObservation?.invalidate()
            rateObservation = nil
            if let endObserver {
                NotificationCenter.default.removeObserver(endObserver)
                self.endObserver = nil
            }
            if let stallObserver {
                NotificationCenter.default.removeObserver(stallObserver)
                self.stallObserver = nil
            }
            tap?.retire()
            tap = nil
            player.pause()
            player.replaceCurrentItem(with: nil)
            videoId = nil
            startOffset = 0
            naturalEnd = nil
        }
    }

    private let chain: MusicDSPChain?
    private let makeMix: MixBuilder
    private let mixTimeout: Duration
    private var loggedUnprocessed = false
    private var fallbackVolume: Float = 1
    private var fallbackMuted = false
    private var active = Deck()
    private var standby = Deck()
    /// The deck whose item is fading out under the new one in a crossfade, nil outside one.
    private var draining: Deck?
    /// Counts the played seconds of the drain, so a pause holds it. Cancelled with the drain.
    private var drainTask: Task<Void, Never>?
    /// Fires the crossfade at its start time.
    private var fadeStartTask: Task<Void, Never>?
    var crossfadeSeconds: TimeInterval = 0
    /// The fade length the scheduled start was planned for, 0 when it is a gapless switch. Fixed while scheduled.
    private var plannedFade: TimeInterval = 0
    private var plannedFor: TimeInterval = 0
    /// How long before the active item's end the scheduled standby starts (the overlap's start). Equal to `plannedFade`
    /// unless a smart plan starts the fade earlier. Fixed while scheduled.
    private var plannedLead: TimeInterval = 0
    /// The plan the scheduled start was planned for.
    private var plannedPlan: TransitionPlan?
    /// The plan of the current preload.
    private(set) var transitionPlan: TransitionPlan?
    /// The offset the plan asked the standby to be parked at, as asked (the deck's own may fall back to 0).
    private var requestedStartOffset: TimeInterval = 0
    /// The active item's forwardPlaybackEndTime was moved to the plan's trimmed end.
    private var endTrimmed = false
    /// A listener's seek landed at or near the trimmed end: the item's natural end is back and the transition is Tier 1
    /// style from there (the setting's fade, ending at the natural end). Reset with the plan.
    private var endRestoredBySeek = false
    /// Seconds of the incoming glide back to 0 dB, started when the outgoing deck has drained. 0 = none pending.
    private var pendingGlide: TimeInterval = 0
    /// The fall-back reason of this preload was logged already.
    private var loggedFallback = false
    /// The rate the scheduled standby start was planned at: the beat plan's nudge, 1 for every other transition.
    private var plannedRate: Float = 1
    /// A beat mix's overlap, from its flip until the outgoing deck has drained: what a resume needs to realign the decks.
    private var beatOverlap: BeatOverlap?
    /// The rate glide back to 1 that follows a beat mix, nil outside one.
    private var glide: Glide?
    private var glideTask: Task<Void, Never>?

    /// What is kept of a beat mix while both decks play.
    struct BeatOverlap: Equatable {
        var rate: Float
        var mixIn: TimeInterval
        var mixOut: TimeInterval
        var glideSeconds: TimeInterval
    }

    /// The incoming song's rate on its way back to 1. `elapsed` counts play-intent seconds only.
    struct Glide: Equatable {
        var from: Float
        var total: TimeInterval
        var elapsed: TimeInterval = 0
    }

    /// The glide's rate after `elapsed` of `total` seconds: a smoothstep from `from` to 1, so it starts and ends flat.
    nonisolated static func glideRate(from: Float, elapsed: TimeInterval, total: TimeInterval) -> Float {
        guard from.isFinite, total > 0, elapsed.isFinite else { return 1 }
        let x = Float(min(1, max(0, elapsed / total)))
        let eased = x * x * (3 - 2 * x)
        return from + (1 - from) * eased
    }

    /// How far the incoming deck is from where the grid says it should be, given where both decks are (positive: ahead).
    nonisolated static func overlapDrift(
        incoming: TimeInterval, outgoing: TimeInterval, rate: Float, mixIn: TimeInterval, mixOut: TimeInterval
    ) -> TimeInterval {
        incoming - (mixIn + Double(rate) * (outgoing - mixOut))
    }

    /// A resume that finds the decks further apart than this puts the incoming song back on the grid first.
    nonisolated static let resumeDriftTolerance: TimeInterval = 0.03
    /// How far ahead of now both decks are restarted together after a pause in the overlap.
    nonisolated static let resumeLead: TimeInterval = 0.15
    /// The step of the rate glide.
    nonisolated static let glideTick: TimeInterval = 0.1
    /// How many crossfades started (a scheduled one or a manual one). A test seam.
    private(set) var crossfadeCount = 0
    private(set) var outgoingPositionAtCrossfade: TimeInterval?
    /// Whether a crossfade is running (the old item still fading out).
    var isCrossfading: Bool { draining != nil }
    #if DEBUG
    var debugDrainingTap: MusicTapDeck? { draining?.tap }
    var debugDrainingPlayer: AVPlayer? { draining?.player }
    #endif
    /// The active player, for tests to read what the engine really set on it.
    var avPlayer: AVPlayer { active.player }
    /// The standby player, for tests.
    var standbyAvPlayer: AVPlayer { standby.player }
    private var wantsPlay = false
    private var pendingStart: TimeInterval = 0

    /// The stream being prepared on (or ready on) the standby deck.
    private var preloadStream: ResolvedStream?
    /// The standby's item is ready and prerolled.
    private var preloadReady = false
    /// The host time the standby is scheduled to start at, nil while it is not scheduled.
    private var scheduledHost: CMTime?
    /// The standby was started by `startStandby(atHostTime:rate:)` (a beat-matched entry at a nudged rate). The gapless
    /// schedule leaves it alone while this is set, and every path that takes the standby back clears it.
    private(set) var alignedStart = false
    /// The preroll was retried once already for this preload.
    private var prerollRetried = false
    /// Arms the standby's tap shortly before its scheduled start (not when the start is scheduled, up to 6 s earlier).
    private var armTask: Task<Void, Never>?

    /// How many hand-overs found the standby already running on its scheduled start, how many had to start it at the
    /// end notification, and how many of those found it not running although it was scheduled. Test seams.
    private(set) var scheduledAdvanceCount = 0
    private(set) var fallbackAdvanceCount = 0
    private(set) var lateStartCount = 0
    /// The standby's start host time, for tests.
    var scheduledStartHost: CMTime? { scheduledHost }
    #if DEBUG
    /// Makes the next seek to a planned incoming offset count as failed. A test seam.
    var debugFailNextParkSeek = false
    var debugActiveTap: MusicTapDeck? { active.tap }
    /// Marks the preload ready without any media, so the aligned-start paths can be tested. A test seam.
    func debugMarkPreloadReady() { if preloadStream != nil { preloadReady = true } }
    /// Sets the aligned flag without starting the player (a fake item can not take a synchronized start). A test seam.
    func debugSetAlignedStart() { alignedStart = true }
    /// Runs the end-of-item hand-over and the schedule check directly. Test seams.
    func debugActiveItemEnded() { activeItemEnded() }
    func debugEvaluateSchedule() { evaluateSchedule() }
    /// The rate glide, driven by hand. Test seams.
    func debugStartGlide(from rate: Float, over seconds: TimeInterval) { startGlide(from: rate, over: seconds) }
    func debugAdvanceGlide(by seconds: TimeInterval) { advanceGlide(by: seconds) }
    var debugGlide: Glide? { glide }
    var debugGlideCurrentRate: Float? {
        glide.map { Self.glideRate(from: $0.from, elapsed: $0.elapsed, total: $0.total) }
    }
    var debugPlannedRate: Float { plannedRate }
    var debugGlideTicking: Bool { glideTask != nil }
    var debugBeatOverlap: BeatOverlap? { beatOverlap }
    func debugSetBeatOverlap(_ overlap: BeatOverlap?) { beatOverlap = overlap }
    func debugSetWantsPlay(_ on: Bool) { wantsPlay = on }
    func debugBeatSchedule(rate: Float, at host: CMTime) {
        plannedRate = rate
        plannedFade = 0
        schedule(at: host)
    }
    var debugStandbyTap: MusicTapDeck? { standby.tap }
    /// Called when a preroll of the standby has completed, with its `finished` flag. A test seam.
    var onStandbyPrerolled: ((Bool) -> Void)?
    #endif

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
        active.player.automaticallyWaitsToMinimizeStalling = true
        // A player that is told to start at a host time must not wait to minimise stalling (it would start when it likes).
        standby.player.automaticallyWaitsToMinimizeStalling = false
    }

    isolated deinit {
        cancelPreload()
        drainTask?.cancel()
        draining?.tearDown()
        active.tearDown()
    }

    var position: TimeInterval {
        let seconds = active.player.currentTime().seconds
        return seconds.isFinite ? seconds : 0
    }

    var preloadedVideoId: String? { preloadStream?.videoId }
    var preloadIsReady: Bool { preloadStream != nil && preloadReady }

    // MARK: - Loading

    func load(_ stream: ResolvedStream, startAt: TimeInterval, autoplay: Bool) {
        // Whatever was preloaded was for the track after the one that is being replaced.
        cancelPreload()
        snapRate(why: "skip")
        endDrain(fast: true)
        pendingGlide = 0
        outgoingPositionAtCrossfade = nil
        active.tearDown()
        wantsPlay = autoplay
        pendingStart = startAt
        active.player.automaticallyWaitsToMinimizeStalling = true
        startItem(on: active, stream: stream, role: .active)
    }

    /// Builds the item for `stream` on `deck`, with its observers, and installs it once its mix is built (or has timed out).
    private func startItem(on deck: Deck, stream: ResolvedStream, role: MusicTapDeck.Role) {
        deck.token += 1
        let token = deck.token
        deck.videoId = stream.videoId
        let tap = MusicTapDeck(role: role)
        deck.tap = tap

        var options: [String: Any] = [:]
        if let userAgent = stream.httpHeaders["User-Agent"] {
            options[AVURLAssetHTTPUserAgentKey] = userAgent
        }
        let asset = AVURLAsset(url: stream.url, options: options)
        let item = AVPlayerItem(asset: asset)
        // A nudged rate keeps its pitch, and the beats stay put on the grid (the default algorithm does neither well).
        item.audioTimePitchAlgorithm = .spectral
        let knownDuration = Self.knownDuration(of: stream)
        deck.naturalEnd = knownDuration
        if let knownDuration {
            // Without this the item runs on through the bogus silent half (see `knownDuration(of:)`).
            item.forwardPlaybackEndTime = CMTime(seconds: knownDuration, preferredTimescale: 1000)
        }

        // Observers only speak for the deck that is active: a standby deck's item is not what the listener hears yet.
        deck.timeObserver = deck.player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self, weak deck] time in
            MainActor.assumeIsolated {
                guard let self, let deck, self.isLive(deck, token) else { return }
                let seconds = time.seconds
                guard seconds.isFinite else { return }
                self.onTick?(seconds, deck.player.timeControlStatus == .playing)
                // The end estimate drifts with stalls and clock changes: keep the standby's start on it.
                self.evaluateSchedule()
            }
        }
        deck.statusObservation = item.observe(\.status, options: [.new]) { [weak self, weak deck] observed, _ in
            let status = observed.status
            Task { @MainActor [weak self, weak deck] in
                guard let self, let deck else { return }
                // Never the item's own duration: it is doubled. Unknown leaves the player on the track's listed length.
                self.handleStatus(status, on: deck, duration: knownDuration, token: token)
            }
        }
        deck.controlObservation = deck.player.observe(\.timeControlStatus, options: [.new]) { [weak self, weak deck] observed, _ in
            let playing = observed.timeControlStatus == .playing
            Task { @MainActor [weak self, weak deck] in
                guard let self, let deck, self.isLive(deck, token) else { return }
                self.onEvent?(.playingChanged(playing))
                self.onTick?(self.position, playing)
                self.activeTransportChanged()
            }
        }
        deck.rateObservation = deck.player.observe(\.rate, options: [.new]) { [weak self, weak deck] _, _ in
            Task { @MainActor [weak self, weak deck] in
                guard let self, let deck, self.isLive(deck, token) else { return }
                self.activeTransportChanged()
            }
        }
        deck.endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self, weak deck] _ in
            MainActor.assumeIsolated {
                guard let self, let deck, self.isLive(deck, token) else { return }
                self.activeItemEnded()
            }
        }
        // The player ran out of buffered audio: audible as a gap, and a glitch the log should show.
        deck.stallObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.playbackStalledNotification,
            object: item,
            queue: .main
        ) { [weak self, weak deck] _ in
            MainActor.assumeIsolated {
                guard let self, let deck, self.isLive(deck, token) else { return }
                self.noteStall()
            }
        }

        guard let chain else {
            install(item, on: deck, tapped: false)
            return
        }
        deck.installPending = true
        let makeMix = makeMix
        // Called from the tap's thread: only the hop to the main actor touches the engine.
        let onPassThrough: @Sendable () -> Void = { [weak self, weak deck] in
            Task { @MainActor [weak self, weak deck] in
                guard let self, let deck else { return }
                self.tapPassesThrough(on: deck, token: token)
            }
        }
        let build = Task { @MainActor [weak self, weak deck] in
            // The deck handle reaches the tap through a task local, so the mix builder keeps its signature.
            let mix = await MusicAudioTap.$currentDeck.withValue(tap) {
                await makeMix(asset, chain, onPassThrough)
            }
            guard let self, let deck else { return }
            self.finishLoad(item, on: deck, mix: mix, token: token, timedOut: false)
        }
        let timeout = Task { @MainActor [weak self, weak deck, mixTimeout] in
            try? await Task.sleep(for: mixTimeout)
            guard !Task.isCancelled, let self, let deck else { return }
            self.finishLoad(item, on: deck, mix: nil, token: token, timedOut: true)
        }
        deck.loadTasks = [build, timeout]
    }

    /// The deck's item is still the one the observers were made for, and the deck is the one that is playing.
    private func isLive(_ deck: Deck, _ token: Int) -> Bool {
        active === deck && deck.token == token
    }

    /// The mix is built or gave up waiting for. A newer load, an unload or a deinit may have happened meanwhile, and
    /// whichever of the build and the timeout comes second finds the item installed already: that one is dropped.
    private func finishLoad(_ item: AVPlayerItem, on deck: Deck, mix: AVAudioMix?, token: Int, timedOut: Bool) {
        guard deck.token == token, deck.installPending else { return }
        deck.cancelLoadTasks()
        if let mix {
            item.audioMix = mix
        } else {
            noteUnprocessed(timedOut: timedOut)
        }
        install(item, on: deck, tapped: mix != nil)
    }

    private func install(_ item: AVPlayerItem, on deck: Deck, tapped: Bool) {
        deck.installPending = false
        deck.itemIsTapped = tapped
        applyLevel(to: deck)
        willInstall?(item)
        deck.player.replaceCurrentItem(with: item)
        // A preload made while this item was still being built could not move its end yet.
        if deck === active, preloadStream != nil { applyOutgoingEnd() }
    }

    /// The tap met a format it cannot process and lets the audio through untouched. Only the item the report came from
    /// matters. The report runs from the tap's prepare, before its first buffer, but it reaches the main actor through
    /// a hop, so a buffer or two can still play at full level.
    private func tapPassesThrough(on deck: Deck, token: Int) {
        guard deck.token == token, deck.itemIsTapped else { return }
        deck.itemIsTapped = false
        noteUnprocessed(timedOut: false)
        applyLevel(to: deck)
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

    // MARK: - Level and output (both decks)

    func setFallbackLevel(volume: Float, muted: Bool) {
        if volume.isFinite { fallbackVolume = min(1, max(0, volume)) }
        fallbackMuted = muted
        applyLevel(to: active)
        applyLevel(to: standby)
    }

    /// With the tap on the item, the tap does the volume and mute and the player stays out of it, or the level would
    /// be applied twice. Without it the player's own volume and mute are all there is.
    private func applyLevel(to deck: Deck) {
        deck.player.volume = deck.itemIsTapped ? 1 : fallbackVolume
        deck.player.isMuted = deck.itemIsTapped ? false : fallbackMuted
    }

    func setOutputDevice(uid: String?) {
        let resolved = (uid?.isEmpty ?? true) ? nil : uid
        outputDeviceUID = resolved
        // Moving a player to another device can drop a start that is scheduled on it: take it back and set it again.
        let rescheduled = scheduledHost != nil || alignedStart
        if rescheduled { cancelSchedule() }
        snapRate(why: "output")
        active.player.audioOutputDeviceUniqueID = resolved
        standby.player.audioOutputDeviceUniqueID = resolved
        // Both decks of a crossfade move together: one left on the old device would play its half of the fade there.
        draining?.player.audioOutputDeviceUniqueID = resolved
        if rescheduled { evaluateSchedule() }
    }

    /// The stream's own length (YouTube's approxDurationMs, exact to the millisecond), when it has one.
    /// AVFoundation reads YouTube's fragmented audio as twice its real length: the empty header still states the
    /// full duration and the fragments are added on top. Trusting it plays the song, then as long again of silence.
    nonisolated static func knownDuration(of stream: ResolvedStream) -> TimeInterval? {
        guard let seconds = stream.durationSeconds, seconds.isFinite, seconds > 0 else { return nil }
        return seconds
    }

    // MARK: - Transport

    func play() {
        wantsPlay = true
        // A beat mix paused in the middle goes on with both decks on the same host time, so they stay on the grid.
        if let draining, draining.player.currentItem != nil, let overlap = beatOverlap,
           active.player.currentItem?.status == .readyToPlay {
            resumeBeatOverlap(draining: draining, overlap: overlap)
            return
        }
        if active.player.currentItem?.status == .readyToPlay {
            if let glide {
                // A glide that was held by a pause goes on from where it was, not from 1.
                active.player.rate = Self.glideRate(from: glide.from, elapsed: glide.elapsed, total: glide.total)
                runGlideTask()
            } else {
                active.player.play()
            }
        }
        // A crossfade that was paused in the middle goes on, both decks together.
        if let draining, draining.player.currentItem != nil { draining.player.play() }
    }

    /// Restarts both decks of a paused beat overlap at the same host time. An incoming deck that is more than 30 ms off
    /// the grid (the two pauses did not land on the same sample) is put back on it first.
    private func resumeBeatOverlap(draining: Deck, overlap: BeatOverlap) {
        let outgoing = draining.player.currentTime().seconds
        let incoming = active.player.currentTime().seconds
        let token = active.token
        let restart: @MainActor () -> Void = { [weak self] in
            guard let self, self.wantsPlay, self.active.token == token, let draining = self.draining else { return }
            let host = CMTimeAdd(
                CMClockGetTime(CMClockGetHostTimeClock()),
                CMTime(seconds: Self.resumeLead, preferredTimescale: 1_000_000_000)
            )
            // setRate(_:time:atHostTime:) traps while a deck waits to minimise stalling; the flip turned that on for the
            // active deck, so both are made ready here and the active one gets it back when the drain ends.
            self.active.player.automaticallyWaitsToMinimizeStalling = false
            draining.player.automaticallyWaitsToMinimizeStalling = false
            if !self.hasRunOut(draining.player) {
                draining.player.setRate(1, time: .invalid, atHostTime: host)
            }
            self.active.player.setRate(overlap.rate, time: .invalid, atHostTime: host)
        }
        guard outgoing.isFinite, incoming.isFinite, !hasRunOut(draining.player) else {
            restart()
            return
        }
        let drift = Self.overlapDrift(
            incoming: incoming, outgoing: outgoing, rate: overlap.rate, mixIn: overlap.mixIn, mixOut: overlap.mixOut
        )
        guard abs(drift) > Self.resumeDriftTolerance else {
            restart()
            return
        }
        let expected = incoming - drift
        active.player.seek(
            to: CMTime(seconds: max(0, expected), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero
        ) { _ in Task { @MainActor in restart() } }
    }

    func pause() {
        wantsPlay = false
        cancelSchedule()
        // A held glide does not tick while paused; play() starts it again.
        glideTask?.cancel()
        glideTask = nil
        active.player.pause()
        draining?.player.pause()
    }

    func seek(to seconds: TimeInterval) {
        if active.installPending {
            // The item is not on the player yet: the seek happens when it becomes ready.
            pendingStart = max(0, seconds)
            return
        }
        snapRate(why: "seek")
        // A seek in the middle of a crossfade lands on the incoming track, which is the current one already: the old one
        // is let go almost at once and the new one comes up to full level.
        if draining != nil {
            endDrain(fast: true)
            active.tap?.fade(to: 1, over: Self.quickDrain)
        }
        restoreEndForSeek(to: seconds)
        // The end moved: the standby's start goes with it, and is set again once the seek has landed.
        cancelSchedule()
        let token = active.token
        let target = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        active.player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.active.token == token else { return }
                self.activeTransportChanged()
            }
        }
    }

    func unload() {
        cancelPreload()
        snapRate(why: "skip")
        endDrain(fast: true)
        pendingGlide = 0
        active.tearDown()
        wantsPlay = false
    }

    private func handleStatus(_ status: AVPlayerItem.Status, on deck: Deck, duration: TimeInterval?, token: Int) {
        guard deck.token == token else { return }
        guard deck === active else {
            handleStandbyStatus(status, on: deck, token: token)
            return
        }
        switch status {
        case .readyToPlay:
            onEvent?(.ready(duration: duration))
            let start = pendingStart
            pendingStart = 0
            if start > 0 {
                let target = CMTime(seconds: start, preferredTimescale: 600)
                deck.player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak deck] _ in
                    Task { @MainActor [weak self, weak deck] in
                        guard let self, let deck, self.isLive(deck, token), self.wantsPlay else { return }
                        deck.player.play()
                    }
                }
            } else if wantsPlay {
                deck.player.play()
            }
        case .failed:
            onEvent?(.failed)
        case .unknown:
            break
        @unknown default:
            break
        }
    }

    // MARK: - Preload

    func preload(_ stream: ResolvedStream, plan: TransitionPlan?) {
        cancelPreload()
        preloadStream = stream
        preloadReady = false
        prerollRetried = false
        loggedFallback = false
        transitionPlan = plan
        standby.player.audioOutputDeviceUniqueID = outputDeviceUID
        standby.player.automaticallyWaitsToMinimizeStalling = false
        startItem(on: standby, stream: stream, role: .standby)
        // The park offset must lie inside the stream (its exact duration, never the item's doubled one).
        let wanted = plan?.incomingStartSec ?? 0
        requestedStartOffset = wanted.isFinite ? max(0, wanted) : 0
        var offset = requestedStartOffset
        if let end = standby.naturalEnd, offset >= end - 1 { offset = 0 }
        standby.startOffset = offset
        if offset != requestedStartOffset { transitionPlan?.incomingStartSec = 0 }
        applyOutgoingEnd()
    }

    func updateTransitionPlan(_ plan: TransitionPlan?) {
        guard preloadStream != nil, draining == nil else { return }
        let wanted = plan?.incomingStartSec ?? 0
        guard wanted == requestedStartOffset else { return }
        // The standby is parked on the beat plan's mix-in and will start at its rate: a plan with another rate is refused.
        // A plan that is not a beat plan (a manual skip's) takes the rate back to 1, which the standby can do at any time.
        if plan?.mode == .beat {
            guard (plan?.incomingRate ?? 1) == (transitionPlan?.incomingRate ?? 1) else { return }
        }
        let old = transitionPlan
        var adopted = plan
        // The standby is parked where it really is, which may differ from what was asked.
        adopted?.incomingStartSec = standby.startOffset
        // A seek brought the natural end back for this item: a later plan cannot put the trimmed end back.
        if endRestoredBySeek { adopted?.outgoingEndSec = nil }
        guard adopted != old else { return }
        transitionPlan = adopted
        applyOutgoingEnd()
        let from = active.videoId ?? "-"
        let to = preloadStream?.videoId ?? "-"
        let line = MusicTransitionLog.replanLine(
            from: from, to: to, old: old?.mode, new: adopted?.mode, reason: "crossfadeToggled"
        )
        Self.logger.notice("\(line, privacy: .public)")
        // A scheduled start sees the changed plan on its next evaluation and is planned again.
        evaluateSchedule()
    }

    /// Moves the active item's end to the plan's trimmed end (from the stream's own duration, so never past its natural
    /// end), or back to the natural end when the plan has none. Not when the new end is within a second of now.
    private func applyOutgoingEnd() {
        guard !endRestoredBySeek, let item = active.player.currentItem, let natural = active.naturalEnd else { return }
        if let end = transitionPlan?.outgoingEndSec, end.isFinite {
            let trimmed = min(end, natural)
            let now = active.player.currentTime().seconds
            let floor = (now.isFinite ? now : 0) + 1
            if natural > trimmed && trimmed > floor {
                item.forwardPlaybackEndTime = CMTime(seconds: trimmed, preferredTimescale: 1000)
                endTrimmed = true
                return
            }
        }
        restoreOutgoingEnd()
    }

    /// A listener's seek to or near the trimmed end (within the fade's lead plus a second of it) would end the item at
    /// once, with no fade: the natural end comes back for this item and the transition runs from there.
    private func restoreEndForSeek(to seconds: TimeInterval) {
        guard endTrimmed, !endRestoredBySeek, let plan = transitionPlan, let end = plan.outgoingEndSec, end.isFinite,
              let natural = active.naturalEnd else { return }
        let trimmed = min(end, natural)
        var lead = max(0, plan.fadeSeconds)
        if plan.mode == .smart || plan.mode == .beat, let start = plan.fadeStartSec, start.isFinite { lead = max(lead, trimmed - start) }
        guard seconds >= trimmed - (lead + 1) else { return }
        restoreOutgoingEnd()
        endRestoredBySeek = true
        // The plan says what is real: this item no longer ends at the trimmed end.
        transitionPlan?.outgoingEndSec = nil
    }

    private func restoreOutgoingEnd() {
        guard endTrimmed else { return }
        endTrimmed = false
        guard let item = active.player.currentItem, let natural = active.naturalEnd else { return }
        item.forwardPlaybackEndTime = CMTime(seconds: natural, preferredTimescale: 1000)
    }

    func cancelPreload() {
        alignedStart = false
        guard preloadStream != nil || standby.videoId != nil else { return }
        scheduledHost = nil
        armTask?.cancel()
        armTask = nil
        fadeStartTask?.cancel()
        fadeStartTask = nil
        plannedFade = 0
        plannedLead = 0
        plannedRate = 1
        plannedPlan = nil
        restoreOutgoingEnd()
        endRestoredBySeek = false
        transitionPlan = nil
        requestedStartOffset = 0
        preloadStream = nil
        preloadReady = false
        standby.tearDown()
        standby.player.automaticallyWaitsToMinimizeStalling = false
    }

    private func handleStandbyStatus(_ status: AVPlayerItem.Status, on deck: Deck, token: Int) {
        guard deck === standby, preloadStream != nil else { return }
        switch status {
        case .readyToPlay:
            parkThenPreroll(deck, token: token)
        case .failed:
            // The next track cannot be prepared: the ordinary track change (resolve, load) will have to do.
            cancelPreload()
        case .unknown:
            break
        @unknown default:
            break
        }
    }

    /// A planned incoming offset is seeked to now, with zero tolerance, and only now: the item is ready, so the seek lands
    /// on a buffer that can be read (a remote item that is not cached yet could lose the preload to an earlier seek).
    /// The preroll follows the seek, so the buffers are warm at the offset and the start stays gapless. A seek that does
    /// not land puts the standby back at 0 (the plan's offset is dropped, the reason logged) instead of losing the preload.
    private func parkThenPreroll(_ deck: Deck, token: Int) {
        guard deck.startOffset > 0 else {
            prerollStandby(deck, token: token)
            return
        }
        let target = CMTime(seconds: deck.startOffset, preferredTimescale: 600)
        deck.player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak deck] finished in
            Task { @MainActor [weak self, weak deck] in
                guard let self, let deck, deck === self.standby, deck.token == token, self.preloadStream != nil else { return }
                var landed = finished
                #if DEBUG
                if self.debugFailNextParkSeek {
                    self.debugFailNextParkSeek = false
                    landed = false
                }
                #endif
                if landed {
                    self.prerollStandby(deck, token: token)
                } else {
                    self.dropParkOffset(on: deck, token: token, reason: "seekFailed")
                }
            }
        }
    }

    /// The standby could not be parked at its offset: it starts at 0 and the plan says so.
    private func dropParkOffset(on deck: Deck, token: Int, reason: String) {
        deck.startOffset = 0
        transitionPlan?.incomingStartSec = 0
        let line = MusicTransitionLog.fallbackLine(
            from: active.videoId ?? "-", to: preloadStream?.videoId ?? "-", mode: transitionPlan?.mode, reason: reason
        )
        Self.logger.notice("\(line, privacy: .public)")
        deck.player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak deck] _ in
            Task { @MainActor [weak self, weak deck] in
                guard let self, let deck, deck === self.standby, deck.token == token, self.preloadStream != nil else { return }
                self.prerollStandby(deck, token: token)
            }
        }
    }

    /// Prerolls the standby paused: the buffers and the decoder are warm, so the scheduled start has nothing left to wait
    /// for. It counts as ready only when the preroll finished; one that did not is tried once more, then the preload is
    /// given up (the ordinary track change then plays the next track).
    private func prerollStandby(_ deck: Deck, token: Int) {
        deck.player.preroll(atRate: 1) { [weak self, weak deck] finished in
            Task { @MainActor [weak self, weak deck] in
                guard let self, let deck, deck === self.standby, deck.token == token, self.preloadStream != nil else { return }
                #if DEBUG
                self.onStandbyPrerolled?(finished)
                #endif
                if finished {
                    self.preloadReady = true
                    self.evaluateSchedule()
                } else if !self.prerollRetried {
                    self.prerollRetried = true
                    self.prerollStandby(deck, token: token)
                } else {
                    self.logFallback(reason: "prerollFailed")
                    self.cancelPreload()
                }
            }
        }
    }

    /// One `transition_fallback` line per preload for a plan that could not run as planned.
    private func logFallback(reason: String) {
        guard let plan = transitionPlan, !loggedFallback else { return }
        loggedFallback = true
        let line = MusicTransitionLog.fallbackLine(
            from: active.videoId ?? "-", to: preloadStream?.videoId ?? "-", mode: plan.mode, reason: reason
        )
        Self.logger.notice("\(line, privacy: .public)")
        // A beat plan that ends up as an end-of-item start skips into the next song's mix-in point: say so.
        if plan.mode == .beat {
            let beat = MusicTransitionLog.beatFallbackLine(
                from: active.videoId ?? "-", to: preloadStream?.videoId ?? "-",
                reason: "engine" + reason.prefix(1).uppercased() + reason.dropFirst(), bpmA: nil, bpmB: nil
            )
            Self.logger.notice("\(beat, privacy: .public)")
        }
    }

    // MARK: - Hand-over

    /// The active deck started, stopped, stalled or changed rate: the standby's start follows or is dropped.
    private func activeTransportChanged() {
        let player = active.player
        if player.timeControlStatus == .playing, player.rate == 1 {
            evaluateSchedule()
        } else {
            cancelSchedule()
        }
    }

    /// The end of the active item as an item time, when the item has one that is known.
    private func endTime(of item: AVPlayerItem) -> CMTime? {
        let end = item.forwardPlaybackEndTime
        guard end.isValid, end.isNumeric, end.seconds.isFinite, end.seconds > 0 else { return nil }
        return end
    }

    /// The fade length for a transition planned now: the setting, held to half of each track and to what is left of the
    /// active one. 0 (a gapless switch) when crossfade is off, a deck is not tapped (the fade lives in the tap), the fade
    /// would be shorter than a second, or the tracks are not known well enough to clamp it.
    private func fadeLength(remaining: TimeInterval, end: CMTime) -> TimeInterval {
        guard crossfadeSeconds > 0, chain != nil, active.itemIsTapped, standby.itemIsTapped,
              active.tap?.hasLease == true, standby.tap?.hasLease == true,
              let incoming = preloadStream.flatMap({ Self.knownDuration(of: $0) }) else { return 0 }
        let length = min(crossfadeSeconds, end.seconds / 2, incoming / 2, remaining - Self.fadeGuard)
        return length >= Self.minimumFade ? length : 0
    }

    /// The overlap length and its lead (how long before the active item's end the standby starts) for a transition
    /// planned now. Without a plan this is Tier 1: the fade and the lead are the same. A smart plan starts the fade at its
    /// own `fadeStartSec` (the lead is then longer than the fade); a fixed plan anchors it at the end. Gapless and clean
    /// plans have neither. A plan that cannot fade (no tap or lease on a deck) degrades to the gapless switch.
    private func transitionNumbers(
        remaining: TimeInterval, end: CMTime
    ) -> (fade: TimeInterval, lead: TimeInterval, rate: Float) {
        guard let plan = transitionPlan, !endRestoredBySeek else {
            let fade = fadeLength(remaining: remaining, end: end)
            return (fade, fade, 1)
        }
        guard plan.mode == .smart || plan.mode == .fixed || plan.mode == .beat,
              plan.fadeSeconds >= Self.minimumFade else { return (0, 0, 1) }
        guard chain != nil, active.itemIsTapped, standby.itemIsTapped,
              active.tap?.hasLease == true, standby.tap?.hasLease == true else {
            logFallback(reason: "noLease")
            return (0, 0, 1)
        }
        let fade = min(plan.fadeSeconds, remaining - Self.fadeGuard)
        let isBeat = plan.mode == .beat
        // Too little is left for the plan's fade: the setting's own fade, held to what remains (gapless only when even
        // that is under a second). A beat mix cut short is no longer on the grid, so it runs at rate 1 as a plain fade.
        guard fade >= Self.minimumFade, !isBeat || fade >= plan.fadeSeconds - 0.05 else {
            if isBeat { logFallback(reason: "late") }
            let fixed = fadeLength(remaining: remaining, end: end)
            return (fixed, fixed, 1)
        }
        var lead = fade
        if plan.mode == .smart || isBeat, let start = plan.fadeStartSec, start.isFinite {
            lead = max(fade, end.seconds - start)
        }
        // A smart lead longer than what remains (a plan that came late) starts the overlap as early as it still can.
        // A beat mix is never started early: its start is the grid, so a late plan gives up the rate instead.
        let latest = max(fade, min(lead, remaining - Self.latestLeadMargin))
        if isBeat, latest < lead - 0.05 {
            logFallback(reason: "late")
            let fixed = fadeLength(remaining: remaining, end: end)
            return (fixed, fixed, 1)
        }
        lead = latest
        return (fade, lead, isBeat ? Float(plan.incomingRate) : 1)
    }

    /// Starts the standby on the host time of the active item's end, once that is near, and keeps it there. With a
    /// crossfade the start is `lead` seconds earlier (the fade's length, or longer when a smart plan starts it earlier)
    /// and the fade is started with it.
    private func evaluateSchedule() {
        guard !alignedStart, glide == nil else { return }
        guard preloadStream != nil, preloadReady, draining == nil, let item = active.player.currentItem,
              active.player.timeControlStatus == .playing, active.player.rate == 1,
              let end = endTime(of: item) else { return }
        let remaining = end.seconds - active.player.currentTime().seconds
        guard remaining.isFinite else { return }
        // A fade is planned when the standby is first scheduled and kept; a changed setting plans it again.
        if scheduledHost != nil, plannedFor != crossfadeSeconds || plannedPlan != transitionPlan {
            cancelSchedule()
            return
        }
        let numbers = scheduledHost != nil
            ? (fade: plannedFade, lead: plannedLead, rate: plannedRate)
            : transitionNumbers(remaining: remaining, end: end)
        let fade = numbers.fade
        let lead = numbers.lead
        // The window is counted from the start of the overlap, not from the end.
        if remaining > Self.scheduleWindow + lead {
            cancelSchedule()
            return
        }
        // Too close to move it again: the end notification starts the standby if it has not started yet.
        guard remaining - lead > 0.05 else {
            if scheduledHost == nil, let plan = transitionPlan, plan.mode == .smart || plan.mode == .fixed || plan.mode == .beat, lead > 0 || plan.fadeSeconds > 0 {
                logFallback(reason: "late")
            }
            return
        }
        let endHost = hostTime(ofItemTime: end, in: item, remaining: remaining)
        let host = CMTimeSubtract(endHost, CMTime(seconds: lead, preferredTimescale: 1_000_000_000))
        if let scheduled = scheduledHost, abs(CMTimeSubtract(scheduled, host).seconds) < Self.scheduleTolerance { return }
        plannedFade = fade
        plannedLead = lead
        plannedRate = numbers.rate
        plannedFor = crossfadeSeconds
        plannedPlan = transitionPlan
        schedule(at: host)
    }

    /// The host-clock time at which `itemTime` of the playing item is heard. The item's own timebase says; an answer that
    /// does not agree with the plain estimate (`remaining` seconds from now) is not trusted.
    private func hostTime(ofItemTime itemTime: CMTime, in item: AVPlayerItem, remaining: TimeInterval) -> CMTime {
        let hostClock = CMClockGetHostTimeClock()
        let now = CMClockGetTime(hostClock)
        if let timebase = item.timebase {
            let converted = CMSyncConvertTime(itemTime, from: timebase, to: hostClock)
            if converted.isValid, converted.isNumeric {
                let delta = CMTimeSubtract(converted, now).seconds
                if delta.isFinite, delta > -0.05, abs(delta - remaining) < max(0.5, remaining * 0.3) {
                    return converted
                }
            }
        }
        return CMTimeAdd(now, CMTime(seconds: remaining, preferredTimescale: 1_000_000_000))
    }

    private func schedule(at host: CMTime) {
        standby.player.automaticallyWaitsToMinimizeStalling = false
        // A crossfade's incoming deck is held silent until the fade starts, so its first frames never sound at full level.
        if plannedFade > 0 { standby.tap?.fade(to: 0) }
        // A beat mix starts at its rate, a few milliseconds early: the player's start lands that late (the 3a spike).
        let start = plannedRate == 1
            ? host
            : CMTimeAdd(host, CMTime(seconds: Self.beatCalibrationSec, preferredTimescale: 1_000_000_000))
        standby.player.setRate(plannedRate, time: .invalid, atHostTime: start)
        scheduledHost = host
        armStandbyTap(before: host)
        scheduleCrossfadeStart(at: host)
    }

    // MARK: - Aligned start (the tier 3b seam)

    /// The host-clock time at which the active item's time `seconds` is heard, nil when the active deck is not playing at
    /// rate 1 (then there is no grid to aim at). Built on the same item-timebase conversion the hand-over uses.
    func hostTime(ofActiveItemTime seconds: TimeInterval) -> CMTime? {
        let player = active.player
        guard seconds.isFinite, let item = player.currentItem, player.timeControlStatus == .playing, player.rate == 1
        else { return nil }
        let now = player.currentTime().seconds
        guard now.isFinite, seconds > now else { return nil }
        return hostTime(ofItemTime: CMTime(seconds: seconds, preferredTimescale: 1_000_000), in: item, remaining: seconds - now)
    }

    /// Starts the prerolled standby at host time `host` at `rate` (a nudged rate keeps its pitch through the item's time
    /// pitch algorithm), and arms its tap `armLead` before. This is the beat-matched mix's entry: the caller picks a host
    /// time on the playing deck's beat grid. It sets no crossfade and no `scheduledHost`, so the gapless hand-over's own
    /// schedule is untouched. False (nothing changes) when the preload is not ready, a fade is running, or `host` or
    /// `rate` is unusable.
    @discardableResult
    func startStandby(atHostTime host: CMTime, rate: Float) -> Bool {
        guard preloadStream != nil, preloadReady, draining == nil, scheduledHost == nil, host.isValid, host.isNumeric,
              rate.isFinite, rate > 0 else { return false }
        // AVPlayer raises (not fails) for a synchronized start before the item is ready.
        guard standby.player.status == .readyToPlay else { return false }
        alignedStart = true
        let deck = standby
        let token = deck.token
        deck.player.automaticallyWaitsToMinimizeStalling = false
        deck.player.setRate(rate, time: .invalid, atHostTime: host)
        armTask?.cancel()
        let wait = CMTimeSubtract(host, CMClockGetTime(CMClockGetHostTimeClock())).seconds - Self.armLead
        armTask = Task { @MainActor [weak self, weak deck] in
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard !Task.isCancelled, let self, let deck, deck === self.standby, deck.token == token else { return }
            deck.tap?.arm()
        }
        return true
    }

    /// Fires the crossfade `fadeLead` before the standby's start. Moves with the schedule.
    private func scheduleCrossfadeStart(at host: CMTime) {
        fadeStartTask?.cancel()
        fadeStartTask = nil
        guard plannedFade > 0 else { return }
        let wait = CMTimeSubtract(host, CMClockGetTime(CMClockGetHostTimeClock())).seconds - Self.fadeLead
        fadeStartTask = Task { @MainActor [weak self] in
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard !Task.isCancelled, let self, let scheduled = self.scheduledHost, scheduled == host else { return }
            self.fadeStartTask = nil
            self.beginScheduledCrossfade()
        }
    }

    /// Arms the standby's tap `armLead` seconds before `host`, and not earlier: an armed standby shares the filters with
    /// the owner. A start that is re-scheduled re-arms for its new time; a cancelled one is never armed.
    private func armStandbyTap(before host: CMTime) {
        armTask?.cancel()
        armTask = nil
        let wait = CMTimeSubtract(host, CMClockGetTime(CMClockGetHostTimeClock())).seconds - Self.armLead
        guard wait > 0 else {
            standby.tap?.arm()
            return
        }
        armTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, let self, let scheduled = self.scheduledHost, scheduled == host else { return }
            self.standby.tap?.arm()
        }
    }

    /// Takes the standby's scheduled start back: it is paused, put back at its first frame (it may have started a few
    /// milliseconds already) and warmed up again, and the schedule is set again once that has landed.
    private func cancelSchedule() {
        let wasAligned = alignedStart
        alignedStart = false
        guard scheduledHost != nil || wasAligned else { return }
        scheduledHost = nil
        armTask?.cancel()
        armTask = nil
        fadeStartTask?.cancel()
        fadeStartTask = nil
        if plannedFade > 0 { standby.tap?.fade(to: 1) }
        plannedFade = 0
        plannedLead = 0
        plannedRate = 1
        standby.tap?.disarm()
        let deck = standby
        let token = deck.token
        deck.player.pause()
        guard preloadReady else { return }
        // Back to where the plan parked it (the first frame the listener should hear), not to the item's start.
        let parked = CMTime(seconds: deck.startOffset, preferredTimescale: 600)
        deck.player.seek(to: parked, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak deck] finished in
            Task { @MainActor [weak self, weak deck] in
                guard let self, let deck, deck === self.standby, deck.token == token, self.preloadStream != nil, finished else { return }
                deck.player.preroll(atRate: 1) { [weak self, weak deck] _ in
                    Task { @MainActor [weak self, weak deck] in
                        guard let self, let deck, deck === self.standby, deck.token == token, self.preloadStream != nil else { return }
                        self.evaluateSchedule()
                    }
                }
            }
        }
    }

    /// The active item played to its end. With a ready preload the standby plays on from here, and `advanced` is reported
    /// in place of `ended`; with none (or one that is not ready) it is the ordinary end of playback.
    private func activeItemEnded() {
        guard let stream = preloadStream, preloadReady else {
            cancelPreload()
            wantsPlay = false
            onEvent?(.ended)
            return
        }
        let incoming = standby
        let outgoing = active
        outgoingPositionAtCrossfade = nil
        let hostClock = CMClockGetHostTimeClock()
        let wasAligned = alignedStart
        alignedStart = false
        let untilStart = scheduledHost.map { CMTimeSubtract($0, CMClockGetTime(hostClock)).seconds }
        let glideBack = transitionPlan?.glideBackSec ?? 0
        snapRate(why: "skip")

        // A start that was planned as a crossfade but never fired (its timer lost the race to the end): the end is here,
        // so it is a gapless switch. The incoming deck was held silent for the fade.
        if plannedFade > 0 { incoming.tap?.fade(to: 1) }
        plannedFade = 0
        plannedLead = 0
        plannedRate = 1
        plannedPlan = nil
        fadeStartTask?.cancel()
        fadeStartTask = nil
        if let plan = transitionPlan {
            let line = MusicTransitionLog.appliedLine(
                from: outgoing.videoId ?? "-", to: stream.videoId,
                mode: plan.mode == .smart || plan.mode == .fixed || plan.mode == .beat ? .gapless : plan.mode,
                fade: 0, lead: 0, skipped: 0
            )
            Self.logger.notice("\(line, privacy: .public)")
        }
        transitionPlan = nil
        requestedStartOffset = 0
        endTrimmed = false
        endRestoredBySeek = false

        // The chain changes hands: the new deck's tap owns it, the old one renders nothing more.
        incoming.tap?.activate()
        outgoing.tap?.retire()
        active = incoming
        standby = outgoing
        scheduledHost = nil
        preloadStream = nil
        preloadReady = false

        // The scheduled start is trusted only when it is seen to run: a standby that stalled, lost its start or was touched
        // by an output change is not playing, and a start that is still well ahead (the real audio was shorter than the
        // duration said) is brought forward. Either way start it now.
        let startedOnSchedule = untilStart != nil && incoming.player.rate != 0 && (untilStart ?? 0) < 0.1
        if startedOnSchedule {
            scheduledAdvanceCount += 1
        } else {
            if untilStart != nil { lateStartCount += 1 } else { fallbackAdvanceCount += 1 }
            // An aligned standby is already running at its nudged rate: play() would reset it to 1.
            if !(wasAligned && incoming.player.rate != 0) { incoming.player.play() }
        }
        armTask?.cancel()
        armTask = nil
        // A standby that already runs at a nudged rate (a beat start that lost its fade) glides back like a mix would.
        let runningRate = incoming.player.rate
        if startedOnSchedule, runningRate > 0, abs(runningRate - 1) > 0.0005, glideBack > 0 {
            startGlide(from: runningRate, over: glideBack)
        }
        incoming.player.automaticallyWaitsToMinimizeStalling = true
        outgoing.tearDown()
        outgoing.player.automaticallyWaitsToMinimizeStalling = false
        applyLevel(to: incoming)
        applyLevel(to: outgoing)

        wantsPlay = true
        pendingStart = 0
        onEvent?(.advanced(videoId: stream.videoId))
        onTick?(position, incoming.player.timeControlStatus == .playing)
    }

    // MARK: - Crossfade

    /// The fade is due: the standby is playing (or is started now), and the decks change roles.
    private func beginScheduledCrossfade() {
        guard let stream = preloadStream, preloadReady, plannedFade > 0 else { return }
        // The timer runs on the main actor and may be late: the fade is held to what is really left of the outgoing item.
        var fade = plannedFade
        if let item = active.player.currentItem, let end = endTime(of: item) {
            let left = end.seconds - active.player.currentTime().seconds
            if left.isFinite { fade = min(fade, left - Self.fadeGuard) }
        }
        guard fade >= Self.minimumFade else {
            // Too late for a fade worth hearing: the transition is the gapless one, scheduled again from the end.
            cancelSchedule()
            return
        }
        let started = standby.player.rate != 0
        flip(to: stream, fade: fade, startStandby: !started, scheduled: true)
        onEvent?(.advanced(videoId: stream.videoId))
        onTick?(position, active.player.timeControlStatus == .playing)
    }

    /// A manual skip onto the preloaded track: a short crossfade, started now.
    var canCrossfadeToPreloaded: Bool {
        preloadStream != nil && preloadReady && draining == nil && chain != nil
            && active.itemIsTapped && standby.itemIsTapped
            && active.tap?.hasLease == true && standby.tap?.hasLease == true
    }

    func crossfadeToPreloaded(seconds: TimeInterval) -> Bool {
        guard let stream = preloadStream, canCrossfadeToPreloaded, seconds > 0 else { return false }
        // A scheduled host-time start must not fire again once the standby is started by hand.
        if scheduledHost != nil { standby.player.pause() }
        standby.tap?.fade(to: 0)
        flip(to: stream, fade: seconds, startStandby: true, scheduled: false)
        return true
    }

    /// The decks change roles for a crossfade: the standby is the active deck now and fades in, the old active deck keeps
    /// playing and fades out, and a new empty standby is ready for the next preload.
    ///
    /// With a plan (Tier 2b) the loudness offsets go on here: the incoming deck's attenuation is set before its fade so the
    /// first audible frame is already lowered, and a glide back to 0 dB is left pending for when the outgoing deck has
    /// drained. The outgoing attenuation only applies to a scheduled fade (a manual skip's 0.3 s needs none).
    private func flip(to stream: ResolvedStream, fade: TimeInterval, startStandby: Bool, scheduled: Bool) {
        crossfadeCount += 1
        outgoingPositionAtCrossfade = active.player.currentTime().seconds
        let incoming = standby
        let outgoing = active
        fadeStartTask?.cancel()
        fadeStartTask = nil
        armTask?.cancel()
        armTask = nil
        alignedStart = false
        let plan = transitionPlan
        let outgoingEnd = active.player.currentItem.flatMap { endTime(of: $0) }?.seconds
        // The outgoing deck may still be gliding from an earlier mix: it goes back to 1 for its fade-out.
        snapRate(why: "skip")
        // The incoming deck's rate: a scheduled beat mix keeps its nudge, a manual skip never does.
        var beat: BeatOverlap?
        if scheduled, let plan, plan.mode == .beat, plan.incomingRate != 1, plan.incomingRate.isFinite,
           let mixIn = plan.mixInSec, let mixOut = plan.mixOutSec {
            beat = BeatOverlap(
                rate: Float(plan.incomingRate), mixIn: mixIn, mixOut: mixOut, glideSeconds: max(0, plan.glideBackSec)
            )
        }
        // The outgoing lease drains before the incoming one claims the chain, so it is never silenced in between.
        outgoing.tap?.drain(over: fade)
        pendingGlide = 0
        beatOverlap = nil
        if let plan {
            if let beat {
                let line = MusicTransitionLog.beatAppliedLine(
                    from: outgoing.videoId ?? "-", to: stream.videoId, rate: Double(beat.rate), calibrationSec: Self.beatCalibrationSec
                )
                Self.logger.notice("\(line, privacy: .public)")
            }
            if scheduled, plan.outgoingGainDb < 0 {
                outgoing.tap?.setOffset(to: Self.linearGain(db: plan.outgoingGainDb), over: plan.outgoingRampSeconds)
            }
            if plan.incomingGainDb < 0 {
                incoming.tap?.setOffset(to: Self.linearGain(db: plan.incomingGainDb), over: 0)
                pendingGlide = max(0, plan.incomingGlideSeconds)
            }
            let position = outgoingPositionAtCrossfade ?? 0
            let lead = outgoingEnd.map { max(0, $0 - position) } ?? fade
            let line = MusicTransitionLog.appliedLine(
                from: outgoing.videoId ?? "-", to: stream.videoId, mode: plan.mode, fade: fade, lead: lead,
                skipped: max(0, lead - fade)
            )
            Self.logger.notice("\(line, privacy: .public)")
        }
        incoming.tap?.beginFadeIn()
        incoming.tap?.activate()
        incoming.tap?.fade(to: 1, over: fade, curve: .equalPower, fromSilence: true)
        active = incoming
        draining = outgoing
        let fresh = Deck()
        fresh.player.automaticallyWaitsToMinimizeStalling = false
        fresh.player.audioOutputDeviceUniqueID = outputDeviceUID
        standby = fresh
        scheduledHost = nil
        plannedFade = 0
        plannedLead = 0
        plannedRate = 1
        plannedPlan = nil
        transitionPlan = nil
        requestedStartOffset = 0
        endTrimmed = false
        endRestoredBySeek = false
        preloadStream = nil
        preloadReady = false
        if startStandby {
            // The grid is lost anyway (the start was late), but the nudge and the glide back stay consistent.
            if let beat { incoming.player.rate = beat.rate } else { incoming.player.play() }
        }
        beatOverlap = beat
        incoming.player.automaticallyWaitsToMinimizeStalling = true
        applyLevel(to: incoming)
        applyLevel(to: outgoing)
        wantsPlay = true
        pendingStart = 0
        startDrainTimer(seconds: fade)
    }

    /// Lets the draining deck go once `seconds` of play intent have passed: counted while the engine wants to play, not
    /// while the deck's rate is non-zero (an outgoing item that reaches its end drops its rate to 0 but is still fading),
    /// so a pause holds the fade where it is and the resume goes on from there. The outgoing item running out ends it too.
    private func startDrainTimer(seconds: TimeInterval) {
        drainTask?.cancel()
        let tick = 0.05
        drainTask = Task { @MainActor [weak self] in
            var played = 0.0
            let wanted = seconds + 0.1
            while played < wanted {
                try? await Task.sleep(for: .seconds(tick))
                guard !Task.isCancelled, let self, let draining = self.draining else { return }
                if self.wantsPlay { played += tick }
                if self.hasRunOut(draining.player) { break }
            }
            guard !Task.isCancelled, let self else { return }
            self.finishDrain()
        }
    }

    /// A short fixed wait, whatever the transport does: used to let a fast fade-out finish before the deck goes.
    private func startQuickDrainTimer() {
        drainTask?.cancel()
        drainTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.quickDrain + 0.05))
            guard !Task.isCancelled, let self else { return }
            self.finishDrain()
        }
    }

    /// True when the player has no item or its item has played to its end (the end the engine set, when it set one).
    private func hasRunOut(_ player: AVPlayer) -> Bool {
        guard let item = player.currentItem else { return true }
        let end = endTime(of: item)?.seconds ?? item.duration.seconds
        guard end.isFinite, end > 0 else { return false }
        return item.currentTime().seconds >= end - 0.02
    }

    /// The fade is over: the old deck is torn down and its lease released.
    private func finishDrain() {
        drainTask?.cancel()
        drainTask = nil
        guard let old = draining else { return }
        draining = nil
        old.tearDown()
        old.player.automaticallyWaitsToMinimizeStalling = false
        active.tap?.endOverlap()
        // The incoming deck was held down for a louder song: it glides back to its own level now, in frames, so a pause
        // holds it.
        if pendingGlide > 0 {
            active.tap?.setOffset(to: 1, over: pendingGlide)
            pendingGlide = 0
        }
        // A beat mix is over: the incoming song's rate relaxes back to 1.
        if let beat = beatOverlap {
            beatOverlap = nil
            // The flip turned stalling-wait off for the synchronised start; the deck plays on its own from here.
            active.player.automaticallyWaitsToMinimizeStalling = true
            startGlide(from: beat.rate, over: beat.glideSeconds)
        }
    }

    // MARK: - Rate glide

    /// Brings the active deck's rate from `rate` back to 1 over `seconds` of play intent, in 100 ms smoothstep steps.
    /// The next mix is not scheduled while it runs (the schedule maths assumes rate 1).
    private func startGlide(from rate: Float, over seconds: TimeInterval) {
        glideTask?.cancel()
        glideTask = nil
        guard rate.isFinite, abs(rate - 1) > 0.0005, seconds > 0 else {
            glide = nil
            return
        }
        glide = Glide(from: rate, total: seconds)
        Self.logger.notice("\(MusicTransitionLog.glideLine(event: .start, rate: Double(rate), seconds: seconds), privacy: .public)")
        runGlideTask()
    }

    private func runGlideTask() {
        glideTask?.cancel()
        glideTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.glideTick))
                guard !Task.isCancelled, let self, self.glide != nil else { return }
                self.advanceGlide(by: Self.glideTick)
            }
        }
    }

    /// One glide step. Only play-intent time counts, so a pause holds the glide where it is.
    private func advanceGlide(by seconds: TimeInterval) {
        guard var current = glide, wantsPlay else { return }
        current.elapsed += seconds
        guard current.elapsed < current.total else {
            finishGlide()
            return
        }
        glide = current
        let rate = Self.glideRate(from: current.from, elapsed: current.elapsed, total: current.total)
        // Not a deck that is not playing: setting a rate would start it.
        if active.player.rate != 0 { active.player.rate = rate }
    }

    private func finishGlide() {
        glideTask?.cancel()
        glideTask = nil
        glide = nil
        if active.player.rate != 0 { active.player.rate = 1 }
        Self.logger.notice("\(MusicTransitionLog.glideLine(event: .end, rate: 1, seconds: 0), privacy: .public)")
        // The glide kept the next mix back: look at the schedule again.
        evaluateSchedule()
    }

    /// A seek, a skip, an output change or a new load: the nudged rate (in the overlap or in the glide) goes to 1 at once.
    private func snapRate(why: String) {
        let hadGlide = glide != nil
        let rate = glide.map { Self.glideRate(from: $0.from, elapsed: $0.elapsed, total: $0.total) } ?? active.player.rate
        glideTask?.cancel()
        glideTask = nil
        glide = nil
        beatOverlap = nil
        let nudged = rate.isFinite && abs(rate - 1) > 0.0005
        if active.player.rate != 0, abs(active.player.rate - 1) > 0.0005 { active.player.rate = 1 }
        if hadGlide || (nudged && draining != nil) {
            Self.logger.notice("\(MusicTransitionLog.glideLine(event: .cancel(why: why), rate: Double(rate), seconds: 0), privacy: .public)")
        }
    }

    /// dB to a linear gain (attenuation only: never above 1).
    nonisolated static func linearGain(db: Double) -> Float {
        guard db.isFinite else { return 1 }
        return Float(min(1, max(0, pow(10, min(0, db) / 20))))
    }

    /// Ends a crossfade early (a seek, a skip, a new load): with `fast`, the old deck fades out in about 30 ms first.
    private func endDrain(fast: Bool) {
        guard let old = draining else { return }
        // Cut short: no glide follows, and the incoming deck is not left at its nudged rate.
        beatOverlap = nil
        // A paused deck cannot play its fade-out: it goes at once.
        if fast, wantsPlay, old.player.rate != 0 {
            old.tap?.drain(over: Self.quickDrain, curve: .linear)
            startQuickDrainTimer()
        } else {
            finishDrain()
        }
    }
}
