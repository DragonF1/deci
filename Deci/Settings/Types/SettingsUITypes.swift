// FineTune/Settings/Types/SettingsUITypes.swift
import Foundation
import AppKit
import CoreGraphics

// MARK: - App-Wide Settings Enums

enum MenuBarIconStyle: String, Codable, CaseIterable, Identifiable {
    case `default` = "Default"
    case speaker = "Speaker"
    case device = "Device"
    case waveform = "Waveform"
    case equalizer = "Equalizer"

    var id: String { rawValue }

    /// The icon name - either asset catalog name or SF Symbol
    var iconName: String {
        switch self {
        case .default: return "MenuBarIcon"
        case .speaker: return "speaker.wave.2.fill"
        case .device: return "headphones"
        case .waveform: return "waveform"
        case .equalizer: return "slider.vertical.3"
        }
    }

    /// Whether this uses an SF Symbol (vs asset catalog image)
    var isSystemSymbol: Bool {
        self != .default
    }
}

// MARK: - HUD Style

/// Style of the on-screen HUD shown when media keys drive FineTune's volume.
/// `.tahoe` renders a small top-right pill; `.classic` renders a center-bottom panel
/// with 16 segment tiles matching Apple's pre-Tahoe HUD aesthetic.
enum HUDStyle: String, Codable, CaseIterable, Identifiable {
    case tahoe
    case classic

    var id: String { rawValue }
}

// MARK: - Appearance Preference

/// User preference for app appearance. `.system` follows macOS appearance live;
/// `.light` and `.dark` lock the override regardless of system setting.
enum AppearancePreference: String, Codable, CaseIterable, Identifiable, CustomStringConvertible {
    case system
    case light
    case dark

    var id: String { rawValue }

    var description: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

extension AppearancePreference {
    /// AppKit appearance override. `nil` means "inherit from window or app".
    /// Apply via `nsView.window?.appearance = value` for any `NSWindow`/`NSPanel`
    /// the app hosts (popup, popover, HUD).
    /// `.aqua` available since macOS 10.9; `.darkAqua` since 10.14.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

// MARK: - Menu Bar Popup Size

enum MenuBarPopupSize: String, Codable, CaseIterable, Identifiable, CustomStringConvertible {
    case compact
    case comfortable
    case spacious

    var id: String { rawValue }

    var description: String {
        switch self {
        case .compact: return "Compact"
        case .comfortable: return "Comfortable"
        case .spacious: return "Spacious"
        }
    }
}

struct PopupDimensions: Equatable {
    let width: CGFloat
    let contentPadding: CGFloat
    /// Ceiling on the scrollable body. Sized to stay within a 13" MacBook Air's
    /// usable height after the menu bar, since FluidMenuBarExtra does not clamp
    /// the popup against `screen.visibleFrame` vertically.
    let maxContentHeight: CGFloat
}

extension MenuBarPopupSize {
    var dimensions: PopupDimensions {
        switch self {
        case .compact:
            return PopupDimensions(
                width: 470,
                contentPadding: 12,
                maxContentHeight: 560
            )
        case .comfortable:
            return PopupDimensions(
                width: 510,
                contentPadding: 16,
                maxContentHeight: 660
            )
        case .spacious:
            return PopupDimensions(
                width: 560,
                contentPadding: 20,
                maxContentHeight: 760
            )
        }
    }
}

// MARK: - Volume Key Bindings

/// The modifier keys held with the volume keys. A binding fires while at least these are held.
nonisolated struct VolumeKeyCombo: OptionSet, Codable, Hashable, Sendable {
    let rawValue: Int

    static let command = VolumeKeyCombo(rawValue: 1)
    static let shift   = VolumeKeyCombo(rawValue: 2)
    static let option  = VolumeKeyCombo(rawValue: 4)
    static let control = VolumeKeyCombo(rawValue: 8)

    static let all: VolumeKeyCombo = [.command, .shift, .option, .control]

    /// Bits a newer build might have written are dropped, so a file never holds a combo no key can make.
    init(rawValue: Int) {
        self.rawValue = rawValue & 0b1111
    }

    /// Only the four modifiers a binding can name count; Caps Lock, fn and the arrow-pad flag do not.
    init(flags: CGEventFlags) {
        var combo: VolumeKeyCombo = []
        if flags.contains(.maskCommand) { combo.insert(.command) }
        if flags.contains(.maskShift) { combo.insert(.shift) }
        if flags.contains(.maskAlternate) { combo.insert(.option) }
        if flags.contains(.maskControl) { combo.insert(.control) }
        self = combo
    }

    var modifierCount: Int { rawValue.nonzeroBitCount }

    /// Settings row title: the modifier symbols in macOS order (control, option, shift, command), then the keys.
    var label: String {
        var symbols = ""
        if contains(.control) { symbols += "\u{2303}" }
        if contains(.option) { symbols += "\u{2325}" }
        if contains(.shift) { symbols += "\u{21E7}" }
        if contains(.command) { symbols += "\u{2318}" }
        return symbols.isEmpty ? "F11 / F12" : symbols + " F11 / F12"
    }
}

/// One volume keybind row: the modifiers that pick it and the percent of the slider one press moves.
nonisolated struct VolumeKeyBinding: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var combo: VolumeKeyCombo
    var percent: Int

