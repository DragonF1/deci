import Foundation
import Observation

@Observable
@MainActor
final class ChromeExtensionManager: NSObject {
    static let shared = ChromeExtensionManager()
    
    var chromeTabs: [ChromeTab] = []
    /// False when Chrome has not granted Deci access to incognito windows.
    var incognitoAllowed: Bool = true
    /// False when the extension cannot read output device names (the one-time mic prompt
    /// is still pending). True until told otherwise: an older extension never says.
    var deviceAccess: Bool = true
    /// Whether the extension is answering. Updated by incoming messages and by the
    /// timeout that follows each `requestTabs()`.
    var connectionState: ChromeConnectionState = .unknown
    /// True once the extension has ever answered on this Mac. Without it, a user who never
    /// installed the optional extension would be told it is "not connected" on every open.
    private(set) var hasConnectedBefore: Bool = false

    /// Which tabs Deci wants. Set from the Chrome section in Settings; the extension is told
    /// with SET_TRACKING and the stored `chromeTabs` never holds a hidden tab.
    private(set) var tracking = ChromeTracking(tabs: true, incognito: false)
    var trackingTabs: Bool { tracking.tabs }
    var trackingIncognito: Bool { tracking.incognito }
    /// Whether the extension clicks "Switch" when YouTube Music asks to listen on this device.
    /// Restated with every request, so a change made while Chrome was closed still lands.
    private(set) var ytMusicAutoSwitch = true
    /// True while Deci's own YouTube Music player is playing. The extension is told "off" for as
    /// long as it is, so a YouTube Music tab cannot take the session over; the setting itself is untouched.
    private(set) var nativeMusicPlaying = false
    /// What the extension is actually told: the user's choice, unless native playback is on.
    var effectiveYTMusicAutoSwitch: Bool { ytMusicAutoSwitch && !nativeMusicPlaying }

    /// True when per-tab device choices exist that the extension cannot resolve yet
    /// because device names are unreadable.
    var needsDeviceAccess: Bool {
        !deviceAccess && chromeTabs.contains { !($0.deviceName ?? "").isEmpty || !$0.deviceNames.isEmpty }
    }

    /// True while the connected extension says it understands SET_TAB_DEVICES (TAB_LIST `multiDevice`, extension 1.8.0
    /// and later). An older extension never says, and is sent the single SET_TAB_DEVICE only.
    private(set) var supportsMultiDevice = false

    /// True while the engine's own Chrome row plays on two or more outputs. Its tap mirrors everything Chrome renders to
    /// each of them, so a tab the extension also sinks to several outputs would play twice on each. Set through
    /// `setEngineFansOutChrome`, never by the extension.
    private(set) var engineFansOutChrome = false

    /// What Deci's own tap of Chrome adds to each output it taps, by output device UID, as the engine last reported it
    /// (`setTapLatency`). Kept raw so a name that is learned later (`updateOutputDevices`) can still be sent.
    @ObservationIgnored private var tapLatencyByUID: [String: Double] = [:]
    /// The SET_TAP_LATENCY entries last queued, in the form they go out: names and whole milliseconds, by name.
    @ObservationIgnored private var lastQueuedTapLatency: [TapLatencyEntry] = []

    /// One output's entry in SET_TAP_LATENCY.
    private struct TapLatencyEntry: Equatable {
        var deviceName: String
        var milliseconds: Int
    }

    /// Whether a tab may play on several outputs at once: the extension can do it and the engine is not already doing it
    /// for the whole Chrome row. The picker's Multi option and the tab's note read this; `supportsMultiDevice` stays the
    /// capability alone.
    var allowsTabMultiDevice: Bool { supportsMultiDevice && !engineFansOutChrome }

    /// The output devices of every captured tab that plays on two or more of them at once; empty when none does.
    /// Read-only for the UI, assigned only when the set really changes (see `refreshMultiOutputs`).
    private(set) var multiOutputDeviceUIDs: Set<String> = []

    /// The output devices the UI last reported (`updateOutputDevices`): what a UID means, in list order. Not observed.
    @ObservationIgnored private var outputDevices: [AudioDevice] = []
    @ObservationIgnored private var defaultOutputUID: String?
    /// Every device name seen so far by UID, so a picked device that was unplugged since keeps its name.
    @ObservationIgnored private var nameByUID: [String: String] = [:]

    /// How long GET_TABS may go unanswered before the extension counts as disconnected.
    static let connectionTimeout: TimeInterval = 2.5

    /// Clock for connection tracking. Tests replace it to avoid real waiting.
    @ObservationIgnored var connectionClock: () -> Date = { Date() }
    @ObservationIgnored private var lastRequestAt: Date?
    @ObservationIgnored private var lastMessageAt: Date?
    @ObservationIgnored private var connectionTimer: Timer?
    /// Set once the permission page was opened, so picking devices does not reopen it
    /// every time. Cleared when the extension reports access.
    @ObservationIgnored private var devicePermissionRequested = false

    /// How long a local change shields its tab from being overwritten by a TAB_LIST that
    /// was built before the extension had applied it.
    private static let pendingWindow: TimeInterval = 1.5
    @ObservationIgnored private var pendingUntil: [Int: Date] = [:]
    /// Handshake bookkeeping: the last `tracking` echo seen in a TAB_LIST (nil = none), and
    /// whether the mismatch it showed was already answered with a SET_TRACKING.
    @ObservationIgnored private var lastTrackingEcho: ChromeTracking?
    @ObservationIgnored private var trackingMismatchAnswered = false
    @ObservationIgnored private let persistsConnection: Bool
    private static let hasConnectedKey = "chromeExtensionHasConnected"
    
