// FineTune/Views/HUD/HUDWindowController.swift
import AppKit
import SwiftUI
import os

/// Owns the on-screen volume HUD panel and its auto-hide timing.
@MainActor
final class HUDWindowController: MediaKeyHUDPresenting {
    private let settingsManager: SettingsManager
    private let mediaKeyStatus: MediaKeyStatus
    private let popupVisibility: PopupVisibilityService
    private let logger = Logger(subsystem: "com.abraham.Deci", category: "HUDWindowController")

    private var panel: NSPanel?
    private var hostingView: NSHostingView<AnyView>?
    private var hideTask: Task<Void, Never>?
    private var styleAtLastShow: HUDStyle = .tahoe

    /// Slider fraction in [0, 1]. The wiring site converts to gain using the current device's tier.
    var volumeWriter: ((Double) -> Void)?

    // MARK: - Suppression-degraded tracking

    private var lastSwallowedKeyTime: DispatchTime?
    private var settingsChangedObserver: NSObjectProtocol?

    var hideDelayOverride: Duration?
    var fullscreenOverride: Bool?
    var frameProvider: () -> NSRect? = { NSScreen.main?.visibleFrame ?? NSScreen.screens.first?.visibleFrame }
    private(set) var showCallCount: Int = 0
    private(set) var showDidUpdatePanel: Bool = false
    /// The panel's window level; nil until the first show builds the panel.
    var panelLevel: NSWindow.Level? { panel?.level }

    /// The volume HUD's level: floating, below the menu bar, the revealed menu bar and the hover card.
    static let volumeLevel = NSWindow.Level.floating

