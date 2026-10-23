// DeciTests/ChromeTabRowLevelTests.swift
// A Chrome tab has no tap to meter, so its row shows a made-up level while the tab plays. The rule for when
// that level is shown is pinned here, apart from the timer that drives it.

import Testing
@testable import Deci

@MainActor
@Suite("ChromeTabRow simulated level")
struct ChromeTabRowLevelTests {
    private func tab(volume: Float = 1, muted: Bool = false, paused: Bool = false,
                     audible: Bool = true, control: ChromeTabControl = .none) -> ChromeTab {
        var tab = ChromeTab(id: 1, title: "Tab", volume: volume)
        tab.isMuted = muted
        tab.paused = paused
        tab.isAudible = audible
        tab.control = control
        return tab
    }

    @Test("an audible playing tab shows the jitter scaled by its volume")
    func audiblePlaying() {
        #expect(ChromeTabRow.simulatedLevel(for: tab(volume: 0.5), jitter: 0.4) == 0.2)
    }

    @Test("a captured tab plays even before Chrome calls it audible")
    func capturedPlaying() {
        #expect(ChromeTabRow.simulatedLevel(for: tab(audible: false, control: .capture), jitter: 0.4) == 0.4)
    }

    @Test("a silent tab that is not captured rests")
    func silentRests() {
        #expect(ChromeTabRow.simulatedLevel(for: tab(audible: false), jitter: 0.4) == 0)
    }

    @Test("a paused tab rests")
    func pausedRests() {
        #expect(ChromeTabRow.simulatedLevel(for: tab(paused: true), jitter: 0.4) == 0)
    }

    @Test("a muted tab rests")
    func mutedRests() {
        #expect(ChromeTabRow.simulatedLevel(for: tab(muted: true), jitter: 0.4) == 0)
    }

    @Test("a tab at zero volume rests")
    func zeroVolumeRests() {
        #expect(ChromeTabRow.simulatedLevel(for: tab(volume: 0), jitter: 0.4) == 0)
    }

    @Test("the made-up jitter stays inside the range the meter has always used")
    func jitterRange() {
        #expect(ChromeTabRow.jitterRange == 0.1...0.7)
    }
}
