// DeciTests/Music/MusicPinnedItemsSettingsTests.swift
// The pinned items are remembered across launches in settings.json (`musicPinnedItems`), an album pin keeps its
// artist links and album playlist id there (an older file without them still reads), and the artists an older build
// saved under `musicPinnedArtists` carry over.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("Music pinned items settings")
struct MusicPinnedItemsSettingsTests {
    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("deci-music-pins-\(UUID().uuidString)")
    }

    private func decode(_ json: String) throws -> AppSettings {
        try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
    }

    private let sample = [
        MusicPinnedItem(kind: .artist, id: "UCa", title: "Ay", thumbnailURL: "https://img.example.test/a.jpg"),
        MusicPinnedItem(kind: .playlist, id: "VLPL1", title: "Mix", subtitle: "Playlist", thumbnailURL: nil),
        MusicPinnedItem(kind: .album, id: "MPRE1", title: "Record", subtitle: "Album \u{2022} Ay"),
        MusicPinnedItem(
            kind: .song,
            id: "vid1",
            title: "Tune",
            subtitle: "Ay",
            thumbnailURL: "https://img.example.test/t.jpg",
            song: MusicPinnedSong(
                album: "Record", albumBrowseId: "MPRE1", durationSeconds: 215,
                artists: [.init(name: "Ay", browseId: "UCa")]
            )
        ),
    ]

    private let legacySample = [
        MusicPinnedItem(kind: .artist, id: "UCa", title: "Ay", thumbnailURL: "https://img.example.test/a.jpg"),
        MusicPinnedItem(kind: .artist, id: "UCb", title: "Bee", thumbnailURL: nil),
    ]

    @Test("a fresh install has nothing pinned")
    func defaults() {
        #expect(AppSettings().musicPinnedItems.isEmpty)
    }

    @Test("a settings file from before pinning existed decodes to no pins and keeps the other settings")
    func oldFile() throws {
        let settings = try decode(#"{"launchAtLogin": true, "musicShuffle": true}"#)
        #expect(settings.musicPinnedItems.isEmpty)
        #expect(settings.launchAtLogin)
        #expect(settings.musicShuffle)
    }

    @Test("the key is musicPinnedItems, a list of objects with kind, id, title and the optional rest")
    func fileShape() throws {
        let json = #"""
        {"musicPinnedItems": [
            {"kind": "artist", "id": "UCa", "title": "Ay", "thumbnailURL": "https://img.example.test/a.jpg"},
            {"kind": "playlist", "id": "VLPL1", "title": "Mix", "subtitle": "Playlist"},
            {"kind": "album", "id": "MPRE1", "title": "Record", "subtitle": "Album • Ay"},
            {"kind": "song", "id": "vid1", "title": "Tune", "subtitle": "Ay",
             "thumbnailURL": "https://img.example.test/t.jpg",
             "song": {"album": "Record", "albumBrowseId": "MPRE1", "durationSeconds": 215,
                      "artists": [{"name": "Ay", "browseId": "UCa"}]}}
        ]}
        """#
        #expect(try decode(json).musicPinnedItems == sample)
    }

    @Test("a pinned items value this build cannot read falls back to none and does not lose the other settings")
    func unreadableValue() throws {
        let settings = try decode(#"{"musicPinnedItems": "oops", "launchAtLogin": true, "musicAutoplay": false}"#)
        #expect(settings.musicPinnedItems.isEmpty)
        #expect(settings.launchAtLogin)
        #expect(settings.musicAutoplay == false)
    }

    @Test("one pin this build cannot read is skipped and the readable ones around it are kept, in order")
    func unreadableEntry() throws {
        let json = #"""
        {"musicPinnedItems": [
            {"kind": "artist", "id": "UCa", "title": "Ay", "thumbnailURL": "https://img.example.test/a.jpg"},
            {"kind": "artist", "title": "No id"},
            42,
            {"kind": "playlist", "id": "VLPL1", "title": "Mix", "subtitle": "Playlist"}
        ], "launchAtLogin": true}
        """#
        let settings = try decode(json)
        #expect(settings.musicPinnedItems == [sample[0], sample[1]])
        #expect(settings.launchAtLogin)
    }

    @Test("a pin of a kind this build does not know is skipped, not the whole list")
    func unknownKindSkipped() throws {
        let json = #"""
        {"musicPinnedItems": [
            {"kind": "artist", "id": "UCa", "title": "Ay", "thumbnailURL": "https://img.example.test/a.jpg"},
            {"kind": "podcast", "id": "PC1", "title": "From a newer build"},
            {"kind": "playlist", "id": "VLPL1", "title": "Mix", "subtitle": "Playlist"}
        ], "launchAtLogin": true}
        """#
        let settings = try decode(json)
        #expect(settings.musicPinnedItems == [sample[0], sample[1]])
        #expect(settings.launchAtLogin)
    }

    @Test("a wrong type in an optional field costs only that field")
    func badOptionalField() throws {
        let json = #"""
        {"musicPinnedItems": [
            {"kind": "song", "id": "vid1", "title": "Tune", "subtitle": 7, "thumbnailURL": false, "song": "oops"}
        ]}
        """#
        let items = try decode(json).musicPinnedItems
        #expect(items == [MusicPinnedItem(kind: .song, id: "vid1", title: "Tune")])
    }

    @Test("a song payload this build cannot read keeps the song and drops the extras")
    func badSongPayloadKeepsSong() throws {
        let json = #"""
        {"musicPinnedItems": [
            {"kind": "song", "id": "vid1", "title": "Tune",
             "song": {"album": "Record", "durationSeconds": "long", "artists": [1, 2]}}
        ]}
        """#
        let item = try #require(decode(json).musicPinnedItems.first)
        #expect(item.id == "vid1")
        #expect(item.song?.album == "Record")
        #expect(item.song?.durationSeconds == nil)
        #expect(item.song?.artists.isEmpty == true)
    }

    @Test("only a song keeps a song payload")
    func payloadOnSongOnly() throws {
        let json = #"""
        {"musicPinnedItems": [
            {"kind": "album", "id": "MPRE1", "title": "Record", "song": {"album": "Stray"}}
        ]}
        """#
        #expect(try decode(json).musicPinnedItems.first?.song == nil)
    }

    @Test("the pins survive an encode and decode, in order")
    func roundTrip() throws {
        var settings = AppSettings()
        settings.musicPinnedItems = sample
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings)
        #expect(decoded.musicPinnedItems == sample)
    }

    // MARK: - Album extras

    private let albumSample = MusicPinnedItem(
        kind: .album,
        id: "MPRE1",
        title: "Record",
        subtitle: "Album \u{2022} Ay",
        album: MusicPinnedAlbum(audioPlaylistId: "OLAK5uy_a", artists: [.init(name: "Ay", browseId: "UCa")])
    )

    @Test("an album pin keeps its extras under album: the playlist id and the artists")
    func albumExtrasShape() throws {
        let json = #"""
        {"musicPinnedItems": [
            {"kind": "album", "id": "MPRE1", "title": "Record", "subtitle": "Album • Ay",
             "album": {"audioPlaylistId": "OLAK5uy_a", "artists": [{"name": "Ay", "browseId": "UCa"}]}}
        ]}
        """#
        #expect(try decode(json).musicPinnedItems == [albumSample])
    }

    @Test("an album pin saved before the extras existed still reads, with none")
    func oldAlbumPinReads() throws {
        let json = #"{"musicPinnedItems": [{"kind": "album", "id": "MPRE1", "title": "Record", "subtitle": "Album"}]}"#
        let item = try #require(decode(json).musicPinnedItems.first)
        #expect(item.id == "MPRE1")
        #expect(item.album == nil)
    }

    @Test("an album payload this build cannot read keeps the pin and drops the extras")
    func badAlbumPayloadKeepsPin() throws {
        let json = #"""
        {"musicPinnedItems": [
            {"kind": "album", "id": "MPRE1", "title": "Record", "album": "oops"},
            {"kind": "album", "id": "MPRE2", "title": "Other", "album": {"audioPlaylistId": 7, "artists": [1, 2]}},
            {"kind": "album", "id": "MPRE3", "title": "Third", "album": {"audioPlaylistId": "OLAK5uy_c", "artists": "no"}}
        ]}
        """#
        let items = try decode(json).musicPinnedItems
        #expect(items.map(\.id) == ["MPRE1", "MPRE2", "MPRE3"])
        #expect(items[0].album == nil)
        #expect(items[1].album?.audioPlaylistId == nil)
        #expect(items[1].album?.artists.isEmpty == true)
        #expect(items[2].album?.audioPlaylistId == "OLAK5uy_c")
        #expect(items[2].album?.artists.isEmpty == true)
    }

    @Test("only an album keeps an album payload")
    func albumPayloadOnAlbumOnly() throws {
        let json = #"""
        {"musicPinnedItems": [
            {"kind": "playlist", "id": "VLPL1", "title": "Mix", "album": {"audioPlaylistId": "OLAK5uy_x"}},
            {"kind": "artist", "id": "UCa", "title": "Ay", "album": {"audioPlaylistId": "OLAK5uy_x"}},
            {"kind": "song", "id": "vid1", "title": "Tune", "album": {"audioPlaylistId": "OLAK5uy_x"}}
        ]}
        """#
        #expect(try decode(json).musicPinnedItems.allSatisfy { $0.album == nil })
    }

    @Test("an album pin's extras survive an encode and decode")
    func albumExtrasRoundTrip() throws {
        var settings = AppSettings()
        settings.musicPinnedItems = sample + [albumSample]
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings)
        #expect(decoded.musicPinnedItems.last?.album == albumSample.album)
    }

    @Test("a pin with no extras writes no album key, so the file stays as an older build wrote it")
    func noExtrasNoKey() throws {
        let data = try JSONEncoder().encode(sample[2])
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["album"] == nil)
    }

    // MARK: - From the old key

    @Test("a file that has only the old musicPinnedArtists key carries its artists over, in order")
    func migratesOldKey() throws {
        let json = #"""
        {"musicPinnedArtists": [
            {"browseId": "UCa", "title": "Ay", "thumbnailURL": "https://img.example.test/a.jpg"},
            {"browseId": "UCb", "title": "Bee"}
        ], "launchAtLogin": true}
        """#
        let settings = try decode(json)
        #expect(settings.musicPinnedItems == legacySample)
        #expect(settings.musicPinnedItems.allSatisfy { $0.kind == .artist })
        #expect(settings.launchAtLogin)
    }

    @Test("an old pin this build cannot read is skipped and the rest carry over")
    func migrationSkipsUnreadableEntry() throws {
        let json = #"""
        {"musicPinnedArtists": [
            {"browseId": "UCa", "title": "Ay", "thumbnailURL": "https://img.example.test/a.jpg"},
            {"title": "No id"},
            42,
            {"browseId": "UCb", "title": "Bee"}
        ]}
        """#
        #expect(try decode(json).musicPinnedItems == legacySample)
    }

    @Test("an old value this build cannot read migrates to none and keeps the other settings")
    func migrationUnreadableValue() throws {
        let settings = try decode(#"{"musicPinnedArtists": "oops", "launchAtLogin": true}"#)
        #expect(settings.musicPinnedItems.isEmpty)
        #expect(settings.launchAtLogin)
    }

    @Test("when both keys are there the new one wins and the old one is not merged in")
    func newKeyWinsOverOld() throws {
        let json = #"""
        {"musicPinnedArtists": [{"browseId": "UCold", "title": "Old"}],
         "musicPinnedItems": [{"kind": "playlist", "id": "VLPL1", "title": "Mix", "subtitle": "Playlist"}]}
        """#
        #expect(try decode(json).musicPinnedItems == [sample[1]])
    }

    @Test("an emptied new key stays empty and the old artists do not come back")
    func emptiedNewKeyStaysEmpty() throws {
        let json = #"{"musicPinnedArtists": [{"browseId": "UCold", "title": "Old"}], "musicPinnedItems": []}"#
        #expect(try decode(json).musicPinnedItems.isEmpty)
    }

    @Test("saving writes the new key only, so the old key is gone after the next save")
    func oldKeyIsNotWrittenBack() throws {
        let old = #"{"musicPinnedArtists": [{"browseId": "UCa", "title": "Ay"}], "launchAtLogin": true}"#
        let settings = try decode(old)
        let encoded = try JSONEncoder().encode(settings)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["musicPinnedArtists"] == nil)
        let items = try #require(object["musicPinnedItems"] as? [[String: Any]])
        #expect(items.count == 1)
        #expect(items.first?["kind"] as? String == "artist")
        #expect(items.first?["id"] as? String == "UCa")
    }

    @Test("an old settings file on disk migrates on load and the next launch reads the new key")
    func migratesFromDisk() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("settings.json")
        let old = #"{"appSettings": {"launchAtLogin": true, "musicPinnedArtists": [{"browseId": "UCa", "title": "Ay"}, {"browseId": "UCb", "title": "Bee"}]}}"#
        try Data(old.utf8).write(to: file)

        let first = SettingsManager(directory: directory)
        #expect(first.appSettings.musicPinnedItems.map(\.id) == ["UCa", "UCb"])
        #expect(first.appSettings.launchAtLogin)
        var settings = first.appSettings
        settings.musicPinnedItems.append(sample[1])
        first.updateAppSettings(settings)
        first.flushSync()

        let second = SettingsManager(directory: directory)
        #expect(second.appSettings.musicPinnedItems.map(\.id) == ["UCa", "UCb", "VLPL1"])
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(!text.contains("musicPinnedArtists"))
    }

    // MARK: - Persistence

    @Test("the pins are written to disk and read back by the next launch")
    func persists() {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = SettingsManager(directory: directory)
        var settings = first.appSettings
        settings.musicPinnedItems = sample
        first.updateAppSettings(settings)
        first.flushSync()

        let second = SettingsManager(directory: directory)
        #expect(second.appSettings.musicPinnedItems == sample)
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

        MusicServiceHost.savePinnedItems(to: manager)(sample)

        #expect(manager.appSettings.musicPinnedItems == sample)
        #expect(manager.appSettings.launchAtLogin)
        #expect(manager.appSettings.musicPlayback == MusicPlaybackPreferences(shuffle: true, loop: .song, autoplay: false))
    }

    @Test("the playback options' save hook leaves the pins alone")
    func playbackSaveKeepsPins() {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = SettingsManager(directory: directory)
        MusicServiceHost.savePinnedItems(to: manager)(sample)

        MusicServiceHost.savePreferences(to: manager)(MusicPlaybackPreferences(shuffle: true, loop: .off, autoplay: true))

        #expect(manager.appSettings.musicPinnedItems == sample)
    }

    @Test("with no settings behind it the save hook does nothing")
    func hostSaveWithoutSettings() {
        MusicServiceHost.savePinnedItems(to: nil)(sample)
    }

    @Test("Reset all settings clears the pins on disk like every other setting")
    func resetAll() {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = SettingsManager(directory: directory)
        MusicServiceHost.savePinnedItems(to: manager)(sample)

        manager.resetAllSettings()

        #expect(manager.appSettings.musicPinnedItems.isEmpty)
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
                pinnedItems: manager.appSettings.musicPinnedItems,
                savePinnedItems: MusicServiceHost.savePinnedItems(to: manager),
                refreshOnCreate: false
            )
        }

        let first = makeService()
        first.pinnedItems.pin(sample[0])
        first.pinnedItems.pin(sample[1])
        first.pinnedItems.pin(sample[3])
        first.pinnedItems.unpin(sample[0])
        first.pinnedItems.pin(sample[0])

        let second = makeService()
        #expect(second.pinnedItems.items == [sample[1], sample[3], sample[0]])
    }
}
