// DeciTests/Music/MusicDownloadFlushTests.swift
// How often the store writes its index. Songs and covers being added are written together a moment later, not once
// each; anything that deletes a file, and every collection change, still writes first. A write that failed is kept and
// tried again with the next. Every test works in a folder of its own under /Volumes/Storage/_test, removed when it ends.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("MusicDownloadFlush")
struct MusicDownloadFlushTests {
    private let idA = DownloadSamples.idA
    private let idB = DownloadSamples.idB

    /// A store whose timer is far off unless a test asks for a short one, so only the calls a test makes write.
    private func makeStore(_ folder: DownloadTestFolder, delay: TimeInterval = 3_600) -> MusicDownloadStore {
        MusicDownloadStore(root: folder.root, now: { DownloadSamples.fixedDate }, indexFlushDelay: delay)
    }

    private func commit(
        _ id: String, standalone: Bool = true, into store: MusicDownloadStore
    ) async throws {
        let part = try await store.beginPart(videoId: id)
        try DownloadSamples.payload(40).write(to: part)
        _ = try await store.commit(DownloadSamples.track(id), expectedBytes: 40, durationSeconds: 200, standalone: standalone)
    }

    private func diskIndex(_ folder: DownloadTestFolder) -> MusicDownloadStore.Index? {
        folder.read(folder.indexURL).flatMap(MusicDownloadStore.Index.decode)
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await condition()
    }

    // MARK: - Adding

    @Test("two hundred songs committed in a row write the index once, when it is flushed")
    func manyCommitsWriteOnce() async throws {
        let folder = DownloadTestFolder()
        defer { folder.remove() }
        let store = makeStore(folder)
        _ = await store.load()

        for number in 1...200 { try await commit(DownloadSamples.id(number), into: store) }

        #expect(await store.indexWriteCount == 0)
        #expect(await store.entries.count == 200)
        await store.flushIndex()
        #expect(await store.indexWriteCount == 1)
        let second = makeStore(folder)
        #expect(await second.load().count == 200)
    }

    @Test("the index is written within the delay without anyone asking")
    func timerWrites() async throws {
        let folder = DownloadTestFolder()
        defer { folder.remove() }
        let store = makeStore(folder, delay: 0.05)
        _ = await store.load()

        try await commit(idA, into: store)

        let written = await waitUntil { await store.indexWriteCount == 1 }
        #expect(written)
        #expect(diskIndex(folder)?.entries.keys.sorted() == [idA])
    }

    @Test("a flush with nothing waiting writes nothing, and creates nothing")
    func flushWithNothingPending() async {
        let folder = DownloadTestFolder()
        defer { folder.remove() }
        let store = makeStore(folder)
        _ = await store.load()

        await store.flushIndex()

        #expect(await store.indexWriteCount == 0)
        #expect(!folder.exists(folder.root))
    }

    @Test("a flush after a flush writes nothing more")
    func secondFlushIsFree() async throws {
        let folder = DownloadTestFolder()
        defer { folder.remove() }
        let store = makeStore(folder)
        _ = await store.load()
        try await commit(idA, into: store)

        await store.flushIndex()
        await store.flushIndex()

        #expect(await store.indexWriteCount == 1)
    }

    @Test("a timer that finds the folder gone writes nothing and does not bring it back")
    func timerLeavesAGoneFolderAlone() async throws {
        let folder = DownloadTestFolder()
        defer { folder.remove() }
        let store = makeStore(folder, delay: 0.05)
        _ = await store.load()
        try await commit(idA, into: store)
        folder.remove()

        try await Task.sleep(for: .milliseconds(400))

        #expect(!folder.exists(folder.root))
        #expect(await store.indexWriteCount == 0)
    }

    @Test("a cover saved for a song is written with the next flush")
    func coverWriteIsDeferred() async throws {
        let folder = DownloadTestFolder()
        defer { folder.remove() }
        let store = makeStore(folder)
        _ = await store.load()
        try await commit(idA, into: store)
        await store.flushIndex()
        let name = MusicDownloadCovers.name(for: URL(string: "https://example.test/a.jpg")!)

        #expect(await store.saveCover(Data("a".utf8), named: name, forVideoId: idA))

        #expect(await store.indexWriteCount == 1)
        #expect(diskIndex(folder)?.entries[idA]?.coverFile == nil)
        await store.flushIndex()
        #expect(await store.indexWriteCount == 2)
        #expect(diskIndex(folder)?.entries[idA]?.coverFile == name)
    }

