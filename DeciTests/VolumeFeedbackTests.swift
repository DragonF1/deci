// FineTuneTests/VolumeFeedbackTests.swift
// Decision logic for the volume-feedback pop. NSSound playback itself is
// verified manually — it needs a real output device and a listener.
import Testing
import Foundation
import CoreGraphics
@testable import Deci

@Suite("VolumeFeedback — shouldPlay modifier rule")
struct VolumeFeedbackShouldPlayTests {
    @Test("Shift alone inverts; Option follows pref", arguments: [
        (prefOn: true,  shift: false, option: false, expected: true),
        (prefOn: false, shift: false, option: false, expected: false),
        (prefOn: true,  shift: true,  option: false, expected: false),
        (prefOn: false, shift: true,  option: false, expected: true),
        (prefOn: true,  shift: true,  option: true,  expected: true),
        (prefOn: false, shift: true,  option: true,  expected: false),
        (prefOn: true,  shift: false, option: true,  expected: true),
        (prefOn: false, shift: false, option: true,  expected: false),
    ])
    func decisionTable(_ c: (prefOn: Bool, shift: Bool, option: Bool, expected: Bool)) {
        #expect(VolumeFeedback.shouldPlay(prefOn: c.prefOn, shiftHeld: c.shift, optionHeld: c.option) == c.expected)
    }
}

@Suite("VolumeKeyModifiers: chord and feedback modifiers from event flags")
struct VolumeKeyModifiersTests {
    @Test("Flags pick the step chord; Shift alone, Option and Control stay plain", arguments: [
        (flags: CGEventFlags([]),                           chord: VolumeStepChord.plain),
        (flags: CGEventFlags([.maskShift]),                 chord: VolumeStepChord.plain),
        (flags: CGEventFlags([.maskAlternate]),             chord: VolumeStepChord.plain),
        (flags: CGEventFlags([.maskControl]),               chord: VolumeStepChord.plain),
        (flags: CGEventFlags([.maskShift, .maskAlternate]), chord: VolumeStepChord.plain),
        (flags: CGEventFlags([.maskCommand]),               chord: VolumeStepChord.command),
        (flags: CGEventFlags([.maskCommand, .maskAlternate]), chord: VolumeStepChord.command),
        (flags: CGEventFlags([.maskCommand, .maskShift]),   chord: VolumeStepChord.commandShift),
        (flags: CGEventFlags([.maskCommand, .maskShift, .maskAlternate]), chord: VolumeStepChord.commandShift),
    ])
    func chordFromFlags(_ c: (flags: CGEventFlags, chord: VolumeStepChord)) {
        #expect(VolumeKeyModifiers(flags: c.flags).chord == c.chord)
    }

    @Test("Shift alone still reaches the feedback rule; under Command it does not")
    func feedbackShift() {
        #expect(VolumeKeyModifiers(flags: []).feedbackShiftHeld == false)
        #expect(VolumeKeyModifiers(flags: [.maskShift]).feedbackShiftHeld == true)
        #expect(VolumeKeyModifiers(flags: [.maskShift, .maskAlternate]).feedbackShiftHeld == true)
        #expect(VolumeKeyModifiers(flags: [.maskCommand]).feedbackShiftHeld == false)
        #expect(VolumeKeyModifiers(flags: [.maskCommand, .maskShift]).feedbackShiftHeld == false)
    }

    @Test("Option is passed through whether or not Command is held")
    func feedbackOption() {
        #expect(VolumeKeyModifiers(flags: []).optionHeld == false)
        #expect(VolumeKeyModifiers(flags: [.maskAlternate]).optionHeld == true)
        #expect(VolumeKeyModifiers(flags: [.maskCommand, .maskAlternate]).optionHeld == true)
        #expect(VolumeKeyModifiers(flags: [.maskCommand, .maskShift]).optionHeld == false)
    }

    @Test("Command+Shift does not invert the pop; Shift alone still does", arguments: [true, false])
    func popDecision(prefOn: Bool) {
        func shouldPlay(_ flags: CGEventFlags) -> Bool {
            let mods = VolumeKeyModifiers(flags: flags)
            return VolumeFeedback.shouldPlay(prefOn: prefOn, shiftHeld: mods.feedbackShiftHeld, optionHeld: mods.optionHeld)
        }
        #expect(shouldPlay([]) == prefOn)
        #expect(shouldPlay([.maskShift]) == !prefOn)                      // macOS convention kept
        #expect(shouldPlay([.maskShift, .maskAlternate]) == prefOn)       // Option+Shift follows the preference
        #expect(shouldPlay([.maskCommand]) == prefOn)
        #expect(shouldPlay([.maskCommand, .maskShift]) == prefOn)         // Shift belongs to the chord here
        #expect(shouldPlay([.maskCommand, .maskShift, .maskAlternate]) == prefOn)
    }
}

@Suite("VolumeFeedback — gain by tier")
struct VolumeFeedbackGainTests {
    @Test func hardwareTierPlaysFullScale() {
        #expect(VolumeFeedback.gain(tier: .hardware, sliderFraction: 0.3) == 1.0)
    }
    @Test func ddcTierPlaysFullScale() {
        #expect(VolumeFeedback.gain(tier: .ddc, sliderFraction: 0.3) == 1.0)
    }
    @Test func softwareTierMatchesTapMapping() {
        #expect(VolumeFeedback.gain(tier: .software, sliderFraction: 0.5)
            == VolumeMapping.systemGain(forSliderFraction: 0.5, tier: .software))
        #expect(VolumeFeedback.gain(tier: .software, sliderFraction: 0.0) == 0.0)
        #expect(VolumeFeedback.gain(tier: .software, sliderFraction: 1.0) == 1.0)
    }
}

@Suite("VolumeFeedbackPlayer — cooldown gate")
@MainActor
struct VolumeFeedbackCooldownTests {
    @Test func leadingEdgeGate() {
        let player = VolumeFeedbackPlayer()
        #expect(player.passesCooldown(at: 10.0) == true)
        #expect(player.passesCooldown(at: 10.1) == false)   // inside the 150 ms window
        #expect(player.passesCooldown(at: 10.16) == true)   // window elapsed
        #expect(player.passesCooldown(at: 10.17) == false)  // new window armed by the pass
    }

    @Test func boundaryExactlyAtCooldownPasses() {
        let player = VolumeFeedbackPlayer()
        #expect(player.passesCooldown(at: 0.0) == true)
        #expect(player.passesCooldown(at: VolumeFeedbackPlayer.cooldown) == true)  // exact: 0.15 - 0.0 == cooldown, fails under >
    }
}
