// DeciTests/ChromeAudibleGateTests.swift
//
// ChromeAudibleGate keeps the stuck-tap watchdog from probing a Chrome that is silent on purpose. Chrome keeps its
// output IO running while it makes no sound (paused tabs, page and offscreen AudioContexts), so "input silent while
// IsRunningOutput" proves nothing for it, and every probe glitches the user's Bluetooth output. The extension knows
// which tabs are audible. The first suite covers the gate's rules and the mapping from the extension's state to a
// report; the second feeds the gate's verdicts to the watchdog.

import Foundation
import Testing
@testable import Deci

@Suite("ChromeAudibleGate: rules")
struct ChromeAudibleGateRuleTests {
    private let allReports: [ChromeAudibleReport] = [.unknown, .silent, .audible]

    private func verdict(
        running: Bool? = true,
        chrome: Bool = true,
        _ report: ChromeAudibleReport,
        silence: Double
    ) -> Bool? {
        ChromeAudibleGate.appIsPlaying(running: running, isChrome: chrome, report: report, inputSilence: silence)
    }

    // MARK: a. running is not true

    @Test("An unread IsRunningOutput stays unread, whatever the report")
    func runningNilPassesThrough() {
        for report in allReports {
            #expect(verdict(running: nil, report, silence: 10) == nil)
            #expect(verdict(running: nil, report, silence: 0) == nil)
        }
    }

    @Test("An app that is not running output is not playing, whatever the report")
    func runningFalsePassesThrough() {
        for report in allReports {
            #expect(verdict(running: false, report, silence: 10) == false)
            #expect(verdict(running: false, report, silence: 0) == false)
        }
    }

    // MARK: b. not Chrome, or no report

    @Test("An app other than Chrome keeps its IsRunningOutput, even when the report says silent")
    func nonChromePassesThrough() {
        for report in allReports {
            #expect(verdict(chrome: false, report, silence: 0) == true)
            #expect(verdict(chrome: false, report, silence: 1) == true)
            #expect(verdict(chrome: false, report, silence: 60) == true)
        }
    }

    @Test("Chrome with an unknown report keeps its IsRunningOutput: today's behaviour")
    func unknownReportPassesThrough() {
        #expect(verdict(.unknown, silence: 0) == true)
        #expect(verdict(.unknown, silence: 0.3) == true)
        #expect(verdict(.unknown, silence: 1.5) == true)
        #expect(verdict(.unknown, silence: 60) == true)
    }

    // MARK: c. signal flowing

    @Test("While the tap hears Chrome the app is playing, whether or not the extension sees an audible tab")
    func signalFlowingIsPlaying() {
        for report in [ChromeAudibleReport.silent, .audible] {
            #expect(verdict(report, silence: 0) == true)
            #expect(verdict(report, silence: 0.1) == true)
            #expect(verdict(report, silence: 0.249) == true)
        }
    }

    @Test("Signal counts as flowing under the first rung's threshold and not from it")
    func flowingBoundaryIsTheFirstRung() {
        let boundary = TapWatchdog.rescueThreshold(rung: 0)
        #expect(verdict(.silent, silence: boundary.nextDown) == true)
        #expect(verdict(.silent, silence: boundary) == false)
        #expect(verdict(.audible, silence: boundary.nextDown) == true)
        #expect(verdict(.audible, silence: boundary) == nil)
    }

    // MARK: d. silent report

    @Test("A silent report with a silent tap means Chrome makes no sound: not playing, whatever the silence")
    func silentReportIsNotPlaying() {
        for silence in [0.25, 0.4, 2.0, 3.5, 8, 600] {
            #expect(verdict(.silent, silence: silence) == false, "silence \(silence)")
        }
    }

    // MARK: e. audible report, not yet proven

