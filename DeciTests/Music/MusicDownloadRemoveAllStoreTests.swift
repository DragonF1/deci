// DeciTests/Music/MusicDownloadRemoveAllStoreTests.swift
// "Remove all downloads" in the store: everything inside the Downloads folder goes (audio, covers, .part files, the index,
// the markers of an earlier launch's trouble, files nobody owns) and nothing outside it; a link inside is unlinked, never
// followed; a folder that is not Application Support/Deci/Downloads is refused; the song playing keeps its file until the
// deferred rule deletes it; the index works again afterwards and the orphan sweep is switched back on; and a failure
// partway leaves an index that matches the disk. Every test works in a folder of its own under /Volumes/Storage/_test.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("MusicDownloadRemoveAllStore")
struct MusicDownloadRemoveAllStoreTests {
    private let idA = DownloadSamples.idA
    private let idB = DownloadSamples.idB
    private let idC = DownloadSamples.idC
    private let orphan = "ZZZZZZZZZZZ"
    private let coverName = "0123abcd.img"

    private func makeStore(_ folder: DownloadTestFolder, flushDelay: TimeInterval = 2) -> MusicDownloadStore {
        MusicDownloadStore(root: folder.root, now: { DownloadSamples.fixedDate }, indexFlushDelay: flushDelay)
    }

    @discardableResult
    private func commit(
        _ id: String, standalone: Bool = true, into store: MusicDownloadStore, bytes count: Int = 40, flush: Bool = true
    ) async throws -> MusicDownloadStore.Entry {
        let part = try await store.beginPart(videoId: id)
        try DownloadSamples.payload(count).write(to: part)
        let entry = try await store.commit(
            DownloadSamples.track(id), expectedBytes: Int64(count), durationSeconds: 200, standalone: standalone
        )
        if flush { await store.flushIndex() }
        return entry
    }

    private func readIndex(_ folder: DownloadTestFolder) throws -> MusicDownloadStore.Index {
        try #require(folder.read(folder.indexURL).flatMap(MusicDownloadStore.Index.decode))
    }

    /// A store with two songs, a playlist that lists the second, a cover for the first, a half-written song, audio no
    /// entry owns, and a stray file and a nested folder, all inside the folder.
    private func fill(_ folder: DownloadTestFolder, _ store: MusicDownloadStore) async throws {
        _ = await store.load()
        try await commit(idA, into: store)
        try await commit(idB, standalone: false, into: store)
        try await store.saveCollection("VLPLmix", MusicDownloadStore.Collection(title: "Mix", videoIds: [idB]))
        #expect(await store.saveCover(Data("image".utf8), named: coverName, forVideoId: idA))
        _ = try await store.beginPart(videoId: idC)
        try folder.write(Data("orphan".utf8), to: folder.audioURL(orphan))
        try folder.write(Data("stray".utf8), to: folder.root.appendingPathComponent("stray.txt"))
        try folder.write(Data("deep".utf8), to: folder.root.appendingPathComponent("extra/deeper/file.bin"))
        await store.flushIndex()
    }

