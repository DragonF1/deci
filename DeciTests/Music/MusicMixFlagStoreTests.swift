// DeciTests/Music/MusicMixFlagStoreTests.swift
// Tier 2b P4: the no-mix flag file. Round trip, ordered pairs, the 5000 caps, a corrupt or unknown-version file moved to
// .bad, writes coalesced to one a second, and a file that outlives the analysis database. Folders live under
// /Volumes/Storage/_test, never in the real Application Support.

import Foundation
import Testing
@testable import Deci

@MainActor
private struct FlagRig {
    let directory = URL(fileURLWithPath: "/Volumes/Storage/_test/deci/mixflags", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let clock = MutableClock()
    let scheduler: ManualWriteScheduler
    var fileURL: URL { directory.appendingPathComponent("MusicMixFlags.json", isDirectory: false) }
    /// The files the store moved aside: `MusicMixFlags.json.<stamp>.bad`.
    var badFiles: [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasPrefix("MusicMixFlags.json.") && $0.hasSuffix(".bad") }
            .map { directory.appendingPathComponent($0, isDirectory: false) }
    }

    init() {
        scheduler = ManualWriteScheduler(clock: clock)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func makeStore() -> MusicMixFlagStore {
        let clock = self.clock
        return MusicMixFlagStore(fileURL: fileURL, now: { clock.now }, scheduler: scheduler)
    }

    func writeRaw(_ text: String) throws {
        try text.data(using: .utf8)!.write(to: fileURL)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: directory) }
}

/// A scheduler that asks the store something from inside `schedule`: with the timer armed under the store's lock this
/// would re-enter it.
private final class ReentrantScheduler: MusicWriteScheduler, @unchecked Sendable {
    var store: MusicMixFlagStore?
    var asked = 0
    func schedule(after delay: TimeInterval, _ work: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        if store?.startsClean("probe") != nil { asked += 1 }
        return {}
    }
}

@MainActor
@Suite("MusicMixFlagStore")
struct MusicMixFlagStoreTests {
    @Test("a new store with no file starts empty and creates nothing")
    func startsEmpty() {
        let rig = FlagRig()
        defer { rig.cleanUp() }
        let store = rig.makeStore()
        #expect(!store.startsClean("a"))
        #expect(!store.pairIsClean(from: "a", to: "b"))
        #expect(!FileManager.default.fileExists(atPath: rig.fileURL.path))
    }

    @Test("song and pair flags round trip through the file, and unflagging removes them")
    func roundTrip() throws {
        let rig = FlagRig()
        defer { rig.cleanUp() }
        let store = rig.makeStore()
        store.setStartsClean(true, videoId: "a")
        store.setStartsClean(true, videoId: "b")
        store.setPairClean(true, from: "x", to: "y")
        store.flush()

        let reopened = rig.makeStore()
        #expect(reopened.startsClean("a"))
        #expect(reopened.startsClean("b"))
        #expect(!reopened.startsClean("c"))
        #expect(reopened.pairIsClean(from: "x", to: "y"))

        reopened.setStartsClean(false, videoId: "a")
        reopened.setPairClean(false, from: "x", to: "y")
        reopened.flush()
        let again = rig.makeStore()
        #expect(!again.startsClean("a"))
        #expect(again.startsClean("b"))
        #expect(!again.pairIsClean(from: "x", to: "y"))
    }

