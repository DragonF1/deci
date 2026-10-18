// Deci/Music/MusicServiceHost.swift
import Observation

/// Created at app launch; builds the real `MusicService` (AVPlayer, backend, JavaScriptCore) only
/// when the Music tab is first opened, so users who never open it pay nothing.
@MainActor
@Observable
final class MusicServiceHost {
    private(set) var service: MusicService?
    /// Told when native playback starts or stops. Set before or after the service exists.
    @ObservationIgnored var onNativePlayingChange: (@MainActor (Bool) -> Void)?

    @ObservationIgnored private let makeService: @MainActor () -> MusicService

    init(makeService: @escaping @MainActor () -> MusicService = { MusicService(backend: MusicBackendLive.live()) }) {
        self.makeService = makeService
        MusicMemoryLog.log("launch")
    }

    func loadIfNeeded() {
        guard service == nil else { return }
        MusicMemoryLog.log("music-open")
        let service = makeService()
        service.onNativePlayingChange = { [weak self] playing in self?.onNativePlayingChange?(playing) }
        self.service = service
    }

    /// Quit path: stops playback if the service was ever created.
    func shutdown() {
        service?.stop()
    }
}
