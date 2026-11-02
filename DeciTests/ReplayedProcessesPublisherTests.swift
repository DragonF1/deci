// DeciTests/ReplayedProcessesPublisherTests.swift
//
// Deci mutes every app it taps and plays the audio back from its own process. A recorder with a global process tap
// (GIF Record) hears the app's raw audio and Deci's replay of it, so the sound doubles. The fix is a handshake: Deci
// publishes the pids it taps in `replayed-processes.json` and the recorder leaves them out of its tap.
//
// The first suite covers the file itself (shape, skip-when-unchanged, removal, a failed write). The second runs the
// engine's side with the fake tap controller: which pids it publishes and when. Every file lives in a temp directory
// the test removes; no process tap is created, no audio plays and the real Application Support folder is never touched.

import Foundation
import AudioToolbox
import Testing
@testable import Deci

/// The contract's JSON, decoded.
private struct PublishedFile: Decodable, Equatable {
    var version: Int
    var publisher: Int
    var processes: [Int]
}

@MainActor
private func decodePublished(_ url: URL) throws -> PublishedFile {
    try JSONDecoder().decode(PublishedFile.self, from: Data(contentsOf: url))
}

@MainActor
private func fileExists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path)
}

// MARK: - The file

@Suite("ReplayedProcessesPublisher")
final class ReplayedProcessesPublisherTests {
    private let directory: URL
    private let fileURL: URL
    private let publisherPID: pid_t = 12_345

    init() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("deci-replayed-tests-\(UUID().uuidString)")
        fileURL = directory.appendingPathComponent(ReplayedProcessesPublisher.fileName)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makePublisher(at url: URL? = nil) -> ReplayedProcessesPublisher {
        ReplayedProcessesPublisher(fileURL: url ?? fileURL, publisherPID: publisherPID)
    }

    // MARK: Encoding

    @Test("encodes the exact bytes of the contract: version, publisher, processes sorted ascending")
    func encodesContractBytes() {
        let data = ReplayedProcessesPublisher.encode(pids: [333, 111, 222], publisher: 12_345)
        #expect(String(decoding: data, as: UTF8.self) == #"{"version":1,"publisher":12345,"processes":[111,222,333]}"#)
    }

