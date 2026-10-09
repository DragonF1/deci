// DeciTests/SwitchVolumeRampTests.swift
//
// Pure-value tests for SwitchVolumeRamp: the bookkeeping that keeps a destructive
// device switch from clobbering the user's volume ("randomly quiet" after a switch).

import Testing
import Foundation
@testable import Deci

@Suite("SwitchVolumeRamp: target vs RT variable")
struct SwitchVolumeRampTargetTests {

    @Test("Starts idle with the given target")
    func startsIdle() {
        let ramp = SwitchVolumeRamp(target: 0.8)
        #expect(ramp.target == 0.8)
        #expect(ramp.isRamping == false)
    }

    @Test("Default target is unity")
    func defaultTargetIsUnity() {
        #expect(SwitchVolumeRamp().target == 1.0)
    }

    @Test("Outside a ramp, setTarget returns the value to publish to the RT variable")
    func setTargetWritesThroughWhenIdle() {
        var ramp = SwitchVolumeRamp()
        #expect(ramp.setTarget(0.6) == 0.6)
        #expect(ramp.target == 0.6)
    }

    @Test("During a ramp, setTarget stores the value but publishes nothing")
    func setTargetIsHeldBackDuringRamp() {
        var ramp = SwitchVolumeRamp(target: 1.0)
        _ = ramp.begin()

        #expect(ramp.setTarget(0.4) == nil)
        #expect(ramp.target == 0.4)
    }

    @Test("Boost values above unity are kept as-is (no clamping here)")
    func boostIsNotClamped() {
        var ramp = SwitchVolumeRamp()
        #expect(ramp.setTarget(4.0) == 4.0)
        #expect(ramp.target == 4.0)
    }
}

@Suite("SwitchVolumeRamp: restore")
struct SwitchVolumeRampRestoreTests {

    @Test("Restore uses the live target, not the value from when the switch began")
    func restoreUsesLiveTarget() {
        var ramp = SwitchVolumeRamp(target: 1.0)
        let token = ramp.begin()

        // The user drags the slider while the switch is in flight.
        _ = ramp.setTarget(0.25)

        #expect(ramp.finish(token) == 0.25)
        #expect(ramp.isRamping == false)
    }

    @Test("After the ramp ends, setTarget writes through again")
    func writesThroughAfterFinish() {
        var ramp = SwitchVolumeRamp()
        let token = ramp.begin()
        _ = ramp.finish(token)

        #expect(ramp.setTarget(0.5) == 0.5)
    }

    @Test("Finishing a ramp that saw no target change restores the original target")
    func restoreWithoutChange() {
        var ramp = SwitchVolumeRamp(target: 0.7)
        let token = ramp.begin()
        #expect(ramp.finish(token) == 0.7)
    }

    @Test("A token can restore only once")
    func tokenIsSingleUse() {
        var ramp = SwitchVolumeRamp(target: 0.7)
        let token = ramp.begin()
        #expect(ramp.finish(token) == 0.7)
        #expect(ramp.finish(token) == nil)
    }
}

@Suite("SwitchVolumeRamp: overlapping switches")
struct SwitchVolumeRampGenerationTests {

    @Test("A newer switch makes the older one stale")
    func newerSwitchSupersedesOlder() {
        var ramp = SwitchVolumeRamp()
        let older = ramp.begin()
        let newer = ramp.begin()

        #expect(ramp.isCurrent(older) == false)
        #expect(ramp.isCurrent(newer) == true)
    }

    @Test("A superseded switch never restores, and does not end the newer switch's ramp")
    func supersededSwitchNeverRestores() {
        var ramp = SwitchVolumeRamp(target: 0.9)
        let older = ramp.begin()
        let newer = ramp.begin()

        #expect(ramp.finish(older) == nil)
        // The newer switch still owns the RT variable.
        #expect(ramp.isRamping == true)
        #expect(ramp.setTarget(0.3) == nil)
        // Only the newer switch restores, and with the live target.
        #expect(ramp.finish(newer) == 0.3)
        #expect(ramp.isRamping == false)
    }

    @Test("Older switch finishing AFTER the newer one has finished still restores nothing")
    func olderAfterNewerRestoresNothing() {
        var ramp = SwitchVolumeRamp(target: 0.9)
        let older = ramp.begin()
        let newer = ramp.begin()

        #expect(ramp.finish(newer) == 0.9)
        #expect(ramp.finish(older) == nil)
        // A late stale finish must not re-enter the ramping state either.
        #expect(ramp.isRamping == false)
        #expect(ramp.setTarget(0.2) == 0.2)
    }

