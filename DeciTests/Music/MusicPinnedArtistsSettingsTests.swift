// DeciTests/Music/MusicPinnedArtistsSettingsTests.swift
// The pinned artists are remembered across launches in settings.json (`musicPinnedArtists`).

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("Music pinned artists settings")
struct MusicPinnedArtistsSettingsTests {
    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("deci-music-pins-\(UUID().uuidString)")
    }

    private func decode(_ json: String) throws -> AppSettings {
        try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
    }

    private let sample = [
        MusicPinnedArtist(browseId: "UCa", title: "Ay", thumbnailURL: "https://img.example.test/a.jpg"),
        MusicPinnedArtist(browseId: "UCb", title: "Bee", thumbnailURL: nil),
    ]

    @Test("a fresh install has no pinned artists")
    func defaults() {
        #expect(AppSettings().musicPinnedArtists.isEmpty)
    }

    @Test("a settings file from before pinning existed decodes to no pins and keeps the other settings")
    func oldFile() throws {
        let settings = try decode(#"{"launchAtLogin": true, "musicShuffle": true}"#)
        #expect(settings.musicPinnedArtists.isEmpty)
        #expect(settings.launchAtLogin)
        #expect(settings.musicShuffle)
    }

    @Test("the key is musicPinnedArtists, a list of objects with browseId, title and thumbnailURL")
    func fileShape() throws {
        let json = #"""
        {"musicPinnedArtists": [
            {"browseId": "UCa", "title": "Ay", "thumbnailURL": "https://img.example.test/a.jpg"},
            {"browseId": "UCb", "title": "Bee"}
        ]}
        """#
        #expect(try decode(json).musicPinnedArtists == sample)
    }

    @Test("a pinned artists value this build cannot read falls back to none and does not lose the other settings")
    func unreadableValue() throws {
        let settings = try decode(#"{"musicPinnedArtists": "oops", "launchAtLogin": true, "musicAutoplay": false}"#)
        #expect(settings.musicPinnedArtists.isEmpty)
        #expect(settings.launchAtLogin)
        #expect(settings.musicAutoplay == false)
    }

    @Test("one pin this build cannot read is skipped and the readable ones around it are kept, in order")
    func unreadableEntry() throws {
        let json = #"""
        {"musicPinnedArtists": [
            {"browseId": "UCa", "title": "Ay", "thumbnailURL": "https://img.example.test/a.jpg"},
            {"title": "No id"},
            42,
            {"browseId": "UCb", "title": "Bee"}
        ], "launchAtLogin": true}
        """#
        let settings = try decode(json)
        #expect(settings.musicPinnedArtists == sample)
        #expect(settings.launchAtLogin)
    }

    @Test("the pins survive an encode and decode, in order")
    func roundTrip() throws {
        var settings = AppSettings()
        settings.musicPinnedArtists = sample
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings)
        #expect(decoded.musicPinnedArtists == sample)
    }

    @Test("the pins are written to disk and read back by the next launch")
    func persists() {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = SettingsManager(directory: directory)
        var settings = first.appSettings
        settings.musicPinnedArtists = sample
        first.updateAppSettings(settings)
        first.flushSync()

        let second = SettingsManager(directory: directory)
        #expect(second.appSettings.musicPinnedArtists == sample)
    }

    @Test("the host's save hook writes the pins into settings and leaves the other settings alone")
    func hostSave() {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = SettingsManager(directory: directory)
        var settings = manager.appSettings
        settings.launchAtLogin = true
        settings.musicPlayback = MusicPlaybackPreferences(shuffle: true, loop: .song, autoplay: false)
        manager.updateAppSettings(settings)

        MusicServiceHost.savePinnedArtists(to: manager)(sample)

        #expect(manager.appSettings.musicPinnedArtists == sample)
        #expect(manager.appSettings.launchAtLogin)
        #expect(manager.appSettings.musicPlayback == MusicPlaybackPreferences(shuffle: true, loop: .song, autoplay: false))
    }

    @Test("the playback options' save hook leaves the pins alone")
    func playbackSaveKeepsPins() {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = SettingsManager(directory: directory)
        MusicServiceHost.savePinnedArtists(to: manager)(sample)

        MusicServiceHost.savePreferences(to: manager)(MusicPlaybackPreferences(shuffle: true, loop: .off, autoplay: true))

        #expect(manager.appSettings.musicPinnedArtists == sample)
    }

    @Test("with no settings behind it the save hook does nothing")
    func hostSaveWithoutSettings() {
        MusicServiceHost.savePinnedArtists(to: nil)(sample)
    }

    @Test("Reset all settings clears the pins on disk like every other setting")
    func resetAll() {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = SettingsManager(directory: directory)
        MusicServiceHost.savePinnedArtists(to: manager)(sample)

        manager.resetAllSettings()

        #expect(manager.appSettings.musicPinnedArtists.isEmpty)
    }

    @Test("a pin made in the player is saved, and the next service starts from it")
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
                pinnedArtists: manager.appSettings.musicPinnedArtists,
                savePinnedArtists: MusicServiceHost.savePinnedArtists(to: manager),
                refreshOnCreate: false
            )
        }

        let first = makeService()
        first.pinnedArtists.pin(sample[0])
        first.pinnedArtists.pin(sample[1])
        first.pinnedArtists.unpin("UCa")
        first.pinnedArtists.pin(sample[0])

        let second = makeService()
        #expect(second.pinnedArtists.artists == [sample[1], sample[0]])
    }
}
