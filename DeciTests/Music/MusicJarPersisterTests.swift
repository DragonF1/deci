// DeciTests/Music/MusicJarPersisterTests.swift
// When the cookie jar reaches the Keychain: a sign-in cookie change at once but at most once a minute,
// every other change only with that write or at quit, never on a timer of its own. Time is a hand-driven
// clock and scheduler; nothing here sleeps, and the threaded tests wait on semaphores, not on the clock.

import Foundation
import os
import Testing
@testable import Deci

/// The persister's keychain log lines, in order.
nonisolated final class PersisterEvents: Sendable {
    private let lines = OSAllocatedUnfairLock(initialState: [String]())

    func record(_ event: MusicJarPersister.Event) {
        lines.withLock { $0.append(event.rawValue) }
    }

    var all: [String] { lines.withLock { $0 } }
}

@MainActor
@Suite("MusicJarPersister")
struct MusicJarPersisterTests {

    private struct Rig {
        let store: MemorySecretStore
        let clock: MutableClock
        let scheduler: ManualWriteScheduler
        let events: PersisterEvents
        let persister: MusicJarPersister

        init(store: MemorySecretStore = MemorySecretStore()) {
            let clock = MutableClock()
            let events = PersisterEvents()
            let scheduler = ManualWriteScheduler(clock: clock)
            self.store = store
            self.clock = clock
            self.scheduler = scheduler
            self.events = events
            persister = MusicJarPersister(
                store: store,
                now: { clock.now },
                scheduler: scheduler,
                report: { events.record($0) }
            )
        }
    }

    private static let first = Data("jar-1".utf8)
    private static let second = Data("jar-2".utf8)
    private static let third = Data("jar-3".utf8)

    // MARK: - Sign-in cookie changes

    @Test("A sign-in cookie change is written at once")
    func signInChangeWritesAtOnce() {
        let rig = Rig()
        rig.persister.stage(Self.first, signInChanged: true)
        #expect(rig.store.saveCount == 1)
        #expect(rig.store.contents == Self.first)
        #expect(rig.events.all == ["keychain write (sign-in cookie changed)"])
        #expect(rig.scheduler.pendingCount == 0)
    }

    @Test("A second sign-in change inside a minute waits, and the newest snapshot goes out at the minute")
    func signInChangesCoalesce() {
        let rig = Rig()
        rig.persister.stage(Self.first, signInChanged: true)
        rig.scheduler.advance(by: 10)
        rig.persister.stage(Self.second, signInChanged: true)
        rig.scheduler.advance(by: 5)
        rig.persister.stage(Self.third, signInChanged: true)
        #expect(rig.store.saveCount == 1)
        #expect(rig.store.contents == Self.first)

        rig.scheduler.advance(by: 44)
        #expect(rig.store.saveCount == 1, "59 s after the first write")
        rig.scheduler.advance(by: 1)
        #expect(rig.store.saveCount == 2, "60 s after it")
        #expect(rig.store.contents == Self.third)
        #expect(rig.scheduler.pendingCount == 0)
        #expect(rig.events.all == ["keychain write (sign-in cookie changed)", "keychain write (sign-in cookie changed)"])
    }

    @Test("A timer that fires early, say after the clock was set back, still keeps the minute and waits again")
    func earlyTimerKeepsTheMinute() {
        let rig = Rig()
        rig.persister.stage(Self.first, signInChanged: true)
        rig.scheduler.advance(by: 10)
        rig.persister.stage(Self.second, signInChanged: true)

        rig.scheduler.fireEverything()
        #expect(rig.store.saveCount == 1, "10 s after the last write")
        #expect(rig.scheduler.pendingCount == 1, "waiting for the real deadline")

        rig.scheduler.advance(by: 50)
        #expect(rig.store.saveCount == 2)
        #expect(rig.store.contents == Self.second)
    }

    @Test("A sign-in change a minute after the last write goes out at once")
    func signInChangeAfterTheWindow() {
        let rig = Rig()
        rig.persister.stage(Self.first, signInChanged: true)
        rig.scheduler.advance(by: 60)
        rig.persister.stage(Self.second, signInChanged: true)
        #expect(rig.store.saveCount == 2)
        #expect(rig.store.contents == Self.second)
    }

