// Deci/Music/MusicRateBurstCenter.swift
import AppKit
import Observation

/// Decides where the like animation plays and hands it there. A rating of the song playing now that turns Like or
/// Dislike on calls `play`. With the Music popup open (on screen and key, the rule the outcome reporter uses) the
/// animation is the popup's: `stripEvent` is set and the player column's strip draws it on the button. With the popup
/// closed, or open but not key, it is the menu bar pill's: `onPill` is told, and the chip controller shows it in the
/// cover's place. Taking the rating back calls `playRemoval`: with the pill the surface it is told to show the outline
/// thumb, replacing a burst that still shows; with the popup open it cuts the burst short on both surfaces, as `cancel`
/// does (the strip's icon shows the song's state). One lives on the `MusicServiceHost`, so it exists before the service
/// does.
@MainActor
@Observable
final class MusicRateBurstCenter {
    /// One animation to play: which button turned on, where, and when it began.
    struct Event: Equatable, Identifiable, Sendable {
        /// Distinct for every burst, so two in a row each restart the animation.
        let id: Int
        let kind: MusicRateBurst.Kind
        let surface: MusicRateBurst.Surface
        /// Reduce Motion as it was when the burst began: a fade to the filled icon and nothing else.
        let reduceMotion: Bool
        let startedAt: Date
        /// Whether this shows a Like or a Dislike being taken back: the outline thumb, with no sparks, instead of the
        /// burst of one turning on. Only the pill shows one.
        var isRemoval = false

        /// How long the animation itself runs.
        var duration: TimeInterval {
            MusicRateBurst.duration(of: kind, reduceMotion: reduceMotion, isRemoval: isRemoval)
        }
    }

    /// The burst the popup's strip is showing; nil when there is none. It removes itself a moment after the animation.
    private(set) var stripEvent: Event?

    /// Whether the Music popup is open. Set where the popup opener is made.
    @ObservationIgnored var isPopupOpen: @MainActor () -> Bool = { false }
    @ObservationIgnored var reduceMotion: @MainActor () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    @ObservationIgnored var now: () -> Date = Date.init
    /// Runs `work` after `delay` seconds. A test replaces it, to hold the clock.
    @ObservationIgnored var schedule: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void = { delay, work in
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            work()
        }
    }
    /// Shows a burst or a removal in the menu bar pill. nil while there is no pill (the Icon style, or no song), and it is
    /// then dropped: there is nothing to show it on.
    @ObservationIgnored var onPill: (@MainActor (Event) -> Void)?
    /// Cuts the pill's burst or removal short when it is of the kind given: the rating that turned it on was taken back,
    /// or the removal of it did not go through. nil while there is no pill.
    @ObservationIgnored var onPillCancel: (@MainActor (MusicRateBurst.Kind) -> Void)?

    @ObservationIgnored private var lastID = 0

    /// Plays the burst for a Like or a Dislike that has just turned on, where the user is looking.
    func play(_ kind: MusicRateBurst.Kind) {
        lastID += 1
        let surface = MusicRateBurst.surface(popupIsOpen: isPopupOpen())
        let event = Event(id: lastID, kind: kind, surface: surface, reduceMotion: reduceMotion(), startedAt: now())
        switch surface {
        case .strip:
            stripEvent = event
            let id = event.id
            schedule(event.duration + MusicRateBurst.Metrics.stripTail) { [weak self] in self?.finish(id) }
        case .pill:
            onPill?(event)
        }
    }

    /// Shows the Like or the Dislike of `kind` being taken back, where the user is looking. With the popup closed, or open
    /// but not key, the pill is told to show the removal, which replaces any burst or removal it shows; a leftover strip
    /// burst of that kind goes. With the popup open this is `cancel`: the strip's burst of that kind is cut short and
    /// its icon shows the song's state, and the pill is told to cut short a burst that began while the popup was closed.
    func playRemoval(of kind: MusicRateBurst.Kind) {
        switch MusicRateBurst.surface(popupIsOpen: isPopupOpen()) {
        case .strip:
            cancel(kind)
        case .pill:
            if stripEvent?.kind == kind { stripEvent = nil }
            lastID += 1
            let event = Event(id: lastID, kind: kind, surface: .pill, reduceMotion: reduceMotion(), startedAt: now(), isRemoval: true)
            onPill?(event)
        }
    }

    /// Cuts the burst of `kind` short, for a rating that was taken back while it plays: the strip's goes at once and the
    /// pill is told. A burst of the other kind stays.
    func cancel(_ kind: MusicRateBurst.Kind) {
        if stripEvent?.kind == kind { stripEvent = nil }
        onPillCancel?(kind)
    }

    /// Takes the strip's burst away once it is over. A newer burst that replaced it stays.
    func finish(_ id: Int) {
        guard stripEvent?.id == id else { return }
        stripEvent = nil
    }
}
