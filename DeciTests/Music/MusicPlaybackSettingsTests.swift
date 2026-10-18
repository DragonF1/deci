// DeciTests/Music/MusicPlaybackSettingsTests.swift
// Shuffle, the loop mode and Autoplay are remembered across launches in settings.json.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("Music playback settings")
struct MusicPlaybackSettingsTests {
    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("deci-music-modes-\(UUID().uuidString)")
    }

    private func decode(_ json: String) throws -> AppSettings {
        try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
    }

    @Test("a fresh install has shuffle off, loop off and autoplay on")
    func defaults() {
        let settings = AppSettings()
        #expect(settings.musicShuffle == false)
        #expect(settings.musicLoopMode == .off)
        #expect(settings.musicAutoplay)
        #expect(settings.musicPlayback == MusicPlaybackPreferences())
    }

    @Test("a settings file from before these options existed decodes to the defaults")
    func oldFile() throws {
        let settings = try decode(#"{"launchAtLogin": true, "chromeTabsEnabled": false}"#)
        #expect(settings.launchAtLogin)
        #expect(settings.musicShuffle == false)
        #expect(settings.musicLoopMode == .off)
        #expect(settings.musicAutoplay)
    }

    @Test("an unknown loop value falls back to off and does not lose the other settings")
    func unknownLoopValue() throws {
        let settings = try decode(#"{"musicLoopMode": "sideways", "musicShuffle": true, "musicAutoplay": false, "launchAtLogin": true}"#)
        #expect(settings.musicLoopMode == .off)
        #expect(settings.musicShuffle)
        #expect(settings.musicAutoplay == false)
        #expect(settings.launchAtLogin)
    }

    @Test("the three options survive an encode and decode")
    func roundTrip() throws {
        var settings = AppSettings()
        settings.musicPlayback = MusicPlaybackPreferences(shuffle: true, loop: .song, autoplay: false)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings)
        #expect(decoded.musicPlayback == MusicPlaybackPreferences(shuffle: true, loop: .song, autoplay: false))
    }

    @Test("the preferences view reads and writes the three fields")
    func preferencesView() {
        var settings = AppSettings()
        settings.musicPlayback = MusicPlaybackPreferences(shuffle: true, loop: .playlist, autoplay: false)
        #expect(settings.musicShuffle)
        #expect(settings.musicLoopMode == .playlist)
        #expect(settings.musicAutoplay == false)
    }

    @Test("loop modes are stored by name")
    func loopRawValues() {
        #expect(MusicLoopMode.allCases.map(\.rawValue) == ["off", "playlist", "song"])
    }

    @Test("the options are written to disk and read back by the next launch")
    func persists() {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = SettingsManager(directory: directory)
        var settings = first.appSettings
        settings.musicPlayback = MusicPlaybackPreferences(shuffle: true, loop: .playlist, autoplay: false)
        first.updateAppSettings(settings)
        first.flushSync()

        let second = SettingsManager(directory: directory)
        #expect(second.appSettings.musicPlayback == MusicPlaybackPreferences(shuffle: true, loop: .playlist, autoplay: false))
    }

    @Test("Reset all settings puts the three options back to their defaults")
    func resetAll() {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let manager = SettingsManager(directory: directory)
        var settings = manager.appSettings
        settings.musicPlayback = MusicPlaybackPreferences(shuffle: true, loop: .song, autoplay: false)
        manager.updateAppSettings(settings)

        manager.resetAllSettings()

        #expect(manager.appSettings.musicPlayback == MusicPlaybackPreferences())
    }

    @Test("the host's save hook writes the options into settings and leaves the other settings alone")
    func hostSave() {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = SettingsManager(directory: directory)
        var settings = manager.appSettings
        settings.launchAtLogin = true
        manager.updateAppSettings(settings)

        let save = MusicServiceHost.savePreferences(to: manager)
        save(MusicPlaybackPreferences(shuffle: true, loop: .song, autoplay: false))

        #expect(manager.appSettings.musicPlayback == MusicPlaybackPreferences(shuffle: true, loop: .song, autoplay: false))
        #expect(manager.appSettings.launchAtLogin)
    }

    @Test("with no settings behind it the save hook does nothing")
    func hostSaveWithoutSettings() {
        MusicServiceHost.savePreferences(to: nil)(MusicPlaybackPreferences(shuffle: true, loop: .playlist, autoplay: false))
    }

    @Test("a change made in the player is saved, and the next service starts from it")
    func serviceRoundTrip() {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = SettingsManager(directory: directory)

        func makeService() -> MusicService {
            MusicService(
                backend: FakeMusicBackend(),
                player: MusicPlayer(engine: FakePlaybackEngine()),
                presentSignIn: { _ in },
                nowPlaying: NowPlayingController(surface: FakeNowPlayingSurface(), fetchArtwork: { _ in nil }),
                preferences: manager.appSettings.musicPlayback,
                savePreferences: MusicServiceHost.savePreferences(to: manager),
                refreshOnCreate: false
            )
        }

        let first = makeService()
        first.setShuffle(true)
        first.cycleLoopMode()
        first.setAutoplay(false)

        let second = makeService()
        #expect(second.isShuffleOn)
        #expect(second.loopMode == .playlist)
        #expect(second.isAutoplayOn == false)
    }
}
