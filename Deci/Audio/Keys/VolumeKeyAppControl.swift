// Deci/Audio/Keys/VolumeKeyAppControl.swift
import AppKit

/// An app's level as the volume keys and the popup's arrow keys step it: on the slider, not on the gain.
nonisolated struct AppVolumeLevel: Equatable, Sendable {
    /// The slider position, 0 to 1.
    var slider: Double
    var isMuted: Bool

    /// At or below this the level counts as silent.
    static let silence = 0.001

    init(slider: Double, isMuted: Bool) {
        self.slider = slider
        self.isMuted = isMuted
    }

    init(gain: Float, isMuted: Bool) {
        self.init(slider: VolumeMapping.gainToSlider(gain), isMuted: isMuted)
    }

    var gain: Float { VolumeMapping.sliderToGain(slider) }

    /// The level one step away, with the mute edges of the system's own keys: a step that can be heard unmutes, and one
    /// that reaches silence mutes.
    func stepped(by delta: Double) -> AppVolumeLevel {
        moved(to: slider + delta)
    }

    /// The level at `slider`, with the same mute edges.
    func moved(to slider: Double) -> AppVolumeLevel {
        let next = VolumeMapping.snappedSliderStep(slider)
        return AppVolumeLevel(slider: next, isMuted: next <= Self.silence)
    }

    var muteToggled: AppVolumeLevel { AppVolumeLevel(slider: slider, isMuted: !isMuted) }
}

/// The Music player's level, for a keybind row that names it.
@MainActor
protocol MusicVolumeControlling: AnyObject {
    var volume: Float { get }
    var isMuted: Bool { get }
    func setVolume(_ newVolume: Float)
    func setMuted(_ muted: Bool)
}

extension MusicMixerState: MusicVolumeControlling {}

/// The app in front, as far as finding it in the mixer needs.
struct VolumeKeyFrontApp: Equatable {
    var pid: pid_t
    var bundleID: String?
    var name: String
}

/// Finds the app a volume keybind row names, and reads and sets its level: a playing app's through the engine, the Music
/// player's through the mixer, and one that is not playing as the saved level it starts with next time.
@MainActor
final class VolumeKeyAppControl {
    /// The identifier and name of the Music player, which is not an app of its own.
    static let musicIdentifier = MusicMixerState.settingsKey
    static let musicName = "Deci Music"

    enum Subject: Equatable {
        case app(identifier: String, name: String)
        /// Nothing to act on, and the line that says why.
        case unavailable(HUDMessage)
    }

    private let engine: AudioEngine

    /// Set by DeciApp once the mixer exists.
    weak var music: (any MusicVolumeControlling)?

    var frontApp: @MainActor () -> VolumeKeyFrontApp? = {
        NSWorkspace.shared.frontmostApplication.map {
            VolumeKeyFrontApp(pid: $0.processIdentifier, bundleID: $0.bundleIdentifier, name: $0.localizedName ?? "This app")
        }
    }

    init(engine: AudioEngine) {
        self.engine = engine
    }

    /// The app `target` means right now. The default output is not an app.
    func subject(for target: VolumeKeyTarget) -> Subject {
        switch target {
        case .defaultOutput:
            return .unavailable(Self.note("No app to control"))
        case .app(let identifier, let name):
            guard identifier != Self.musicIdentifier else { return musicSubject }
            guard !engine.isIgnored(identifier: identifier) else { return .unavailable(Self.ignoredNote(name)) }
            return .app(identifier: identifier, name: playing(identifier).first?.name ?? name)
        case .frontApp:
            return frontSubject
        }
    }

    private var musicSubject: Subject {
        music == nil
            ? .unavailable(Self.note("\(Self.musicName) is not ready"))
            : .app(identifier: Self.musicIdentifier, name: Self.musicName)
    }

    /// The app in front, when its sound is Deci's to change. One that makes none is left alone: a level saved for it now
    /// would only surprise later.
    private var frontSubject: Subject {
        guard let front = frontApp() else { return .unavailable(Self.note("No app in front")) }
        guard front.pid != ProcessInfo.processInfo.processIdentifier else { return musicSubject }
        let app = engine.apps.first { $0.id == front.pid }
            ?? front.bundleID.flatMap { bundleID in engine.apps.first { $0.bundleID == bundleID } }
        let identifier = app?.persistenceIdentifier ?? front.bundleID ?? "name:\(front.name)"
        guard !engine.isIgnored(identifier: identifier) else { return .unavailable(Self.ignoredNote(front.name)) }
        guard app != nil || engine.isPaused(identifier: identifier) else {
            return .unavailable(Self.note("\(front.name) is not playing"))
        }
        return .app(identifier: identifier, name: app?.name ?? front.name)
    }

