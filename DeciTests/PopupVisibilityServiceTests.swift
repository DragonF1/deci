// DeciTests/PopupVisibilityServiceTests.swift
// The HUD stays quiet while either popup is open. Swapping from one popup to the other resigns one
// window and makes the other key in an order nobody controls, so the flag must not depend on it.

import Testing
@testable import Deci

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
}
