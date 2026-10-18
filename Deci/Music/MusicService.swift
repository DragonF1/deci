// Deci/Music/MusicService.swift
import Foundation
import Observation
import os

private let logger = Logger(subsystem: "com.abraham.Deci", category: "Music")

/// Sign-in, search, the radio queue and playback for the Music tab. Everything network-facing goes through `MusicBackend`.
@MainActor
@Observable
final class MusicService {
    enum AuthState: Equatable {
        case unknown, signedOut, signingIn, signedIn
    }

    /// Opens the sign-in UI and reports the harvested cookies, or nil when the user closed it.
    typealias SignInPresenter = @MainActor (_ completion: @escaping @MainActor ([StoredCookie]?) -> Void) -> Void

    private(set) var authState: AuthState = .unknown
    var query = ""
    private(set) var results: [MusicTrack] = []
    private(set) var isSearching = false
    /// One short human line for the UI; never contains cookies or URLs.
    private(set) var lastError: String?
    let player: MusicPlayer
    /// What plays next: the tapped track, then the radio's tracks as they arrive.
    private(set) var queue = MusicQueue()
    var canGoNext: Bool { queue.hasNext }
    /// Told whenever Deci's own player starts or stops playing (not on every state change).
    @ObservationIgnored var onNativePlayingChange: (@MainActor (Bool) -> Void)?

    /// One playback session: one CPN, one listening-time count, at most one history ping.
    private struct Session {
        let cpn: String
        var trackingURL: URL?
        var accumulator = PlaybackTimeAccumulator()
    }

    private enum Direction { case forward, backward }

    /// Previous restarts the track instead of going back once it has played this long.
    private static let restartThreshold: TimeInterval = 3
    /// Consecutive tracks that may fail before playback stops with an error.
    private static let maxFailures = 3
    /// The next track's stream is resolved this long before the current one ends.
    private static let prefetchLead: TimeInterval = 15

    @ObservationIgnored private let backend: any MusicBackend
    @ObservationIgnored private let presentSignIn: SignInPresenter
    @ObservationIgnored private let nowPlaying: NowPlayingController
    @ObservationIgnored private var session: Session?
    @ObservationIgnored private var direction = Direction.forward
    @ObservationIgnored private var failureStreak = 0
    @ObservationIgnored private var nativePlaying = false
    @ObservationIgnored private var radioGeneration = 0
    @ObservationIgnored private var prefetchAttempt: String?
    @ObservationIgnored private var prefetched: ResolvedStream?

    @ObservationIgnored private(set) var searchTask: Task<Void, Never>?
    @ObservationIgnored private(set) var playTask: Task<Void, Never>?
    @ObservationIgnored private(set) var signInTask: Task<Void, Never>?
    @ObservationIgnored private(set) var reportTask: Task<Void, Never>?
    @ObservationIgnored private(set) var signOutTask: Task<Void, Never>?
    /// The radio fetch in flight (first page or a continuation); nil when none is running.
    @ObservationIgnored private(set) var radioTask: Task<Void, Never>?
    @ObservationIgnored private(set) var prefetchTask: Task<Void, Never>?
    @ObservationIgnored private var searchGeneration = 0
    @ObservationIgnored private var playGeneration = 0
    #if DEBUG
    @ObservationIgnored private var memoryProbe: Task<Void, Never>?
    #endif

    init(
        backend: any MusicBackend,
        player: MusicPlayer = MusicPlayer(),
        presentSignIn: @escaping SignInPresenter = { MusicSignInWindowController.present(completion: $0) },
        nowPlaying: NowPlayingController = NowPlayingController(),
        refreshOnCreate: Bool = true
    ) {
        self.backend = backend
        self.player = player
        self.presentSignIn = presentSignIn
        self.nowPlaying = nowPlaying
        player.onTick = { [weak self] position, isPlaying in
            self?.handlePlaybackTick(position: position, isPlaying: isPlaying)
        }
        player.onNeedsFreshStream = { [weak self] track in
            guard let self else { throw CancellationError() }
            return try await self.resolveFreshStream(for: track)
        }
        player.onEnded = { [weak self] in self?.handleTrackEnded() }
        player.onFailed = { [weak self] in self?.handlePlayerFailure() }
        player.onStateChange = { [weak self] in self?.playerStateChanged() }
        nowPlaying.onCommand = { [weak self] command in self?.handleRemote(command) }
        if refreshOnCreate {
            Task { [weak self] in await self?.refreshAuth() }
        }
    }