    init(id: UUID = UUID(), combo: VolumeKeyCombo, percent: Int) {
        self.id = id
        self.combo = combo
        self.percent = percent
    }

    /// Whole percent of the slider moved per press.
    static let percentRange = 1...50

    /// Rows past this many are not offered in Settings and are cut from a file that has more.
    static let maxCount = 8

    static func clampedPercent(_ percent: Int) -> Int {
        min(max(percent, percentRange.lowerBound), percentRange.upperBound)
    }

    /// Plain F11 / F12 at 10%, Command at 5% and Command+Shift at 1%, as the keys always worked.
    /// Computed, so every reset or migration gets rows with new ids: an id held across one (a recording left
    /// open in Settings) then matches no row instead of re-arming a fresh one.
    static var defaults: [VolumeKeyBinding] {
        [
            VolumeKeyBinding(combo: [], percent: 10),
            VolumeKeyBinding(combo: [.command], percent: 5),
            VolumeKeyBinding(combo: [.command, .shift], percent: 1),
        ]
    }
}

/// One element of the saved bindings list, read on its own so a single bad row (missing id, wrong type, not
/// an object) is dropped instead of failing the whole list.
nonisolated struct VolumeKeyBindingEntry: Decodable {
    let binding: VolumeKeyBinding?

    init(from decoder: Decoder) throws {
        binding = try? VolumeKeyBinding(from: decoder)
    }
}

extension Array where Element == VolumeKeyBinding {
    /// The row a press with `held` modifiers uses: among the rows whose modifiers are all held, the one
    /// naming the most; a tie goes to the earlier row. Nil when no row fits, so the key is left to macOS.
    func binding(matching held: VolumeKeyCombo) -> VolumeKeyBinding? {
        var best: VolumeKeyBinding?
        for binding in self where held.isSuperset(of: binding.combo) {
            if let current = best, current.combo.modifierCount >= binding.combo.modifierCount { continue }
            best = binding
        }
        return best
    }

    /// A new row for the Add button: the first combination no row uses, fewest modifiers first, at 5%.
    /// Nil once the rows are at `VolumeKeyBinding.maxCount`.
    func unusedBinding() -> VolumeKeyBinding? {
        guard count < VolumeKeyBinding.maxCount else { return nil }
        let free = (0...VolumeKeyCombo.all.rawValue)
            .map { VolumeKeyCombo(rawValue: $0) }
            .sorted { ($0.modifierCount, $0.rawValue) < ($1.modifierCount, $1.rawValue) }
            .first { combo in !contains { $0.combo == combo } }
        return free.map { VolumeKeyBinding(combo: $0, percent: 5) }
    }
}
