// FineTune/Settings/SettingsManager.swift
import Foundation
import os
import ServiceManagement
import AppKit

// MARK: - Pinned App Info

struct PinnedAppInfo: Codable, Equatable {
    let persistenceIdentifier: String
    let displayName: String
    let bundleID: String?
}

// MARK: - Ignored App Info

struct IgnoredAppInfo: Codable, Equatable {
    let persistenceIdentifier: String
    let displayName: String
    let bundleID: String?
}

// MARK: - App-Wide Settings Model

nonisolated struct AppSettings: Codable, Equatable {
    // General
    var launchAtLogin: Bool = false
    var menuBarIconStyle: MenuBarIconStyle = .default

    // Audio
    var defaultNewAppVolume: Float = 1.0      // 100% (unity gain)

    // Input Device Lock
    var lockInputDevice: Bool = true          // Prevent auto-switching input device

    // Notifications
    var showDeviceDisconnectAlerts: Bool = true

    // Audio Processing
    var loudnessCompensationEnabled: Bool = false  // ISO 226:2023 equal-loudness contour compensation
    var loudnessEqualizationEnabled: Bool = false  // Real-time loudness equalization

    // Media Keys & HUD
    var hudStyle: HUDStyle = .tahoe                // Visual style of the volume HUD
    var mediaKeyControlEnabled: Bool = true        // Intercept the media keys: F10/F11/F12 drive the default output device, F7/F8/F9 drive Chrome and Deci
    // What F11 / F12 do under each set of held modifiers, and by how many percent of the slider; user-configurable
    var volumeKeyBindings: [VolumeKeyBinding] = VolumeKeyBinding.defaults

    // Global Hotkeys
    // Keyed by ShortcutAction.rawValue. Values mirror what KeyboardShortcuts persists in
    // its UserDefaults; settings.json is the source of truth.
    var customShortcuts: [String: ShortcutCodable] = [:]

    // Appearance
    var appearance: AppearancePreference = .system  // Follow system appearance, or lock light/dark

    // Popup
    var popupSize: MenuBarPopupSize = .comfortable  // Overall menu bar popup size and density
    var showMusicInMenuBar: Bool = true            // The second menu bar icon, for the music player
    var musicMenuBarStyle: MusicMenuBarStyle = .default  // That item as the plain icon, or the Now playing chip

    // Chrome
    var chromeTabsEnabled: Bool = true             // Show Chrome tabs and let the extension send them
    var chromeIncognitoEnabled: Bool = false       // Same, for tabs in incognito windows (off by default)
    var chromeYTMusicAutoSwitch: Bool = true       // Click "Switch" when YouTube Music asks to listen on this device

    // Music playback
    var musicShuffle: Bool = false                 // Shuffle the Music tab's queue
    var musicLoopMode: MusicLoopMode = .off        // Off, loop the playlist or loop the song
    var musicAutoplay: Bool = true                 // Keep playing recommendations after a playlist or album ends

    // Music Home
    var musicPinnedItems: [MusicPinnedItem] = []   // Artists, playlists, albums and songs pinned to the top of Home, oldest first

    init() {}

    mutating func setUnifiedLoudnessEnabled(_ enabled: Bool) {
        loudnessCompensationEnabled = enabled
        loudnessEqualizationEnabled = enabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        menuBarIconStyle = try c.decodeIfPresent(MenuBarIconStyle.self, forKey: .menuBarIconStyle) ?? .default
        defaultNewAppVolume = try c.decodeIfPresent(Float.self, forKey: .defaultNewAppVolume) ?? 1.0
        lockInputDevice = try c.decodeIfPresent(Bool.self, forKey: .lockInputDevice) ?? true
        showDeviceDisconnectAlerts = try c.decodeIfPresent(Bool.self, forKey: .showDeviceDisconnectAlerts) ?? true
        loudnessCompensationEnabled = try c.decodeIfPresent(Bool.self, forKey: .loudnessCompensationEnabled) ?? false
        loudnessEqualizationEnabled = try c.decodeIfPresent(Bool.self, forKey: .loudnessEqualizationEnabled) ?? false
        hudStyle = try c.decodeIfPresent(HUDStyle.self, forKey: .hudStyle) ?? .tahoe
        mediaKeyControlEnabled = try c.decodeIfPresent(Bool.self, forKey: .mediaKeyControlEnabled) ?? true
        // A hand-edited value of the wrong type (7.5, "loud") falls back to the defaults instead of failing
        // the whole file, which would reset every setting. One bad row costs only itself.
        volumeKeyBindings = Self.cleanedVolumeKeyBindings(
            saved: Self.readableVolumeKeyBindings(try? c.decode([VolumeKeyBindingEntry].self, forKey: .volumeKeyBindings)),
            decoder: decoder)
        customShortcuts = try c.decodeIfPresent([String: ShortcutCodable].self, forKey: .customShortcuts) ?? [:]
        appearance = try c.decodeIfPresent(AppearancePreference.self, forKey: .appearance) ?? .system
        popupSize = try c.decodeIfPresent(MenuBarPopupSize.self, forKey: .popupSize) ?? .comfortable
        showMusicInMenuBar = try c.decodeIfPresent(Bool.self, forKey: .showMusicInMenuBar) ?? true
        // A style this build does not know (or a value of the wrong type) must not cost the listener the rest of their settings.
        musicMenuBarStyle = (try? c.decodeIfPresent(MusicMenuBarStyle.self, forKey: .musicMenuBarStyle)) ?? .default
        chromeTabsEnabled = try c.decodeIfPresent(Bool.self, forKey: .chromeTabsEnabled) ?? true
        chromeIncognitoEnabled = try c.decodeIfPresent(Bool.self, forKey: .chromeIncognitoEnabled) ?? false
        chromeYTMusicAutoSwitch = try c.decodeIfPresent(Bool.self, forKey: .chromeYTMusicAutoSwitch) ?? true
        musicShuffle = try c.decodeIfPresent(Bool.self, forKey: .musicShuffle) ?? false
        // A loop mode this build does not know must not cost the listener the rest of their settings.
        musicLoopMode = (try? c.decodeIfPresent(MusicLoopMode.self, forKey: .musicLoopMode)) ?? .off
        musicAutoplay = try c.decodeIfPresent(Bool.self, forKey: .musicAutoplay) ?? true
        // Pins this build cannot read must not cost the listener the rest of their settings either, and one
        // unreadable pin costs only itself. A file from before Home held more than artists has only the old key,
        // and its artists carry over; the old key is not written again.
        if c.contains(.musicPinnedItems) {
            musicPinnedItems = (try? c.decode([MusicPinnedItemEntry].self, forKey: .musicPinnedItems))?
                .compactMap(\.item) ?? []
        } else {
            let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
            musicPinnedItems = (try? legacy.decodeIfPresent([MusicLegacyPinnedArtistEntry].self, forKey: .musicPinnedArtists))?
                .compactMap(\.item) ?? []
        }
    }

    /// Keys an earlier build wrote that this one only reads.
    private enum LegacyCodingKeys: String, CodingKey {
        case musicPinnedArtists
        case volumeStepPercent
        case volumeStepCommandPercent
        case volumeStepCommandShiftPercent
    }

    /// The saved rows that can be read, each element on its own so one bad row is dropped and the rest load.
    /// Nil when the value is not a list, or when a list with rows in it has none readable: both fall back like
    /// any unreadable value. An empty list stays empty, which cleaning turns into the defaults.
    private static func readableVolumeKeyBindings(_ entries: [VolumeKeyBindingEntry]?) -> [VolumeKeyBinding]? {
        guard let entries else { return nil }
        let rows = entries.compactMap(\.binding)
        return rows.isEmpty && !entries.isEmpty ? nil : rows
    }

    /// The saved rows, cleaned up: percents clamped, a later row with the same modifiers or id dropped
    /// (the first one wins), at most `VolumeKeyBinding.maxCount` kept, and the defaults when none is left.
    /// A file from before rows existed has three step keys instead, and they become the three default rows.
    /// A value that cannot be read at all counts as missing, so it never costs the listener the rest of the file.
    /// An earlier build's volumeHotkeyStep key is not read.
    private static func cleanedVolumeKeyBindings(saved: [VolumeKeyBinding]?, decoder: Decoder) -> [VolumeKeyBinding] {
        guard let saved else { return migratedVolumeKeyBindings(decoder: decoder) }
        var seenCombos = Set<VolumeKeyCombo>()
        var seenIDs = Set<UUID>()
        var rows: [VolumeKeyBinding] = []
        for var row in saved {
            guard seenCombos.insert(row.combo).inserted else { continue }
            row.percent = VolumeKeyBinding.clampedPercent(row.percent)
            if !seenIDs.insert(row.id).inserted { row.id = UUID() }
            rows.append(row)
            if rows.count == VolumeKeyBinding.maxCount { break }
        }
        return rows.isEmpty ? VolumeKeyBinding.defaults : rows
    }

    /// The three step keys an earlier build wrote, as plain, Command and Command+Shift rows; each one that is
    /// missing or of the wrong type keeps its old default.
    private static func migratedVolumeKeyBindings(decoder: Decoder) -> [VolumeKeyBinding] {
        guard let legacy = try? decoder.container(keyedBy: LegacyCodingKeys.self) else {
            return VolumeKeyBinding.defaults
        }
        let keys: [LegacyCodingKeys] = [.volumeStepPercent, .volumeStepCommandPercent, .volumeStepCommandShiftPercent]
        return zip(VolumeKeyBinding.defaults, keys).map { row, key in
            let percent = (try? legacy.decodeIfPresent(Int.self, forKey: key)) ?? row.percent
            return VolumeKeyBinding(id: row.id, combo: row.combo, percent: VolumeKeyBinding.clampedPercent(percent))
        }
    }
}