    @Test("An audible flag that lingers after sound stops proves nothing for the first 3.5 s: no decision")
    func audibleWithinHoldIsUndecided() {
        for silence in [0.25, 0.4, 1.0, 2.0, 2.5, 3.49, ChromeAudibleGate.audibleHold.nextDown] {
            #expect(verdict(.audible, silence: silence) == nil, "silence \(silence)")
        }
    }

    // MARK: f. audible report, still silent

    @Test("A tab still audible 3.5 s into the tap's silence means the tap may be dead: playing, so the ladder may probe")
    func audiblePastHoldIsPlaying() {
        for silence in [ChromeAudibleGate.audibleHold, 3.51, 4, 8, 600] {
            #expect(verdict(.audible, silence: silence) == true, "silence \(silence)")
        }
    }

    @Test("The hold is 3.5 s: the tab flag lingers about 2 s, then the extension needs its push debounce and a round trip")
    func holdValue() {
        #expect(ChromeAudibleGate.audibleHold == 3.5)
    }
}

@Suite("ChromeAudibleGate: report from the extension's state")
struct ChromeAudibleReportMappingTests {
    private func tab(_ id: Int, audible: Bool = false, muted: Bool = false, volume: Float = 1) -> ChromeTab {
        var tab = ChromeTab(id: id, title: "Tab \(id)", volume: volume)
        tab.isAudible = audible
        tab.isMuted = muted
        return tab
    }

    private func report(
        _ tabs: [ChromeTab],
        connection: ChromeConnectionState = .connected,
        tracking: Bool = true
    ) -> ChromeAudibleReport {
        ChromeAudibleGate.report(connection: connection, trackingTabs: tracking, tabs: tabs)
    }

    @Test("A disconnected extension says nothing: unknown, even with an audible tab on record")
    func disconnected() {
        #expect(report([tab(1, audible: true)], connection: .disconnected) == .unknown)
        #expect(report([], connection: .disconnected) == .unknown)
    }

    @Test("An extension not judged yet says nothing: unknown")
    func notJudgedYet() {
        #expect(report([tab(1, audible: true)], connection: .unknown) == .unknown)
        #expect(report([], connection: .unknown) == .unknown)
    }

    @Test("With tab tracking off the extension reports no tabs at all, which is not a silent Chrome: unknown")
    func trackingOff() {
        #expect(report([], tracking: false) == .unknown)
        #expect(report([tab(1, audible: true)], tracking: false) == .unknown)
    }

    @Test("Connected and tracking with no tabs: silent")
    func noTabs() {
        #expect(report([]) == .silent)
    }

    @Test("An audible tab: audible")
    func audibleTab() {
        #expect(report([tab(1, audible: true)]) == .audible)
    }

    @Test("A tab flagged audible but muted outputs nothing: silent")
    func audibleButMutedTab() {
        #expect(report([tab(1, audible: true, muted: true)]) == .silent)
    }

    @Test("A captured tab turned down to volume 0 can stay flagged audible while it outputs nothing: silent")
    func audibleButZeroVolumeTab() {
        #expect(report([tab(1, audible: true, volume: 0)]) == .silent)
    }

    @Test("Any volume above 0 counts: a quiet audible tab is audible")
    func quietAudibleTab() {
        #expect(report([tab(1, audible: true, volume: 0.01)]) == .audible)
        #expect(report([tab(1, audible: true, volume: 1)]) == .audible)
    }

    @Test("A zeroed tab does not hide an audible one beside it")
    func zeroVolumeBesideAudible() {
        #expect(report([tab(1, audible: true, volume: 0), tab(2, audible: true)]) == .audible)
        #expect(report([tab(1, audible: true, volume: 0), tab(2, audible: true, muted: true)]) == .silent)
    }

    @Test("A tab that is not audible: silent, muted or not")
    func silentTab() {
        #expect(report([tab(1)]) == .silent)
        #expect(report([tab(1, muted: true)]) == .silent)
    }

    @Test("One audible, unmuted tab among silent and muted ones is enough: audible")
    func oneAudibleAmongMany() {
        let tabs = [tab(1), tab(2, audible: true, muted: true), tab(3, audible: true), tab(4, muted: true)]
        #expect(report(tabs) == .audible)
    }