    @Test("The minute counts from any write, a sign-in save included")
    func windowStartsAtEveryWrite() throws {
        let rig = Rig()
        try rig.persister.saveSignedIn(Self.first)
        rig.scheduler.advance(by: 20)
        rig.persister.stage(Self.second, signInChanged: true)
        #expect(rig.store.saveCount == 1)
        rig.scheduler.advance(by: 40)
        #expect(rig.store.saveCount == 2)
        #expect(rig.store.contents == Self.second)
    }

    @Test("Many threads reporting sign-in changes at one instant write once")
    func concurrentSignInChangesWriteOnce() {
        let rig = Rig()
        let persister = rig.persister
        DispatchQueue.concurrentPerform(iterations: 500) { index in
            persister.stage(Data("jar-\(index)".utf8), signInChanged: true)
        }
        #expect(rig.store.saveCount == 1, "one write for the whole burst, whichever thread got the item")

        // A change after the burst waits out the same minute and goes out as one write of the newest jar.
        let last = Data("last".utf8)
        persister.stage(last, signInChanged: true)
        #expect(rig.store.saveCount == 1)
        #expect(rig.scheduler.pendingCount == 1)
        rig.scheduler.advance(by: 60)
        #expect(rig.store.saveCount == 2)
        #expect(rig.store.contents == last)
    }

    // MARK: - Other changes

    @Test("Changes to other cookies write nothing and arm no timer")
    func otherChangesOnlyMarkDirty() {
        let rig = Rig()
        for index in 0..<10 {
            rig.persister.stage(Data("jar-\(index)".utf8), signInChanged: false)
        }
        #expect(rig.store.saveCount == 0)
        #expect(rig.store.contents == nil)
        #expect(rig.events.all.isEmpty)
        #expect(rig.scheduler.pendingCount == 0)
    }

    @Test("Dirty data is never written on a timer, however long the app runs")
    func dirtyDataWaitsForTheNextWriteOrQuit() {
        let rig = Rig()
        rig.persister.stage(Self.first, signInChanged: false)
        rig.scheduler.advance(by: 24 * 60 * 60)
        rig.scheduler.fireEverything()
        #expect(rig.store.saveCount == 0)
        #expect(rig.events.all.isEmpty)

        rig.persister.flushNow()
        #expect(rig.store.contents == Self.first)
    }

    @Test("Dirty data goes out with the next sign-in write")
    func dirtyDataRidesOnASignInWrite() {
        let rig = Rig()
        rig.persister.stage(Self.first, signInChanged: false)
        rig.persister.stage(Self.second, signInChanged: true)
        #expect(rig.store.saveCount == 1)
        #expect(rig.store.contents == Self.second)
        #expect(rig.scheduler.pendingCount == 0)

        rig.persister.flushNow()
        rig.scheduler.advance(by: 2 * 60 * 60)
        #expect(rig.store.saveCount == 1)
    }

    @Test("A dirty change after a sign-in write waits for the quit flush: no timer comes for it")
    func dirtyAfterAWrite() {
        let rig = Rig()
        rig.persister.stage(Self.first, signInChanged: true)
        rig.scheduler.advance(by: 5 * 60)
        rig.persister.stage(Self.second, signInChanged: false)
        #expect(rig.scheduler.pendingCount == 0)
        rig.scheduler.advance(by: 3 * 60 * 60)
        #expect(rig.store.saveCount == 1)

        rig.persister.flushNow()
        #expect(rig.store.saveCount == 2)
        #expect(rig.store.contents == Self.second)
    }

    @Test("A coalesced sign-in write that is already waiting also carries dirty data")
    func coalescedWriteCarriesDirtyData() {
        let rig = Rig()
        rig.persister.stage(Self.first, signInChanged: true)
        rig.persister.stage(Self.second, signInChanged: true)
        rig.persister.stage(Self.third, signInChanged: false)
        rig.scheduler.advance(by: 60)
        #expect(rig.store.saveCount == 2)
        #expect(rig.store.contents == Self.third)
        #expect(rig.scheduler.pendingCount == 0)
    }

    // MARK: - Quit flush

