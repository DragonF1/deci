// DeciTests/VolumeKeyTargetTests.swift
// Volume keys that control one app: the saved target, finding the app, stepping and muting it, and the menu.

import AppKit
import Foundation
import Testing
@testable import Deci

@MainActor
private final class FakeMusicVolume: MusicVolumeControlling {
    var volume: Float = 0.25
    var isMuted = false
    func setVolume(_ newVolume: Float) { volume = newVolume }
    func setMuted(_ muted: Bool) { isMuted = muted }
}

@Suite("Volume keybind target: saved file")
struct VolumeKeyTargetCodingTests {
    @Test("Every target survives a save", arguments: [
        VolumeKeyTarget.defaultOutput, .frontApp, .app(identifier: "com.hnc.Discord", name: "Discord"),
    ])
    func roundTrip(target: VolumeKeyTarget) throws {
        let row = VolumeKeyBinding(combo: .command, percent: 5, target: target)
        let decoded = try JSONDecoder().decode(VolumeKeyBinding.self, from: JSONEncoder().encode(row))
        #expect(decoded == row)
    }

    @Test("A row from before targets controls the default output")
    func missingTarget() throws {
        let json = #"{"id":"6F1C2D5E-8B0A-4C57-9D53-0B5A0E1F2A3B","combo":1,"percent":5}"#
        let row = try JSONDecoder().decode(VolumeKeyBinding.self, from: Data(json.utf8))
        #expect(row.target == .defaultOutput)
        #expect(row.percent == 5)
    }

    @Test("A target that cannot be read keeps the row", arguments: [
        #""loud""#, "7", "{}", #"{"kind":"window"}"#, #"{"kind":"app"}"#, #"{"kind":"app","identifier":""}"#, "null",
    ])
    func unreadableTarget(target: String) throws {
        let json = #"{"id":"6F1C2D5E-8B0A-4C57-9D53-0B5A0E1F2A3B","combo":1,"percent":5,"target":"# + target + "}"
        let row = try JSONDecoder().decode(VolumeKeyBinding.self, from: Data(json.utf8))
        #expect(row.target == .defaultOutput)
        #expect(row.combo == .command)
    }

    @Test("An app saved without a name is called by its identifier")
    func namelessApp() throws {
        let json = #"{"kind":"app","identifier":"com.hnc.Discord"}"#
        let target = try JSONDecoder().decode(VolumeKeyTarget.self, from: Data(json.utf8))
        #expect(target == .app(identifier: "com.hnc.Discord", name: "com.hnc.Discord"))
    }

    @Test("The settings file keeps the targets")
    @MainActor
    func settingsFile() throws {
        var settings = AppSettings()
        settings.volumeKeyBindings = [
            VolumeKeyBinding(combo: [], percent: 10),
            VolumeKeyBinding(combo: .option, percent: 5, target: .app(identifier: "com.hnc.Discord", name: "Discord")),
            VolumeKeyBinding(combo: .control, percent: 5, target: .frontApp),
        ]
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.volumeKeyBindings == settings.volumeKeyBindings)
    }
}

@Suite("App volume step")
@MainActor
struct AppVolumeLevelTests {
    @Test("A step moves the slider, and the gain follows the square law")
    func step() {
        let next = AppVolumeLevel(gain: 0.25, isMuted: false).stepped(by: 0.10)
        #expect(abs(next.slider - 0.6) < 1e-6)
        #expect(abs(next.gain - 0.36) < 1e-5)
        #expect(!next.isMuted)
    }

    @Test("An audible step unmutes, up or down", arguments: [0.1, -0.1])
    func unmutes(delta: Double) {
        #expect(!AppVolumeLevel(slider: 0.5, isMuted: true).stepped(by: delta).isMuted)
    }

    @Test("A step to silence mutes, and stays muted there")
    func silence() {
        let silent = AppVolumeLevel(slider: 0.05, isMuted: false).stepped(by: -0.1)
        #expect(silent == AppVolumeLevel(slider: 0, isMuted: true))
        #expect(silent.stepped(by: -0.1) == silent)
    }

    @Test("A step never leaves the slider")
    func top() {
        #expect(AppVolumeLevel(slider: 0.95, isMuted: false).stepped(by: 0.1) == AppVolumeLevel(slider: 1, isMuted: false))
    }
}

@Suite("Volume keys on one app", .serialized)
@MainActor
struct VolumeKeyAppTests {
    private static let chrome = VolumeKeyTarget.app(identifier: "com.google.Chrome", name: "Chrome")

