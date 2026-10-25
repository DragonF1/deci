// DeciTests/Music/MusicDownloadDiskUsageTests.swift
// How much room the Downloads folder takes, measured from the disk: the allocated size of every file under it (audio,
// covers, half-written songs, files nobody owns, hidden files), nothing outside it, links counted as links and never
// followed; whether the folder holds anything besides the index; and the counts read from the index alone. Every test
// works in a folder of its own under /Volumes/Storage/_test.

import Foundation
import Testing
@testable import Deci

@Suite("MusicDownloadDiskUsage")
struct MusicDownloadDiskUsageTests {
    /// A file of `count` bytes that cannot be stored sparsely or compressed to nothing.
    private func data(_ count: Int) -> Data { DownloadSamples.payload(count) }

    /// How far above the bytes written the disk may round them up (a few blocks).
    private let slack: Int64 = 64 * 1024

    private func isMeasuredNear(_ measured: Int64, _ written: Int) -> Bool {
        measured >= Int64(written) && measured <= Int64(written) + slack
    }

    // MARK: - Bytes

    @Test("a folder that does not exist takes no room and holds nothing")
    func missingFolder() {
        let folder = DownloadTestFolder(shaped: true)
        let usage = MusicDownloadDiskUsage.measure(root: folder.root)
        #expect(usage == MusicDownloadDiskUsage.Usage(bytes: 0, hasFiles: false))
    }

    @Test("an empty folder takes no room and holds nothing")
    func emptyFolder() throws {
        let folder = DownloadTestFolder(shaped: true)
        defer { folder.remove() }
        try FileManager.default.createDirectory(at: folder.root, withIntermediateDirectories: true)
        #expect(MusicDownloadDiskUsage.measure(root: folder.root) == MusicDownloadDiskUsage.Usage(bytes: 0, hasFiles: false))
    }

    @Test("the room is the allocated size of the files, at least what they hold and never far above it")
    func sumsAllocatedSizes() throws {
        let folder = DownloadTestFolder(shaped: true)
        defer { folder.remove() }
        try folder.write(data(300_000), to: folder.audioURL("AAAAAAAAAAA"))
        try folder.write(data(500_000), to: folder.audioURL("BBBBBBBBBBB"))

        let usage = MusicDownloadDiskUsage.measure(root: folder.root)

        #expect(isMeasuredNear(usage.bytes, 800_000), "\(usage.bytes)")
        #expect(usage.hasFiles)
    }

    @Test("a file counts by the blocks it takes, not the bytes it holds")
    func countsAllocatedNotLogical() throws {
        let folder = DownloadTestFolder(shaped: true)
        defer { folder.remove() }
        try folder.write(Data("x".utf8), to: folder.audioURL("AAAAAAAAAAA"))

        let usage = MusicDownloadDiskUsage.measure(root: folder.root)

        // One byte written, a whole block taken (the volume's block is at least 512 bytes).
        #expect(usage.bytes >= 512, "\(usage.bytes)")
    }

    @Test("covers, half-written songs, audio nobody owns, hidden files and nested folders all count")
    func countsEverythingUnderTheRoot() throws {
        let folder = DownloadTestFolder(shaped: true)
        defer { folder.remove() }
        try folder.write(data(100_000), to: folder.audioURL("AAAAAAAAAAA"))
        try folder.write(data(100_000), to: folder.partURL("BBBBBBBBBBB"))
        try folder.write(data(100_000), to: folder.root.appendingPathComponent("covers/0123abcd.img"))
        try folder.write(data(100_000), to: folder.root.appendingPathComponent(".hidden-file"))
        try folder.write(data(100_000), to: folder.root.appendingPathComponent("extra/deeper/file.bin"))
        try folder.write(data(100_000), to: folder.root.appendingPathComponent("downloads.json.unreadable"))

        let usage = MusicDownloadDiskUsage.measure(root: folder.root)

        #expect(isMeasuredNear(usage.bytes, 600_000), "\(usage.bytes)")
    }

    @Test("files beside the folder, and above it, are not counted")
    func ignoresWhatIsOutside() throws {
        let folder = DownloadTestFolder(shaped: true)
        defer { folder.remove() }
        try folder.write(data(100_000), to: folder.audioURL("AAAAAAAAAAA"))
        try folder.write(data(900_000), to: folder.container.appendingPathComponent("outside.bin"))
        try folder.write(data(900_000), to: folder.container.appendingPathComponent("Application Support/Deci/settings.json"))
        try folder.write(data(900_000), to: folder.container.appendingPathComponent("Application Support/Deci/DownloadsOld/a.bin"))

        let usage = MusicDownloadDiskUsage.measure(root: folder.root)

        #expect(isMeasuredNear(usage.bytes, 100_000), "\(usage.bytes)")
    }

