// Deci/Music/MusicService.swift
import Foundation
import Observation
import os

private let logger = Logger(subsystem: "com.abraham.Deci", category: "Music")

/// Sign-in, search and playback for the Music tab. Everything network-facing goes through `MusicBackend`.
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

    /// One playback session: one CPN, one listening-time count, at most one history ping.
    private struct Session {
        let cpn: String
        var trackingURL: URL?
        var accumulator = PlaybackTimeAccumulator()
    }

    @ObservationIgnored private let backend: any MusicBackend
    @ObservationIgnored private let presentSignIn: SignInPresenter
    @ObservationIgnored private var session: Session?

    @ObservationIgnored private(set) var searchTask: Task<Void, Never>?
    @ObservationIgnored private(set) var playTask: Task<Void, Never>?
    @ObservationIgnored private(set) var signInTask: Task<Void, Never>?
    @ObservationIgnored private(set) var reportTask: Task<Void, Never>?
    @ObservationIgnored private(set) var signOutTask: Task<Void, Never>?
    @ObservationIgnored private var searchGeneration = 0
    @ObservationIgnored private var playGeneration = 0
    #if DEBUG
    @ObservationIgnored private var memoryProbe: Task<Void, Never>?
    #endif

    init(
        backend: any MusicBackend,
        player: MusicPlayer = MusicPlayer(),
        presentSignIn: @escaping SignInPresenter = { MusicSignInWindowController.present(completion: $0) },
        refreshOnCreate: Bool = true
    ) {
        self.backend = backend
        self.player = player
        self.presentSignIn = presentSignIn
        player.onTick = { [weak self] position, isPlaying in
            self?.handlePlaybackTick(position: position, isPlaying: isPlaying)
        }
        player.onNeedsFreshStream = { [weak self] track in
            guard let self else { throw CancellationError() }
            return try await self.resolveFreshStream(for: track)
        }
        if refreshOnCreate {
            Task { [weak self] in await self?.refreshAuth() }
        }
    }

    isolated deinit {
        searchTask?.cancel()
        playTask?.cancel()
        signInTask?.cancel()
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

    func play(_ track: MusicTrack) {
        playTask?.cancel()
        playGeneration += 1
        let generation = playGeneration
        lastError = nil
        session = nil
        player.beginLoading(track)
        playTask = Task { [weak self] in
            await self?.resolveAndLoad(track, generation: generation)
        }
    }

    private func resolveAndLoad(_ track: MusicTrack, generation: Int) async {
        do {
            let stream = try await backend.resolve(videoId: track.videoId)
            guard generation == playGeneration, !Task.isCancelled else { return }
            session = Session(cpn: CPN.make(), trackingURL: stream.playbackTrackingURL)
            player.load(stream: stream, track: track)
            scheduleMemoryProbe()
        } catch {
            guard generation == playGeneration else { return }
            player.stop()
            handle(error)
        }
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

    // MARK: - History

    /// Fed by the player every 0.5 s. Pings YouTube's history once after 30 s of real listening.
    func handlePlaybackTick(position: TimeInterval, isPlaying: Bool) {
        guard session != nil else { return }
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
