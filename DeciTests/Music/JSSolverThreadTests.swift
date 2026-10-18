// DeciTests/Music/JSSolverThreadTests.swift
// The dedicated solver thread: where jobs run, ordering, state lifetime, shutdown.

import Foundation
import os
import Testing
@testable import Deci

/// A thread-confined state that counts how many were made and how many were released.
nonisolated final class CountedState {
    static let made = OSAllocatedUnfairLock(initialState: 0)
    static let released = OSAllocatedUnfairLock(initialState: 0)

    let id: Int

    init() {
        id = Self.made.withLock { value in
            value += 1
            return value
        }
    }

    deinit { Self.released.withLock { $0 += 1 } }
}

nonisolated struct ProbeError: Error, Equatable {
    let message: String
}

@MainActor
@Suite("JSSolverThread", .serialized)
struct JSSolverThreadTests {

    @Test("Jobs run off the main thread, on a thread named for the solver, with a 16 MB stack")
    func runsOffMain() async throws {
        let thread = JSSolverThread<Int>(name: "com.abraham.Deci.test-solver", makeState: { 7 })
        defer { thread.shutdown() }
        let info = try await thread.run { _ in
            [Thread.isMainThread ? "main" : "other", Thread.current.name ?? "", "\(Thread.current.stackSize)"]
        }
        #expect(info == ["other", "com.abraham.Deci.test-solver", "\(16 * 1024 * 1024)"])
    }

    @Test("The state is created once and reused by later jobs")
    func stateCreatedOnce() async throws {
        let made = OSAllocatedUnfairLock(initialState: 0)
        let thread = JSSolverThread<[Int]>(name: "once", makeState: {
            made.withLock { $0 += 1 }
            return [Int]()
        })
        defer { thread.shutdown() }
        #expect(thread.hasState == false)
        _ = try await thread.run { _ in 1 }
        _ = try await thread.run { _ in 2 }
        _ = try await thread.run { _ in 3 }
        #expect(made.withLock { $0 } == 1)
        #expect(thread.hasState)
    }

    @Test("State is created on the solver thread, not the caller's")
    func stateCreatedOnThread() async throws {
        let onMain = OSAllocatedUnfairLock(initialState: true)
        let thread = JSSolverThread<Int>(name: "where", makeState: {
            onMain.withLock { $0 = Thread.isMainThread }
            return 0
        })
        defer { thread.shutdown() }
        _ = try await thread.run { _ in 0 }
        #expect(onMain.withLock { $0 } == false)
    }

    @Test("Jobs run one at a time, in the order they were submitted")
    func serialAndOrdered() async throws {
        let thread = JSSolverThread<Int>(name: "order", makeState: { 0 })
        defer { thread.shutdown() }
        let log = OSAllocatedUnfairLock(initialState: [Int]())
        let overlap = OSAllocatedUnfairLock(initialState: false)
        let active = OSAllocatedUnfairLock(initialState: 0)

        // Submit sequentially without awaiting each result, so the queue is what orders them.
        var tasks: [Task<Int, Error>] = []
        for index in 0..<20 {
            let task = Task { [thread] in
                try await thread.run { _ in
                    if active.withLock({ value in value += 1; return value }) > 1 { overlap.withLock { $0 = true } }
                    Thread.sleep(forTimeInterval: 0.002)
                    log.withLock { $0.append(index) }
                    active.withLock { $0 -= 1 }
                    return index
                }
            }
            tasks.append(task)
            // Let the task reach the queue before the next one starts.
            try await Task.sleep(for: .milliseconds(3))
        }
        for task in tasks { _ = try await task.value }
        #expect(overlap.withLock { $0 } == false)
        #expect(log.withLock { $0 } == Array(0..<20))
    }

    @Test("100 concurrent jobs all complete exactly once")
    func manyConcurrentJobs() async throws {
        let thread = JSSolverThread<Int>(name: "many", makeState: { 0 })
        defer { thread.shutdown() }
        let total = try await withThrowingTaskGroup(of: Int.self) { group -> Int in
            for index in 1...100 {
                group.addTask { try await thread.run { _ in index } }
            }
            var sum = 0
            for try await value in group { sum += value }
            return sum
        }
        #expect(total == 5050)
    }