    @Test("flushNow writes dirty data once")
    func flushWritesDirtyOnce() {
        let rig = Rig()
        rig.persister.stage(Self.first, signInChanged: false)
        rig.persister.flushNow()
        #expect(rig.store.saveCount == 1)
        #expect(rig.store.contents == Self.first)
        #expect(rig.events.all == ["keychain write (quit flush)"])
        #expect(rig.scheduler.pendingCount == 0)

        rig.persister.flushNow()
        #expect(rig.store.saveCount == 1)
    }

    @Test("flushNow with nothing dirty writes nothing and logs nothing")
    func flushWithNothingDirty() {
        let rig = Rig()
        rig.persister.flushNow()
        #expect(rig.store.saveCount == 0)
        #expect(rig.events.all.isEmpty)
    }

    @Test("flushNow right after a sign-in write has nothing left to write")
    func flushAfterASignInWrite() {
        let rig = Rig()
        rig.persister.stage(Self.first, signInChanged: true)
        rig.persister.flushNow()
        #expect(rig.store.saveCount == 1)
    }

    @Test("flushNow also writes a sign-in change that was waiting out its minute")
    func flushWritesAWaitingSignInChange() {
        let rig = Rig()
        rig.persister.stage(Self.first, signInChanged: true)
        rig.persister.stage(Self.second, signInChanged: true)
        rig.persister.flushNow()
        #expect(rig.store.saveCount == 2)
        #expect(rig.store.contents == Self.second)
        #expect(rig.events.all.last == "keychain write (quit flush)")
        #expect(rig.scheduler.pendingCount == 0)
    }

    @Test("flushNow runs on the calling thread and is done when it returns")
    func flushIsSynchronous() async {
        let rig = Rig()
        rig.persister.stage(Self.first, signInChanged: false)
        let persister = rig.persister
        let store = rig.store
        let savedWhenItReturned = await Task.detached {
            persister.flushNow()
            return store.saveCount
        }.value
        #expect(savedWhenItReturned == 1)
    }

    // MARK: - Signed in

    @Test("saveSignedIn writes at once, even right after another write")
    func signedInWritesAtOnce() throws {
        let rig = Rig()
        rig.persister.stage(Self.first, signInChanged: true)
        try rig.persister.saveSignedIn(Self.second)
        #expect(rig.store.saveCount == 2)
        #expect(rig.store.contents == Self.second)
        #expect(rig.events.all == ["keychain write (sign-in cookie changed)", "keychain write (signed in)"])
    }

    @Test("saveSignedIn replaces anything staged: no later write brings the old snapshot back")
    func signedInDropsStagedData() throws {
        let rig = Rig()
        rig.persister.stage(Self.first, signInChanged: true)
        rig.persister.stage(Self.second, signInChanged: true)
        rig.persister.stage(Self.third, signInChanged: false)
        try rig.persister.saveSignedIn(Data("new-account".utf8))

        rig.persister.flushNow()
        rig.scheduler.advance(by: 3 * 60 * 60)
        #expect(rig.store.saveCount == 2)
        #expect(rig.store.contents == Data("new-account".utf8))
        #expect(rig.scheduler.pendingCount == 0)
    }

    @Test("A refused saveSignedIn throws and leaves what was staged for a later write")
    func signedInFailureKeepsStagedData() throws {
        let rig = Rig()
        rig.persister.stage(Self.first, signInChanged: false)
        rig.store.failSaves = true
        #expect(throws: KeychainSecretStore.KeychainError.self) { try rig.persister.saveSignedIn(Self.second) }
        rig.store.failSaves = false
        rig.persister.flushNow()
        #expect(rig.store.contents == Self.first)
    }

    // MARK: - Sign-out

    @Test("discard deletes the item and nothing staged or waiting can write it back")
    func discardDropsEverything() {
        let rig = Rig()
        rig.persister.stage(Self.first, signInChanged: true)
        rig.persister.stage(Self.second, signInChanged: true)
        rig.persister.stage(Self.third, signInChanged: false)
        rig.persister.discard()

        #expect(rig.store.deleteCount == 1)
        #expect(rig.store.contents == nil)
        #expect(rig.scheduler.pendingCount == 0)

        rig.persister.flushNow()
        rig.scheduler.advance(by: 3 * 60 * 60)
        #expect(rig.store.saveCount == 1, "only the write that happened before the sign-out")
        #expect(rig.store.contents == nil)
        #expect(rig.events.all.suffix(1) == ["keychain delete"])
    }

