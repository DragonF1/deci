// DeciTests/Music/MusicConnectivityTests.swift
// Whether the Music tab can reach the network: only a path the system calls satisfied is online, the flag is what views
// and services read, and the seam a test drives (`update`) tells every observer once per change. The real
// NWPathMonitor behind `live()` is checked by hand.

import Foundation
import Network
import Observation
import os
import Testing
@testable import Deci

@MainActor
private final class OnlineLog {
    private(set) var values: [Bool] = []

    func note(_ online: Bool) { values.append(online) }
}

@MainActor
@Suite("MusicConnectivity")
struct MusicConnectivityTests {
    @Test("only a satisfied path is online")
    func statuses() {
        #expect(MusicConnectivity.isOnline(status: .satisfied))
        #expect(!MusicConnectivity.isOnline(status: .unsatisfied))
        #expect(!MusicConnectivity.isOnline(status: .requiresConnection))
    }

    @Test("it starts online unless told it is not")
    func startsOnline() {
        #expect(MusicConnectivity().isOnline)
        #expect(!MusicConnectivity(isOnline: false).isOnline)
    }

    @Test("update flips the flag and tells every observer, once per change")
    func updateTellsObservers() {
        let connectivity = MusicConnectivity()
        let first = OnlineLog(), second = OnlineLog()
        connectivity.observe { first.note($0) }
        connectivity.observe { second.note($0) }

        connectivity.update(isOnline: false)
        #expect(!connectivity.isOnline)
        connectivity.update(isOnline: false)
        connectivity.update(isOnline: true)
        connectivity.update(isOnline: true)

        #expect(connectivity.isOnline)
        #expect(first.values == [false, true])
        #expect(second.values == [false, true])
    }

    @Test("the flag is observable, so a view reading it redraws when the network goes")
    func flagIsObservable() {
        let connectivity = MusicConnectivity()
        let fired = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking { _ = connectivity.isOnline } onChange: { fired.withLock { $0 = true } }

        connectivity.update(isOnline: false)

        #expect(fired.withLock { $0 })
    }

    // MARK: - The first report

    @Test("a flag built by hand counts as reported, and live() waits for the system's first word")
    func reportedStates() {
        #expect(MusicConnectivity().hasReported)
        #expect(MusicConnectivity(isOnline: false).hasReported)
        #expect(!MusicConnectivity(isOnline: true, reported: false).hasReported)
    }

    @Test("the first report that repeats the starting flag changes nothing, and still counts as the first word")
    func firstReportSameAsFlag() {
        let connectivity = MusicConnectivity(isOnline: true, reported: false)
        let changes = OnlineLog(), firsts = OnlineLog()
        connectivity.observe { changes.note($0) }
        connectivity.observeFirstReport { firsts.note($0) }

        connectivity.report(isOnline: true)

        #expect(connectivity.hasReported)
        #expect(connectivity.isOnline)
        #expect(changes.values.isEmpty)
        #expect(firsts.values == [true])
    }

    @Test("a first report of no network flips the flag, tells the change observers, then the first-report ones")
    func firstReportOffline() {
        let connectivity = MusicConnectivity(isOnline: true, reported: false)
        let order = OnlineOrder()
        connectivity.observe { order.note("change \($0)") }
        connectivity.observeFirstReport { order.note("first \($0)") }

        connectivity.report(isOnline: false)

        #expect(!connectivity.isOnline)
        #expect(order.lines == ["change false", "first false"])
    }

    @Test("the first-report observers are told once, whatever follows")
    func firstReportOnce() {
        let connectivity = MusicConnectivity(isOnline: true, reported: false)
        let firsts = OnlineLog()
        connectivity.observeFirstReport { firsts.note($0) }

        connectivity.report(isOnline: false)
        connectivity.report(isOnline: true)
        connectivity.report(isOnline: false)

        #expect(firsts.values == [false])
        #expect(!connectivity.isOnline)
    }

    @Test("a flag that was reported already never tells a first-report observer")
    func reportedFlagTellsNoFirst() {
        let connectivity = MusicConnectivity()
        let firsts = OnlineLog()
        connectivity.observeFirstReport { firsts.note($0) }

        connectivity.report(isOnline: false)

        #expect(firsts.values.isEmpty)
    }

    @Test("the system's statuses map the same way as the online test: only satisfied is online")
    func reportByStatus() {
        let satisfied = MusicConnectivity(isOnline: false, reported: false)
        satisfied.report(status: .satisfied)
        #expect(satisfied.isOnline)
        #expect(satisfied.hasReported)

        let unsatisfied = MusicConnectivity(isOnline: true, reported: false)
        unsatisfied.report(status: .unsatisfied)
        #expect(!unsatisfied.isOnline)

        let needsConnection = MusicConnectivity(isOnline: true, reported: false)
        needsConnection.report(status: .requiresConnection)
        #expect(!needsConnection.isOnline)
    }

    @Test("seeding from the monitor's current path trusts a satisfied path, and ignores any other as not yet known")
    func seeding() {
        let known = MusicConnectivity(isOnline: true, reported: false)
        known.seed(status: .satisfied)
        #expect(known.hasReported)
        #expect(known.isOnline)

        // Before its first update the monitor's current path reads unsatisfied or requiresConnection whatever the network is.
        let unknown = MusicConnectivity(isOnline: true, reported: false)
        unknown.seed(status: .unsatisfied)
        unknown.seed(status: .requiresConnection)
        #expect(!unknown.hasReported)
        #expect(unknown.isOnline)
    }

    @Test("waiting for the first report returns at once when it came, and when it comes otherwise")
    func waitingForTheFirstReport() async {
        let reported = MusicConnectivity()
        await reported.firstReport()

        let connectivity = MusicConnectivity(isOnline: true, reported: false)
        let finished = OnlineLog()
        let waiter = Task {
            await connectivity.firstReport()
            finished.note(connectivity.isOnline)
        }
        for _ in 0..<400 where connectivity.reportWaiters == 0 { await Task.yield() }
        #expect(connectivity.reportWaiters == 1)
        #expect(finished.values.isEmpty)

        connectivity.report(isOnline: false)
        await waiter.value

        #expect(finished.values == [false])
        #expect(connectivity.reportWaiters == 0)
    }

    // MARK: - Which errors are the network

    @Test("the errors that mean the network is down or cannot be reached")
    func networkFailures() {
        let network: [URLError.Code] = [.notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .timedOut, .dataNotAllowed]
        for code in network { #expect(MusicConnectivity.isNetworkFailure(URLError(code)), "\(code)") }
        for code in [URLError.Code.badServerResponse, .cancelled, .badURL] {
            #expect(!MusicConnectivity.isNetworkFailure(URLError(code)), "\(code)")
        }
        #expect(!MusicConnectivity.isNetworkFailure(MusicError.signedOut))
        #expect(!MusicConnectivity.isNetworkFailure(MusicError.http(500)))
        #expect(!MusicConnectivity.isNetworkFailure(CancellationError()))
    }
}

@MainActor
private final class OnlineOrder {
    private(set) var lines: [String] = []

    func note(_ line: String) { lines.append(line) }
}
