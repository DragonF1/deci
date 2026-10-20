// Deci/Views/MenuBar/MusicCardHover.swift
// When the hover card shows and hides. A pure state machine: the controller feeds it what the mouse and the popup do,
// and runs the timers and the panel it asks for, so every rule here is unit tested without a window or a clock.

import Foundation

/// The mouse resting on the chip for `showDelay` shows the card. The card stays while the mouse is over the chip or over
/// the card, and goes `hideGrace` after it has left both. A click on the item, the full popover opening, the song
/// clearing and the style or visibility changing close it at once. While the popover is open nothing starts.
nonisolated struct MusicCardHover: Equatable, Sendable {
    /// How long the mouse rests on the chip before the card appears, and how long after leaving both before it goes.
    static let showDelay: TimeInterval = 0.25
    static let hideGrace: TimeInterval = 0.3

    enum Phase: Equatable, Sendable {
        case hidden
        /// The mouse is on the chip and the show delay runs.
        case waitingToShow
        case shown
        /// The card is up, the mouse is on neither part, and the grace runs.
        case waitingToHide
    }

    enum Event: Equatable, Sendable {
        case chipEntered
        case chipExited
        case cardEntered
        case cardExited
        case showDelayElapsed
        case hideGraceElapsed
        /// The item was clicked.
        case clicked
        /// The full Music popover opened, or closed.
        case popoverOpened
        case popoverClosed
        /// Whether the chip is on offer at all: chip style, item shown, a song loaded.
        case eligibilityChanged(Bool)
    }

    /// What the controller does about an event.
    enum Effect: Equatable, Sendable {
        case startShowTimer
        case cancelShowTimer
        case startHideTimer
        case cancelHideTimer
        case showCard
        case hideCard
    }

    private(set) var phase: Phase = .hidden
    private(set) var isOverChip = false
    private(set) var isOverCard = false
    private(set) var isEligible: Bool
    private(set) var isPopoverOpen = false

    init(isEligible: Bool = false) {
        self.isEligible = isEligible
    }

    /// The card is on screen (or fading out for the grace).
    var isCardVisible: Bool {
        phase == .shown || phase == .waitingToHide
    }

    /// Takes one event and answers with what to do about it. Timer events that arrive after their timer was cancelled
    /// (or after the state moved on) answer nothing.
    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .chipEntered:
            isOverChip = true
            switch phase {
            case .hidden:
                guard isEligible, !isPopoverOpen else { return [] }
                phase = .waitingToShow
                return [.startShowTimer]
            case .waitingToHide:
                phase = .shown
                return [.cancelHideTimer]
            case .waitingToShow, .shown:
                return []
            }

        case .chipExited:
            isOverChip = false
            switch phase {
            case .waitingToShow:
                phase = .hidden
                return [.cancelShowTimer]
            case .shown where !isOverCard:
                phase = .waitingToHide
                return [.startHideTimer]
            case .hidden, .shown, .waitingToHide:
                return []
            }

        case .cardEntered:
            // Only a card that is up can have the mouse on it. A card that is gone, or fading out, can still report an
            // enter; it goes off screen under the cursor, so the exit that would undo it never comes.
            guard phase == .shown || phase == .waitingToHide else { return [] }
            isOverCard = true
            guard phase == .waitingToHide else { return [] }
            phase = .shown
            return [.cancelHideTimer]

        case .cardExited:
            isOverCard = false
            guard phase == .shown, !isOverChip else { return [] }
            phase = .waitingToHide
            return [.startHideTimer]

        case .showDelayElapsed:
            guard phase == .waitingToShow, isOverChip, isEligible, !isPopoverOpen else { return [] }
            phase = .shown
            // The card is only now appearing: the mouse is not on it yet.
            isOverCard = false
            return [.showCard]

        case .hideGraceElapsed:
            guard phase == .waitingToHide, !isOverChip, !isOverCard else { return [] }
            phase = .hidden
            isOverCard = false
            return [.hideCard]

        case .clicked:
            return closeNow()

        case .popoverOpened:
            isPopoverOpen = true
            return closeNow()

        case .popoverClosed:
            // The mouse may still be on the chip: the card waits for the next time it comes in.
            isPopoverOpen = false
            return []

        case .eligibilityChanged(let eligible):
            isEligible = eligible
            return eligible ? [] : closeNow()
        }
    }

    /// The exits to feed in once the mouse's true place is known, for when an exit may have been lost (a Space change
    /// can swallow a mouseExited): one for each part the machine thinks the mouse is on and it is not.
    func exitsToReconcile(mouseOverChip: Bool, mouseOverCard: Bool) -> [Event] {
        var events: [Event] = []
        if isOverChip, !mouseOverChip { events.append(.chipExited) }
        if isOverCard, !mouseOverCard { events.append(.cardExited) }
        return events
    }

    /// Back to hidden with no grace, undoing whatever timer or card is up. The mouse's place on the chip stays; the
    /// card is gone, so the mouse is no longer on it.
    private mutating func closeNow() -> [Effect] {
        let effects: [Effect]
        switch phase {
        case .hidden: effects = []
        case .waitingToShow: effects = [.cancelShowTimer]
        case .shown: effects = [.hideCard]
        case .waitingToHide: effects = [.cancelHideTimer, .hideCard]
        }
        phase = .hidden
        isOverCard = false
        return effects
    }
}