    @Test("A job's thrown error comes back to its caller and later jobs still run")
    func errorPropagation() async throws {
        let thread = JSSolverThread<Int>(name: "errors", makeState: { 0 })
        defer { thread.shutdown() }
        await #expect(throws: ProbeError(message: "boom")) {
            try await thread.run { _ -> Int in throw ProbeError(message: "boom") }
        }
        #expect(try await thread.run { _ in 5 } == 5)
    }

    @Test("A failing makeState fails that job and is retried on the next one")
    func makeStateRetry() async throws {
        let attempts = OSAllocatedUnfairLock(initialState: 0)
        let thread = JSSolverThread<Int>(name: "retry", makeState: {
            let attempt = attempts.withLock { value in value += 1; return value }
            if attempt == 1 { throw ProbeError(message: "first attempt") }
            return 42
        })
        defer { thread.shutdown() }
        await #expect(throws: ProbeError(message: "first attempt")) {
            try await thread.run { state in state }
        }
        #expect(thread.hasState == false)
        #expect(try await thread.run { state in state } == 42)
        #expect(attempts.withLock { $0 } == 2)
    }

    @Test("After the idle timeout the state is released, and the next job builds a new one")
    func idleDropAndRecreate() async throws {
        let madeBefore = CountedState.made.withLock { $0 }
        let releasedBefore = CountedState.released.withLock { $0 }
        let thread = JSSolverThread<CountedState>(name: "idle", idleTimeout: 0.15, makeState: { CountedState() })
        defer { thread.shutdown() }

        let first = try await thread.run { $0.id }
        #expect(thread.hasState)
        #expect(await waitUntil { thread.hasState == false })
        #expect(await waitUntil { CountedState.released.withLock { $0 } == releasedBefore + 1 })

        let second = try await thread.run { $0.id }
        #expect(second != first)
        #expect(CountedState.made.withLock { $0 } == madeBefore + 2)
    }

    @Test("A busy thread does not idle out between quick jobs")
    func staysAliveWhileUsed() async throws {
        let made = OSAllocatedUnfairLock(initialState: 0)
        let thread = JSSolverThread<Int>(name: "busy", idleTimeout: 0.4, makeState: {
            made.withLock { $0 += 1 }
            return 0
        })
        defer { thread.shutdown() }
        for _ in 0..<5 {
            _ = try await thread.run { _ in 0 }
            try await Task.sleep(for: .milliseconds(80))
        }
        #expect(made.withLock { $0 } == 1)
    }

    @Test("Shutdown refuses new jobs")
    func runAfterShutdown() async {
        let thread = JSSolverThread<Int>(name: "shutdown", makeState: { 0 })
        thread.shutdown()
        await #expect(throws: JSSolverThread<Int>.ShutDown.self) {
            try await thread.run { _ in 1 }
        }
    }

    @Test("Shutdown after work releases the state")
    func shutdownReleasesState() async throws {
        let releasedBefore = CountedState.released.withLock { $0 }
        let thread = JSSolverThread<CountedState>(name: "release", makeState: { CountedState() })
        _ = try await thread.run { $0.id }
        thread.shutdown()
        #expect(await waitUntil { CountedState.released.withLock { $0 } == releasedBefore + 1 })
        #expect(thread.hasState == false)
    }

    @Test("Shutdown fails jobs that are still queued")
    func shutdownFailsQueued() async throws {
        let thread = JSSolverThread<Int>(name: "queued", makeState: { 0 })
        let started = OSAllocatedUnfairLock(initialState: false)
        let release = DispatchSemaphore(value: 0)

        let blocker = Task { [thread] in
            try await thread.run { _ -> Int in
                started.withLock { $0 = true }
                release.wait()
                return 1
            }
        }
        #expect(await waitUntil { started.withLock { $0 } })
        let queued = Task { [thread] in try await thread.run { _ in 2 } }
        try await Task.sleep(for: .milliseconds(50))

        thread.shutdown()
        release.signal()
        #expect(try await blocker.value == 1)
        await #expect(throws: JSSolverThread<Int>.ShutDown.self) { _ = try await queued.value }
    }

    /// Polls a condition for up to five seconds.
    private func waitUntil(_ condition: @Sendable () -> Bool) async -> Bool {
        for _ in 0..<500 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}