    @Test("A timer that had already started when discard ran still writes nothing")
    func discardBeatsAStartedTimer() {
        let rig = Rig()
        rig.persister.stage(Self.first, signInChanged: true)
        rig.persister.stage(Self.second, signInChanged: true)
        rig.persister.stage(Self.third, signInChanged: false)
        rig.persister.discard()
        rig.scheduler.fireEverything()

        #expect(rig.store.saveCount == 1)
        #expect(rig.store.contents == nil)
    }

    @Test("A timer left over from before a saveSignedIn writes nothing")
    func signedInBeatsAStartedTimer() throws {
        let rig = Rig()
        rig.persister.stage(Self.first, signInChanged: false)
        try rig.persister.saveSignedIn(Self.second)
        rig.scheduler.fireEverything()
        #expect(rig.store.saveCount == 1)
        #expect(rig.store.contents == Self.second)
    }

    @Test("After a discard the persister starts over: the next sign-in change writes at once")
    func discardThenStartOver() {
        let rig = Rig()
        rig.persister.stage(Self.first, signInChanged: true)
        rig.persister.discard()
        rig.persister.stage(Self.second, signInChanged: true)
        #expect(rig.store.saveCount == 2)
        #expect(rig.store.contents == Self.second)
    }

    // MARK: - Failures

    @Test("A refused write keeps the data and arms no retry timer")
    func failedWriteArmsNoTimer() {
        let rig = Rig()
        rig.store.failSaves = true
        rig.persister.stage(Self.first, signInChanged: true)
        #expect(rig.store.saveCount == 0)
        #expect(rig.events.all == ["keychain write failed"])
        #expect(rig.scheduler.pendingCount == 0)

        rig.store.failSaves = false
        rig.scheduler.advance(by: 3 * 60 * 60)
        rig.scheduler.fireEverything()
        #expect(rig.store.saveCount == 0, "no timer retries a refused write")
        #expect(rig.events.all == ["keychain write failed"])

        rig.persister.flushNow()
        #expect(rig.store.contents == Self.first, "the data was kept for the quit flush")
    }

    @Test("A refused coalesced write is not retried by a timer either")
    func failedCoalescedWriteArmsNoTimer() {
        let rig = Rig()
        rig.persister.stage(Self.first, signInChanged: true)
        rig.persister.stage(Self.second, signInChanged: true)
        rig.store.failSaves = true
        rig.scheduler.advance(by: 60)
        #expect(rig.events.all.suffix(1) == ["keychain write failed"])
        #expect(rig.scheduler.pendingCount == 0)

        rig.store.failSaves = false
        rig.scheduler.advance(by: 3 * 60 * 60)
        #expect(rig.store.saveCount == 1)
        #expect(rig.store.contents == Self.first)

        rig.persister.flushNow()
        #expect(rig.store.contents == Self.second)
    }

    @Test("A refused write is retried by the next sign-in change after its minute, and at quit")
    func failedWriteRetriedByNextChangeAndQuit() {
        let rig = Rig()
        rig.store.failSaves = true
        rig.persister.stage(Self.first, signInChanged: true)
        rig.store.failSaves = false
        rig.scheduler.advance(by: 60)
        rig.persister.stage(Self.second, signInChanged: true)
        #expect(rig.store.contents == Self.second)

        rig.store.failSaves = true
        rig.persister.stage(Self.third, signInChanged: false)
        rig.store.failSaves = false
        rig.persister.flushNow()
        #expect(rig.store.contents == Self.third)
    }

    @Test("A sign-in change inside the minute after a refused write waits for the minute, then retries once")
    func failedWriteThenSignInChangeInsideTheMinute() {
        let rig = Rig()
        rig.store.failSaves = true
        rig.persister.stage(Self.first, signInChanged: true)
        rig.store.failSaves = false
        rig.scheduler.advance(by: 20)
        rig.persister.stage(Self.second, signInChanged: true)
        #expect(rig.store.saveCount == 0)
        #expect(rig.scheduler.pendingCount == 1)

        rig.scheduler.advance(by: 40)
        #expect(rig.store.saveCount == 1)
        #expect(rig.store.contents == Self.second)
    }

    // MARK: - Failed deletes