    @Test("a link is counted as a link: the folder or file it points at is never read")
    func doesNotFollowLinks() throws {
        let folder = DownloadTestFolder(shaped: true)
        defer { folder.remove() }
        let elsewhere = folder.container.appendingPathComponent("elsewhere", isDirectory: true)
        try folder.write(data(2_000_000), to: elsewhere.appendingPathComponent("big.bin"))
        try folder.write(data(2_000_000), to: folder.container.appendingPathComponent("outside.bin"))
        try folder.write(data(10_000), to: folder.audioURL("AAAAAAAAAAA"))
        try FileManager.default.createSymbolicLink(
            at: folder.root.appendingPathComponent("link-to-folder"), withDestinationURL: elsewhere
        )
        try FileManager.default.createSymbolicLink(
            at: folder.audioDirectory.appendingPathComponent("link-to-file.m4a"),
            withDestinationURL: folder.container.appendingPathComponent("outside.bin")
        )
        try FileManager.default.createSymbolicLink(
            at: folder.root.appendingPathComponent("extra-link"), withDestinationURL: folder.root
        )

        let usage = MusicDownloadDiskUsage.measure(root: folder.root)

        // The audio file and a few links, far from the four megabytes the links point at.
        #expect(usage.bytes >= 10_000 && usage.bytes < 200_000, "\(usage.bytes)")
    }

    @Test("a root that is a link measures nothing")
    func linkedRoot() throws {
        let folder = DownloadTestFolder(shaped: true)
        defer { folder.remove() }
        let elsewhere = folder.container.appendingPathComponent("elsewhere", isDirectory: true)
        try folder.write(data(2_000_000), to: elsewhere.appendingPathComponent("big.bin"))
        try FileManager.default.createDirectory(at: folder.root.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: folder.root, withDestinationURL: elsewhere)

        let usage = MusicDownloadDiskUsage.measure(root: folder.root)

        #expect(usage.bytes < 200_000, "\(usage.bytes)")
    }

    @Test("a root that is a plain file measures nothing and holds nothing")
    func rootIsAFile() throws {
        let folder = DownloadTestFolder(shaped: true)
        defer { folder.remove() }
        try folder.write(data(50_000), to: folder.root)
        #expect(MusicDownloadDiskUsage.measure(root: folder.root) == MusicDownloadDiskUsage.Usage(bytes: 0, hasFiles: false))
    }

    @Test("a folder that cannot be read is skipped and the rest still counts")
    func unreadableSubfolder() throws {
        let folder = DownloadTestFolder(shaped: true)
        defer { folder.remove() }
        try folder.write(data(100_000), to: folder.audioURL("AAAAAAAAAAA"))
        try folder.write(data(100_000), to: folder.root.appendingPathComponent("covers/0123abcd.img"))
        try folder.lock(folder.root.appendingPathComponent("covers", isDirectory: true))
        defer { try? folder.unlock(folder.root.appendingPathComponent("covers", isDirectory: true), isDirectory: true) }

        let usage = MusicDownloadDiskUsage.measure(root: folder.root)

        #expect(usage.bytes >= 100_000 && usage.bytes <= 100_000 + slack, "\(usage.bytes)")
        #expect(usage.hasFiles)
    }

    @Test("many files are measured in well under a second")
    func manyFiles() throws {
        let folder = DownloadTestFolder(shaped: true)
        defer { folder.remove() }
        try FileManager.default.createDirectory(at: folder.audioDirectory, withIntermediateDirectories: true)
        for number in 0..<2_000 {
            try Data("x".utf8).write(to: folder.audioURL(DownloadSamples.id(number)))
        }
        let clock = ContinuousClock()
        var usage = MusicDownloadDiskUsage.Usage(bytes: 0, hasFiles: false)

        let elapsed = clock.measure { usage = MusicDownloadDiskUsage.measure(root: folder.root) }

        #expect(usage.bytes >= 2_000)
        #expect(elapsed < .seconds(2), "\(elapsed)")
    }

    // MARK: - Whether anything is there

    @Test("the index alone is not a download: a folder with only downloads.json holds nothing")
    func indexAloneIsEmpty() throws {
        let folder = DownloadTestFolder(shaped: true)
        defer { folder.remove() }
        // A long title makes an index big enough that its room cannot round to nothing.
        let record = MusicDownloadStore.Collection(title: String(repeating: "t", count: 100_000), videoIds: [])
        try folder.write(try MusicDownloadStore.Index(collections: ["VLPLone": record]).encoded(), to: folder.indexURL)

        let usage = MusicDownloadDiskUsage.measure(root: folder.root)

        #expect(!usage.hasFiles)
        // It still takes room, and the room is counted.
        #expect(usage.bytes >= 100_000, "\(usage.bytes)")
    }

    @Test("anything but the index counts as files: audio, a marker of an index that was lost, a stray file")
    func anythingElseIsFiles() throws {
        for name in ["audio/AAAAAAAAAAA.m4a", "downloads.json.missing", "downloads.json.unreadable", "covers/0123abcd.img", "stray.txt"] {
            let folder = DownloadTestFolder(shaped: true)
            defer { folder.remove() }
            try folder.write(try MusicDownloadStore.Index().encoded(), to: folder.indexURL)
            try folder.write(data(10), to: folder.root.appendingPathComponent(name))
            #expect(MusicDownloadDiskUsage.measure(root: folder.root).hasFiles, "\(name)")
        }
    }

