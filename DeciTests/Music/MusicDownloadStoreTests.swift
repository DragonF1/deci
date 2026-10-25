// DeciTests/Music/MusicDownloadStoreTests.swift
// The downloads folder on disk: the index across launches, what loading drops and sweeps, the video id check that
// keeps every path inside the folder, the .part file that is never a download, and removal. Every test works in a
// folder of its own under /Volumes/Storage/_test, removed when it ends.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("MusicDownloadStore")
struct MusicDownloadStoreTests {
    private let idA = DownloadSamples.idA
    private let idB = DownloadSamples.idB

    private func makeStore(_ folder: DownloadTestFolder) -> MusicDownloadStore {
        MusicDownloadStore(root: folder.root, now: { DownloadSamples.fixedDate })
    }

    /// Puts `count` bytes in the id's .part file the way the downloader does, and commits them.
    @discardableResult
    private func download(
        _ id: String, bytes count: Int = 40, into store: MusicDownloadStore, duration: Double? = 201.5
    ) async throws -> MusicDownloadStore.Entry {
        let part = try await store.beginPart(videoId: id)
        try DownloadSamples.payload(count).write(to: part)
        return try await store.commit(DownloadSamples.track(id), expectedBytes: Int64(count), durationSeconds: duration)
    }

    // MARK: - The index

    @Test("the index round trips: a second store on the same folder sees what the first committed")
    func indexRoundTrip() async throws {
        let folder = DownloadTestFolder()
        defer { folder.remove() }
        let first = makeStore(folder)
        _ = await first.load()
        let entry = try await download(idA, into: first)

        let second = makeStore(folder)
        let loaded = await second.load()

        #expect(loaded == [idA: entry])
        #expect(loaded[idA]?.track == DownloadSamples.track(idA))
        #expect(loaded[idA]?.bytes == 40)
        #expect(loaded[idA]?.downloadedAt == DownloadSamples.fixedDate)
        #expect(loaded[idA]?.durationSeconds == 201.5)
        #expect(folder.read(folder.audioURL(idA)) == DownloadSamples.payload(40))
    }

    @Test("the layout is audio/<id>.m4a beside downloads.json, and no temp file is left behind")
    func layout() async throws {
        let folder = DownloadTestFolder()
        defer { folder.remove() }
        let store = makeStore(folder)
        _ = await store.load()
        try await download(idA, into: store)

        #expect(folder.rootFiles == ["audio", "downloads.json"])
        #expect(folder.audioFiles == ["\(idA).m4a"])
        let index = try #require(folder.read(folder.indexURL).flatMap(MusicDownloadStore.Index.decode))
        #expect(index.entries.keys.sorted() == [idA])
    }

    @Test("loading with no folder yet gives an empty index and creates nothing")
    func loadCreatesNothing() async {
        let folder = DownloadTestFolder()
        defer { folder.remove() }
        let store = makeStore(folder)

        #expect(await store.load().isEmpty)
        #expect(!folder.exists(folder.root))
    }

    @Test("an entry whose audio file is missing is dropped, and the index is rewritten without it")
    func missingFileDropsEntry() async throws {
        let folder = DownloadTestFolder()
        defer { folder.remove() }
        let first = makeStore(folder)
        _ = await first.load()
        try await download(idA, into: first)
        try await download(idB, into: first)
        try FileManager.default.removeItem(at: folder.audioURL(idA))

        let second = makeStore(folder)
        let loaded = await second.load()

        #expect(loaded.keys.sorted() == [idB])
        let index = try #require(folder.read(folder.indexURL).flatMap(MusicDownloadStore.Index.decode))
        #expect(index.entries.keys.sorted() == [idB])
        #expect(await second.isDownloaded(idA) == false)
        #expect(await second.isDownloaded(idB))
    }

