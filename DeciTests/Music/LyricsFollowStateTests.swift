// DeciTests/Music/LyricsFollowStateTests.swift
// Whether the lyrics list follows the song or has been left where the user scrolled it, on an injected clock.

import Foundation
import Testing
@testable import Deci

@Suite("Lyrics follow state")
struct LyricsFollowStateTests {

    private func make(_ clock: MutableClock = MutableClock()) -> (state: LyricsFollowState, clock: MutableClock) {
        (LyricsFollowState(now: { clock.now }), clock)
    }

    /// `resumeIfDue()` as a plain call that `#expect` can hold, since the call changes the state.
    private func resumes(_ state: inout LyricsFollowState) -> Bool {
        state.resumeIfDue()
    }

    // MARK: - Pausing

    @Test("A new list follows the song and has no wait pending")
    func startsFollowing() {
        let (state, _) = make()
        #expect(state.isFollowing)
        #expect(state.resumeAt == nil)
    }

    @Test("A scroll the user drives pauses following", arguments: [LyricsScrollPhase.tracking, .interacting, .decelerating])
    func userPhasePauses(phase: LyricsScrollPhase) {
        var (state, _) = make()
        state.scrollPhaseChanged(phase)
        #expect(!state.isFollowing)
    }

    @Test("The list's own animated scroll does not pause following")
    func animatingDoesNotPause() {
        var (state, _) = make()
        state.scrollPhaseChanged(.animating)
        #expect(state.isFollowing)
        state.scrollPhaseChanged(.idle)
        #expect(state.isFollowing)
        #expect(state.resumeAt == nil)
    }

    @Test("While the user's scroll is still going no wait is running, however long it takes")
    func noWaitWhileScrolling() {
        var (state, clock) = make()
        state.scrollPhaseChanged(.interacting)
        clock.advance(by: 60)
        #expect(state.resumeAt == nil)
        #expect(!resumes(&state))
        #expect(!state.isFollowing)
        state.scrollPhaseChanged(.decelerating)
        clock.advance(by: 60)
        #expect(!resumes(&state))
        #expect(!state.isFollowing)
    }

    // MARK: - Resuming

    @Test("The wait is 3 seconds")
    func delayIsThreeSeconds() {
        #expect(LyricsFollowState.resumeDelay == 3)
    }

    @Test("Following resumes 3 seconds after the user's scroll goes idle")
    func resumesAfterIdle() {
        var (state, clock) = make()
        state.scrollPhaseChanged(.interacting)
        state.scrollPhaseChanged(.decelerating)
        clock.advance(by: 10)
        let idleAt = clock.now
        state.scrollPhaseChanged(.idle)
        #expect(state.resumeAt == idleAt.addingTimeInterval(3))

        clock.advance(by: 2.9)
        #expect(!resumes(&state))
        #expect(!state.isFollowing)

        clock.advance(by: 0.2)
        #expect(resumes(&state))
        #expect(state.isFollowing)
        #expect(state.resumeAt == nil)
    }

    @Test("Resuming reports once: the caller glides back a single time")
    func resumeReportsOnce() {
        var (state, clock) = make()
        state.scrollPhaseChanged(.interacting)
        state.scrollPhaseChanged(.idle)
        clock.advance(by: 3)
        #expect(resumes(&state))
        #expect(!resumes(&state))
    }

    @Test("A list that was never paused has nothing to resume")
    func nothingToResume() {
        var (state, clock) = make()
        clock.advance(by: 60)
        #expect(!resumes(&state))
        #expect(state.isFollowing)
    }

    @Test("A new user scroll before the 3 seconds are up restarts the wait")
    func newScrollRestartsWait() {
        var (state, clock) = make()
        state.scrollPhaseChanged(.interacting)
        state.scrollPhaseChanged(.idle)
        clock.advance(by: 2)

        state.scrollPhaseChanged(.interacting)
        #expect(state.resumeAt == nil)
        clock.advance(by: 0.5)
        state.scrollPhaseChanged(.idle)
        #expect(state.resumeAt == clock.now.addingTimeInterval(3))

        // 3 seconds after the FIRST idle: still waiting, because the second scroll restarted the wait.
        clock.advance(by: 0.5)
        #expect(!resumes(&state))
        #expect(!state.isFollowing)

        clock.advance(by: 2.6)
        #expect(resumes(&state))
        #expect(state.isFollowing)
    }

    @Test("Coasting again during the wait drops it, and it starts over once that settles")
    func deceleratingDuringWait() {
        var (state, clock) = make()
        state.scrollPhaseChanged(.interacting)
        state.scrollPhaseChanged(.idle)
        #expect(state.resumeAt != nil)
        clock.advance(by: 1)

        state.scrollPhaseChanged(.decelerating)
        #expect(!state.isFollowing)
        #expect(state.resumeAt == nil)
        clock.advance(by: 60)
        #expect(!resumes(&state))

        state.scrollPhaseChanged(.idle)
        #expect(state.resumeAt == clock.now.addingTimeInterval(3))
        clock.advance(by: 3)
        #expect(resumes(&state))
    }

    @Test("The list's own animation during the wait neither restarts nor cancels it")
    func animatingDuringWait() {
        var (state, clock) = make()
        state.scrollPhaseChanged(.interacting)
        state.scrollPhaseChanged(.idle)
        let due = state.resumeAt
        clock.advance(by: 1)

        state.scrollPhaseChanged(.animating)
        state.scrollPhaseChanged(.idle)
        #expect(state.resumeAt == due)
        #expect(!state.isFollowing)

        clock.advance(by: 2.1)
        #expect(resumes(&state))
    }

    // MARK: - Seeking

    @Test("A seek resumes following at once, from a scroll still going and from a wait")
    func seekResumesAtOnce() {
        var (state, _) = make()
        state.scrollPhaseChanged(.interacting)
        state.resume()
        #expect(state.isFollowing)

        state.scrollPhaseChanged(.idle)
        state.scrollPhaseChanged(.interacting)
        state.scrollPhaseChanged(.idle)
        #expect(state.resumeAt != nil)
        state.resume()
        #expect(state.isFollowing)
        #expect(state.resumeAt == nil)
    }

    @Test("The idle that follows a seek starts no wait: nothing was paused")
    func idleAfterSeekStartsNoWait() {
        var (state, clock) = make()
        state.scrollPhaseChanged(.interacting)
        state.resume()
        state.scrollPhaseChanged(.idle)
        #expect(state.isFollowing)
        #expect(state.resumeAt == nil)
        clock.advance(by: 10)
        #expect(!resumes(&state))
    }

    @Test("After a seek the old wait is gone, and a later user scroll pauses again")
    func seekDropsTheWait() {
        var (state, clock) = make()
        state.scrollPhaseChanged(.interacting)
        state.scrollPhaseChanged(.idle)
        state.resume()
        clock.advance(by: 10)
        #expect(!resumes(&state))

        state.scrollPhaseChanged(.interacting)
        #expect(!state.isFollowing)
        state.scrollPhaseChanged(.idle)
        clock.advance(by: 2.9)
        #expect(!resumes(&state))
        clock.advance(by: 0.2)
        #expect(resumes(&state))
    }
}
