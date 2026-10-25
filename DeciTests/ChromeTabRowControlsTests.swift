// DeciTests/ChromeTabRowControlsTests.swift
// A Chrome tab is either captured (the user clicked Deci in Chrome) and fully controllable, or not, and then it
// gets plain control only: volume and mute. Boost, EQ and outputs wait for a capture. The rules for which controls
// respond, what the row says and which volume it shows are pinned here, apart from the views that draw them.

import Testing
@testable import Deci

@MainActor
@Suite("ChromeTabRow controls")
struct ChromeTabRowControlsTests {
    private func tab(captured: Bool, volume: Float = 0.5, boost: BoostLevel = .x1) -> ChromeTab {
        var tab = ChromeTab(id: 1, title: "Tab", volume: volume)
        tab.isCaptured = captured
        tab.boost = boost
        return tab
    }

    // MARK: - Which controls respond

    @Test("an uncaptured tab keeps volume and mute, and boost, EQ and outputs stay unavailable")
    func uncapturedPlainControl() {
        let controls = ChromeTabRow.controls(for: tab(captured: false))
        #expect(controls.volumeAndMute)
        #expect(!controls.boostEQAndOutputs)
    }

    @Test("a captured tab has every control")
    func capturedFullControl() {
        let controls = ChromeTabRow.controls(for: tab(captured: true))
        #expect(controls.volumeAndMute)
        #expect(controls.boostEQAndOutputs)
    }

    @Test("a tab from an older extension that still says page or armed is plain control only")
    func legacyControlIsPlain() {
        let json: [String: Any] = ["tabs": [["id": 1, "control": "page"], ["id": 2, "control": "armed"]]]
        for parsed in ChromeExtensionManager.parseTabList(json).tabs {
            let controls = ChromeTabRow.controls(for: parsed)
            #expect(controls.volumeAndMute)
            #expect(!controls.boostEQAndOutputs)
        }
    }

    // MARK: - Caption

    @Test("an uncaptured tab says what a click on Deci in Chrome adds")
    func uncapturedCaption() {
        #expect(ChromeTabRow.captureNote(for: tab(captured: false)) == "Click Deci in Chrome for boost, EQ and outputs")
        #expect(ChromeTabRow.uncapturedCaption == "Click Deci in Chrome for boost, EQ and outputs")
    }

    @Test("an uncaptured tab with a stored output still shows the capture caption, whatever its device status")
    func uncapturedCaptionOutranksDevice() {
        var stored = tab(captured: false)
        stored.deviceName = "Speakers"
        stored.deviceStatus = .notFound
        #expect(ChromeTabRow.captureNote(for: stored) == ChromeTabRow.uncapturedCaption)
    }

    @Test("a captured tab has no capture caption, so its device and multi-output captions show")
    func capturedHasNoCaptureCaption() {
        #expect(ChromeTabRow.captureNote(for: tab(captured: true)) == nil)
    }

    // MARK: - Displayed volume

    @Test("an uncaptured tab shows its volume capped to 0...1 and leaves boost alone", arguments: [
        (stored: Float(0.4), shown: Float(0.4)),
        (stored: Float(0), shown: Float(0)),
        (stored: Float(1), shown: Float(1)),
        (stored: Float(1.7), shown: Float(1)),
        (stored: Float(-0.2), shown: Float(0)),
    ])
    func uncapturedVolumeIsCapped(stored: Float, shown: Float) {
        let source = tab(captured: false, volume: stored, boost: .x3)
        #expect(ChromeTabRow.displayedVolume(for: source) == shown)
        // The stored values are read, never rewritten.
        #expect(source.volume == stored)
        #expect(source.boost == .x3)
    }

    @Test("a captured tab shows its volume as it is")
    func capturedVolumeIsUnchanged() {
        #expect(ChromeTabRow.displayedVolume(for: tab(captured: true, volume: 0.4, boost: .x3)) == 0.4)
        #expect(ChromeTabRow.displayedVolume(for: tab(captured: true, volume: 0)) == 0)
    }

    @Test("the made-up level of an uncaptured tab scales by the capped volume")
    func simulatedLevelUsesCappedVolume() {
        var loud = tab(captured: false, volume: 1.6)
        loud.isAudible = true
        #expect(ChromeTabRow.simulatedLevel(for: loud, jitter: 0.5) == 0.5)
    }
}