    @Test("the file has the documented shape")
    func fileShape() throws {
        let rig = FlagRig()
        defer { rig.cleanUp() }
        let store = rig.makeStore()
        store.setStartsClean(true, videoId: "a")
        store.setPairClean(true, from: "x", to: "y")
        store.flush()
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: rig.fileURL)) as? [String: Any]
        )
        #expect(object["version"] as? Int == 1)
        #expect(object["cleanStart"] as? [String] == ["a"])
        #expect(object["pairs"] as? [[String]] == [["x", "y"]])
    }

    @Test("a pair is ordered: A into B does not flag B into A")
    func pairIsOrdered() {
        let rig = FlagRig()
        defer { rig.cleanUp() }
        let store = rig.makeStore()
        store.setPairClean(true, from: "a", to: "b")
        #expect(store.pairIsClean(from: "a", to: "b"))
        #expect(!store.pairIsClean(from: "b", to: "a"))
    }

    @Test("a song flag and a pair flag are independent")
    func flagsAreIndependent() {
        let rig = FlagRig()
        defer { rig.cleanUp() }
        let store = rig.makeStore()
        store.setStartsClean(true, videoId: "b")
        #expect(!store.pairIsClean(from: "a", to: "b"))
        store.setPairClean(true, from: "a", to: "c")
        #expect(!store.startsClean("c"))
    }

    @Test("flags survive the analysis database being deleted")
    func survivesAnalysisReset() throws {
        let rig = FlagRig()
        defer { rig.cleanUp() }
        let database = rig.directory.appendingPathComponent("Analysis.sqlite")
        try Data("x".utf8).write(to: database)
        let store = rig.makeStore()
        store.setStartsClean(true, videoId: "a")
        store.flush()
        try FileManager.default.removeItem(at: database)
        #expect(rig.makeStore().startsClean("a"))
    }

    // MARK: - Caps

    @Test("5000 song flags are kept and the next one drops the oldest")
    func songCap() {
        let rig = FlagRig()
        defer { rig.cleanUp() }
        let store = rig.makeStore()
        for i in 0..<5001 { store.setStartsClean(true, videoId: "id\(i)") }
        #expect(store.cleanStartCount == 5000)
        #expect(!store.startsClean("id0"))
        #expect(store.startsClean("id1"))
        #expect(store.startsClean("id5000"))
        store.flush()
        let reopened = rig.makeStore()
        #expect(reopened.cleanStartCount == 5000)
        #expect(!reopened.startsClean("id0"))
    }

    @Test("5000 pairs are kept and the next one drops the oldest")
    func pairCap() {
        let rig = FlagRig()
        defer { rig.cleanUp() }
        let store = rig.makeStore()
        for i in 0..<5001 { store.setPairClean(true, from: "f\(i)", to: "t\(i)") }
        #expect(store.pairCount == 5000)
        #expect(!store.pairIsClean(from: "f0", to: "t0"))
        #expect(store.pairIsClean(from: "f1", to: "t1"))
        #expect(store.pairIsClean(from: "f5000", to: "t5000"))
    }

    @Test("flagging the same song twice is one entry")
    func noDuplicates() {
        let rig = FlagRig()
        defer { rig.cleanUp() }
        let store = rig.makeStore()
        store.setStartsClean(true, videoId: "a")
        store.setStartsClean(true, videoId: "a")
        #expect(store.cleanStartCount == 1)
    }

    // MARK: - Bad files

    @Test("a corrupt file is moved to .bad and the store starts empty")
    func corruptFileMovedAside() throws {
        let rig = FlagRig()
        defer { rig.cleanUp() }
        try rig.writeRaw("{ not json")
        let store = rig.makeStore()
        #expect(!store.startsClean("a"))
        #expect(!FileManager.default.fileExists(atPath: rig.fileURL.path))
        #expect(rig.badFiles.count == 1)
        #expect(try String(contentsOf: try #require(rig.badFiles.first), encoding: .utf8) == "{ not json")
        store.setStartsClean(true, videoId: "a")
        store.flush()
        #expect(rig.makeStore().startsClean("a"))
    }

    @Test("a newer version is left untouched, nothing is loaded and nothing is written this session")
    func newerVersionIsLeftAlone() throws {
        let rig = FlagRig()
        defer { rig.cleanUp() }
        let text = #"{"version":2,"cleanStart":["a"],"pairs":[]}"#
        try rig.writeRaw(text)
        let store = rig.makeStore()
        #expect(!store.startsClean("a"))
        #expect(rig.badFiles.isEmpty)
        store.setStartsClean(true, videoId: "b")
        store.flush()
        #expect(store.startsClean("b"), "flags still work in memory")
        #expect(store.writeCount == 0)
        #expect(try String(contentsOf: rig.fileURL, encoding: .utf8) == text, "the file on disk is as it was")
    }

    @Test("a file that cannot be read is left untouched and writes stay off")
    func unreadableFileIsLeftAlone() throws {
        let rig = FlagRig()
        defer { rig.cleanUp() }
        let text = #"{"version":1,"cleanStart":["a"],"pairs":[]}"#
        try rig.writeRaw(text)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: rig.fileURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: rig.fileURL.path) }
        let store = rig.makeStore()
        #expect(!store.startsClean("a"))
        #expect(rig.badFiles.isEmpty)
        store.setStartsClean(true, videoId: "b")
        store.flush()
        #expect(store.writeCount == 0)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: rig.fileURL.path)
        #expect(try String(contentsOf: rig.fileURL, encoding: .utf8) == text)
    }

    @Test("two bad files in a row each keep their own .bad name")
    func badNamesDoNotCollide() throws {
        let rig = FlagRig()
        defer { rig.cleanUp() }
        try rig.writeRaw("{ one")
        _ = rig.makeStore()
        try rig.writeRaw("{ two")
        _ = rig.makeStore()
        #expect(rig.badFiles.count == 2)
    }

    @Test("a pair that is not two ids makes the file unusable")
    func malformedPairMovedAside() throws {
        let rig = FlagRig()
        defer { rig.cleanUp() }
        try rig.writeRaw(#"{"version":1,"cleanStart":["a"],"pairs":[["x"]]}"#)
        let store = rig.makeStore()
        #expect(!store.startsClean("a"))
        #expect(rig.badFiles.count == 1)
    }

    @Test("a file holding more than the cap loads only the newest entries")
    func oversizedFileIsTrimmed() throws {
        let rig = FlagRig()
        defer { rig.cleanUp() }
        let ids = (0..<5003).map { "\"id\($0)\"" }.joined(separator: ",")
        try rig.writeRaw(#"{"version":1,"cleanStart":[\#(ids)],"pairs":[]}"#)
        let store = rig.makeStore()
        #expect(store.cleanStartCount == 5000)
        #expect(!store.startsClean("id2"))
        #expect(store.startsClean("id3"))
    }

    // MARK: - Writes

    @Test("the first change writes at once, a burst after it is one trailing write a second later")
    func writesCoalesce() {
        let rig = FlagRig()
        defer { rig.cleanUp() }
        let store = rig.makeStore()
        store.setStartsClean(true, videoId: "a")
        #expect(store.writeCount == 1)
        store.setStartsClean(true, videoId: "b")
        store.setStartsClean(true, videoId: "c")
        store.setPairClean(true, from: "a", to: "b")
        #expect(store.writeCount == 1)
        #expect(rig.scheduler.pendingCount == 1)

        rig.scheduler.advance(by: 1)
        #expect(store.writeCount == 2)
        store.waitForWrites()
        let reopened = rig.makeStore()
        #expect(reopened.startsClean("c"))
        #expect(reopened.pairIsClean(from: "a", to: "b"))
    }

    @Test("a change that changes nothing writes nothing")
    func noOpWritesNothing() {
        let rig = FlagRig()
        defer { rig.cleanUp() }
        let store = rig.makeStore()
        store.setStartsClean(false, videoId: "a")
        store.setPairClean(false, from: "a", to: "b")
        #expect(store.writeCount == 0)
    }

    @Test("flush writes the waiting change now")
    func flushWritesNow() {
        let rig = FlagRig()
        defer { rig.cleanUp() }
        let store = rig.makeStore()
        store.setStartsClean(true, videoId: "a")
        store.setStartsClean(true, videoId: "b")
        store.flush()
        #expect(store.writeCount == 2)
        #expect(rig.makeStore().startsClean("b"))
    }

    @Test("the live file sits beside the session file")
    func liveFileBesideSession() {
        #expect(MusicMixFlagStore.liveFileURL().lastPathComponent == "MusicMixFlags.json")
        #expect(
            MusicMixFlagStore.liveFileURL().deletingLastPathComponent()
                == MusicSessionStore.liveFileURL().deletingLastPathComponent()
        )
    }

    @Test("the trailing-write timer is armed outside the store's lock")
    func timerIsArmedOutsideTheLock() {
        let rig = FlagRig()
        defer { rig.cleanUp() }
        let scheduler = ReentrantScheduler()
        let clock = rig.clock
        let store = MusicMixFlagStore(fileURL: rig.fileURL, now: { clock.now }, scheduler: scheduler)
        scheduler.store = store
        store.setStartsClean(true, videoId: "a")
        store.setStartsClean(true, videoId: "b")
        #expect(scheduler.asked == 1, "the second change inside the second armed the one trailing timer")
        store.flush()
    }
}