    @Test("a .part file never counts as a download, even when the index lists the id")
    func partIsNotADownload() async throws {
        let folder = DownloadTestFolder()
        defer { folder.remove() }
        let first = makeStore(folder)
        _ = await first.load()
        try await download(idA, into: first)
        // The audio is gone and only a half-written .part is left, as after a crash during a re-download.
        try FileManager.default.removeItem(at: folder.audioURL(idA))
        try DownloadSamples.payload(10).write(to: folder.partURL(idA))

        let second = makeStore(folder)
        let loaded = await second.load()

        #expect(loaded.isEmpty)
        #expect(await second.isDownloaded(idA) == false)
        #expect(!folder.exists(folder.partURL(idA)))
    }

    @Test("a download in progress is not downloaded until it is committed")
    func inProgressIsNotDownloaded() async throws {
        let folder = DownloadTestFolder()
        defer { folder.remove() }
        let store = makeStore(folder)
        _ = await store.load()

        let part = try await store.beginPart(videoId: idA)
        try DownloadSamples.payload(10).write(to: part)

        #expect(part.lastPathComponent == "\(idA).m4a.part")
        #expect(await store.isDownloaded(idA) == false)
        #expect(await store.entries.isEmpty)
        #expect(!folder.exists(folder.audioURL(idA)))
    }

    @Test("loading sweeps .part files left by a crash")
    func loadSweepsParts() async throws {
        let folder = DownloadTestFolder()
        defer { folder.remove() }
        try folder.write(DownloadSamples.payload(10), to: folder.partURL(idA))

        let store = makeStore(folder)
        _ = await store.load()

        #expect(folder.audioFiles.isEmpty)
    }

    @Test("loading sweeps audio no index entry owns, since a crash between the rename and the index write leaves one")
    func loadSweepsOrphans() async throws {
        let folder = DownloadTestFolder()
        defer { folder.remove() }
        let first = makeStore(folder)
        _ = await first.load()
        try await download(idA, into: first)
        try folder.write(DownloadSamples.payload(12), to: folder.audioURL(idB))

        let second = makeStore(folder)
        let loaded = await second.load()

        #expect(loaded.keys.sorted() == [idA])
        #expect(folder.audioFiles == ["\(idA).m4a"])
    }

    @Test("an unreadable index is moved aside, not deleted, and no audio is swept without an index to judge it by")
    func unreadableIndexMovedAside() async throws {
        let folder = DownloadTestFolder()
        defer { folder.remove() }
        let garbage = Data("{ not an index".utf8)
        try folder.write(garbage, to: folder.indexURL)
        try folder.write(DownloadSamples.payload(12), to: folder.audioURL(idA))

        let store = makeStore(folder)
        let loaded = await store.load()

        #expect(loaded.isEmpty)
        #expect(folder.read(folder.root.appendingPathComponent("downloads.json.unreadable")) == garbage)
        #expect(folder.audioFiles == ["\(idA).m4a"])
        // A new download works and writes a fresh, readable index.
        try await download(idB, into: store)
        #expect(folder.read(folder.indexURL).flatMap(MusicDownloadStore.Index.decode) != nil)
    }

