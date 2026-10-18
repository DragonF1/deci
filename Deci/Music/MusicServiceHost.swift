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
    /// The popup is on screen. It stays mounted while hidden, so `MenuBarPopupView` reports it here; the lyrics
    /// panel fetches and animates only while this is true. Remembered for a service that is created later.
    var isPopupVisible = true {
        didSet { service?.lyrics.setPopupVisible(isPopupVisible) }
    }

    /// The YouTube Music row's model in the Mixer tab. Lives here, not in the service, so the row's settings load at
    /// launch and the service stays lazy. nil in tests that do not care about audio.
    let mixer: MusicMixerState?

    @ObservationIgnored private let makeService: @MainActor () -> MusicService

    init(
        mixer: MusicMixerState? = nil,
        makeService: (@MainActor () -> MusicService)? = nil
    ) {
        self.mixer = mixer
        self.makeService = makeService ?? {
            MusicService(backend: MusicBackendLive.live(), player: MusicServiceHost.makePlayer(mixer: mixer), lyrics: .live())
        }
        MusicMemoryLog.log("launch")
    }

    /// The real player. With a mixer its engine runs the mixer's DSP chain and takes its output device, so volume,
    /// boost, EQ and AutoEQ shape the audio that plays inside Deci's own process.
    static func makePlayer(mixer: MusicMixerState?) -> MusicPlayer {
        guard let mixer else { return MusicPlayer() }
        let engine = AVPlaybackEngine(chain: mixer.chain)
        mixer.attach(engine: engine)
        return MusicPlayer(engine: engine)
    }

    /// A track is loaded in the player, playing or paused, so the Mixer tab shows the YouTube Music row. False before
    /// the Music tab was ever used: reading it never creates the service.
    var hasLoadedTrack: Bool {
        guard let player = service?.player else { return false }
        return player.nowPlaying != nil && (player.isLoading || player.hasStream)
    }

    func loadIfNeeded() {
        guard service == nil else { return }
        MusicMemoryLog.log("music-open")
        let service = makeService()
        service.onNativePlayingChange = { [weak self] playing in self?.onNativePlayingChange?(playing) }
        service.lyrics.setPopupVisible(isPopupVisible)
        self.service = service
    }

    /// Escape on the Music tab: closes the account card if it is open. True when it was open, so the
    /// key is used up and the popup stays; false lets Escape go on to dismiss the popup.
    func closeAccountCard() -> Bool {
        guard isAccountCardOpen else { return false }
        isAccountCardOpen = false
        return true
    }

    /// Quit path: stops playback and flushes held-back cookies, if the service was ever created.
    func shutdown() {
        service?.stop()
    }
}
