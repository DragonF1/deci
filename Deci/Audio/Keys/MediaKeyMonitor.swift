// FineTune/Audio/Keys/MediaKeyMonitor.swift
import AppKit
import AudioToolbox
import CoreGraphics
import os

/// View-layer collaborators MediaKeyMonitor drives. Abstracting them keeps the audio
/// layer free of concrete view types (HUDWindowController, MenuBarIconCoordinator);
/// the view layer supplies the conformances.
@MainActor
protocol MediaKeyHUDPresenting: AnyObject {
    func show(sliderFraction: Double, mute: Bool, deviceName: String)
    func swallowObserved()
    func passThroughObserved()
}

@MainActor
protocol MediaKeyIconFlashing: AnyObject {
    func flashDevice()
}

/// The Shift and Option state the feedback pop sees for a volume key press. A modifier that belongs to the
/// matched row's combo is part of choosing the step, so it must not also invert the pop: under a Command+Shift
/// row, Shift is spent on the row.
struct VolumeKeyModifiers: Equatable {
    let feedbackShiftHeld: Bool
    let feedbackOptionHeld: Bool

    init(held: VolumeKeyCombo, matched: VolumeKeyCombo) {
        feedbackShiftHeld = held.contains(.shift) && !matched.contains(.shift)
        feedbackOptionHeld = held.contains(.option) && !matched.contains(.option)
    }
}

/// Intercepts F10/F11/F12 via a `CGEventTap`, swallows them so the native HUD
/// does not double-fire, and drives the default output device.
@MainActor
final class MediaKeyMonitor {
    // MARK: - Collaborators

    private let decoder: any MediaKeyEventDecoding
    private let audioEngine: AudioEngine
    private let settingsManager: SettingsManager
    private let accessibility: any AccessibilityTrustProviding
    private let hudController: MediaKeyHUDPresenting
    private let popupVisibility: PopupVisibilityService
    private let mediaKeyStatus: MediaKeyStatus
    private let volumeKeyRecorder: VolumeKeyRecorder
    private let logger = Logger(subsystem: "com.abraham.Deci", category: "MediaKeyMonitor")

    // MARK: - Tap state

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Second `.tapDisabledBy*` inside the watchdog window marks the feature offline.
    private var disableWatchdogTask: Task<Void, Never>?
    private(set) var watchdogOpen: Bool = false

    /// 80 ms floor between DDC-tier repeats — DDC write queues saturate at key-repeat rate.
    var lastDDCRepeatTime: DispatchTime?

    private var ghostTapProbeTask: Task<Void, Never>?

    /// How the last fresh press of a volume key was routed. macOS sends the auto-repeats of a held key with
    /// whatever modifiers are down at that moment, so a repeat follows its press instead of being matched from
    /// scratch: a modifier released mid-hold must not hand the rest of the hold to macOS.
    private enum PressRoute {
        /// Deci stepped the volume. The row is kept by id so a row removed mid-hold is simply not found.
        case handled(rowID: UUID)
        /// No row fit, so macOS acted on the press and acts on its repeats.
        case passedThrough
    }

    private var upRoute: PressRoute?
    private var downRoute: PressRoute?

    /// The transport keys whose fresh press this monitor swallowed and that have not been released yet. A repeat or a
    /// key-up is swallowed only for a key in here: one whose press was never swallowed (the setting was off, the tap was
    /// down, the monitor was stopped) belongs to whoever got the press, so it passes through instead of leaving
    /// that app with a key it never saw go down.
    private var swallowedPlaybackKeys: Set<PlaybackKey> = []

    /// CGEventTaps are per-session; wake leaves them enabled-but-inert.
    private var workspaceObservers: [NSObjectProtocol] = []

    var onRunLoopSourceRemoved: (() -> Void)?

    /// Optional coordinator notified on every volume/mute key event so the menu bar icon
    /// can flash the current device's transport symbol. Wired by FineTuneApp after init.
    var iconCoordinator: MediaKeyIconFlashing?

    /// Plays the system volume-feedback pop on volume key steps. Wired by FineTuneApp after init.
    var feedbackPlayer: VolumeFeedbackPlayer?

    /// Where the play/pause, next and previous keys go. Wired by DeciApp after init. The monitor swallows those keys
    /// whether or not one is wired.
    var playbackKeyHandler: PlaybackKeyHandling?

