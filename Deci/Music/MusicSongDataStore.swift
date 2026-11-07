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
/// error kinds. Later tiers add their own sources beside these two (outside metadata, an on-demand analysis, the
/// listener's own stats).
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
        /// The listener's own plays of a song, from the local listening store.
        var listening: @MainActor (String) async -> MusicListeningEntry? = { _ in nil }
    }

    /// The song the panel is open for; nil while it is closed.
    private(set) var track: MusicTrack?
    private(set) var stream: MusicSongDataStreamState = .loading
    private(set) var analysis: MusicAnalysis?
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

    init(backend: any MusicBackend) {
        self.backend = backend
    }

    // MARK: - Opening and closing

    /// The panel is for `track` from here on: opened, or swapped from another song.
    func show(_ track: MusicTrack) {
        let run = newRun()
        self.track = track
        analysis = nil
        listening = nil
        let id = track.videoId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else {
            stream = .unavailable
            return
        }
        loadAnalysis(id: id, run: run)
        loadListening(id: id, run: run)
        if let held = sources?.heldStream(id) {
            stream = .loaded(held)
        } else {
            loadStream(id: id, run: run)
        }
    }

    /// The network came back: a song that said Offline is asked for again, once.
    func connectionReturned() {
        guard let track, stream == .offline, sources?.isOffline() != true else { return }
        let id = track.videoId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        loadStream(id: id, run: runCounter)
    }

    /// The panel closed: what is out lands nowhere.
    func close() {
        _ = newRun()
        track = nil
        analysis = nil
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
        return runCounter
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
    }
}