    @Test("a cover that replaces another is written before the old file is deleted")
    func coverReplacementWritesFirst() async throws {
        let folder = DownloadTestFolder()
        defer { folder.remove() }
        let store = makeStore(folder)
        _ = await store.load()
        try await commit(idA, into: store)
        let old = MusicDownloadCovers.name(for: URL(string: "https://example.test/old.jpg")!)
        let new = MusicDownloadCovers.name(for: URL(string: "https://example.test/new.jpg")!)
        #expect(await store.saveCover(Data("old".utf8), named: old, forVideoId: idA))
        await store.flushIndex()
        let before = await store.indexWriteCount

        #expect(await store.saveCover(Data("new".utf8), named: new, forVideoId: idA))

        #expect(await store.indexWriteCount == before + 1)
        #expect(diskIndex(folder)?.entries[idA]?.coverFile == new)
        #expect(!(store.coverURL(named: old).map { folder.exists($0) } ?? true))
    }

    // MARK: - What still writes at once

    @Test("a removal writes at once, taking the songs added since along, before the file goes")
    func removalWritesAtOnce() async throws {
        let folder = DownloadTestFolder()
        defer { folder.remove() }
        let store = makeStore(folder)
        _ = await store.load()
        try await commit(idA, into: store)
        try await commit(idB, into: store)

        #expect(await store.remove(videoId: idA) == .deleted)

        #expect(await store.indexWriteCount == 1)
        #expect(diskIndex(folder)?.entries.keys.sorted() == [idB])
        #expect(folder.audioFiles == ["\(idB).m4a"])
    }

    @Test("saving a collection writes at once and takes the songs added since along")
    func collectionSaveWritesAtOnce() async throws {
        let folder = DownloadTestFolder()
        defer { folder.remove() }
        let store = makeStore(folder)
        _ = await store.load()
        try await commit(idA, standalone: false, into: store)

        try await store.saveCollection("VLone", MusicDownloadStore.Collection(title: "One", videoIds: [idA]))

        #expect(await store.indexWriteCount == 1)
        let index = diskIndex(folder)
        #expect(index?.entries.keys.sorted() == [idA])
        #expect(index?.collections["VLone"]?.videoIds == [idA])
    }

    @Test("removing a collection writes at once, before its songs are deleted")
    func collectionRemovalWritesAtOnce() async throws {
        let folder = DownloadTestFolder()
        defer { folder.remove() }
        let store = makeStore(folder)
        _ = await store.load()
        try await commit(idA, standalone: false, into: store)
        try await store.saveCollection("VLone", MusicDownloadStore.Collection(title: "One", videoIds: [idA]))
        try await commit(idB, into: store)
        let before = await store.indexWriteCount

        let removal = await store.removeCollection("VLone")

        #expect(removal.dropped == [idA])
        #expect(await store.indexWriteCount == before + 1)
        #expect(diskIndex(folder)?.entries.keys.sorted() == [idB])
        #expect(diskIndex(folder)?.collections.isEmpty == true)
    }

    // MARK: - Failures and crashes

    @Test("a write that failed is tried again by the next, and the change stays in memory meanwhile")
    func failedFlushIsRetried() async throws {
        let folder = DownloadTestFolder()
        defer { folder.remove() }
        let store = makeStore(folder)
        _ = await store.load()
        try await commit(idA, standalone: false, into: store)
        try await store.saveCollection("VLone", MusicDownloadStore.Collection(title: "One", videoIds: [idA]))
        let before = await store.indexWriteCount

        await store.setStandalone(videoId: idA)
        // The folder cannot take a new index: the atomic write needs to create a file beside it.
        try folder.lock(folder.root)
        await store.flushIndex()
        try folder.unlock(folder.root, isDirectory: true)

        #expect(await store.indexWriteCount == before)
        #expect(await store.entries[idA]?.standalone == true)
        #expect(diskIndex(folder)?.entries[idA]?.standalone == false)

        // The next write, of anything, carries the flag down.
        await store.setSyncResult("VLone", .complete, syncedAt: DownloadSamples.fixedDate)

        #expect(diskIndex(folder)?.entries[idA]?.standalone == true)
        #expect(await store.indexWriteCount == before + 1)
    }

    @Test("a failed flush is tried again by the next flush")
    func failedFlushIsTriedAgain() async throws {
        let folder = DownloadTestFolder()
        defer { folder.remove() }
        let store = makeStore(folder)
        _ = await store.load()
        try await commit(idA, into: store)
        await store.flushIndex()
        try await commit(idB, into: store)
        try folder.lock(folder.root)
        await store.flushIndex()
        try folder.unlock(folder.root, isDirectory: true)
        #expect(diskIndex(folder)?.entries.keys.sorted() == [idA])

        await store.flushIndex()

        #expect(diskIndex(folder)?.entries.keys.sorted() == [idA, idB])
    }

    @Test("a quit before the flush loses only the songs not yet written: loading sweeps their audio")
    func quitBeforeFlush() async throws {
        let folder = DownloadTestFolder()
        defer { folder.remove() }
        let first = makeStore(folder)
        _ = await first.load()
        try await commit(idA, into: first)
        await first.flushIndex()
        try await commit(idB, into: first)

        let second = makeStore(folder)
        let loaded = await second.load()

        #expect(loaded.keys.sorted() == [idA])
        #expect(folder.audioFiles == ["\(idA).m4a"])
    }
}
