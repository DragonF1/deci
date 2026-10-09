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

    /// True when per-tab device choices exist that the extension cannot resolve yet
    /// because device names are unreadable.
    var needsDeviceAccess: Bool {
        !deviceAccess && chromeTabs.contains { !($0.deviceName ?? "").isEmpty }
    }

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

                let now = Date()
                let previous = chromeTabs
                let newTabs = Self.merge(
                    existing: previous,
                    incoming: parsed.tabs,
                    pendingUntil: pendingUntil,
                    now: now
                )
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
            } else if type == "MEDIA_STATE", let tabId = json["tabId"] as? Int {
                let paused = json["paused"] as? Bool ?? false
                let currentTime = (json["currentTime"] as? NSNumber)?.doubleValue ?? 0
                let duration = (json["duration"] as? NSNumber)?.doubleValue ?? 0
                
                guard let index = self.chromeTabs.firstIndex(where: { $0.id == tabId }) else { return }
                if self.chromeTabs[index].lastSyncedAt == nil {
                    self.chromeTabs[index].songBaselineCurrentTime = currentTime
                }
                self.chromeTabs[index].paused = paused
                self.chromeTabs[index].currentTime = currentTime
                self.chromeTabs[index].duration = duration
                self.chromeTabs[index].lastSyncedAt = Date()
            }
        } catch {
            // parsing error ignored
        }
    }
    
    /// Parses a TAB_LIST message. Pure: no state, no side effects.
    static func parseTabList(_ json: [String: Any]) -> (tabs: [ChromeTab], incognitoAllowed: Bool, deviceAccess: Bool) {
        let incognitoAllowed = json["incognitoAllowed"] as? Bool ?? true
        // Missing means an older extension that routes nothing and never asks for access.
        let deviceAccess = json["deviceAccess"] as? Bool ?? true
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
            tabs.append(tab)
        }
        return (tabs, incognitoAllowed, deviceAccess)
    }

    /// Merges a fresh TAB_LIST into the current tabs. Pure: callers pass the clock.
    ///
    /// The extension is the source of truth for volume, boost, mute, EQ and device, except
    /// for a tab with a local change inside its pending window (the extension has not seen
    /// it yet). Media state (paused, position) only ever comes from MEDIA_STATE messages,
    /// so it is carried over from the existing tab. `deviceStatus` is extension-owned
    /// state with no local counterpart, so it is always adopted, pending or not.
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

            if let until = pendingUntil[tab.id], until > now {
                tab.volume = old.volume
                tab.boost = old.boost
                tab.isMuted = old.isMuted
                tab.eqSettings = old.eqSettings
                tab.deviceName = old.deviceName
                // A status for a device the user has already moved away from is stale.
                if fresh.deviceName != old.deviceName {
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
        let messages = pendingMessages.values
        pendingMessages.removeAll()
        for msg in messages {
            sendMessage(msg)
        }
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

    func setTabVolume(tabId: Int, volume: Float) {
        guard let index = chromeTabs.firstIndex(where: { $0.id == tabId }) else { return }
        chromeTabs[index].volume = volume
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

    func setTabDevice(tabId: Int, deviceName: String?) {
        if let index = chromeTabs.firstIndex(where: { $0.id == tabId }) {
            chromeTabs[index].deviceName = deviceName
            // The old status belongs to the old device; show "pending" until the extension reports.
            chromeTabs[index].deviceStatus = (deviceName ?? "").isEmpty ? .defaultOutput : .pending
            markPending(tabId)
            queueMessage([
                "type": "SET_TAB_DEVICE",
                "tabId": tabId,
                "deviceName": deviceName ?? ""
            ])
            // Without device names the extension cannot honour the choice. Open the
            // permission page once instead of leaving the user to find the button.
            if let deviceName, !deviceName.isEmpty, !deviceAccess, !devicePermissionRequested {
                openDevicePermission()
            }
        }
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
            if next == .disconnected { chromeTabs = [] }
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
    /// Auto mode routed the page's media in-page: volume, boost and EQ, no output device.
    case page
    /// Nothing controls the tab until the user clicks Deci in Chrome.
    case none

    /// A capture always wins. Older extensions send no `control`, only `captured`.
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
    /// False until the user clicks the Deci toolbar button in Chrome for this tab.
    var isCaptured: Bool {
        get { control == .capture }
        set { control = newValue ? .capture : (control == .capture ? .none : control) }
    }
    /// Volume, boost and EQ work (captured or auto-controlled in-page).
    var isControlled: Bool { control != .none }
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
}