    @Test("Only silent and muted tabs: silent")
    func manyQuietTabs() {
        let tabs = [tab(1), tab(2, audible: true, muted: true), tab(3, muted: true)]
        #expect(report(tabs) == .silent)
    }
}

@Suite("TapWatchdog: Chrome audible gate")
struct TapWatchdogChromeGateTests {
    private let step = 0.25

    /// One health tick for Chrome's tap, as the engine builds it: IsRunningOutput true, the gate's verdict as the sample.
    private func tick(
        _ watchdog: inout TapWatchdog,
        silence: Double,
        report: ChromeAudibleReport,
        clock: Double
    ) -> TapWatchdogAction? {
        let playing = ChromeAudibleGate.appIsPlaying(running: true, isChrome: true, report: report, inputSilence: silence)
        let readings = TapHealthReadings(
            isSwitching: false,
            secondsSinceTapStart: 300,
            inputSignalSeen: true,
            secondsSinceInputSignal: silence,
            secondsSinceDiscontinuity: .infinity,
            discontinuityCount: 0,
            secondsSinceHealthyOutput: 0.1
        )
        return watchdog.evaluate(TapHealthSample(readings: readings, appIsPlaying: playing, isUserMuted: false, clock: clock))
    }

    @Test("A silent Chrome (no audible tab) is never rescued or rebuilt over 10 s of silent tap input")
    func silentChromeIsNeverProbed() {
        var watchdog = TapWatchdog()
        for i in 0...40 {
            let silence = Double(i) * step
            let action = tick(&watchdog, silence: silence, report: .silent, clock: silence)
            #expect(action == nil, "silence \(silence)")
        }
    }

    @Test("A silent Chrome stays unprobed over minutes, past every rung of the ladder")
    func silentChromeStaysUnprobedForMinutes() {
        var watchdog = TapWatchdog()
        for i in 0...(5 * 60 * 4) {
            let silence = Double(i) * step
            #expect(tick(&watchdog, silence: silence, report: .silent, clock: silence) == nil)
        }
    }

    @Test("Chrome with an audible tab and a dead tap is first probed at 3.5 s of silence, not at 0.25 s")
    func audibleDeadChromeWaitsForTheHold() {
        var watchdog = TapWatchdog()
        var firstRescue: (silence: Double, action: TapWatchdogAction)?
        for i in 0...40 where firstRescue == nil {
            let silence = Double(i) * step
            if let action = tick(&watchdog, silence: silence, report: .audible, clock: silence) {
                firstRescue = (silence, action)
            }
        }
        #expect(firstRescue?.action == .rescue(.unexplainedSilence, rung: 0))
        #expect(firstRescue.map { $0.silence >= ChromeAudibleGate.audibleHold } == true)
        #expect(firstRescue?.silence == 3.5)
    }

    @Test("Nothing is probed before 3.5 s of silence while a tab merely looks audible")
    func lingeringAudibleFlagIsNotProbed() {
        var watchdog = TapWatchdog()
        for silence in [0.0, 0.25, 0.5, 1.0, 2.0, 2.25, 3.0, 3.25] {
            #expect(tick(&watchdog, silence: silence, report: .audible, clock: silence) == nil, "silence \(silence)")
        }
    }

    @Test("Pausing a tab: the audible flag lingers about 2 s and then clears, and nothing is probed on the way to 10 s")
    func pausePathIsNeverProbed() {
        var watchdog = TapWatchdog()
        for i in 0...40 {
            let silence = Double(i) * step
            // The sound stopped at silence 0; the tab flag stays up until about 2.1 s.
            let report: ChromeAudibleReport = silence <= 2.1 ? .audible : .silent
            let action = tick(&watchdog, silence: silence, report: report, clock: silence)
            #expect(action == nil, "silence \(silence)")
        }
    }