    private struct Rig {
        let h: EngineHarness
        let monitor: MediaKeyMonitor
        let hud: FractionRecordingHUD
        let popup: PopupVisibilityService
        let music: FakeMusicVolume
    }

    private func makeRig(_ target: VolumeKeyTarget, percent: Int = 10) -> Rig {
        let h = EngineHarness()
        var app = h.settings.appSettings
        app.mediaKeyControlEnabled = true
        app.volumeKeyBindings = [
            VolumeKeyBinding(combo: [], percent: 10),
            VolumeKeyBinding(combo: .option, percent: percent, target: target),
        ]
        h.settings.updateAppSettings(app)
        let hud = FractionRecordingHUD()
        let popup = PopupVisibilityService()
        let monitor = MediaKeyMonitor(
            decoder: StubMediaKeyDecoder(),
            audioEngine: h.engine,
            settingsManager: h.settings,
            accessibility: MockAccessibilityTrustProviding(isTrusted: true),
            hudController: hud,
            popupVisibility: popup,
            mediaKeyStatus: MediaKeyStatus(),
            volumeKeyRecorder: VolumeKeyRecorder(settings: h.settings, beep: {})
        )
        let music = FakeMusicVolume()
        monitor.appVolume.music = music
        monitor.appVolume.frontApp = { nil }
        return Rig(h: h, monitor: monitor, hud: hud, popup: popup, music: music)
    }

    private func slider(_ rig: Rig, _ app: AudioApp) -> Double {
        VolumeMapping.gainToSlider(rig.h.engine.getVolume(for: app))
    }

    @Test("The row's keys step the app, show its name and leave the device alone")
    func stepsApp() throws {
        let rig = makeRig(Self.chrome)
        let app = rig.h.makeApp(ids: [10])
        let tap = rig.h.launch(app)
        let deviceBefore = rig.h.deviceVolume.volumes
        rig.monitor.handle(.volumeDown(isRepeat: false), held: .option)
        #expect(abs(slider(rig, app) - 0.9) < 1e-4)
        #expect(abs(tap.volume - 0.81) < 1e-4)
        #expect(rig.h.deviceVolume.volumes == deviceBefore)
        let shown = try #require(rig.hud.shownApps.last)
        #expect(shown.name == "Chrome")
        #expect(abs(shown.sliderFraction - 0.9) < 1e-4)
        #expect(!shown.mute)
        #expect(rig.hud.shown.isEmpty)
        rig.monitor.handle(.volumeUp(isRepeat: false), held: .option)
        #expect(abs(slider(rig, app) - 1) < 1e-4)
    }

    @Test("A plain press still steps the default output")
    func plainIsDevice() {
        let rig = makeRig(Self.chrome)
        let app = rig.h.makeApp(ids: [10])
        rig.h.launch(app)
        rig.monitor.handle(.volumeDown(isRepeat: false))
        #expect(slider(rig, app) == 1)
        #expect(rig.hud.shownApps.isEmpty)
    }

    @Test("Mute follows the row, and leaves the device alone")
    func mutesApp() throws {
        let rig = makeRig(Self.chrome)
        let app = rig.h.makeApp(ids: [10])
        let tap = rig.h.launch(app)
        let deviceBefore = rig.h.deviceVolume.muteStates
        rig.monitor.handle(.muteToggle, held: .option)
        #expect(rig.h.engine.getMute(for: app))
        #expect(tap.isMuted)
        #expect(try #require(rig.hud.shownApps.last).mute)
        #expect(rig.h.deviceVolume.muteStates == deviceBefore)
        rig.monitor.handle(.muteToggle, held: .option)
        #expect(!rig.h.engine.getMute(for: app))
    }

    @Test("The last step down mutes the app and the next one up unmutes it")
    func muteEdges() {
        let rig = makeRig(Self.chrome)
        let app = rig.h.makeApp(ids: [10])
        rig.h.launch(app)
        rig.h.engine.setVolume(for: app, to: VolumeMapping.sliderToGain(0.1))
        rig.monitor.handle(.volumeDown(isRepeat: false), held: .option)
        #expect(rig.h.engine.getMute(for: app))
        rig.monitor.handle(.volumeUp(isRepeat: false), held: .option)
        #expect(!rig.h.engine.getMute(for: app))
        #expect(abs(slider(rig, app) - 0.1) < 1e-4)
    }

