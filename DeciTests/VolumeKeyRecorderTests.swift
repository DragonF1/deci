// DeciTests/VolumeKeyRecorderTests.swift
// Tests for VolumeKeyRecorder: which row is being re-bound, what a captured press does to the
// settings, and when it beeps instead. The monitor side (swallowing the press) is covered in
// MediaKeyMonitorHandlerTests.

import Testing
import AppKit
import Foundation
@testable import Deci

@Suite("VolumeKeyRecorder: re-binding a volume keybind row")
@MainActor
struct VolumeKeyRecorderTests {

    // MARK: Helpers

    private func makeSettings(directory: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)) -> SettingsManager {
        SettingsManager(directory: directory)
    }

    private func makeRecorder(
        _ settings: SettingsManager
    ) -> (recorder: VolumeKeyRecorder, beeps: BeepCounter) {
        let beeps = BeepCounter()
        return (VolumeKeyRecorder(settings: settings, beep: { beeps.beep() }), beeps)
    }

    private func ids(_ settings: SettingsManager) -> [UUID] {
        settings.appSettings.volumeKeyBindings.map(\.id)
    }

    private func rows(_ settings: SettingsManager) -> [VolumeKeyRow] {
        settings.appSettings.volumeKeyBindings.rows
    }

    // MARK: begin and cancel

    @Test("A new recorder is idle")
    func startsIdle() {
        let (recorder, _) = makeRecorder(makeSettings())
        #expect(recorder.recordingID == nil)
    }

    @Test("begin marks the row as recording and cancel ends it without touching the settings")
    func beginAndCancel() {
        let settings = makeSettings()
        let (recorder, beeps) = makeRecorder(settings)
        let id = ids(settings)[1]

        recorder.begin(id)
        #expect(recorder.recordingID == id)

        recorder.cancel()
        #expect(recorder.recordingID == nil)
        #expect(rows(settings) == defaultVolumeKeyRows)
        #expect(beeps.count == 0)
    }

    @Test("begin on another row moves the recording there")
    func beginSwitchesRows() {
        let settings = makeSettings()
        let (recorder, _) = makeRecorder(settings)
        let all = ids(settings)

        recorder.begin(all[0])
        recorder.begin(all[2])
        #expect(recorder.recordingID == all[2])
    }

    @Test("begin with an id no row has records nothing")
    func beginUnknownIDIsIgnored() {
        let (recorder, _) = makeRecorder(makeSettings())
        recorder.begin(UUID())
        #expect(recorder.recordingID == nil)
    }

    @Test("cancel while idle is harmless")
    func cancelWhileIdle() {
        let (recorder, beeps) = makeRecorder(makeSettings())
        recorder.cancel()
        #expect(recorder.recordingID == nil)
        #expect(beeps.count == 0)
    }

    // MARK: capture

    @Test("capture while idle consumes nothing and changes nothing", arguments: [
        VolumeKeyCombo([]), VolumeKeyCombo([.command]), VolumeKeyCombo([.option, .control]),
    ])
    func idleCaptureDoesNothing(held: VolumeKeyCombo) {
        let settings = makeSettings()
        let (recorder, beeps) = makeRecorder(settings)

        #expect(recorder.capture(held) == false)
        #expect(rows(settings) == defaultVolumeKeyRows)
        #expect(beeps.count == 0)
    }

    @Test("capture re-binds only the recording row and keeps its id, percent and place", arguments: [
        VolumeKeyCombo([.option]),
        VolumeKeyCombo([.control, .shift]),
        VolumeKeyCombo([.command, .option, .control, .shift]),
    ])
    func captureRebindsTargetRowOnly(held: VolumeKeyCombo) {
        let settings = makeSettings()
        let (recorder, beeps) = makeRecorder(settings)
        let before = settings.appSettings.volumeKeyBindings
        recorder.begin(before[1].id)

        #expect(recorder.capture(held))

        let after = settings.appSettings.volumeKeyBindings
        #expect(after.map(\.id) == before.map(\.id))
        #expect(after[0] == before[0])
        #expect(after[2] == before[2])
        #expect(after[1].combo == held)
        #expect(after[1].percent == before[1].percent)
        #expect(recorder.recordingID == nil)
        #expect(beeps.count == 0)
    }

    @Test("The empty combo (no modifier held) is a valid capture when no other row has it")
    func captureEmptyComboWhenFree() {
        let settings = makeSettings()
        var app = settings.appSettings
        app.volumeKeyBindings[0].combo = [.option]
        settings.appSettings = app
        let (recorder, beeps) = makeRecorder(settings)
        recorder.begin(ids(settings)[1])

        #expect(recorder.capture([]))
        #expect(rows(settings) == [VolumeKeyRow([.option], 10), VolumeKeyRow([], 5), VolumeKeyRow([.command, .shift], 1)])
        #expect(beeps.count == 0)
    }

    @Test("A combo another row already has is rejected with one beep and the old combo is kept", arguments: [
        VolumeKeyCombo([]), VolumeKeyCombo([.command, .shift]),
    ])
    func duplicateIsRejected(held: VolumeKeyCombo) {
        let settings = makeSettings()
        let (recorder, beeps) = makeRecorder(settings)
        recorder.begin(ids(settings)[1])

        #expect(recorder.capture(held))  // still consumed: the press was meant for the recorder

        #expect(beeps.count == 1)
        #expect(recorder.recordingID == nil)
        #expect(rows(settings) == defaultVolumeKeyRows)
    }

    @Test("Re-recording a row's own combo is a quiet success")
    func ownComboIsNoOp() {
        let settings = makeSettings()
        let (recorder, beeps) = makeRecorder(settings)
        let before = settings.appSettings.volumeKeyBindings
        recorder.begin(before[1].id)

        #expect(recorder.capture([.command]))

        #expect(settings.appSettings.volumeKeyBindings == before)
        #expect(recorder.recordingID == nil)
        #expect(beeps.count == 0)
    }

    @Test("A second capture after one finished is not a capture")
    func recordingEndsAfterOneCapture() {
        let settings = makeSettings()
        let (recorder, _) = makeRecorder(settings)
        recorder.begin(ids(settings)[1])
        #expect(recorder.capture([.option]))

        #expect(recorder.capture([.control]) == false)
        #expect(rows(settings)[1] == VolumeKeyRow([.option], 5))
    }

    @Test("If the recording row was removed meanwhile, the press is consumed and nothing changes")
    func rowRemovedMidRecording() {
        let settings = makeSettings()
        let (recorder, beeps) = makeRecorder(settings)
        let removed = ids(settings)[1]
        recorder.begin(removed)
        var app = settings.appSettings
        app.volumeKeyBindings.removeAll { $0.id == removed }
        settings.appSettings = app

        #expect(recorder.capture([.option]))

        #expect(recorder.recordingID == nil)
        #expect(rows(settings) == [VolumeKeyRow([], 10), VolumeKeyRow([.command, .shift], 1)])
        #expect(beeps.count == 0)
    }

    @Test("A recording left open across a settings reset cannot re-arm a fresh default row")
    func staleRecordingIDAfterResetMatchesNothing() {
        let settings = makeSettings()
        let (recorder, beeps) = makeRecorder(settings)
        recorder.begin(ids(settings)[1])

        settings.resetAllSettings()

        #expect(recorder.capture([.option]))  // the press is still the recording's, so it is consumed
        #expect(rows(settings) == defaultVolumeKeyRows)  // but no new row carries the old id
        #expect(recorder.recordingID == nil)
        #expect(beeps.count == 0)
    }

    // MARK: Key repeat

    @Test("Repeats of the press that ended recording are consumed, a fresh press is not")
    func repeatsAfterCaptureAreAbsorbed() {
        let settings = makeSettings()
        let (recorder, _) = makeRecorder(settings)
        recorder.begin(ids(settings)[1])
        #expect(recorder.capture([.option]))

        #expect(recorder.capture([.option], isRepeat: true))
        #expect(recorder.capture([.option], isRepeat: true))

        #expect(recorder.capture([.option]) == false)     // a fresh press goes to normal handling
        #expect(recorder.capture([.option], isRepeat: true) == false)  // and so do its repeats
    }

    @Test("A repeat while recording is consumed without capturing, the next fresh press captures")
    func repeatWhileRecordingIsNotACapture() {
        let settings = makeSettings()
        let (recorder, _) = makeRecorder(settings)
        let id = ids(settings)[1]
        recorder.begin(id)

        #expect(recorder.capture([.option], isRepeat: true))
        #expect(recorder.recordingID == id)
        #expect(rows(settings) == defaultVolumeKeyRows)

        #expect(recorder.capture([.option]))
        #expect(rows(settings)[1] == VolumeKeyRow([.option], 5))
    }

    @Test("Repeats are not absorbed when the recording was cancelled instead of captured")
    func cancelDoesNotAbsorbRepeats() {
        let settings = makeSettings()
        let (recorder, _) = makeRecorder(settings)
        recorder.begin(ids(settings)[1])
        recorder.cancel()

        #expect(recorder.capture([], isRepeat: true) == false)
    }

    // MARK: Adding a row

    @Test("addBinding appends the first unused combo at 5% and returns it")
    func addBindingAppendsUnusedRow() throws {
        let settings = makeSettings()
        let (recorder, _) = makeRecorder(settings)

        let added = try #require(recorder.addBinding(startRecording: false))

        #expect(added.combo == [.shift])
        #expect(added.percent == 5)
        #expect(settings.appSettings.volumeKeyBindings.last == added)
        #expect(rows(settings) == defaultVolumeKeyRows + [VolumeKeyRow([.shift], 5)])
    }

    @Test("addBinding with startRecording waits for a press on the new row")
    func addBindingStartsRecording() throws {
        let settings = makeSettings()
        let (recorder, _) = makeRecorder(settings)

        let added = try #require(recorder.addBinding(startRecording: true))
        #expect(recorder.recordingID == added.id)

        #expect(recorder.capture([.control, .option]))
        #expect(rows(settings).last == VolumeKeyRow([.control, .option], 5))
        #expect(rows(settings).dropLast() == defaultVolumeKeyRows[...])
    }

    @Test("addBinding without startRecording leaves any recording as it was")
    func addBindingWithoutRecordingKeepsTheCurrentOne() throws {
        let settings = makeSettings()
        let (recorder, _) = makeRecorder(settings)
        #expect(recorder.addBinding(startRecording: false) != nil)
        #expect(recorder.recordingID == nil)

        let first = ids(settings)[0]
        recorder.begin(first)
        #expect(recorder.addBinding(startRecording: false) != nil)
        #expect(recorder.recordingID == first)
    }

    @Test("addBinding with startRecording moves an open recording to the new row")
    func addBindingMovesTheRecording() throws {
        let settings = makeSettings()
        let (recorder, _) = makeRecorder(settings)
        recorder.begin(ids(settings)[0])

        let added = try #require(recorder.addBinding(startRecording: true))

        #expect(recorder.recordingID == added.id)
    }

    @Test("At the cap addBinding adds nothing and starts no recording", arguments: [false, true])
    func addBindingStopsAtTheCap(startRecording: Bool) {
        let settings = makeSettings()
        let (recorder, _) = makeRecorder(settings)
        while recorder.addBinding(startRecording: false) != nil {}
        #expect(settings.appSettings.volumeKeyBindings.count == VolumeKeyBinding.maxCount)
        let before = settings.appSettings.volumeKeyBindings

        #expect(recorder.addBinding(startRecording: startRecording) == nil)

        #expect(settings.appSettings.volumeKeyBindings == before)
        #expect(recorder.recordingID == nil)
    }

    @Test("An added row is written to settings.json and survives a reload")
    func addBindingPersists() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let settings = makeSettings(directory: directory)
        let (recorder, _) = makeRecorder(settings)
        let added = try #require(recorder.addBinding(startRecording: true))
        settings.flushSync()

        let reloaded = makeSettings(directory: directory)
        #expect(reloaded.appSettings.volumeKeyBindings.last == added)
        #expect(reloaded.appSettings.volumeKeyBindings.count == 4)
    }

    // MARK: Persistence

    @Test("A captured combo is written to settings.json and survives a reload")
    func capturePersists() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let settings = makeSettings(directory: directory)
        let (recorder, _) = makeRecorder(settings)
        let before = settings.appSettings.volumeKeyBindings
        recorder.begin(before[1].id)
        #expect(recorder.capture([.control, .option]))
        settings.flushSync()

        let reloaded = makeSettings(directory: directory)
        let after = reloaded.appSettings.volumeKeyBindings
        #expect(after.map(\.id) == before.map(\.id))
        #expect(after[1].combo == [.control, .option])
        #expect(after[1].percent == before[1].percent)
    }
}

