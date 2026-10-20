// DeciTests/Music/MusicCardHoverTests.swift
// When the hover card shows and hides: the mouse resting on the chip, moving into the card, leaving both, and the
// things that close it at once. The state machine is pure; the controller only runs the timers it asks for.

import CoreGraphics
import Foundation
import Testing
@testable import Deci

@Suite("Music hover card state")
struct MusicCardHoverTests {
    private func eligible() -> MusicCardHover {
        var hover = MusicCardHover()
        _ = hover.handle(.eligibilityChanged(true))
        return hover
    }

    /// The chip hovered long enough for the card to be up.
    private func shown() -> MusicCardHover {
        var hover = eligible()
        _ = hover.handle(.chipEntered)
        _ = hover.handle(.showDelayElapsed)
        return hover
    }

    @Test("the delays are a quarter second to show and a third of a second to hide")
    func delays() {
        #expect(MusicCardHover.showDelay == 0.25)
        #expect(MusicCardHover.hideGrace == 0.3)
    }

    @Test("a fresh machine is hidden and asks for nothing")
    func startsHidden() {
        let hover = MusicCardHover()
        #expect(hover.phase == .hidden)
        #expect(hover.isCardVisible == false)
    }

    @Test("the mouse entering the chip starts the show delay")
    func enterStartsDelay() {
        var hover = eligible()
        #expect(hover.handle(.chipEntered) == [.startShowTimer])
        #expect(hover.phase == .waitingToShow)
        #expect(hover.isCardVisible == false)
    }

    @Test("the delay running out with the mouse still on the chip shows the card")
    func delayShows() {
        var hover = eligible()
        _ = hover.handle(.chipEntered)
        #expect(hover.handle(.showDelayElapsed) == [.showCard])
        #expect(hover.phase == .shown)
        #expect(hover.isCardVisible)
    }

    @Test("leaving before the delay runs out cancels it, and a late timer does nothing")
    func leaveBeforeDelay() {
        var hover = eligible()
        _ = hover.handle(.chipEntered)
        #expect(hover.handle(.chipExited) == [.cancelShowTimer])
        #expect(hover.phase == .hidden)
        #expect(hover.handle(.showDelayElapsed).isEmpty)
        #expect(hover.phase == .hidden)
    }

    @Test("entering again while the card is up asks for nothing more")
    func enterWhileShown() {
        var hover = shown()
        #expect(hover.handle(.chipEntered).isEmpty)
        #expect(hover.phase == .shown)
    }

    @Test("leaving the chip into the card keeps it open")
    func chipIntoCard() {
        var hover = shown()
        #expect(hover.handle(.chipExited) == [.startHideTimer])
        #expect(hover.phase == .waitingToHide)
        #expect(hover.isCardVisible)
        #expect(hover.handle(.cardEntered) == [.cancelHideTimer])
        #expect(hover.phase == .shown)
        #expect(hover.handle(.hideGraceElapsed).isEmpty)
        #expect(hover.phase == .shown)
    }

    @Test("leaving the card back onto the chip keeps it open")
    func cardBackToChip() {
        var hover = shown()
        _ = hover.handle(.chipExited)
        _ = hover.handle(.cardEntered)
        #expect(hover.handle(.cardExited) == [.startHideTimer])
        #expect(hover.handle(.chipEntered) == [.cancelHideTimer])
        #expect(hover.phase == .shown)
        #expect(hover.handle(.hideGraceElapsed).isEmpty)
        #expect(hover.isCardVisible)
    }

    @Test("leaving the chip while already over the card starts no hide")
    func chipExitedWhileOverCard() {
        var hover = shown()
        _ = hover.handle(.cardEntered)
        #expect(hover.handle(.chipExited).isEmpty)
        #expect(hover.phase == .shown)
    }

    @Test("leaving both hides the card once the grace has passed")
    func leaveBothHides() {
        var hover = shown()
        #expect(hover.handle(.chipExited) == [.startHideTimer])
        #expect(hover.handle(.hideGraceElapsed) == [.hideCard])
        #expect(hover.phase == .hidden)
        #expect(hover.isCardVisible == false)
    }

    @Test("leaving the card for open space hides it after the grace")
    func leaveCardHides() {
        var hover = shown()
        _ = hover.handle(.chipExited)
        _ = hover.handle(.cardEntered)
        #expect(hover.handle(.cardExited) == [.startHideTimer])
        #expect(hover.handle(.hideGraceElapsed) == [.hideCard])
        #expect(hover.phase == .hidden)
    }

