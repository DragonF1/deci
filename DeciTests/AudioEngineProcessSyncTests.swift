// DeciTests/AudioEngineProcessSyncTests.swift
//
// A tap is created around the app's process objects at that moment. When the app
// later spawns another audio-producing helper (a new Chrome tab process), the engine
// must rebuild the tap around the grown list, or that helper plays unprocessed.

import Testing
import Foundation
import AppKit
import AudioToolbox
@testable import Deci

private struct RebuildFailure: Error {}

@Suite("AudioEngine: taps follow new helper processes", .serialized)
@MainActor
struct AudioEngineProcessSyncTests {

    // MARK: Growth

    @Test("Process set grows: updateProcesses is called once with the new IDs after the debounce")
    func growTriggersOneRebuildAfterDebounce() async throws {
        let h = EngineHarness()
        let tap = h.launch(h.makeApp(ids: [10, 20]))

        h.publish([h.makeApp(ids: [10, 20, 30])])

        #expect(tap.updateProcessesCalls.isEmpty, "the rebuild must wait for the debounce")
        let called = await waitUntil { tap.updateProcessesCalls.count == 1 }
        #expect(called)
        await h.settleProcessRebuilds()
        #expect(tap.updateProcessesCalls == [[10, 20, 30]])
    }

    @Test("The rebuilt app keeps its identity (pid, name, bundle ID)")
    func rebuiltAppKeepsIdentity() async throws {
        let h = EngineHarness()
        let tap = h.launch(h.makeApp(pid: 777, ids: [10], bundleID: "com.brave.Browser"))

        h.publish([h.makeApp(pid: 777, ids: [10, 11], bundleID: "com.brave.Browser")])

        let called = await waitUntil { tap.updateProcessesCalls.count == 1 }
        #expect(called)
        #expect(tap.app.id == 777)
        #expect(tap.app.bundleID == "com.brave.Browser")
        #expect(tap.app.name == "Chrome")
    }

    @Test("Replacing one helper with another (same count, different ID) rebuilds")
    func swappedHelperRebuilds() async throws {
        let h = EngineHarness()
        let tap = h.launch(h.makeApp(ids: [10, 20]))
        h.probes.liveObjectIDs.remove(20)

        h.publish([h.makeApp(ids: [10, 40])])

        let called = await waitUntil { tap.updateProcessesCalls.count == 1 }
        #expect(called)
        #expect(tap.updateProcessesCalls == [[10, 40]])
    }

    // MARK: No rebuild

    @Test("Shrink-only: updateProcesses is never called")
    func shrinkNeverRebuilds() async throws {
        let h = EngineHarness()
        let tap = h.launch(h.makeApp(ids: [10, 20, 30]))

        h.publish([h.makeApp(ids: [10, 20])])
        await h.settleProcessRebuilds()

        #expect(tap.updateProcessesCalls.isEmpty)
    }

    @Test("A reordered but identical ID set is not a change")
    func reorderIsNotAChange() async throws {
        let h = EngineHarness()
        let tap = h.launch(h.makeApp(ids: [10, 20, 30]))

        h.publish([h.makeApp(ids: [30, 10, 20])])
        await h.settleProcessRebuilds()

        #expect(tap.updateProcessesCalls.isEmpty)
    }

    @Test("A growth that reverts before the debounce fires does not rebuild")
    func revertedGrowthDoesNotRebuild() async throws {
        let h = EngineHarness()
        let tap = h.launch(h.makeApp(ids: [10, 20]))

        h.publish([h.makeApp(ids: [10, 20, 30])])
        h.publish([h.makeApp(ids: [10, 20])])
        await h.settleProcessRebuilds()

        #expect(tap.updateProcessesCalls.isEmpty)
    }

    @Test("A paused app (absent from the monitor list) is not rebuilt")
    func pausedAppIsNotRebuilt() async throws {
        let h = EngineHarness()
        let tap = h.launch(h.makeApp(ids: [10, 20]))

        h.publish([])
        await h.settleProcessRebuilds()

        #expect(tap.updateProcessesCalls.isEmpty)
    }

    @Test("An app with no tap yet is not rebuilt (it is created with the full list instead)")
    func appWithoutTapIsLeftToCreation() async throws {
        let h = EngineHarness()
        let app = h.makeApp(ids: [10, 20, 30])

        h.launchAll([app])

        let tap = try #require(h.tap(for: app.id))
        #expect(tap.app.processObjectIDs == [10, 20, 30])
        await h.settleProcessRebuilds()
        #expect(tap.updateProcessesCalls.isEmpty)
    }

    // MARK: Debounce and coalescing