    /// A message's level, one above the menu bar popups, which are `.statusBar`: a message shown while a popup is open is
    /// not hidden behind it. The panel is raised for a message only; the volume HUD sets it back.
    static let messageLevel = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)

    init(
        settingsManager: SettingsManager,
        mediaKeyStatus: MediaKeyStatus,
        popupVisibility: PopupVisibilityService
    ) {
        self.settingsManager = settingsManager
        self.mediaKeyStatus = mediaKeyStatus
        self.popupVisibility = popupVisibility
        subscribeToSettingsChangedNotification()
    }

    isolated deinit {
        if let observer = settingsChangedObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        // Prefer shutdown() for synchronous teardown during willTerminate; this
        // deinit safety-net only fires for objects released without that call.
        if let panel {
            panel.orderOut(nil)
        }
    }

    /// Synchronous teardown for `willTerminate` — hides without animation.
    func shutdown() {
        hideTask?.cancel()
        hideTask = nil
        if let panel, panel.isVisible {
            panel.orderOut(nil)
        }
    }

    // MARK: - Style-indexed hide delay

    func hideDelay(for style: HUDStyle) -> Duration {
        if let override = hideDelayOverride { return override }
        return .milliseconds(1100)
    }

    // MARK: - Public API

    /// Displays the HUD. Skipped when the foreground app is fullscreen or the popup is visible.
    func show(sliderFraction: Double, mute: Bool, deviceName: String) {
        showCallCount += 1
        showDidUpdatePanel = false

        guard !(fullscreenOverride ?? isForegroundAppFullscreen()) else {
            logger.debug("Skipping HUD show: foreground app is fullscreen")
            return
        }
        guard !popupVisibility.isVisible else {
            logger.debug("Skipping HUD show: popup is visible")
            return
        }

        let style = settingsManager.appSettings.hudStyle
        let appearance = settingsManager.appSettings.appearance
        styleAtLastShow = style
        let panel = ensurePanel()
        // The panel is shared with the messages, so each show sets its own level.
        panel.level = Self.volumeLevel
        // Refresh on every show so a preference change between invocations
        // takes effect immediately.
        panel.appearance = appearance.nsAppearance

        // Classic is click-through; Tahoe takes mouse events for drag + hover.
        panel.ignoresMouseEvents = (style == .classic)

        let scheme = appearance.swiftUIColorScheme
        let displayFraction = Float(max(0, min(1, sliderFraction)))
        let root: AnyView
        let size: NSSize
        switch style {
        case .tahoe:
            root = AnyView(
                TahoeStyleHUD(
                    sliderFraction: displayFraction,
                    mute: mute,
                    deviceName: deviceName,
                    onSliderChange: { [weak self] newFraction in
                        self?.volumeWriter?(Double(newFraction))
                    },
                    onHoverChange: { [weak self] hovering in
                        self?.handleHoverChange(hovering)
                    }
                )
                .preferredColorScheme(scheme)
            )
            size = NSSize(width: 300, height: 72)
        case .classic:
            root = AnyView(
                ClassicStyleHUD(sliderFraction: displayFraction, mute: mute)
                    .preferredColorScheme(scheme)
            )
            size = NSSize(width: 200, height: 200)
        }

        if let existing = hostingView {
            existing.rootView = root
        } else {
            let hv = NSHostingView(rootView: root)
            hv.frame = NSRect(origin: .zero, size: size)
            panel.contentView = hv
            hostingView = hv
        }
        showDidUpdatePanel = true

        panel.setContentSize(size)
        panel.setFrameOrigin(position(for: style, size: size))

        if panel.isVisible {
            panel.orderFrontRegardless()
        } else {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            let duration = reduceMotionEnabled() ? 0.08 : 0.12
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = duration
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1.0
            }
        }

        scheduleHide(for: style)
        postAccessibilityAnnouncement(panel: panel, sliderFraction: sliderFraction, mute: mute, deviceName: deviceName)
    }

    /// Shows one short line with a symbol, for what a hotkey came to. Same panel, place and timing as the volume HUD. It
    /// bypasses the fullscreen guard and the popup guard because the user explicitly invoked it: the caller decides
    /// whether a popup shows the line instead (`MusicOutcomeReporter`).
    func showMessage(_ message: HUDMessage) {
        showCallCount += 1
        showDidUpdatePanel = false

        let appearance = settingsManager.appSettings.appearance
        styleAtLastShow = .tahoe
        let panel = ensurePanel()
        panel.level = Self.messageLevel
        panel.appearance = appearance.nsAppearance
        panel.ignoresMouseEvents = true

        let scheme = appearance.swiftUIColorScheme
        let root = AnyView(
            MessageHUD(message: message)
                .preferredColorScheme(scheme)
        )
        let size = NSSize(width: 300, height: 72)

        if let existing = hostingView {
            existing.rootView = root
        } else {
            let hv = NSHostingView(rootView: root)
            hv.frame = NSRect(origin: .zero, size: size)
            panel.contentView = hv
            hostingView = hv
        }
        showDidUpdatePanel = true

        panel.setContentSize(size)
        panel.setFrameOrigin(position(for: .tahoe, size: size))

        if panel.isVisible {
            panel.orderFrontRegardless()
        } else {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            let duration = reduceMotionEnabled() ? 0.08 : 0.12
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = duration
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1.0
            }
        }

        scheduleHide(for: .tahoe)
        NSAccessibility.post(
            element: panel,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message.text,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue
            ]
        )
    }

    /// Called when the monitor swallows a keypress; used to detect if the native HUD still fired.
    func swallowObserved() {
        lastSwallowedKeyTime = DispatchTime.now()
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        guard let panel, panel.isVisible else { return }
        let duration = reduceMotionEnabled() ? 0.08 : 0.11
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = 0.0
        }, completionHandler: {
            MainActor.assumeIsolated { panel.orderOut(nil) }
        })
    }

    // MARK: - Position Math

    /// Tahoe: top-right. Classic: bottom-center. Under suppression-degraded,
    /// Tahoe shifts left so it doesn't overlap the native top-right HUD.
    static func computePosition(
        style: HUDStyle,
        size: NSSize,
        visibleFrame: NSRect,
        suppressionDegraded: Bool
    ) -> NSPoint {
        switch style {
        case .tahoe:
            if suppressionDegraded {
                let x = visibleFrame.minX + visibleFrame.width * 0.25 - size.width / 2
                let y = visibleFrame.maxY - size.height - 8
                return NSPoint(x: x, y: y)
            } else {
                let x = visibleFrame.maxX - size.width - 8
                let y = visibleFrame.maxY - size.height - 8
                return NSPoint(x: x, y: y)
            }
        case .classic:
            let x = visibleFrame.midX - size.width / 2
            let y = visibleFrame.minY + 140
            return NSPoint(x: x, y: y)
        }
    }

    private func position(for style: HUDStyle, size: NSSize) -> NSPoint {
        let frame = frameProvider() ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return Self.computePosition(
            style: style,
            size: size,
            visibleFrame: frame,
            suppressionDegraded: mediaKeyStatus.suppressionDegraded
        )
    }

    // MARK: - Panel construction

    private func ensurePanel() -> NSPanel {
        if let existing = panel { return existing }

        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 72),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.level = Self.volumeLevel
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
        p.hasShadow = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.ignoresMouseEvents = true
        // Needed for Tahoe hover/drag on a non-activating panel.
        p.acceptsMouseMovedEvents = true
        p.hidesOnDeactivate = false
        p.isMovable = false
        p.isReleasedWhenClosed = false
        // Initial appearance; refreshed on every show() so preference flips
        // between invocations propagate.
        p.appearance = settingsManager.appSettings.appearance.nsAppearance

        panel = p
        return p
    }

    private func scheduleHide(for style: HUDStyle) {
        hideTask?.cancel()
        let delay = hideDelay(for: style)
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    private func handleHoverChange(_ hovering: Bool) {
        if hovering {
            hideTask?.cancel()
            hideTask = nil
        } else {
            scheduleHide(for: styleAtLastShow)
        }
    }

    // MARK: - Accessibility

    private func postAccessibilityAnnouncement(panel: NSPanel, sliderFraction: Double, mute: Bool, deviceName: String) {
        let description = accessibilityDescription(sliderFraction: sliderFraction, mute: mute, deviceName: deviceName)
        NSAccessibility.post(
            element: panel,
            notification: .announcementRequested,
            userInfo: [
                .announcement: description,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue
            ]
        )
    }

    private func accessibilityDescription(sliderFraction: Double, mute: Bool, deviceName: String) -> String {
        let device = deviceName.isEmpty ? "Unknown device" : deviceName
        if mute { return "\(device), muted" }
        let clamped = max(0, min(1, sliderFraction))
        return "\(device), volume \(Int((clamped * 100).rounded())) percent"
    }

    private func reduceMotionEnabled() -> Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    // MARK: - Fullscreen guard

    private func isForegroundAppFullscreen() -> Bool {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else { return false }
        let pid = frontmostApp.processIdentifier
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        guard let mainScreen = NSScreen.main else { return false }
        let screenFrame = mainScreen.frame
        for windowInfo in windowList {
            guard let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? pid_t, ownerPID == pid,
                  let boundsDict = windowInfo[kCGWindowBounds as String] as? [String: Any],
                  let boundsRect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else {
                continue
            }
            if boundsRect.width >= screenFrame.width && boundsRect.height >= screenFrame.height {
                return true
            }
        }
        return false
    }

    // MARK: - Suppression-degraded detection

    private func subscribeToSettingsChangedNotification() {
        settingsChangedObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.sound.settingsChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleSettingsChangedNotification()
            }
        }
    }

    private func handleSettingsChangedNotification() {
        guard let lastSwallow = lastSwallowedKeyTime else { return }
        let elapsed = DispatchTime.now().uptimeNanoseconds &- lastSwallow.uptimeNanoseconds
        let elapsedMs = elapsed / 1_000_000
        if elapsedMs <= 500 && !mediaKeyStatus.suppressionDegraded {
            mediaKeyStatus.suppressionDegraded = true
            logger.warning("Suppression degraded: native sound handler fired within \(elapsedMs)ms of our swallow")
        }
    }
}

// MARK: - Message HUD

private struct MessageHUD: View {
    let message: HUDMessage

    private static let frameWidth: CGFloat = 300
    private static let frameHeight: CGFloat = 72
    private static let cornerRadius: CGFloat = 22
    private static let iconSize: CGFloat = 28

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: message.symbol)
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(DesignTokens.Colors.hudTileActive)
                .frame(width: Self.iconSize, height: Self.iconSize)
            Text(message.text)
                .font(TahoeStyleHUD.nameFont)
                .foregroundStyle(DesignTokens.Colors.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .frame(width: Self.frameWidth, height: Self.frameHeight)
        .background {
            RoundedRectangle(cornerRadius: Self.cornerRadius)
                .fill(.regularMaterial)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Self.cornerRadius)
                .strokeBorder(DesignTokens.Colors.hudBorder, lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(message.text)
    }
}
