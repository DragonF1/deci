// DeciTests/Music/MusicSessionStoreTests.swift
// The session file: written atomically at most once a second, read back only inside its hour and for its own channel.
// Everything lives in a folder of its own under /Volumes/Storage/_test, never in the real Application Support.

import Foundation
import Testing
@testable import Deci

/// A fresh folder for one test's session file, removed by `remove()`.
nonisolated struct SessionTestFolder {
    let directory: URL
    var fileURL: URL { directory.appendingPathComponent("music-session.json", isDirectory: false) }

    init() {
        directory = URL(fileURLWithPath: "/Volumes/Storage/_test/deci/session", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    var fileExists: Bool { FileManager.default.fileExists(atPath: fileURL.path) }

    /// What the folder holds, so a leftover temp file shows.
    var contents: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    func writeRaw(_ data: Data) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: fileURL)
    }

    func readSnapshot() -> MusicSessionSnapshot? {
        (try? Data(contentsOf: fileURL)).flatMap(MusicSessionSnapshot.decode)
    }
}

@MainActor
private struct StoreRig {
    let folder = SessionTestFolder()
    let clock = MutableClock()
    let scheduler: ManualWriteScheduler
    let store: MusicSessionStore

    init() {
        let clock = self.clock
        let scheduler = ManualWriteScheduler(clock: clock)
        self.scheduler = scheduler
        self.store = MusicSessionStore(fileURL: folder.fileURL, now: { clock.now }, scheduler: scheduler)
    }

    func snapshot(
        _ ids: [String] = ["a", "b", "c"], position: TimeInterval = 10, channel: String = "chan-a", age: TimeInterval = 0
    ) -> MusicSessionSnapshot {
        var queue = MusicQueue()
        queue.start(with: MusicSamples.track(ids[0], title: "Song \(ids[0])"))
        queue.append(ids.dropFirst().map { MusicSamples.track($0, title: "Song \($0)") }, continuation: nil)
        return MusicSessionSnapshot(
            savedAt: clock.now.addingTimeInterval(-age), channelKey: channel, position: position, queue: queue
        )
    }

    func cleanUp() {
        store.waitForWrites()
        folder.remove()
    }
}

@MainActor
@Suite("MusicSessionStore")
struct MusicSessionStoreTests {

    // MARK: - Expiry

    @Test("A session saved 59 minutes ago comes back")
    func fiftyNineMinutesRestores() throws {
        let rig = StoreRig()
        defer { rig.cleanUp() }
        rig.store.save(rig.snapshot(["a", "b"], position: 77))
        rig.store.flush()
        rig.clock.advance(by: 59 * 60)

        let restored = try #require(rig.store.load())
        #expect(restored.queue.current?.videoId == "a")
        #expect(restored.position == 77)
        #expect(rig.folder.fileExists)
    }

    @Test("A session saved 61 minutes ago is deleted, not restored")
    func sixtyOneMinutesDeletes() {
        let rig = StoreRig()
        defer { rig.cleanUp() }
        rig.store.save(rig.snapshot())
        rig.store.flush()
        rig.clock.advance(by: 61 * 60)

        #expect(rig.store.load() == nil)
        #expect(!rig.folder.fileExists)
    }

    @Test("A session saved in the future is deleted, a few seconds of clock skew is not")
    func futureSaveDeletes() {
        let rig = StoreRig()
        defer { rig.cleanUp() }
        rig.store.save(rig.snapshot(age: -30))
        rig.store.flush()
        #expect(rig.store.load() != nil)

        rig.store.save(rig.snapshot(position: 20, age: -2 * 3600))
        rig.store.flush()
        #expect(rig.store.load() == nil)
        #expect(!rig.folder.fileExists)
    }

    @Test("The hour itself still counts, the next second does not")
    func theBoundary() {
        let rig = StoreRig()
        defer { rig.cleanUp() }
        rig.store.save(rig.snapshot())
        rig.store.flush()
        rig.clock.advance(by: MusicSessionSnapshot.lifetime)
        #expect(rig.store.load() != nil)
        rig.clock.advance(by: 1)
        #expect(rig.store.load() == nil)
        #expect(!rig.folder.fileExists)
    }

    @Test("The hour counts from the last save, not from the first")
    func hourCountsFromTheLastSave() {
        let rig = StoreRig()
        defer { rig.cleanUp() }
        rig.store.save(rig.snapshot(position: 5))
        rig.store.flush()
        rig.clock.advance(by: 50 * 60)
        rig.store.save(rig.snapshot(position: 600))
        rig.store.flush()
        rig.clock.advance(by: 50 * 60)
        #expect(rig.store.load()?.position == 600)
    }

