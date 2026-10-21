// Deci/Views/MenuBar/MusicHoverCardController.swift
// Shows the Now playing card under the Music status item while the mouse rests on the chip. The rules of when it shows
// and hides are MusicCardHover's; this runs what that machine asks for: a tracking area on the item's button, the two
// timers (which exist only during a hover), and a borderless panel that never takes focus.

import AppKit
import SwiftUI

@MainActor
final class MusicHoverCardController {
    private let musicHost: MusicServiceHost
    /// Opens the full Music popover; the Save hotkey opens it through the same one.
    private let popupOpener: any MusicPopupOpening
    /// Tells a Like or Dislike that did not go through, the way the hotkeys tell it.
    private let hud: any MessageHUDPresenting

    private var hover = MusicCardHover()
    private var showTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?

    private let buttonTarget = ButtonHoverTarget()
    private var trackingArea: NSTrackingArea?
    private weak var trackedButton: NSStatusBarButton?

    private var panel: HoverCardPanel?
    /// Bumped by every show and every hide, so a fade that was overtaken does not finish what a later one started.
    private var fadeGeneration = 0
    /// Watches the full popover opening and closing, only while the chip is on offer.
    private let popupWatcher = MusicPopupKeyWatcher()
    /// Whether the Music popover was open when it was last looked at.
    private var isPopupKey = false
    /// Watches for a Space change, only while the card is up: it can swallow the mouseExited that would let the card go.
    private var spaceObserver: NSObjectProtocol?

    init(
        musicHost: MusicServiceHost,
        hud: any MessageHUDPresenting,
        popupOpener: any MusicPopupOpening = MusicPopupOpener()
    ) {
        self.musicHost = musicHost
        self.hud = hud
        self.popupOpener = popupOpener
        buttonTarget.onEnter = { [weak self] in self?.send(.chipEntered) }
        buttonTarget.onExit = { [weak self] in self?.send(.chipExited) }
    }

    // MARK: - Inputs

    /// Whether the chip is on offer (chip style, item shown, a song loaded). Only while it is on offer does anything
    /// watch: the tracking area on the button and the popover's key changes. Turning it off closes the card at once and
    /// takes both away, so an idle menu bar (and the Icon style) has nothing listening. Safe to call again with the
    /// same value.
    func setEligible(_ eligible: Bool) {
        if eligible {
            observePopup()
            installTrackingArea()
        } else {
            removeTrackingArea()
            stopObservingPopup()
        }
        send(.eligibilityChanged(eligible))
    }

    /// Takes everything down, for a controller that is going away.
    func stop() {
        setEligible(false)
        stopObservingSpace()
    }

    // MARK: - State machine

    private func send(_ event: MusicCardHover.Event) {
        for effect in hover.handle(event) {
            run(effect, after: event)
        }
    }

    private func run(_ effect: MusicCardHover.Effect, after event: MusicCardHover.Event) {
        switch effect {
        case .startShowTimer: startShowTimer()
        case .cancelShowTimer: cancelShowTimer()
        case .startHideTimer: startHideTimer()
        case .cancelHideTimer: cancelHideTimer()
        case .showCard: showCard()
        case .hideCard: hideCard(animated: event == .hideGraceElapsed)
        }
    }