    func level(of identifier: String) -> AppVolumeLevel {
        if identifier == Self.musicIdentifier {
            return AppVolumeLevel(gain: music?.volume ?? 1, isMuted: music?.isMuted ?? false)
        }
        if let app = playing(identifier).first {
            return AppVolumeLevel(gain: engine.getVolume(for: app), isMuted: engine.getMute(for: app))
        }
        return AppVolumeLevel(
            gain: engine.getVolumeForInactive(identifier: identifier),
            isMuted: engine.getMuteForInactive(identifier: identifier)
        )
    }

    /// Sets the level of every process of the app, the playing and the paused ones, so they stay together.
    func set(_ level: AppVolumeLevel, for identifier: String) {
        if identifier == Self.musicIdentifier {
            write(level, isMuted: music?.isMuted, setMute: { music?.setMuted($0) }, setGain: { music?.setVolume($0) })
            return
        }
        let apps = playing(identifier)
        for app in apps {
            write(
                level, isMuted: engine.getMute(for: app),
                setMute: { engine.setMute(for: app, to: $0) }, setGain: { engine.setVolume(for: app, to: $0) }
            )
        }
        let isPaused = engine.isPaused(identifier: identifier)
        guard apps.isEmpty || isPaused else { return }
        // A paused process beside a playing one has the old mute, while the saved one is the new one by now.
        write(
            level, isMuted: isPaused ? nil : engine.getMuteForInactive(identifier: identifier),
            setMute: { engine.setMuteForInactive(identifier: identifier, to: $0) },
            setGain: { engine.setVolumeForInactive(identifier: identifier, to: $0) }
        )
    }

    /// A drag on the HUD. The app may have been ignored since the HUD came up.
    func drag(to slider: Double, for identifier: String) {
        guard slider.isFinite, !engine.isIgnored(identifier: identifier) else { return }
        set(level(of: identifier).moved(to: slider), for: identifier)
    }

    private func write(
        _ level: AppVolumeLevel, isMuted: Bool?, setMute: (Bool) -> Void, setGain: (Float) -> Void
    ) {
        if isMuted != level.isMuted { setMute(level.isMuted) }
        setGain(level.gain)
    }

    private func playing(_ identifier: String) -> [AudioApp] {
        engine.apps.filter { $0.persistenceIdentifier == identifier }
    }

    private static func note(_ text: String) -> HUDMessage {
        HUDMessage(symbol: "speaker.slash", text: text)
    }

    private static func ignoredNote(_ name: String) -> HUDMessage {
        note("\(name) is ignored in Deci")
    }
}

/// The apps a volume keybind row offers.
@MainActor
enum VolumeKeyTargetMenu {
    /// The Music player first, then the apps in the mixer and the ones running, by name. The row's own app is always
    /// there, as it was saved, also when it is closed or ignored by now.
    static func apps(
        saved: VolumeKeyTarget,
        mixer: [DisplayableApp],
        running: [VolumeKeyTarget],
        isIgnored: (String) -> Bool
    ) -> [VolumeKeyTarget] {
        let music = VolumeKeyTarget.app(identifier: VolumeKeyAppControl.musicIdentifier, name: VolumeKeyAppControl.musicName)
        var seen: Set<String> = [VolumeKeyAppControl.musicIdentifier]
        var found: [VolumeKeyTarget] = []
        // The picker's selection must be one of its tags, name included, so the saved row goes first.
        if let identifier = saved.appIdentifier, seen.insert(identifier).inserted { found.append(saved) }
        let inMixer = mixer.map { VolumeKeyTarget.app(identifier: $0.id, name: $0.displayName) }
        for target in inMixer + running {
            guard let identifier = target.appIdentifier, !isIgnored(identifier), seen.insert(identifier).inserted else { continue }
            found.append(target)
        }
        found.sort { $0.menuTitle.localizedCaseInsensitiveCompare($1.menuTitle) == .orderedAscending }
        return [saved.appIdentifier == VolumeKeyAppControl.musicIdentifier ? saved : music] + found
    }

    /// The apps with a Dock icon that are open now, Deci left out.
    static func runningApps(_ apps: [NSRunningApplication] = NSWorkspace.shared.runningApplications) -> [VolumeKeyTarget] {
        apps.compactMap { app in
            guard app.activationPolicy == .regular, app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                  let bundleID = app.bundleIdentifier, let name = app.localizedName else { return nil }
            return .app(identifier: bundleID, name: name)
        }
    }
}

extension VolumeKeyTarget {
    var menuTitle: String {
        switch self {
        case .defaultOutput: "Default output"
        case .frontApp: "App in front"
        case .app(_, let name): name
        }
    }
}
