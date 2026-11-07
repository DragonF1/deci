// Deci/Music/MusicSongDataStore.swift
import Foundation
import Observation
import os

private let logger = Logger(subsystem: "com.abraham.Deci", category: "MusicSongData")

/// The state of the Song data panel: the one song it is open for, the stream facts for it and its stored analysis row.
/// `MusicService` owns one (`service.songData`). The state lives here, not in the view, because the popover panel hides
/// whenever it loses focus.
///
/// The song's stream comes from the service when the player holds it (the song that plays, or the one prefetched next),
/// so the panel opens at once and asks nothing. Any other song is resolved through the backend for its metadata only:
/// the stream URL is never played or fetched. While the network is down the panel says Offline, and any other failure
/// says Unavailable. Opening for another song, closing, or a reset cancels what is out, and a late answer lands nowhere.
/// The analysis row is read from the stored one; a song with no row has none. Nothing here logs a song or an id, only
/// error kinds.
///
/// The music data (tempo, key, feel, genres) comes from the song facts cache, or, on a miss, from the online chain (which
/// stores what it learns). What no service said is measured here when the song has a stream to measure from: the 2a analysis
/// when the song has no stored row, and the tempo from the beat finder. One measurement runs at a time, and a switch or a
/// close cancels it. Later tiers add their own sources beside these (the listener's own stats).
@MainActor
@Observable
final class MusicSongDataStore {
    /// What the store reads from the service. The service sets it once it is built.
    struct Sources {
        /// The stream the player holds for a song, if it does.
        var heldStream: @MainActor (String) -> ResolvedStream?
        /// The stored analysis row of a song.
        var analysis: @MainActor (String) async -> MusicAnalysis?
        /// The network is gone.
        var isOffline: @MainActor () -> Bool
        /// The account is signed out.
        var isSignedOut: @MainActor () -> Bool = { false }
        /// What the song facts cache holds for a song; reads no network.
        var cachedFacts: @MainActor (String) async -> MusicSongFactsCached? = { _ in nil }
        /// Asks the online services about a song and stores the answer. Nil: there is no facts side, and the panel
        /// neither looks up nor measures.
        var lookupFacts: (@MainActor (MusicTrack) async -> Void)?
        /// Analyses the song (when `needAnalysis`) and measures its tempo (when `needBPM`) from its stream. Nil: none.
        var measure: (@MainActor (ResolvedStream, _ needAnalysis: Bool, _ needBPM: Bool) async -> MusicSongMeasureResult)?
        /// The listener's own plays of a song, from the local listening store.
        var listening: @MainActor (String) async -> MusicListeningEntry? = { _ in nil }
    }

    /// The song the panel is open for; nil while it is closed.
    private(set) var track: MusicTrack?
    private(set) var stream: MusicSongDataStreamState = .loading
    private(set) var analysis: MusicAnalysis?
    /// The song's music data and whether it is still being looked up or measured.
    private(set) var music = MusicSongDataMusicState()
    private(set) var listening: MusicListeningEntry?

    var isOpen: Bool { track != nil }

    /// The panel header's quiet text beside its title: the song's title, nil when closed or blank.
    var subtitle: String? {
        guard let title = track?.title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return title
    }

    /// Told when a call says the session is gone, so the service can sign out.
    @ObservationIgnored var onSessionExpired: (@MainActor () -> Void)?
    @ObservationIgnored var sources: Sources?

