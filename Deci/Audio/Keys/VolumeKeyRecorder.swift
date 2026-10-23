// Deci/Audio/Keys/VolumeKeyRecorder.swift
import AppKit
import Foundation

/// Records which modifiers a volume keybind row is bound to. The row's Record button starts a recording;
/// the next press of F11 / F12 then re-binds that row to whatever modifiers are held, instead of changing
/// the volume. The monitor sees the press (a hardware volume key never reaches the Settings window as a
/// key event), so it hands the held modifiers here before it handles the key.
@MainActor
@Observable
final class VolumeKeyRecorder {
    private let settings: SettingsManager
    private let beep: @MainActor () -> Void

    /// The row waiting for a press, if any. Settings shows that row's button as recording.
    private(set) var recordingID: UUID?

    /// The key that ended a recording is still down and macOS keeps repeating it. Those repeats now match the
    /// new combo, so they are swallowed until the next fresh press instead of stepping the volume.
    private var absorbingRepeats = false

    init(settings: SettingsManager, beep: @escaping @MainActor () -> Void = { NSSound.beep() }) {
        self.settings = settings
        self.beep = beep
    }

    /// Starts recording for the row with this id. An id no row has leaves the recorder idle.
    func begin(_ id: UUID) {
        guard settings.appSettings.volumeKeyBindings.contains(where: { $0.id == id }) else { return }
        recordingID = id
    }

    func cancel() {
        recordingID = nil
    }

    /// Adds the row the Add button offers (the first unused combo, at 5%) and, when asked, starts recording it
    /// at once, so a press right after Add picks the modifiers. Nil, and nothing changes, once the rows are full.
    @discardableResult
    func addBinding(startRecording: Bool) -> VolumeKeyBinding? {
        var app = settings.appSettings
        guard let row = app.volumeKeyBindings.unusedBinding() else { return nil }
        app.volumeKeyBindings.append(row)
        settings.appSettings = app
        if startRecording { begin(row.id) }
        return row
    }

    /// Offers a volume key press to the recording. Returns whether the recorder consumed it, in which case the
    /// monitor swallows the key and changes no volume.
    ///
    /// A combo another row already has is refused with a beep and the row keeps its old combo, since two rows
    /// on the same modifiers could never both fire. Pressing a row's own combo again changes nothing.
    @discardableResult
    func capture(_ held: VolumeKeyCombo, isRepeat: Bool = false) -> Bool {
        if isRepeat { return recordingID != nil || absorbingRepeats }
        absorbingRepeats = false
        guard let id = recordingID else { return false }
        recordingID = nil
        absorbingRepeats = true

        var app = settings.appSettings
        guard let index = app.volumeKeyBindings.firstIndex(where: { $0.id == id }) else { return true }
        if app.volumeKeyBindings[index].combo == held { return true }
        if app.volumeKeyBindings.contains(where: { $0.combo == held }) {
            beep()
            return true
        }
        app.volumeKeyBindings[index].combo = held
        settings.appSettings = app
        return true
    }
}
