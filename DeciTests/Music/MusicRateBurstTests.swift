// DeciTests/Music/MusicRateBurstTests.swift
// The like animation: the timeline of the thumb and its sparks at key times, which rating changes play it, which cut
// it short and which do not, where it plays (the popup's strip while the popup is open, the menu bar pill while it is
// not), how long the pill keeps the thumb, and what Reduce Motion leaves of it. Pure values and a few closures; nothing
// is drawn here.

import Foundation
import Testing
@testable import Deci

@Suite("Music rate burst timeline")
struct MusicRateBurstTimelineTests {
    private typealias Burst = MusicRateBurst

    private func frame(_ seconds: Double, _ kind: Burst.Kind = .like, reduceMotion: Bool = false) -> Burst.Frame {
        Burst.frame(at: seconds, kind: kind, reduceMotion: reduceMotion)
    }

    // MARK: - A like

    @Test("A like starts as the plain outline thumb at full size, with no sparks")
    func likeStart() {
        let start = frame(0)
        #expect(start.scale == 1)
        #expect(start.fill == 0)
        #expect(start.rotation == 0)
        #expect(start.sparks == nil)
    }

    @Test("The thumb collapses to a small filled blob within 100 ms")
    func likeCollapses() {
        let blob = frame(0.06)
        #expect(blob.scale == 0.3)
        #expect(blob.fill == 1)
        #expect(blob.sparks == nil)
        // Halfway through the collapse it is already shrinking, and still the outline.
        let falling = frame(0.015)
        #expect(falling.scale < 1)
        #expect(falling.scale > 0.3)
        #expect(falling.fill == 0)
        #expect(frame(0.099).scale == 0.3)
    }

    @Test("It pops back filled and a little oversized at about 130 ms, with the ring of sparks at its tightest")
    func likePops() throws {
        let pop = frame(0.133)
        #expect(pop.fill == 1)
        #expect(pop.scale > 1.05)
        #expect(pop.scale <= 1.2)
        let sparks = try #require(pop.sparks)
        #expect(sparks.opacity == 1)
        #expect(sparks.radius == 0.62)
        // Just before the pop there is still nothing to see of them.
        #expect(frame(0.12).sparks == nil)
    }

    @Test("The sparks move out and shrink from dashes to dots while the thumb settles to full size")
    func sparksTravel() throws {
        let early = try #require(frame(0.133).sparks)
        let middle = try #require(frame(0.23).sparks)
        let late = try #require(frame(0.33).sparks)
        #expect(early.radius < middle.radius)
        #expect(middle.radius < late.radius)
        #expect(early.dashLength > middle.dashLength)
        #expect(middle.dashLength > late.dashLength)
        #expect(late.dashLength < early.dashLength / 2)
        #expect(frame(0.33).scale == 1)
        #expect(frame(0.23).scale > 1)
        #expect(frame(0.23).scale < frame(0.133).scale)
    }

    @Test("The sparks hold until 370 ms, fade out by 570 ms and are gone after")
    func sparksFade() throws {
        #expect(try #require(frame(0.37).sparks).opacity == 1)
        let fading = try #require(frame(0.47).sparks)
        #expect(fading.opacity > 0)
        #expect(fading.opacity < 1)
        #expect(frame(0.57).sparks == nil)
        #expect(frame(0.8).sparks == nil)
    }

    @Test("The thumb tilts to about minus 12 degrees from 450 ms and is upright again by 850 ms")
    func likeWiggles() {
        #expect(frame(0.45).rotation == 0)
        #expect(frame(0.6).rotation == -12)
        let back = frame(0.72).rotation
        #expect(back < 0)
        #expect(back > -12)
        #expect(frame(0.85).rotation == 0)
        // Nothing else turns it.
        #expect(frame(0.3).rotation == 0)
    }

    @Test("A like settles filled at full size, upright, and stays so however long the clock runs")
    func likeSettles() {
        for seconds in [0.85, 0.9, 5, 1_000] {
            let settled = frame(seconds)
            #expect(settled.scale == 1)
            #expect(settled.fill == 1)
            #expect(settled.rotation == 0)
            #expect(settled.sparks == nil)
        }
        #expect(Burst.duration(of: .like, reduceMotion: false) == 0.85)
    }

    @Test("The sparks never reach further than the extent the pill is fitted to")
    func sparksStayInsideTheirExtent() {
        var seconds = 0.0
        while seconds <= 1 {
            if let sparks = frame(seconds).sparks {
                #expect(sparks.radius + max(sparks.dashLength, sparks.dotDiameter) / 2 <= Burst.sparkExtent)
            }
            seconds += 0.005
        }
    }