    private func isLink(_ url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    // MARK: - What goes

    @Test("everything inside the folder is deleted, and a fresh empty index is all that is left")
    func wipesEverythingInsideTheRoot() async throws {
        let folder = DownloadTestFolder(shaped: true)
        defer { folder.remove() }
        let store = makeStore(folder)
        try await fill(folder, store)

        let wipe = await store.removeAll()

        #expect(!wipe.refused)
        #expect(wipe.failed == 0)
        #expect(wipe.removed > 0)
        #expect(wipe.entries.isEmpty)
        #expect(folder.rootFiles == ["downloads.json"])
        let index = try readIndex(folder)
        #expect(index.entries.isEmpty)
        #expect(index.collections.isEmpty)
        #expect(await store.load().isEmpty)
        #expect(await store.collectionList().isEmpty)
        #expect(await store.isDownloaded(idA) == false)
        #expect(await store.isDownloaded(idB) == false)
    }

    @Test("each file, link and folder deleted is counted once")
    func countsWhatItDeletes() async throws {
        let folder = DownloadTestFolder(shaped: true)
        defer { folder.remove() }
        let store = makeStore(folder)
        _ = await store.load()
        try folder.write(Data("one".utf8), to: folder.audioURL(idA))
        try folder.write(Data("two".utf8), to: folder.audioURL(idB))
        try folder.write(Data("cover".utf8), to: folder.root.appendingPathComponent("covers/\(coverName)"))

        let wipe = await store.removeAll()

        // audio/ with two files, covers/ with one: five items. The index is replaced, not deleted.
        #expect(wipe.removed == 5)
        #expect(wipe.failed == 0)
    }

    @Test("a folder that does not exist yet is an empty wipe that creates nothing")
    func missingRootIsAnEmptyWipe() async {
        let folder = DownloadTestFolder(shaped: true)
        defer { folder.remove() }
        let store = makeStore(folder)

        let wipe = await store.removeAll()

        #expect(!wipe.refused)
        #expect(wipe.removed == 0)
        #expect(wipe.failed == 0)
        #expect(!folder.exists(folder.root))
    }

    // MARK: - What stays

    @Test("files outside the Downloads folder are never touched, even right beside it")
    func leavesFilesOutsideTheRootAlone() async throws {
        let folder = DownloadTestFolder(shaped: true)
        defer { folder.remove() }
        let store = makeStore(folder)
        try await fill(folder, store)
        let outside = [
            folder.container.appendingPathComponent("outside.txt"),
            folder.container.appendingPathComponent("Application Support/other.txt"),
            folder.container.appendingPathComponent("Application Support/Deci/settings.json"),
            folder.container.appendingPathComponent("Application Support/Deci/DownloadsBackup/audio/keep.m4a")
        ]
        for url in outside { try folder.write(Data(url.lastPathComponent.utf8), to: url) }

        await store.removeAll()

        for url in outside {
            #expect(folder.read(url) == Data(url.lastPathComponent.utf8), "\(url.lastPathComponent) was touched")
        }
    }

    @Test("a link inside the folder is unlinked and its target, a file or a folder outside, is left whole")
    func unlinksSymlinksWithoutFollowingThem() async throws {
        let folder = DownloadTestFolder(shaped: true)
        defer { folder.remove() }
        let store = makeStore(folder)
        try await fill(folder, store)
        let outsideFolder = folder.container.appendingPathComponent("elsewhere", isDirectory: true)
        let precious = outsideFolder.appendingPathComponent("precious.txt")
        let outsideFile = folder.container.appendingPathComponent("outside.txt")
        try folder.write(Data("precious".utf8), to: precious)
        try folder.write(Data("outside".utf8), to: outsideFile)
        let folderLink = folder.root.appendingPathComponent("link-to-folder")
        let fileLink = folder.audioDirectory.appendingPathComponent("link-to-file.m4a")
        let nestedLink = folder.root.appendingPathComponent("extra/deeper/nested-link")
        try FileManager.default.createSymbolicLink(at: folderLink, withDestinationURL: outsideFolder)
        try FileManager.default.createSymbolicLink(at: fileLink, withDestinationURL: outsideFile)
        try FileManager.default.createSymbolicLink(at: nestedLink, withDestinationURL: outsideFolder)

        let wipe = await store.removeAll()

        #expect(wipe.failed == 0)
        #expect(!isLink(folderLink) && !folder.exists(folderLink))
        #expect(!isLink(fileLink) && !folder.exists(fileLink))
        #expect(!isLink(nestedLink) && !folder.exists(nestedLink))
        #expect(folder.read(precious) == Data("precious".utf8))
        #expect(folder.read(outsideFile) == Data("outside".utf8))
        #expect(folder.rootFiles == ["downloads.json"])
    }

    // MARK: - Which folder

    @Test("only a folder ending in Application Support/Deci/Downloads can be emptied")
    func deletableRootShape() throws {
        let folder = DownloadTestFolder()
        defer { folder.remove() }
        let base = folder.container
        let good = base.appendingPathComponent("Library/Application Support/Deci/Downloads", isDirectory: true)

        #expect(MusicDownloadStore.isDeletableRoot(good))
        // The real folder has the shape (only its path is looked at here, never the disk).
        #expect(MusicDownloadStore.hasDownloadsShape(MusicDownloadStore.liveRoot()))
        // Beside the real name, above it, below it, or somewhere else altogether.
        for path in [
            "Library/Application Support/Deci/Downloads2",
            "Library/Application Support/Deci/downloads",
            "Library/Application Support/Deci",
            "Library/Application Support/Deci/Downloads/audio",
            "Library/Application Support/Other/Downloads",
            "Library/Caches/Deci/Downloads",
            "Downloads",
            "Application Support/Deci/Downloads/.."
        ] {
            #expect(!MusicDownloadStore.isDeletableRoot(base.appendingPathComponent(path, isDirectory: true)), "\(path)")
        }
        #expect(!MusicDownloadStore.isDeletableRoot(URL(fileURLWithPath: "/")))
        #expect(!MusicDownloadStore.isDeletableRoot(URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)))
        #expect(!MusicDownloadStore.isDeletableRoot(URL(fileURLWithPath: "/Application Support/Deci/Downloads")))
    }

    @Test("a folder with the wrong name is refused and everything in it stays")
    func refusesAWronglyShapedRoot() async throws {
        let folder = DownloadTestFolder()
        defer { folder.remove() }
        let store = makeStore(folder)
        try await fill(folder, store)
        let before = folder.rootFiles

        let wipe = await store.removeAll()

        #expect(wipe.refused)
        #expect(wipe.removed == 0)
        #expect(folder.rootFiles == before)
        #expect(folder.audioFiles.contains("\(idA).m4a"))
        #expect(await store.isDownloaded(idA))
        #expect(wipe.entries.keys.sorted() == [idA, idB].sorted())
        #expect(try readIndex(folder).entries.count == 2)
    }

    @Test("a Downloads folder that is itself a link is refused, and the folder it points at is left whole")
    func refusesALinkedRoot() async throws {
        let folder = DownloadTestFolder(shaped: true)
        defer { folder.remove() }
        let elsewhere = folder.container.appendingPathComponent("elsewhere", isDirectory: true)
        let precious = elsewhere.appendingPathComponent("audio/precious.m4a")
        try folder.write(Data("precious".utf8), to: precious)
        try FileManager.default.createDirectory(
            at: folder.root.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: folder.root, withDestinationURL: elsewhere)
        let store = makeStore(folder)

        let wipe = await store.removeAll()

        #expect(wipe.refused)
        #expect(folder.read(precious) == Data("precious".utf8))
        #expect(isLink(folder.root))
        #expect(!folder.exists(elsewhere.appendingPathComponent("downloads.json")))
    }

    @Test("a link at Deci is refused even when it leads to a folder with the same shape, and that folder is left whole")
    func refusesALinkedAncestor() async throws {
        let folder = DownloadTestFolder(shaped: true)
        defer { folder.remove() }
        let other = folder.container.appendingPathComponent("other", isDirectory: true)
        let precious = other.appendingPathComponent("Application Support/Deci/Downloads/audio/precious.m4a")
        try folder.write(Data("precious".utf8), to: precious)
        let link = folder.container.appendingPathComponent("Application Support/Deci")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: other.appendingPathComponent("Application Support/Deci")
        )
        let store = makeStore(folder)

        #expect(!MusicDownloadStore.isDeletableRoot(folder.root))
        #expect(!store.canRemoveAll())
        let wipe = await store.removeAll()

        #expect(wipe.refused)
        #expect(folder.read(precious) == Data("precious".utf8))
        #expect(!folder.exists(other.appendingPathComponent("Application Support/Deci/Downloads/downloads.json")))
    }

