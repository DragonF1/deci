// Deci/Views/MenuBar/MusicMenuBarChipController.swift
// Puts the Now playing chip on the Music status item's button, and takes it off again. Like MenuBarIconCoordinator it
// owns the button's image: FluidMenuBarExtra sets it once and never touches it again. The chip is shown only when the
// style is Now playing chip, the item is shown and a song is loaded; in every other case the button holds the icon it
// started with, exactly as before. While the chip shows, the item has an explicit length that follows the pill: a new
// song, a pause or a play makes it grow or shrink on the pill's own curve (MusicChipLengthAnimator), the pill and its
// content animate by Core Animation (MusicChipView), a title longer than the max scrolls, and a paused song is only the
// cover's colour with a play glyph.

import AppKit
import Observation

@MainActor
final class MusicMenuBarChipController {
    private let settings: SettingsManager
    private let musicHost: MusicServiceHost
    /// The Music item's own icon, put back whenever the chip is not on offer.
    private let iconImage: NSImage
    private let hoverCard: MusicHoverCardController

    private let popupWatcher = MusicPopupKeyWatcher()

    private var started = false
    private var stopped = false
    /// What the chip was last given, so a refresh that changes nothing touches nothing.
    private var applied: MusicChipSpec?
    private var appliedGeometry: MusicChipGeometry?
    /// The pill's width on screen: the title's while the song plays, the small paused one while it does not.
    private var appliedPillWidth: Double? {
        guard let applied, let appliedGeometry else { return nil }
        return MusicChipLayout.shownPillWidth(for: appliedGeometry, isPlaying: applied.isPlaying)
    }
    private var chipView: MusicChipView?
    private var lengthAnimator: MusicChipLengthAnimator?
    /// What the item leaves on each side of an icon, read once from the button before the chip first takes it over.
    private var measuredPadding: Double?
    private var reduceMotionObserver: NSObjectProtocol?
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
        lengthAnimator?.cancel()
        chipView?.teardown()
        stopObservingReduceMotion()
        hoverCard.stop()
    }

    // MARK: - Observation

    private func scheduleTracking() {
        CommittedObservation.track { [weak self] in
            self?.readTracked()
        } onChange: { [weak self] in
            self?.refresh()
        }
    }

    /// Everything the chip is drawn from, and nothing that ticks: no playback position.
    private func readTracked() {
        _ = settings.appSettings.musicMenuBarStyle
        _ = settings.appSettings.showMusicInMenuBar
        _ = musicHost.service
        _ = musicHost.service?.authState
        _ = musicHost.hasLoadedTrack
        let player = musicHost.service?.player
        _ = player?.nowPlaying
        _ = player?.isPlaying
        _ = player?.isLoading
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

    /// Brings the button in line with the settings and the player. While the full popover is open a change that alters
    /// the item's width waits: FluidMenuBarExtra frames its window only when it opens, so a different width would shift
    /// the item and leave the popover misaligned. The change is made when the popover closes (`ignoringPopup`). A change
    /// that keeps the width (a title as wide as the last, a cover that arrives, a marquee) is made at once; a play or a
    /// pause changes the width, so it waits like a new title does.
    private func refresh(ignoringPopup: Bool = false) {
        guard !stopped else { return }
        let style = settings.appSettings.musicMenuBarStyle
        let isShown = settings.appSettings.showMusicInMenuBar
        let service = musicHost.service
        let hasTrack = musicHost.hasLoadedTrack && service?.authState == .signedIn
        let wantsChip = MusicChipLayout.showsChip(style: style, isMusicShown: isShown, hasTrack: hasTrack)

        guard let item = MenuBarStatusItems.statusItem(for: .music), let button = item.button else { return }

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
            restoreIcon(on: button, item: item)
            return
        }

        loadCoverIfNeeded(for: track.thumbnailURL)
        let store = MusicCoverTintStore.shared
        let thumbnail = store.cachedThumbnail(for: track.thumbnailURL)
        // While the cover loads, the pill keeps the colour it has, so it goes from the old colour to the new one and does
        // not pass through the accent colour.
        let pendingTint = coverTask != nil ? applied?.tint : nil
        let spec = MusicChipSpec(
            title: MusicChipLayout.displayTitle(title: track.title, artist: track.artist),
            isPlaying: player.isPlaying,
            tint: store.cachedTint(for: track.thumbnailURL) ?? pendingTint ?? MusicChipRenderer.accentFallbackTint(),
            hasThumbnail: thumbnail != nil,
            coverURL: track.thumbnailURL,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
        let change = MusicChipMotion.change(from: applied, to: spec)
        guard change != .none else {
            releaseHold()
            return
        }
        // Only a different title needs measuring: a play, a pause or a cover that arrives keeps the title on screen, so
        // its geometry stays. What the pill's width is follows from that and from whether the song plays.
        let geometry: MusicChipGeometry
        if change != .content, let appliedGeometry {
            geometry = appliedGeometry
        } else {
            geometry = MusicChipLayout.geometry(title: spec.title, measure: MusicChipRenderer.titleWidth)
        }
        let pillWidth = MusicChipLayout.shownPillWidth(for: geometry, isPlaying: spec.isPlaying)
        let widthChanges = chipView == nil || appliedPillWidth != pillWidth
        guard ignoringPopup || !MusicPopupKeyWatcher.isPopupOpen || !widthChanges else {
            holdUntilPopupCloses()
            return
        }
        releaseHold()

        let isInstall = chipView == nil
        if isInstall {
            install(on: button, item: item, pillWidth: pillWidth)
        }
        applied = spec
        appliedGeometry = geometry

        let duration = isInstall ? 0 : MusicChipMotion.widthChangeDuration(reduceMotion: spec.reduceMotion)
        chipView?.show(spec: spec, geometry: geometry, thumbnail: thumbnail, change: change, widthDuration: duration)
        if !isInstall, widthChanges {
            lengthAnimator?.animate(to: pillWidth, duration: duration)
        }
        button.setAccessibilityLabel(MusicChipLayout.accessibilityLabel(title: spec.title, isPlaying: spec.isPlaying))
    }

    // MARK: - Install and remove

    /// Takes the button's icon off and puts the chip view there, with the item at the pill's length. The icon fades into
    /// the chip, as the swap of the button's picture did before.
    private func install(on button: NSStatusBarButton, item: NSStatusItem, pillWidth: Double) {
        let padding = itemPadding(for: button)
        let animator = MusicChipLengthAnimator(item: item, button: button, itemPadding: padding)
        lengthAnimator = animator

        fade(button)
        button.image = nil
        animator.set(pillWidth: pillWidth)
        let view = MusicChipView(frame: button.bounds, scale: button.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2)
        view.autoresizingMask = [.width, .height]
        button.addSubview(view)
        view.appear()
        chipView = view
        observeReduceMotion()
    }

    /// Back to the icon, only if the chip was put there: with the Icon style the button is never touched. The item goes
    /// back to the length it sizes itself to.
    private func restoreIcon(on button: NSStatusBarButton, item: NSStatusItem) {
        guard applied != nil else { return }
        applied = nil
        appliedGeometry = nil
        lengthAnimator?.cancel()
        lengthAnimator = nil
        stopObservingReduceMotion()
        fade(button)
        chipView?.teardown()
        chipView?.removeFromSuperview()
        chipView = nil
        item.length = NSStatusItem.variableLength
        button.image = iconImage
        // Nil makes the button read the icon's own description again ("Deci Music").
        button.setAccessibilityLabel(nil)
    }

    /// What the item leaves on each side of its icon. Read from the button while it still holds the icon, and kept once it
    /// makes sense; the usual padding stands in until then.
    private func itemPadding(for button: NSStatusBarButton) -> Double {
        if let measuredPadding { return measuredPadding }
        guard chipView == nil,
              let padding = MusicChipLayout.measuredItemPadding(
                  buttonWidth: Double(button.bounds.width),
                  iconWidth: Double(iconImage.size.width)
              )
        else { return MusicChipLayout.defaultItemPadding }
        measuredPadding = padding
        return padding
    }

    private func fade(_ button: NSStatusBarButton) {
        button.wantsLayer = true
        let transition = CATransition()
        transition.type = .fade
        transition.duration = 0.18
        transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        button.layer?.add(transition, forKey: "chipFade")
    }

    // MARK: - Reduce Motion

    /// While the chip shows, a change of the Reduce Motion setting rebuilds the title (an ellipsis or a marquee) at once.
    private func observeReduceMotion() {
        guard reduceMotionObserver == nil else { return }
        reduceMotionObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func stopObservingReduceMotion() {
        guard let reduceMotionObserver else { return }
        NSWorkspace.shared.notificationCenter.removeObserver(reduceMotionObserver)
        self.reduceMotionObserver = nil
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

/// Calls `onChange` after every change to what `read` reads. withObservationTracking's onChange runs in willSet, while
/// the property still holds its old value, so tracking again from there follows the old value's children: the Music
/// service is made lazily, and a tracker that looked again while it was still nil never followed its player. Here the
/// tracking starts again on the next main actor turn, once the change has landed, and `onChange` runs after it.
@MainActor
enum CommittedObservation {
    static func track(_ read: @escaping @MainActor () -> Void, onChange: @escaping @MainActor () -> Void) {
        withObservationTracking {
            read()
        } onChange: {
            Task { @MainActor in
                track(read, onChange: onChange)
                onChange()
            }
        }
    }
}