    @Test("encodes the three contract keys and nothing else, with integer values")
    func encodesOnlyContractKeys() throws {
        let data = ReplayedProcessesPublisher.encode(pids: [7], publisher: 99)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["version", "publisher", "processes"])
        #expect(object["version"] as? Int == 1)
        #expect(object["publisher"] as? Int == 99)
        #expect(object["processes"] as? [Int] == [7])
    }

    @Test("encodes an empty set as an empty list")
    func encodesEmpty() {
        let data = ReplayedProcessesPublisher.encode(pids: [], publisher: 5)
        #expect(String(decoding: data, as: UTF8.self) == #"{"version":1,"publisher":5,"processes":[]}"#)
    }

    @Test("encodes the largest pid_t value without overflow")
    func encodesPIDRangeEdge() throws {
        let data = ReplayedProcessesPublisher.encode(pids: [1, pid_t.max], publisher: pid_t.max)
        let decoded = try JSONDecoder().decode(PublishedFile.self, from: data)
        #expect(decoded.processes == [1, Int(pid_t.max)])
        #expect(decoded.publisher == Int(pid_t.max))
    }

    @Test("encodes 10,000 pids sorted and unique")
    func encodesLargeSet() throws {
        let pids = Set((1...10_000).map { pid_t($0 * 3) })
        let data = ReplayedProcessesPublisher.encode(pids: pids, publisher: 1)
        let decoded = try JSONDecoder().decode(PublishedFile.self, from: data)
        #expect(decoded.processes.count == 10_000)
        #expect(decoded.processes == decoded.processes.sorted())
        #expect(decoded.processes.first == 3)
        #expect(decoded.processes.last == 30_000)
    }

    @Test("the live file is Application Support/Deci/replayed-processes.json")
    func liveURL() {
        let url = ReplayedProcessesPublisher.liveFileURL()
        #expect(url.lastPathComponent == "replayed-processes.json")
        #expect(url.deletingLastPathComponent().lastPathComponent == "Deci")
        #expect(url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "Application Support")
    }

    // MARK: Writing

    @Test("publish writes the file with this publisher's pid and the sorted pids")
    func publishWrites() throws {
        let publisher = makePublisher()
        publisher.publish(pids: [222, 111, 333])
        #expect(try decodePublished(fileURL) == PublishedFile(version: 1, publisher: 12_345, processes: [111, 222, 333]))
    }

    @Test("publish creates the directory when it is missing")
    func createsDirectory() throws {
        let nested = directory.appendingPathComponent("a/b/c").appendingPathComponent(ReplayedProcessesPublisher.fileName)
        makePublisher(at: nested).publish(pids: [10])
        #expect(try decodePublished(nested).processes == [10])
    }

    @Test("a write is atomic: the directory holds only the final file afterwards")
    func leavesNoTempFiles() throws {
        let publisher = makePublisher()
        publisher.publish(pids: [1])
        publisher.publish(pids: [1, 2])
        publisher.publish(pids: [3])
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(names == [ReplayedProcessesPublisher.fileName])
    }

    @Test("Deci's own pid and non-positive pids are never published")
    func dropsOwnAndInvalidPIDs() throws {
        let publisher = makePublisher()
        publisher.publish(pids: [12_345, 0, -1, 77])
        #expect(try decodePublished(fileURL).processes == [77])
    }

    @Test("a set of only Deci's own pid counts as empty and publishes no file")
    func onlyOwnPIDIsEmpty() {
        let publisher = makePublisher()
        publisher.publish(pids: [12_345])
        #expect(!fileExists(fileURL))
    }

    // MARK: Skip when unchanged

    @Test("publishing the same set again does not rewrite the file")
    func unchangedIsSkipped() throws {
        let publisher = makePublisher()
        publisher.publish(pids: [1, 2])
        // Remove the file behind the publisher's back: a rewrite would bring it back.
        try FileManager.default.removeItem(at: fileURL)
        publisher.publish(pids: [2, 1])
        #expect(!fileExists(fileURL))
    }

    @Test("a changed set rewrites the file")
    func changeRewrites() throws {
        let publisher = makePublisher()
        publisher.publish(pids: [1, 2])
        publisher.publish(pids: [1, 2, 3])
        #expect(try decodePublished(fileURL).processes == [1, 2, 3])
        publisher.publish(pids: [3])
        #expect(try decodePublished(fileURL).processes == [3])
    }

    // MARK: Removal

    @Test("publishing an empty set removes the file")
    func emptyRemoves() {
        let publisher = makePublisher()
        publisher.publish(pids: [1])
        #expect(fileExists(fileURL))
        publisher.publish(pids: [])
        #expect(!fileExists(fileURL))
    }

    @Test("clear removes the file")
    func clearRemoves() {
        let publisher = makePublisher()
        publisher.publish(pids: [1])
        publisher.clear()
        #expect(!fileExists(fileURL))
    }

    @Test("after a clear the same set publishes again")
    func publishAfterClear() throws {
        let publisher = makePublisher()
        publisher.publish(pids: [1])
        publisher.clear()
        publisher.publish(pids: [1])
        #expect(try decodePublished(fileURL).processes == [1])
    }

    @Test("the first empty publish removes a stale file a crashed run left behind")
    func firstEmptyRemovesStaleFile() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"version":1,"publisher":1,"processes":[4,5]}"#.utf8).write(to: fileURL)
        makePublisher().publish(pids: [])
        #expect(!fileExists(fileURL))
    }

    @Test("an unchanged list is checked again after recheckEvery publishes, and a removed file is written back")
    func recheckRestoresRemovedFile() throws {
        let publisher = makePublisher()
        publisher.publish(pids: [1, 2])
        try FileManager.default.removeItem(at: fileURL)
        for _ in 0..<(ReplayedProcessesPublisher.recheckEvery - 1) { publisher.publish(pids: [1, 2]) }
        #expect(!fileExists(fileURL))
        publisher.publish(pids: [1, 2])
        #expect(try decodePublished(fileURL) == PublishedFile(version: 1, publisher: 12_345, processes: [1, 2]))
    }

    @Test("the recheck takes the file back from another Deci that replaced it")
    func recheckReplacesForeignFile() throws {
        let publisher = makePublisher()
        publisher.publish(pids: [1, 2])
        try Data(#"{"version":1,"publisher":\#(getpid()),"processes":[9]}"#.utf8).write(to: fileURL)
        for _ in 0..<ReplayedProcessesPublisher.recheckEvery { publisher.publish(pids: [1, 2]) }
        #expect(try decodePublished(fileURL).publisher == 12_345)
    }

    @Test("an empty list leaves a file another running Deci wrote")
    func removalLeavesLiveForeignFile() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"version":1,"publisher":\#(getpid()),"processes":[9]}"#.utf8).write(to: fileURL)
        makePublisher().publish(pids: [])
        #expect(fileExists(fileURL))
    }

    @Test("clearing when no file exists is quiet and counts as done")
    func clearWithoutFile() throws {
        let publisher = makePublisher()
        publisher.clear()
        #expect(!fileExists(fileURL))
        // A file someone else puts there now survives a second clear: the first one was a success, not a failure to retry.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: fileURL)
        publisher.clear()
        #expect(fileExists(fileURL))
    }

    // MARK: Failure

    @Test("a failed write does not crash and is retried on the next publish of the same set")
    func failedWriteIsRetried() throws {
        // The directory's place is taken by a regular file, so creating the directory (and so the write) fails.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let blocker = directory.appendingPathComponent("blocked")
        try Data("not a directory".utf8).write(to: blocker)
        let blockedURL = blocker.appendingPathComponent(ReplayedProcessesPublisher.fileName)

        let publisher = makePublisher(at: blockedURL)
        publisher.publish(pids: [1, 2])
        #expect(!fileExists(blockedURL))

        // The obstacle goes away. Publishing the same set must write: the failed set was never recorded as published.
        try FileManager.default.removeItem(at: blocker)
        publisher.publish(pids: [1, 2])
        #expect(try decodePublished(blockedURL).processes == [1, 2])
    }

    @Test("repeated failures stay quiet and recover when the write works again")
    func repeatedFailuresRecover() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let blocker = directory.appendingPathComponent("blocked")
        try Data("x".utf8).write(to: blocker)
        let blockedURL = blocker.appendingPathComponent(ReplayedProcessesPublisher.fileName)

        let publisher = makePublisher(at: blockedURL)
        for _ in 0..<20 { publisher.publish(pids: [9]) }
        #expect(!fileExists(blockedURL))

        try FileManager.default.removeItem(at: blocker)
        publisher.publish(pids: [9, 10])
        #expect(try decodePublished(blockedURL).processes == [9, 10])
    }
}