    // MARK: - A dislike

    @Test("A dislike collapses and pops to the filled thumb like a like does, and then rests: no wiggle")
    func dislikeShape() {
        for seconds in [0, 0.015, 0.06, 0.12, 0.133, 0.23, 0.33] {
            let like = frame(seconds, .like)
            let dislike = frame(seconds, .dislike)
            #expect(dislike.scale == like.scale)
            #expect(dislike.fill == like.fill)
        }
        for seconds in stride(from: 0.0, through: 1.2, by: 0.01) {
            #expect(frame(seconds, .dislike).rotation == 0)
        }
        #expect(Burst.duration(of: .dislike, reduceMotion: false) == 0.33)
    }

    @Test("A dislike has no sparks at any time")
    func dislikeHasNoSparks() {
        for seconds in stride(from: 0.0, through: 1.2, by: 0.005) {
            #expect(frame(seconds, .dislike).sparks == nil)
        }
        #expect(Burst.hasSparks(.like))
        #expect(!Burst.hasSparks(.dislike))
    }

    // MARK: - Odd clocks

    @Test("A time before the start, or one that is not a number, is the start")
    func oddClocks() {
        #expect(frame(-3) == frame(0))
        #expect(frame(.nan) == frame(0))
        #expect(frame(-.infinity) == frame(0))
        #expect(frame(.infinity) == frame(10))
    }

    // MARK: - Reduce Motion

    @Test("With Reduce Motion there is no collapse, no sparks and no wiggle: only a short fade to the filled thumb")
    func reduceMotion() {
        var seconds = 0.0
        while seconds <= 1 {
            for kind in [Burst.Kind.like, .dislike] {
                let reduced = frame(seconds, kind, reduceMotion: true)
                #expect(reduced.scale == 1)
                #expect(reduced.rotation == 0)
                #expect(reduced.sparks == nil)
            }
            seconds += 0.01
        }
        #expect(frame(0, reduceMotion: true).fill == 0)
        let halfway = frame(Burst.Metrics.reducedDuration / 2, reduceMotion: true).fill
        #expect(halfway > 0)
        #expect(halfway < 1)
        #expect(frame(Burst.Metrics.reducedDuration, reduceMotion: true).fill == 1)
        #expect(Burst.duration(of: .like, reduceMotion: true) == Burst.Metrics.reducedDuration)
        #expect(Burst.duration(of: .dislike, reduceMotion: true) == Burst.Metrics.reducedDuration)
        #expect(Burst.Metrics.reducedDuration <= 0.2)
    }

    // MARK: - What triggers it

    @Test("A like turning on plays the burst, from any earlier state, a dislike on the dislike one")
    func turningOnPlays() {
        for previous in [nil, .indifferent, .dislike] as [MusicLikeStatus?] {
            #expect(Burst.kind(from: previous, to: .like) == .like)
        }
        for previous in [nil, .indifferent, .like] as [MusicLikeStatus?] {
            #expect(Burst.kind(from: previous, to: .dislike) == .dislike)
        }
    }

    @Test("Taking a rating back plays nothing, and neither does sending the state a song already has")
    func removalAndRepeatPlayNothing() {
        for previous in [nil, .indifferent, .like, .dislike] as [MusicLikeStatus?] {
            #expect(Burst.kind(from: previous, to: .indifferent) == nil)
        }
        #expect(Burst.kind(from: .like, to: .like) == nil)
        #expect(Burst.kind(from: .dislike, to: .dislike) == nil)
    }

    // MARK: - What cuts it short

    @Test("Taking a like or a dislike back names the burst that was taken away, so it can be cut short")
    func takingBackNamesTheKind() {
        #expect(Burst.kindTakenBack(from: .like, to: .indifferent) == .like)
        #expect(Burst.kindTakenBack(from: .dislike, to: .indifferent) == .dislike)
    }

    @Test("Nothing is taken back from a song with no rating, or when the rating stays the same")
    func nothingToTakeBack() {
        for previous in [nil, .indifferent] as [MusicLikeStatus?] {
            for status in [.like, .dislike, .indifferent] as [MusicLikeStatus] {
                #expect(Burst.kindTakenBack(from: previous, to: status) == nil)
            }
        }
        #expect(Burst.kindTakenBack(from: .like, to: .like) == nil)
        #expect(Burst.kindTakenBack(from: .dislike, to: .dislike) == nil)
    }