    @Test("A row works without a default output")
    func noDevice() {
        let rig = makeRig(Self.chrome)
        let app = rig.h.makeApp(ids: [10])
        rig.h.launch(app)
        rig.h.deviceVolume.defaultDeviceID = .unknown
        rig.monitor.handle(.volumeDown(isRepeat: false), held: .option)
        #expect(abs(slider(rig, app) - 0.9) < 1e-4)
    }

    @Test("The HUD stays away while the popup is open")
    func popupOpen() {
        let rig = makeRig(Self.chrome)
        rig.popup.isVisible = true
        let app = rig.h.makeApp(ids: [10])
        rig.h.launch(app)
        rig.monitor.handle(.volumeDown(isRepeat: false), held: .option)
        #expect(abs(slider(rig, app) - 0.9) < 1e-4)
        #expect(rig.hud.shownApps.isEmpty)
    }

    @Test("A drag on the HUD sets the app")
    func hudDrag() throws {
        let rig = makeRig(Self.chrome)
        let app = rig.h.makeApp(ids: [10])
        rig.h.launch(app)
        rig.monitor.handle(.muteToggle, held: .option)
        let write = try #require(rig.hud.shownApps.last).write
        write(0.4)
        #expect(abs(slider(rig, app) - 0.4) < 1e-4)
        #expect(!rig.h.engine.getMute(for: app))
        write(0)
        #expect(rig.h.engine.getMute(for: app))
        write(.nan)
        #expect(slider(rig, app) == 0)
    }

    @Test("An app that is not playing has its level saved for next time")
    func notPlaying() throws {
        let rig = makeRig(.app(identifier: "com.hnc.Discord", name: "Discord"), percent: 20)
        rig.monitor.handle(.volumeDown(isRepeat: false), held: .option)
        rig.monitor.handle(.muteToggle, held: .option)
        #expect(abs(VolumeMapping.gainToSlider(try #require(rig.h.settings.getVolume(for: "com.hnc.Discord"))) - 0.8) < 1e-4)
        #expect(rig.h.settings.getMute(for: "com.hnc.Discord") == true)
        #expect(rig.hud.shownApps.map(\.name) == ["Discord", "Discord"])
        let app = rig.h.makeApp(ids: [20], bundleID: "com.hnc.Discord")
        let tap = rig.h.launch(app)
        #expect(abs(slider(rig, app) - 0.8) < 1e-4)
        #expect(tap.isMuted)
    }

    @Test("An app with no saved level starts from the level new apps get")
    func newAppLevel() throws {
        let rig = makeRig(.app(identifier: "com.hnc.Discord", name: "Discord"))
        var settings = rig.h.settings.appSettings
        settings.defaultNewAppVolume = VolumeMapping.sliderToGain(0.5)
        rig.h.settings.updateAppSettings(settings)
        rig.monitor.handle(.volumeUp(isRepeat: false), held: .option)
        #expect(abs(VolumeMapping.gainToSlider(try #require(rig.h.settings.getVolume(for: "com.hnc.Discord"))) - 0.6) < 1e-4)
    }

    @Test("A paused app resumes with the level the keys gave it")
    func pausedApp() {
        let rig = makeRig(Self.chrome)
        let app = rig.h.makeApp(ids: [10])
        let tap = rig.h.launch(app)
        rig.h.publish([])
        rig.monitor.handle(.volumeDown(isRepeat: false), held: .option)
        rig.monitor.handle(.muteToggle, held: .option)
        #expect(abs(tap.volume - 0.81) < 1e-4)
        #expect(tap.isMuted)
        rig.h.publish([app])
        #expect(abs(slider(rig, app) - 0.9) < 1e-4)
        #expect(rig.h.engine.getMute(for: app))
    }

    @Test("A paused process of a playing app gets the level too")
    func pausedSibling() throws {
        let rig = makeRig(Self.chrome)
        let playing = rig.h.makeApp(pid: 50, ids: [10])
        let paused = rig.h.makeApp(pid: 51, ids: [20])
        rig.h.launchAll([playing, paused])
        let pausedTap = try #require(rig.h.tap(for: 51))
        rig.h.publish([playing])
        rig.monitor.handle(.volumeDown(isRepeat: false), held: .option)
        rig.monitor.handle(.muteToggle, held: .option)
        #expect(abs(slider(rig, playing) - 0.9) < 1e-4)
        #expect(abs(pausedTap.volume - 0.81) < 1e-4)
        #expect(pausedTap.isMuted)
    }

