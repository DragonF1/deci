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

@Suite("VolumeKeyModifiers: the modifiers the feedback pop still sees")
struct VolumeKeyModifiersTests {

    @Test("A modifier that belongs to the matched combo does not count for the pop", arguments: [
        (held: VolumeKeyCombo([]),                          matched: VolumeKeyCombo([]),                shift: false, option: false),
        (held: VolumeKeyCombo([.shift]),                    matched: VolumeKeyCombo([]),                shift: true,  option: false),
        (held: VolumeKeyCombo([.option]),                   matched: VolumeKeyCombo([]),                shift: false, option: true),
        (held: VolumeKeyCombo([.shift, .option]),           matched: VolumeKeyCombo([]),                shift: true,  option: true),
        (held: VolumeKeyCombo([.control]),                  matched: VolumeKeyCombo([]),                shift: false, option: false),
        (held: VolumeKeyCombo([.command]),                  matched: VolumeKeyCombo([.command]),        shift: false, option: false),
        (held: VolumeKeyCombo([.command, .shift]),          matched: VolumeKeyCombo([.command, .shift]), shift: false, option: false),
        (held: VolumeKeyCombo([.command, .shift]),          matched: VolumeKeyCombo([.command]),        shift: true,  option: false),
        (held: VolumeKeyCombo([.command, .option]),         matched: VolumeKeyCombo([.command]),        shift: false, option: true),
        (held: VolumeKeyCombo([.option]),                   matched: VolumeKeyCombo([.option]),         shift: false, option: false),
        (held: VolumeKeyCombo([.option, .shift]),           matched: VolumeKeyCombo([.option]),         shift: true,  option: false),
        (held: VolumeKeyCombo([.control, .shift]),          matched: VolumeKeyCombo([.control]),        shift: true,  option: false),
        (held: VolumeKeyCombo([.shift]),                    matched: VolumeKeyCombo([.shift]),          shift: false, option: false),
    ])
    func feedbackFlags(_ c: (held: VolumeKeyCombo, matched: VolumeKeyCombo, shift: Bool, option: Bool)) {
        let modifiers = VolumeKeyModifiers(held: c.held, matched: c.matched)
        #expect(modifiers.feedbackShiftHeld == c.shift)
        #expect(modifiers.feedbackOptionHeld == c.option)
    }

    @Test("With the default rows Command+Shift does not invert the pop; Shift alone still does", arguments: [true, false])
    func popDecision(prefOn: Bool) {
        func shouldPlay(_ held: VolumeKeyCombo) -> Bool? {
            guard let binding = VolumeKeyBinding.defaults.binding(matching: held) else { return nil }
            let mods = VolumeKeyModifiers(held: held, matched: binding.combo)
            return VolumeFeedback.shouldPlay(prefOn: prefOn, shiftHeld: mods.feedbackShiftHeld, optionHeld: mods.feedbackOptionHeld)
        }
        #expect(shouldPlay([]) == prefOn)
        #expect(shouldPlay([.shift]) == !prefOn)                          // macOS convention kept
        #expect(shouldPlay([.shift, .option]) == prefOn)                  // Option+Shift follows the preference
        #expect(shouldPlay([.option]) == prefOn)
        #expect(shouldPlay([.command]) == prefOn)
        #expect(shouldPlay([.command, .shift]) == prefOn)                 // Shift belongs to the combo here
        #expect(shouldPlay([.command, .shift, .option]) == prefOn)
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
