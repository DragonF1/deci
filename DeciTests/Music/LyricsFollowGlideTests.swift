// DeciTests/Music/LyricsFollowGlideTests.swift
// The list's own glide moves the real scroll view, and the scroll view may report that as a scroll. It must never pause
// following; only the user's scroll does.

import Foundation
import Testing
@testable import Deci

@Suite("Lyrics follow state: the list's own glide")
struct LyricsFollowGlideTests {

    private func make(_ clock: MutableClock = MutableClock()) -> (state: LyricsFollowState, clock: MutableClock) {
        (LyricsFollowState(now: { clock.now }), clock)
    }

    @Test("A new list is not gliding")
    func startsNotGliding() {
        let (state, _) = make()
        #expect(!state.isGliding)
    }

    @Test("Gliding is on between the start and the end of a glide")
    func startAndEnd() {
        var (state, _) = make()
        state.glideStarted()
        #expect(state.isGliding)
        state.glideEnded()
        #expect(!state.isGliding)
    }

    @Test("A scroll phase reported during a glide is the glide's, not the user's", arguments: [
        LyricsScrollPhase.tracking, .interacting, .decelerating, .animating, .idle,
    ])
    func phasesDuringAGlideAreIgnored(phase: LyricsScrollPhase) {
        var (state, _) = make()
        state.glideStarted()
        state.scrollPhaseChanged(phase)
        #expect(state.isFollowing)
        #expect(state.resumeAt == nil)
    }

    @Test("Once the glide has ended the same phases are the user again")
    func phasesAfterAGlideCount() {
        var (state, _) = make()
        state.glideStarted()
        state.glideEnded()
        state.scrollPhaseChanged(.interacting)
        #expect(!state.isFollowing)
    }

    @Test("A user who grabs the scroll mid glide: the glide is cancelled first, so the scroll that follows pauses")
    func userCancelsTheGlide() {
        var (state, clock) = make()
        state.glideStarted()
        state.glideEnded()
        state.scrollPhaseChanged(.tracking)
        state.scrollPhaseChanged(.interacting)
        #expect(!state.isFollowing)
        state.scrollPhaseChanged(.idle)
        #expect(state.resumeAt == clock.now.addingTimeInterval(LyricsFollowState.resumeDelay))
    }

    @Test("Ending a glide that never started changes nothing")
    func endWithoutStart() {
        var (state, _) = make()
        state.glideEnded()
        #expect(!state.isGliding)
        #expect(state.isFollowing)
    }

    @Test("Starting a glide twice is one glide: a single end finishes it")
    func startTwice() {
        var (state, _) = make()
        state.glideStarted()
        state.glideStarted()
        state.glideEnded()
        #expect(!state.isGliding)
    }

    @Test("A glide does not disturb a wait that is running")
    func glideDuringWait() {
        var (state, clock) = make()
        state.scrollPhaseChanged(.interacting)
        state.scrollPhaseChanged(.idle)
        let due = state.resumeAt
        clock.advance(by: 1)
        state.glideStarted()
        state.scrollPhaseChanged(.idle)
        state.glideEnded()
        #expect(state.resumeAt == due)
        #expect(!state.isFollowing)
    }

    @Test("Resuming after the wait, then gliding back, leaves the list following")
    func glideBackAfterResume() {
        var (state, clock) = make()
        state.scrollPhaseChanged(.interacting)
        state.scrollPhaseChanged(.idle)
        clock.advance(by: LyricsFollowState.resumeDelay)
        let resumed = state.resumeIfDue()
        #expect(resumed)
        state.glideStarted()
        state.scrollPhaseChanged(.interacting)
        state.glideEnded()
        #expect(state.isFollowing)
        #expect(state.resumeAt == nil)
    }
}
