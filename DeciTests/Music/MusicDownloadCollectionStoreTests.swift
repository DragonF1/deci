// DeciTests/Music/MusicDownloadCollectionStoreTests.swift
// The downloads folder once playlists and albums can own songs: the collection records and their round trip, the
// phase 1 index that has none of it, the rule that a file goes only when no collection lists the song and it is not
// downloaded on its own, what the store does with records it cannot read, and the cover files kept beside the audio.
// Every test works in a folder of its own under /Volumes/Storage/_test, removed when it ends.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("MusicDownloadCollectionStore")
struct MusicDownloadCollectionStoreTests {
    private let idA = DownloadSamples.idA
    private let idB = DownloadSamples.idB
    private let idC = DownloadSamples.idC

    private func makeStore(_ folder: DownloadTestFolder) -> MusicDownloadStore {
        MusicDownloadStore(root: folder.root, now: { DownloadSamples.fixedDate })
    }

    /// Commits `count` bytes for the song, the way the downloader does, and flushes the index, which the store otherwise
    /// writes a moment later: the tests here look at the disk right after.
    @discardableResult
    private func commit(
        _ id: String, standalone: Bool, into store: MusicDownloadStore, bytes count: Int = 40
    ) async throws -> MusicDownloadStore.Entry {
        let part = try await store.beginPart(videoId: id)
        try DownloadSamples.payload(count).write(to: part)
        let entry = try await store.commit(
            DownloadSamples.track(id), expectedBytes: Int64(count), durationSeconds: 200, standalone: standalone
        )
        await store.flushIndex()
        return entry
    }

    private func collection(_ title: String = "Mix", _ ids: [String]) -> MusicDownloadStore.Collection {
        MusicDownloadStore.Collection(title: title, videoIds: ids)
    }

