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
    /// Whether the account card in the Music tab's search row is open. Lives here, not in the tab's
    /// view, so the popup's Escape handler can close the card before it dismisses the popup.
    var isAccountCardOpen = false

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

    /// Escape on the Music tab: closes the account card if it is open. True when it was open, so the
    /// key is used up and the popup stays; false lets Escape go on to dismiss the popup.
    func closeAccountCard() -> Bool {
        guard isAccountCardOpen else { return false }
        isAccountCardOpen = false
        return true
    }

    /// Quit path: stops playback if the service was ever created.
    func shutdown() {
        service?.stop()
    }
}