    // MARK: - Whose session

    @Test("Another account's session is deleted, the same account's is kept")
    func otherAccountDeletes() {
        let rig = StoreRig()
        defer { rig.cleanUp() }
        rig.store.save(rig.snapshot(channel: "chan-a"))
        rig.store.flush()

        #expect(rig.store.load(forChannel: "chan-a") != nil)
        #expect(rig.folder.fileExists)
        #expect(rig.store.load(forChannel: "chan-b") == nil)
        #expect(!rig.folder.fileExists)
    }

    @Test("Without a channel to check against, a fresh session is returned for the caller to check")
    func noChannelGiven() {
        let rig = StoreRig()
        defer { rig.cleanUp() }
        rig.store.save(rig.snapshot(channel: "chan-a"))
        rig.store.flush()
        #expect(rig.store.load()?.channelKey == "chan-a")
        #expect(rig.folder.fileExists)
    }

    // MARK: - Unreadable files

    @Test("A damaged file, an empty one and one of another version are deleted")
    func unreadableDeletes() throws {
        let rig = StoreRig()
        defer { rig.cleanUp() }

        try rig.folder.writeRaw(Data("{ not json".utf8))
        #expect(rig.store.load() == nil)
        #expect(!rig.folder.fileExists)

        try rig.folder.writeRaw(Data())
        #expect(rig.store.load() == nil)
        #expect(!rig.folder.fileExists)

        let good = try rig.snapshot().encoded()
        var object = try #require(JSONSerialization.jsonObject(with: good) as? [String: Any])
        object["version"] = MusicSessionSnapshot.version + 1
        try rig.folder.writeRaw(try JSONSerialization.data(withJSONObject: object))
        #expect(rig.store.load() == nil)
        #expect(!rig.folder.fileExists)
    }

    @Test("With no file there is nothing to restore and nothing is created")
    func noFile() {
        let rig = StoreRig()
        defer { rig.cleanUp() }
        #expect(rig.store.load() == nil)
        #expect(rig.store.load(forChannel: "chan-a") == nil)
        #expect(!rig.folder.fileExists)
        #expect(rig.store.writeCount == 0)
    }

    // MARK: - Writing

    @Test("Writes come at most once a second: a burst lands as the first save and then one trailing write of the newest")
    func coalescedWrites() {
        let rig = StoreRig()
        defer { rig.cleanUp() }

        rig.store.save(rig.snapshot(position: 1))
        #expect(rig.store.writeCount == 1)
        rig.store.save(rig.snapshot(position: 2))
        rig.clock.advance(by: 0.2)
        rig.store.save(rig.snapshot(position: 3))
        rig.clock.advance(by: 0.2)
        rig.store.save(rig.snapshot(position: 4))
        rig.store.waitForWrites()

        #expect(rig.store.writeCount == 1)
        #expect(rig.scheduler.pendingCount == 1)
        #expect(rig.folder.readSnapshot()?.position == 1)

        rig.scheduler.advance(by: 1)
        rig.store.waitForWrites()
        #expect(rig.store.writeCount == 2)
        #expect(rig.scheduler.pendingCount == 0)
        #expect(rig.folder.readSnapshot()?.position == 4)
    }

    @Test("The trailing write comes a second after the last write, not a second after the save that asked for it")
    func trailingWriteTiming() throws {
        let rig = StoreRig()
        defer { rig.cleanUp() }
        rig.store.save(rig.snapshot(position: 1))
        rig.clock.advance(by: 0.6)
        rig.store.save(rig.snapshot(position: 2))
        let delay = try #require(rig.scheduler.nextDelay)
        #expect(abs(delay - 0.4) < 0.001)
    }

    @Test("A save after a quiet second is written at once")
    func quietSecondWritesAtOnce() {
        let rig = StoreRig()
        defer { rig.cleanUp() }
        rig.store.save(rig.snapshot(position: 1))
        rig.clock.advance(by: 1.5)
        rig.store.save(rig.snapshot(position: 2))
        rig.store.waitForWrites()
        #expect(rig.store.writeCount == 2)
        #expect(rig.scheduler.pendingCount == 0)
        #expect(rig.folder.readSnapshot()?.position == 2)
    }