    /// `observeHost: false` builds an instance that never listens to DeciHost, so tests
    /// do not share state with `shared`.
    init(observeHost: Bool = true) {
        persistsConnection = observeHost
        super.init()
        guard observeHost else { return }
        hasConnectedBefore = UserDefaults.standard.bool(forKey: Self.hasConnectedKey)
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleChromeNotification(_:)),
            name: NSNotification.Name("com.abraham.Deci.FromChrome"),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
    }
    
    @objc nonisolated private func handleChromeNotification(_ notification: Notification) {
        let message = notification.object as? String
        Task { @MainActor in
            self.handleChromeMessageString(message)
        }
    }
    
    func handleChromeMessageString(_ messageString: String?) {
        guard let messageString,
              let data = messageString.data(using: .utf8) else { return }
              
        do {
            guard let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                  let type = json["type"] as? String else { return }

            // Any message proves the extension is alive, whatever its type.
            noteMessageReceived()

            if type == "TAB_LIST", let rawTabs = json["tabs"] as? [[String: Any]] {
                let parsed = Self.parseTabList(json)
                if incognitoAllowed != parsed.incognitoAllowed {
                    incognitoAllowed = parsed.incognitoAllowed
                }
                if deviceAccess != parsed.deviceAccess {
                    deviceAccess = parsed.deviceAccess
                }
                if parsed.deviceAccess {
                    devicePermissionRequested = false
                }
                // Only an extension that says so understands SET_TAB_DEVICES; an older one omits the marker.
                let multiCapable = json["multiDevice"] as? Bool ?? false
                if supportsMultiDevice != multiCapable {
                    supportsMultiDevice = multiCapable
                }
                answerTrackingEcho(parsed.tracking)

                let now = Date()
                let previous = chromeTabs
                let newTabs = adoptingExtensionMultiState(Self.merge(
                    existing: previous,
                    incoming: Self.visibleTabs(parsed.tabs, tracking: tracking),
                    pendingUntil: pendingUntil,
                    now: now
                ))
                pendingUntil = pendingUntil.filter { $0.value > now }

                // A new song usually means a new duration, so refresh media state right away.
                for tab in newTabs {
                    if let old = previous.first(where: { $0.id == tab.id }),
                       !old.title.isEmpty, !tab.title.isEmpty, old.title != tab.title {
                        requestMediaState(tabId: tab.id)
                    }
                }
                
                if newTabs != self.chromeTabs {
                    self.chromeTabs = newTabs
                }
                refreshMultiOutputs()
            } else if type == "MEDIA_STATE", let tabId = json["tabId"] as? Int {
                let paused = json["paused"] as? Bool ?? false
                let currentTime = (json["currentTime"] as? NSNumber)?.doubleValue ?? 0
                let duration = (json["duration"] as? NSNumber)?.doubleValue ?? 0
                
                guard let index = self.chromeTabs.firstIndex(where: { $0.id == tabId }) else { return }
                // A write into the array notifies every reader of `chromeTabs`, equal value or not, so a reply that
                // changes nothing (a paused tab asked again) must not reach it.
                if let updated = Self.applyingMediaState(
                    to: self.chromeTabs[index], paused: paused, currentTime: currentTime, duration: duration, now: Date()
                ) {
                    self.chromeTabs[index] = updated
                }
            }
        } catch {
            // parsing error ignored
        }
    }
    
    /// The tab after a MEDIA_STATE reply, or nil when the reply changes nothing. Pure: callers pass the clock.
    ///
    /// `lastSyncedAt` only marks that the tab has been synced (nothing reads its value, and the song baseline is taken on
    /// the first reply), so it moves when the reply changes something, and is set by the first reply whatever it holds.
    static func applyingMediaState(
        to tab: ChromeTab,
        paused: Bool,
        currentTime: Double,
        duration: Double,
        now: Date
    ) -> ChromeTab? {
        var updated = tab
        if tab.lastSyncedAt == nil {
            updated.songBaselineCurrentTime = currentTime
        }
        updated.paused = paused
        updated.currentTime = currentTime
        updated.duration = duration
        guard updated != tab || tab.lastSyncedAt == nil else { return nil }
        updated.lastSyncedAt = now
        return updated
    }

    /// Parses a TAB_LIST message. Pure: no state, no side effects.
    static func parseTabList(_ json: [String: Any]) -> (tabs: [ChromeTab], incognitoAllowed: Bool, deviceAccess: Bool, tracking: ChromeTracking?) {
        let incognitoAllowed = json["incognitoAllowed"] as? Bool ?? true
        // Missing means an older extension that routes nothing and never asks for access.
        let deviceAccess = json["deviceAccess"] as? Bool ?? true
        // The extension's stored switches. Missing or incomplete means an older extension.
        var echo: ChromeTracking?
        if let raw = json["tracking"] as? [String: Any],
           let tabs = raw["tabs"] as? Bool,
           let incognito = raw["incognito"] as? Bool {
            echo = ChromeTracking(tabs: tabs, incognito: incognito)
        }
        let rawTabs = json["tabs"] as? [[String: Any]] ?? []

        var tabs: [ChromeTab] = []
        for raw in rawTabs.prefix(maxTabs) {
            guard let id = raw["id"] as? Int else { continue }
            let title = (raw["title"] as? String) ?? ""
            let rawVolume = (raw["volume"] as? NSNumber)?.floatValue ?? 1.0
            let volume = rawVolume.isFinite ? min(max(rawVolume, 0), 1) : 1.0
            let boost = (raw["boost"] as? NSNumber).flatMap { BoostLevel(rawValue: $0.floatValue) } ?? .x1

            var eqSettings = EQSettings()
            if let eqBandsArray = raw["eqBands"] as? [NSNumber] {
                eqSettings = EQSettings(bandGains: eqBandsArray.map { $0.floatValue }, isEnabled: true)
            }
            // The extension reports "" for "follow the system default".
            let deviceName = (raw["deviceName"] as? String).flatMap { $0.isEmpty ? nil : $0 }

            var tab = ChromeTab(
                id: id,
                title: String(title.prefix(maxTitleLength)),
                volume: volume,
                favIconUrl: sanitizedFaviconURL(raw["favIconUrl"] as? String),
                isAudible: raw["isAudible"] as? Bool ?? false,
                eqSettings: eqSettings,
                deviceName: deviceName
            )
            tab.boost = boost
            tab.isMuted = raw["muted"] as? Bool ?? false
            tab.isIncognito = raw["incognito"] as? Bool ?? false
            tab.control = ChromeTabControl(wireValue: raw["control"] as? String, captured: raw["captured"] as? Bool ?? false)
            tab.deviceStatus = ChromeTabDeviceStatus(wireValue: raw["deviceStatus"] as? String)
            tab.deviceNames = nameList(raw["deviceNames"])
            tab.missingDeviceNames = nameList(raw["deviceMissing"])
            tabs.append(tab)
        }
        return (tabs, incognitoAllowed, deviceAccess, echo)
    }

    /// The most output names read from one tab. The extension keeps at most 8; this only bounds a hostile message.
    private static let maxDeviceNames = 16

    /// A list of output names off the wire: strings only, no empties, no repeats, in order. Anything else is no list.
    private static func nameList(_ value: Any?) -> [String] {
        guard let raw = value as? [Any] else { return [] }
        var names: [String] = []
        for case let name as String in raw where !name.isEmpty && !names.contains(name) {
            names.append(name)
            if names.count == maxDeviceNames { break }
        }
        return names
    }

    /// The tabs the user wants to see: none when tabs are off, no incognito ones when
    /// incognito is off. Pure.
    static func visibleTabs(_ tabs: [ChromeTab], tracking: ChromeTracking) -> [ChromeTab] {
        guard tracking.tabs else { return [] }
        return tracking.incognito ? tabs : tabs.filter { !$0.isIncognito }
    }

    /// Merges a fresh TAB_LIST into the current tabs. Pure: callers pass the clock.
    ///
    /// The extension is the source of truth for volume, boost, mute, EQ and device, except
    /// for a tab with a local change inside its pending window (the extension has not seen
    /// it yet). Media state (paused, position) only ever comes from MEDIA_STATE messages,
    /// so it is carried over from the existing tab. `deviceStatus` is extension-owned
    /// state with no local counterpart, so it is always adopted, pending or not. The output list
    /// (`deviceNames`, `missingDeviceNames`) follows the device choice: local while pending, the
    /// extension's after. The picker's own state (`deviceSelectionMode`, `selectedDeviceUIDs`, `multiSince`,
    /// `preMultiDeviceName`) exists only here and is always carried over.
    static func merge(
        existing: [ChromeTab],
        incoming: [ChromeTab],
        pendingUntil: [Int: Date],
        now: Date
    ) -> [ChromeTab] {
        let existingByID = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return incoming.map { fresh in
            guard let old = existingByID[fresh.id] else { return fresh }
            var tab = fresh

            if tab.title.isEmpty {
                tab.title = old.title
            }
            if tab.favIconUrl == nil {
                tab.favIconUrl = old.favIconUrl
            }

            tab.deviceSelectionMode = old.deviceSelectionMode
            tab.selectedDeviceUIDs = old.selectedDeviceUIDs
            tab.multiSince = old.multiSince
            tab.preMultiDeviceName = old.preMultiDeviceName
            // Cleared once the extension itself reports one output for the tab.
            tab.revertAwaitsExtension = old.revertAwaitsExtension && !fresh.deviceNames.isEmpty

            if let until = pendingUntil[tab.id], until > now {
                tab.volume = old.volume
                tab.boost = old.boost
                tab.isMuted = old.isMuted
                tab.eqSettings = old.eqSettings
                tab.deviceName = old.deviceName
                tab.deviceNames = old.deviceNames
                tab.missingDeviceNames = old.missingDeviceNames
                // A status for a device the user has already moved away from is stale.
                if fresh.deviceName != old.deviceName || fresh.deviceNames != old.deviceNames {
                    tab.deviceStatus = old.deviceStatus
                }
            } else if !old.eqSettings.isEnabled, fresh.eqSettings.bandGains.allSatisfy({ $0 == 0 }) {
                // A bypassed EQ is sent as a flat curve; keep the bands the user dialled in.
                tab.eqSettings = old.eqSettings
            }

            tab.paused = old.paused
            tab.currentTime = old.currentTime
            tab.duration = old.duration
            tab.lastSyncedAt = old.lastSyncedAt

            let titleChanged = !old.title.isEmpty
                && !fresh.title.isEmpty
                && old.title != fresh.title
            tab.songBaselineCurrentTime = titleChanged
                ? old.currentTime
                : old.songBaselineCurrentTime
            return tab
        }
    }

    private static let maxTabs = 200
    private static let maxTitleLength = 300
    private static let maxFaviconLength = 64 * 1024

    private static func sanitizedFaviconURL(_ string: String?) -> String? {
        guard let string, !string.isEmpty, string.count <= maxFaviconLength,
              let url = URL(string: string) else { return nil }
        switch url.scheme?.lowercased() {
        case "https", "http":
            return string
        case "data":
            return string.lowercased().hasPrefix("data:image/") ? string : nil
        default:
            return nil
        }
    }


    private var pendingMessages: [String: [String: Any]] = [:]
    private var messageTimer: Timer?

    private func queueMessage(_ message: [String: Any]) {
        let type = message["type"] as? String ?? "UNKNOWN"
        let tabId = message["tabId"] as? Int ?? 0
        let key = "\(type)_\(tabId)"
        pendingMessages[key] = message
        
        if messageTimer == nil {
            messageTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.flushMessages() }
            }
        }
    }
    
    /// Sends everything queued so far. The batch timer calls this; tests call it to skip the wait.
    func flushMessages() {
        messageTimer?.invalidate()
        messageTimer = nil
        // SET_TRACKING goes first: the TAB_LIST that answers a GET_TABS sent with it should
        // already follow the new switches. The rest has no order.
        let messages = pendingMessages.values
        pendingMessages.removeAll()
        let isTracking: ([String: Any]) -> Bool = { $0["type"] as? String == "SET_TRACKING" }
        for msg in messages where isTracking(msg) {
            sendMessage(msg)
        }
        for msg in messages where !isTracking(msg) {
            sendMessage(msg)
        }
    }

    /// Sets which tabs Deci tracks. Hides them at once and tells the extension to stop
    /// sending them (it keeps each tab's sound settings). Always sends, so callers that
    /// only mean "make sure" can call it freely.
    func setTracking(tabs: Bool, incognito: Bool) {
        tracking = ChromeTracking(tabs: tabs, incognito: incognito)
        let visible = Self.visibleTabs(chromeTabs, tracking: tracking)
        if visible != chromeTabs {
            chromeTabs = visible
            refreshMultiOutputs()
        }
        // A new wish deserves a fresh answer to the next mismatching TAB_LIST.
        trackingMismatchAnswered = false
        queueTracking()
    }

    private func queueTracking() {
        queueMessage([
            "type": "SET_TRACKING",
            "tabs": tracking.tabs,
            "incognito": tracking.incognito
        ])
    }

    /// Stores the YouTube Music auto-switch and tells the extension when what it acts on changed.
    func setYTMusicAutoSwitch(_ enabled: Bool) {
        let before = effectiveYTMusicAutoSwitch
        ytMusicAutoSwitch = enabled
        if effectiveYTMusicAutoSwitch != before { queueOptions() }
    }

    /// Called when Deci's Music player starts or stops playing. Sends only when the effective value changed.
    func setNativeMusicPlaying(_ playing: Bool) {
        guard playing != nativeMusicPlaying else { return }
        let before = effectiveYTMusicAutoSwitch
        nativeMusicPlaying = playing
        if effectiveYTMusicAutoSwitch != before { queueOptions() }
    }

    private func queueOptions() {
        queueMessage([
            "type": "SET_OPTIONS",
            "ytmAutoSwitch": effectiveYTMusicAutoSwitch
        ])
    }

    /// Compares the extension's reported switches with ours and repeats SET_TRACKING when
    /// they differ (or an older build reports none), once per mismatch: again only after the
    /// report changes, a match in between, a fresh `requestTabs()` or a new wish.
    private func answerTrackingEcho(_ echo: ChromeTracking?) {
        defer { lastTrackingEcho = echo }
        if echo == tracking {
            trackingMismatchAnswered = false
            return
        }
        if echo != lastTrackingEcho {
            trackingMismatchAnswered = false
        }
        guard !trackingMismatchAnswered else { return }
        trackingMismatchAnswered = true
        queueTracking()
    }

    private func markPending(_ tabId: Int) {
        pendingUntil[tabId] = Date().addingTimeInterval(Self.pendingWindow)
    }

    /// Volume and boost travel together: the extension multiplies them, so each message
    /// carries the full state and last-wins batching is safe.
    private func queueVolume(for tab: ChromeTab) {
        queueMessage([
            "type": "SET_TAB_VOLUME",
            "tabId": tab.id,
            "volume": tab.volume,
            "boost": tab.boost.rawValue
        ])
    }

    /// Sets the tab's volume. A tab that is not captured has plain control only, a level in 0...1, so that is what is
    /// kept and sent; the boost it may hold for a later capture goes along untouched.
    func setTabVolume(tabId: Int, volume: Float) {
        guard let index = chromeTabs.firstIndex(where: { $0.id == tabId }) else { return }
        chromeTabs[index].volume = chromeTabs[index].isCaptured ? volume : ChromeTab.plainVolume(volume)
        markPending(tabId)
        queueVolume(for: chromeTabs[index])
    }

    func setTabBoost(tabId: Int, boost: BoostLevel) {
        guard let index = chromeTabs.firstIndex(where: { $0.id == tabId }) else { return }
        chromeTabs[index].boost = boost
        markPending(tabId)
        queueVolume(for: chromeTabs[index])
    }

    func setTabEQ(tabId: Int, eqSettings: EQSettings) {
        if let index = chromeTabs.firstIndex(where: { $0.id == tabId }) {
            chromeTabs[index].eqSettings = eqSettings
            markPending(tabId)
            queueMessage([
                "type": "SET_TAB_EQ",
                "tabId": tabId,
                "eqBands": eqSettings.isEnabled ? eqSettings.clampedGains : Array(repeating: Float(0), count: 10)
            ])
        }
    }

    /// Puts the tab on one output (nil = follow the system default). Ends any multi-output list the tab was playing.
    func setTabDevice(tabId: Int, deviceName: String?) {
        if let index = chromeTabs.firstIndex(where: { $0.id == tabId }) {
            var tab = chromeTabs[index]
            tab.deviceName = deviceName
            // The list is over: the extension drops it on this message.
            tab.deviceNames = []
            tab.missingDeviceNames = []
            // The old status belongs to the old device; show "pending" until the extension reports.
            tab.deviceStatus = (deviceName ?? "").isEmpty ? .defaultOutput : .pending
            chromeTabs[index] = tab
            markPending(tabId)
            // Both messages are last-wins per tab but batched apart, so a list queued just before would otherwise
            // be sent after this one and win.
            pendingMessages["SET_TAB_DEVICES_\(tabId)"] = nil
            queueMessage([
                "type": "SET_TAB_DEVICE",
                "tabId": tabId,
                "deviceName": deviceName ?? ""
            ])
            requestDevicePermissionIfNeeded(for: deviceName)
            refreshMultiOutputs()
        }
    }

    /// Without device names the extension cannot honour the choice. Open the
    /// permission page once instead of leaving the user to find the button.
    private func requestDevicePermissionIfNeeded(for deviceName: String?) {
        if let deviceName, !deviceName.isEmpty, !deviceAccess, !devicePermissionRequested {
            openDevicePermission()
        }
    }

    // MARK: Multi-output

    /// Tells the manager which output devices exist (in the order the picker lists them) and which one is the system
    /// default. The manager maps UIDs to the names the extension matches on, seeds a tab's first flip to Multi, and
    /// works out `multiOutputDeviceUIDs` from it. Cheap to repeat: nothing changes unless the list or the default does.
    func updateOutputDevices(_ devices: [AudioDevice], defaultDeviceUID: String?) {
        let sameList = devices.count == outputDevices.count
            && zip(devices, outputDevices).allSatisfy { $0.uid == $1.uid && $0.name == $1.name }
        guard !sameList || defaultDeviceUID != defaultOutputUID else { return }

        outputDevices = devices
        defaultOutputUID = defaultDeviceUID
        for device in devices { nameByUID[device.uid] = device.name }
        queueTapLatencyIfChanged()

        // A list adopted before the devices were known has no UIDs yet; they can be read off its names now.
        var tabs = chromeTabs
        var changed = false
        for index in tabs.indices {
            let tab = tabs[index]
            guard tab.deviceSelectionMode == .multi, tab.selectedDeviceUIDs.isEmpty, !tab.deviceNames.isEmpty else { continue }
            let uids = outputUIDs(forNames: tab.deviceNames)
            if !uids.isEmpty {
                tabs[index].selectedDeviceUIDs = uids
                changed = true
            }
        }
        if changed { chromeTabs = tabs }
        refreshMultiOutputs()
    }

    /// Tells the manager whether the engine's Chrome row plays on several outputs (see `engineFansOutChrome`). While it
    /// does, a tab on several outputs is pulled back to its first one, the ticks kept for later; when it stops, such a
    /// tab gets its ticked outputs back. Cheap to repeat: nothing is sent unless the state changes.
    func setEngineFansOutChrome(_ fansOut: Bool) {
        guard fansOut != engineFansOutChrome else { return }
        engineFansOutChrome = fansOut
        for tab in chromeTabs where tab.deviceSelectionMode == .multi {
            if fansOut {
                guard tab.deviceNames.count > 1 else { continue }
                setTabDevice(tabId: tab.id, deviceName: tab.deviceNames.first)
            } else if supportsMultiDevice, tab.selectedDeviceUIDs.count > 1, tab.deviceNames.count < 2 {
                setTabDevices(tabId: tab.id, deviceUIDs: tab.selectedDeviceUIDs)
            }
        }
    }

    // MARK: Tap latency

    /// The delay Deci's own Chrome tap adds to the outputs it taps, by output device UID, as the engine measured it; an
    /// empty map means none applies. Sent to the extension as a tab-less SET_TAP_LATENCY, which it adds to those outputs'
    /// latency when it lines Chrome's outputs up. Each message replaces the previous one. A UID with no known name is
    /// dropped (the extension matches on the names routing messages use), seconds are rounded to a millisecond, and
    /// nothing is queued unless the result differs from what was queued last. Cheap to repeat.
    func setTapLatency(_ byUID: [String: Double]) {
        tapLatencyByUID = byUID
        queueTapLatencyIfChanged()
    }

    /// What `setTapLatency` was last given, as it goes out: one entry per device name (the larger value when two
    /// devices share one), whole milliseconds, sorted by name so the message is stable. Entries that are not a positive
    /// finite delay up to the extension's 0.5 s limit, or round to 0 ms, are left out.
    private func tapLatencyEntries() -> [TapLatencyEntry] {
        var millisecondsByName: [String: Int] = [:]
        for (uid, seconds) in tapLatencyByUID {
            guard seconds.isFinite, seconds > 0, seconds <= Self.maxTapLatencySeconds,
                  let name = outputName(forUID: uid) else { continue }
            let milliseconds = Int((seconds * 1000).rounded())
            guard milliseconds > 0 else { continue }
            millisecondsByName[name] = max(millisecondsByName[name] ?? 0, milliseconds)
        }
        return millisecondsByName
            .map { TapLatencyEntry(deviceName: $0.key, milliseconds: $0.value) }
            .sorted { $0.deviceName < $1.deviceName }
    }

    /// The most the extension accepts for one entry; it drops anything larger.
    private static let maxTapLatencySeconds: Double = 0.5

    private func queueTapLatencyIfChanged() {
        let entries = tapLatencyEntries()
        guard entries != lastQueuedTapLatency else { return }
        lastQueuedTapLatency = entries
        queueTapLatency(entries)
    }

    private func queueTapLatency(_ entries: [TapLatencyEntry]) {
        queueMessage([
            "type": "SET_TAP_LATENCY",
            "devices": entries.map { entry -> [String: Any] in
                ["deviceName": entry.deviceName, "seconds": Double(entry.milliseconds) / 1000]
            }
        ])
    }

    /// Puts the tab on every ticked output at once. The tab is in multi mode from here on. An empty selection, or one
    /// that names no known device, is recorded for the picker but sends nothing: the tab keeps playing where it is.
    /// An extension that does not know SET_TAB_DEVICES gets a plain SET_TAB_DEVICE for the first ticked device in
    /// list order, so the tab still reacts (on one output) instead of ignoring the tick. So does a tab with several
    /// ticks while the engine fans the Chrome row out, which already plays everything on all of them.
    func setTabDevices(tabId: Int, deviceUIDs: Set<String>) {
        guard let index = chromeTabs.firstIndex(where: { $0.id == tabId }) else { return }
        let names = outputNames(forUIDs: deviceUIDs)

        var tab = chromeTabs[index]
        if tab.deviceSelectionMode != .multi { tab.enterMulti(at: connectionClock()) }
        tab.deviceSelectionMode = .multi
        tab.selectedDeviceUIDs = deviceUIDs

        guard let first = names.first else {
            if tab != chromeTabs[index] { chromeTabs[index] = tab }
            return
        }
        guard supportsMultiDevice, !(engineFansOutChrome && names.count > 1) else {
            chromeTabs[index] = tab
            setTabDevice(tabId: tabId, deviceName: first)
            return
        }

        // The single choice (`deviceName`) stays: it is what flipping back to single restores.
        tab.deviceNames = names
        tab.missingDeviceNames = []
        tab.deviceStatus = .pending
        chromeTabs[index] = tab
        markPending(tabId)
        pendingMessages["SET_TAB_DEVICE_\(tabId)"] = nil
        queueMessage([
            "type": "SET_TAB_DEVICES",
            "tabId": tabId,
            "deviceNames": names
        ])
        for name in names { requestDevicePermissionIfNeeded(for: name) }
        refreshMultiOutputs()
    }

    /// Flips the tab between one output and several. The first flip to Multi ticks the device the tab plays on now (the
    /// default when it follows the default or its device is gone) and sends nothing: the tab does not move until a
    /// second device is ticked. Flipping back keeps the selection for next time and puts the tab back on its single choice
    /// (the one it had before Multi) when a list was playing or the fallback pin moved it.
    func setTabDeviceSelectionMode(tabId: Int, to mode: DeviceSelectionMode) {
        guard let index = chromeTabs.firstIndex(where: { $0.id == tabId }),
              chromeTabs[index].deviceSelectionMode != mode else { return }
        switch mode {
        case .multi:
            var tab = chromeTabs[index]
            tab.enterMulti(at: connectionClock())
            tab.deviceSelectionMode = .multi
            if tab.selectedDeviceUIDs.isEmpty {
                tab.selectedDeviceUIDs = seedSelection(for: tab)
            }
            chromeTabs[index] = tab
        case .single:
            // Same choice the disconnect revert uses. A tab entered by hand (`multiSince` set) goes back to what it
            // had before Multi, since the one-output fallbacks may have replaced `deviceName` with a tick. An
            // adopted tab (start unknown) has no record and keeps `deviceName`. Read both before `leaveMulti()`.
            let current = chromeTabs[index].deviceName
            let restored = chromeTabs[index].multiSince != nil ? chromeTabs[index].preMultiDeviceName : current
            let playingAList = !chromeTabs[index].deviceNames.isEmpty
            chromeTabs[index].deviceSelectionMode = .single
            chromeTabs[index].leaveMulti()
            if playingAList || (restored ?? "") != (current ?? "") {
                setTabDevice(tabId: tabId, deviceName: restored)
            }
        }
        refreshMultiOutputs()
    }

    /// An output device disconnected (not one that was never there at launch). Every tab in multi mode with that device
    /// ticked goes back to single right away, even when its other ticked devices are still connected. Under
    /// `MultiOutputRevert.rememberWindow` of entering Multi it returns to its pre-Multi single choice, else to System
    /// Audio and the old choice is cleared. A single choice that is itself away stays the choice: the extension handles a
    /// missing device in single mode. The ticks are kept, and nothing rejoins when the device returns. A message goes to
    /// the extension only when it has something to undo: a list was playing, or a cleared choice was a specific device.
    func outputDeviceDisconnected(uid: String) {
        let now = connectionClock()
        for tab in chromeTabs where MultiOutputRevert.disconnectAffects(
            mode: tab.deviceSelectionMode, selected: tab.selectedDeviceUIDs, uid: uid
        ) {
            let target = MultiOutputRevert.target(multiSince: tab.multiSince, now: now)
            let playingAList = !tab.deviceNames.isEmpty
            if let index = chromeTabs.firstIndex(where: { $0.id == tab.id }) {
                chromeTabs[index].deviceSelectionMode = .single
                chromeTabs[index].leaveMulti()
                chromeTabs[index].revertAwaitsExtension = playingAList
            }
            switch target {
            case .previousSingle:
                // The one-output fallbacks overwrote `deviceName` with a tick, so the choice from before Multi is the
                // one recorded when the tab entered it.
                let previous = tab.preMultiDeviceName
                if playingAList || (previous ?? "") != (tab.deviceName ?? "") {
                    setTabDevice(tabId: tab.id, deviceName: previous)
                }
            case .systemAudio:
                if playingAList || !(tab.deviceName ?? "").isEmpty { setTabDevice(tabId: tab.id, deviceName: nil) }
            }
        }
        refreshMultiOutputs()
    }

    /// What the first flip to Multi ticks: the device the tab is on, else the system default.
    private func seedSelection(for tab: ChromeTab) -> Set<String> {
        if let name = tab.deviceName, !name.isEmpty,
           let device = outputDevices.first(where: { $0.name == name }) {
            return [device.uid]
        }
        if let uid = defaultOutputUID, !uid.isEmpty { return [uid] }
        return []
    }

    /// The names of the ticked devices as the extension matches them: device-list order, one per name. A ticked device
    /// that left the list keeps the name it had (so a list holding it still names it), after the listed ones in UID
    /// order. A UID never seen is skipped.
    private func outputNames(forUIDs uids: Set<String>) -> [String] {
        var names: [String] = []
        for device in outputDevices where uids.contains(device.uid) && !names.contains(device.name) {
            names.append(device.name)
        }
        let listed = Set(outputDevices.map(\.uid))
        for uid in uids.subtracting(listed).sorted() {
            if let name = nameByUID[uid], !names.contains(name) { names.append(name) }
        }
        return names
    }

    /// The name of one device as `outputNames(forUIDs:)` gives it: its name in the current list, else the name it had
    /// when it was last listed. nil for a UID never seen.
    private func outputName(forUID uid: String) -> String? {
        outputDevices.first(where: { $0.uid == uid })?.name ?? nameByUID[uid]
    }

    /// The devices the names stand for in the current list (the first device of each name).
    private func outputUIDs(forNames names: [String]) -> Set<String> {
        Set(names.compactMap { name in outputDevices.first(where: { $0.name == name })?.uid })
    }

    /// A tab the extension already plays on a list of outputs, that this side has no multi record of (first sight, or
    /// the app restarted while Chrome kept going), is shown as multi with the devices those names are.
    private func adoptingExtensionMultiState(_ tabs: [ChromeTab]) -> [ChromeTab] {
        tabs.map { tab in
            guard tab.deviceSelectionMode == .single, !tab.deviceNames.isEmpty, !tab.revertAwaitsExtension else { return tab }
            var adopted = tab
            adopted.deviceSelectionMode = .multi
            if adopted.selectedDeviceUIDs.isEmpty {
                adopted.selectedDeviceUIDs = outputUIDs(forNames: tab.deviceNames)
            }
            return adopted
        }
    }

    /// Recomputes `multiOutputDeviceUIDs` and assigns it only when it differs, so readers are not woken by
    /// a volume change or a new song title. Called after every change to `chromeTabs` that could move it.
    private func refreshMultiOutputs() {
        let next = Self.multiOutputUIDs(tabs: chromeTabs, devices: outputDevices)
        if next != multiOutputDeviceUIDs {
            multiOutputDeviceUIDs = next
        }
    }

    /// The devices of every tab that plays on two or more outputs. Pure.
    ///
    /// Only a captured tab counts (Chrome plays any other as it always did), and only while its outputs are not known
    /// to have failed (`notFound` and `noAccess` mean it fell back to the default output, `default` that it has no
    /// list). Names the extension could not match do not count; fewer than two left means one output, not multi.
    /// A name no device in `devices` carries adds nothing to the set, but still counts as an output.
    static func multiOutputUIDs(tabs: [ChromeTab], devices: [AudioDevice]) -> Set<String> {
        var uids = Set<String>()
        for tab in tabs where tab.control == .capture {
            switch tab.deviceStatus {
            case .notFound, .noAccess, .defaultOutput: continue
            case .pending, .routed: break
            }
            let names = Set(tab.deviceNames).subtracting(tab.missingDeviceNames)
            guard names.count >= 2 else { continue }
            for name in names {
                if let device = devices.first(where: { $0.name == name }) { uids.insert(device.uid) }
            }
        }
        return uids
    }

    /// Asks the extension to open the page with the one-time mic prompt that unlocks
    /// output device names. Always sends: callers that want it once check first.
    func openDevicePermission() {
        devicePermissionRequested = true
        queueMessage(["type": "OPEN_DEVICE_PERMISSION"])
    }

    /// Sets mute explicitly. Volume is never touched, so unmuting returns to the same level.
    func setTabMuted(tabId: Int, muted: Bool) {
        guard let index = chromeTabs.firstIndex(where: { $0.id == tabId }) else { return }
        chromeTabs[index].isMuted = muted
        markPending(tabId)
        queueMessage([
            "type": "SET_TAB_MUTE",
            "tabId": tabId,
            "muted": muted
        ])
    }

    func requestTabs() {
        // Only the oldest unanswered request counts, so asking again and again (every
        // popup open) cannot postpone the "disconnected" verdict.
        let unanswered = lastRequestAt.map { (lastMessageAt ?? .distantPast) < $0 } ?? false
        if !unanswered {
            lastRequestAt = connectionClock()
            connectionTimer?.invalidate()
            // A little slack so the check never lands just before the timeout.
            connectionTimer = Timer.scheduledTimer(withTimeInterval: Self.connectionTimeout + 0.1, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.evaluateConnection() }
            }
        }
        // Restate the switches with every request: a change made while Chrome was closed
        // never reached the extension, and this is what delivers it.
        trackingMismatchAnswered = false
        queueTracking()
        queueOptions()
        // Same for the tap latency, empty included: the native host outlives the app, so a value a previous run
        // sent is still in force in the extension until this one clears it.
        queueTapLatency(lastQueuedTapLatency)
        queueMessage(["type": "GET_TABS"])
    }

    private func noteMessageReceived() {
        lastMessageAt = connectionClock()
        if connectionState != .connected {
            connectionState = .connected
        }
        if !hasConnectedBefore {
            hasConnectedBefore = true
            if persistsConnection { UserDefaults.standard.set(true, forKey: Self.hasConnectedKey) }
        }
    }

    /// Re-judges the connection against the clock. The timer calls this after each
    /// request; tests call it after moving their clock.
    func evaluateConnection() {
        let next = Self.connectionState(
            current: connectionState,
            lastRequestAt: lastRequestAt,
            lastMessageAt: lastMessageAt,
            now: connectionClock(),
            timeout: Self.connectionTimeout
        )
        if next != connectionState {
            connectionState = next
            // Tabs from a dead connection cannot be controlled; drop them until Chrome answers again.
            if next == .disconnected {
                chromeTabs = []
                refreshMultiOutputs()
            }
        }
    }

    /// Decides the connection state. Pure: callers pass the clock.
    ///
    /// A message at or after the last request means connected, however old the request is,
    /// so a stream of pushes never reads as a dropout. A request nobody has answered for
    /// `timeout` seconds means disconnected. Before that, and before any request, the
    /// current state stands.
    static func connectionState(
        current: ChromeConnectionState,
        lastRequestAt: Date?,
        lastMessageAt: Date?,
        now: Date,
        timeout: TimeInterval
    ) -> ChromeConnectionState {
        guard let lastRequestAt else {
            return lastMessageAt == nil ? current : .connected
        }
        if let lastMessageAt, lastMessageAt >= lastRequestAt {
            return .connected
        }
        if now.timeIntervalSince(lastRequestAt) >= timeout {
            return .disconnected
        }
        return current
    }

    func requestMediaState(tabId: Int) {
        queueMessage(["type": "GET_MEDIA_STATE", "tabId": tabId])
    }

    func togglePlayback(tabId: Int) {
        if let index = chromeTabs.firstIndex(where: { $0.id == tabId }) {
            chromeTabs[index].paused.toggle()
            chromeTabs[index].lastSyncedAt = Date()
        }
        queueMessage(["type": "TOGGLE_PLAYBACK", "tabId": tabId])
    }

    /// Test hook: when set, outgoing messages go here instead of to DeciHost.
    var messageSink: (([String: Any]) -> Void)?

    private func sendMessage(_ message: [String: Any]) {
        if let messageSink {
            messageSink(message)
            return
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: message, options: [])
            if let messageString = String(data: data, encoding: .utf8) {
                DistributedNotificationCenter.default().postNotificationName(
                    NSNotification.Name("com.abraham.Deci.ToChrome"),
                    object: messageString,
                    userInfo: nil,
                    deliverImmediately: true
                )
            }
        } catch {
            // serialization error ignored
        }
    }
}