    @Test("an empty audio folder is still a folder, so it counts as something left")
    func emptyAudioFolder() throws {
        let folder = DownloadTestFolder(shaped: true)
        defer { folder.remove() }
        try FileManager.default.createDirectory(at: folder.audioDirectory, withIntermediateDirectories: true)
        #expect(MusicDownloadDiskUsage.measure(root: folder.root).hasFiles)
    }

    // MARK: - Cancelling

    @Test("a walk that is cancelled stops and reads as empty, so a caller that drops it never shows a partial size")
    func cancelledWalkIsEmpty() async throws {
        let folder = DownloadTestFolder(shaped: true)
        defer { folder.remove() }
        for number in 0..<40 { try folder.write(data(5_000), to: folder.audioURL(DownloadSamples.id(number))) }
        let root = folder.root

        let usage = await Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return MusicDownloadDiskUsage.measure(root: root)
        }.value

        #expect(usage == MusicDownloadDiskUsage.Usage(bytes: 0, hasFiles: false))
        // The same folder, not cancelled, still reads in full.
        #expect(MusicDownloadDiskUsage.measure(root: root).hasFiles)
    }

    // MARK: - Counts from the index

    private func writeIndex(_ folder: DownloadTestFolder, songs: [String], collections: [String: [String]]) throws {
        var entries: [String: MusicDownloadStore.Entry] = [:]
        for id in songs {
            entries[id] = MusicDownloadStore.Entry(
                track: DownloadSamples.track(id), bytes: 10, downloadedAt: DownloadSamples.fixedDate, durationSeconds: 200
            )
        }
        var records: [String: MusicDownloadStore.Collection] = [:]
        for (browseId, ids) in collections { records[browseId] = MusicDownloadStore.Collection(title: browseId, videoIds: ids) }
        try folder.write(try MusicDownloadStore.Index(entries: entries, collections: records).encoded(), to: folder.indexURL)
    }

    @Test("the counts are the songs and the collections the index lists")
    func countsFromTheIndex() throws {
        let folder = DownloadTestFolder(shaped: true)
        defer { folder.remove() }
        try writeIndex(
            folder,
            songs: [DownloadSamples.idA, DownloadSamples.idB, DownloadSamples.idC],
            collections: ["VLPLone": [DownloadSamples.idA], "VLPLtwo": [DownloadSamples.idB]]
        )

        let counts = MusicDownloadDiskUsage.storedCounts(at: folder.root)

        #expect(counts == MusicDownloadDiskUsage.Counts(songs: 3, collections: 2))
    }

    @Test("no index, an empty index, a broken one and a root that is not there all count as nothing downloaded")
    func countsNothingWithoutAnIndex() throws {
        let zero = MusicDownloadDiskUsage.Counts(songs: 0, collections: 0)
        let missing = DownloadTestFolder(shaped: true)
        #expect(MusicDownloadDiskUsage.storedCounts(at: missing.root) == zero)

        let empty = DownloadTestFolder(shaped: true)
        defer { empty.remove() }
        try writeIndex(empty, songs: [], collections: [:])
        #expect(MusicDownloadDiskUsage.storedCounts(at: empty.root) == zero)

        for text in ["not json", "[]", "{\"version\": 2, \"entries\": 5}", "{}", ""] {
            let broken = DownloadTestFolder(shaped: true)
            defer { broken.remove() }
            try broken.write(Data(text.utf8), to: broken.indexURL)
            #expect(MusicDownloadDiskUsage.storedCounts(at: broken.root) == zero, "\(text)")
        }
    }

    @Test("an index with only one of the two lists counts the other as none")
    func countsAPartialIndex() throws {
        let folder = DownloadTestFolder(shaped: true)
        defer { folder.remove() }
        try folder.write(Data("{\"version\": 2, \"collections\": {\"VLPLone\": {}}}".utf8), to: folder.indexURL)
        #expect(MusicDownloadDiskUsage.storedCounts(at: folder.root) == MusicDownloadDiskUsage.Counts(songs: 0, collections: 1))
    }

    @Test("an entry this version cannot decode is still a song on disk, so it is counted")
    func countsUnreadableEntries() throws {
        let folder = DownloadTestFolder(shaped: true)
        defer { folder.remove() }
        try folder.write(
            Data("{\"version\": 2, \"entries\": {\"AAAAAAAAAAA\": {\"future\": true}, \"BBBBBBBBBBB\": {}}}".utf8),
            to: folder.indexURL
        )
        #expect(MusicDownloadDiskUsage.storedCounts(at: folder.root) == MusicDownloadDiskUsage.Counts(songs: 2, collections: 0))
    }
}