    @Test("Three quick changes produce one rebuild with the latest list")
    func quickChangesCollapseToOneRebuild() async throws {
        let h = EngineHarness()
        let tap = h.launch(h.makeApp(ids: [10]))

        h.publish([h.makeApp(ids: [10, 20])])
        h.publish([h.makeApp(ids: [10, 20, 30])])
        h.publish([h.makeApp(ids: [10, 20, 30, 40])])

        let called = await waitUntil { !tap.updateProcessesCalls.isEmpty }
        #expect(called)
        await h.settleProcessRebuilds()
        #expect(tap.updateProcessesCalls == [[10, 20, 30, 40]])
    }

    @Test("Changes during a rebuild coalesce into exactly one rerun with the latest list")
    func changesDuringRebuildCoalesce() async throws {
        let h = EngineHarness()
        let tap = h.launch(h.makeApp(ids: [10]))
        tap.updateProcessesDelay = .milliseconds(200)

        h.publish([h.makeApp(ids: [10, 20])])
        let started = await waitUntil { tap.updateProcessesCalls.count == 1 }
        #expect(started)

        // Two more changes land while that rebuild is still running.
        h.publish([h.makeApp(ids: [10, 20, 30])])
        h.publish([h.makeApp(ids: [10, 20, 30, 40])])

        let rerun = await waitUntil { tap.updateProcessesCalls.count == 2 }
        #expect(rerun)
        try await Task.sleep(for: .milliseconds(500))
        await h.settleProcessRebuilds()
        #expect(tap.updateProcessesCalls == [[10, 20], [10, 20, 30, 40]])
    }

    @Test("A change during a rebuild that the rebuild already covers does not trigger a rerun")
    func coveredChangeDuringRebuildIsNotRerun() async throws {
        let h = EngineHarness()
        let tap = h.launch(h.makeApp(ids: [10]))
        tap.updateProcessesDelay = .milliseconds(150)

        h.publish([h.makeApp(ids: [10, 20])])
        let started = await waitUntil { tap.updateProcessesCalls.count == 1 }
        #expect(started)

        // Same list again: the tap already adopted it.
        h.publish([h.makeApp(ids: [10, 20])])
        try await Task.sleep(for: .milliseconds(500))
        await h.settleProcessRebuilds()

        #expect(tap.updateProcessesCalls == [[10, 20]])
    }

    @Test("Two apps debounce independently: each gets its own single rebuild")
    func appsRebuildIndependently() async throws {
        let h = EngineHarness()
        let a = h.makeApp(pid: 100, ids: [1, 2])
        let b = h.makeApp(pid: 200, ids: [5])
        h.launchAll([a, b])
        let tapA = try #require(h.tap(for: 100))
        let tapB = try #require(h.tap(for: 200))

        h.publish([h.makeApp(pid: 100, ids: [1, 2, 3]), h.makeApp(pid: 200, ids: [5, 6])])

        let both = await waitUntil { tapA.updateProcessesCalls.count == 1 && tapB.updateProcessesCalls.count == 1 }
        #expect(both)
        await h.settleProcessRebuilds()
        #expect(tapA.updateProcessesCalls == [[1, 2, 3]])
        #expect(tapB.updateProcessesCalls == [[5, 6]])
    }

    // MARK: Which old IDs survive

    @Test("Old IDs whose HAL object is gone are dropped; live ones are kept")
    func deadOldIDsDroppedLiveKept() async throws {
        let h = EngineHarness()
        let tap = h.launch(h.makeApp(ids: [10, 20, 30]))
        // 30 exited; 20 is a paused helper that still exists as a HAL object.
        h.probes.liveObjectIDs.remove(30)

        // The monitor now lists only 10 (running) plus a brand new helper 40.
        h.publish([h.makeApp(ids: [10, 40])])

        let called = await waitUntil { tap.updateProcessesCalls.count == 1 }
        #expect(called)
        #expect(tap.updateProcessesCalls == [[10, 20, 40]])
    }

    @Test("Rebuild list has no duplicates when an old ID is also current")
    func rebuildListHasNoDuplicates() async throws {
        let h = EngineHarness()
        let tap = h.launch(h.makeApp(ids: [10, 20]))

        h.publish([h.makeApp(ids: [10, 20, 30])])

        let called = await waitUntil { tap.updateProcessesCalls.count == 1 }
        #expect(called)
        #expect(tap.updateProcessesCalls == [[10, 20, 30]])
    }

    @Test("Retained old IDs do not cause a rebuild loop on the next unchanged refresh")
    func retainedIDsDoNotLoop() async throws {
        let h = EngineHarness()
        let tap = h.launch(h.makeApp(ids: [10, 20]))

        h.publish([h.makeApp(ids: [10, 30])])  // 20 paused (kept), 30 new
        let first = await waitUntil { tap.updateProcessesCalls.count == 1 }
        #expect(first)

        // Same monitor snapshot again: 20 is still absent from it but already in the tap.
        h.publish([h.makeApp(ids: [10, 30])])
        await h.settleProcessRebuilds()

        #expect(tap.updateProcessesCalls.count == 1)
    }