    @ObservationIgnored private let backend: any MusicBackend
    /// Each open names itself with the next number and lands only while it is still the current one.
    @ObservationIgnored private var runCounter = 0
    @ObservationIgnored private var streamTask: Task<Void, Never>?
    @ObservationIgnored private var analysisTask: Task<Void, Never>?
    @ObservationIgnored private var factsTask: Task<Void, Never>?
    @ObservationIgnored private var measureTask: Task<Void, Never>?
    /// The measurement of the song left behind, which a new one waits for: one manual run at a time.
    @ObservationIgnored private var lastMeasure: Task<Void, Never>?
    /// What this open has settled so far; measuring starts once the stream, the stored row and the lookup are all in.
    @ObservationIgnored private var analysisRead = false
    @ObservationIgnored private var lookupDone = false
    @ObservationIgnored private var lookupSkippedOffline = false
    @ObservationIgnored private var measureAttempted = false
    /// The last measurement of this song failed less than a day ago, so it is not downloaded again yet.
    @ObservationIgnored private var measureFailedRecently = false
    @ObservationIgnored private var measureStarted = false

    init(backend: any MusicBackend) {
        self.backend = backend
    }

    // MARK: - Opening and closing

    /// The panel is for `track` from here on: opened, or swapped from another song.
    func show(_ track: MusicTrack) {
        let run = newRun()
        self.track = track
        analysis = nil
        music = MusicSongDataMusicState(lookingUp: true)
        listening = nil
        let id = track.videoId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else {
            stream = .unavailable
            music = MusicSongDataMusicState()
            return
        }
        loadAnalysis(id: id, run: run)
        loadFacts(track, id: id, run: run)
        loadListening(id: id, run: run)
        if let held = sources?.heldStream(id) {
            stream = .loaded(held)
        } else {
            loadStream(id: id, run: run)
        }
    }

    /// The network came back: a song that said Offline is asked for again, once.
    func connectionReturned() {
        guard let track, sources?.isOffline() != true else { return }
        let id = track.videoId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        var restarted = false
        if lookupSkippedOffline {
            lookupSkippedOffline = false
            music.lookingUp = true
            // The measuring waits for this lookup, not for the facts of before.
            lookupDone = false
            loadFacts(track, id: id, run: runCounter)
            restarted = true
        }
        if stream == .offline {
            loadStream(id: id, run: runCounter)
            restarted = true
        }
        // The stream loaded and the facts were fresh, so only the measuring was held back by the network.
        if !restarted, music.problem == .offline { advance(run: runCounter) }
    }

    /// The panel closed: what is out lands nowhere.
    func close() {
        _ = newRun()
        track = nil
        analysis = nil
        music = MusicSongDataMusicState()
        listening = nil
        stream = .loading
    }

    /// Sign-out or an account swap: nothing of the old session stays.
    func reset() {
        close()
    }

    // MARK: - Loading

    private func newRun() -> Int {
        runCounter += 1
        streamTask?.cancel()
        streamTask = nil
        analysisTask?.cancel()
        analysisTask = nil
        factsTask?.cancel()
        factsTask = nil
        if let running = measureTask { lastMeasure = running }
        measureTask?.cancel()
        measureTask = nil
        analysisRead = false
        lookupDone = false
        lookupSkippedOffline = false
        measureAttempted = false
        measureFailedRecently = false
        measureStarted = false
        return runCounter
    }

    private func isCurrent(_ run: Int) -> Bool {
        run == runCounter && !Task.isCancelled
    }

    private func loadStream(id: String, run: Int) {
        if sources?.isOffline() == true {
            stream = .offline
            return
        }
        stream = .loading
        streamTask?.cancel()
        streamTask = Task { [weak self, backend] in
            do {
                let resolved = try await backend.resolve(videoId: id)
                self?.land(resolved, run: run)
            } catch is CancellationError {
                // Whoever cancelled has already set the state.
            } catch {
                self?.fail(error, run: run)
            }
        }
    }

    private func loadAnalysis(id: String, run: Int) {
        guard let read = sources?.analysis else { return }
        analysisTask = Task { [weak self] in
            let row = await read(id)
            guard let self, !Task.isCancelled, run == self.runCounter else { return }
            self.analysis = row
            self.analysisRead = true
            self.advance(run: run)
        }
    }