    private func readIndexObject(_ folder: DownloadTestFolder) throws -> [String: Any] {
        let data = try #require(folder.read(folder.indexURL))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - Records

    @Test("a collection round trips through the index with every field and the order of its songs")
    func collectionRoundTrip() async throws {
        let folder = DownloadTestFolder()
        defer { folder.remove() }
        let first = makeStore(folder)
        _ = await first.load()
        let saved = MusicDownloadStore.Collection(
            title: "Road trip",
            videoIds: [idC, idA, idB],
            subtitle: "Playlist \u{00B7} 3 songs",
            kind: .album,
            coverURL: URL(string: "https://lh3.googleusercontent.com/cover=w544-h544"),
            coverFile: nil,
            addedAt: Date(timeIntervalSince1970: 1_700_000_100),
            lastSyncedAt: Date(timeIntervalSince1970: 1_700_000_200),
            syncResult: .failed(2),
            channelKey: "channel-a"
        )
        try await first.saveCollection("VLPLroad", saved)

        let second = makeStore(folder)
        _ = await second.load()

        #expect(await second.collectionList() == ["VLPLroad": saved])
        #expect(await second.collectionList()["VLPLroad"]?.videoIds == [idC, idA, idB])
    }

    @Test("every sync result survives the index: complete, some failed, and unreachable")
    func syncResultsRoundTrip() async throws {
        let folder = DownloadTestFolder()
        defer { folder.remove() }
        let first = makeStore(folder)
        _ = await first.load()
        try await first.saveCollection("VLone", collection("One", [idA]))
        try await first.saveCollection("VLtwo", collection("Two", [idB]))
        try await first.saveCollection("VLthree", collection("Three", [idC]))
        let stamp = Date(timeIntervalSince1970: 1_700_000_900)
        await first.setSyncResult("VLone", .complete, syncedAt: stamp)
        await first.setSyncResult("VLtwo", .failed(7), syncedAt: stamp)
        await first.setSyncResult("VLthree", .unreachable, syncedAt: nil)

        let second = makeStore(folder)
        _ = await second.load()
        let list = await second.collectionList()

        #expect(list["VLone"]?.syncResult == .complete)
        #expect(list["VLone"]?.lastSyncedAt == stamp)
        #expect(list["VLtwo"]?.syncResult == .failed(7))
        #expect(list["VLthree"]?.syncResult == .unreachable)
        // A sync that could not run did not sync: the time of the last good one is not moved.
        #expect(list["VLthree"]?.lastSyncedAt == nil)
    }

    @Test("the index is written as version 2, and the entries carry whether they stand alone")
    func indexVersion() async throws {
        let folder = DownloadTestFolder()
        defer { folder.remove() }
        let store = makeStore(folder)
        _ = await store.load()
        try await commit(idA, standalone: false, into: store)

        let object = try readIndexObject(folder)

        #expect(object["version"] as? Int == 2)
        let entries = try #require(object["entries"] as? [String: Any])
        let entry = try #require(entries[idA] as? [String: Any])
        #expect(entry["standalone"] as? Bool == false)
    }

    @Test("a phase 1 index, with no standalone flag and a bare collection, loads: old songs stand alone")
    func phaseOneIndexMigrates() async throws {
        let folder = DownloadTestFolder()
        defer { folder.remove() }
        let first = makeStore(folder)
        _ = await first.load()
        try await commit(idA, standalone: true, into: first)
        try await commit(idB, standalone: true, into: first)
        try await first.saveCollection("PLmix", collection("Mix", [idA]))
        // Rewrite the index the way the first build wrote it: version 1, none of the newer fields.
        var object = try readIndexObject(folder)
        object["version"] = 1
        var entries = try #require(object["entries"] as? [String: Any])
        for key in Array(entries.keys) {
            var entry = try #require(entries[key] as? [String: Any])
            entry.removeValue(forKey: "standalone")
            entry.removeValue(forKey: "coverFile")
            entries[key] = entry
        }
        object["entries"] = entries
        object["collections"] = ["PLmix": ["title": "Mix", "videoIds": [idA]]]
        try folder.write(try JSONSerialization.data(withJSONObject: object), to: folder.indexURL)

        let second = makeStore(folder)
        let loaded = await second.load()

        #expect(loaded[idA]?.standalone == true)
        #expect(loaded[idB]?.standalone == true)
        let migrated = try #require(await second.collectionList()["PLmix"])
        #expect(migrated.title == "Mix")
        #expect(migrated.videoIds == [idA])
        #expect(migrated.kind == .playlist)
        #expect(migrated.subtitle == "")
        #expect(migrated.syncResult == nil)
        #expect(migrated.lastSyncedAt == nil)
        // Nothing was deleted on the way: both files are still there.
        #expect(folder.audioFiles == ["\(idA).m4a", "\(idB).m4a"])
        // The next write puts it down as the newer version.
        try await second.saveCollection("PLmix", collection("Mix", [idA, idB]))
        #expect(try readIndexObject(folder)["version"] as? Int == 2)
    }

    @Test("a song committed without saying so stands alone, and committing it for a collection does not change that")
    func commitFlag() async throws {
        let folder = DownloadTestFolder()
        defer { folder.remove() }
        let store = makeStore(folder)
        _ = await store.load()

        let plain = try await commit(idA, standalone: true, into: store)
        #expect(plain.standalone)
        let again = try await commit(idA, standalone: false, into: store)
        #expect(again.standalone, "Downloading a standalone song again for a collection must not drop the flag")
        let listed = try await commit(idB, standalone: false, into: store)
        #expect(!listed.standalone)
    }

    // MARK: - Who keeps a file

    @Test("two collections that share a song: removing one keeps it, removing the other deletes it")
    func overlappingCollections() async throws {
        let folder = DownloadTestFolder()
        defer { folder.remove() }
        let store = makeStore(folder)
        _ = await store.load()
        for id in [idA, idB, idC] { try await commit(id, standalone: false, into: store) }
        try await store.saveCollection("VLone", collection("One", [idA, idB]))
        try await store.saveCollection("VLtwo", collection("Two", [idB, idC]))

        let removedFirst = await store.removeCollection("VLone").dropped

        #expect(removedFirst == [idA])
        #expect(folder.audioFiles == ["\(idB).m4a", "\(idC).m4a"])
        #expect(await store.isDownloaded(idB))

        let removedSecond = await store.removeCollection("VLtwo").dropped

        #expect(removedSecond.sorted() == [idB, idC])
        #expect(folder.audioFiles.isEmpty)
        #expect(await store.collectionList().isEmpty)
        #expect(await store.entries.isEmpty)
    }

    @Test("a song downloaded on its own inside a collection stays when the collection goes")
    func standaloneInsideCollection() async throws {
        let folder = DownloadTestFolder()
        defer { folder.remove() }
        let store = makeStore(folder)
        _ = await store.load()
        try await commit(idA, standalone: true, into: store)
        try await commit(idB, standalone: false, into: store)
        try await store.saveCollection("VLone", collection("One", [idA, idB]))

        let removed = await store.removeCollection("VLone").dropped

        #expect(removed == [idB])
        #expect(folder.audioFiles == ["\(idA).m4a"])
        #expect(await store.entries[idA]?.standalone == true)
    }

    @Test("a song in a collection that is also downloaded on its own: clearing the flag keeps it, and the collection's removal then deletes it")
    func clearStandaloneInsideCollection() async throws {
        let folder = DownloadTestFolder()
        defer { folder.remove() }
        let store = makeStore(folder)
        _ = await store.load()
        try await commit(idA, standalone: true, into: store)
        try await store.saveCollection("VLone", collection("One", [idA]))

        let release = await store.remove(videoId: idA)

        #expect(release == .keptForCollection(try #require(await store.entries[idA])))
        #expect(await store.entries[idA]?.standalone == false)
        #expect(folder.audioFiles == ["\(idA).m4a"])
        #expect(await store.removeCollection("VLone").dropped == [idA])
        #expect(folder.audioFiles.isEmpty)
    }

    @Test("clearing the flag of a song no collection lists deletes the song")
    func clearStandaloneAlone() async throws {
        let folder = DownloadTestFolder()
        defer { folder.remove() }
        let store = makeStore(folder)
        _ = await store.load()
        try await commit(idA, standalone: true, into: store)

        let release = await store.remove(videoId: idA)

        #expect(release == .deleted)
        #expect(folder.audioFiles.isEmpty)
        #expect(await store.entries.isEmpty)
    }

    @Test("a song only a collection held becomes standalone when asked for, and then outlives the collection")
    func setStandalone() async throws {
        let folder = DownloadTestFolder()
        defer { folder.remove() }
        let store = makeStore(folder)
        _ = await store.load()
        try await commit(idA, standalone: false, into: store)
        try await store.saveCollection("VLone", collection("One", [idA]))

        await store.setStandalone(videoId: idA)
        let removed = await store.removeCollection("VLone").dropped

        #expect(removed.isEmpty)
        #expect(folder.audioFiles == ["\(idA).m4a"])
        #expect(await store.entries[idA]?.standalone == true)
    }

    @Test("a sync that drops a song from a collection deletes it unless another holds it or it stands alone")
    func saveCollectionDropsSongs() async throws {
        let folder = DownloadTestFolder()
        defer { folder.remove() }
        let store = makeStore(folder)
        _ = await store.load()
        for id in [idA, idB, idC] { try await commit(id, standalone: false, into: store) }
        try await store.saveCollection("VLone", collection("One", [idA, idB, idC]))
        try await store.saveCollection("VLtwo", collection("Two", [idB]))
        await store.setStandalone(videoId: idC)

        let removed = try await store.saveCollection("VLone", collection("One", [idA]))
        #expect(removed.isEmpty)

        let dropped = try await store.saveCollection("VLone", collection("One", []))
        #expect(dropped == [idA])
        #expect(folder.audioFiles == ["\(idB).m4a", "\(idC).m4a"])
        #expect(await store.collectionList()["VLone"]?.videoIds == [])
    }

    @Test("a removal can keep a file for a song that is playing, which removeFileIfUnlisted deletes later")
    func removalKeepingFiles() async throws {
        let folder = DownloadTestFolder()
        defer { folder.remove() }
        let store = makeStore(folder)
        _ = await store.load()
        try await commit(idA, standalone: false, into: store)
        try await commit(idB, standalone: false, into: store)
        try await store.saveCollection("VLone", collection("One", [idA, idB]))

        let removed = await store.removeCollection("VLone", keepingFiles: [idA]).dropped

        #expect(removed.sorted() == [idA, idB])
        #expect(folder.audioFiles == ["\(idA).m4a"])
        #expect(await store.entries.isEmpty)
        await store.removeFileIfUnlisted(videoId: idA)
        #expect(folder.audioFiles.isEmpty)
    }

    @Test("removing a collection that is not there changes nothing")
    func removeUnknownCollection() async throws {
        let folder = DownloadTestFolder()
        defer { folder.remove() }
        let store = makeStore(folder)
        _ = await store.load()
        try await commit(idA, standalone: true, into: store)

        #expect(await store.removeCollection("VLnothing").dropped.isEmpty)
        #expect(folder.audioFiles == ["\(idA).m4a"])
    }

    @Test("isHeld says whether a collection lists the song")
    func isHeld() async throws {
        let folder = DownloadTestFolder()
        defer { folder.remove() }
        let store = makeStore(folder)
        _ = await store.load()
        try await store.saveCollection("VLone", collection("One", [idA]))

        #expect(await store.isHeld(idA))
        #expect(await store.isHeld(idB) == false)
    }

    // MARK: - What the store cannot read

    @Test("a collection this version cannot read is kept as it was, and holds every song, so nothing is deleted on its behalf")
    func unreadableCollectionHoldsEverything() async throws {
        let folder = DownloadTestFolder()
        defer { folder.remove() }
        let first = makeStore(folder)
        _ = await first.load()
        try await commit(idA, standalone: false, into: first)
        try await commit(idB, standalone: false, into: first)
        try await first.saveCollection("VLone", collection("One", [idA]))
        // A later build's collection: a kind this one does not know.
        var object = try readIndexObject(folder)
        var collections = try #require(object["collections"] as? [String: Any])
        collections["VLfuture"] = ["title": "Podcast", "videoIds": [idB], "kind": "podcast"]
        object["collections"] = collections
        try folder.write(try JSONSerialization.data(withJSONObject: object), to: folder.indexURL)

        let second = makeStore(folder)
        _ = await second.load()
        let removed = await second.removeCollection("VLone").dropped

        #expect(removed.isEmpty, "A collection that could not be read might hold the song")
        #expect(folder.audioFiles == ["\(idA).m4a", "\(idB).m4a"])
        let kept = try #require(try readIndexObject(folder)["collections"] as? [String: Any])
        #expect(kept["VLfuture"] != nil)
        #expect(kept["VLone"] == nil)
    }

    @Test("an index that cannot be read at all blocks collection writes and deletes nothing")
    func blockedStoreChangesNothing() async throws {
        let folder = DownloadTestFolder()
        defer { folder.remove() }
        let first = makeStore(folder)
        _ = await first.load()
        try await commit(idA, standalone: false, into: first)
        try await first.saveCollection("VLone", collection("One", [idA]))
        try folder.lock(folder.indexURL)

        let second = makeStore(folder)
        _ = await second.load()

        await #expect(throws: MusicDownloadError.self) {
            try await second.saveCollection("VLtwo", collection("Two", [idB]))
        }
        #expect(await second.removeCollection("VLone").dropped.isEmpty)
        try folder.unlock(folder.indexURL)
        #expect(folder.audioFiles == ["\(idA).m4a"])
        #expect(await second.collectionList().isEmpty)
    }