    @Test("a folder nested deeper than the cap is counted as failed and stays, and the rest of the wipe still happens")
    func tooDeepIsAFailureNotAHang() async throws {
        let folder = DownloadTestFolder(shaped: true)
        defer { folder.remove() }
        let store = makeStore(folder)
        try await fill(folder, store)
        var deep = folder.root.appendingPathComponent("extra", isDirectory: true)
        for level in 1...(MusicDownloadTreeWipe.maxDepth + 2) { deep.appendPathComponent("l\(level)", isDirectory: true) }
        try folder.write(Data("deep".utf8), to: deep.appendingPathComponent("file.bin"))

        let wipe = await store.removeAll()

        #expect(wipe.failed >= 1)
        #expect(folder.audioFiles.isEmpty)
        #expect(folder.exists(deep.appendingPathComponent("file.bin")))
        #expect(wipe.entries.isEmpty)
    }

    // MARK: - The song that is playing

    @Test("a file kept for the player stays, the rest goes, and the deferred rule deletes it once playback has left")
    func keepsThePlayingFileForTheDeferredRule() async throws {
        let folder = DownloadTestFolder(shaped: true)
        defer { folder.remove() }
        let store = makeStore(folder)
        _ = await store.load()
        try await commit(idA, into: store)
        try await commit(idB, into: store)

        let wipe = await store.removeAll(keepingFiles: [idA])

        #expect(wipe.failed == 0)
        #expect(folder.audioFiles == ["\(idA).m4a"])
        #expect(try readIndex(folder).entries.isEmpty)
        #expect(await store.isDownloaded(idA) == false)

        await store.removeFileIfUnlisted(videoId: idA)

        #expect(folder.audioFiles.isEmpty)
    }