    @Test("A Chrome that was silent and then gets an audible tab onto a dead tap is probed after all, not left stopped")
    func silentThenAudibleDeadTapIsProbed() {
        var watchdog = TapWatchdog()
        // Quiet for 5 s: the watchdog is told the app is not playing, and waits.
        for i in 0...20 {
            let silence = Double(i) * step
            #expect(tick(&watchdog, silence: silence, report: .silent, clock: silence) == nil)
        }
        // A tab turns audible but the tap stays dead (silence is already past the hold): the watchdog starts counting
        // from here, so the probe follows once the tap has stayed silent for the first rung's 0.25 s.
        #expect(tick(&watchdog, silence: 5.25, report: .audible, clock: 5.25) == nil)
        var rescued = false
        for i in 0...40 where !rescued {
            let silence = 5.5 + Double(i) * step
            if case .rescue = tick(&watchdog, silence: silence, report: .audible, clock: silence) { rescued = true }
        }
        #expect(rescued)
    }

    @Test("Chrome without a report is probed at 0.25 s, as before")
    func unknownReportIsUnchanged() {
        var watchdog = TapWatchdog()
        #expect(tick(&watchdog, silence: 0.25, report: .unknown, clock: 0.25) == .rescue(.unexplainedSilence, rung: 0))
    }
}

@MainActor
@Suite("ChromeExtensionManager: audible report")
struct ChromeExtensionAudibleReportTests {
    private final class SentLog {
        var messages: [[String: Any]] = []
        func types() -> [String] { messages.compactMap { $0["type"] as? String } }
        var getTabsCount: Int { types().filter { $0 == "GET_TABS" }.count }
        func clear() { messages.removeAll() }
    }

    private final class FakeClock {
        var now: Date
        init(_ now: Date) { self.now = now }
        func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
    }

    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func makeManager(_ clock: FakeClock) -> (manager: ChromeExtensionManager, sent: SentLog) {
        let manager = ChromeExtensionManager(observeHost: false)
        let sent = SentLog()
        manager.messageSink = { sent.messages.append($0) }
        manager.connectionClock = { clock.now }
        return (manager, sent)
    }

    private let quietList = #"{"type":"TAB_LIST","tabs":[{"id":4,"title":"Paused"}]}"#
    private let audibleList = #"{"type":"TAB_LIST","tabs":[{"id":4,"title":"Playing","isAudible":true}]}"#

    /// Reads the report, then lets the 50 ms message timer's work happen at once.
    private func report(_ manager: ChromeExtensionManager) -> ChromeAudibleReport {
        let report = manager.audibleReport()
        manager.flushMessages()
        return report
    }

    @Test("The freshness window is 30 s")
    func freshnessValue() {
        #expect(ChromeExtensionManager.audibleReportFreshness == 30)
    }

    @Test("An extension never heard from is unknown, and asking does not poll it")
    func neverHeardFrom() {
        let clock = FakeClock(start)
        let (manager, sent) = makeManager(clock)
        #expect(report(manager) == .unknown)
        clock.advance(600)
        #expect(report(manager) == .unknown)
        #expect(sent.getTabsCount == 0)
    }

    @Test("A fresh message gives the report and sends no request")
    func freshMessageNoRequest() {
        let clock = FakeClock(start)
        let (manager, sent) = makeManager(clock)
        manager.handleChromeMessageString(quietList)
        sent.clear()

        #expect(report(manager) == .silent)
        clock.advance(29.9)
        #expect(report(manager) == .silent)
        #expect(sent.getTabsCount == 0)
    }

    @Test("A message 30 s old sends one GET_TABS, and a second call right after sends none")
    func staleMessageSendsOneRequest() {
        let clock = FakeClock(start)
        let (manager, sent) = makeManager(clock)
        manager.handleChromeMessageString(quietList)
        sent.clear()

        clock.advance(30)
        #expect(report(manager) == .silent, "the verdict stands until the request is judged")
        #expect(sent.getTabsCount == 1)

        sent.clear()
        clock.advance(0.5)
        #expect(report(manager) == .silent)
        #expect(sent.getTabsCount == 0)
    }