    @Test("Switching between Like and Dislike takes nothing back: the new rating's own burst replaces the old one")
    func switchingTakesNothingBack() {
        #expect(Burst.kindTakenBack(from: .like, to: .dislike) == nil)
        #expect(Burst.kindTakenBack(from: .dislike, to: .like) == nil)
    }

    @Test("A change never plays a burst and cuts one short at once")
    func playAndCutShortExclude() {
        let states: [MusicLikeStatus?] = [nil, .indifferent, .like, .dislike]
        for previous in states {
            for status in [.like, .dislike, .indifferent] as [MusicLikeStatus] {
                #expect(Burst.kind(from: previous, to: status) == nil || Burst.kindTakenBack(from: previous, to: status) == nil)
            }
        }
    }

    // MARK: - Where it plays

    @Test("With the popup open the burst plays on the strip, with it closed or not key in the pill")
    func surfaceFollowsThePopup() {
        #expect(Burst.surface(popupIsOpen: true) == .strip)
        #expect(Burst.surface(popupIsOpen: false) == .pill)
    }

    // MARK: - The pill

    @Test("The pill keeps the filled thumb for 0.7 s after the animation, then gives the cover back")
    func pillHold() {
        #expect(Burst.Metrics.pillHold == 0.7)
        #expect(Burst.pillShownDuration(of: .like, reduceMotion: false) == 0.85 + 0.7)
        #expect(Burst.pillShownDuration(of: .dislike, reduceMotion: false) == 0.33 + 0.7)
        // With Reduce Motion the thumb still shows briefly, then the cover is back.
        #expect(Burst.pillShownDuration(of: .like, reduceMotion: true) == Burst.Metrics.reducedDuration + 0.7)
    }

    // MARK: - Fitting the sparks

    @Test("Sparks are scaled down until the whole burst fits the room it is given, and never scaled up")
    func sparkFit() {
        #expect(Burst.sparkScale(glyphSize: 12, reach: .infinity) == 1)
        #expect(Burst.sparkScale(glyphSize: 12, reach: 1_000) == 1)
        let pill = Burst.sparkScale(glyphSize: 11, reach: 11)
        #expect(pill < 1)
        #expect(pill > 0.5)
        // At that scale the sparks' outer end is inside the reach.
        #expect(pill * 11 * Burst.sparkExtent <= 11 + 0.0001)
        #expect(Burst.sparkScale(glyphSize: 0, reach: 11) == 1)
        #expect(Burst.sparkScale(glyphSize: 11, reach: 0) == 0)
    }
}

@MainActor
@Suite("Music rate burst center")
struct MusicRateBurstCenterTests {
    private let start = Date(timeIntervalSince1970: 1_000)

    /// What a test needs to see: the pill events and cancels, and the timers the center asked for.
    private final class Probe {
        var pillEvents: [MusicRateBurstCenter.Event] = []
        var pillCancels: [MusicRateBurst.Kind] = []
        var timers: [(delay: TimeInterval, work: @MainActor () -> Void)] = []
    }

    private func makeCenter(isOpen: Bool, reduceMotion: Bool = false) -> (MusicRateBurstCenter, Probe) {
        let probe = Probe()
        let center = MusicRateBurstCenter()
        center.isPopupOpen = { isOpen }
        center.reduceMotion = { reduceMotion }
        center.now = { [start] in start }
        center.schedule = { delay, work in probe.timers.append((delay, work)) }
        center.onPill = { probe.pillEvents.append($0) }
        center.onPillCancel = { probe.pillCancels.append($0) }
        return (center, probe)
    }

    @Test("With the popup open a like plays on the strip and the pill is not told")
    func openPlaysOnTheStrip() throws {
        let (center, probe) = makeCenter(isOpen: true)
        center.play(.like)
        let event = try #require(center.stripEvent)
        #expect(event.kind == .like)
        #expect(event.surface == .strip)
        #expect(event.startedAt == start)
        #expect(!event.reduceMotion)
        #expect(probe.pillEvents.isEmpty)
    }

    @Test("With the popup closed a like plays in the pill and the strip stays as it is")
    func closedPlaysInThePill() throws {
        let (center, probe) = makeCenter(isOpen: false)
        center.play(.like)
        #expect(center.stripEvent == nil)
        let event = try #require(probe.pillEvents.first)
        #expect(probe.pillEvents.count == 1)
        #expect(event.kind == .like)
        #expect(event.surface == .pill)
        #expect(event.startedAt == start)
    }