    @Test("coming back to the chip during the grace keeps the card")
    func returnDuringGrace() {
        var hover = shown()
        _ = hover.handle(.chipExited)
        #expect(hover.handle(.chipEntered) == [.cancelHideTimer])
        #expect(hover.phase == .shown)
        #expect(hover.handle(.hideGraceElapsed).isEmpty)
    }

    @Test("a grace timer that fires while hidden does nothing")
    func staleGrace() {
        var hover = eligible()
        #expect(hover.handle(.hideGraceElapsed).isEmpty)
        #expect(hover.phase == .hidden)
    }

    // MARK: - Closing at once

    @Test("a click closes a card that is up at once, with no grace")
    func clickHidesShown() {
        var hover = shown()
        #expect(hover.handle(.clicked) == [.hideCard])
        #expect(hover.phase == .hidden)
    }

    @Test("a click while the card is still waiting for its delay cancels the delay")
    func clickCancelsDelay() {
        var hover = eligible()
        _ = hover.handle(.chipEntered)
        #expect(hover.handle(.clicked) == [.cancelShowTimer])
        #expect(hover.phase == .hidden)
        #expect(hover.handle(.showDelayElapsed).isEmpty)
    }

    @Test("a click during the grace cancels the grace and hides the card")
    func clickDuringGrace() {
        var hover = shown()
        _ = hover.handle(.chipExited)
        #expect(hover.handle(.clicked) == [.cancelHideTimer, .hideCard])
        #expect(hover.phase == .hidden)
    }

    @Test("a click with the card hidden asks for nothing")
    func clickWhenHidden() {
        var hover = eligible()
        #expect(hover.handle(.clicked).isEmpty)
    }

    @Test("the full popover opening hides the card at once")
    func popoverOpenHides() {
        var hover = shown()
        #expect(hover.handle(.popoverOpened) == [.hideCard])
        #expect(hover.phase == .hidden)
    }

    @Test("the track clearing hides the card at once")
    func trackClearedHides() {
        var hover = shown()
        #expect(hover.handle(.eligibilityChanged(false)) == [.hideCard])
        #expect(hover.phase == .hidden)
    }

    @Test("switching to the icon, or hiding the item, closes a card waiting to hide too")
    func ineligibleDuringGrace() {
        var hover = shown()
        _ = hover.handle(.chipExited)
        #expect(hover.handle(.eligibilityChanged(false)) == [.cancelHideTimer, .hideCard])
        #expect(hover.phase == .hidden)
    }

    @Test("becoming ineligible while the card waits for its delay cancels the delay")
    func ineligibleDuringDelay() {
        var hover = eligible()
        _ = hover.handle(.chipEntered)
        #expect(hover.handle(.eligibilityChanged(false)) == [.cancelShowTimer])
        #expect(hover.handle(.showDelayElapsed).isEmpty)
    }

    // MARK: - Never while it must not show

    @Test("the card never starts while the full popover is open")
    func blockedWhilePopoverOpen() {
        var hover = eligible()
        _ = hover.handle(.popoverOpened)
        #expect(hover.handle(.chipEntered).isEmpty)
        #expect(hover.phase == .hidden)
        #expect(hover.handle(.showDelayElapsed).isEmpty)
    }

    @Test("after the popover closes the next hover works, and the one that was on the chip does not pop up by itself")
    func afterPopoverCloses() {
        var hover = eligible()
        _ = hover.handle(.chipEntered)
        _ = hover.handle(.popoverOpened)
        #expect(hover.handle(.popoverClosed).isEmpty)
        #expect(hover.phase == .hidden)
        _ = hover.handle(.chipExited)
        #expect(hover.handle(.chipEntered) == [.startShowTimer])
    }

    @Test("a chip that is not eligible never starts the delay")
    func notEligible() {
        var hover = MusicCardHover()
        #expect(hover.handle(.chipEntered).isEmpty)
        #expect(hover.phase == .hidden)
        _ = hover.handle(.chipExited)
        _ = hover.handle(.eligibilityChanged(true))
        #expect(hover.handle(.chipEntered) == [.startShowTimer])
    }

    @Test("a delay that fires after the mouse left the chip shows nothing")
    func delayWithMouseGone() {
        var hover = eligible()
        _ = hover.handle(.chipEntered)
        _ = hover.handle(.chipExited)
        _ = hover.handle(.chipEntered)
        _ = hover.handle(.chipExited)
        #expect(hover.handle(.showDelayElapsed).isEmpty)
        #expect(hover.phase == .hidden)
    }