    // MARK: Cancellation and failure

    @Test("Tearing the tap down before the debounce fires cancels the pending rebuild")
    func teardownCancelsPendingRebuild() async throws {
        let h = EngineHarness(debounce: .milliseconds(150))
        let app = h.makeApp(ids: [10, 20])
        let tap = h.launch(app)

        h.publish([h.makeApp(ids: [10, 20, 30])])
        h.engine.ignoreApp(app)   // removes and invalidates the tap
        try await Task.sleep(for: .milliseconds(500))

        #expect(tap.wasInvalidated)
        #expect(tap.updateProcessesCalls.isEmpty)
    }

    @Test("Tearing the tap down mid-rebuild cancels the in-flight rebuild and queues no rerun")
    func teardownCancelsInFlightRebuild() async throws {
        let h = EngineHarness()
        let app = h.makeApp(ids: [10])
        let tap = h.launch(app)
        tap.updateProcessesDelay = .seconds(5)

        h.publish([h.makeApp(ids: [10, 20])])
        let started = await waitUntil { tap.updateProcessesCalls.count == 1 }
        #expect(started)
        // A second change is queued behind the running rebuild.
        h.publish([h.makeApp(ids: [10, 20, 30])])

        h.engine.ignoreApp(app)

        let cancelled = await waitUntil { tap.updateProcessesCancelCount == 1 }
        #expect(cancelled, "the in-flight rebuild must be cancelled, not left running for seconds")
        await h.settleProcessRebuilds()
        #expect(tap.updateProcessesCalls.count == 1, "no coalesced rerun after teardown")
    }

    @Test("engine.stop() cancels pending rebuilds")
    func stopCancelsPendingRebuilds() async throws {
        let h = EngineHarness(debounce: .milliseconds(150))
        let tap = h.launch(h.makeApp(ids: [10]))

        h.publish([h.makeApp(ids: [10, 20])])
        h.engine.stop()
        try await Task.sleep(for: .milliseconds(500))

        #expect(tap.updateProcessesCalls.isEmpty)
    }

    @Test("A failed rebuild is logged and does not wedge later rebuilds")
    func failedRebuildDoesNotWedge() async throws {
        let h = EngineHarness()
        let tap = h.launch(h.makeApp(ids: [10]))
        tap.updateProcessesError = RebuildFailure()

        h.publish([h.makeApp(ids: [10, 20])])
        let first = await waitUntil { tap.updateProcessesCalls.count == 1 }
        #expect(first)
        try await Task.sleep(for: h.debounce * 2)

        tap.updateProcessesError = nil
        h.publish([h.makeApp(ids: [10, 20, 30])])
        let second = await waitUntil { tap.updateProcessesCalls.count == 2 }
        #expect(second)
        #expect(tap.updateProcessesCalls.last == [10, 20, 30])
    }

    @Test("A list that failed to rebuild is not retried on every later app change")
    func failedListIsNotRetried() async throws {
        let h = EngineHarness()
        let tap = h.launch(h.makeApp(ids: [10]))
        tap.updateProcessesError = RebuildFailure()

        h.publish([h.makeApp(ids: [10, 20])])
        let first = await waitUntil { tap.updateProcessesCalls.count == 1 }
        #expect(first)
        await h.settleProcessRebuilds()
        #expect(tap.app.processObjectIDs == [10], "the failed rebuild rolled the list back")

        // Same grown list again (any app's change re-fires onAppsChanged): no second dip.
        h.publish([h.makeApp(ids: [10, 20])])
        await h.settleProcessRebuilds()
        #expect(tap.updateProcessesCalls.count == 1)

        // A different list is a new attempt.
        tap.updateProcessesError = nil
        h.publish([h.makeApp(ids: [10, 20, 30])])
        let second = await waitUntil { tap.updateProcessesCalls.count == 2 }
        #expect(second)
        #expect(tap.updateProcessesCalls.last == [10, 20, 30])
    }

    @Test("A failed rebuild keeps the tap alive (no teardown, no recreate)")
    func failedRebuildKeepsTap() async throws {
        let h = EngineHarness()
        let app = h.makeApp(ids: [10])
        let tap = h.launch(app)
        tap.updateProcessesError = RebuildFailure()

        h.publish([h.makeApp(ids: [10, 20])])
        let first = await waitUntil { tap.updateProcessesCalls.count == 1 }
        #expect(first)
        await h.settleProcessRebuilds()

        #expect(tap.wasInvalidated == false)
        #expect(h.probes.createdTaps.filter { $0.app.id == app.id }.count == 1, "no replacement tap for this app")
        #expect(h.engine.audioLevels[app.id] != nil)
    }
}