    @Test("An ignored app is never touched")
    func ignoredApp() {
        let rig = makeRig(Self.chrome)
        let app = rig.h.makeApp(ids: [10])
        rig.h.launch(app)
        rig.h.engine.ignoreApp(app)
        let saved = rig.h.settings.getVolume(for: "com.google.Chrome")
        rig.monitor.handle(.volumeDown(isRepeat: false), held: .option)
        rig.monitor.handle(.muteToggle, held: .option)
        #expect(rig.h.settings.getVolume(for: "com.google.Chrome") == saved)
        #expect(rig.h.settings.getMute(for: "com.google.Chrome") != true)
        #expect(rig.hud.shownApps.isEmpty)
        #expect(rig.hud.notes.map(\.text) == ["Chrome is ignored in Deci", "Chrome is ignored in Deci"])
    }

    @Test("A drag on the HUD of an app ignored meanwhile does nothing")
    func ignoredDuringDrag() throws {
        let rig = makeRig(Self.chrome)
        let app = rig.h.makeApp(ids: [10])
        rig.h.launch(app)
        rig.monitor.handle(.volumeDown(isRepeat: false), held: .option)
        rig.h.engine.ignoreApp(app)
        let saved = rig.h.settings.getVolume(for: "com.google.Chrome")
        try #require(rig.hud.shownApps.last).write(0.2)
        #expect(rig.h.settings.getVolume(for: "com.google.Chrome") == saved)
    }

    @Test("The app in front is the one stepped")
    func frontApp() {
        let rig = makeRig(.frontApp)
        let front = rig.h.makeApp(pid: 50, ids: [10])
        let other = rig.h.makeApp(pid: 51, ids: [20], bundleID: "com.hnc.Discord")
        rig.h.launchAll([front, other])
        rig.monitor.appVolume.frontApp = { VolumeKeyFrontApp(pid: 51, bundleID: "com.hnc.Discord", name: "Discord") }
        rig.monitor.handle(.volumeDown(isRepeat: false), held: .option)
        #expect(slider(rig, front) == 1)
        #expect(abs(slider(rig, other) - 0.9) < 1e-4)
    }

    @Test("The app in front is found by its bundle when its sound comes from another process")
    func frontAppHelper() {
        let rig = makeRig(.frontApp)
        let app = rig.h.makeApp(pid: 50, ids: [10])
        rig.h.launch(app)
        rig.monitor.appVolume.frontApp = { VolumeKeyFrontApp(pid: 7, bundleID: "com.google.Chrome", name: "Google Chrome") }
        rig.monitor.handle(.volumeDown(isRepeat: false), held: .option)
        #expect(abs(slider(rig, app) - 0.9) < 1e-4)
    }

    @Test("A paused app in front is still stepped")
    func frontAppPaused() {
        let rig = makeRig(.frontApp)
        let app = rig.h.makeApp(pid: 50, ids: [10])
        let tap = rig.h.launch(app)
        rig.h.publish([])
        rig.monitor.appVolume.frontApp = { VolumeKeyFrontApp(pid: 50, bundleID: "com.google.Chrome", name: "Chrome") }
        rig.monitor.handle(.volumeDown(isRepeat: false), held: .option)
        #expect(abs(tap.volume - 0.81) < 1e-4)
        #expect(rig.hud.notes.isEmpty)
    }

    @Test("A silent app in front changes nothing and says so")
    func frontAppSilent() {
        let rig = makeRig(.frontApp)
        rig.monitor.appVolume.frontApp = { VolumeKeyFrontApp(pid: 60, bundleID: "com.apple.TextEdit", name: "TextEdit") }
        let before = rig.h.deviceVolume.volumes
        rig.monitor.handle(.volumeDown(isRepeat: false), held: .option)
        #expect(rig.h.settings.getVolume(for: "com.apple.TextEdit") == nil)
        #expect(rig.h.deviceVolume.volumes == before)
        #expect(rig.hud.shownApps.isEmpty)
        rig.monitor.handle(.volumeDown(isRepeat: true), held: .option)
        #expect(rig.hud.notes.map(\.text) == ["TextEdit is not playing"])
    }

    @Test("No app in front says so")
    func noFrontApp() {
        let rig = makeRig(.frontApp)
        rig.monitor.handle(.muteToggle, held: .option)
        #expect(rig.hud.notes.map(\.text) == ["No app in front"])
    }