    @Test("Three overlapping switches: only the last one is current")
    func onlyLastOfThreeIsCurrent() {
        var ramp = SwitchVolumeRamp()
        let first = ramp.begin()
        let second = ramp.begin()
        let third = ramp.begin()

        #expect(ramp.isCurrent(first) == false)
        #expect(ramp.isCurrent(second) == false)
        #expect(ramp.isCurrent(third) == true)
    }

    @Test("cancelAll (tap invalidated) makes every token stale and ends the ramp")
    func cancelAllInvalidatesEverything() {
        var ramp = SwitchVolumeRamp(target: 0.6)
        let token = ramp.begin()

        let publish = ramp.cancelAll()

        #expect(publish == 0.6)
        #expect(ramp.isCurrent(token) == false)
        #expect(ramp.finish(token) == nil)
        #expect(ramp.isRamping == false)
    }

    @Test("cancelAll when idle is harmless and reports the target")
    func cancelAllWhenIdle() {
        var ramp = SwitchVolumeRamp(target: 0.45)
        #expect(ramp.cancelAll() == 0.45)
        #expect(ramp.isRamping == false)
    }

    @Test("A token from before cancelAll stays stale after a new switch begins")
    func staleTokenStaysStaleAcrossNewSwitch() {
        var ramp = SwitchVolumeRamp()
        let old = ramp.begin()
        _ = ramp.cancelAll()
        let fresh = ramp.begin()

        #expect(ramp.isCurrent(old) == false)
        #expect(ramp.isCurrent(fresh) == true)
    }
}

@Suite("SwitchVolumeRamp: ramp steps")
struct SwitchVolumeRampStepTests {

    @Test("Steps scale the target linearly: step i of n is target * i / n")
    func stepsScaleTarget() {
        let ramp = SwitchVolumeRamp(target: 1.0)
        #expect(ramp.stepVolume(step: 1, of: 10) == 0.1)
        #expect(abs(ramp.stepVolume(step: 5, of: 10) - 0.5) < 1e-6)
        #expect(ramp.stepVolume(step: 10, of: 10) == 1.0)
    }

    @Test("Steps scale the CURRENT target after a mid-ramp change")
    func stepsFollowLiveTarget() {
        var ramp = SwitchVolumeRamp(target: 1.0)
        _ = ramp.begin()
        _ = ramp.setTarget(0.5)

        #expect(abs(ramp.stepVolume(step: 5, of: 10) - 0.25) < 1e-6)
        #expect(ramp.stepVolume(step: 10, of: 10) == 0.5)
    }

    @Test("The final step lands exactly on the target (including boost)")
    func finalStepIsExactlyTarget() {
        let ramp = SwitchVolumeRamp(target: 3.7)
        #expect(ramp.stepVolume(step: 10, of: 10) == 3.7)
    }

    @Test("Step 0 is silence")
    func stepZeroIsSilence() {
        let ramp = SwitchVolumeRamp(target: 2.0)
        #expect(ramp.stepVolume(step: 0, of: 10) == 0)
    }

    @Test("Steps past the end are clamped to the target")
    func overshootingStepIsClamped() {
        let ramp = SwitchVolumeRamp(target: 0.8)
        #expect(ramp.stepVolume(step: 25, of: 10) == 0.8)
    }

    @Test("Negative steps clamp to silence")
    func negativeStepIsSilence() {
        let ramp = SwitchVolumeRamp(target: 0.8)
        #expect(ramp.stepVolume(step: -3, of: 10) == 0)
    }

    @Test("A zero or negative step count falls back to the full target instead of dividing by zero")
    func degenerateStepCount() {
        let ramp = SwitchVolumeRamp(target: 0.8)
        #expect(ramp.stepVolume(step: 1, of: 0) == 0.8)
        #expect(ramp.stepVolume(step: 1, of: -4) == 0.8)
    }

    @Test("Zero target stays zero at every step")
    func zeroTargetStaysZero() {
        let ramp = SwitchVolumeRamp(target: 0)
        for step in 0...10 {
            #expect(ramp.stepVolume(step: step, of: 10) == 0)
        }
    }
}