    private func startShowTimer() {
        showTask?.cancel()
        showTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(MusicCardHover.showDelay))
            guard !Task.isCancelled else { return }
            self?.showTask = nil
            self?.send(.showDelayElapsed)
        }
    }

    private func cancelShowTimer() {
        showTask?.cancel()
        showTask = nil
    }

    private func startHideTimer() {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(MusicCardHover.hideGrace))
            guard !Task.isCancelled else { return }
            self?.hideTask = nil
            self?.send(.hideGraceElapsed)
        }
    }

    private func cancelHideTimer() {
        hideTask?.cancel()
        hideTask = nil
    }

    // MARK: - Tracking area on the item's button

    private var musicButton: NSStatusBarButton? {
        MenuBarStatusItems.statusItem(for: .music)?.button
    }

    private func installTrackingArea() {
        guard let button = musicButton else { return }
        if let area = trackingArea, trackedButton === button, button.trackingAreas.contains(where: { $0 === area }) {
            return
        }
        removeTrackingArea()
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: buttonTarget,
            userInfo: nil
        )
        button.addTrackingArea(area)
        trackingArea = area
        trackedButton = button
    }

    private func removeTrackingArea() {
        if let area = trackingArea { trackedButton?.removeTrackingArea(area) }
        trackingArea = nil
        trackedButton = nil
    }

    // MARK: - The full popover

    /// The popover is key while it is open: a click opens it that way, and it resigns when it closes. That is the one
    /// signal that also covers a click, the shortcut and the save button. Any window changing key status is a cue to
    /// look at the Music popover's own; a change in some other window changes nothing.
    private func observePopup() {
        popupWatcher.start { [weak self] in self?.syncPopupKeyState() }
        // Started while the popover is open (a song picked in it makes the chip eligible): the machine is told.
        syncPopupKeyState()
    }

    /// With nothing listening, the machine must not be left believing the popover is open.
    private func stopObservingPopup() {
        popupWatcher.stop()
        guard isPopupKey else { return }
        isPopupKey = false
        send(.popoverClosed)
    }

    private func syncPopupKeyState() {
        let isOpen = MusicPopupKeyWatcher.isPopupOpen
        guard isOpen != isPopupKey else { return }
        isPopupKey = isOpen
        send(isOpen ? .popoverOpened : .popoverClosed)
    }

    // MARK: - A lost mouseExited

    /// While the card is up, a Space change can swallow the mouseExited of the chip or of the card, and the card would
    /// stay. After one, the mouse's real place is looked up and the missing exits are fed in.
    private func observeSpace() {
        guard spaceObserver == nil else { return }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcileMouse() }
        }
    }

    private func stopObservingSpace() {
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        spaceObserver = nil
    }

    private func reconcileMouse() {
        guard hover.isCardVisible, let button = musicButton, let buttonWindow = button.window else { return }
        let mouse = NSEvent.mouseLocation
        let chipFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let overCard = panel?.frame.contains(mouse) == true
        for event in hover.exitsToReconcile(mouseOverChip: chipFrame.contains(mouse), mouseOverCard: overCard) {
            send(event)
        }
    }

    private var isPopupOnScreen: Bool {
        popupOpener.isOnScreen
    }

    /// The save button: the card goes, and the full popover opens as a click on the item opens it.
    private func openPlayer() {
        send(.clicked)
        popupOpener.open()
    }

    // MARK: - The panel

    private func showCard() {
        // The popover can be on screen without having reported it (it is still fading out after a close): no card then.
        guard let button = musicButton, let buttonWindow = button.window, !isPopupOnScreen else {
            send(.clicked)
            return
        }
        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let visibleFrame = buttonWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? buttonFrame
        let frame = MusicHoverCardPlacement.frame(
            buttonFrame: buttonFrame,
            size: MusicHoverCardMetrics.size,
            visibleFrame: visibleFrame
        )

        fadeGeneration &+= 1
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.contentView = makeContent()
        panel.setFrame(frame, display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.invalidateShadow()
        observeSpace()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
    }

    private func hideCard(animated: Bool) {
        fadeGeneration &+= 1
        stopObservingSpace()
        guard let panel, panel.isVisible else { return }
        guard animated else {
            finishHiding(panel)
            return
        }
        let generation = fadeGeneration
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.fadeGeneration == generation, let panel = self.panel else { return }
                self.finishHiding(panel)
            }
        }
    }

    /// Takes the panel off screen and lets its SwiftUI content go, so a hidden card holds nothing that observes the
    /// player. The content is released a turn later: a button of it may be what asked for this.
    private func finishHiding(_ panel: HoverCardPanel) {
        panel.orderOut(nil)
        panel.alphaValue = 1
        let generation = fadeGeneration
        Task { @MainActor [weak self] in
            guard let self, self.fadeGeneration == generation, !panel.isVisible else { return }
            panel.contentView = nil
        }
    }

    private func makeContent() -> NSView {
        let hosting = FirstMouseHostingView(
            rootView: MusicNowPlayingCard(
                musicHost: musicHost,
                onOpenPlayer: { [weak self] in self?.openPlayer() },
                onRated: { [weak self] in self?.hud.showIfFailed($0) }
            )
        )
        // The card never changes size: the panel is sized once, so the hosting view must not ask for another.
        hosting.sizingOptions = []

        let container = HoverCardContainerView(frame: NSRect(origin: .zero, size: MusicHoverCardMetrics.size))
        container.onEnter = { [weak self] in self?.send(.cardEntered) }
        container.onExit = { [weak self] in self?.send(.cardExited) }
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        return container
    }

    private func makePanel() -> HoverCardPanel {
        let panel = HoverCardPanel(
            contentRect: NSRect(origin: .zero, size: MusicHoverCardMetrics.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.setAccessibilityLabel("Now playing")
        return panel
    }
}

// MARK: - AppKit pieces

/// Receives the tracking area's events for the status item's button. An NSResponder, so the overrides answer to
/// `mouseEntered:` and `mouseExited:`: on a plain NSObject `@objc func mouseEntered(with:)` is `mouseEnteredWith:`,
/// which the tracking area never calls.
@MainActor
private final class ButtonHoverTarget: NSResponder {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?

    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }
}

/// A panel that never becomes key or main: the card is used with the mouse and takes no focus from what the owner is
/// typing in.
private final class HoverCardPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A click on the card works at once, with the panel not key.
private final class FirstMouseHostingView: NSHostingView<MusicNowPlayingCard> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Holds the card and reports the mouse coming onto it and leaving it.
private final class HoverCardContainerView: NSView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }
}
