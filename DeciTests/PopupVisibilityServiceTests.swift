// DeciTests/PopupVisibilityServiceTests.swift
// The HUD stays quiet while either popup is open. Swapping from one popup to the other resigns one
// window and makes the other key in an order nobody controls, so the flag must not depend on it.

import Foundation
import Observation
import os
import Testing
@testable import Deci

/// Records that an observation fired, from the nonisolated closure `withObservationTracking` takes.
private nonisolated final class Fired: Sendable {
    private let flag = OSAllocatedUnfairLock(initialState: false)
    var value: Bool { flag.withLock { $0 } }
    func set() { flag.withLock { $0 = true } }
}

@MainActor
@Suite("PopupVisibilityService")
struct PopupVisibilityServiceTests {
    @Test("nothing is visible at launch")
    func startsHidden() {
        #expect(PopupVisibilityService().isVisible == false)
    }

    @Test("opening one popup makes the service visible", arguments: MenuBarItemID.allCases)
    func oneOpen(id: MenuBarItemID) {
        let service = PopupVisibilityService()
        service.setOpen(id, true)
        #expect(service.isVisible)
    }

    @Test("closing the only open popup hides the service", arguments: MenuBarItemID.allCases)
    func oneOpenThenClosed(id: MenuBarItemID) {
        let service = PopupVisibilityService()
        service.setOpen(id, true)
        service.setOpen(id, false)
        #expect(service.isVisible == false)
    }

    @Test("both open is visible")
    func bothOpen() {
        let service = PopupVisibilityService()
        service.setOpen(.mixer, true)
        service.setOpen(.music, true)
        #expect(service.isVisible)
    }

    @Test("Music opens before the Mixer resigns: still visible")
    func mixerResignsAfterMusicBecomesKey() {
        let service = PopupVisibilityService()
        service.setOpen(.mixer, true)
        service.setOpen(.music, true)
        service.setOpen(.mixer, false)
        #expect(service.isVisible)
    }

    @Test("the Mixer opens before Music resigns: still visible")
    func musicResignsAfterMixerBecomesKey() {
        let service = PopupVisibilityService()
        service.setOpen(.music, true)
        service.setOpen(.mixer, true)
        service.setOpen(.music, false)
        #expect(service.isVisible)
    }

    @Test("the Mixer resigns first, then Music becomes key: visible at the end")
    func resignThenBecomeKey() {
        let service = PopupVisibilityService()
        service.setOpen(.mixer, true)
        service.setOpen(.mixer, false)
        service.setOpen(.music, true)
        #expect(service.isVisible)
    }

    @Test("both closed in either order is hidden")
    func bothClosed() {
        let first = PopupVisibilityService()
        first.setOpen(.mixer, true)
        first.setOpen(.music, true)
        first.setOpen(.mixer, false)
        first.setOpen(.music, false)
        #expect(first.isVisible == false)

        let second = PopupVisibilityService()
        second.setOpen(.mixer, true)
        second.setOpen(.music, true)
        second.setOpen(.music, false)
        second.setOpen(.mixer, false)
        #expect(second.isVisible == false)
    }

    @Test("a popup reported open twice closes with one report")
    func repeatedOpenCountsOnce() {
        let service = PopupVisibilityService()
        service.setOpen(.music, true)
        service.setOpen(.music, true)
        service.setOpen(.music, false)
        #expect(service.isVisible == false)
    }

    @Test("closing a popup that was never open changes nothing")
    func closeWithoutOpen() {
        let service = PopupVisibilityService()
        service.setOpen(.music, false)
        #expect(service.isVisible == false)

        service.setOpen(.mixer, true)
        service.setOpen(.music, false)
        #expect(service.isVisible)
    }

    @Test("the flag can still be written directly, as the HUD tests do")
    func directWrite() {
        let service = PopupVisibilityService()
        service.isVisible = true
        #expect(service.isVisible)
        service.isVisible = false
        #expect(service.isVisible == false)
    }

    // MARK: - Per-popup state

    /// Reads `read` once, and says whether `change` afterwards would redraw whoever read it.
    private func redraws(read: @MainActor () -> Void, after change: @MainActor () -> Void) -> Bool {
        let fired = Fired()
        withObservationTracking { read() } onChange: { fired.set() }
        change()
        return fired.value
    }

    @Test("no popup is open at launch", arguments: MenuBarItemID.allCases)
    func notOpenAtLaunch(id: MenuBarItemID) {
        #expect(PopupVisibilityService().isOpen(id) == false)
    }

    @Test("a popup reports only itself open", arguments: MenuBarItemID.allCases)
    func openIsPerPopup(id: MenuBarItemID) {
        let service = PopupVisibilityService()
        service.setOpen(id, true)
        for other in MenuBarItemID.allCases {
            #expect(service.isOpen(other) == (other == id))
        }
    }

    @Test("closing one popup leaves the other open", arguments: MenuBarItemID.allCases)
    func closeIsPerPopup(id: MenuBarItemID) {
        let service = PopupVisibilityService()
        for item in MenuBarItemID.allCases { service.setOpen(item, true) }
        service.setOpen(id, false)
        for other in MenuBarItemID.allCases {
            #expect(service.isOpen(other) == (other != id))
        }
    }

    @Test("opening a popup redraws a view that reads it", arguments: MenuBarItemID.allCases)
    func openRedrawsItsReader(id: MenuBarItemID) {
        let service = PopupVisibilityService()
        let drawn = redraws(read: { _ = service.isOpen(id) }, after: { service.setOpen(id, true) })
        #expect(drawn)
    }

    @Test("the other popup opening or closing does not redraw a view that reads this one", arguments: MenuBarItemID.allCases)
    func otherPopupDoesNotRedraw(id: MenuBarItemID) {
        let other = MenuBarItemID.allCases.first { $0 != id }!
        let service = PopupVisibilityService()
        let drawn = redraws(read: { _ = service.isOpen(id) }, after: { service.setOpen(other, true) })
        #expect(!drawn)
        let drawnAgain = redraws(read: { _ = service.isOpen(id) }, after: { service.setOpen(other, false) })
        #expect(!drawnAgain)
    }

    @Test("a repeated report redraws nobody", arguments: MenuBarItemID.allCases)
    func repeatedReportIsSilent(id: MenuBarItemID) {
        let service = PopupVisibilityService()
        service.setOpen(id, true)
        let drawn = redraws(read: { _ = service.isOpen(id); _ = service.isVisible }, after: { service.setOpen(id, true) })
        #expect(!drawn)

        let closed = PopupVisibilityService()
        let drawnAgain = redraws(read: { _ = closed.isOpen(id); _ = closed.isVisible }, after: { closed.setOpen(id, false) })
        #expect(!drawnAgain)
    }

    @Test("a second popup opening while one is open leaves the HUD flag alone")
    func secondPopupDoesNotRedrawVisible() {
        let service = PopupVisibilityService()
        service.setOpen(.mixer, true)
        let drawn = redraws(read: { _ = service.isVisible }, after: { service.setOpen(.music, true) })
        #expect(!drawn)
        let drawnAgain = redraws(read: { _ = service.isVisible }, after: { service.setOpen(.music, false) })
        #expect(!drawnAgain)
        #expect(service.isVisible)
    }
}