    @Test("deleting the last kept file leaves no empty audio folder behind, so the folder reads as holding nothing")
    func deferredDeleteRemovesTheEmptyFolders() async throws {
        let folder = DownloadTestFolder(shaped: true)
        defer { folder.remove() }
        let store = makeStore(folder)
        _ = await store.load()
        try await commit(idA, into: store)
        await store.removeAll(keepingFiles: [idA])
        #expect(folder.rootFiles == ["audio", "downloads.json"])

        await store.removeFileIfUnlisted(videoId: idA)

        #expect(folder.rootFiles == ["downloads.json"])
        #expect(!MusicDownloadDiskUsage.measure(root: folder.root).hasFiles)
    }

    @Test("the deferred delete leaves the audio folder alone while another song is in it, and while the song is listed again")
    func deferredDeleteKeepsAFolderInUse() async throws {
        let folder = DownloadTestFolder(shaped: true)
        defer { folder.remove() }
        let store = makeStore(folder)
        _ = await store.load()
        try await commit(idA, into: store)
        try await commit(idB, into: store)
        await store.remove(videoId: idA, keepingFile: true)

        await store.removeFileIfUnlisted(videoId: idA)

        #expect(folder.audioFiles == ["\(idB).m4a"])

        // Listed again: nothing is deleted.
        try await commit(idA, into: store)
        await store.removeFileIfUnlisted(videoId: idA)
        #expect(folder.audioFiles == ["\(idA).m4a", "\(idB).m4a"])
    }

    @Test("removing the last song, with its cover, leaves neither folder behind")
    func removingTheLastSongTidiesUp() async throws {
        let folder = DownloadTestFolder(shaped: true)
        defer { folder.remove() }
        let store = makeStore(folder)
        _ = await store.load()
        try await commit(idA, into: store)
        #expect(await store.saveCover(Data("image".utf8), named: coverName, forVideoId: idA))
        #expect(folder.rootFiles == ["audio", "covers", "downloads.json"])

        await store.remove(videoId: idA)

        #expect(folder.rootFiles == ["downloads.json"])
    }

    @Test("a song being downloaded keeps the audio folder when another song is removed")
    func removalKeepsTheFolderOfAPartInProgress() async throws {
        let folder = DownloadTestFolder(shaped: true)
        defer { folder.remove() }
        let store = makeStore(folder)
        _ = await store.load()
        try await commit(idA, into: store)
        _ = try await store.beginPart(videoId: idB)

        await store.remove(videoId: idA)

        #expect(folder.audioFiles == ["\(idB).m4a.part"])
    }