    @Test("Flush writes what is waiting, now, and the trailing write is not run twice")
    func flushWritesPending() {
        let rig = StoreRig()
        defer { rig.cleanUp() }
        rig.store.save(rig.snapshot(position: 1))
        rig.store.save(rig.snapshot(position: 9))
        #expect(rig.folder.readSnapshot()?.position == 1 || rig.folder.readSnapshot() == nil)

        rig.store.flush()
        #expect(rig.folder.readSnapshot()?.position == 9)
        #expect(rig.store.writeCount == 2)
        #expect(rig.scheduler.pendingCount == 0)

        rig.scheduler.advance(by: 5)
        rig.store.waitForWrites()
        #expect(rig.store.writeCount == 2)
    }

    @Test("Flush with nothing waiting writes nothing")
    func flushWithNothingWaiting() {
        let rig = StoreRig()
        defer { rig.cleanUp() }
        rig.store.flush()
        #expect(rig.store.writeCount == 0)
        #expect(!rig.folder.fileExists)
    }

    @Test("The folder is made when it is missing, and no temp file is left behind")
    func foldersAndAtomicity() {
        let rig = StoreRig()
        defer { rig.cleanUp() }
        #expect(!FileManager.default.fileExists(atPath: rig.folder.directory.path))
        for position in 1...5 {
            rig.store.save(rig.snapshot(position: TimeInterval(position)))
            rig.clock.advance(by: 2)
        }
        rig.store.flush()
        #expect(rig.folder.contents == ["music-session.json"])
        #expect(rig.folder.readSnapshot()?.position == 5)
    }

    @Test("A write that cannot land is survived: the next one still works")
    func failedWriteIsSurvived() throws {
        let rig = StoreRig()
        defer { rig.cleanUp() }
        // A file where the folder should be: the first write fails.
        try FileManager.default.createDirectory(
            at: rig.folder.directory.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("in the way".utf8).write(to: rig.folder.directory)
        rig.store.save(rig.snapshot(position: 1))
        rig.store.waitForWrites()
        #expect(!rig.folder.fileExists)

        try FileManager.default.removeItem(at: rig.folder.directory)
        rig.clock.advance(by: 2)
        rig.store.save(rig.snapshot(position: 2))
        rig.store.waitForWrites()
        #expect(rig.folder.readSnapshot()?.position == 2)
    }

    // MARK: - Deleting

    @Test("Delete removes the file")
    func deleteRemovesTheFile() {
        let rig = StoreRig()
        defer { rig.cleanUp() }
        rig.store.save(rig.snapshot())
        rig.store.flush()
        #expect(rig.folder.fileExists)
        rig.store.delete()
        rig.store.waitForWrites()
        #expect(!rig.folder.fileExists)
        #expect(rig.store.load() == nil)
    }

    @Test("Delete also drops the write that was waiting, so the old session cannot come back")
    func deleteDropsPendingWrites() {
        let rig = StoreRig()
        defer { rig.cleanUp() }
        rig.store.save(rig.snapshot(position: 1))
        rig.store.save(rig.snapshot(position: 2))
        #expect(rig.scheduler.pendingCount == 1)

        rig.store.delete()
        #expect(rig.scheduler.pendingCount == 0)
        rig.scheduler.advance(by: 5)
        rig.store.flush()
        #expect(!rig.folder.fileExists)
    }

    @Test("A save right after a delete is written at once and lands after it")
    func saveAfterDelete() {
        let rig = StoreRig()
        defer { rig.cleanUp() }
        rig.store.save(rig.snapshot(position: 1))
        rig.store.delete()
        rig.store.save(rig.snapshot(["x", "y"], position: 2))
        rig.store.waitForWrites()
        #expect(rig.folder.readSnapshot()?.queue.current?.videoId == "x")
        #expect(rig.store.writeCount == 2)
    }

    @Test("Deleting with no file is quiet")
    func deleteWithNoFile() {
        let rig = StoreRig()
        defer { rig.cleanUp() }
        rig.store.delete()
        rig.store.waitForWrites()
        #expect(!rig.folder.fileExists)
    }

    // MARK: - Live location

    @Test("The live store keeps its file in the app's own Application Support folder")
    func liveLocation() {
        let url = MusicSessionStore.liveFileURL()
        #expect(url.lastPathComponent == "music-session.json")
        #expect(url.deletingLastPathComponent().lastPathComponent == "Deci")
        #expect(url.path.contains("Application Support"))
    }
}
