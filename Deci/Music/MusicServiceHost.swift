// Deci/Music/MusicServiceHost.swift
import AppKit
import Observation

/// Created at app launch; builds the real `MusicService` (AVPlayer, backend, JavaScriptCore) only
/// when the Music popup is first opened, so users who never open it pay nothing.
@MainActor
@Observable
final class MusicServiceHost {
    private(set) var service: MusicService?
    /// What the Music popup shows over its tabs, made with the service. Lives here, not in the tab's view:
    /// the player is unmounted when the Music icon is hidden in Settings and built again when it is shown, and the
    /// view takes this one back, so an artist opened from the search results is still open (and Back still returns to the results).
    private(set) var navigation: MusicSearchNavigation?
    /// Where a menu pick's Like or Dislike outcome shows, passed on to the navigation whenever either exists. Not held:
    /// the reporter holds the host.
    @ObservationIgnored weak var outcomes: (any MusicOutcomeReporting)? {
        didSet { navigation?.outcomes = outcomes }
    }
    /// Told when native playback starts or stops. Set before or after the service exists.
    @ObservationIgnored var onNativePlayingChange: (@MainActor (Bool) -> Void)?
    /// Whether the account card in the Music popup's search row is open. Lives here, not in the tab's
    /// view, so the popup's Escape handler can close the card before it dismisses the popup.
    var isAccountCardOpen = false
    /// The Music popup is on screen. It stays mounted while hidden, so `MusicPopupView` reports it here; the lyrics
    /// panel fetches and animates only while this is true. Remembered for a service that is created later.
    var isPopupVisible = true {
        didSet { service?.lyrics.setPopupVisible(isPopupVisible) }
    }

    /// The player column's spectrum: polls the loudness and the position while the popup is on screen and a song plays.
    /// Lives here for the same reason as the navigation: it keeps the bars it has seen while the popup is closed.
    let spectrum = MusicSpectrumDriver()

    /// The music player row's model in the Mixer popup (shown there as Deci). Lives here, not in the service, so the row's settings load at
    /// launch and the service stays lazy. nil in tests that do not care about audio.
    let mixer: MusicMixerState?

    @ObservationIgnored private let makeService: @MainActor () -> MusicService

    init(
        mixer: MusicMixerState? = nil,
        settings: SettingsManager? = nil,
        makeService: (@MainActor () -> MusicService)? = nil
    ) {
        self.mixer = mixer
        self.makeService = makeService ?? {
            MusicService(
                backend: MusicBackendLive.live(),
                player: MusicServiceHost.makePlayer(mixer: mixer),
                lyrics: .live(),
                listenerLevel: { [weak mixer] in mixer?.watchtimeLevel ?? (WatchtimeTracker.fullVolume, false) },
                // Shuffle, loop and Autoplay are remembered in settings.json.
                preferences: settings?.appSettings.musicPlayback ?? MusicPlaybackPreferences(),
                savePreferences: MusicServiceHost.savePreferences(to: settings),
                // The items pinned to Home are remembered in settings.json too.
                pinnedItems: settings?.appSettings.musicPinnedItems ?? [],
                savePinnedItems: MusicServiceHost.savePinnedItems(to: settings)
            )
        }
        MusicMemoryLog.log("launch")
    }

    /// Writes the playback options into settings.json, leaving every other setting as it is.
    static func savePreferences(to settings: SettingsManager?) -> @MainActor (MusicPlaybackPreferences) -> Void {
        { [weak settings] preferences in
            guard let settings else { return }
            var appSettings = settings.appSettings
            appSettings.musicPlayback = preferences
            settings.updateAppSettings(appSettings)
        }
    }

    /// Writes the pinned items into settings.json, leaving every other setting as it is.
    static func savePinnedItems(to settings: SettingsManager?) -> @MainActor ([MusicPinnedItem]) -> Void {
        { [weak settings] items in
            guard let settings else { return }
            var appSettings = settings.appSettings
            appSettings.musicPinnedItems = items
            settings.updateAppSettings(appSettings)
        }
    }

    /// The real player. With a mixer its engine runs the mixer's DSP chain and takes its output device, so volume,
    /// boost, EQ and AutoEQ shape the audio that plays inside Deci's own process.
    static func makePlayer(mixer: MusicMixerState?) -> MusicPlayer {
        guard let mixer else { return MusicPlayer() }
        let engine = AVPlaybackEngine(chain: mixer.chain)
        mixer.attach(engine: engine)
        return MusicPlayer(engine: engine)
    }

    /// A track is loaded in the player, playing or paused, so the Mixer popup shows the music player row (as Deci). False before
    /// the Music popup was ever used: reading it never creates the service.
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
        let navigation = MusicSearchNavigation(service: service)
        navigation.outcomes = outcomes
        self.navigation = navigation
        spectrum.sources = MusicSpectrumDriver.Sources(
            level: { [weak mixer = self.mixer] in mixer?.sampleSpectrumLevel() ?? 0 },
            position: { [weak service] in service?.player.livePosition() ?? 0 },
            duration: { [weak service] in service?.player.duration ?? 0 },
            videoId: { [weak service] in service?.player.nowPlaying?.videoId },
            reduceMotion: { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
        )
    }

    /// Escape in the Music popup: closes the account card if it is open. True when it was open, so the
    /// key is used up and the popup stays; false lets Escape go on to dismiss the popup.
    func closeAccountCard() -> Bool {
        guard isAccountCardOpen else { return false }
        isAccountCardOpen = false
        return true
    }

    /// Reset all settings: the music options and pins held in memory go back to their defaults too. Nothing to do
    /// before the Music popup was ever used, since a later service starts from the cleared settings.
    func settingsDidReset() {
        service?.settingsDidReset()
    }

    /// Quit path: stops playback and flushes held-back cookies, if the service was ever created.
    func shutdown() {
        service?.stop()
    }
}