    @Test("A request in flight counts as fresh: nothing more is sent for 30 s after it")
    func requestInFlightIsFresh() {
        let clock = FakeClock(start)
        let (manager, sent) = makeManager(clock)
        manager.handleChromeMessageString(quietList)
        clock.advance(29)
        manager.requestTabs()
        manager.flushMessages()
        sent.clear()

        clock.advance(2)
        _ = report(manager)
        #expect(sent.getTabsCount == 0)
    }

    @Test("An answer to the request keeps the connection and brings the new tabs")
    func answeredRequestRefreshes() {
        let clock = FakeClock(start)
        let (manager, sent) = makeManager(clock)
        manager.handleChromeMessageString(quietList)
        clock.advance(31)
        #expect(report(manager) == .silent)
        #expect(sent.getTabsCount == 1)

        clock.advance(0.1)
        manager.handleChromeMessageString(audibleList)
        clock.advance(5)
        manager.evaluateConnection()
        #expect(manager.connectionState == .connected)
        #expect(report(manager) == .audible)
    }

    @Test("An extension that dies after a silent list times out to disconnected, and the report turns unknown")
    func deadExtensionTurnsUnknown() {
        let clock = FakeClock(start)
        let (manager, sent) = makeManager(clock)
        manager.handleChromeMessageString(quietList)
        #expect(manager.audibleReport() == .silent)

        clock.advance(31)
        #expect(report(manager) == .silent)
        #expect(sent.getTabsCount == 1)

        // Nobody answers: past the timeout the connection is judged dead and its tabs are dropped.
        clock.advance(ChromeExtensionManager.connectionTimeout + 0.1)
        manager.evaluateConnection()
        #expect(manager.connectionState == .disconnected)
        #expect(manager.chromeTabs.isEmpty)
        #expect(manager.audibleReport() == .unknown)
    }

    @Test("A dead extension is polled once per 30 s, not on every call")
    func deadExtensionIsPolledSlowly() {
        let clock = FakeClock(start)
        let (manager, sent) = makeManager(clock)
        manager.handleChromeMessageString(quietList)
        clock.advance(31)
        _ = report(manager)
        clock.advance(ChromeExtensionManager.connectionTimeout + 0.1)
        manager.evaluateConnection()
        #expect(manager.connectionState == .disconnected)

        sent.clear()
        for _ in 0..<20 {
            clock.advance(0.25)
            #expect(report(manager) == .unknown)
        }
        #expect(sent.getTabsCount == 0, "well inside 30 s of the last request")

        clock.advance(30)
        #expect(report(manager) == .unknown)
        #expect(sent.getTabsCount == 1)
        _ = report(manager)
        _ = report(manager)
        #expect(sent.getTabsCount == 1, "calls right after the request add none")
    }

    @Test("An extension that comes back is picked up by the next poll")
    func deadExtensionComesBack() {
        let clock = FakeClock(start)
        let (manager, _) = makeManager(clock)
        manager.handleChromeMessageString(quietList)
        clock.advance(31)
        _ = report(manager)
        clock.advance(ChromeExtensionManager.connectionTimeout + 0.1)
        manager.evaluateConnection()
        #expect(report(manager) == .unknown)

        manager.handleChromeMessageString(audibleList)
        #expect(manager.connectionState == .connected)
        #expect(report(manager) == .audible)
    }

    @Test("With tab tracking off the report is unknown however fresh the extension is")
    func trackingOffIsUnknown() {
        let clock = FakeClock(start)
        let (manager, _) = makeManager(clock)
        manager.setTracking(tabs: false, incognito: false)
        manager.handleChromeMessageString(#"{"type":"TAB_LIST","tabs":[]}"#)
        #expect(report(manager) == .unknown)
    }
}
