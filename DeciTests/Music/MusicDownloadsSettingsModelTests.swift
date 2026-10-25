// DeciTests/Music/MusicDownloadsSettingsModelTests.swift
// What the Downloads section of Settings > General shows and does: the counts (from the live service once it has loaded,
// from the index on disk before), the size measured off the main thread, recomputed when the download set changes but not
// for every progress tick and not once per song of a burst, a stale measurement never replacing a newer one, and Remove all
// reaching the service (building it first when Settings is the first to need it). Real service and store on a fake
// transport, in a folder under /Volumes/Storage/_test; nothing touches the network or the real downloads.

import Foundation
import Observation
import os
import Testing
@testable import Deci

/// Stands for the Music host: the service that exists, and the one that `prepare` would build.
@MainActor
@Observable
private final class ServiceBox {
    var service: MusicDownloadService?
    @ObservationIgnored var waiting: MusicDownloadService?
    @ObservationIgnored private(set) var prepared = 0

    func prepare() -> MusicDownloadService? {
        prepared += 1
        if service == nil { service = waiting }
        return service
    }
}

/// Counts the measurements the model asked for and where they ran.
private nonisolated final class Measurements: Sendable {
    private struct State {
        var count = 0
        var ranOnMain = false
        var counts = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func measured() {
        state.withLock {
            $0.count += 1
            if Thread.isMainThread { $0.ranOnMain = true }
        }
    }

    func counted() { state.withLock { $0.counts += 1 } }

    var count: Int { state.withLock { $0.count } }
    var ranOnMain: Bool { state.withLock { $0.ranOnMain } }
    var counts: Int { state.withLock { $0.counts } }
}

@MainActor
@Suite("MusicDownloadsSettingsModel")
struct MusicDownloadsSettingsModelTests {
    private func id(_ number: Int) -> String { DownloadSamples.id(number) }

    private func makeRig(songs: WipeSongGate = WipeSongGate(), shaped: Bool = true) -> DownloadServiceRig {
        DownloadServiceRig(folder: DownloadTestFolder(shaped: shaped), handler: songs.handler, backend: FakeMusicBackend())
    }

    private func makeModel(
        _ rig: DownloadServiceRig, box: ServiceBox, measurements: Measurements = Measurements(),
        debounce: Duration = .milliseconds(20)
    ) -> MusicDownloadsSettingsModel {
        MusicDownloadsSettingsModel(
            downloads: { box.service },
            prepare: { box.prepare() },
            root: rig.folder.root,
            debounce: debounce,
            measure: { root in
                measurements.measured()
                return MusicDownloadDiskUsage.measure(root: root)
            },
            storedCounts: { root in
                measurements.counted()
                return MusicDownloadDiskUsage.storedCounts(at: root)
            }
        )
    }

    /// Three songs, two of them in a playlist, all on disk with the index written.
    private func fill(_ rig: DownloadServiceRig) async {
        await rig.script("VLPLone", tracks: DownloadSamples.tracks(1...2))
        rig.service.downloadCollection(rig.request("VLPLone"))
        rig.download(id(9))
        await rig.service.waitUntilIdle()
    }

    // MARK: - Reading

    @Test("before anything is read the counts and the size are unknown, and nothing can be removed")
    func unknownAtFirst() {
        let rig = makeRig()
        defer { rig.cleanUp() }
        let model = makeModel(rig, box: ServiceBox())

        #expect(model.songs == nil && model.collections == nil && model.usage == nil)
        #expect(model.summary == "Calculating")
        #expect(model.sizeText == "Calculating")
        #expect(!model.canRemoveAll)
        #expect(!model.isRemoving)
    }

    @Test("with nothing downloaded and no folder, the section says so and Remove all is off")
    func nothingDownloaded() async {
        let rig = makeRig()
        defer { rig.cleanUp() }
        let model = makeModel(rig, box: ServiceBox())

        await model.refresh()

        #expect(model.songs == 0 && model.collections == 0)
        #expect(model.summary == "Nothing downloaded")
        #expect(model.usage == MusicDownloadDiskUsage.Usage(bytes: 0, hasFiles: false))
        #expect(!model.canRemoveAll)
    }

    @Test("before the service exists the counts come from the index on disk, and the size from the folder")
    func readsTheDiskWithoutAService() async {
        let rig = makeRig()
        defer { rig.cleanUp() }
        await fill(rig)
        let measurements = Measurements()
        let model = makeModel(rig, box: ServiceBox(), measurements: measurements)

        await model.refresh()

        #expect(model.songs == 3)
        #expect(model.collections == 1)
        #expect(model.summary == "3 songs, 1 playlist or album")
        #expect((model.usage?.bytes ?? 0) > 0)
        #expect(model.usage?.hasFiles == true)
        #expect(model.canRemoveAll)
        #expect(measurements.counts == 1)
    }

    @Test("once the service has loaded the counts come from it and the index is not read")
    func readsTheLiveService() async {
        let rig = makeRig()
        defer { rig.cleanUp() }
        await fill(rig)
        let box = ServiceBox()
        box.service = rig.service
        let measurements = Measurements()
        let model = makeModel(rig, box: box, measurements: measurements)

        await model.refresh()

        #expect(model.songs == 3)
        #expect(model.collections == 1)
        #expect(measurements.counts == 0)
        #expect(measurements.count == 1)
    }

    @Test("the folder is measured off the main thread")
    func measuresOffTheMainThread() async {
        let rig = makeRig()
        defer { rig.cleanUp() }
        await fill(rig)
        let measurements = Measurements()
        let model = makeModel(rig, box: ServiceBox(), measurements: measurements)

        await model.refresh()

        #expect(measurements.count == 1)
        #expect(!measurements.ranOnMain)
    }

    @Test("the confirmation names the size that was measured")
    func confirmationUsesTheMeasuredSize() async {
        let rig = makeRig()
        defer { rig.cleanUp() }
        await fill(rig)
        let model = makeModel(rig, box: ServiceBox())
        #expect(model.confirmationMessage == MusicDownloadSettingsText.confirmationMessage(bytes: nil))

        await model.refresh()

        let bytes = model.usage?.bytes
        #expect(bytes != nil)
        #expect(model.confirmationMessage == MusicDownloadSettingsText.confirmationMessage(bytes: bytes))
        #expect(model.sizeText == MusicDownloadSettingsText.sizeText(bytes))
    }

    @Test("a measurement that finishes after a newer one never replaces it")
    func staleMeasurementIsDropped() async {
        let rig = makeRig()
        defer { rig.cleanUp() }
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let release = DispatchSemaphore(value: 0)
        let model = MusicDownloadsSettingsModel(
            downloads: { nil },
            prepare: { nil },
            root: rig.folder.root,
            debounce: .milliseconds(20),
            measure: { _ in
                let call = calls.withLock { (count: inout Int) -> Int in
                    count += 1
                    return count
                }
                if call == 1 {
                    release.wait()
                    return MusicDownloadDiskUsage.Usage(bytes: 111, hasFiles: true)
                }
                return MusicDownloadDiskUsage.Usage(bytes: 222, hasFiles: true)
            },
            storedCounts: { _ in MusicDownloadDiskUsage.Counts(songs: 0, collections: 0) }
        )
        let older = Task { @MainActor in await model.refresh() }
        #expect(await rig.eventually { calls.withLock { $0 } == 1 })

        await model.refresh()
        release.signal()
        await older.value

        #expect(model.usage?.bytes == 222)
    }

    // MARK: - Watching

    @Test("progress ticks do not measure again, the song finishing does")
    func progressDoesNotMeasure() async {
        let first = MusicTestGate()
        let second = MusicTestGate()
        let payload = DownloadSamples.payload(35)
        let rig = DownloadServiceRig(
            folder: DownloadTestFolder(shaped: true),
            handler: { request, _ in
                switch request.range.lowerBound {
                case 0: await first.wait()
                case 10: await second.wait()
                default: break
                }
                return FakeDownloadTransport.chunk(of: payload, request.range)
            },
            backend: FakeMusicBackend()
        )
        defer { rig.cleanUp() }
        await rig.service.waitUntilLoaded()
        let box = ServiceBox()
        box.service = rig.service
        let measurements = Measurements()
        let model = makeModel(rig, box: box, measurements: measurements, debounce: .milliseconds(30))
        let watching = Task { @MainActor in await model.watch() }
        defer { watching.cancel() }
        #expect(await rig.eventually { measurements.count == 1 && model.usage != nil })

        rig.download(id(1))
        #expect(await rig.eventually { await rig.requestCount(for: id(1)) == 1 })
        rig.clock.advance(by: 1)
        await first.open()
        #expect(await rig.eventually { fraction(rig.service.state(for: id(1))) > 0 }, "no progress reached the row")
        try? await Task.sleep(for: .milliseconds(300))
        #expect(measurements.count == 1, "the download started or progressed and the folder was measured")

        await second.open()
        #expect(await rig.eventually { model.songs == 1 })
        #expect(await rig.eventually { measurements.count == 2 })
    }

    private func fraction(_ state: MusicDownloadState) -> Double {
        if case .downloading(let value) = state { return value }
        return 0
    }

    @Test("a burst of songs finishing is measured once, after it settles")
    func burstIsDebounced() async {
        let rig = makeRig()
        defer { rig.cleanUp() }
        await rig.service.waitUntilLoaded()
        let box = ServiceBox()
        box.service = rig.service
        let measurements = Measurements()
        let model = makeModel(rig, box: box, measurements: measurements, debounce: .milliseconds(250))
        let watching = Task { @MainActor in await model.watch() }
        defer { watching.cancel() }
        #expect(await rig.eventually { measurements.count == 1 && model.usage != nil })

        for number in 1...4 { rig.download(id(number)) }
        await rig.service.waitUntilIdle()
        #expect(await rig.eventually { model.songs == 4 })
        try? await Task.sleep(for: .milliseconds(700))

        #expect(measurements.count == 2)
        #expect(model.songs == 4)
        #expect(model.usage?.hasFiles == true)
    }

    @Test("a service that appears later is picked up")
    func servicesAppearsLater() async {
        let rig = makeRig()
        defer { rig.cleanUp() }
        await fill(rig)
        let box = ServiceBox()
        let measurements = Measurements()
        let model = makeModel(rig, box: box, measurements: measurements, debounce: .milliseconds(20))
        let watching = Task { @MainActor in await model.watch() }
        defer { watching.cancel() }
        #expect(await rig.eventually { measurements.count == 1 && model.songs == 3 })
        #expect(measurements.counts == 1)

        box.service = rig.service

        #expect(await rig.eventually { measurements.count == 2 })
        #expect(model.songs == 3)
        #expect(measurements.counts == 1, "the loaded service answers, not the index")
    }

    @Test("a cancelled watch ends and measures nothing more")
    func cancelledWatchStops() async {
        let rig = makeRig()
        defer { rig.cleanUp() }
        let box = ServiceBox()
        box.service = rig.service
        let measurements = Measurements()
        let model = makeModel(rig, box: box, measurements: measurements, debounce: .milliseconds(20))
        let watching = Task { @MainActor in await model.watch() }
        #expect(await rig.eventually { measurements.count == 1 })

        watching.cancel()
        await watching.value
        rig.download(id(1))
        await rig.service.waitUntilIdle()
        try? await Task.sleep(for: .milliseconds(200))

        #expect(measurements.count == 1)
    }

    @Test("a sync that changes no count and no file does not measure the folder again")
    func noOpSyncDoesNotMeasure() async {
        let rig = makeRig()
        defer { rig.cleanUp() }
        await fill(rig)
        let box = ServiceBox()
        box.service = rig.service
        let measurements = Measurements()
        let model = makeModel(rig, box: box, measurements: measurements, debounce: .milliseconds(30))
        let watching = Task { @MainActor in await model.watch() }
        defer { watching.cancel() }
        #expect(await rig.eventually { measurements.count == 1 && model.usage != nil })

        // The same page is read again: the collection's record is written anew (its time of sync), nothing is added or deleted.
        rig.clock.advance(by: 60)
        rig.service.sync("VLPLone")
        await rig.service.waitUntilIdle()
        try? await Task.sleep(for: .milliseconds(400))

        #expect(measurements.count == 1, "a record that was written again with the same counts measured the folder")
        #expect(model.songs == 3 && model.collections == 1)
    }

    @Test("a picture saved after the counts settled is a change of the disk, so the folder is measured again")
    func coverSaveMeasures() async {
        let gate = MusicTestGate()
        let rig = DownloadServiceRig(
            folder: DownloadTestFolder(shaped: true), backend: FakeMusicBackend(), covers: FakeCoverFetcher(gate: gate)
        )
        defer { rig.cleanUp() }
        await rig.service.waitUntilLoaded()
        let box = ServiceBox()
        box.service = rig.service
        let measurements = Measurements()
        let model = makeModel(rig, box: box, measurements: measurements, debounce: .milliseconds(30))
        let watching = Task { @MainActor in await model.watch() }
        defer { watching.cancel() }
        #expect(await rig.eventually { measurements.count == 1 && model.usage != nil })

        rig.service.download(DownloadSamples.track(id(1)).withCover("https://img.example.test/a=w120-h120"))
        #expect(await rig.eventually { measurements.count == 2 && model.songs == 1 })

        // The picture arrives long after the count settled: no count moves, a file is added.
        await gate.open()

        #expect(await rig.eventually { measurements.count == 3 }, "a new file on the disk was not measured")
    }

    @Test("a measurement still running when the watch is cancelled is told to stop, and its result is dropped")
    func cancelledWatchStopsTheMeasurement() async {
        let rig = makeRig()
        defer { rig.cleanUp() }
        let started = OSAllocatedUnfairLock(initialState: false)
        let sawCancel = OSAllocatedUnfairLock(initialState: false)
        let model = MusicDownloadsSettingsModel(
            downloads: { nil },
            prepare: { nil },
            root: rig.folder.root,
            debounce: .milliseconds(20),
            measure: { _ in
                started.withLock { $0 = true }
                // Walks until it is told to stop, but for no more than a few seconds.
                let deadline = ContinuousClock.now + .seconds(5)
                while !Task.isCancelled, ContinuousClock.now < deadline { Thread.sleep(forTimeInterval: 0.005) }
                sawCancel.withLock { $0 = Task.isCancelled }
                return MusicDownloadDiskUsage.Usage(bytes: 777, hasFiles: true)
            },
            storedCounts: { _ in MusicDownloadDiskUsage.Counts(songs: 0, collections: 0) }
        )
        let watching = Task { @MainActor in await model.watch() }
        #expect(await rig.eventually { started.withLock { $0 } })

        watching.cancel()
        await watching.value

        #expect(await rig.eventually { sawCancel.withLock { $0 } }, "the measurement was never told to stop")
        #expect(model.usage == nil, "a measurement of a cancelled watch was applied")
    }

    @Test("after a wipe that kept the playing file, deleting that file brings the section to nothing downloaded")
    func keptFileDeletedUpdatesTheSection() async {
        let rig = makeRig()
        defer { rig.cleanUp() }
        rig.download(id(1))
        await rig.service.waitUntilIdle()
        let box = ServiceBox()
        box.service = rig.service
        let model = makeModel(rig, box: box, debounce: .milliseconds(20))
        let watching = Task { @MainActor in await model.watch() }
        defer { watching.cancel() }
        #expect(await rig.eventually { model.songs == 1 && model.usage != nil })
        rig.service.noteLocalPlayback(of: id(1))

        await model.removeAll()

        #expect(model.songs == 0)
        #expect(model.usage?.hasFiles == true, "the file kept for the player is still on the disk")
        #expect(model.canRemoveAll)

        rig.service.noteLocalPlayback(of: id(3))

        #expect(await rig.eventually { model.usage?.hasFiles == false })
        #expect(model.songs == 0 && model.collections == 0)
        #expect(model.summary == "Nothing downloaded")
        #expect(!model.canRemoveAll)
        #expect(model.sizeText == MusicDownloadSettingsText.sizeText(model.usage?.bytes))
        #expect(rig.folder.rootFiles == ["downloads.json"])
    }

    // MARK: - Remove all

    @Test("Remove all deletes everything through the service and the section reads empty afterwards")
    func removesThroughTheService() async {
        let rig = makeRig()
        defer { rig.cleanUp() }
        await fill(rig)
        let box = ServiceBox()
        box.service = rig.service
        let model = makeModel(rig, box: box)
        await model.refresh()
        #expect(model.canRemoveAll)

        await model.removeAll()

        #expect(!model.isRemoving)
        #expect(model.songs == 0 && model.collections == 0)
        #expect(model.summary == "Nothing downloaded")
        #expect(model.usage?.hasFiles == false)
        #expect(!model.canRemoveAll)
        #expect(model.lastWipe?.refused == false)
        #expect(rig.folder.rootFiles == ["downloads.json"])
        #expect(box.prepared == 0)
        #expect(rig.service.downloadedSongCount == 0)
    }

    @Test("with no service yet Remove all builds it first, then removes through it")
    func buildsTheServiceWhenNeeded() async {
        let rig = makeRig()
        defer { rig.cleanUp() }
        await fill(rig)
        let box = ServiceBox()
        box.waiting = rig.service
        let model = makeModel(rig, box: box)
        await model.refresh()
        #expect(model.songs == 3)

        await model.removeAll()

        #expect(box.prepared == 1)
        #expect(model.songs == 0 && model.collections == 0)
        #expect(rig.folder.rootFiles == ["downloads.json"])
    }

    @Test("with nothing to remove the button does nothing and builds nothing")
    func nothingToRemove() async {
        let rig = makeRig()
        defer { rig.cleanUp() }
        let box = ServiceBox()
        box.waiting = rig.service
        let model = makeModel(rig, box: box)
        await model.refresh()

        await model.removeAll()

        #expect(box.prepared == 0)
        #expect(model.lastWipe == nil)
    }

    @Test("files left behind with nothing listed can still be removed")
    func leftoverFilesCanBeRemoved() async throws {
        let rig = makeRig()
        defer { rig.cleanUp() }
        try rig.folder.write(Data("audio".utf8), to: rig.folder.audioURL("ZZZZZZZZZZZ"))
        try rig.folder.write(Data("marker".utf8), to: rig.folder.root.appendingPathComponent("downloads.json.missing"))
        let box = ServiceBox()
        box.service = rig.service
        let model = makeModel(rig, box: box)
        await model.refresh()
        #expect(model.summary == "Nothing downloaded")
        #expect(model.canRemoveAll)

        await model.removeAll()

        #expect(rig.folder.rootFiles == ["downloads.json"])
        #expect(!model.canRemoveAll)
    }

    @Test("while a removal runs the button is off, and pressing it again does nothing")
    func disabledWhileRemoving() async {
        let songs = WipeSongGate()
        let rig = makeRig(songs: songs)
        defer { rig.cleanUp() }
        let box = ServiceBox()
        box.service = rig.service
        rig.download(id(1))
        await rig.service.waitUntilIdle()
        songs.hold(id(2))
        rig.download(id(2))
        #expect(await rig.eventually { await rig.requestCount(for: id(2)) == 1 })
        let model = makeModel(rig, box: box)
        await model.refresh()
        #expect(model.canRemoveAll)

        #expect(model.removingText == nil)
        let removal = Task { @MainActor in await model.removeAll() }
        #expect(await rig.eventually { model.isRemoving })
        #expect(!model.canRemoveAll)
        #expect(model.removingText == "Removing")
        await model.removeAll()
        #expect(model.isRemoving, "the second press ended the first")
        await songs.gate.open()
        await removal.value

        #expect(!model.isRemoving)
        #expect(model.removingText == nil)
        #expect(model.songs == 0)
        #expect(rig.folder.rootFiles == ["downloads.json"])
    }

    @Test("a refused removal changes nothing and the section keeps what it showed")
    func refusedRemoval() async {
        let rig = makeRig(shaped: false)
        defer { rig.cleanUp() }
        rig.download(id(1))
        await rig.service.waitUntilIdle()
        let box = ServiceBox()
        box.service = rig.service
        let model = makeModel(rig, box: box)
        await model.refresh()

        await model.removeAll()

        #expect(model.lastWipe?.refused == true)
        #expect(!model.isRemoving)
        #expect(model.songs == 1)
        #expect(model.canRemoveAll)
        #expect(rig.folder.audioFiles == ["\(id(1)).m4a"])
        #expect(model.wipeCaption == MusicDownloadSettingsText.caption(for: model.lastWipe))
        #expect(model.wipeCaption?.text == "The Downloads folder is not where Deci expects it, so nothing was removed.")
        #expect(model.wipeCaption?.isFailure == false)
    }

    // MARK: - What a removal says

    @Test("nothing is said before a removal runs, or after one that removed everything")
    func noCaptionWhenAllWentWell() async {
        let rig = makeRig()
        defer { rig.cleanUp() }
        await fill(rig)
        let box = ServiceBox()
        box.service = rig.service
        let model = makeModel(rig, box: box)
        await model.refresh()
        #expect(model.wipeCaption == nil)

        await model.removeAll()

        #expect(model.lastWipe?.failed == 0)
        #expect(model.wipeCaption == nil)
    }

    @Test("a partial removal says how many items it could not remove, and the next run starts from a clean note")
    func partialRemovalCaption() async throws {
        let rig = makeRig()
        defer { rig.cleanUp() }
        rig.download(id(1))
        await rig.service.waitUntilIdle()
        try rig.folder.write(Data("stray".utf8), to: rig.folder.root.appendingPathComponent("stray.txt"))
        let box = ServiceBox()
        box.service = rig.service
        let model = makeModel(rig, box: box)
        await model.refresh()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: rig.folder.audioDirectory.path)
        defer { try? rig.folder.unlock(rig.folder.audioDirectory, isDirectory: true) }

        await model.removeAll()

        let failed = model.lastWipe?.failed ?? 0
        #expect(failed > 0)
        #expect(model.wipeCaption?.text == "Could not remove \(failed) \(failed == 1 ? "item" : "items").")
        #expect(model.wipeCaption?.isFailure == true)
        #expect(model.songs == 1)
        #expect(model.canRemoveAll)

        try rig.folder.unlock(rig.folder.audioDirectory, isDirectory: true)
        await model.removeAll()

        #expect(model.lastWipe?.failed == 0)
        #expect(model.wipeCaption == nil)
        #expect(rig.folder.rootFiles == ["downloads.json"])
    }

    @Test("a removal that could not even write the empty index says that nothing was removed")
    func indexFailureCaption() async throws {
        let rig = makeRig()
        defer { rig.cleanUp() }
        await fill(rig)
        let box = ServiceBox()
        box.service = rig.service
        let model = makeModel(rig, box: box)
        await model.refresh()
        try rig.folder.lock(rig.folder.root)
        defer { try? rig.folder.unlock(rig.folder.root, isDirectory: true) }

        await model.removeAll()

        try rig.folder.unlock(rig.folder.root, isDirectory: true)
        #expect(model.wipeCaption?.text.hasSuffix("Nothing was removed.") == true)
        #expect(model.wipeCaption?.text.hasPrefix("Could not remove ") == true)
        #expect(model.wipeCaption?.isFailure == true)
        #expect(model.songs == 3)
        #expect(rig.folder.audioFiles.count == 3)
    }

    @Test("a run that never reaches the service still clears the note of the one before")
    func lastWipeResetsEvenWithoutAService() async {
        let rig = makeRig(shaped: false)
        defer { rig.cleanUp() }
        rig.download(id(1))
        await rig.service.waitUntilIdle()
        let box = ServiceBox()
        box.service = rig.service
        let model = makeModel(rig, box: box)
        await model.refresh()
        await model.removeAll()
        #expect(model.lastWipe?.refused == true)
        #expect(model.wipeCaption != nil)

        box.service = nil
        await model.removeAll()

        #expect(box.prepared == 1)
        #expect(model.lastWipe == nil)
        #expect(model.wipeCaption == nil)
    }
}