    isolated deinit {
        searchTask?.cancel()
        playTask?.cancel()
        signInTask?.cancel()
        radioTask?.cancel()
        prefetchTask?.cancel()
        #if DEBUG
        memoryProbe?.cancel()
        #endif
    }

    // MARK: - Auth

    func refreshAuth() async {
        let signedIn = await backend.isSignedIn()
        guard authState != .signingIn else { return }
        authState = signedIn ? .signedIn : .signedOut
    }

    func signIn() {
        guard authState != .signingIn else { return }
        authState = .signingIn
        lastError = nil
        presentSignIn { [weak self] cookies in
            self?.finishSignIn(with: cookies)
        }
    }

    private func finishSignIn(with cookies: [StoredCookie]?) {
        guard let cookies, !cookies.isEmpty else {
            authState = .signedOut
            return
        }
        signInTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.backend.signIn(with: cookies)
                self.authState = .signedIn
            } catch {
                logger.error("sign-in failed: \(Self.logDescription(of: error), privacy: .public)")
                self.authState = .signedOut
                self.lastError = Self.message(for: error)
            }
        }
    }

    func signOut() {
        cancelWork()
        endQueue()
        player.stop()
        session = nil
        results = []
        query = ""
        lastError = nil
        authState = .signedOut
        signOutTask = Task { [backend] in await backend.signOut() }
    }

    /// Stops playback and pending work. Called when the app quits.
    func stop() {
        cancelWork()
        endQueue()
        player.stop()
        session = nil
    }

    private func cancelWork() {
        searchGeneration += 1
        playGeneration += 1
        searchTask?.cancel()
        playTask?.cancel()
        searchTask = nil
        playTask = nil
        isSearching = false
        #if DEBUG
        memoryProbe?.cancel()
        #endif
    }

    // MARK: - Search

    /// Submit-on-Return search. A newer search replaces the one in flight.
    func search() {
        searchTask?.cancel()
        searchGeneration += 1
        let generation = searchGeneration
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            isSearching = false
            searchTask = nil
            return
        }
        isSearching = true
        lastError = nil
        searchTask = Task { [weak self] in
            await self?.runSearch(trimmed, generation: generation)
        }
    }

    private func runSearch(_ term: String, generation: Int) async {
        do {
            let found = try await backend.search(term)
            guard generation == searchGeneration, !Task.isCancelled else { return }
            results = found
            isSearching = false
            MusicMemoryLog.log("search")
        } catch {
            guard generation == searchGeneration else { return }
            isSearching = false
            handle(error)
        }
    }

    // MARK: - Playback

    /// Plays a tapped track and starts a radio queue behind it.
    func play(_ track: MusicTrack) {
        queue.start(with: track)
        direction = .forward
        failureStreak = 0
        startRadio(seed: track.videoId)
        begin(track)
    }

    func next() {
        direction = .forward
        failureStreak = 0
        guard let track = queue.advance() else {
            stopPlayback()
            return
        }
        begin(track)
    }

    /// Restarts the track once it has played a few seconds (or when it is the first); otherwise goes back one.
    func previous() {
        guard player.nowPlaying != nil else { return }
        if player.currentTime > Self.restartThreshold || !queue.hasPrevious {
            // A track that ended replays through play(), which also rewinds it.
            if player.hasEnded { player.play() } else { seek(to: 0) }
            return
        }
        direction = .backward
        failureStreak = 0
        guard let track = queue.retreat() else { return }
        begin(track)
    }

    /// Plays a track that is already in the queue.
    func jump(to track: MusicTrack) {
        guard let target = queue.jump(to: track.videoId) else { return }
        direction = .forward
        failureStreak = 0
        begin(target)
    }

    func seek(to seconds: TimeInterval) {
        guard player.nowPlaying != nil else { return }
        player.seek(to: seconds)
        // The jump is not listening time, however short: restart the count from where it landed.
        _ = session?.accumulator.record(position: player.currentTime, isPlaying: false, canFire: false)
    }

    /// Starts one queue item as its own playback session.
    private func begin(_ track: MusicTrack) {
        playTask?.cancel()
        playGeneration += 1
        let generation = playGeneration
        cancelPrefetch()
        lastError = nil
        session = nil
        player.beginLoading(track)
        playTask = Task { [weak self] in
            await self?.resolveAndLoad(track, generation: generation)
        }
        topUpQueue()
    }

    private func resolveAndLoad(_ track: MusicTrack, generation: Int) async {
        do {
            let stream = try await streamForPlayback(of: track)
            guard generation == playGeneration, !Task.isCancelled else { return }
            session = Session(cpn: CPN.make(), trackingURL: stream.playbackTrackingURL)
            player.load(stream: stream, track: track)
            scheduleMemoryProbe()
        } catch {
            guard generation == playGeneration else { return }
            handleResolveFailure(error)
        }
    }

    /// The stream resolved ahead of time when it is still good, otherwise a fresh one.
    private func streamForPlayback(of track: MusicTrack) async throws -> ResolvedStream {
        if let ready = prefetched, ready.videoId == track.videoId, ready.expiresAt > Date().addingTimeInterval(60) {
            prefetched = nil
            return ready
        }
        return try await backend.resolve(videoId: track.videoId)
    }

    /// Used by the player to replace a dead or expired stream. The playback session carries on.
    private func resolveFreshStream(for track: MusicTrack) async throws -> ResolvedStream {
        do {
            let stream = try await backend.resolve(videoId: track.videoId)
            if session?.trackingURL == nil, let url = stream.playbackTrackingURL {
                session?.trackingURL = url
                // The 30 s may have passed while there was nowhere to send the ping.
                if session?.accumulator.claim() == true, let cpn = session?.cpn { reportHistory(url: url, cpn: cpn) }
            }
            return stream
        } catch {
            handle(error)
            throw error
        }
    }

    // MARK: - Queue

    private func handleTrackEnded() {
        direction = .forward
        // At the end of the queue the player stays on the finished track, as with a single song.
        guard let track = queue.advance() else { return }
        begin(track)
    }

    /// A track that cannot be resolved is skipped; the third failure in a row stops playback.
    private func handleResolveFailure(_ error: any Error) {
        if Self.isCancellation(error) || Self.isSignedOut(error) {
            player.stop()
            if Self.isSignedOut(error) { endQueue() }
            handle(error)
            return
        }
        failureStreak += 1
        logger.error("track skipped: \(Self.logDescription(of: error), privacy: .public)")
        if skipToNeighbour() { return }
        player.stop()
        endQueue()
        handle(error)
    }

    /// The player gave up on the current stream (recovery failed or was already spent).
    private func handlePlayerFailure() {
        guard player.nowPlaying != nil else { return }
        if authState == .signedOut {
            player.stop()
            endQueue()
            return
        }
        failureStreak += 1
        if skipToNeighbour() { return }
        // Nothing left to skip to: the failure stays on the player, as it did for a single song.
        endQueue()
    }

    /// Moves past a failed track in the direction the listener was going. False when it cannot.
    private func skipToNeighbour() -> Bool {
        guard failureStreak < Self.maxFailures else { return false }
        guard let neighbour = direction == .forward ? queue.advance() : queue.retreat() else { return false }
        begin(neighbour)
        return true
    }

    private func stopPlayback() {
        playTask?.cancel()
        playGeneration += 1
        playTask = nil
        endQueue()
        player.stop()
        session = nil
    }

    private func endQueue() {
        cancelRadio()
        cancelPrefetch()
        prefetched = nil
        queue.clear()
    }

    // MARK: - Radio

    private func startRadio(seed: String) {
        cancelRadio()
        let generation = radioGeneration
        radioTask = Task { [weak self] in
            await self?.fetchRadioPage(seed: seed, continuation: nil, generation: generation)
        }
    }

    /// Asks for the next page when the queue is running low. One fetch at a time.
    private func topUpQueue() {
        guard radioTask == nil, queue.needsMore, let seed = queue.seedVideoId, let continuation = queue.continuation else { return }
        let generation = radioGeneration
        radioTask = Task { [weak self] in
            await self?.fetchRadioPage(seed: seed, continuation: continuation, generation: generation)
        }
    }

    private func fetchRadioPage(seed: String, continuation: String?, generation: Int) async {
        let page: MusicQueuePage
        do {
            if let continuation {
                page = try await backend.moreRadio(seedVideoId: seed, continuation: continuation)
            } else {
                page = try await backend.radio(seedVideoId: seed)
            }
        } catch {
            // No radio is not an error: the song keeps playing, the queue just does not grow.
            guard generation == radioGeneration else { return }
            radioTask = nil
            logger.info("radio unavailable: \(Self.logDescription(of: error), privacy: .public)")
            return
        }
        guard generation == radioGeneration, !Task.isCancelled else { return }
        radioTask = nil
        // A page of repeats adds nothing; asking again right away could loop, so wait for the next track change.
        if queue.append(page.tracks, continuation: page.continuation) > 0 { topUpQueue() }
    }

    private func cancelRadio() {
        radioGeneration += 1
        radioTask?.cancel()
        radioTask = nil
    }

    // MARK: - Prefetch

    private func prefetchNextIfNeeded(position: TimeInterval) {
        let duration = player.duration
        guard duration > Self.prefetchLead * 2, duration - position <= Self.prefetchLead,
              let next = queue.upcoming.first, prefetchAttempt != next.videoId else { return }
        prefetchAttempt = next.videoId
        prefetchTask = Task { [weak self, backend] in
            guard let stream = try? await backend.resolve(videoId: next.videoId) else { return }
            guard let self, !Task.isCancelled, self.prefetchAttempt == next.videoId else { return }
            self.prefetched = stream
        }
    }

    private func cancelPrefetch() {
        prefetchTask?.cancel()
        prefetchTask = nil
        prefetchAttempt = nil
    }

    // MARK: - Player state, Now Playing and media keys

    private func playerStateChanged() {
        if player.isPlaying { failureStreak = 0 }
        let active = player.isActive
        if active != nativePlaying {
            nativePlaying = active
            onNativePlayingChange?(active)
        }
        syncNowPlaying()
    }

    private func syncNowPlaying() {
        guard let track = player.nowPlaying, !player.hasEnded else {
            nowPlaying.update(nil)
            return
        }
        nowPlaying.update(NowPlayingState(
            track: track,
            elapsed: player.currentTime,
            duration: player.duration,
            isPlaying: player.isPlaying
        ))
    }

    private func handleRemote(_ command: NowPlayingCommand) {
        switch command {
        case .play: player.play()
        case .pause: player.pause()
        case .toggle: player.toggle()
        case .next: next()
        case .previous: previous()
        case .seek(let seconds): seek(to: seconds)
        }
    }

    // MARK: - History

    /// Fed by the player every 0.5 s. Pings YouTube's history once after 30 s of real listening.
    func handlePlaybackTick(position: TimeInterval, isPlaying: Bool) {
        guard session != nil else { return }
        if isPlaying { prefetchNextIfNeeded(position: position) }
        let url = session?.trackingURL
        guard session?.accumulator.record(position: position, isPlaying: isPlaying, canFire: url != nil) == true,
              let url, let cpn = session?.cpn else { return }
        reportHistory(url: url, cpn: cpn)
    }

    private func reportHistory(url: URL, cpn: String) {
        reportTask = Task { [backend] in
            do {
                try await backend.reportPlayback(trackingURL: url, cpn: cpn)
                logger.info("history ping sent")
            } catch {
                logger.error("history ping failed: \(Self.logDescription(of: error), privacy: .public)")
            }
        }
    }

    private func scheduleMemoryProbe() {
        #if DEBUG
        memoryProbe?.cancel()
        memoryProbe = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            MusicMemoryLog.log("playing")
        }
        #endif
    }

    // MARK: - Errors

    private func handle(_ error: any Error) {
        guard !Self.isCancellation(error) else { return }
        if let musicError = error as? MusicError, case .signedOut = musicError {
            // The session is dead: forget its cookies so the next launch does not start from them.
            authState = .signedOut
            lastError = nil
            signOutTask = Task { [backend] in await backend.signOut() }
            return
        }
        logger.error("music request failed: \(Self.logDescription(of: error), privacy: .public)")
        lastError = Self.message(for: error)
    }

    private static func isCancellation(_ error: any Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    private static func isSignedOut(_ error: any Error) -> Bool {
        (error as? MusicError) == .signedOut
    }

    /// The short line shown in the UI.
    static func message(for error: any Error) -> String {
        if let musicError = error as? MusicError {
            switch musicError {
            case .signedOut:
                return "Signed out. Sign in again."
            case .http(let status):
                return "YouTube Music returned an error (\(status))."
            case .parse:
                return "Couldn't read YouTube Music's response."
            case .unplayable(let reason):
                let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? "This track can't be played." : String(trimmed.prefix(80))
            case .noAudioFormat:
                return "No audio stream for this track."
            case .solver:
                return "Couldn't prepare the stream. Try again."
            }
        }
        if error is URLError {
            return "Network problem. Check your connection."
        }
        return "Something went wrong. Try again."
    }

    /// Safe for logs: error kind and status only, never a URL, cookie or response text.
    static func logDescription(of error: any Error) -> String {
        if let musicError = error as? MusicError {
            switch musicError {
            case .signedOut: return "signedOut"
            case .http(let status): return "http \(status)"
            case .parse: return "parse"
            case .unplayable: return "unplayable"
            case .noAudioFormat: return "noAudioFormat"
            case .solver: return "solver"
            }
        }
        let nsError = error as NSError
        return "\(nsError.domain) \(nsError.code)"
    }
}
