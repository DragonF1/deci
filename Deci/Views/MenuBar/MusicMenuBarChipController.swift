// Deci/Views/MenuBar/MusicMenuBarChipController.swift
// Puts the Now playing chip on the Music status item's button, and takes it off again. Like MenuBarIconCoordinator it
// owns the button's image: FluidMenuBarExtra sets it once and never touches it again. The chip is drawn only when the
// style is Now playing chip, the item is shown and a song is loaded; in every other case the button holds the icon it
// started with, exactly as before.

import AppKit
import Observation

@MainActor
final class MusicMenuBarChipController {
    /// What the button was last given, so a refresh that changes nothing touches nothing.
    private struct Applied: Equatable {
        var spec: MusicChipSpec
        var thumbnailURL: URL?
    }

    private let settings: SettingsManager
    private let musicHost: MusicServiceHost
    /// The Music item's own icon, put back whenever the chip is not on offer.
    private let iconImage: NSImage
    private let hoverCard: MusicHoverCardController

    private let popupWatcher = MusicPopupKeyWatcher()

    private var started = false
    private var stopped = false
    private var applied: Applied?
    /// What the hover card was last told about the chip being on offer, so a refresh that changes nothing says nothing.
    private var eligibleSent = false
    /// Loading the cover of the current song (its colour and its small picture). Nothing runs while the style is Icon.
    private var coverTask: Task<Void, Never>?
    private var coverURL: URL?

    init(settings: SettingsManager, musicHost: MusicServiceHost, iconImage: NSImage) {
        self.settings = settings
        self.musicHost = musicHost
        self.iconImage = iconImage
        self.hoverCard = MusicHoverCardController(musicHost: musicHost)
    }

    /// Begins following the setting and the player. Idempotent, and safe before the status item exists.
    func start() {
        guard !started else { return }
        started = true
        scheduleTracking()
        refreshWhenButtonExists(retriesLeft: 20)
    }

    /// Takes everything down, for the app quitting.
    func stop() {
        stopped = true
        popupWatcher.stop()
        cancelCoverLoad()
        hoverCard.stop()
    }

    // MARK: - Observation

    /// Everything the chip is drawn from, and nothing that ticks: no playback position.
    private func scheduleTracking() {
        withObservationTracking {
            _ = settings.appSettings.musicMenuBarStyle
            _ = settings.appSettings.showMusicInMenuBar
            _ = musicHost.service
            _ = musicHost.service?.authState
            _ = musicHost.hasLoadedTrack
            let player = musicHost.service?.player
            _ = player?.nowPlaying
            _ = player?.isPlaying
            _ = player?.isLoading
        } onChange: { [weak self] in
            // onChange fires in willSet: re-register now so the next change is not missed, and read the committed
            // values in a task (the same way MenuBarIconCoordinator does).
            MainActor.assumeIsolated { [weak self] in
                self?.scheduleTracking()
            }
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
    }

    /// The Music scene builds its item after the app's init returns: wait for its button, for up to a second.
    private func refreshWhenButtonExists(retriesLeft: Int) {
        if MenuBarStatusItems.statusItem(for: .music)?.button != nil {
            refresh()
            return
        }
        guard retriesLeft > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.refreshWhenButtonExists(retriesLeft: retriesLeft - 1)
        }
    }

    // MARK: - Apply

    /// Brings the button in line with the settings and the player. While the full popover is open a change of the
    /// button's picture waits: FluidMenuBarExtra frames its window only when it opens, so a different width would shift
    /// the item and leave the popover misaligned. The change is made when the popover closes (`ignoringPopup`).
    private func refresh(ignoringPopup: Bool = false) {
        guard !stopped else { return }
        let style = settings.appSettings.musicMenuBarStyle
        let isShown = settings.appSettings.showMusicInMenuBar
        let service = musicHost.service
        let hasTrack = musicHost.hasLoadedTrack && service?.authState == .signedIn
        let wantsChip = MusicChipLayout.showsChip(style: style, isMusicShown: isShown, hasTrack: hasTrack)

        guard let button = MenuBarStatusItems.statusItem(for: .music)?.button else { return }

        // The Icon style never gets past this: nothing is installed for it and nothing is told.
        if wantsChip != eligibleSent {
            eligibleSent = wantsChip
            hoverCard.setEligible(wantsChip)
        }

        guard wantsChip, let player = service?.player, let track = player.nowPlaying else {
            cancelCoverLoad()
            guard applied != nil else {
                releaseHold()
                return
            }
            guard ignoringPopup || !MusicPopupKeyWatcher.isPopupOpen else {
                holdUntilPopupCloses()
                return
            }
            releaseHold()
            restoreIcon(on: button)
            return
        }

        loadCoverIfNeeded(for: track.thumbnailURL)
        let store = MusicCoverTintStore.shared
        let thumbnail = store.cachedThumbnail(for: track.thumbnailURL)
        let spec = MusicChipSpec(
            title: MusicChipLayout.displayTitle(title: track.title, artist: track.artist),
            isPlaying: player.isPlaying,
            tint: store.cachedTint(for: track.thumbnailURL) ?? MusicChipRenderer.accentFallbackTint(),
            hasThumbnail: thumbnail != nil
        )
        let next = Applied(spec: spec, thumbnailURL: track.thumbnailURL)
        guard next != applied else {
            releaseHold()
            return
        }
        guard ignoringPopup || !MusicPopupKeyWatcher.isPopupOpen else {
            holdUntilPopupCloses()
            return
        }
        releaseHold()
        applied = next

        fade(button)
        button.image = MusicChipRenderer.image(for: spec, thumbnail: thumbnail)
        button.setAccessibilityLabel(MusicChipLayout.accessibilityLabel(title: spec.title, isPlaying: spec.isPlaying))
    }

    // MARK: - While the popover is open

    /// Waits for the popover to close, listening only for as long as a change is waiting.
    private func holdUntilPopupCloses() {
        popupWatcher.start { [weak self] in self?.popupStateChanged() }
    }

    private func popupStateChanged() {
        guard !MusicPopupKeyWatcher.isPopupOpen else { return }
        releaseHold()
        refresh(ignoringPopup: true)
    }

    private func releaseHold() {
        popupWatcher.stop()
    }

    /// Back to the icon, only if the chip was put there: with the Icon style the button is never touched.
    private func restoreIcon(on button: NSStatusBarButton) {
        guard applied != nil else { return }
        applied = nil
        fade(button)
        button.image = iconImage
        // Nil makes the button read the icon's own description again ("Deci Music").
        button.setAccessibilityLabel(nil)
    }

    private func fade(_ button: NSStatusBarButton) {
        button.wantsLayer = true
        let transition = CATransition()
        transition.type = .fade
        transition.duration = 0.18
        transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        button.layer?.add(transition, forKey: "chipFade")
    }

    // MARK: - Cover

    /// The cover's colour and small picture come from the one fetch the player's own accent already makes. The chip is
    /// drawn at once with what is known, and again when the cover arrives.
    private func loadCoverIfNeeded(for url: URL?) {
        guard let url else {
            cancelCoverLoad()
            return
        }
        guard url != coverURL else { return }
        coverTask?.cancel()
        coverURL = url
        guard MusicCoverTintStore.shared.cachedThumbnail(for: url) == nil else { return }
        coverTask = Task { [weak self] in
            _ = await MusicCoverTintStore.shared.tint(for: url)
            guard !Task.isCancelled, let self, self.coverURL == url else { return }
            self.coverTask = nil
            self.refresh()
        }
    }

    private func cancelCoverLoad() {
        coverTask?.cancel()
        coverTask = nil
        coverURL = nil
    }
}