    @Test("the card forgets the mouse when it goes away, so it opens normally next time")
    func forgetsCardMouse() {
        var hover = shown()
        _ = hover.handle(.chipExited)
        _ = hover.handle(.cardEntered)
        _ = hover.handle(.clicked)
        _ = hover.handle(.chipEntered)
        #expect(hover.phase == .waitingToShow)
        _ = hover.handle(.showDelayElapsed)
        #expect(hover.handle(.chipExited) == [.startHideTimer])
    }

    // MARK: - A mouse that is not really on the card

    @Test("a card that reports the mouse after it is gone leaves nothing behind: the next card still hides")
    func staleCardEnterDoesNotPinTheNextCard() {
        var hover = eligible()
        _ = hover.handle(.chipEntered)
        _ = hover.handle(.showDelayElapsed)
        _ = hover.handle(.chipExited)
        #expect(hover.handle(.hideGraceElapsed) == [.hideCard])
        // The mouse lands on the card while it fades; it goes off screen under the cursor, so no exit arrives.
        #expect(hover.handle(.cardEntered).isEmpty)
        #expect(hover.isOverCard == false)
        _ = hover.handle(.chipEntered)
        #expect(hover.handle(.showDelayElapsed) == [.showCard])
        #expect(hover.handle(.chipExited) == [.startHideTimer])
        #expect(hover.phase == .waitingToHide)
        #expect(hover.handle(.hideGraceElapsed) == [.hideCard])
        #expect(hover.phase == .hidden)
    }

    @Test("the mouse entering the card while it is hidden, or waiting for its delay, is not remembered")
    func cardEnterWhenNotUp() {
        var hover = eligible()
        #expect(hover.handle(.cardEntered).isEmpty)
        #expect(hover.isOverCard == false)
        _ = hover.handle(.chipEntered)
        #expect(hover.phase == .waitingToShow)
        #expect(hover.handle(.cardEntered).isEmpty)
        #expect(hover.isOverCard == false)
        #expect(hover.phase == .waitingToShow)
    }

    @Test("the mouse entering the card while it is up is remembered, and its exit lets the grace start")
    func cardEnterWhenUp() {
        var hover = shown()
        #expect(hover.handle(.cardEntered).isEmpty)
        #expect(hover.isOverCard)
        _ = hover.handle(.chipExited)
        #expect(hover.phase == .shown)
        #expect(hover.handle(.cardExited) == [.startHideTimer])
    }

    @Test("a card that opens starts with the mouse off it")
    func cardOpensWithMouseOff() {
        var hover = shown()
        #expect(hover.isOverCard == false)
        _ = hover.handle(.cardEntered)
        _ = hover.handle(.clicked)
        _ = hover.handle(.chipEntered)
        _ = hover.handle(.showDelayElapsed)
        #expect(hover.isOverCard == false)
    }

    // MARK: - Exits that may have been lost

    @Test("an exit lost on the chip is made up when the mouse is found elsewhere")
    func reconcileChip() {
        let hover = shown()
        #expect(hover.exitsToReconcile(mouseOverChip: false, mouseOverCard: false) == [.chipExited])
        #expect(hover.exitsToReconcile(mouseOverChip: true, mouseOverCard: false).isEmpty)
        #expect(hover.exitsToReconcile(mouseOverChip: false, mouseOverCard: true) == [.chipExited])
    }

    @Test("an exit lost on the card is made up when the mouse is found elsewhere")
    func reconcileCard() {
        var hover = shown()
        _ = hover.handle(.chipExited)
        _ = hover.handle(.cardEntered)
        #expect(hover.exitsToReconcile(mouseOverChip: false, mouseOverCard: false) == [.cardExited])
        #expect(hover.exitsToReconcile(mouseOverChip: false, mouseOverCard: true).isEmpty)
    }

    @Test("feeding the made up exits lets the card go after the grace")
    func reconcileHides() {
        var hover = shown()
        for event in hover.exitsToReconcile(mouseOverChip: false, mouseOverCard: false) {
            _ = hover.handle(event)
        }
        #expect(hover.phase == .waitingToHide)
        #expect(hover.handle(.hideGraceElapsed) == [.hideCard])
    }

    @Test("a mouse the machine already places nowhere needs no correction")
    func reconcileNothingToDo() {
        var hover = shown()
        _ = hover.handle(.chipExited)
        #expect(hover.exitsToReconcile(mouseOverChip: false, mouseOverCard: false).isEmpty)
        #expect(eligible().exitsToReconcile(mouseOverChip: false, mouseOverCard: false).isEmpty)
    }
}