    @Test("Deci in front, and Deci Music picked, control the Music player", arguments: [true, false])
    func music(front: Bool) throws {
        let rig = makeRig(front ? .frontApp : .app(identifier: VolumeKeyAppControl.musicIdentifier, name: "Deci Music"))
        rig.monitor.appVolume.frontApp = {
            VolumeKeyFrontApp(pid: ProcessInfo.processInfo.processIdentifier, bundleID: "com.abraham.Deci", name: "Deci")
        }
        rig.monitor.handle(.volumeUp(isRepeat: false), held: .option)
        #expect(abs(rig.music.volume - 0.36) < 1e-4)
        rig.monitor.handle(.muteToggle, held: .option)
        #expect(rig.music.isMuted)
        #expect(try #require(rig.hud.shownApps.last).name == "Deci Music")
    }

    @Test("A press on a row with an app is swallowed, and its repeats keep the row")
    func swallowed() {
        let rig = makeRig(Self.chrome)
        let app = rig.h.makeApp(ids: [10])
        rig.h.launch(app)
        #expect(rig.monitor.processMediaKey(.volumeDown(isRepeat: false), held: .option))
        #expect(rig.monitor.processMediaKey(.volumeDown(isRepeat: true), held: []))
        #expect(abs(slider(rig, app) - 0.8) < 1e-4)
        #expect(rig.hud.shown.isEmpty)
    }

    @Test("A hold that began on the default output never moves to an app")
    func holdStaysOnDevice() {
        let rig = makeRig(Self.chrome)
        let app = rig.h.makeApp(ids: [10])
        rig.h.launch(app)
        #expect(rig.monitor.processMediaKey(.volumeDown(isRepeat: false), held: []))
        #expect(rig.monitor.processMediaKey(.volumeDown(isRepeat: true), held: .option))
        #expect(slider(rig, app) == 1)
        #expect(rig.hud.shownApps.isEmpty)
    }
}

@Suite("Volume keybind target menu")
@MainActor
struct VolumeKeyTargetMenuTests {
    private func app(_ identifier: String, _ name: String) -> VolumeKeyTarget { .app(identifier: identifier, name: name) }

    private func names(_ targets: [VolumeKeyTarget]) -> [String] { targets.map(\.menuTitle) }

    @Test("Deci Music first, then the mixer's and the running apps by name, each once")
    func order() {
        let playing = AudioApp(id: 9, processObjectIDs: [1], name: "Zoom", icon: NSImage(), bundleID: "us.zoom.xos", isHelperBacked: false)
        let targets = VolumeKeyTargetMenu.apps(
            saved: .defaultOutput,
            mixer: [.active(playing)],
            running: [app("com.hnc.Discord", "Discord"), app("us.zoom.xos", "zoom.us"), app("com.apple.Safari", "Safari")],
            isIgnored: { _ in false }
        )
        #expect(names(targets) == ["Deci Music", "Discord", "Safari", "Zoom"])
    }

    @Test("Ignored apps are left out")
    func ignored() {
        let targets = VolumeKeyTargetMenu.apps(
            saved: .frontApp, mixer: [], running: [app("a", "A"), app("b", "B")], isIgnored: { $0 == "a" }
        )
        #expect(names(targets) == ["Deci Music", "B"])
    }

    @Test("The row's own app is there as it was saved, closed or ignored or under a new name")
    func saved() {
        let closed = VolumeKeyTargetMenu.apps(saved: app("x", "Xylo"), mixer: [], running: [], isIgnored: { _ in true })
        #expect(names(closed) == ["Deci Music", "Xylo"])
        let renamed = VolumeKeyTargetMenu.apps(saved: app("x", "Xylo"), mixer: [], running: [app("x", "Xylo 2")], isIgnored: { _ in false })
        #expect(renamed.contains(app("x", "Xylo")))
        #expect(renamed.count == 2)
    }

    @Test("A saved Deci Music target is a tag of the menu")
    func savedMusic() {
        let saved = app(VolumeKeyAppControl.musicIdentifier, "Music")
        let targets = VolumeKeyTargetMenu.apps(saved: saved, mixer: [], running: [], isIgnored: { _ in false })
        #expect(targets == [saved])
    }

    @Test("Deci itself is not in the running apps")
    func runningWithoutDeci() {
        let own = Bundle.main.bundleIdentifier
        #expect(!VolumeKeyTargetMenu.runningApps().contains { $0.appIdentifier == own })
    }
}