    @Test("an index of a newer format is left alone the same way")
    func newerIndexMovedAside() async throws {
        let folder = DownloadTestFolder()
        defer { folder.remove() }
        let future = Data(#"{"version":99,"entries":{},"collections":{}}"#.utf8)
        try folder.write(future, to: folder.indexURL)

        let store = makeStore(folder)
        #expect(await store.load().isEmpty)

        #expect(folder.read(folder.root.appendingPathComponent("downloads.json.unreadable")) == future)
    }

    @Test("collections survive loading and every rewrite, so playlists and albums can reference ids later")
    func collectionsSurvive() async throws {
        let folder = DownloadTestFolder()
        defer { folder.remove() }
        let first = makeStore(folder)
        _ = await first.load()
        try await download(idA, into: first)

        // A later phase's collection, written into the index by hand.
        var index = try #require(folder.read(folder.indexURL).flatMap(MusicDownloadStore.Index.decode))
        index.collections["PLmix"] = MusicDownloadStore.Collection(title: "Mix", videoIds: [idA])
        try folder.write(try index.encoded(), to: folder.indexURL)

        let second = makeStore(folder)
        _ = await second.load()
        try await download(idB, into: second)

        let rewritten = try #require(folder.read(folder.indexURL).flatMap(MusicDownloadStore.Index.decode))
        #expect(rewritten.collections == ["PLmix": MusicDownloadStore.Collection(title: "Mix", videoIds: [idA])])
        #expect(rewritten.entries.keys.sorted() == [idA, idB])
    }

    @Test("an index entry with a path in place of a video id is dropped and touches nothing outside the audio folder")
    func hostileIndexKey() async throws {
        let folder = DownloadTestFolder()
        defer { folder.remove() }
        // "../victim" would resolve to <root>/victim.m4a: a file that exists, so only the id check can drop the entry.
        let victim = folder.root.appendingPathComponent("victim.m4a")
        try folder.write(Data("keep".utf8), to: victim)
        let hostile = MusicDownloadStore.Entry(
            track: DownloadSamples.track("../victim"), bytes: 4, downloadedAt: DownloadSamples.fixedDate, durationSeconds: nil
        )
        try folder.write(try MusicDownloadStore.Index(entries: ["../victim": hostile]).encoded(), to: folder.indexURL)

        let store = makeStore(folder)
        let loaded = await store.load()

        #expect(loaded.isEmpty)
        #expect(folder.read(victim) == Data("keep".utf8))
        let index = try #require(folder.read(folder.indexURL).flatMap(MusicDownloadStore.Index.decode))
        #expect(index.entries.isEmpty)
    }

    // MARK: - The video id

    @Test("only eleven characters from A-Z, a-z, 0-9, underscore and hyphen are a video id")
    func videoIdRule() {
        for valid in ["dQw4w9WgXcQ", "a-b_c-d_e-f", "___________", "-----------", "00000000000"] {
            #expect(MusicDownloadStore.isValidVideoId(valid), "\(valid)")
        }
        for invalid in [
            "", "short", "tenchars10", "twelve_chars", "abc/defghij", "abc defghij", "../../abcde", "abc.defghij",
            "ééééééééééé", "abcdefghij\n", "abcdefghij\u{0}", "abc\\defghij",
        ] {
            #expect(!MusicDownloadStore.isValidVideoId(invalid), "\(invalid.debugDescription)")
        }
    }

    @Test("a bad id has no path, and beginning a download for it is refused")
    func badIdRejected() async throws {
        let folder = DownloadTestFolder()
        defer { folder.remove() }
        let store = makeStore(folder)
        _ = await store.load()

        #expect(store.audioURL(for: "../../etc/passwd") == nil)
        #expect(store.partURL(for: "../../etc/passwd") == nil)
        #expect(store.audioURL(for: idA)?.path == folder.audioURL(idA).path)
        await #expect(throws: MusicDownloadError.invalidVideoId) {
            _ = try await store.beginPart(videoId: "../../etc/passwd")
        }
        await #expect(throws: MusicDownloadError.invalidVideoId) {
            _ = try await store.commit(
                DownloadSamples.track("../../etc/passwd"), expectedBytes: 1, durationSeconds: nil
            )
        }
        #expect(await store.remove(videoId: "../../etc/passwd") == false)
        #expect(!folder.exists(folder.root))
    }

    // MARK: - Committing

    @Test("a part whose size is not the expected length is deleted and never listed")
    func commitSizeMismatch() async throws {
        let folder = DownloadTestFolder()
        defer { folder.remove() }
        let store = makeStore(folder)
        _ = await store.load()
        let part = try await store.beginPart(videoId: idA)
        try DownloadSamples.payload(30).write(to: part)

        await #expect(throws: MusicDownloadError.lengthMismatch) {
            _ = try await store.commit(DownloadSamples.track(idA), expectedBytes: 40, durationSeconds: nil)
        }

        #expect(folder.audioFiles.isEmpty)
        #expect(await store.entries.isEmpty)
        #expect(await store.isDownloaded(idA) == false)
    }

    @Test("beginning a download again starts from an empty part")
    func beginTruncates() async throws {
        let folder = DownloadTestFolder()
        defer { folder.remove() }
        let store = makeStore(folder)
        _ = await store.load()
        let part = try await store.beginPart(videoId: idA)
        try DownloadSamples.payload(30).write(to: part)

        let again = try await store.beginPart(videoId: idA)

        #expect(again == part)
        #expect(folder.read(again) == Data())
    }

    @Test("downloading a song again replaces its entry and its file")
    func commitReplaces() async throws {
        let folder = DownloadTestFolder()
        defer { folder.remove() }
        let store = makeStore(folder)
        _ = await store.load()
        try await download(idA, bytes: 40, into: store)

        let second = try await download(idA, bytes: 25, into: store)

        #expect(await store.entries == [idA: second])
        #expect(second.bytes == 25)
        #expect(folder.read(folder.audioURL(idA)) == DownloadSamples.payload(25))
        #expect(folder.audioFiles == ["\(idA).m4a"])
    }

    @Test("discarding a part deletes it and nothing else")
    func discardPart() async throws {
        let folder = DownloadTestFolder()
        defer { folder.remove() }
        let store = makeStore(folder)
        _ = await store.load()
        try await download(idA, into: store)
        let part = try await store.beginPart(videoId: idB)
        try DownloadSamples.payload(10).write(to: part)

        await store.discardPart(videoId: idB)

        #expect(folder.audioFiles == ["\(idA).m4a"])
        #expect(await store.isDownloaded(idA))
    }

    // MARK: - Removing

    @Test("removing deletes the file and the entry, and a later store agrees")
    func removeDeletes() async throws {
        let folder = DownloadTestFolder()
        defer { folder.remove() }
        let store = makeStore(folder)
        _ = await store.load()
        try await download(idA, into: store)
        try await download(idB, into: store)

        let removed = await store.remove(videoId: idA)

        #expect(removed)
        #expect(folder.audioFiles == ["\(idB).m4a"])
        #expect(await store.entries.keys.sorted() == [idB])
        #expect(await store.isDownloaded(idA) == false)
        let later = makeStore(folder)
        #expect(await later.load().keys.sorted() == [idB])
    }

    @Test("removing an id nothing was saved for does no harm")
    func removeUnknown() async throws {
        let folder = DownloadTestFolder()
        defer { folder.remove() }
        let store = makeStore(folder)
        _ = await store.load()
        try await download(idA, into: store)

        #expect(await store.remove(videoId: idB) == false)
        #expect(await store.isDownloaded(idA))
    }

    @Test("removing also deletes a part left for the id")
    func removeDeletesPart() async throws {
        let folder = DownloadTestFolder()
        defer { folder.remove() }
        let store = makeStore(folder)
        _ = await store.load()
        let part = try await store.beginPart(videoId: idA)
        try DownloadSamples.payload(10).write(to: part)

        _ = await store.remove(videoId: idA)

        #expect(folder.audioFiles.isEmpty)
    }

    @Test("removing the entry only keeps the file for now, and the file goes once nothing lists it")
    func removeKeepingFile() async throws {
        let folder = DownloadTestFolder()
        defer { folder.remove() }
        let store = makeStore(folder)
        _ = await store.load()
        try await download(idA, into: store)
        try await download(idB, into: store)

        let removed = await store.remove(videoId: idA, keepingFile: true)

        #expect(removed)
        #expect(await store.entries.keys.sorted() == [idB])
        #expect(folder.audioFiles == ["\(idA).m4a", "\(idB).m4a"])
        let index = try #require(folder.read(folder.indexURL).flatMap(MusicDownloadStore.Index.decode))
        #expect(index.entries.keys.sorted() == [idB])

        await store.removeFileIfUnlisted(videoId: idA)
        #expect(folder.audioFiles == ["\(idB).m4a"])
    }

    @Test("a file kept for the playing song is not deleted if the song was downloaded again in the meantime")
    func unlistedFileDeletionSparesRelisted() async throws {
        let folder = DownloadTestFolder()
        defer { folder.remove() }
        let store = makeStore(folder)
        _ = await store.load()
        try await download(idA, bytes: 40, into: store)
        _ = await store.remove(videoId: idA, keepingFile: true)
        try await download(idA, bytes: 25, into: store)

        await store.removeFileIfUnlisted(videoId: idA)

        #expect(folder.read(folder.audioURL(idA)) == DownloadSamples.payload(25))
        #expect(await store.isDownloaded(idA))
    }

    @Test("a file kept for the playing song is swept by the next load if the app quit before it was deleted")
    func keptFileSweptAtNextLoad() async throws {
        let folder = DownloadTestFolder()
        defer { folder.remove() }
        let first = makeStore(folder)
        _ = await first.load()
        try await download(idA, into: first)
        try await download(idB, into: first)
        _ = await first.remove(videoId: idA, keepingFile: true)

        let second = makeStore(folder)
        let loaded = await second.load()

        #expect(loaded.keys.sorted() == [idB])
        #expect(folder.audioFiles == ["\(idB).m4a"])
    }

    // MARK: - Never deleting finished audio

    /// An entry as the store writes it.
    private func entry(_ id: String, bytes: Int64 = 40) -> MusicDownloadStore.Entry {
        MusicDownloadStore.Entry(
            track: DownloadSamples.track(id), bytes: bytes, downloadedAt: DownloadSamples.fixedDate, durationSeconds: 200
        )
    }

    /// An entry a later version wrote: its track lacks a field this version needs, so it cannot be decoded.
    private func driftedEntry(_ id: String, bytes: Int = 12) -> [String: Any] {
        ["track": ["videoId": id, "title": "Song"], "bytes": bytes, "downloadedAt": 1_700_000_000, "newField": true]
    }

    /// Writes `downloads.json` by hand: `good` entries as the store writes them and `bad` ones as raw JSON.
    private func writeIndex(
        _ folder: DownloadTestFolder, good: [String: MusicDownloadStore.Entry] = [:], bad: [String: Any] = [:]
    ) throws {
        var root = try #require(
            JSONSerialization.jsonObject(with: MusicDownloadStore.Index(entries: good).encoded()) as? [String: Any]
        )
        var entries = root["entries"] as? [String: Any] ?? [:]
        for (id, raw) in bad { entries[id] = raw }
        root["entries"] = entries
        try folder.write(try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]), to: folder.indexURL)
    }

    /// The entries object of `downloads.json` as plain JSON, however well the store could read each.
    private func rawEntries(_ folder: DownloadTestFolder) throws -> [String: Any] {
        let data = try #require(folder.read(folder.indexURL))
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(root["entries"] as? [String: Any])
    }

    @Test("an index that cannot be read is not an empty one: no audio is swept, nothing is written, and downloads wait")
    func readFailureKeepsEverything() async throws {
        let folder = DownloadTestFolder()
        defer { folder.remove() }
        try writeIndex(folder, good: [idA: entry(idA), idB: entry(idB)])
        try folder.write(DownloadSamples.payload(40), to: folder.audioURL(idA))
        try folder.write(DownloadSamples.payload(40), to: folder.audioURL(idB))
        let before = try #require(folder.read(folder.indexURL))
        try folder.lock(folder.indexURL)

        let store = makeStore(folder)
        let loaded = await store.load()

        #expect(loaded.isEmpty)
        #expect(folder.audioFiles == ["\(idA).m4a", "\(idB).m4a"])
        await #expect(throws: MusicDownloadError.indexUnavailable) {
            _ = try await store.beginPart(videoId: DownloadSamples.idC)
        }
        try folder.unlock(folder.indexURL)
        #expect(folder.read(folder.indexURL) == before)
        #expect(folder.rootFiles == ["audio", "downloads.json"])

        // The read worked the next time, so both songs are still there.
        let later = makeStore(folder)
        #expect(await later.load().keys.sorted() == [idA, idB])
    }

    @Test("a bad entry among good ones drops only itself: the others load and every audio file stays")
    func badEntryDropsOnlyItself() async throws {
        let folder = DownloadTestFolder()
        defer { folder.remove() }
        try writeIndex(folder, good: [idA: entry(idA)], bad: [idB: driftedEntry(idB)])
        try folder.write(DownloadSamples.payload(40), to: folder.audioURL(idA))
        try folder.write(DownloadSamples.payload(12), to: folder.audioURL(idB))
        try folder.write(DownloadSamples.payload(7), to: folder.audioURL(DownloadSamples.idC))

        let store = makeStore(folder)
        let loaded = await store.load()

        #expect(loaded.keys.sorted() == [idA])
        // Not even the file no entry lists is swept: the index was only partly read.
        #expect(folder.audioFiles == ["\(idA).m4a", "\(idB).m4a", "\(DownloadSamples.idC).m4a"])
    }

    @Test("the index keeps writing a bad entry back as it was, so the next launch does not take its audio for an orphan")
    func badEntrySurvivesRewrites() async throws {
        let folder = DownloadTestFolder()
        defer { folder.remove() }
        try writeIndex(folder, good: [idA: entry(idA)], bad: [idB: driftedEntry(idB)])
        try folder.write(DownloadSamples.payload(40), to: folder.audioURL(idA))
        try folder.write(DownloadSamples.payload(12), to: folder.audioURL(idB))

        let first = makeStore(folder)
        _ = await first.load()
        try await download(DownloadSamples.idC, into: first)

        let written = try rawEntries(folder)
        #expect(written.keys.sorted() == [idA, idB, DownloadSamples.idC])
        #expect(NSDictionary(dictionary: try #require(written[idB] as? [String: Any])).isEqual(to: driftedEntry(idB)))

        // The second launch: the index is read in full again, and still the bad entry's audio is not swept.
        let second = makeStore(folder)
        let loaded = await second.load()
        #expect(loaded.keys.sorted() == [idA, DownloadSamples.idC])
        #expect(folder.audioFiles == ["\(idA).m4a", "\(idB).m4a", "\(DownloadSamples.idC).m4a"])
    }

    @Test("a schema change that makes every entry unreadable deletes no audio, now or on a later launch")
    func schemaDriftKeepsAudio() async throws {
        let folder = DownloadTestFolder()
        defer { folder.remove() }
        try writeIndex(folder, bad: [idA: driftedEntry(idA), idB: driftedEntry(idB)])
        try folder.write(DownloadSamples.payload(12), to: folder.audioURL(idA))
        try folder.write(DownloadSamples.payload(12), to: folder.audioURL(idB))

        let first = makeStore(folder)
        #expect(await first.load().isEmpty)
        try await download(DownloadSamples.idC, into: first)

        let second = makeStore(folder)
        #expect(await second.load().keys.sorted() == [DownloadSamples.idC])
        #expect(folder.audioFiles == ["\(idA).m4a", "\(idB).m4a", "\(DownloadSamples.idC).m4a"])
        #expect(try rawEntries(folder).keys.sorted() == [idA, idB, DownloadSamples.idC])
    }

    @Test("the second launch after an index that could not be decoded still sweeps nothing")
    func secondLaunchAfterUndecodableIndex() async throws {
        let folder = DownloadTestFolder()
        defer { folder.remove() }
        let garbage = Data("{ not an index".utf8)
        try folder.write(garbage, to: folder.indexURL)
        try folder.write(DownloadSamples.payload(12), to: folder.audioURL(idA))

        // First launch: the index is moved aside and a new download writes a fresh, readable one.
        let first = makeStore(folder)
        #expect(await first.load().isEmpty)
        try await download(idB, into: first)

        // Second launch: the fresh index decodes in full, and the old audio is still no orphan to sweep.
        let second = makeStore(folder)
        let loaded = await second.load()

        #expect(loaded.keys.sorted() == [idB])
        #expect(folder.audioFiles == ["\(idA).m4a", "\(idB).m4a"])
        #expect(folder.read(folder.root.appendingPathComponent("downloads.json.unreadable")) == garbage)
    }

    @Test("a lost index with audio beside it is no empty index: that audio is kept on every launch")
    func lostIndexKeepsAudio() async throws {
        let folder = DownloadTestFolder()
        defer { folder.remove() }
        try folder.write(DownloadSamples.payload(12), to: folder.audioURL(idA))

        let first = makeStore(folder)
        #expect(await first.load().isEmpty)
        try await download(idB, into: first)

        let second = makeStore(folder)
        #expect(await second.load().keys.sorted() == [idB])
        #expect(folder.audioFiles == ["\(idA).m4a", "\(idB).m4a"])
    }

    @Test("an index of a newer format keeps its audio on later launches too")
    func secondLaunchAfterNewerIndex() async throws {
        let folder = DownloadTestFolder()
        defer { folder.remove() }
        try folder.write(Data(#"{"version":99,"entries":{},"collections":{}}"#.utf8), to: folder.indexURL)
        try folder.write(DownloadSamples.payload(12), to: folder.audioURL(idA))

        let first = makeStore(folder)
        _ = await first.load()
        try await download(idB, into: first)
        let second = makeStore(folder)
        _ = await second.load()

        #expect(folder.audioFiles == ["\(idA).m4a", "\(idB).m4a"])
    }

    @Test("a second index set aside does not replace the first")
    func asideFilesAreKept() async throws {
        let folder = DownloadTestFolder()
        defer { folder.remove() }
        let first = Data("{ first".utf8)
        let second = Data("{ second".utf8)
        try folder.write(first, to: folder.indexURL)
        _ = await makeStore(folder).load()
        try folder.write(second, to: folder.indexURL)
        _ = await makeStore(folder).load()

        let asides = folder.rootFiles.filter { $0.hasPrefix("downloads.json.unreadable") }
        let contents = asides.compactMap { folder.read(folder.root.appendingPathComponent($0)) }
        #expect(asides.count == 2)
        #expect(Set(contents) == [first, second])
    }

    @Test("an entry whose file is not the size the index says is dropped and its file deleted")
    func sizeMismatchAtLoad() async throws {
        let folder = DownloadTestFolder()
        defer { folder.remove() }
        try writeIndex(folder, good: [idA: entry(idA, bytes: 40), idB: entry(idB, bytes: 40)])
        try folder.write(DownloadSamples.payload(40), to: folder.audioURL(idA))
        try folder.write(DownloadSamples.payload(31), to: folder.audioURL(idB))

        let store = makeStore(folder)
        let loaded = await store.load()

        #expect(loaded.keys.sorted() == [idA])
        #expect(folder.audioFiles == ["\(idA).m4a"])
        let index = try #require(folder.read(folder.indexURL).flatMap(MusicDownloadStore.Index.decode))
        #expect(index.entries.keys.sorted() == [idA])
    }

    // MARK: - Where it lives

    @Test("the folder is left out of backups")
    func excludedFromBackup() async throws {
        let folder = DownloadTestFolder()
        defer { folder.remove() }
        let store = makeStore(folder)
        _ = await store.load()
        try await download(idA, into: store)

        let values = try folder.root.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    @Test("a folder that cannot be written to fails a download with the disk's own error")
    func unwritableAudioFolder() async throws {
        let folder = DownloadTestFolder()
        defer { folder.remove() }
        let store = makeStore(folder)
        _ = await store.load()
        try await download(idA, into: store)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.audioDirectory.path)

        do {
            _ = try await store.beginPart(videoId: idB)
            Issue.record("beginPart should have thrown")
        } catch {
            let nsError = error as NSError
            #expect(nsError.domain == NSCocoaErrorDomain)
            #expect(nsError.code == CocoaError.fileWriteNoPermission.rawValue)
        }
        #expect(folder.audioFiles == ["\(idA).m4a"])
    }
}