    @Test("A refused delete is logged as such, keeps the item, and the quit flush deletes it")
    func failedDeleteIsRetriedAtQuit() {
        let rig = Rig()
        rig.persister.stage(Self.first, signInChanged: true)
        rig.store.failDeletes = true
        rig.persister.discard()
        #expect(rig.store.deleteCount == 0)
        #expect(rig.store.contents == Self.first)
        #expect(rig.events.all.suffix(1) == ["keychain delete failed"])

        rig.store.failDeletes = false
        rig.persister.flushNow()
        #expect(rig.store.deleteCount == 1)
        #expect(rig.store.contents == nil)
        #expect(rig.events.all.suffix(1) == ["keychain delete"])

        rig.persister.flushNow()
        #expect(rig.store.deleteCount == 1, "settled: nothing owed any more")
    }

    @Test("The owed delete keeps failing visibly until it lands, and stays owed across flushes")
    func failedDeleteStaysOwed() {
        let rig = Rig()
        rig.store.failDeletes = true
        rig.persister.discard()
        rig.persister.flushNow()
        rig.persister.flushNow()
        #expect(rig.events.all == ["keychain delete failed", "keychain delete failed", "keychain delete failed"])

        rig.store.failDeletes = false
        rig.persister.flushNow()
        #expect(rig.events.all.suffix(1) == ["keychain delete"])
        #expect(rig.store.deleteCount == 1)
    }

    @Test("A refused delete still drops everything held back: the old jar is never written afterwards")
    func failedDeleteStillDropsHeldBackData() {
        let rig = Rig()
        rig.persister.stage(Self.first, signInChanged: true)
        rig.persister.stage(Self.second, signInChanged: true)
        rig.persister.stage(Self.third, signInChanged: false)
        rig.store.failDeletes = true
        rig.persister.discard()
        rig.store.failDeletes = false

        rig.scheduler.advance(by: 3 * 60 * 60)
        rig.persister.flushNow()
        #expect(rig.store.saveCount == 1, "only the write from before the sign-out")
        #expect(rig.store.contents == nil, "the flush deleted rather than wrote")
    }

    @Test("A later sign-in save replaces the item, which settles an owed delete without a second call")
    func saveSettlesAnOwedDelete() throws {
        let rig = Rig()
        rig.persister.stage(Self.first, signInChanged: true)
        rig.store.failDeletes = true
        rig.persister.discard()
        rig.store.failDeletes = false

        try rig.persister.saveSignedIn(Self.second)
        rig.persister.flushNow()
        #expect(rig.store.deleteCount == 0)
        #expect(rig.store.contents == Self.second, "the new jar survives the quit flush")
    }

    @Test("A sign-in change saved after a refused delete also settles it")
    func stagedWriteSettlesAnOwedDelete() {
        let rig = Rig()
        rig.store.failDeletes = true
        rig.persister.discard()
        rig.store.failDeletes = false

        rig.persister.stage(Self.first, signInChanged: true)
        rig.persister.flushNow()
        #expect(rig.store.deleteCount == 0)
        #expect(rig.store.contents == Self.first)
    }

    // MARK: - A write in flight on another thread