extension AppSettings {
    /// The row a press with `held` modifiers uses, or nil when none fits and macOS should handle the key.
    func volumeKeyBinding(for held: VolumeKeyCombo) -> VolumeKeyBinding? {
        volumeKeyBindings.binding(matching: held)
    }

    /// The step in slider fraction (0...1) for a press with `held` modifiers, nil when no row fits. The percent
    /// is clamped to `VolumeKeyBinding.percentRange` (decode clamps too, but a programmatic write can still put
    /// a row out of range).
    func sliderDelta(for held: VolumeKeyCombo) -> Double? {
        volumeKeyBinding(for: held).map { Double(VolumeKeyBinding.clampedPercent($0.percent)) / 100.0 }
    }

    /// The step of the popup's arrow keys: the plain row's, or 10% when that row has been rebound.
    var arrowKeySliderDelta: Double {
        sliderDelta(for: []) ?? 0.10
    }
}

extension AppSettings {
    /// The three Music playback options as the player takes them.
    var musicPlayback: MusicPlaybackPreferences {
        get { MusicPlaybackPreferences(shuffle: musicShuffle, loop: musicLoopMode, autoplay: musicAutoplay) }
        set {
            musicShuffle = newValue.shuffle
            musicLoopMode = newValue.loop
            musicAutoplay = newValue.autoplay
        }
    }
}

// MARK: - Settings Manager

@Observable
@MainActor
final class SettingsManager {
    private var settings: Settings
    private var saveTask: Task<Void, Never>?
    private let settingsURL: URL
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FineTune", category: "SettingsManager")

    struct Settings: Codable {
        var version: Int = 12
        var appVolumes: [String: Float] = [:]
        var appDeviceRouting: [String: String] = [:]  // bundleID → deviceUID
        var appMutes: [String: Bool] = [:]  // bundleID → isMuted
        var appBoosts: [String: Float] = [:]  // bundleID → boost rawValue (1.0, 2.0, 3.0, 4.0)
        var appEQSettings: [String: EQSettings] = [:]  // bundleID → EQ settings
        var appSettings: AppSettings = AppSettings()  // App-wide settings
        var systemSoundsFollowsDefault: Bool = true  // Whether system sounds follows macOS default
        var appDeviceSelectionMode: [String: DeviceSelectionMode] = [:]  // bundleID → selection mode
        var appSelectedDeviceUIDs: [String: [String]] = [:]  // bundleID → array of device UIDs for multi mode
        var appMultiOutputSince: [String: Date] = [:]  // bundleID → when it entered Multi (present only while in Multi)
        var lockedInputDeviceUID: String? = nil  // Current locked input device (updated on fallback)
        var preferredInputDeviceUID: String? = nil  // User's intended input device (survives disconnect)
        var pinnedApps: Set<String> = []  // Persistence identifiers of pinned apps
        var pinnedAppInfo: [String: PinnedAppInfo] = [:]  // Persistence identifier → app metadata
        var ignoredApps: Set<String> = []  // Persistence identifiers of hidden apps
        var ignoredAppInfo: [String: IgnoredAppInfo] = [:]  // Persistence identifier → app metadata