    init(
        decoder: any MediaKeyEventDecoding,
        audioEngine: AudioEngine,
        settingsManager: SettingsManager,
        accessibility: any AccessibilityTrustProviding,
        hudController: MediaKeyHUDPresenting,
        popupVisibility: PopupVisibilityService,
        mediaKeyStatus: MediaKeyStatus,
        volumeKeyRecorder: VolumeKeyRecorder
    ) {
        self.decoder = decoder
        self.audioEngine = audioEngine
        self.settingsManager = settingsManager
        self.accessibility = accessibility
        self.hudController = hudController
        self.popupVisibility = popupVisibility
        self.mediaKeyStatus = mediaKeyStatus
        self.volumeKeyRecorder = volumeKeyRecorder
        subscribeToWorkspaceLifecycle()
    }

    isolated deinit {
        // C callback holds an unretained pointer to self; runloop source must not outlive us.
        if let tap = tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        let nc = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers { nc.removeObserver(observer) }
    }

    // MARK: - Lifecycle

    /// Idempotent. No-op unless media keys are enabled and Accessibility is trusted.
    func start() {
        guard tap == nil else { return }
        guard settingsManager.appSettings.mediaKeyControlEnabled else {
            logger.debug("Media key control disabled in settings; tap not installed")
            return
        }
        guard accessibility.isTrusted else {
            logger.info("Accessibility not trusted; tap not installed")
            return
        }

        // NX_SYSDEFINED = 14 (from <IOLLEvent.h>); CGEventType has no Swift case.
        let mask = CGEventMask(1 << 14)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let newTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: mediaKeyTapCallback,
            userInfo: userInfo
        ) else {
            logger.error("CGEvent.tapCreate returned nil — media keys will not be intercepted")
            mediaKeyStatus.isOffline = true
            return
        }

        let source = CFMachPortCreateRunLoopSource(nil, newTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)