// MARK: - The engine's side

@Suite("AudioEngine: replayed processes")
final class AudioEngineReplayedProcessesTests {
    let h: EngineHarness
    /// The harness keeps settings and the published file in one temp directory.
    private let tempDirectory: URL

    init() {
        h = EngineHarness()
        tempDirectory = h.replayedProcessesURL.deletingLastPathComponent()
    }

    deinit {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    private var url: URL { h.replayedProcessesURL }

    /// An app whose process objects 11, 12 and 13 belong to pids 111, 222 and 333.
    private func chrome(pid: pid_t = 4242, ids: [AudioObjectID] = [11, 12, 13]) -> AudioApp {
        h.probes.processPIDs[11] = 111
        h.probes.processPIDs[12] = 222
        h.probes.processPIDs[13] = 333
        return h.makeApp(pid: pid, ids: ids)
    }

    @Test("a tapped app's process objects are published as sorted pids with Deci's own pid as publisher")
    func publishesTappedProcesses() async throws {
        h.launch(chrome(ids: [13, 11, 12]))
        await h.engine.runHealthTick()
        #expect(try decodePublished(url) == PublishedFile(version: 1, publisher: Int(getpid()), processes: [111, 222, 333]))
    }

    @Test("taps of several apps are merged, and a pid shared by two process objects appears once")
    func mergesTapsAndDeduplicates() async throws {
        h.probes.processPIDs[21] = 500
        h.probes.processPIDs[22] = 500
        h.probes.processPIDs[23] = 400
        h.launchAll([
            chrome(ids: [11, 12]),
            h.makeApp(pid: 5151, ids: [21, 22, 23], bundleID: "com.spotify.client"),
        ])
        await h.engine.runHealthTick()
        #expect(try decodePublished(url).processes == [111, 222, 400, 500])
    }

    @Test("a process object whose pid cannot be read is skipped")
    func skipsUnreadableObjects() async throws {
        // Object 99 has no pid in the probe, like a process object that went away.
        h.launch(chrome(ids: [11, 99, 12]))
        await h.engine.runHealthTick()
        #expect(try decodePublished(url).processes == [111, 222])
    }

    @Test("Deci's own pid is left out if a process object resolves to it")
    func excludesOwnPID() async throws {
        h.probes.processPIDs[31] = getpid()
        h.launch(chrome(ids: [11, 31]))
        await h.engine.runHealthTick()
        #expect(try decodePublished(url).processes == [111])
    }

    @Test("an app that is only listed, with no tap, publishes nothing")
    func noTapNoFile() async {
        h.probes.processPIDs[11] = 111
        h.processMonitor.activeApps = [h.makeApp(ids: [11])]
        await h.engine.runHealthTick()
        #expect(!fileExists(url))
    }

    @Test("an unchanged tap set is not written again on later ticks")
    func unchangedSetIsNotRewritten() async throws {
        h.launch(chrome())
        await h.engine.runHealthTick()
        try FileManager.default.removeItem(at: url)
        await h.engine.runHealthTick()
        await h.engine.runHealthTick()
        #expect(!fileExists(url))
    }

    @Test("a new tap is published on the next tick, and a pid change rewrites the file")
    func newTapIsPublished() async throws {
        h.launch(chrome(ids: [11]))
        await h.engine.runHealthTick()
        #expect(try decodePublished(url).processes == [111])

        h.probes.processPIDs[41] = 600
        h.launch(h.makeApp(pid: 6161, ids: [41], bundleID: "com.apple.Safari"))
        await h.engine.runHealthTick()
        #expect(try decodePublished(url).processes == [111, 600])
    }

    @Test("a tap rebuilt around a grown process list publishes the new helpers")
    func rebuiltTapPublishesGrownList() async throws {
        let tap = h.launch(chrome(ids: [11]))
        await h.engine.runHealthTick()
        #expect(try decodePublished(url).processes == [111])

        // The real controller replaces `app` when it is rebuilt around a new process list.
        tap.app = chrome(ids: [11, 12, 13])
        await h.engine.runHealthTick()
        #expect(try decodePublished(url).processes == [111, 222, 333])
    }

    @Test("the file is removed in the tick after the last tap goes, even though that tick returns early")
    func lastTapGoneRemovesFile() async {
        let app = chrome()
        h.launch(app)
        await h.engine.runHealthTick()
        #expect(fileExists(url))

        h.engine.ignoreApp(app)
        await h.engine.runHealthTick()
        #expect(!fileExists(url))
    }

    @Test("the first tick with no taps removes a stale file left by an earlier run")
    func staleFileRemovedAtStartup() async throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"version":1,"publisher":1,"processes":[4]}"#.utf8).write(to: url)
        #expect(fileExists(url))
        await h.engine.runHealthTick()
        #expect(!fileExists(url))
    }

    @Test("shutdown removes the file")
    func shutdownRemovesFile() async {
        h.launch(chrome())
        await h.engine.runHealthTick()
        #expect(fileExists(url))

        h.engine.shutdown()
        #expect(!fileExists(url))
    }

    @Test("stop removes the file too, so no tick can leave a stale one behind")
    func stopRemovesFile() async {
        h.launch(chrome())
        await h.engine.runHealthTick()
        #expect(fileExists(url))

        h.engine.stop()
        #expect(!fileExists(url))
    }

    @Test("withdrawing the list removes the file without touching the taps")
    func withdrawRemovesFile() async {
        let tap = h.launch(chrome())
        await h.engine.runHealthTick()
        h.engine.withdrawReplayedProcesses()
        #expect(!fileExists(url))
        #expect(!tap.wasInvalidated)
    }
}
