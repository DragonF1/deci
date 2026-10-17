// DeciTests/DebugSoakConfigTests.swift
//
// Parsing of the DEBUG-only soak environment flags (see DebugSoakConfig).

#if DEBUG
import Testing
import Foundation
@testable import Deci

@Suite("DebugSoakConfig")
struct DebugSoakConfigTests {

    @Test("An empty environment changes nothing")
    func defaults() {
        let c = DebugSoakConfig(environment: [:])
        #expect(c.forceMixdown == false)
        #expect(c.forcedStreamTapSource == nil)
        #expect(c.driftOverride == nil)
        #expect(c.refreshSeconds == nil)
        #expect(c.zeroLog == false)
        #expect(c.summary == "tapSource=default drift=auto refresh=10s(default) zeroLog=off")
    }

    @Test("DECI_DEBUG_TAP_SOURCE=mixdown forces the mixdown tap and is not a device UID")
    func mixdown() {
        let c = DebugSoakConfig(environment: ["DECI_DEBUG_TAP_SOURCE": "mixdown"])
        #expect(c.forceMixdown)
        #expect(c.forcedStreamTapSource == nil)
        #expect(c.summary.contains("tapSource=mixdown"))
    }

    @Test("The mixdown flag ignores case and surrounding spaces")
    func mixdownLoose() {
        let c = DebugSoakConfig(environment: ["DECI_DEBUG_TAP_SOURCE": " Mixdown "])
        #expect(c.forceMixdown)
        #expect(c.forcedStreamTapSource == nil)
    }

    @Test("Any other DECI_DEBUG_TAP_SOURCE value is a device UID to stream-tap")
    func deviceUID() {
        let c = DebugSoakConfig(environment: ["DECI_DEBUG_TAP_SOURCE": "BuiltInSpeakerDevice"])
        #expect(!c.forceMixdown)
        #expect(c.forcedStreamTapSource == "BuiltInSpeakerDevice")
        #expect(c.summary.contains("tapSource=BuiltInSpeakerDevice"))
        #expect(DebugSoakConfig(environment: ["DECI_DEBUG_TAP_SOURCE": ""]).forcedStreamTapSource == nil)
    }

    @Test("DECI_DEBUG_TAP_DRIFT accepts on and off only")
    func drift() {
        #expect(DebugSoakConfig(environment: ["DECI_DEBUG_TAP_DRIFT": "on"]).driftOverride == true)
        #expect(DebugSoakConfig(environment: ["DECI_DEBUG_TAP_DRIFT": "off"]).driftOverride == false)
        #expect(DebugSoakConfig(environment: ["DECI_DEBUG_TAP_DRIFT": "yes"]).driftOverride == nil)
        #expect(DebugSoakConfig(environment: ["DECI_DEBUG_TAP_DRIFT": "off"]).summary.contains("drift=off"))
        #expect(DebugSoakConfig(environment: ["DECI_DEBUG_TAP_DRIFT": "on"]).summary.contains("drift=on"))
    }

    @Test("DECI_DEBUG_REFRESH_S takes positive seconds, fractions included")
    func refresh() {
        #expect(DebugSoakConfig(environment: ["DECI_DEBUG_REFRESH_S": "3"]).refreshSeconds == 3)
        #expect(DebugSoakConfig(environment: ["DECI_DEBUG_REFRESH_S": "0.5"]).refreshSeconds == 0.5)
        #expect(DebugSoakConfig(environment: ["DECI_DEBUG_REFRESH_S": "0"]).refreshSeconds == nil)
        #expect(DebugSoakConfig(environment: ["DECI_DEBUG_REFRESH_S": "-2"]).refreshSeconds == nil)
        #expect(DebugSoakConfig(environment: ["DECI_DEBUG_REFRESH_S": "soon"]).refreshSeconds == nil)
        #expect(DebugSoakConfig(environment: ["DECI_DEBUG_REFRESH_S": "inf"]).refreshSeconds == nil)
        #expect(DebugSoakConfig(environment: ["DECI_DEBUG_REFRESH_S": "3"]).summary.contains("refresh=3s"))
    }

    @Test("DECI_DEBUG_ZERO_LOG is on only for 1")
    func zeroLog() {
        #expect(DebugSoakConfig(environment: ["DECI_DEBUG_ZERO_LOG": "1"]).zeroLog)
        #expect(!DebugSoakConfig(environment: ["DECI_DEBUG_ZERO_LOG": "0"]).zeroLog)
        #expect(!DebugSoakConfig(environment: ["DECI_DEBUG_ZERO_LOG": "true"]).zeroLog)
        #expect(DebugSoakConfig(environment: ["DECI_DEBUG_ZERO_LOG": "1"]).summary.hasSuffix("zeroLog=on"))
    }
}
#endif