        // DDC monitor speaker volumes (keyed by CoreAudio device UID for stability across reboots)
        var ddcVolumes: [String: Int] = [:]       // device UID → volume (0-100)
        var ddcMuteStates: [String: Bool] = [:]   // device UID → software mute state
        var ddcSavedVolumes: [String: Int] = [:]  // device UID → volume before mute

        // Software-backed output volumes for devices without native volume control
        var softwareDeviceVolumes: [String: Float] = [:]      // device UID → visible volume (0.0-1.0)
        var softwareDeviceMuteStates: [String: Bool] = [:]    // device UID → software mute state
        var softwareDeviceSavedVolumes: [String: Float] = [:] // device UID → volume before mute

        // Per-device volume control tier override (overrides auto-detection).
        // nil/missing → auto-detect (hardware/ddc/software). Populated only by
        // the user via the device detail sheet's manual override toggle.
        var deviceVolumeTierOverride: [String: VolumeControlTier] = [:]
        var deviceIconOverrides: [String: String] = [:]  // device UID → SF Symbol name

        // Device priority (ordered device UIDs, highest priority first)
        var outputDevicePriority: [String] = []
        var inputDevicePriority: [String] = []

        // Hidden devices (UIDs of devices suppressed from the main view)
        var hiddenOutputDeviceUIDs: Set<String> = []
        var hiddenInputDeviceUIDs: Set<String> = []

        // Per-device AutoEQ headphone correction
        var deviceAutoEQ: [String: AutoEQSelection] = [:]  // deviceUID → selection
        var favoriteAutoEQProfiles: Set<String> = []  // profile IDs
        var autoEQPreampEnabled: Bool = true  // Use profile preamp vs bypass (rely on limiter)

        // User-created EQ presets (named EQ curves)
        var userEQPresets: [UserEQPreset] = []

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 9
            appVolumes = (try c.decodeIfPresent([String: Float].self, forKey: .appVolumes) ?? [:])
                .filter { $0.value.isFinite && $0.value >= 0 }
                .mapValues { min($0, 1.0) }  // Clamp old volumes > 1.0 (boost is now per-app)
            appDeviceRouting = try c.decodeIfPresent([String: String].self, forKey: .appDeviceRouting) ?? [:]
            appMutes = try c.decodeIfPresent([String: Bool].self, forKey: .appMutes) ?? [:]
            appBoosts = try c.decodeIfPresent([String: Float].self, forKey: .appBoosts) ?? [:]
            appEQSettings = try c.decodeIfPresent([String: EQSettings].self, forKey: .appEQSettings) ?? [:]
            var decodedAppSettings = try c.decodeIfPresent(AppSettings.self, forKey: .appSettings) ?? AppSettings()
            if !decodedAppSettings.defaultNewAppVolume.isFinite || decodedAppSettings.defaultNewAppVolume < 0 {
                decodedAppSettings.defaultNewAppVolume = 1.0
            }

