// Deci/Music/Lyrics/LyricsFollowState.swift
import Foundation

/// The phases of a scroll view that matter here, so this file needs no UI framework: the view maps SwiftUI's
/// `ScrollPhase` onto it one to one.
enum LyricsScrollPhase: Sendable {
    /// At rest.
    case idle
    /// A finger or pointer is down on the scroll but has not moved it yet.
    case tracking
    /// Being dragged.
    case interacting
    /// Coasting after a fling.
    case decelerating
    /// Moved by the program: a scroll to a line.
    case animating
}

/// Whether the synced lyrics list follows the song or has been left where the user scrolled it. A scroll the user
/// drives (touching, dragging, coasting) pauses following; 3 seconds after that scroll goes idle it resumes and the
/// list glides back to the current line. The list's own animated scroll is not the user and never pauses anything,
/// and a seek (a tap on a line) resumes at once. Pure: the view feeds it scroll phases and reads the answers, and the
/// clock is injected so the wait can be tested without waiting.
struct LyricsFollowState: Sendable {
    /// How long the list stays where the user left it, counted from the moment their scroll goes idle.
    static let resumeDelay: TimeInterval = 3

    private enum Mode: Equatable, Sendable {
        /// The list moves with the song.
        case following
        /// The user has the scroll: no wait runs until it goes idle.
        case userScrolling
        /// The user let go: following resumes at this time.
        case waiting(until: Date)
    }

    private let now: @Sendable () -> Date
    private var mode = Mode.following
    private(set) var isGliding = false

    init(now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
    }

    /// True while a change of the current line should move the list.
    var isFollowing: Bool { mode == .following }

    /// When following resumes by itself; nil while following, and while the user's scroll is still going.
    var resumeAt: Date? {
        if case .waiting(let until) = mode { until } else { nil }
    }

    /// The list started its own glide to a line. The scroll view may report that move as a scroll of its own, so until
    /// the glide ends no phase counts: only the user's scroll pauses following, never the list's.
    mutating func glideStarted() {
        isGliding = true
    }

    /// The glide is over, finished or cancelled by the user's hand. The user's scroll that follows counts again.
    mutating func glideEnded() {
        isGliding = false
    }

    /// The scroll view's phase changed. Touching, dragging and coasting are the user: they pause (and drop any wait
    /// that was running); going idle after one starts the wait. The list's own animated scroll leaves the state alone,
    /// and so does any phase reported while the list glides.
    mutating func scrollPhaseChanged(_ phase: LyricsScrollPhase) {
        guard !isGliding else { return }
        switch phase {
        case .tracking, .interacting, .decelerating:
            mode = .userScrolling
        case .idle:
            if mode == .userScrolling {
                mode = .waiting(until: now().addingTimeInterval(Self.resumeDelay))
            }
        case .animating:
            break
        }
    }

    /// Follow again right now: a tap on a line seeks there, and a panel that shows again has no scroll left going, so
    /// the list has no reason to stay where it was left.
    mutating func resume() {
        mode = .following
    }

    /// Resumes if the wait is over. True only when it just did, so the caller glides back exactly once.
    mutating func resumeIfDue() -> Bool {
        guard case .waiting(let until) = mode, now() >= until else { return false }
        mode = .following
        return true
    }
}
