// DeciTests/DebugFaultsTests.swift
//
// The SIGUSR2 stuck-tap fault is keyed by the callback that was primary when it fired, so
// a tap promoted by a rescue is healthy (a role-keyed flag would stick every promoted tap
// and the rescue would loop). DECI_DEBUG_STUCK_TARGET picks that or "every tap".

#if DEBUG
import Testing
import Foundation
@testable import Deci

@Suite("DebugFaults: stuck-tap target")
struct DebugFaultsStuckTargetTests {

    @Test("The target defaults to the primary callback and parses primary and all, ignoring case and spaces")
    func parsing() {
        #expect(DebugFaults.StuckTarget.parse(nil) == .primary)
        #expect(DebugFaults.StuckTarget.parse("") == .primary)
        #expect(DebugFaults.StuckTarget.parse("primary") == .primary)
        #expect(DebugFaults.StuckTarget.parse("  PRIMARY ") == .primary)
        #expect(DebugFaults.StuckTarget.parse("all") == .all)
        #expect(DebugFaults.StuckTarget.parse(" All") == .all)
        #expect(DebugFaults.StuckTarget.parse("secondary") == .primary)
    }

    @Test("Only the callback that was stuck reads zeros, whatever its role is now")
    func keyedByCallbackID() {
        // Callback 7 was primary at SIGUSR2. A rescue's candidate (callback 8) is healthy,
        // and stays healthy after it is promoted to primary.
        #expect(DebugFaults.isStuck(callbackID: 7, stuckCallbackID: 7, stuckAll: false))
        #expect(!DebugFaults.isStuck(callbackID: 8, stuckCallbackID: 7, stuckAll: false))
    }

    @Test("No stuck callback means nothing is stuck")
    func nothingStuck() {
        #expect(!DebugFaults.isStuck(callbackID: 0, stuckCallbackID: 0, stuckAll: false))
        #expect(!DebugFaults.isStuck(callbackID: 3, stuckCallbackID: 0, stuckAll: false))
    }

    @Test("Stuck-all sticks every callback, including taps created later")
    func stuckAll() {
        #expect(DebugFaults.isStuck(callbackID: 1, stuckCallbackID: 0, stuckAll: true))
        #expect(DebugFaults.isStuck(callbackID: 99, stuckCallbackID: 7, stuckAll: true))
    }
}
#endif