            appSettings = decodedAppSettings
            systemSoundsFollowsDefault = try c.decodeIfPresent(Bool.self, forKey: .systemSoundsFollowsDefault) ?? true
            appDeviceSelectionMode = try c.decodeIfPresent([String: DeviceSelectionMode].self, forKey: .appDeviceSelectionMode) ?? [:]
            appSelectedDeviceUIDs = try c.decodeIfPresent([String: [String]].self, forKey: .appSelectedDeviceUIDs) ?? [:]
            appMultiOutputSince = try c.decodeIfPresent([String: Date].self, forKey: .appMultiOutputSince) ?? [:]
            lockedInputDeviceUID = try c.decodeIfPresent(String.self, forKey: .lockedInputDeviceUID)
            preferredInputDeviceUID = try c.decodeIfPresent(String.self, forKey: .preferredInputDeviceUID)
            pinnedApps = try c.decodeIfPresent(Set<String>.self, forKey: .pinnedApps) ?? []
            pinnedAppInfo = try c.decodeIfPresent([String: PinnedAppInfo].self, forKey: .pinnedAppInfo) ?? [:]
            ignoredApps = try c.decodeIfPresent(Set<String>.self, forKey: .ignoredApps) ?? []
            ignoredAppInfo = try c.decodeIfPresent([String: IgnoredAppInfo].self, forKey: .ignoredAppInfo) ?? [:]
            ddcVolumes = try c.decodeIfPresent([String: Int].self, forKey: .ddcVolumes) ?? [:]
            ddcMuteStates = try c.decodeIfPresent([String: Bool].self, forKey: .ddcMuteStates) ?? [:]
            ddcSavedVolumes = try c.decodeIfPresent([String: Int].self, forKey: .ddcSavedVolumes) ?? [:]
            softwareDeviceVolumes = (try c.decodeIfPresent([String: Float].self, forKey: .softwareDeviceVolumes) ?? [:])
                .filter { $0.value.isFinite && $0.value >= 0 }
                .mapValues { min($0, 1.0) }
            softwareDeviceMuteStates = try c.decodeIfPresent([String: Bool].self, forKey: .softwareDeviceMuteStates) ?? [:]
            softwareDeviceSavedVolumes = (try c.decodeIfPresent([String: Float].self, forKey: .softwareDeviceSavedVolumes) ?? [:])
                .filter { $0.value.isFinite && $0.value >= 0 }
                .mapValues { min($0, 1.0) }
            deviceVolumeTierOverride = try c.decodeIfPresent([String: VolumeControlTier].self, forKey: .deviceVolumeTierOverride) ?? [:]
            deviceIconOverrides = try c.decodeIfPresent([String: String].self, forKey: .deviceIconOverrides) ?? [:]
            outputDevicePriority = try c.decodeIfPresent([String].self, forKey: .outputDevicePriority) ?? []
            inputDevicePriority = try c.decodeIfPresent([String].self, forKey: .inputDevicePriority) ?? []
            hiddenOutputDeviceUIDs = try c.decodeIfPresent(Set<String>.self, forKey: .hiddenOutputDeviceUIDs) ?? []
            hiddenInputDeviceUIDs = try c.decodeIfPresent(Set<String>.self, forKey: .hiddenInputDeviceUIDs) ?? []
            deviceAutoEQ = try c.decodeIfPresent([String: AutoEQSelection].self, forKey: .deviceAutoEQ) ?? [:]
            favoriteAutoEQProfiles = try c.decodeIfPresent(Set<String>.self, forKey: .favoriteAutoEQProfiles) ?? []
            autoEQPreampEnabled = try c.decodeIfPresent(Bool.self, forKey: .autoEQPreampEnabled) ?? true
            userEQPresets = try c.decodeIfPresent([UserEQPreset].self, forKey: .userEQPresets) ?? []
        }
    }

    /// Only the app's own settings (default directory) own the login item. A manager on another
    /// directory (tests) must not register whatever app hosts it as a login item.
    private let managesLoginItem: Bool

    init(directory: URL? = nil) {
        let baseDir = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("Deci")
        self.settingsURL = baseDir.appendingPathComponent("settings.json")
        self.managesLoginItem = directory == nil
        self.settings = Settings()
        loadFromDisk()
    }

    func getVolume(for identifier: String) -> Float? {
        settings.appVolumes[identifier]
    }

    func setVolume(for identifier: String, to volume: Float) {
        settings.appVolumes[identifier] = volume
        scheduleSave()
    }

    // MARK: - Per-App Boost

    func getBoost(for identifier: String) -> BoostLevel? {
        guard let raw = settings.appBoosts[identifier] else { return nil }
        return BoostLevel(rawValue: raw)
    }

    func setBoost(for identifier: String, to boost: BoostLevel) {
        settings.appBoosts[identifier] = boost.rawValue
        scheduleSave()
    }

    func getDeviceRouting(for identifier: String) -> String? {
        settings.appDeviceRouting[identifier]
    }

    func setDeviceRouting(for identifier: String, deviceUID: String) {
        settings.appDeviceRouting[identifier] = deviceUID
        scheduleSave()
    }

    /// Returns true if the app follows system default (no explicit device routing saved)
    func isFollowingDefault(for identifier: String) -> Bool {
        settings.appDeviceRouting[identifier] == nil
    }

    /// Clears device routing for an app, making it follow system default
    func setFollowDefault(for identifier: String) {
        settings.appDeviceRouting.removeValue(forKey: identifier)
        scheduleSave()
    }

    // MARK: - System Sounds Settings

    /// Returns whether system sounds should follow the macOS default output device
    var isSystemSoundsFollowingDefault: Bool {
        settings.systemSoundsFollowsDefault
    }

    /// Sets whether system sounds should follow the macOS default output device
    func setSystemSoundsFollowDefault(_ follows: Bool) {
        settings.systemSoundsFollowsDefault = follows
        scheduleSave()
    }

    func getMute(for identifier: String) -> Bool? {
        settings.appMutes[identifier]
    }

    func setMute(for identifier: String, to muted: Bool) {
        settings.appMutes[identifier] = muted
        scheduleSave()
    }

    func getEQSettings(for appIdentifier: String) -> EQSettings {
        return settings.appEQSettings[appIdentifier] ?? EQSettings.flat
    }

    func setEQSettings(_ eqSettings: EQSettings, for appIdentifier: String) {
        settings.appEQSettings[appIdentifier] = eqSettings
        scheduleSave()
    }

    // MARK: - Device Selection Mode

    func getDeviceSelectionMode(for identifier: String) -> DeviceSelectionMode? {
        settings.appDeviceSelectionMode[identifier]
    }

    /// Saves the mode. Entering Multi records `date` as the start of the Multi session (asking for Multi again keeps
    /// the first start); leaving it clears the start, so Multi to Single to Multi begins a fresh clock.
    func setDeviceSelectionMode(for identifier: String, to mode: DeviceSelectionMode, at date: Date = Date()) {
        let wasMulti = settings.appDeviceSelectionMode[identifier] == .multi
        settings.appDeviceSelectionMode[identifier] = mode
        if mode != .multi {
            settings.appMultiOutputSince.removeValue(forKey: identifier)
        } else if !wasMulti {
            settings.appMultiOutputSince[identifier] = date
        }
        scheduleSave()
    }

    /// When the item entered Multi. nil when it is not in Multi, or when the start was never recorded (a file written
    /// before the start was kept).
    func getMultiOutputSince(for identifier: String) -> Date? {
        settings.appMultiOutputSince[identifier]
    }

    /// Writes or, with nil, removes the start of a Multi session.
    func setMultiOutputSince(_ date: Date?, for identifier: String) {
        if let date {
            settings.appMultiOutputSince[identifier] = date
        } else {
            settings.appMultiOutputSince.removeValue(forKey: identifier)
        }
        scheduleSave()
    }

    /// The items in Multi mode that have this output device selected, in no particular order.
    func multiOutputIdentifiers(containing deviceUID: String) -> [String] {
        settings.appDeviceSelectionMode.compactMap { identifier, mode in
            MultiOutputRevert.disconnectAffects(
                mode: mode,
                selected: Set(settings.appSelectedDeviceUIDs[identifier] ?? []),
                uid: deviceUID
            ) ? identifier : nil
        }
    }

    // MARK: - Selected Device UIDs (Multi Mode)

    func getSelectedDeviceUIDs(for identifier: String) -> Set<String>? {
        guard let uids = settings.appSelectedDeviceUIDs[identifier] else { return nil }
        return Set(uids)
    }

    func setSelectedDeviceUIDs(for identifier: String, to uids: Set<String>) {
        settings.appSelectedDeviceUIDs[identifier] = Array(uids)
        scheduleSave()
    }

    // MARK: - Input Device Lock

    var lockedInputDeviceUID: String? {
        settings.lockedInputDeviceUID
    }

    func setLockedInputDeviceUID(_ uid: String?) {
        settings.lockedInputDeviceUID = uid
        scheduleSave()
    }

    var preferredInputDeviceUID: String? {
        settings.preferredInputDeviceUID
    }

    func setPreferredInputDeviceUID(_ uid: String?) {
        settings.preferredInputDeviceUID = uid
        scheduleSave()
    }

    // MARK: - Pinned Apps

    func pinApp(_ identifier: String, info: PinnedAppInfo) {
        settings.pinnedApps.insert(identifier)
        settings.pinnedAppInfo[identifier] = info
        scheduleSave()
    }

    func unpinApp(_ identifier: String) {
        settings.pinnedApps.remove(identifier)
        settings.pinnedAppInfo.removeValue(forKey: identifier)
        scheduleSave()
    }

    func isPinned(_ identifier: String) -> Bool {
        settings.pinnedApps.contains(identifier)
    }

    /// Returns metadata for all pinned apps
    func getPinnedAppInfo() -> [PinnedAppInfo] {
        settings.pinnedApps.compactMap { settings.pinnedAppInfo[$0] }
    }

    // MARK: - Ignored Apps

    func ignoreApp(_ identifier: String, info: IgnoredAppInfo) {
        settings.ignoredApps.insert(identifier)
        settings.ignoredAppInfo[identifier] = info
        // Hiding is mutually exclusive with pinning
        settings.pinnedApps.remove(identifier)
        settings.pinnedAppInfo.removeValue(forKey: identifier)
        // Clear per-app settings — FineTune won't interact with this app
        settings.appVolumes.removeValue(forKey: identifier)
        settings.appBoosts.removeValue(forKey: identifier)
        settings.appMutes.removeValue(forKey: identifier)
        settings.appDeviceRouting.removeValue(forKey: identifier)
        settings.appEQSettings.removeValue(forKey: identifier)
        settings.appDeviceSelectionMode.removeValue(forKey: identifier)
        settings.appSelectedDeviceUIDs.removeValue(forKey: identifier)
        settings.appMultiOutputSince.removeValue(forKey: identifier)
        scheduleSave()
    }

    func unignoreApp(_ identifier: String) {
        settings.ignoredApps.remove(identifier)
        settings.ignoredAppInfo.removeValue(forKey: identifier)
        scheduleSave()
    }

    func isIgnored(_ identifier: String) -> Bool {
        settings.ignoredApps.contains(identifier)
    }

    func getIgnoredAppInfo() -> [IgnoredAppInfo] {
        settings.ignoredApps.compactMap { settings.ignoredAppInfo[$0] }
    }

    // MARK: - DDC Monitor Volume

    func getDDCVolume(for deviceUID: String) -> Int? {
        settings.ddcVolumes[deviceUID]
    }

    func setDDCVolume(for deviceUID: String, to volume: Int) {
        settings.ddcVolumes[deviceUID] = volume
        scheduleSave()
    }

    func getDDCMuteState(for deviceUID: String) -> Bool {
        settings.ddcMuteStates[deviceUID] ?? false
    }

    func setDDCMuteState(for deviceUID: String, to muted: Bool) {
        settings.ddcMuteStates[deviceUID] = muted
        scheduleSave()
    }

    func getDDCSavedVolume(for deviceUID: String) -> Int? {
        settings.ddcSavedVolumes[deviceUID]
    }

    func setDDCSavedVolume(for deviceUID: String, to volume: Int) {
        settings.ddcSavedVolumes[deviceUID] = volume
        scheduleSave()
    }

    // MARK: - Software Output Device Volume

    func getSoftwareDeviceVolume(for deviceUID: String) -> Float? {
        settings.softwareDeviceVolumes[deviceUID]
    }

    func setSoftwareDeviceVolume(for deviceUID: String, to volume: Float) {
        settings.softwareDeviceVolumes[deviceUID] = normalizedDeviceVolume(volume)
        scheduleSave()
    }

    func getSoftwareDeviceMuteState(for deviceUID: String) -> Bool {
        settings.softwareDeviceMuteStates[deviceUID] ?? false
    }

    func setSoftwareDeviceMuteState(for deviceUID: String, to muted: Bool) {
        settings.softwareDeviceMuteStates[deviceUID] = muted
        scheduleSave()
    }

    func getSoftwareDeviceSavedVolume(for deviceUID: String) -> Float? {
        settings.softwareDeviceSavedVolumes[deviceUID]
    }

    func setSoftwareDeviceSavedVolume(for deviceUID: String, to volume: Float) {
        settings.softwareDeviceSavedVolumes[deviceUID] = normalizedDeviceVolume(volume)
        scheduleSave()
    }

    // MARK: - Per-Device Volume Tier Override

    /// Returns the user-set override tier for a device, or nil when
    /// auto-detection should take effect.
    func getDeviceVolumeTierOverride(for deviceUID: String) -> VolumeControlTier? {
        settings.deviceVolumeTierOverride[deviceUID]
    }

    /// Sets or clears the volume tier override for a device. Passing `nil` removes
    /// the override, returning the device to auto-detection.
    func setDeviceVolumeTierOverride(for deviceUID: String, to tier: VolumeControlTier?) {
        if let tier {
            settings.deviceVolumeTierOverride[deviceUID] = tier
        } else {
            settings.deviceVolumeTierOverride.removeValue(forKey: deviceUID)
        }
        scheduleSave()
    }

    // MARK: - Per-Device Icon Override

    /// Returns the user-chosen SF Symbol override for a device, or nil when
    /// the automatic icon should take effect.
    func getDeviceIconOverride(for deviceUID: String) -> String? {
        settings.deviceIconOverrides[deviceUID]
    }

    /// All UID → symbol overrides, for views that render many devices.
    var deviceIconOverrides: [String: String] {
        settings.deviceIconOverrides
    }

    /// Sets or clears the icon override for a device. Passing `nil` removes
    /// the override, returning the device to its automatic icon.
    func setDeviceIconOverride(for deviceUID: String, to symbol: String?) {
        if let symbol {
            settings.deviceIconOverrides[deviceUID] = symbol
        } else {
            settings.deviceIconOverrides.removeValue(forKey: deviceUID)
        }
        scheduleSave()
    }

    // MARK: - Device Priority

    var devicePriorityOrder: [String] {
        settings.outputDevicePriority
    }

    func setDevicePriorityOrder(_ uids: [String]) {
        settings.outputDevicePriority = uids
        scheduleSave()
    }

    func ensureDeviceInPriority(_ uid: String) {
        guard !settings.outputDevicePriority.contains(uid) else { return }
        settings.outputDevicePriority.append(uid)
        scheduleSave()
    }

    var inputDevicePriorityOrder: [String] {
        settings.inputDevicePriority
    }

    func setInputDevicePriorityOrder(_ uids: [String]) {
        settings.inputDevicePriority = uids
        scheduleSave()
    }

    func ensureInputDeviceInPriority(_ uid: String) {
        guard !settings.inputDevicePriority.contains(uid) else { return }
        settings.inputDevicePriority.append(uid)
        scheduleSave()
    }

    // MARK: - Hidden Devices

    /// Hides an output device from the main view. Has no effect when the device is the current default.
    func hideOutputDevice(uid: String) {
        settings.hiddenOutputDeviceUIDs.insert(uid)
        scheduleSave()
    }

    /// Reveals a previously hidden output device in the main view.
    func unhideOutputDevice(uid: String) {
        settings.hiddenOutputDeviceUIDs.remove(uid)
        scheduleSave()
    }

    /// Returns true if the output device is hidden from the main view.
    func isOutputDeviceHidden(_ uid: String) -> Bool {
        settings.hiddenOutputDeviceUIDs.contains(uid)
    }

    /// All UIDs of hidden output devices.
    var hiddenOutputDeviceUIDs: Set<String> {
        settings.hiddenOutputDeviceUIDs
    }

    /// Flips the hidden state of an output device based on the persisted set.
    /// Prefer this over read-then-hide/unhide from the view layer, which can
    /// desync under rapid taps that re-read stale captured state.
    func toggleOutputDeviceHidden(uid: String) {
        if settings.hiddenOutputDeviceUIDs.contains(uid) {
            settings.hiddenOutputDeviceUIDs.remove(uid)
        } else {
            settings.hiddenOutputDeviceUIDs.insert(uid)
        }
        scheduleSave()
    }

    /// Hides an input device from the main view. Has no effect when the device is the current default.
    func hideInputDevice(uid: String) {
        settings.hiddenInputDeviceUIDs.insert(uid)
        scheduleSave()
    }

    /// Reveals a previously hidden input device in the main view.
    func unhideInputDevice(uid: String) {
        settings.hiddenInputDeviceUIDs.remove(uid)
        scheduleSave()
    }

    /// Returns true if the input device is hidden from the main view.
    func isInputDeviceHidden(_ uid: String) -> Bool {
        settings.hiddenInputDeviceUIDs.contains(uid)
    }

    /// All UIDs of hidden input devices.
    var hiddenInputDeviceUIDs: Set<String> {
        settings.hiddenInputDeviceUIDs
    }

    /// Flips the hidden state of an input device based on the persisted set.
    func toggleInputDeviceHidden(uid: String) {
        if settings.hiddenInputDeviceUIDs.contains(uid) {
            settings.hiddenInputDeviceUIDs.remove(uid)
        } else {
            settings.hiddenInputDeviceUIDs.insert(uid)
        }
        scheduleSave()
    }

    /// Merges reordered connected devices into the full priority list, preserving
    /// disconnected device positions via an anchor algorithm.
    ///
    /// Each disconnected UID is anchored to the last connected UID that preceded it
    /// in `oldPriority`. When rebuilding, disconnected UIDs are inserted after their
    /// anchor (or at the start if no anchor exists).
    ///
    /// - Parameters:
    ///   - oldPriority: The full saved priority list (connected + disconnected UIDs).
    ///   - connectedOrder: The user's reordered list of currently-connected UIDs.
    /// - Returns: Merged priority list preserving disconnected positions relative to connected anchors.
    func mergeDevicePriorityOrder(oldPriority: [String], connectedOrder: [String]) {
        settings.outputDevicePriority = Self.mergePriorityOrder(oldPriority: oldPriority, connectedOrder: connectedOrder)
        scheduleSave()
    }

    /// Input device variant of `mergeDevicePriorityOrder`.
    func mergeInputDevicePriorityOrder(oldPriority: [String], connectedOrder: [String]) {
        settings.inputDevicePriority = Self.mergePriorityOrder(oldPriority: oldPriority, connectedOrder: connectedOrder)
        scheduleSave()
    }

    /// Pure function: merges reordered connected UIDs back into the full priority list.
    ///
    /// Algorithm:
    /// 1. Walk `oldPriority` and assign each disconnected UID an "anchor" — the last
    ///    connected UID that preceded it.  UIDs with no preceding connected UID use
    ///    `nil` anchor (inserted at the front).
    /// 2. Build result from `connectedOrder`, inserting disconnected groups after
    ///    their anchor.
    /// 3. Append any connected UIDs not in `oldPriority` at the end (brand new devices).
    static func mergePriorityOrder(oldPriority: [String], connectedOrder: [String]) -> [String] {
        let connectedSet = Set(connectedOrder)

        // Step 1: Build anchor map — disconnected UID → last connected UID before it (or nil)
        // Also collect ordering of disconnected UIDs per anchor to preserve relative order
        var anchoredGroups: [String?: [String]] = [:]  // anchor → [disconnected UIDs]
        var currentAnchor: String? = nil

        for uid in oldPriority {
            if connectedSet.contains(uid) {
                currentAnchor = uid
            } else {
                anchoredGroups[currentAnchor, default: []].append(uid)
            }
        }

        // Step 2: Build result — insert disconnected groups after their anchors
        var result: [String] = []

        // First, insert any disconnected UIDs anchored to nil (they were before all connected devices)
        if let prefixGroup = anchoredGroups[nil] {
            result.append(contentsOf: prefixGroup)
        }

        for uid in connectedOrder {
            result.append(uid)
            if let group = anchoredGroups[uid] {
                result.append(contentsOf: group)
            }
        }

        return result
    }

    /// Removes per-app settings for apps that are no longer active, not pinned,
    /// and have only default values. Preserves device routing (explicit user intent).
    ///
    /// - Parameter activeIdentifiers: Persistence identifiers of currently active apps.
    func pruneStaleSettings(keeping activeIdentifiers: Set<String>) {
        let allIdentifiers = Set(settings.appVolumes.keys)
            .union(settings.appBoosts.keys)
            .union(settings.appMutes.keys)
            .union(settings.appEQSettings.keys)
            .union(settings.appDeviceSelectionMode.keys)
            .union(settings.appSelectedDeviceUIDs.keys)
            .union(settings.appMultiOutputSince.keys)

        var pruned = 0
        for identifier in allIdentifiers {
            // Keep active apps
            if activeIdentifiers.contains(identifier) { continue }
            // Keep pinned apps
            if settings.pinnedApps.contains(identifier) { continue }
            // Keep apps with explicit device routing (user intent)
            if settings.appDeviceRouting[identifier] != nil { continue }

            // Check if all remaining settings are default values
            let volume = settings.appVolumes[identifier]
            let mute = settings.appMutes[identifier]
            let eq = settings.appEQSettings[identifier]
            let selectionMode = settings.appDeviceSelectionMode[identifier]
            let selectedUIDs = settings.appSelectedDeviceUIDs[identifier]

            let boost = settings.appBoosts[identifier]

            let isDefaultVolume = volume == nil || volume == 1.0
            let isDefaultBoost = boost == nil || boost == BoostLevel.x1.rawValue
            let isDefaultMute = mute == nil || mute == false
            let isDefaultEQ = eq == nil || eq == .flat
            let isDefaultSelectionMode = selectionMode == nil
            let isDefaultSelectedUIDs = selectedUIDs == nil || selectedUIDs?.isEmpty == true

            guard isDefaultVolume && isDefaultBoost && isDefaultMute && isDefaultEQ
                    && isDefaultSelectionMode && isDefaultSelectedUIDs else {
                continue
            }

            // All values are defaults — safe to prune
            settings.appVolumes.removeValue(forKey: identifier)
            settings.appBoosts.removeValue(forKey: identifier)
            settings.appMutes.removeValue(forKey: identifier)
            settings.appEQSettings.removeValue(forKey: identifier)
            settings.appDeviceSelectionMode.removeValue(forKey: identifier)
            settings.appSelectedDeviceUIDs.removeValue(forKey: identifier)
            settings.appMultiOutputSince.removeValue(forKey: identifier)
            pruned += 1
        }

        if pruned > 0 {
            logger.info("Pruned \(pruned) stale app settings entries")
            scheduleSave()
        }
    }

    // MARK: - Per-Device AutoEQ

    func getAutoEQSelection(for deviceUID: String) -> AutoEQSelection? {
        settings.deviceAutoEQ[deviceUID]
    }

    func setAutoEQSelection(for deviceUID: String, to selection: AutoEQSelection?) {
        settings.deviceAutoEQ[deviceUID] = selection
        scheduleSave()
    }

    func favoriteAutoEQProfile(id: String) {
        settings.favoriteAutoEQProfiles.insert(id)
        scheduleSave()
    }

    func unfavoriteAutoEQProfile(id: String) {
        settings.favoriteAutoEQProfiles.remove(id)
        scheduleSave()
    }

    func isAutoEQFavorite(id: String) -> Bool {
        settings.favoriteAutoEQProfiles.contains(id)
    }

    var favoriteAutoEQProfileIDs: Set<String> {
        settings.favoriteAutoEQProfiles
    }

    var autoEQPreampEnabled: Bool {
        get { settings.autoEQPreampEnabled }
        set {
            settings.autoEQPreampEnabled = newValue
            scheduleSave()
        }
    }

    // MARK: - User EQ Presets

    /// Returns all user-created EQ presets, ordered by creation date (newest first).
    func getUserPresets() -> [UserEQPreset] {
        settings.userEQPresets.sorted { $0.createdAt > $1.createdAt }
    }

    /// Creates a new user EQ preset with the given name and band gains.
    /// Trims whitespace, falls back to "Untitled" for empty names,
    /// and auto-suffixes duplicates Finder-style: "Name (2)", "Name (3)", etc.
    /// Returns the created preset.
    @discardableResult
    func createUserPreset(name: String, settings eqSettings: EQSettings) -> UserEQPreset {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = trimmed.isEmpty ? "Untitled" : trimmed
        let finalName = uniquePresetName(baseName)
        let preset = UserEQPreset(name: finalName, settings: eqSettings)
        settings.userEQPresets.append(preset)
        scheduleSave()
        return preset
    }

    /// Renames an existing user preset. Trims whitespace; rejects empty names (no-op).
    /// Auto-suffixes if the new name collides with another preset.
    /// No-op if the preset ID is not found.
    func updateUserPreset(id: UUID, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let index = settings.userEQPresets.firstIndex(where: { $0.id == id }) else { return }
        let finalName = uniquePresetName(trimmed, excluding: id)
        settings.userEQPresets[index].name = finalName
        scheduleSave()
    }

    /// Generates a unique preset name by appending (2), (3), etc. if the name
    /// already exists among user presets. Follows Finder duplicate naming convention.
    /// - Parameters:
    ///   - name: The desired base name.
    ///   - excludeID: A preset ID to exclude from collision checks (used during rename).
    /// - Returns: A unique name, either the original or with a numeric suffix.
    private func uniquePresetName(_ name: String, excluding excludeID: UUID? = nil) -> String {
        let existingNames = Set(
            settings.userEQPresets
                .filter { $0.id != excludeID }
                .map { $0.name }
        )
        guard existingNames.contains(name) else { return name }

        var counter = 2
        while true {
            let candidate = "\(name) (\(counter))"
            if !existingNames.contains(candidate) { return candidate }
            counter += 1
        }
    }

    /// Deletes a user preset by ID. No-op if the preset ID is not found.
    func deleteUserPreset(id: UUID) {
        settings.userEQPresets.removeAll { $0.id == id }
        scheduleSave()
    }

    // MARK: - App-Wide Settings

    var appSettings: AppSettings {
        get { settings.appSettings }
        set { updateAppSettings(newValue) }
    }

    /// Called with (tabs, incognito) whenever either Chrome switch changes, from the UI or a
    /// reset. The one place the Chrome bridge hears about them; not called for other settings.
    var onChromeTrackingChange: ((_ tabs: Bool, _ incognito: Bool) -> Void)?

    /// Called with the new value whenever the YouTube Music auto-switch setting changes,
    /// from the UI or a reset.
    var onChromeYTMusicAutoSwitchChange: ((Bool) -> Void)?

    /// Called with the new value whenever the "Show Music in menu bar" setting really changes, from the UI
    /// or a reset. The one place the menu bar hears about it; not called for a same-value write, for other
    /// settings, or when the file is loaded.
    var onShowMusicInMenuBarChange: ((Bool) -> Void)?

    func updateAppSettings(_ newSettings: AppSettings) {
        // Handle launch at login separately via ServiceManagement
        if newSettings.launchAtLogin != settings.appSettings.launchAtLogin {
            setLaunchAtLogin(newSettings.launchAtLogin)
        }
        let previous = settings.appSettings
        settings.appSettings = newSettings
        scheduleSave()
        notifyChromeSettingsIfChanged(from: previous)
        notifyMusicMenuBarIfChanged(from: previous)
    }

    private func notifyMusicMenuBarIfChanged(from previous: AppSettings) {
        let current = settings.appSettings.showMusicInMenuBar
        guard previous.showMusicInMenuBar != current else { return }
        onShowMusicInMenuBarChange?(current)
    }

    private func notifyChromeSettingsIfChanged(from previous: AppSettings) {
        let current = settings.appSettings
        if previous.chromeYTMusicAutoSwitch != current.chromeYTMusicAutoSwitch {
            onChromeYTMusicAutoSwitchChange?(current.chromeYTMusicAutoSwitch)
        }
        guard previous.chromeTabsEnabled != current.chromeTabsEnabled
            || previous.chromeIncognitoEnabled != current.chromeIncognitoEnabled else { return }
        onChromeTrackingChange?(current.chromeTabsEnabled, current.chromeIncognitoEnabled)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        guard managesLoginItem else { return }
        do {
            if enabled {
                try SMAppService.mainApp.register()
                logger.info("Registered for launch at login")
            } else {
                try SMAppService.mainApp.unregister()
                logger.info("Unregistered from launch at login")
            }
        } catch {
            logger.error("Failed to set launch at login: \(error.localizedDescription)")
        }
    }

    // MARK: - Reset All Settings

    /// Resets all per-app settings and app-wide settings to defaults
    func resetAllSettings() {
        settings.appVolumes.removeAll()
        settings.appBoosts.removeAll()
        settings.appDeviceRouting.removeAll()
        settings.appMutes.removeAll()
        settings.appEQSettings.removeAll()
        settings.pinnedApps.removeAll()
        settings.pinnedAppInfo.removeAll()
        settings.ignoredApps.removeAll()
        settings.ignoredAppInfo.removeAll()
        let previousAppSettings = settings.appSettings
        settings.appSettings = AppSettings()
        settings.systemSoundsFollowsDefault = true
        settings.lockedInputDeviceUID = nil
        settings.preferredInputDeviceUID = nil
        settings.ddcVolumes.removeAll()
        settings.ddcMuteStates.removeAll()
        settings.ddcSavedVolumes.removeAll()
        settings.softwareDeviceVolumes.removeAll()
        settings.softwareDeviceMuteStates.removeAll()
        settings.softwareDeviceSavedVolumes.removeAll()
        settings.deviceVolumeTierOverride.removeAll()
        settings.deviceIconOverrides.removeAll()
        settings.outputDevicePriority.removeAll()
        settings.inputDevicePriority.removeAll()
        settings.hiddenOutputDeviceUIDs.removeAll()
        settings.hiddenInputDeviceUIDs.removeAll()
        settings.autoEQPreampEnabled = true
        settings.deviceAutoEQ.removeAll()
        settings.favoriteAutoEQProfiles.removeAll()
        settings.appDeviceSelectionMode.removeAll()
        settings.appSelectedDeviceUIDs.removeAll()
        settings.appMultiOutputSince.removeAll()
        settings.userEQPresets.removeAll()

        // Also unregister from launch at login
        if managesLoginItem { try? SMAppService.mainApp.unregister() }

        scheduleSave()
        notifyChromeSettingsIfChanged(from: previousAppSettings)
        notifyMusicMenuBarIfChanged(from: previousAppSettings)
        logger.info("Reset all settings to defaults")
    }

    private func loadFromDisk() {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return }

        do {
            let data = try Data(contentsOf: settingsURL)
            settings = try JSONDecoder().decode(Settings.self, from: data)
            logger.debug("Loaded settings with \(self.settings.appVolumes.count) volumes, \(self.settings.appDeviceRouting.count) device routings, \(self.settings.appMutes.count) mutes, \(self.settings.appEQSettings.count) EQ settings")
        } catch {
            logger.error("Failed to load settings: \(error.localizedDescription)")
            // Backup corrupted file before resetting
            let backupURL = settingsURL.deletingPathExtension().appendingPathExtension("backup.json")
            try? FileManager.default.removeItem(at: backupURL)  // Remove old backup if exists
            try? FileManager.default.copyItem(at: settingsURL, to: backupURL)
            logger.warning("Backed up corrupted settings to \(backupURL.lastPathComponent)")
            settings = Settings()
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            let snapshot = settings
            let url = settingsURL
            let data = try? JSONEncoder().encode(snapshot)
            guard let data else { return }
            Task.detached(priority: .utility) {
                do {
                    try Self.writeData(data, to: url)
                } catch {
                    // Avoid actor hops/logging on audio-critical paths; failures are
                    // non-fatal and will retry on the next settings mutation.
                }
            }
        }
    }

    /// Immediately writes pending changes to disk.
    /// Call this on app termination to prevent data loss.
    func flushSync() {
        saveTask?.cancel()
        saveTask = nil
        writeToDisk()
    }

    private func writeToDisk() {
        do {
            let data = try JSONEncoder().encode(settings)
            try Self.writeData(data, to: settingsURL)

            logger.debug("Saved settings")
        } catch {
            logger.error("Failed to save settings: \(error.localizedDescription)")
        }
    }

    private nonisolated static func writeData(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private func normalizedDeviceVolume(_ volume: Float) -> Float {
        guard volume.isFinite else { return 1.0 }
        return max(0.0, min(1.0, volume))
    }
}
