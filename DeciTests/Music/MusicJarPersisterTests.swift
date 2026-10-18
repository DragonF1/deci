// DeciTests/Music/MusicJarPersisterTests.swift
// When the cookie jar reaches the Keychain: a sign-in cookie change at once but at most once a minute,
// every other change only with that write, every 30 minutes, or at quit. Time is a hand-driven clock
// and scheduler; nothing here sleeps.

import Foundation
import os
import Testing
@testable import Deci

/// The persister's keychain log lines, in order.
nonisolated final class PersisterEvents: @unchecked Sendable {
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
        #expect(rig.store.saveCount == 1)
        #expect(rig.scheduler.pendingCount == 1)
        rig.scheduler.advance(by: 60)
        #expect(rig.store.saveCount == 2)
    }

    // MARK: - Other changes

    @Test("Changes to other cookies write nothing and arm one timer")
    func otherChangesOnlyMarkDirty() {
        let rig = Rig()
        for index in 0..<10 {
            rig.persister.stage(Data("jar-\(index)".utf8), signInChanged: false)
        }
        #expect(rig.store.saveCount == 0)
        #expect(rig.store.contents == nil)
        #expect(rig.events.all.isEmpty)
        #expect(rig.scheduler.pendingCount == 1)
    }

    @Test("Dirty data is written 30 minutes after it first went dirty")
    func dirtyDataIsWrittenPeriodically() {
        let rig = Rig()
        rig.persister.stage(Self.first, signInChanged: false)
        rig.scheduler.advance(by: 30 * 60 - 1)
        #expect(rig.store.saveCount == 0)
        rig.scheduler.advance(by: 1)
        #expect(rig.store.saveCount == 1)
        #expect(rig.store.contents == Self.first)
        #expect(rig.events.all == ["keychain write (periodic)"])

        rig.scheduler.advance(by: 3 * 60 * 60)
        #expect(rig.store.saveCount == 1, "clean data is not written again")
    }

    @Test("More changes do not push the periodic write back, and it carries the newest snapshot")
    func periodicWriteDoesNotSlide() {
        let rig = Rig()
        rig.persister.stage(Self.first, signInChanged: false)
        rig.scheduler.advance(by: 20 * 60)
        rig.persister.stage(Self.second, signInChanged: false)
        rig.scheduler.advance(by: 10 * 60)
        #expect(rig.store.saveCount == 1)
        #expect(rig.store.contents == Self.second)
    }

    @Test("Dirty data goes out with the next sign-in write, and the periodic timer is dropped")
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

    @Test("A dirty change after a sign-in write waits for its own 30 minutes")
    func dirtyAfterAWrite() {
        let rig = Rig()
        rig.persister.stage(Self.first, signInChanged: true)
        rig.scheduler.advance(by: 5 * 60)
        rig.persister.stage(Self.second, signInChanged: false)
        rig.scheduler.advance(by: 29 * 60)
        #expect(rig.store.saveCount == 1)
        rig.scheduler.advance(by: 60)
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

    @Test("discard deletes the item and nothing staged, waiting or periodic can write it back")
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

    @Test("A refused write keeps the data and retries at the periodic mark, not every response")
    func failedWriteRetriesLater() {
        let rig = Rig()
        rig.store.failSaves = true
        rig.persister.stage(Self.first, signInChanged: true)
        #expect(rig.store.saveCount == 0)
        #expect(rig.events.all == ["keychain write failed"])

        rig.store.failSaves = false
        rig.scheduler.advance(by: 10 * 60)
        #expect(rig.store.saveCount == 0, "no retry on a timer inside the periodic window")
        rig.scheduler.advance(by: 20 * 60)
        #expect(rig.store.saveCount == 1)
        #expect(rig.store.contents == Self.first)
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
        rig.persister.stage(jar, signInChanged: false)
        rig.scheduler.advance(by: 60 * 60)
        try rig.persister.saveSignedIn(jar)
        rig.persister.discard()

        let allowed: Set<String> = [
            "keychain read",
            "keychain write (sign-in cookie changed)",
            "keychain write (quit flush)",
            "keychain write (periodic)",
            "keychain write (signed in)",
            "keychain delete",
            "keychain write failed",
        ]
        let lines = rig.events.all
        #expect(lines.count >= 6)
        #expect(lines.allSatisfy { allowed.contains($0) })
        #expect(lines.allSatisfy { !$0.contains("hunter2") })
        #expect(Set(lines) == allowed.subtracting(["keychain write failed"]))
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