    @Test("A dislike is routed the same way, as a dislike")
    func dislikeRouting() throws {
        let (open, _) = makeCenter(isOpen: true)
        open.play(.dislike)
        #expect(open.stripEvent?.kind == .dislike)
        let (closed, probe) = makeCenter(isOpen: false)
        closed.play(.dislike)
        #expect(probe.pillEvents.map(\.kind) == [.dislike])
    }

    @Test("Reduce Motion is read when the burst starts and rides with the event")
    func reduceMotionRidesAlong() throws {
        let (center, probe) = makeCenter(isOpen: true, reduceMotion: true)
        center.play(.like)
        let event = try #require(center.stripEvent)
        #expect(event.reduceMotion)
        #expect(event.duration == MusicRateBurst.Metrics.reducedDuration)
        let (closed, closedProbe) = makeCenter(isOpen: false, reduceMotion: true)
        closed.play(.dislike)
        #expect(closedProbe.pillEvents.first?.reduceMotion == true)
        #expect(probe.pillEvents.isEmpty)
    }

    @Test("Every burst is a new event, so a second one restarts the animation")
    func eventsAreDistinct() throws {
        let (center, _) = makeCenter(isOpen: true)
        center.play(.like)
        let first = try #require(center.stripEvent)
        center.play(.like)
        let second = try #require(center.stripEvent)
        #expect(first.id != second.id)
        #expect(first != second)
    }

    @Test("A strip event removes itself after the animation and a short tail, and only its own")
    func stripEventEnds() throws {
        let (center, probe) = makeCenter(isOpen: true)
        center.play(.like)
        let first = try #require(center.stripEvent)
        #expect(probe.timers.count == 1)
        #expect(probe.timers[0].delay == first.duration + MusicRateBurst.Metrics.stripTail)
        // A newer burst replaced it: the first one's timer must not take the second away.
        center.play(.dislike)
        let second = try #require(center.stripEvent)
        probe.timers[0].work()
        #expect(center.stripEvent == second)
        probe.timers[1].work()
        #expect(center.stripEvent == nil)
    }

    @Test("A pill event needs no timer of the center's: the pill ends it itself")
    func pillEventSchedulesNothing() {
        let (center, probe) = makeCenter(isOpen: false)
        center.play(.like)
        #expect(probe.timers.isEmpty)
    }

    @Test("A burst for the pill with nobody to show it is dropped, and a strip one is not held for later")
    func noPillListener() {
        let (center, _) = makeCenter(isOpen: false)
        center.onPill = nil
        center.play(.like)
        #expect(center.stripEvent == nil)
    }

    // MARK: - Cutting a burst short

    @Test("Cancelling the kind the strip is showing takes its burst away at once, and the pill is told too")
    func cancelClearsTheStrip() {
        let (center, probe) = makeCenter(isOpen: true)
        center.play(.like)

        center.cancel(.like)

        #expect(center.stripEvent == nil)
        #expect(probe.pillCancels == [.like])
    }

    @Test("Cancelling the other kind leaves the strip's burst alone")
    func cancelOfAnotherKindKeepsTheStrip() throws {
        let (center, probe) = makeCenter(isOpen: true)
        center.play(.dislike)
        let event = try #require(center.stripEvent)

        center.cancel(.like)

        #expect(center.stripEvent == event)
        #expect(probe.pillCancels == [.like])
    }

    @Test("Cancelling with the popup closed tells the pill and has no strip burst to touch")
    func cancelWithThePopupClosed() {
        let (center, probe) = makeCenter(isOpen: false)
        center.play(.dislike)

        center.cancel(.dislike)

        #expect(center.stripEvent == nil)
        #expect(probe.pillEvents.map(\.kind) == [.dislike])
        #expect(probe.pillCancels == [.dislike])
    }

    @Test("Cancelling when nothing shows, or with nobody to show the pill's, is harmless")
    func cancelWithNothingShowing() {
        let (center, probe) = makeCenter(isOpen: true)
        center.cancel(.like)
        #expect(center.stripEvent == nil)
        #expect(probe.pillCancels == [.like])

        center.onPillCancel = nil
        center.cancel(.dislike)
        #expect(center.stripEvent == nil)
    }

    @Test("The timer of a cancelled strip burst does not take away the burst that came after it")
    func cancelledTimerLeavesTheNextBurst() throws {
        let (center, probe) = makeCenter(isOpen: true)
        center.play(.like)
        center.cancel(.like)
        center.play(.like)
        let second = try #require(center.stripEvent)

        probe.timers[0].work()

        #expect(center.stripEvent == second)
        probe.timers[1].work()
        #expect(center.stripEvent == nil)
    }
}
