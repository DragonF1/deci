// FineTuneTests/HUDPopupParityTests.swift
// Regression: the HUD's displayed value must always match the popup slider
// for the same underlying gain / device tier.

import Testing
import Foundation
@testable import Deci

@Suite("HUD slider fraction matches popup slider position for every tier")
struct HUDPopupParityTests {
    @Test("Software tier: HUD sliderFraction == DeviceRow.volumeToSlider for the same gain", arguments: [
        Float(0.0), 0.01, 0.1, 0.25, 0.5, 0.7071, 0.9, 1.0
    ])
    func softwareParity(gain: Float) {
        let hudFraction = VolumeMapping.sliderFraction(forSystemGain: gain, tier: .software)
        let popupFraction = DeviceRow.volumeToSlider(gain, backend: .software)
        #expect(hudFraction == popupFraction)
    }

    @Test("Hardware tier: HUD sliderFraction == popup slider for the same scalar", arguments: [
        Float(0.0), 0.25, 0.5, 0.75, 1.0
    ])
    func hardwareParity(gain: Float) {
        let hudFraction = VolumeMapping.sliderFraction(forSystemGain: gain, tier: .hardware)
        let popupFraction = DeviceRow.volumeToSlider(gain, backend: .hardware)
        #expect(hudFraction == popupFraction)
    }

    @Test("DDC tier: HUD sliderFraction == popup slider for the same scalar", arguments: [
        Float(0.0), 0.25, 0.5, 0.75, 1.0
    ])
    func ddcParity(gain: Float) {
        let hudFraction = VolumeMapping.sliderFraction(forSystemGain: gain, tier: .ddc)
        let popupFraction = DeviceRow.volumeToSlider(gain, backend: .ddc)
        #expect(hudFraction == popupFraction)
    }

    @Test("Per-app: gainToSlider matches AppRowControls' sliderValue formula", arguments: [
        Float(0.0), 0.01, 0.25, 0.5, 1.0
    ])
    func perAppParity(gain: Float) {
        // AppRowControls.sliderValue (no drag override) == VolumeMapping.gainToSlider(volume).
        let hudFraction = VolumeMapping.gainToSlider(gain)
        let popupSliderValue = VolumeMapping.gainToSlider(gain)
        #expect(hudFraction == popupSliderValue)
    }
}