    @Test("a write that fails leaves the collections as they were in memory, and deletes no file")
    func failedWriteRollsBack() async throws {
        let folder = DownloadTestFolder()
        defer { folder.remove() }
        let store = makeStore(folder)
        _ = await store.load()
        try await commit(idA, standalone: false, into: store)
        try await store.saveCollection("VLone", collection("One", [idA]))
        // The root cannot take a new index: the atomic write needs to create a file beside it.
        try folder.lock(folder.root)

        await #expect(throws: (any Error).self) {
            try await store.saveCollection("VLone", collection("One", []))
        }
        try folder.unlock(folder.root, isDirectory: true)

        #expect(await store.collectionList()["VLone"]?.videoIds == [idA])
        #expect(await store.entries[idA] != nil)
        #expect(folder.audioFiles == ["\(idA).m4a"])
    }

    // MARK: - Loading

    @Test("loading sweeps a song no collection lists and that does not stand alone, since nothing wants its file")
    func loadSweepsUnheldSongs() async throws {
        let folder = DownloadTestFolder()
        defer { folder.remove() }
        let first = makeStore(folder)
        _ = await first.load()
        try await commit(idA, standalone: false, into: first)
        try await commit(idB, standalone: true, into: first)
        try await commit(idC, standalone: false, into: first)
        try await first.saveCollection("VLone", collection("One", [idC]))

        let second = makeStore(folder)
        let loaded = await second.load()

        #expect(loaded.keys.sorted() == [idB, idC])
        #expect(folder.audioFiles == ["\(idB).m4a", "\(idC).m4a"])
    }

    @Test("loading keeps a collection's song ids that are not downloaded yet: a sync downloads them")
    func loadKeepsMissingSongIDs() async throws {
        let folder = DownloadTestFolder()
        defer { folder.remove() }
        let first = makeStore(folder)
        _ = await first.load()
        try await commit(idA, standalone: false, into: first)
        try await first.saveCollection("VLone", collection("One", [idA, idB, idC]))

        let second = makeStore(folder)
        _ = await second.load()

        #expect(await second.collectionList()["VLone"]?.videoIds == [idA, idB, idC])
    }

    @Test("the unheld sweep stands down when a collection could not be read")
    func unheldSweepNeedsEveryCollection() async throws {
        let folder = DownloadTestFolder()
        defer { folder.remove() }
        let first = makeStore(folder)
        _ = await first.load()
        try await commit(idA, standalone: false, into: first)
        var object = try readIndexObject(folder)
        object["collections"] = ["VLfuture": ["title": "Podcast", "videoIds": [idA], "kind": "podcast"]]
        try folder.write(try JSONSerialization.data(withJSONObject: object), to: folder.indexURL)

        let second = makeStore(folder)
        let loaded = await second.load()

        #expect(loaded.keys.sorted() == [idA])
        #expect(folder.audioFiles == ["\(idA).m4a"])
    }

    // MARK: - Covers

    @Test("a cover saved for a song lives under covers/ and the song's entry names it")
    func songCover() async throws {
        let folder = DownloadTestFolder()
        defer { folder.remove() }
        let store = makeStore(folder)
        _ = await store.load()
        try await commit(idA, standalone: true, into: store)
        let name = MusicDownloadCovers.name(for: URL(string: "https://example.test/a.jpg")!)

        let saved = await store.saveCover(Data("cover-a".utf8), named: name, forVideoId: idA)
        await store.flushIndex()

        #expect(saved)
        #expect(await store.entries[idA]?.coverFile == name)
        let url = try #require(store.coverURL(named: name))
        #expect(url.deletingLastPathComponent().lastPathComponent == "covers")
        #expect(folder.read(url) == Data("cover-a".utf8))
        let second = makeStore(folder)
        #expect(await second.load()[idA]?.coverFile == name)
    }

    @Test("a cover saved for a collection is named by the collection's record")
    func collectionCover() async throws {
        let folder = DownloadTestFolder()
        defer { folder.remove() }
        let store = makeStore(folder)
        _ = await store.load()
        try await store.saveCollection("VLone", collection("One", [idA]))
        let name = MusicDownloadCovers.name(for: URL(string: "https://example.test/c.jpg")!)

        #expect(await store.saveCover(Data("cover-c".utf8), named: name, forCollection: "VLone"))

        #expect(await store.collectionList()["VLone"]?.coverFile == name)
        #expect(folder.read(try #require(store.coverURL(named: name))) == Data("cover-c".utf8))
    }

    @Test("a cover for a song or collection that is not there is not written")
    func coverForNothing() async throws {
        let folder = DownloadTestFolder()
        defer { folder.remove() }
        let store = makeStore(folder)
        _ = await store.load()
        let name = MusicDownloadCovers.name(for: URL(string: "https://example.test/a.jpg")!)

        #expect(await store.saveCover(Data("x".utf8), named: name, forVideoId: idA) == false)
        #expect(await store.saveCover(Data("x".utf8), named: name, forCollection: "VLnone") == false)
        #expect(!folder.exists(folder.root.appendingPathComponent("covers")))
    }

    @Test("a cover name that could leave the covers folder is refused")
    func coverNamesAreChecked() async throws {
        let folder = DownloadTestFolder()
        defer { folder.remove() }
        let store = makeStore(folder)
        _ = await store.load()
        try await commit(idA, standalone: true, into: store)

        for name in ["../escape.img", "a/b.img", "", ".img", "UPPER.img", "abc", "abc.png"] {
            #expect(await store.saveCover(Data("x".utf8), named: name, forVideoId: idA) == false, "\(name)")
            #expect(store.coverURL(named: name) == nil, "\(name)")
        }
        #expect(!folder.exists(folder.root.appendingPathComponent("covers")))
        #expect(folder.rootFiles == ["audio", "downloads.json"])
    }

    @Test("songs that share a cover share the file, which goes only when the last of them does")
    func sharedCoverIsCounted() async throws {
        let folder = DownloadTestFolder()
        defer { folder.remove() }
        let store = makeStore(folder)
        _ = await store.load()
        try await commit(idA, standalone: false, into: store)
        try await commit(idB, standalone: false, into: store)
        try await store.saveCollection("VLone", collection("One", [idA]))
        try await store.saveCollection("VLtwo", collection("Two", [idB]))
        let name = MusicDownloadCovers.name(for: URL(string: "https://example.test/shared.jpg")!)
        #expect(await store.saveCover(Data("shared".utf8), named: name, forVideoId: idA))
        #expect(await store.saveCover(Data("shared".utf8), named: name, forVideoId: idB))
        let coverPath = try #require(store.coverURL(named: name))

        await store.removeCollection("VLone")
        #expect(folder.exists(coverPath), "The second song still shows the cover")

        await store.removeCollection("VLtwo")
        #expect(!folder.exists(coverPath))
    }

    @Test("removing a collection deletes its cover and its songs' covers, and keeps a standalone song's")
    func coversCleanedUp() async throws {
        let folder = DownloadTestFolder()
        defer { folder.remove() }
        let store = makeStore(folder)
        _ = await store.load()
        try await commit(idA, standalone: false, into: store)
        try await commit(idB, standalone: true, into: store)
        try await store.saveCollection("VLone", collection("One", [idA, idB]))
        let nameA = MusicDownloadCovers.name(for: URL(string: "https://example.test/a.jpg")!)
        let nameB = MusicDownloadCovers.name(for: URL(string: "https://example.test/b.jpg")!)
        let nameC = MusicDownloadCovers.name(for: URL(string: "https://example.test/collection.jpg")!)
        #expect(await store.saveCover(Data("a".utf8), named: nameA, forVideoId: idA))
        #expect(await store.saveCover(Data("b".utf8), named: nameB, forVideoId: idB))
        #expect(await store.saveCover(Data("c".utf8), named: nameC, forCollection: "VLone"))

        await store.removeCollection("VLone")

        let covers = folder.root.appendingPathComponent("covers")
        let left = ((try? FileManager.default.contentsOfDirectory(atPath: covers.path)) ?? []).sorted()
        #expect(left == [nameB])
    }

    @Test("a cover replaced by a new one for the same song removes the old file")
    func replacedCoverGoes() async throws {
        let folder = DownloadTestFolder()
        defer { folder.remove() }
        let store = makeStore(folder)
        _ = await store.load()
        try await commit(idA, standalone: true, into: store)
        let old = MusicDownloadCovers.name(for: URL(string: "https://example.test/old.jpg")!)
        let new = MusicDownloadCovers.name(for: URL(string: "https://example.test/new.jpg")!)
        #expect(await store.saveCover(Data("old".utf8), named: old, forVideoId: idA))
        #expect(await store.saveCover(Data("new".utf8), named: new, forVideoId: idA))

        let covers = folder.root.appendingPathComponent("covers")
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: covers.path)) ?? []) == [new])
    }

    @Test("loading sweeps cover files nothing names, and clears the name of a cover whose file is gone")
    func loadSweepsCovers() async throws {
        let folder = DownloadTestFolder()
        defer { folder.remove() }
        let first = makeStore(folder)
        _ = await first.load()
        try await commit(idA, standalone: true, into: first)
        try await commit(idB, standalone: true, into: first)
        let nameA = MusicDownloadCovers.name(for: URL(string: "https://example.test/a.jpg")!)
        let nameB = MusicDownloadCovers.name(for: URL(string: "https://example.test/b.jpg")!)
        let stray = MusicDownloadCovers.name(for: URL(string: "https://example.test/stray.jpg")!)
        #expect(await first.saveCover(Data("a".utf8), named: nameA, forVideoId: idA))
        #expect(await first.saveCover(Data("b".utf8), named: nameB, forVideoId: idB))
        try folder.write(Data("stray".utf8), to: folder.root.appendingPathComponent("covers/\(stray)"))
        try FileManager.default.removeItem(at: try #require(first.coverURL(named: nameB)))
        await first.flushIndex()

        let second = makeStore(folder)
        let loaded = await second.load()

        #expect(loaded[idA]?.coverFile == nameA)
        #expect(loaded[idB]?.coverFile == nil)
        let covers = folder.root.appendingPathComponent("covers")
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: covers.path)) ?? []) == [nameA])
    }

    @Test("cover files are left alone when an entry could not be read, since it may name one")
    func coversKeptWhileSomethingIsUnread() async throws {
        let folder = DownloadTestFolder()
        defer { folder.remove() }
        let first = makeStore(folder)
        _ = await first.load()
        try await commit(idA, standalone: true, into: first)
        let stray = MusicDownloadCovers.name(for: URL(string: "https://example.test/stray.jpg")!)
        try folder.write(Data("stray".utf8), to: folder.root.appendingPathComponent("covers/\(stray)"))
        var object = try readIndexObject(folder)
        var entries = try #require(object["entries"] as? [String: Any])
        entries[idB] = ["track": ["nope": true], "bytes": 5]
        object["entries"] = entries
        try folder.write(try JSONSerialization.data(withJSONObject: object), to: folder.indexURL)

        let second = makeStore(folder)
        _ = await second.load()

        #expect(folder.exists(folder.root.appendingPathComponent("covers/\(stray)")))
    }

    // MARK: - The launch check

    @Test("the launch check says whether the index lists any collection, without loading the store")
    func indexHasCollections() async throws {
        let folder = DownloadTestFolder()
        defer { folder.remove() }
        #expect(MusicDownloadStore.indexHasCollections(at: folder.root) == false)

        let store = makeStore(folder)
        _ = await store.load()
        try await commit(idA, standalone: true, into: store)
        #expect(MusicDownloadStore.indexHasCollections(at: folder.root) == false)

        try await store.saveCollection("VLone", collection("One", [idA]))
        #expect(MusicDownloadStore.indexHasCollections(at: folder.root))

        try folder.write(Data("not json".utf8), to: folder.indexURL)
        #expect(MusicDownloadStore.indexHasCollections(at: folder.root) == false)
    }

    // MARK: - Held drops

    @Test("a held drop round trips through the index with its ids and its time")
    func heldDropRoundTrip() async throws {
        let folder = DownloadTestFolder()
        defer { folder.remove() }
        let first = makeStore(folder)
        _ = await first.load()
        var record = collection("One", [idA, idB])
        record.heldDrop = .init(videoIds: [idB], since: Date(timeIntervalSince1970: 1_700_000_300))
        try await first.saveCollection("VLone", record)

        let second = makeStore(folder)
        _ = await second.load()

        #expect(await second.collectionList()["VLone"]?.heldDrop == record.heldDrop)
        #expect(await second.collectionList()["VLone"] == record)
    }

    @Test("a record written before held drops existed has none, and is not held back as unreadable")
    func recordWithoutHeldDrop() async throws {
        let folder = DownloadTestFolder()
        defer { folder.remove() }
        let first = makeStore(folder)
        _ = await first.load()
        try await commit(idA, standalone: false, into: first)
        var object = try readIndexObject(folder)
        object["collections"] = ["VLone": ["title": "One", "videoIds": [idA]]]
        try folder.write(try JSONSerialization.data(withJSONObject: object), to: folder.indexURL)

        let second = makeStore(folder)
        _ = await second.load()

        #expect(await second.collectionList()["VLone"]?.heldDrop == nil)
        #expect(await second.removeCollection("VLone").dropped == [idA])
    }

    @Test("a held drop this version cannot read is dropped, and the record is kept")
    func unreadableHeldDropIsDropped() async throws {
        let folder = DownloadTestFolder()
        defer { folder.remove() }
        let first = makeStore(folder)
        _ = await first.load()
        try await commit(idA, standalone: false, into: first)
        var object = try readIndexObject(folder)
        object["collections"] = ["VLone": ["title": "One", "videoIds": [idA], "heldDrop": "garbage"]]
        try folder.write(try JSONSerialization.data(withJSONObject: object), to: folder.indexURL)

        let second = makeStore(folder)
        _ = await second.load()

        let record = try #require(await second.collectionList()["VLone"])
        #expect(record.videoIds == [idA])
        #expect(record.heldDrop == nil)
        #expect(await second.removeCollection("VLone").dropped == [idA])
    }

    // MARK: - Removing a song

    @Test("removing a song only a collection holds keeps its entry and its file")
    func removeKeepsCollectionOnlySong() async throws {
        let folder = DownloadTestFolder()
        defer { folder.remove() }
        let store = makeStore(folder)
        _ = await store.load()
        let entry = try await commit(idA, standalone: false, into: store)
        try await store.saveCollection("VLone", collection("One", [idA]))

        let release = await store.remove(videoId: idA)

        #expect(release == .keptForCollection(entry))
        #expect(folder.audioFiles == ["\(idA).m4a"])
        #expect(await store.entries[idA] == entry)
    }

    @Test("removing a song a collection lists clears the flag on disk too, and deletes nothing")
    func removeClearsFlagOnDisk() async throws {
        let folder = DownloadTestFolder()
        defer { folder.remove() }
        let store = makeStore(folder)
        _ = await store.load()
        try await commit(idA, standalone: true, into: store)
        try await store.saveCollection("VLone", collection("One", [idA]))

        _ = await store.remove(videoId: idA, keepingFile: false)
        await store.flushIndex()

        let entries = try #require(try readIndexObject(folder)["entries"] as? [String: Any])
        let entry = try #require(entries[idA] as? [String: Any])
        #expect(entry["standalone"] as? Bool == false)
        #expect(folder.audioFiles == ["\(idA).m4a"])
    }

    @Test("a song stays while a record this version cannot read might list it")
    func removeKeepsWhileARecordIsUnread() async throws {
        let folder = DownloadTestFolder()
        defer { folder.remove() }
        let first = makeStore(folder)
        _ = await first.load()
        try await commit(idA, standalone: true, into: first)
        var object = try readIndexObject(folder)
        object["collections"] = ["VLfuture": ["title": "Podcast", "videoIds": [idB], "kind": "podcast"]]
        try folder.write(try JSONSerialization.data(withJSONObject: object), to: folder.indexURL)
        let second = makeStore(folder)
        _ = await second.load()

        let release = await second.remove(videoId: idA)

        guard case .keptForCollection = release else {
            Issue.record("The unread record might list the song, so the file must stay")
            return
        }
        #expect(folder.audioFiles == ["\(idA).m4a"])
    }

    @Test("discarding a damaged song deletes its entry and file even though a collection lists it")
    func discardIgnoresCollections() async throws {
        let folder = DownloadTestFolder()
        defer { folder.remove() }
        let store = makeStore(folder)
        _ = await store.load()
        try await commit(idA, standalone: false, into: store)
        try await commit(idB, standalone: true, into: store)
        try await store.saveCollection("VLone", collection("One", [idA, idB]))

        await store.discard(videoId: idA)
        await store.discard(videoId: idB)

        #expect(await store.entries.isEmpty)
        #expect(folder.audioFiles.isEmpty)
        // The list still names the songs, so a sync fetches them again.
        #expect(await store.collectionList()["VLone"]?.videoIds == [idA, idB])
        let entries = try #require(try readIndexObject(folder)["entries"] as? [String: Any])
        #expect(entries.isEmpty)
    }

    // MARK: - Removing a collection

    @Test("a collection removal whose index write fails puts the record back, says so, and deletes nothing")
    func removalRestoredWhenTheWriteFails() async throws {
        let folder = DownloadTestFolder()
        defer { folder.remove() }
        let store = makeStore(folder)
        _ = await store.load()
        try await commit(idA, standalone: false, into: store)
        let record = collection("One", [idA])
        try await store.saveCollection("VLone", record)
        try folder.lock(folder.root)

        let removal = await store.removeCollection("VLone")
        try folder.unlock(folder.root, isDirectory: true)

        #expect(removal.dropped.isEmpty)
        #expect(removal.restored == record)
        #expect(await store.collectionList()["VLone"] == record)
        #expect(await store.entries[idA] != nil)
        #expect(folder.audioFiles == ["\(idA).m4a"])
    }

    @Test("a removal that worked restores nothing")
    func removalNotRestored() async throws {
        let folder = DownloadTestFolder()
        defer { folder.remove() }
        let store = makeStore(folder)
        _ = await store.load()
        try await commit(idA, standalone: false, into: store)
        try await store.saveCollection("VLone", collection("One", [idA]))

        let removal = await store.removeCollection("VLone")

        #expect(removal.dropped == [idA])
        #expect(removal.restored == nil)
    }
}