    // MARK: - After the wipe

    @Test("the index works again: new songs and collections are written and read back by a new store")
    func indexWorksAfterAWipe() async throws {
        let folder = DownloadTestFolder(shaped: true)
        defer { folder.remove() }
        let store = makeStore(folder)
        try await fill(folder, store)
        await store.removeAll()

        try await commit(idC, into: store)
        try await store.saveCollection("VLPLnew", MusicDownloadStore.Collection(title: "New", videoIds: [idC]))
        await store.flushIndex()

        let second = makeStore(folder)
        let loaded = await second.load()
        #expect(loaded.keys.sorted() == [idC])
        #expect(await second.collectionList().keys.sorted() == ["VLPLnew"])
        #expect(folder.audioFiles == ["\(idC).m4a"])
        #expect(!folder.rootFiles.contains("downloads.json.missing"))
    }

    @Test("a store that never loaded can be wiped, and loading afterwards finds nothing")
    func wipesBeforeLoad() async throws {
        let folder = DownloadTestFolder(shaped: true)
        defer { folder.remove() }
        let first = makeStore(folder)
        try await fill(folder, first)

        let fresh = makeStore(folder)
        let wipe = await fresh.removeAll()

        #expect(!wipe.refused)
        #expect(wipe.failed == 0)
        #expect(folder.rootFiles == ["downloads.json"])
        #expect(await fresh.load().isEmpty)
        #expect(await makeStore(folder).load().isEmpty)
    }

    @Test("changes that were waiting for their timer are not written after the wipe")
    func pendingWritesDoNotComeBack() async throws {
        let folder = DownloadTestFolder(shaped: true)
        defer { folder.remove() }
        let store = makeStore(folder, flushDelay: 0.3)
        _ = await store.load()
        try await commit(idA, into: store, flush: false)
        // Nothing has been written yet: the index waits for its timer.
        #expect(folder.read(folder.indexURL) == nil)
        let writes = await store.indexWriteCount

        await store.removeAll()
        try await Task.sleep(for: .milliseconds(800))
        await store.flushIndex()

        #expect(try readIndex(folder).entries.isEmpty)
        #expect(folder.rootFiles == ["downloads.json"])
        // The wipe wrote the empty index once and nothing wrote after it.
        #expect(await store.indexWriteCount == writes + 1)
    }

    @Test("a song downloaded again after the wipe is listed and its file is whole")
    func downloadsAgainAfterTheWipe() async throws {
        let folder = DownloadTestFolder(shaped: true)
        defer { folder.remove() }
        let store = makeStore(folder)
        _ = await store.load()
        try await commit(idA, into: store)
        await store.removeAll()

        let entry = try await commit(idA, into: store, bytes: 55)

        #expect(entry.bytes == 55)
        #expect(await store.isDownloaded(idA))
        #expect(folder.read(folder.audioURL(idA)) == DownloadSamples.payload(55))
    }

    // MARK: - The orphan sweep

    @Test("after an unreadable index was moved aside, the wipe clears the marker so the sweep runs again")
    func sweepRunsAgainAfterAnUnreadableIndex() async throws {
        let folder = DownloadTestFolder(shaped: true)
        defer { folder.remove() }
        try folder.write(Data("not json".utf8), to: folder.indexURL)
        try folder.write(Data("audio".utf8), to: folder.audioURL(idA))
        let store = makeStore(folder)
        _ = await store.load()
        #expect(folder.rootFiles.contains("downloads.json.unreadable"))
        #expect(folder.exists(folder.audioURL(idA)))

        await store.removeAll()

        #expect(folder.rootFiles == ["downloads.json"])
        try folder.write(Data("orphan".utf8), to: folder.audioURL(orphan))
        let next = makeStore(folder)
        #expect(await next.load().isEmpty)
        #expect(!folder.exists(folder.audioURL(orphan)), "audio nobody owns was not swept")
    }

