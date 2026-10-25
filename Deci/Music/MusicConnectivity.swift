// Deci/Music/MusicConnectivity.swift
// Whether the Music tab can reach the network. One flag that views read (it is observable, so they redraw when the
// network goes) and a list of observers that services tell once per change: the download pump pauses, the search and
// the queue wait, and everything that was held back runs when the network returns. The real source is an NWPathMonitor;
// a test drives `update` (a change) or `report` (the system's word, the first of which is told apart) itself.

import Foundation
import Network
import Observation

@MainActor
@Observable
final class MusicConnectivity {
    /// True until the system says otherwise: the first path report arrives a moment after launch, and a flag that started
    /// offline would flash the offline screens for nothing.
    private(set) var isOnline: Bool

    /// The system has said, at least once, whether there is a network. Until then `isOnline` is a guess, and a load that
    /// fails for the network may only have started on a path that was already gone. A flag built by hand has been told.
    private(set) var hasReported: Bool

    @ObservationIgnored private var observers: [@MainActor (Bool) -> Void] = []
    @ObservationIgnored private var firstReportObservers: [@MainActor (Bool) -> Void] = []
    @ObservationIgnored private var reportContinuations: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var monitor: NWPathMonitor?

    /// How many callers wait in `firstReport()`. Read by the tests.
    var reportWaiters: Int { reportContinuations.count }

    init(isOnline: Bool = true, reported: Bool = true) {
        self.isOnline = isOnline
        hasReported = reported
    }

    /// Only a path the system calls satisfied is online. A path that needs a connection first (a dial-up or a VPN that is
    /// not up) is not: a request on it would fail.
    nonisolated static func isOnline(status: NWPath.Status) -> Bool {
        status == .satisfied
    }

    /// Whether `error` says the network is down or cannot be reached, as opposed to a server that answered badly.
    nonisolated static func isNetworkFailure(_ error: any Error) -> Bool {
        guard let failure = error as? URLError else { return false }
        switch failure.code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .timedOut, .dataNotAllowed: return true
        default: return false
        }
    }

    /// The device's own network, watched for as long as the app runs. It starts not yet reported: the first word of the
    /// system arrives a moment after launch (see `hasReported`).
    static func live() -> MusicConnectivity {
        let connectivity = MusicConnectivity(isOnline: true, reported: false)
        connectivity.startMonitoring()
        return connectivity
    }

    /// Sets the flag and, when it changed, tells every observer. A path report that repeats what is known tells nobody.
    func update(isOnline online: Bool) {
        guard online != isOnline else { return }
        isOnline = online
        for observer in observers { observer(online) }
    }

    /// The system's word on the network. The first one counts as the first even when it repeats the starting flag: the
    /// change observers are told if it changed anything, then the first-report observers and everyone waiting for it.
    func report(isOnline online: Bool) {
        let first = !hasReported
        hasReported = true
        update(isOnline: online)
        guard first else { return }
        let handlers = firstReportObservers
        firstReportObservers.removeAll()
        for handler in handlers { handler(online) }
        let waiting = reportContinuations
        reportContinuations.removeAll()
        for continuation in waiting { continuation.resume() }
    }

    func report(status: NWPath.Status) {
        report(isOnline: Self.isOnline(status: status))
    }

    /// The monitor's current path right after it started. A satisfied path is a report; any other is not yet known, since
    /// the path reads unsatisfied before the monitor's first update whatever the network is.
    func seed(status: NWPath.Status) {
        guard status == .satisfied else { return }
        report(isOnline: true)
    }

    /// `handler` is told, on the main actor, each time the network goes or returns. It is not told the state it was
    /// registered in.
    func observe(_ handler: @escaping @MainActor (Bool) -> Void) {
        observers.append(handler)
    }

    /// `handler` is told once, with what the first report said, after the change observers. Never told when the system
    /// has already reported (`hasReported`).
    func observeFirstReport(_ handler: @escaping @MainActor (Bool) -> Void) {
        guard !hasReported else { return }
        firstReportObservers.append(handler)
    }

    /// Returns at once when the system has reported, else when its first report comes.
    func firstReport() async {
        guard !hasReported else { return }
        await withCheckedContinuation { reportContinuations.append($0) }
    }

    private func startMonitoring() {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        self.monitor = monitor
        // Delivered on the main queue, so the reports reach the observers in the order the system made them (a task per
        // report could swap two).
        monitor.pathUpdateHandler = { [weak self] path in
            let status = path.status
            MainActor.assumeIsolated { self?.report(status: status) }
        }
        monitor.start(queue: .main)
        seed(status: monitor.currentPath.status)
    }

    isolated deinit {
        monitor?.cancel()
    }
}