@Suite("ShortcutsTab: which window ends a volume key recording")
@MainActor
struct ShortcutsTabWindowFilterTests {

    private func makeWindow(title: String) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled], backing: .buffered, defer: true
        )
        window.title = title
        return window
    }

    private func resigned(_ object: Any?) -> Notification {
        Notification(name: NSWindow.didResignKeyNotification, object: object)
    }

    @Test("The Settings window resigning key counts")
    func settingsWindowCounts() {
        let window = makeWindow(title: SettingsRootView.windowTitle)
        #expect(ShortcutsTab.isSettingsWindow(resigned(window)))
    }

    @Test("Any other Deci window resigning key does not", arguments: ["Deci", "Deci Music", "Deci Mixer", "", "deci settings", "Deci Settings "])
    func otherWindowsDoNotCount(title: String) {
        #expect(ShortcutsTab.isSettingsWindow(resigned(makeWindow(title: title))) == false)
    }

    @Test("A notification with no window, or something that is not one, does not count")
    func nonWindowObjects() {
        #expect(ShortcutsTab.isSettingsWindow(resigned(nil)) == false)
        #expect(ShortcutsTab.isSettingsWindow(resigned("Deci Settings")) == false)
        #expect(ShortcutsTab.isSettingsWindow(resigned(NSView())) == false)
    }
}