    @Test("after audio was found with no index, the wipe clears the missing marker so the sweep runs again")
    func sweepRunsAgainAfterAMissingIndex() async throws {
        let folder = DownloadTestFolder(shaped: true)
        defer { folder.remove() }
        try folder.write(Data("audio".utf8), to: folder.audioURL(idA))
        let store = makeStore(folder)
        _ = await store.load()
        #expect(folder.rootFiles.contains("downloads.json.missing"))

        await store.removeAll()

        #expect(folder.rootFiles == ["downloads.json"])
        try folder.write(Data("orphan".utf8), to: folder.audioURL(orphan))
        let next = makeStore(folder)
        #expect(await next.load().isEmpty)
        #expect(!folder.exists(folder.audioURL(orphan)), "audio nobody owns was not swept")
    }

    @Test("a store blocked by an index it could not read is unblocked by the wipe")
    func wipeUnblocksAStore() async throws {
        let folder = DownloadTestFolder(shaped: true)
        defer { folder.remove() }
        try folder.write(Data("{}".utf8), to: folder.indexURL)
        try folder.lock(folder.indexURL)
        let store = makeStore(folder)
        _ = await store.load()
        await #expect(throws: MusicDownloadError.self) { try await store.beginPart(videoId: idA) }

        let wipe = await store.removeAll()

        #expect(wipe.failed == 0)
        try await commit(idA, into: store)
        #expect(await store.isDownloaded(idA))
        #expect(folder.rootFiles == ["audio", "downloads.json"])
    }

    // MARK: - Failures

    @Test("when the fresh index cannot be written nothing is deleted and the store is as it was")
    func deletesNothingWhenTheIndexCannotBeWritten() async throws {
        let folder = DownloadTestFolder(shaped: true)
        defer { folder.remove() }
        let store = makeStore(folder)
        try await fill(folder, store)
        try folder.lock(folder.root)
        defer { try? folder.unlock(folder.root, isDirectory: true) }

        let wipe = await store.removeAll()

        try folder.unlock(folder.root, isDirectory: true)
        #expect(wipe.failed > 0)
        #expect(wipe.removed == 0)
        #expect(folder.exists(folder.audioURL(idA)))
        #expect(folder.exists(folder.audioURL(idB)))
        #expect(await store.isDownloaded(idA))
        #expect(wipe.entries.keys.sorted() == [idA, idB].sorted())
        #expect(await store.collectionList().keys.sorted() == ["VLPLmix"])
        #expect(try readIndex(folder).entries.count == 2)
    }

    @Test("a file that cannot be deleted stays listed, the rest goes, and the index matches the disk")
    func partialFailureLeavesAConsistentIndex() async throws {
        let folder = DownloadTestFolder(shaped: true)
        defer { folder.remove() }
        let store = makeStore(folder)
        _ = await store.load()
        try await commit(idA, into: store)
        try folder.write(Data("cover".utf8), to: folder.root.appendingPathComponent("covers/\(coverName)"))
        try folder.write(Data("stray".utf8), to: folder.root.appendingPathComponent("stray.txt"))
        // Nothing can be taken out of a folder that cannot be written to.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.audioDirectory.path)
        defer { try? folder.unlock(folder.audioDirectory, isDirectory: true) }

        let wipe = await store.removeAll()

        try folder.unlock(folder.audioDirectory, isDirectory: true)
        #expect(wipe.failed > 0)
        #expect(!wipe.refused)
        #expect(Set(folder.rootFiles) == ["audio", "downloads.json"])
        #expect(folder.audioFiles == ["\(idA).m4a"])
        // The survivor is still a download: listed in memory and on disk.
        #expect(wipe.entries.keys.sorted() == [idA])
        #expect(await store.isDownloaded(idA))
        let index = try readIndex(folder)
        #expect(index.entries.keys.sorted() == [idA])
        #expect(await makeStore(folder).load().keys.sorted() == [idA])
    }
}