    /// The facts of the song: the cache when it can answer, else the services (stored by the lookup), else what is stored.
    private func loadFacts(_ track: MusicTrack, id: String, run: Int) {
        guard let sources, let lookup = sources.lookupFacts else {
            music.lookingUp = false
            lookupDone = true
            return
        }
        factsTask?.cancel()
        factsTask = Task { [weak self] in
            var cached = await sources.cachedFacts(id)
            guard let self, self.isCurrent(run) else { return }
            if cached?.lookupIsFresh != true {
                if sources.isOffline() {
                    self.lookupSkippedOffline = true
                } else {
                    await lookup(track)
                    guard self.isCurrent(run) else { return }
                    cached = await sources.cachedFacts(id)
                    guard self.isCurrent(run) else { return }
                }
            }
            self.music.facts = cached?.facts
            self.music.lookingUp = false
            self.measureFailedRecently = cached?.measureFailedRecently ?? false
            self.measureAttempted = (cached?.measureAttempted ?? false) || self.measureFailedRecently
            self.lookupDone = true
            self.factsTask = nil
            self.advance(run: run)
        }
    }

    /// Starts the measuring once everything it depends on is settled, when something is still missing: no analysis row, or
    /// no tempo from any service. A stream that cannot be had says why, quietly, instead.
    private func advance(run: Int) {
        guard run == runCounter, track != nil, let sources, let measure = sources.measure,
              lookupDone, analysisRead, !measureStarted else { return }
        let needAnalysis = analysis == nil && !measureFailedRecently
        let needBPM = music.facts?.bpm == nil && !measureAttempted
        guard needAnalysis || needBPM else { return }
        let held: ResolvedStream
        switch stream {
        case .loading:
            return
        case .offline:
            music.problem = .offline
            return
        case .unavailable:
            music.problem = sources.isSignedOut() ? .signedOut : .failed
            return
        case .loaded(let loaded):
            held = loaded
        }
        // A file on this Mac needs no network; anything else does.
        if !held.url.isFileURL {
            if sources.isOffline() { music.problem = .offline; return }
            if sources.isSignedOut() { music.problem = .signedOut; return }
        }
        measureStarted = true
        music.problem = nil
        music.measuringAnalysis = needAnalysis
        music.measuringTempo = needBPM
        let previous = lastMeasure
        let id = held.videoId
        measureTask = Task { [weak self] in
            await previous?.value
            guard let self, self.isCurrent(run) else { return }
            let result = await measure(held, needAnalysis, needBPM)
            guard self.isCurrent(run) else { return }
            let cached = await sources.cachedFacts(id)
            let row = needAnalysis ? await sources.analysis(id) : nil
            guard self.isCurrent(run) else { return }
            // A cache read that failed leaves the facts that are shown.
            if let facts = cached?.facts { self.music.facts = facts }
            if needAnalysis { self.analysis = row }
            self.music.measuringAnalysis = false
            self.music.measuringTempo = false
            switch result.problem {
            case .rateLimited?: self.music.problem = .rateLimited
            case .failed?: self.music.problem = .failed
            case nil: self.music.problem = nil
            }
            self.measureTask = nil
            self.lastMeasure = nil
        }
    }

    private func loadListening(id: String, run: Int) {
        guard let read = sources?.listening else { return }
        Task { [weak self] in
            let row = await read(id)
            guard let self, run == self.runCounter else { return }
            self.listening = row
        }
    }

    private func land(_ resolved: ResolvedStream, run: Int) {
        guard run == runCounter else { return }
        streamTask = nil
        stream = .loaded(resolved)
        advance(run: run)
    }

    private func fail(_ error: any Error, run: Int) {
        guard run == runCounter else { return }
        streamTask = nil
        logger.error("song data failed: \(MusicService.logDescription(of: error), privacy: .public)")
        if error is URLError {
            stream = .offline
        } else {
            stream = .unavailable
        }
        if (error as? MusicError) == .signedOut { onSessionExpired?() }
        advance(run: run)
    }
}