    /// A persister over a store that can hold a save at a gate, with the hand-driven clock and scheduler.
    private nonisolated struct GatedRig {
        let store = BlockingSecretStore()
        let clock = MutableClock()
        let scheduler: ManualWriteScheduler
        let events = PersisterEvents()
        let persister: MusicJarPersister

        init() {
            let (store, clock, events) = (self.store, self.clock, self.events)
            scheduler = ManualWriteScheduler(clock: clock)
            persister = MusicJarPersister(
                store: store,
                now: { clock.now },
                scheduler: scheduler,
                report: { events.record($0) }
            )
        }

        /// Runs `work` on a background thread; the returned semaphore is signalled when it returns.
        func background(_ work: @escaping @Sendable () -> Void) -> DispatchSemaphore {
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                work()
                done.signal()
            }
            return done
        }
    }

    @Test("flushNow does not wait behind a write that is already in flight, and never writes it twice")
    func flushSkipsAnInFlightWrite() {
        let rig = GatedRig()
        let persister = rig.persister
        let (first, second) = (Self.first, Self.second)
        rig.persister.stage(first, signInChanged: false)
        let writer = rig.background { persister.stage(second, signInChanged: true) }
        #expect(rig.store.waitUntilSaving(), "the sign-in write is inside the store call")

        // The quit flush comes while the write sits behind the gate, like a Keychain prompt.
        let flush = rig.background { persister.flushNow() }
        let flushReturned = flush.wait(timeout: .now() + 5) == .success
        rig.store.finishOneSave()
        #expect(flushReturned, "the quit flush returned while the write was still in flight")
        #expect(writer.wait(timeout: .now() + 5) == .success)

        #expect(rig.store.saveCount == 1, "the write in flight already carried the newest jar")
        #expect(rig.store.contents == second)
        #expect(rig.events.all == ["keychain write (sign-in cookie changed)"])
    }

    @Test("Once the write in flight is done, flushNow writes whatever was staged since")
    func flushWritesAfterTheInFlightWriteEnds() {
        let rig = GatedRig()
        let persister = rig.persister
        let first = Self.first
        let writer = rig.background { persister.stage(first, signInChanged: true) }
        #expect(rig.store.waitUntilSaving())
        rig.store.finishOneSave()
        #expect(writer.wait(timeout: .now() + 5) == .success)

        rig.persister.stage(Self.second, signInChanged: false)
        rig.store.finishOneSave()
        rig.persister.flushNow()
        #expect(rig.store.saveCount == 2)
        #expect(rig.store.contents == Self.second)
    }

    @Test("A sign-in change that finds a write in flight does not block, and its jar goes out at the minute")
    func skippedChangeIsNotLost() {
        let rig = GatedRig()
        let persister = rig.persister
        let (first, second) = (Self.first, Self.second)
        let writer = rig.background { persister.stage(first, signInChanged: true) }
        #expect(rig.store.waitUntilSaving())

        let skipped = rig.background { persister.stage(second, signInChanged: true) }
        #expect(skipped.wait(timeout: .now() + 5) == .success, "the second change returned at once")
        rig.store.finishOneSave()
        #expect(writer.wait(timeout: .now() + 5) == .success)
        #expect(rig.store.contents == first)

        // The writer armed the wake-up for what the second change left behind.
        #expect(rig.scheduler.pendingCount == 1)
        rig.store.finishOneSave()
        rig.scheduler.advance(by: 60)
        #expect(rig.store.contents == second)
        #expect(rig.store.saveCount == 2)
    }

    @Test("A sign-out that comes during a write in flight waits for it, and the delete lands last")
    func discardWaitsForAnInFlightWrite() {
        let rig = GatedRig()
        let persister = rig.persister
        let first = Self.first
        let writer = rig.background { persister.stage(first, signInChanged: true) }
        #expect(rig.store.waitUntilSaving())

        let signOut = rig.background { persister.discard() }
        usleep(50_000)
        rig.store.finishOneSave()
        #expect(writer.wait(timeout: .now() + 5) == .success)
        #expect(signOut.wait(timeout: .now() + 5) == .success)

        #expect(rig.store.contents == nil, "the write did not land after the delete")
        #expect(rig.store.deleteCount == 1)
        rig.persister.flushNow()
        rig.scheduler.advance(by: 3 * 60 * 60)
        #expect(rig.store.contents == nil)
    }

    // MARK: - Threads against each other

    /// One call into the persister, with tickets taken just before and just after it.
    private nonisolated struct Call: Sendable {
        nonisolated enum Kind: Sendable { case stage, signedIn, discard }
        let kind: Kind
        let payload: Data?
        let began: Int
        let returned: Int
    }

    private nonisolated final class CallLog: Sendable {
        private let calls = OSAllocatedUnfairLock(initialState: [Call]())
        func add(_ call: Call) { calls.withLock { $0.append(call) } }
        var all: [Call] { calls.withLock { $0 } }
    }

    @Test("Stage, flush, discard and saveSignedIn from many threads never overlap on the item, and nothing is written back after a sign-out")
    func concurrentMixNeverResurrects() {
        let ticker = Ticker()
        let store = OrderedSecretStore(ticker: ticker)
        let clock = MutableClock()
        let scheduler = ManualWriteScheduler(clock: clock)
        let persister = MusicJarPersister(store: store, now: { clock.now }, scheduler: scheduler, report: { _ in })
        let log = CallLog()

        DispatchQueue.concurrentPerform(iterations: 3_000) { index in
            let payload = Data("jar-\(index)".utf8)
            let began = ticker.next()
            switch index % 6 {
            case 0, 1:
                persister.stage(payload, signInChanged: index % 2 == 0)
                log.add(Call(kind: .stage, payload: payload, began: began, returned: ticker.next()))
            case 2:
                persister.flushNow()
            case 3:
                persister.discard()
                log.add(Call(kind: .discard, payload: nil, began: began, returned: ticker.next()))
            case 4:
                try? persister.saveSignedIn(payload)
                log.add(Call(kind: .signedIn, payload: payload, began: began, returned: ticker.next()))
            default:
                scheduler.advance(by: 61)
            }
        }

        #expect(store.overlaps == 0, "two store calls never ran at once")

        // A write that lands after a sign-out has returned must come from a call that was still running when
        // that sign-out began; anything that had returned before it was dropped by it.
        let calls = log.all
        let discards = calls.filter { $0.kind == .discard }
        let payloadCalls = Dictionary(
            calls.compactMap { call in call.payload.map { ($0, call) } },
            uniquingKeysWith: { first, _ in first }
        )
        var resurrected = 0
        for landed in store.landed {
            guard case .save(let data) = landed.operation, let source = payloadCalls[data] else { continue }
            if discards.contains(where: { source.returned < $0.began && landed.tick > $0.returned }) { resurrected += 1 }
        }
        #expect(resurrected == 0, "saves that came back after a sign-out they predate")

        // The sign-out that ends the run leaves the item deleted whatever else happens afterwards.
        persister.stage(Data("late".utf8), signInChanged: false)
        persister.discard()
        persister.flushNow()
        scheduler.fireEverything()
        scheduler.advance(by: 3 * 60 * 60)
        #expect(store.operations.last == .delete)
    }

    // MARK: - Reads and logging

    @Test("load passes the stored bytes through and logs a read")
    func loadLogsARead() {
        let rig = Rig(store: MemorySecretStore(data: Self.first))
        #expect(rig.persister.load() == Self.first)
        #expect(rig.events.all == ["keychain read"])
        #expect(rig.store.loadCount == 1)
    }

    @Test("The log lines are fixed text: no cookie value, jar bytes or account data in any of them")
    func logLinesAreFixedText() throws {
        let secret = "SAPISID=hunter2-secret"
        let jar = Data(secret.utf8)
        let rig = Rig(store: MemorySecretStore(data: jar))
        _ = rig.persister.load()
        rig.persister.stage(jar, signInChanged: true)
        rig.persister.stage(jar, signInChanged: false)
        rig.persister.flushNow()
        rig.scheduler.advance(by: 60 * 60)
        try rig.persister.saveSignedIn(jar)
        rig.scheduler.advance(by: 60)
        rig.store.failSaves = true
        rig.persister.stage(jar, signInChanged: true)
        rig.store.failSaves = false
        rig.store.failDeletes = true
        rig.persister.discard()
        rig.store.failDeletes = false
        rig.persister.flushNow()

        let allowed: Set<String> = [
            "keychain read",
            "keychain write (sign-in cookie changed)",
            "keychain write (quit flush)",
            "keychain write (signed in)",
            "keychain delete",
            "keychain delete failed",
            "keychain write failed",
        ]
        let lines = rig.events.all
        #expect(lines.count >= 7)
        #expect(lines.allSatisfy { allowed.contains($0) })
        #expect(lines.allSatisfy { !$0.contains("hunter2") })
        #expect(Set(lines) == allowed)
    }
}

@Suite("DispatchWriteScheduler")
struct DispatchWriteSchedulerTests {
    @Test("Runs the work once after the delay")
    func runsTheWork() {
        let ran = DispatchSemaphore(value: 0)
        _ = DispatchWriteScheduler().schedule(after: 0) { ran.signal() }
        #expect(ran.wait(timeout: .now() + 5) == .success)
    }

    @Test("Cancelling before the delay passes keeps the work from running")
    func cancelStopsTheWork() {
        let ran = DispatchSemaphore(value: 0)
        let cancel = DispatchWriteScheduler().schedule(after: 0.2) { ran.signal() }
        cancel()
        #expect(ran.wait(timeout: .now() + 0.5) == .timedOut)
    }
}