/// Which Chrome tabs Deci tracks: the wire form of SET_TRACKING and of the `tracking`
/// echo in TAB_LIST.
struct ChromeTracking: Equatable {
    var tabs: Bool
    var incognito: Bool
}

/// Whether the extension is answering GET_TABS.
enum ChromeConnectionState: Equatable {
    /// No request has been judged yet (app just started).
    case unknown
    case connected
    /// A request went unanswered past the timeout.
    case disconnected
}

/// Where a tab's chosen output device stands, as reported by the extension.
enum ChromeTabDeviceStatus: String, Equatable {
    /// Following the system default output.
    case defaultOutput = "default"
    /// A device is chosen but the tab is not captured yet.
    case pending
    /// Captured and playing on the chosen device.
    case routed
    /// Captured, but no output matches the chosen name (playing on the default meanwhile).
    case notFound
    /// Captured, but device names are unreadable until the mic prompt is accepted.
    case noAccess

    /// Unknown or missing values mean "default", as the contract says.
    init(wireValue: String?) {
        self = wireValue.flatMap(Self.init(rawValue:)) ?? .defaultOutput
    }
}

/// Who is processing a tab's audio, as reported in TAB_LIST `control`.
enum ChromeTabControl: String, Equatable {
    /// Captured through the toolbar click: volume, boost, EQ and output device.
    case capture
    /// Not captured: plain volume and mute only, until the user clicks Deci in Chrome.
    case none

