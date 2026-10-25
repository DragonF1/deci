// DeciTests/Music/MusicDownloadTreeWipeTests.swift
// The walk that empties the Downloads folder, done with calls relative to open folder handles so a link swapped in while it
// runs is never followed: files and folders go and are counted, a link is unlinked and its target left whole, names to keep
// stay, nesting deeper than the cap is counted as failed and left, anything on another device is skipped, and a link at
// Application Support, Deci or Downloads (before or after the open) is refused. Every test works in a folder of its own
// under /Volumes/Storage/_test.

import Foundation
import Testing
@testable import Deci

@Suite("MusicDownloadTreeWipe")
struct MusicDownloadTreeWipeTests {
    private func isLink(_ url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    /// Opens the folder and hands its handle to `body`, closing it afterwards.
    private func withFolder<T>(_ root: URL, _ body: (Int32) -> T) throws -> T {
        guard case .folder(let handle) = MusicDownloadTreeWipe.openFolder(root) else {
            throw TreeWipeTestError.notOpened
        }
        defer { close(handle) }
        return body(handle)
    }

    private enum TreeWipeTestError: Error { case notOpened }

    private func nested(_ levels: Int, under base: URL) -> [URL] {
        var urls: [URL] = []
        var current = base
        for level in 1...levels {
            current = current.appendingPathComponent("d\(level)", isDirectory: true)
            urls.append(current)
        }
        return urls
    }

    // MARK: - Opening

    @Test("a real folder opens, a missing one reads as missing")
    func opensOrIsMissing() throws {
        let folder = DownloadTestFolder(shaped: true)
        defer { folder.remove() }
        #expect(MusicDownloadTreeWipe.openFolder(folder.root) == .missing)

        try FileManager.default.createDirectory(at: folder.root, withIntermediateDirectories: true)
        guard case .folder(let handle) = MusicDownloadTreeWipe.openFolder(folder.root) else {
            Issue.record("a real folder was not opened")
            return
        }
        close(handle)
    }

    @Test("a link as the Downloads folder itself is refused")
    func refusesALinkedDownloads() throws {
        let folder = DownloadTestFolder(shaped: true)
        defer { folder.remove() }
        let elsewhere = folder.container.appendingPathComponent("elsewhere", isDirectory: true)
        try folder.write(Data("x".utf8), to: elsewhere.appendingPathComponent("keep.txt"))
        try FileManager.default.createDirectory(at: folder.root.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: folder.root, withDestinationURL: elsewhere)

        #expect(MusicDownloadTreeWipe.openFolder(folder.root) == .refused)
    }

    @Test("a link at Deci or at Application Support is refused even when the folder it points at has the same shape")
    func refusesALinkedAncestor() throws {
        for linked in ["Deci", "Application Support"] {
            let folder = DownloadTestFolder(shaped: true)
            defer { folder.remove() }
            // A second tree with the very same shape, which the link leads into.
            let other = folder.container.appendingPathComponent("other", isDirectory: true)
            try folder.write(Data("x".utf8), to: other.appendingPathComponent("Application Support/Deci/Downloads/audio/a.m4a"))
            let link = linked == "Deci"
                ? folder.container.appendingPathComponent("Application Support/Deci")
                : folder.container.appendingPathComponent("Application Support")
            let target = linked == "Deci"
                ? other.appendingPathComponent("Application Support/Deci")
                : other.appendingPathComponent("Application Support")
            try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

            #expect(MusicDownloadTreeWipe.openFolder(folder.root) == .refused, "\(linked)")
        }
    }

    // MARK: - Deleting

    @Test("files, nested folders and links go, each counted once, and the link targets stay whole")
    func deletesAndCounts() throws {
        let folder = DownloadTestFolder(shaped: true)
        defer { folder.remove() }
        let outside = folder.container.appendingPathComponent("outside", isDirectory: true)
        try folder.write(Data("precious".utf8), to: outside.appendingPathComponent("precious.txt"))
        try folder.write(Data("1".utf8), to: folder.root.appendingPathComponent("one.txt"))
        try folder.write(Data("2".utf8), to: folder.root.appendingPathComponent("audio/two.m4a"))
        try folder.write(Data("3".utf8), to: folder.root.appendingPathComponent("a/b/three.bin"))
        try FileManager.default.createSymbolicLink(
            at: folder.root.appendingPathComponent("a/link"), withDestinationURL: outside
        )

        let tally = try withFolder(folder.root) { MusicDownloadTreeWipe.deleteContents(of: $0) }

        // one.txt, audio/two.m4a, audio, a/b/three.bin, a/b, a/link, a.
        #expect(tally == MusicDownloadTreeWipe.Tally(removed: 7, failed: 0))
        #expect(folder.rootFiles.isEmpty)
        #expect(folder.read(outside.appendingPathComponent("precious.txt")) == Data("precious".utf8))
    }

    @Test("names to skip stay at the top, and names to keep stay inside a folder, which then stays too")
    func skipsAndKeeps() throws {
        let folder = DownloadTestFolder(shaped: true)
        defer { folder.remove() }
        try folder.write(Data("index".utf8), to: folder.indexURL)
        try folder.write(Data("keep".utf8), to: folder.audioURL(DownloadSamples.idA))
        try folder.write(Data("gone".utf8), to: folder.audioURL(DownloadSamples.idB))
        try folder.write(Data("gone".utf8), to: folder.root.appendingPathComponent("covers/c.img"))

        let tally = try withFolder(folder.root) {
            MusicDownloadTreeWipe.deleteContents(
                of: $0, skipping: [MusicDownloadStore.indexName], keepingInside: ["audio": ["\(DownloadSamples.idA).m4a"]]
            )
        }

        #expect(tally.failed == 0)
        #expect(folder.rootFiles == ["audio", "downloads.json"])
        #expect(folder.audioFiles == ["\(DownloadSamples.idA).m4a"])
    }

    // MARK: - Depth

    @Test("a tree exactly as deep as the cap is deleted whole")
    func deletesToTheCap() throws {
        let folder = DownloadTestFolder(shaped: true)
        defer { folder.remove() }
        let folders = nested(MusicDownloadTreeWipe.maxDepth, under: folder.root)
        try folder.write(Data("deep".utf8), to: folders[folders.count - 1].appendingPathComponent("file.bin"))

        let tally = try withFolder(folder.root) { MusicDownloadTreeWipe.deleteContents(of: $0) }

        #expect(tally.failed == 0)
        #expect(tally.removed == MusicDownloadTreeWipe.maxDepth + 1)
        #expect(folder.rootFiles.isEmpty)
    }

    @Test("nesting past the cap is counted as failed and left, and everything shallower around it still goes")
    func stopsPastTheCap() throws {
        let folder = DownloadTestFolder(shaped: true)
        defer { folder.remove() }
        let folders = nested(MusicDownloadTreeWipe.maxDepth + 4, under: folder.root)
        try folder.write(Data("deep".utf8), to: folders[folders.count - 1].appendingPathComponent("file.bin"))
        try folder.write(Data("shallow".utf8), to: folder.root.appendingPathComponent("shallow.txt"))

        let tally = try withFolder(folder.root) { MusicDownloadTreeWipe.deleteContents(of: $0) }

        #expect(tally.failed == 1)
        #expect(!folder.exists(folder.root.appendingPathComponent("shallow.txt")))
        // The first folder past the cap was not entered, so it and every folder above it are still there.
        #expect(folder.exists(folders[MusicDownloadTreeWipe.maxDepth]))
        #expect(folder.exists(folders[0]))
        #expect(folder.exists(folders[folders.count - 1].appendingPathComponent("file.bin")))
    }

    // MARK: - Another device

    @Test("an item on another device than the folder's own is skipped and counted as failed, never deleted through")
    func skipsAnotherDevice() throws {
        let folder = DownloadTestFolder(shaped: true)
        defer { folder.remove() }
        try folder.write(Data("1".utf8), to: folder.root.appendingPathComponent("one.txt"))
        try folder.write(Data("2".utf8), to: folder.audioURL(DownloadSamples.idA))
        var info = stat()
        #expect(stat(folder.root.path, &info) == 0)
        // Standing in for a mount point: every child reads as being on a different device from the one expected.
        let wrongDevice = info.st_dev &+ 1

        let tally = try withFolder(folder.root) { MusicDownloadTreeWipe.deleteContents(of: $0, expectedDevice: wrongDevice) }

        #expect(tally == MusicDownloadTreeWipe.Tally(removed: 0, failed: 2))
        #expect(folder.rootFiles == ["audio", "one.txt"])
        #expect(folder.audioFiles == ["\(DownloadSamples.idA).m4a"])
    }

    // MARK: - Links met while walking

    @Test("a link that stands where a folder was is unlinked, not entered")
    func neverEntersALinkedFolder() throws {
        let folder = DownloadTestFolder(shaped: true)
        defer { folder.remove() }
        let outside = folder.container.appendingPathComponent("outside", isDirectory: true)
        try folder.write(Data("precious".utf8), to: outside.appendingPathComponent("audio/precious.m4a"))
        try FileManager.default.createDirectory(at: folder.root, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: folder.audioDirectory, withDestinationURL: outside.appendingPathComponent("audio"))

        let tally = try withFolder(folder.root) { MusicDownloadTreeWipe.deleteContents(of: $0) }

        #expect(tally == MusicDownloadTreeWipe.Tally(removed: 1, failed: 0))
        #expect(!isLink(folder.audioDirectory))
        #expect(folder.read(outside.appendingPathComponent("audio/precious.m4a")) == Data("precious".utf8))
    }
}