        self.tap = newTap
        self.runLoopSource = source
        self.mediaKeyStatus.isOffline = false
        logger.info("Media key tap installed")
    }

    /// Reconciles tap state against settings + Accessibility trust. Idempotent.
    func reconcile() {
        if settingsManager.appSettings.mediaKeyControlEnabled && accessibility.isTrusted {
            // Post-regrant taps can come up inert; arm a probe to surface that to the user.
            let wasOffline = (tap == nil)
            start()
            if wasOffline && tap != nil {
                armGhostTapProbe()
            }
        } else {
            cancelGhostTapProbe()
            stop()
        }
    }

    // MARK: - Workspace lifecycle (sleep/wake, session)

    /// Re-enable on wake/session-activate; disable on sleep/deactivate.
    private func subscribeToWorkspaceLifecycle() {
        let nc = NSWorkspace.shared.notificationCenter
        func add(_ name: Notification.Name, _ handler: @escaping @MainActor () -> Void) {
            let token = nc.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { handler() }
            }
            workspaceObservers.append(token)
        }
        add(NSWorkspace.didWakeNotification) { [weak self] in self?.handleWake() }
        add(NSWorkspace.sessionDidBecomeActiveNotification) { [weak self] in self?.handleWake() }
        add(NSWorkspace.willSleepNotification) { [weak self] in self?.handleSuspend() }
        add(NSWorkspace.sessionDidResignActiveNotification) { [weak self] in self?.handleSuspend() }
    }

    private func handleWake() {
        guard let tap else {
            reconcile()
            return
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        logger.info("Media key tap re-enabled after wake / session activation")
        armGhostTapProbe()
    }

    private func handleSuspend() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        logger.info("Media key tap disabled for sleep / session resign")
    }

    // MARK: - Ghost-tap probe

    /// Checks `tapIsEnabled` ~1.5s after install; marks offline if the kernel dropped it.
    private func armGhostTapProbe() {
        cancelGhostTapProbe()
        ghostTapProbeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled, let self, let tap = self.tap else { return }
            if !CGEvent.tapIsEnabled(tap: tap) {
                self.logger.error("Ghost-tap probe: tap reports disabled after regrant/wake — marking offline")
                self.mediaKeyStatus.isOffline = true
            }
            self.ghostTapProbeTask = nil
        }
    }

    private func cancelGhostTapProbe() {
        ghostTapProbeTask?.cancel()
        ghostTapProbeTask = nil
    }

    /// Tears down the tap + runloop source. Must be called before dealloc.
    func stop() {
        disableWatchdogTask?.cancel()
        disableWatchdogTask = nil
        watchdogOpen = false
        cancelGhostTapProbe()
        forgetPressRoutes()

        if let tap = tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            onRunLoopSourceRemoved?()
        }
        tap = nil
        runLoopSource = nil
        logger.info("Media key tap removed")
    }

    // MARK: - Event handling

    /// Applies a decoded `MediaKeyEvent` to the default output device, stepping by the row that fits the
    /// modifiers `held` with the key. `stepping` names the row instead, for a repeat that keeps the row of its
    /// press after the modifiers changed; `held` still decides the feedback pop's Shift and Option.
    func handle(_ event: MediaKeyEvent, held: VolumeKeyCombo = [], stepping row: VolumeKeyBinding? = nil) {
        let volumeMonitor = audioEngine.deviceVolumeMonitor
        let deviceID = volumeMonitor.defaultDeviceID
        guard deviceID.isValid else {
            logger.debug("Ignoring media key: no valid default output device")
            return
        }
        let tier = volumeMonitor.outputVolumeBackend(for: deviceID)
        let deviceName = audioEngine.deviceMonitor.outputDevices.first { $0.id == deviceID }?.name ?? ""
        let rowCombo = row?.combo ?? held
        let matched = settingsManager.appSettings.volumeKeyBinding(for: rowCombo)?.combo ?? []
        let modifiers = VolumeKeyModifiers(held: held, matched: matched)
        handleCore(
            event: event,
            deviceID: deviceID,
            tier: tier,
            deviceName: deviceName,
            currentVolume: volumeMonitor.volumes[deviceID] ?? 0,
            currentMute: volumeMonitor.muteStates[deviceID] ?? false,
            setVolume: { id, vol in volumeMonitor.setVolume(for: id, to: vol) },
            setMute:   { id, mute in volumeMonitor.setMute(for: id, to: mute) },
            playFeedback: { gain in
                self.feedbackPlayer?.requestFeedback(
                    gain: gain,
                    shiftHeld: modifiers.feedbackShiftHeld,
                    optionHeld: modifiers.feedbackOptionHeld
                )
            },
            held: rowCombo
        )
    }

    /// `.ddc` tier coalesces repeats to an 80 ms floor; hardware/software pass them through.
    /// Mute repeats are dropped upstream. Stepping operates on slider-position, by the percent of the row
    /// that fits `held`; a volume key no row fits does nothing here. HUD receives the slider fraction so it
    /// always matches the popup device row.
    func handleCore(
        event: MediaKeyEvent,
        deviceID: AudioDeviceID,
        tier: VolumeControlTier,
        deviceName: String,
        currentVolume: Float,
        currentMute: Bool,
        setVolume: (AudioDeviceID, Float) -> Void,
        setMute: (AudioDeviceID, Bool) -> Void,
        playFeedback: (Float) -> Void = { _ in },
        held: VolumeKeyCombo = []
    ) {
        let shouldShowHUD = !popupVisibility.isVisible
        let sliderDelta = settingsManager.appSettings.sliderDelta(for: held)
        let currentSlider = VolumeMapping.sliderFraction(forSystemGain: currentVolume, tier: tier)

        switch event {
        case .volumeUp(let isRepeat):
            guard let sliderDelta else { return }
            if isRepeat && tier == .ddc && isDDCRepeatCoalesced() {
                logger.debug("DDC repeat coalesced")
                return
            }
            let nextSlider = VolumeMapping.snappedSliderStep(currentSlider + sliderDelta)
            let newVolume = VolumeMapping.systemGain(forSliderFraction: nextSlider, tier: tier)
            // Volume-up from muted unmutes (system HUD parity).
            if currentMute {
                setMute(deviceID, false)
            }
            setVolume(deviceID, newVolume)
            playFeedback(VolumeFeedback.gain(tier: tier, sliderFraction: nextSlider))
            if shouldShowHUD {
                hudController.show(sliderFraction: nextSlider, mute: false, deviceName: deviceName)
            }
            iconCoordinator?.flashDevice()

        case .volumeDown(let isRepeat):
            guard let sliderDelta else { return }
            if isRepeat && tier == .ddc && isDDCRepeatCoalesced() {
                logger.debug("DDC repeat coalesced")
                return
            }
            let nextSlider = VolumeMapping.snappedSliderStep(currentSlider - sliderDelta)
            let newVolume = VolumeMapping.systemGain(forSliderFraction: nextSlider, tier: tier)
            let willBeSilent = nextSlider <= 0.001
            // muted+audible → unmute; unmuted+silent → auto-mute (system HUD parity).
            if currentMute && !willBeSilent {
                setMute(deviceID, false)
            } else if !currentMute && willBeSilent {
                setMute(deviceID, true)
            }
            setVolume(deviceID, newVolume)
            playFeedback(VolumeFeedback.gain(tier: tier, sliderFraction: nextSlider))
            if shouldShowHUD {
                hudController.show(sliderFraction: nextSlider, mute: willBeSilent, deviceName: deviceName)
            }
            iconCoordinator?.flashDevice()

        case .muteToggle:
            let newMute = !currentMute
            setMute(deviceID, newMute)
            if shouldShowHUD {
                hudController.show(sliderFraction: currentSlider, mute: newMute, deviceName: deviceName)
            }
            iconCoordinator?.flashDevice()

        case .playback:
            // Transport keys go to `playbackKeyHandler` in `processMediaKey` and never change the volume.
            break
        }
    }

    /// `true` if this repeat falls inside the 80 ms floor and should be dropped.
    private func isDDCRepeatCoalesced() -> Bool {
        let now = DispatchTime.now()
        if let last = lastDDCRepeatTime {
            let deltaNs = now.uptimeNanoseconds &- last.uptimeNanoseconds
            if deltaNs < 80 * 1_000_000 { return true }
        }
        lastDDCRepeatTime = now
        return false
    }

    // MARK: - Tap-disabled watchdog

    /// Kernel disabled the tap. One-shot re-enable; second disable inside 5s marks offline.
    func handleTapDisabled() {
        // Presses may have gone by while the tap was off, so no remembered route or held key can be trusted for what
        // follows.
        forgetPressRoutes()

        // Runtime Accessibility revocation — tear down and let the permission card surface.
        // `isOffline` stays false here; it's reserved for kernel-stall ("Retry") scenarios.
        if !accessibility.isTrusted {
            logger.warning("Tap disabled and Accessibility no longer trusted — stopping tap")
            disableWatchdogTask?.cancel()
            disableWatchdogTask = nil
            watchdogOpen = false
            stop()
            accessibility.refresh()
            return
        }

        logger.info("Tap disabled by kernel — attempting re-enable")

        if watchdogOpen {
            // Second disable inside the 5s window — feature is offline.
            logger.error("Second tap-disable inside watchdog window; marking media keys offline")
            mediaKeyStatus.isOffline = true
            disableWatchdogTask?.cancel()
            disableWatchdogTask = nil
            watchdogOpen = false
            return
        }

        watchdogOpen = true
        disableWatchdogTask?.cancel()
        disableWatchdogTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.watchdogOpen = false
            self?.disableWatchdogTask = nil
        }

        if let tap = tap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    // MARK: - Callback bridge

    /// Returns `true` if the caller should swallow the event.
    fileprivate func processSystemDefined(_ cgEvent: CGEvent) -> Bool {
        guard let nsEvent = NSEvent(cgEvent: cgEvent) else { return false }
        return processSystemDefined(
            subtype: Int(nsEvent.subtype.rawValue),
            data1: nsEvent.data1,
            held: VolumeKeyCombo(flags: cgEvent.flags)
        )
    }

    /// The tap's decision for a system-defined event, from the fields it reads. `true` swallows the event.
    func processSystemDefined(subtype: Int, data1: Int, held: VolumeKeyCombo) -> Bool {
        // Pass through if disabled mid-race; never silently eat another app's media keys. What is left of a held
        // transport key goes with it, so the setting coming back on does not pair a later key-up with a press from
        // before.
        guard settingsManager.appSettings.mediaKeyControlEnabled else {
            swallowedPlaybackKeys.removeAll()
            return false
        }
        // Subtype 8 is the media-key channel; aux-button / brightness are pass-through.
        guard subtype == 8 else { return false }
        guard let mediaEvent = decoder.decode(data1: data1) else { return false }
        return processMediaKey(mediaEvent, held: held)
    }

    /// Decides what a decoded key does and returns `true` if the caller should swallow it. While a keybind row
    /// is recording, a volume key is that recording and changes no volume. A volume key no row fits is left
    /// alone, not swallowed, so macOS makes its own change. Mute has no combos and is always handled. The
    /// play/pause, next and previous keys are swallowed from their fresh press until its key-up, so macOS never acts
    /// on them (F8 would otherwise launch Apple Music); a repeat or key-up with no swallowed press before it passes
    /// through. The verdict is returned at once and the handler hears the swallowed phases on the next turn of the main
    /// queue, so the tap callback never waits on routing, Chrome or the player. They stay out of the volume HUD's
    /// observations.
    func processMediaKey(_ event: MediaKeyEvent, held: VolumeKeyCombo) -> Bool {
        var stepping: VolumeKeyBinding?
        switch event {
        case .volumeUp(let isRepeat), .volumeDown(let isRepeat):
            if volumeKeyRecorder.capture(held, isRepeat: isRepeat) {
                hudController.swallowObserved()
                return true
            }
            guard let row = steppingRow(for: event, held: held) else {
                hudController.passThroughObserved()
                return false
            }
            stepping = row
        case .muteToggle:
            break
        case .playback(let key, let phase):
            guard swallowsPlayback(key, phase) else { return false }
            deliverPlayback(key, phase)
            return true
        }
        hudController.swallowObserved()
        handle(event, held: held, stepping: stepping)
        return true
    }

    // MARK: - Transport keys

    /// Whether a transport key event is swallowed, and the bookkeeping of which keys are held. A fresh press is always
    /// taken; a repeat or key-up follows its press.
    private func swallowsPlayback(_ key: PlaybackKey, _ phase: PlaybackKeyPhase) -> Bool {
        switch phase {
        case .down:
            swallowedPlaybackKeys.insert(key)
            return true
        case .autoRepeat:
            return swallowedPlaybackKeys.contains(key)
        case .up:
            return swallowedPlaybackKeys.remove(key) != nil
        }
    }

    /// Hands a swallowed transport event to the handler on the next turn of the main queue. The main queue runs its
    /// blocks in order, so quick presses reach the handler in the order they were made.
    private func deliverPlayback(_ key: PlaybackKey, _ phase: PlaybackKeyPhase) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.playbackKeyHandler?.handle(key, phase: phase)
            }
        }
    }

    // MARK: - Key repeat routing

    /// The row a volume key steps by, or nil to leave the key to macOS.
    ///
    /// A fresh press is matched on the modifiers held and its route remembered per key. A repeat follows that
    /// route: after a handled press the modifiers held now are matched again, falling back to the pressed row when
    /// none fits; after a passed-through press it passes through, whatever is held by then. A repeat whose press
    /// was never seen is matched on the modifiers held, as a fresh press would be.
    private func steppingRow(for event: MediaKeyEvent, held: VolumeKeyCombo) -> VolumeKeyBinding? {
        let isUp: Bool
        let isRepeat: Bool
        switch event {
        case .volumeUp(let value): (isUp, isRepeat) = (true, value)
        case .volumeDown(let value): (isUp, isRepeat) = (false, value)
        case .muteToggle, .playback: return nil
        }
        let rows = settingsManager.appSettings.volumeKeyBindings
        let matched = rows.binding(matching: held)

        if isRepeat {
            switch isUp ? upRoute : downRoute {
            case .handled(let rowID)?: return matched ?? rows.first { $0.id == rowID }
            case .passedThrough?: return nil
            case nil: return matched
            }
        }

        let route: PressRoute = matched.map { .handled(rowID: $0.id) } ?? .passedThrough
        if isUp { upRoute = route } else { downRoute = route }
        return matched
    }

    private func forgetPressRoutes() {
        upRoute = nil
        downRoute = nil
        swallowedPlaybackKeys.removeAll()
    }
}

// MARK: - CGEventTap C callback

// Tap installs on `CFRunLoopGetMain()` so this runs on main; `assumeIsolated`
// preserves ordering against the next event (a Task-hop would reorder).
private let mediaKeyTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo = userInfo else {
        return Unmanaged.passUnretained(event)
    }
    let monitor = Unmanaged<MediaKeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated {
            monitor.handleTapDisabled()
        }
        return nil
    }

    // NX_SYSDEFINED = 14; no Swift case in CGEventType.
    guard type.rawValue == 14 else {
        return Unmanaged.passUnretained(event)
    }

    // CGEvent is a CF type without Swift's Sendable conformance, so wrap it for
    // the synchronous hop into MainActor — assumeIsolated runs inline on the
    // current (main) thread, no real cross-actor send happens.
    struct EventBox: @unchecked Sendable { let event: CGEvent }
    let box = EventBox(event: event)
    let shouldSwallow = MainActor.assumeIsolated {
        monitor.processSystemDefined(box.event)
    }
    return shouldSwallow ? nil : Unmanaged.passUnretained(event)
}