    /// A capture always wins. Older extensions send no `control`, only `captured`. Any other value, such as the
    /// `page` and `armed` of the removed auto mode, reads as not captured.
    init(wireValue: String?, captured: Bool) {
        if captured {
            self = .capture
        } else {
            self = wireValue.flatMap(Self.init(rawValue:)) ?? .none
        }
    }
}

struct ChromeTab: Identifiable, Equatable {
    let id: Int
    var title: String
    var volume: Float
    var favIconUrl: String?
    var isMuted: Bool = false
    var paused: Bool = false
    var isAudible: Bool = false
    var control: ChromeTabControl = .none
    /// False until the user clicks the Deci toolbar button in Chrome for this tab. Volume and mute work either way;
    /// boost, EQ and output devices need a capture.
    var isCaptured: Bool {
        get { control == .capture }
        set { control = newValue ? .capture : .none }
    }
    var isIncognito: Bool = false
    var currentTime: Double = 0
    var duration: Double = 0
    var lastSyncedAt: Date? = nil
    var songBaselineCurrentTime: Double = 0
    var boost: BoostLevel = .x1
    var eqSettings: EQSettings = EQSettings()
    var deviceName: String? = nil
    /// Owned by the extension: never set locally, always adopted from TAB_LIST.
    var deviceStatus: ChromeTabDeviceStatus = .defaultOutput
    /// The outputs the tab plays on in multi-output mode, as the extension has them; empty for a tab on one output
    /// (`deviceName`). Set locally the moment the user ticks devices, then adopted from TAB_LIST.
    var deviceNames: [String] = []
    /// The names in `deviceNames` the extension could not match to an output. Extension-owned.
    var missingDeviceNames: [String] = []
    /// Which picker the row shows. Exists only in Deci: the extension has no such thing, only `deviceNames`.
    var deviceSelectionMode: DeviceSelectionMode = .single
    /// The devices ticked in multi mode. Kept when flipping back to single, like the engine keeps it. Exists only in Deci.
    var selectedDeviceUIDs: Set<String> = []
    /// When the tab entered multi mode; nil in single mode, and for a tab adopted from the extension already playing a
    /// list (its start is not known). Decides where the tab goes when one of its outputs disconnects. Exists only in Deci.
    var multiSince: Date? = nil
    /// The single choice the tab had when it entered Multi (a device name; nil means System Audio). The fallbacks that
    /// play a Multi tab on one output overwrite `deviceName`, so the disconnect revert restores this instead. Nil in
    /// single mode. Exists only in Deci.
    var preMultiDeviceName: String? = nil
    /// Set when a disconnect sent a tab that was playing a list back to one output, until the extension reports that it
    /// no longer plays a list. A TAB_LIST that still carries the old list in between must not be adopted as Multi again.
    /// Exists only in Deci.
    var revertAwaitsExtension: Bool = false

    /// The tab goes from one output to several: remembers when, and the single choice it is leaving.
    mutating func enterMulti(at date: Date) {
        multiSince = date
        preMultiDeviceName = (deviceName ?? "").isEmpty ? nil : deviceName
        revertAwaitsExtension = false
    }

    /// The tab leaves Multi, by hand or through a disconnect: the session's records go.
    mutating func leaveMulti() {
        multiSince = nil
        preMultiDeviceName = nil
    }

    /// A volume as a tab without a capture plays it: a plain level from 0 (silent) to 1 (full). Boost, which can
    /// push past full, needs a capture. A value that is not a number reads as full, like a missing one on the wire.
    static func plainVolume(_ volume: Float) -> Float {
        volume.isNaN ? 1 : min(max(volume, 0), 1)
    }
}
