// DeciTests/Music/MusicMarqueeTests.swift
// The Music popup's scrolling title and artist line. A SwiftUI TimelineView(.animation) there made the popup's whole
// window render and lay out on every display frame (120 a second) while a long title scrolled, and a nested hosting view
// whose frame a display link moved every frame still made the window resolve its tracking areas and set the cursor again
// every frame while the pointer was over the popup. The line is now a hosting view of its own that Core Animation slides
// on the render server. Covered: the path over time (hold, scroll, loop, pixel snap) and its keyframe list, the view
// (the slide and fade animations: keys, duration, hold, repeat and begin time; its frame, which does not change while it
// slides; its edge fade; where a click lands; that a window nobody can see removes all of it and that it starts again at
// the hold; that the display link runs only while the pointer is over a line with buttons in it), that the environment
// reaches the nested hosting view, and that the popup's window does not lay out for it.

import AppKit
import QuartzCore
import SwiftUI
import Testing
@testable import Deci

@Suite("MusicMarqueeMotion")
struct MusicMarqueeMotionTests {
    private let width = 200.0
    /// One loop: the hold and the scroll over the width and the gap.
    private var loop: Double { MusicChipMotion.marqueeHold + (width + MusicChipMotion.marqueeGap) / MusicChipMotion.marqueeSpeed }

    @Test("the line stands at its start for the hold, with no fade at the start")
    func hold() {
        for elapsed in [0.0, 0.5, 1.4] {
            let frame = MusicMarqueeMotion.frame(elapsed: elapsed, textWidth: width, scale: 2)
            #expect(frame == MusicMarqueeFrame(offset: 0, leadingFade: false))
        }
    }

    @Test("after the hold it scrolls left at the chip's speed, with the start fading")
    func scroll() {
        let frame = MusicMarqueeMotion.frame(elapsed: MusicChipMotion.marqueeHold + 2, textWidth: width, scale: 2)
        #expect(frame.offset == -2 * MusicChipMotion.marqueeSpeed)
        #expect(frame.leadingFade)
    }

    @Test("it never goes further than the line and the gap, and the next loop starts at the hold again")
    func distanceAndLoop() {
        let late = MusicMarqueeMotion.frame(elapsed: loop - 0.001, textWidth: width, scale: 2)
        #expect(late.offset <= -(width + MusicChipMotion.marqueeGap) + 0.1)
        #expect(late.offset >= -(width + MusicChipMotion.marqueeGap))
        let wrapped = MusicMarqueeMotion.frame(elapsed: loop + 0.5, textWidth: width, scale: 2)
        #expect(wrapped == MusicMarqueeFrame(offset: 0, leadingFade: false))
    }

    @Test("it has no rest: the tenth loop reads as the first")
    func noRest() {
        let tenth = MusicMarqueeMotion.frame(elapsed: 10 * loop + MusicChipMotion.marqueeHold + 2, textWidth: width, scale: 2)
        #expect(tenth.offset == -2 * MusicChipMotion.marqueeSpeed)
    }

    @Test("the offset sits on a whole device pixel")
    func snapsToPixels() {
        for scale in [1.0, 2.0, 3.0] {
            for step in 0..<200 {
                let elapsed = MusicChipMotion.marqueeHold + Double(step) * 0.037
                let offset = MusicMarqueeMotion.frame(elapsed: elapsed, textWidth: width, scale: scale).offset
                let pixels = offset * scale
                #expect(abs(pixels - pixels.rounded()) < 1e-9)
            }
        }
    }

    @Test("a start is a plain zero, never a negative zero")
    func plainZero() {
        let frame = MusicMarqueeMotion.frame(elapsed: MusicChipMotion.marqueeHold + 0.001, textWidth: width, scale: 2)
        #expect(frame.offset == 0 && frame.offset.sign == .plus)
        #expect(!frame.leadingFade)
    }

    @Test("a time that is not a number, or before the start, leaves the line at its start")
    func oddTimes() {
        for elapsed in [-5.0, .nan, .infinity, -.infinity] {
            #expect(MusicMarqueeMotion.frame(elapsed: elapsed, textWidth: width, scale: 2).offset == 0)
        }
    }

    @Test("a scale that is not usable reads as one pixel to the point")
    func oddScale() {
        let offset = MusicMarqueeMotion.frame(elapsed: MusicChipMotion.marqueeHold + 2.02, textWidth: width, scale: 0).offset
        #expect(offset == offset.rounded())
    }

    @Test("the keyframe list is one loop long, with a value for every device pixel of the scroll")
    func loopList() {
        for scale in [1.0, 2.0, 3.0] {
            let list = MusicMarqueeMotion.loop(textWidth: width, scale: scale)
            #expect(list.duration == loop)
            #expect(list.offsets.count == Int((loop * MusicChipMotion.marqueeSpeed * scale).rounded(.up)))
            // The list is the path itself, sampled at the start of each part.
            let step = list.duration / Double(list.offsets.count)
            for (index, offset) in list.offsets.enumerated() {
                let expected = MusicMarqueeMotion.frame(elapsed: Double(index) * step, textWidth: width, scale: scale).offset
                #expect(offset == expected)
            }
        }
    }

    @Test("the keyframe list stands still for the hold, then only moves left, to just short of the second copy")
    func loopShape() {
        let list = MusicMarqueeMotion.loop(textWidth: width, scale: 2)
        let step = list.duration / Double(list.offsets.count)
        let held = list.offsets.prefix(while: { $0 == 0 }).count
        // The hold is 1.5 s: the list holds for that long (the first pixel of the scroll rounds to nothing, which adds a
        // hundredth of a second), to within a part.
        #expect(abs(Double(held) * step - MusicChipMotion.marqueeHold) <= step + 0.011)
        for index in 1..<list.offsets.count { #expect(list.offsets[index] <= list.offsets[index - 1]) }
        let last = list.offsets.last ?? 0
        #expect(last <= -(width + MusicChipMotion.marqueeGap) + 0.6)
        #expect(last >= -(width + MusicChipMotion.marqueeGap))
        for offset in list.offsets { #expect(abs(offset * 2 - (offset * 2).rounded()) < 1e-9) }
    }

    @Test("a width or scale that is not usable still gives a loop")
    func loopOddInput() {
        for (text, scale) in [(0.0, 2.0), (.nan, 2.0), (-5.0, 0.0), (200.0, .nan)] {
            let list = MusicMarqueeMotion.loop(textWidth: text, scale: scale)
            #expect(list.duration.isFinite && list.duration > MusicChipMotion.marqueeHold)
            #expect(!list.offsets.isEmpty)
            #expect(list.offsets.allSatisfy { $0.isFinite && $0 <= 0 })
        }
    }

    @Test("the mask's colours: the end always fades, the start fades only when asked")
    func fadeColors() {
        #expect(MusicMarqueeMotion.fadeColors(leading: false).map(\.alpha) == [1, 1, 1, 0])
        #expect(MusicMarqueeMotion.fadeColors(leading: true).map(\.alpha) == [0, 1, 1, 0])
    }

    @Test("the track holds two copies and the gap, rounded up")
    func trackWidth() {
        #expect(MusicMarqueeMotion.trackWidth(textWidth: 200) == 424)
        #expect(MusicMarqueeMotion.trackWidth(textWidth: 200.2) == 425)
        #expect(MusicMarqueeMotion.trackWidth(textWidth: -3) == MusicChipMotion.marqueeGap)
        #expect(MusicMarqueeMotion.trackWidth(textWidth: .nan) == MusicChipMotion.marqueeGap)
    }
}

@MainActor
@Suite("MusicMarqueeView")
struct MusicMarqueeViewTests {
    private static let textWidth = 200.0

    /// A marquee 100 wide and 20 high over a plain hosted view that holds a 30 wide "button" 100 points in.
    private func makeView(interactive: Bool = true) -> (view: MusicMarqueeView, button: NSView) {
        let hosted = NSView(frame: .zero)
        let button = NSView(frame: NSRect(x: 100, y: 0, width: 30, height: 20))
        hosted.addSubview(button)
        let view = MusicMarqueeView(hosted: hosted, isInteractive: interactive)
        view.setFrameSize(NSSize(width: 100, height: 20))
        view.configure(textWidth: Self.textWidth)
        view.restart(at: 100)
        return (view, button)
    }

    private var scrolling: Double { 100 + MusicChipMotion.marqueeHold + 2 }

    private func fadeAlphas(_ view: MusicMarqueeView) -> [CGFloat] {
        let colors = (view.layer?.mask as? CAGradientLayer)?.colors as? [CGColor] ?? []
        return colors.map(\.alpha)
    }

    @Test("the hosting view is as wide as both copies and the gap, as high as the window, and starts at the left")
    func parts() {
        let (view, _) = makeView()
        #expect(view.hosted.frame == CGRect(x: 0, y: 0, width: 424, height: 20))
        #expect(view.shown == MusicMarqueeFrame(offset: 0, leadingFade: false))
    }

    @Test("a step in the scroll moves the hosting view to the offset")
    func moves() {
        let (view, _) = makeView()
        view.advance(at: scrolling)
        let x = Double(view.hosted.frame.origin.x)
        #expect(x == -2 * MusicChipMotion.marqueeSpeed)
        #expect(view.hosted.frame.origin.y == 0)
        #expect(view.hosted.frame.width == 424)
    }

    @Test("a step that lands on the picture already shown writes nothing")
    func unchangedStepsAreFree() {
        let (view, _) = makeView()
        let before = view.moves
        for time in [100.1, 100.5, 101.0, 101.4] { view.advance(at: time) }
        #expect(view.moves == before)
        view.advance(at: scrolling)
        let scrolled = view.moves
        view.advance(at: scrolling)
        #expect(view.moves == scrolled)
        #expect(scrolled == before + 1)
    }

    @Test("the end of the window always fades, and the start fades once the line is off it")
    func fade() {
        let (view, _) = makeView()
        #expect(fadeAlphas(view) == [1, 1, 1, 0])
        view.advance(at: scrolling)
        #expect(fadeAlphas(view) == [0, 1, 1, 0])
        // Back at the start of the next loop.
        let loop = MusicChipMotion.marqueeHold + (Self.textWidth + MusicChipMotion.marqueeGap) / MusicChipMotion.marqueeSpeed
        view.advance(at: 100 + loop + 0.2)
        #expect(fadeAlphas(view) == [1, 1, 1, 0])
    }

    @Test("the fade is ten points at each edge and follows the window's width")
    func fadeLocations() {
        let (view, _) = makeView()
        let gradient = view.layer?.mask as? CAGradientLayer
        let first = (gradient?.locations ?? []).map(\.doubleValue)
        #expect(first == MusicChipMotion.edgeFadeLocations(windowWidth: 100))
        #expect(gradient?.frame == CGRect(x: 0, y: 0, width: 100, height: 20))
        view.setFrameSize(NSSize(width: 250, height: 22))
        let second = (gradient?.locations ?? []).map(\.doubleValue)
        #expect(second == MusicChipMotion.edgeFadeLocations(windowWidth: 250))
        #expect(gradient?.frame == CGRect(x: 0, y: 0, width: 250, height: 22))
        #expect(view.hosted.frame.height == 22)
    }

    @Test("a new width begins the marquee again at its hold; the same width leaves it going")
    func newWidthRestarts() {
        let (view, _) = makeView()
        view.advance(at: scrolling)
        let moved = view.moves
        view.configure(textWidth: Self.textWidth)
        #expect(view.moves == moved)
        #expect(view.shown?.offset == -2 * MusicChipMotion.marqueeSpeed)
        view.configure(textWidth: 300)
        #expect(view.shown == MusicMarqueeFrame(offset: 0, leadingFade: false))
        let width = Double(view.hosted.frame.width)
        #expect(width == MusicMarqueeMotion.trackWidth(textWidth: 300))
    }

    @Test("a line with nothing to click lets every click through")
    func plainLineTakesNoClicks() {
        let (view, _) = makeView(interactive: false)
        #expect(view.hitTest(NSPoint(x: 10, y: 10)) == nil)
    }

    @Test("a click lands on the name where it shows, also after the line has moved")
    func clicksFollowTheLine() {
        let (view, button) = makeView()
        // At the start the name is at 100...130, past the 100 wide window: nothing there.
        #expect(view.hitTest(NSPoint(x: 50, y: 10)) === view.hosted)
        // Scrolled 50 to the left, the name stands at 50...80.
        view.advance(at: scrolling)
        #expect(view.hitTest(NSPoint(x: 60, y: 10)) === button)
        #expect(view.hitTest(NSPoint(x: 90, y: 10)) === view.hosted)
        // Scrolled 150: the name stands at -50...-20, out of the window.
        view.advance(at: 100 + MusicChipMotion.marqueeHold + 6)
        #expect(view.hitTest(NSPoint(x: 10, y: 10)) !== button)
    }

    // MARK: - The animation, in a window

    /// Whether the test's window counts as one that can be seen, and where the pointer is.
    private final class Stage {
        var showing = true
        var pointer = NSPoint(x: -500, y: -500)
    }

    /// A marquee 100 by 20 at the window's lower left, in a window that is not on screen, with the stage deciding
    /// whether the window counts as seen and where the pointer is. `show` puts it in the window, which starts it.
    private func stage(
        interactive: Bool = true, showing: Bool = true, in stageState: Stage = Stage()
    ) -> (view: MusicMarqueeView, window: NSWindow, stage: Stage, show: () -> Void) {
        stageState.showing = showing
        let (view, _) = makeView(interactive: interactive)
        view.frame = NSRect(x: 0, y: 0, width: 100, height: 20)
        view.windowIsShowing = { [stageState] _ in stageState.showing }
        view.pointerLocation = { [stageState] _ in stageState.pointer }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 20), styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        return (view, window, stageState, { window.contentView?.addSubview(view) })
    }

    private func close(_ window: NSWindow) {
        window.contentView = nil
        window.close()
    }

    private func numbers(_ values: [Any]?) -> [Double] {
        (values as? [NSNumber])?.map(\.doubleValue) ?? []
    }

    @Test("in a window that can be seen the line slides by one discrete animation that repeats for ever and holds first")
    func slideAnimationSetup() throws {
        let (view, window, _, show) = stage()
        defer { close(window) }
        show()
        #expect(view.motion == .animating)
        #expect(!view.isLinked)
        let slide = try #require(view.slideAnimation)
        let scale = Double(window.backingScaleFactor)
        let duration = MusicChipMotion.marqueeHold + (Self.textWidth + MusicChipMotion.marqueeGap) / MusicChipMotion.marqueeSpeed
        #expect(slide.keyPath == "transform.translation.x")
        #expect(slide.calculationMode == .discrete)
        #expect(slide.duration == duration)
        #expect(slide.repeatCount == .infinity)
        #expect(slide.isRemovedOnCompletion == false)
        let values = numbers(slide.values)
        #expect(values == MusicMarqueeMotion.loop(textWidth: Self.textWidth, scale: scale).offsets)
        // Held for the hold: the leading zeros last 1.5 s, to within a part and the first pixel's rounding.
        let step = duration / Double(values.count)
        let held = values.prefix(while: { $0 == 0 }).count
        #expect(abs(Double(held) * step - MusicChipMotion.marqueeHold) <= step + 0.5 / (scale * MusicChipMotion.marqueeSpeed) + 1e-9)
        // A part is under a device pixel of the scroll.
        #expect(step * MusicChipMotion.marqueeSpeed * scale <= 1 + 1e-9)
    }

    @Test("the fade is one colour animation on the mask with the chip's key times, as long as the slide")
    func fadeAnimationSetup() throws {
        let (view, window, _, show) = stage()
        defer { close(window) }
        show()
        let slide = try #require(view.slideAnimation)
        let fade = try #require(view.fadeAnimation)
        #expect(fade.keyPath == "colors")
        #expect(fade.duration == slide.duration)
        #expect(fade.repeatCount == .infinity)
        #expect(fade.isRemovedOnCompletion == false)
        #expect(fade.beginTime == slide.beginTime)
        #expect(fade.calculationMode == .linear)
        #expect(numbers(fade.keyTimes) == MusicChipMotion.edgeFadeKeyTimes(textWidth: Self.textWidth))
        let stops = try #require(fade.values as? [[CGColor]])
        #expect(stops.map { $0.map(\.alpha) } == [[1, 1, 1, 0], [1, 1, 1, 0], [0, 1, 1, 0], [0, 1, 1, 0], [1, 1, 1, 0]])
        // The first part of the loop holds with no fade at the start; the scroll's fade is in for most of it.
        let times = numbers(fade.keyTimes)
        #expect(times.first == 0 && times.last == 1)
        #expect(abs(times[1] * slide.duration - MusicChipMotion.marqueeHold) < 1e-9)
    }

    @Test("the animations begin when the marquee began, on the media clock, so the hold is the first 1.5 s")
    func beginTime() throws {
        let (view, window, _, show) = stage()
        defer { close(window) }
        show()
        let begin = try #require(view.slideAnimation).beginTime
        let layer = try #require(view.hosted.layer)
        #expect(begin == layer.convertTime(view.startedAt, from: nil))
        // Restarting at a time puts the animation's begin there.
        view.restart(at: CACurrentMediaTime() - 3)
        let again = try #require(view.slideAnimation).beginTime
        #expect(again == layer.convertTime(view.startedAt, from: nil))
        #expect(again < begin)
    }

    @Test("the model place of the hosting view does not move while it slides, and nothing is counted as a move")
    func modelFrameStaysPut() {
        let (view, window, _, show) = stage()
        defer { close(window) }
        show()
        let frame = view.hosted.frame
        let moves = view.moves
        view.syncMotion()
        view.syncMotion()
        #expect(view.hosted.frame == frame)
        #expect(view.moves == moves)
        #expect(frame.origin.x == 0)
        // Restarting mid-scroll moves the animation's begin, not the frame.
        view.restart(at: CACurrentMediaTime() - (MusicChipMotion.marqueeHold + 2))
        #expect(view.hosted.frame.origin.x == 0)
        #expect(view.moves == moves)
    }

    @Test("a new width replaces the animations with ones for that width")
    func newWidthRetimes() throws {
        let (view, window, _, show) = stage()
        defer { close(window) }
        show()
        let before = try #require(view.slideAnimation).duration
        view.configure(textWidth: 400)
        let slide = try #require(view.slideAnimation)
        #expect(slide.duration == MusicChipMotion.marqueeHold + (400 + MusicChipMotion.marqueeGap) / MusicChipMotion.marqueeSpeed)
        #expect(slide.duration > before)
        #expect(try #require(view.fadeAnimation).duration == slide.duration)
        let width = Double(view.hosted.frame.width)
        #expect(width == MusicMarqueeMotion.trackWidth(textWidth: 400))
    }

    @Test("a view that is not in a window has no animation and no display link")
    func noWindowNoMotion() {
        let (view, window, _, _) = stage()
        defer { close(window) }
        #expect(view.motion == .idle)
        #expect(view.slideAnimation == nil && view.fadeAnimation == nil)
        #expect(!view.isLinked)
    }

    @Test("leaving the window removes the animations and the line goes back to its start")
    func leavingTheWindow() {
        let (view, window, _, show) = stage()
        defer { close(window) }
        show()
        #expect(view.slideAnimation != nil)
        view.removeFromSuperview()
        #expect(view.motion == .idle)
        #expect(view.slideAnimation == nil && view.fadeAnimation == nil)
        #expect(!view.isLinked)
        #expect(view.hosted.frame.origin.x == 0)
        #expect(fadeAlphas(view) == [1, 1, 1, 0])
    }

    @Test("a window nobody can see starts nothing, and it starts when the window is seen")
    func hiddenWindowStartsNothing() {
        let (view, window, state, show) = stage(showing: false)
        defer { close(window) }
        show()
        #expect(view.motion == .idle)
        #expect(view.slideAnimation == nil && view.fadeAnimation == nil)
        #expect(!view.isLinked)

        state.showing = true
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        #expect(view.motion == .animating)
        #expect(view.slideAnimation != nil && view.fadeAnimation != nil)
    }

    @Test("a window that is ordered out or covered removes the animations, whatever the view tree says")
    func hidingStops() {
        let (view, window, state, show) = stage()
        defer { close(window) }
        show()
        #expect(view.motion == .animating)

        state.showing = false
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        #expect(view.motion == .idle)
        #expect(view.slideAnimation == nil && view.fadeAnimation == nil)
        #expect(!view.isLinked)
        #expect(view.hosted.frame.origin.x == 0)
    }

    @Test("a window that is closing stops the motion even if it still reports as seen")
    func closingStops() {
        let (view, window, _, show) = stage()
        defer { close(window) }
        show()
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
        #expect(view.motion == .idle)
        #expect(view.slideAnimation == nil)
    }

    @Test("an update from the view tree puts the motion right when the window changed without a notice")
    func syncCatchesUp() {
        let (view, window, state, show) = stage()
        defer { close(window) }
        show()
        state.showing = false
        view.syncMotion()
        #expect(view.motion == .idle)
        state.showing = true
        view.syncMotion()
        #expect(view.motion == .animating)
    }

    @Test("it starts again at the hold when the window is seen again, not where it left off")
    func restartsAtTheHold() throws {
        let (view, window, state, show) = stage()
        defer { close(window) }
        show()
        view.restart(at: 0.5)
        state.showing = false
        view.syncMotion()
        state.showing = true
        view.syncMotion()
        #expect(view.startedAt > 1)
        let slide = try #require(view.slideAnimation)
        let layer = try #require(view.hosted.layer)
        #expect(slide.beginTime == layer.convertTime(view.startedAt, from: nil))
        #expect(abs(view.startedAt - CACurrentMediaTime()) < 1)
    }

    // MARK: - The pointer

    @Test("the pointer over a line with buttons in it moves the line by frame on a display link, with no animation")
    func hoverSteps() throws {
        let (view, window, _, show) = stage()
        defer { close(window) }
        show()
        #expect(view.motion == .animating)
        view.restart(at: CACurrentMediaTime() - (MusicChipMotion.marqueeHold + 2))
        view.setPointerInside(true)
        #expect(view.motion == .stepping)
        #expect(view.isLinked)
        #expect(view.slideAnimation == nil && view.fadeAnimation == nil)
        // The line is where the slide had it, so its buttons are where they show.
        let x = Double(view.hosted.frame.origin.x)
        #expect(abs(x - -2 * MusicChipMotion.marqueeSpeed) <= 2 * MusicChipMotion.marqueeSpeed * 0.1 + 1)
        #expect(view.shown?.offset == x)
        #expect(fadeAlphas(view) == [0, 1, 1, 0])

        // A step moves it on.
        let before = view.moves
        view.step(at: CACurrentMediaTime() + 1)
        #expect(view.moves == before + 1)
        #expect(Double(view.hosted.frame.origin.x) < x)
    }

    @Test("the pointer leaving gives the line back to the render server, from the same place in its path")
    func hoverEnds() throws {
        let (view, window, _, show) = stage()
        defer { close(window) }
        show()
        view.restart(at: CACurrentMediaTime() - (MusicChipMotion.marqueeHold + 2))
        let started = view.startedAt
        view.setPointerInside(true)
        view.setPointerInside(false)
        #expect(view.motion == .animating)
        #expect(!view.isLinked)
        #expect(view.slideAnimation != nil && view.fadeAnimation != nil)
        #expect(view.hosted.frame.origin.x == 0)
        #expect(view.startedAt == started)
        let layer = try #require(view.hosted.layer)
        #expect(try #require(view.slideAnimation).beginTime == layer.convertTime(started, from: nil))
    }

    @Test("a line with nothing to click ignores the pointer, and keeps sliding")
    func plainLineIgnoresThePointer() {
        let (view, window, _, show) = stage(interactive: false)
        defer { close(window) }
        show()
        view.setPointerInside(true)
        #expect(!view.pointerInside)
        #expect(view.motion == .animating)
        #expect(!view.isLinked)
        #expect(view.slideAnimation != nil)
    }

    @Test("the pointer already over the line when it starts makes it step from the start")
    func pointerAlreadyThere() {
        let state = Stage()
        state.pointer = NSPoint(x: 10, y: 10)
        let (view, window, _, show) = stage(in: state)
        defer { close(window) }
        show()
        #expect(view.pointerInside)
        #expect(view.motion == .stepping)
        #expect(view.isLinked)
        #expect(view.slideAnimation == nil)
    }

    @Test("a pointer that left without a notice lets the display link go within a few steps")
    func lostExitStopsStepping() {
        let state = Stage()
        state.pointer = NSPoint(x: 10, y: 10)
        let (view, window, _, show) = stage(in: state)
        defer { close(window) }
        show()
        #expect(view.motion == .stepping)
        state.pointer = NSPoint(x: 500, y: 500)
        for _ in 0..<MusicMarqueeView.pointerCheckInterval { view.step(at: CACurrentMediaTime()) }
        #expect(view.motion == .animating)
        #expect(!view.isLinked)
        #expect(view.slideAnimation != nil)
    }

    @Test("a step in a window that cannot be seen stops the display link")
    func steppingStopsWhenHidden() {
        let state = Stage()
        state.pointer = NSPoint(x: 10, y: 10)
        let (view, window, _, show) = stage(in: state)
        defer { close(window) }
        show()
        #expect(view.isLinked)
        state.showing = false
        view.step(at: CACurrentMediaTime())
        #expect(view.motion == .idle)
        #expect(!view.isLinked)
    }

    @Test("a step does nothing when the line is not stepping")
    func stepOutsideSteppingIsFree() {
        let (view, window, _, show) = stage()
        defer { close(window) }
        show()
        let moves = view.moves
        view.step(at: CACurrentMediaTime() + 5)
        #expect(view.moves == moves)
        #expect(view.motion == .animating)
    }

    @Test("dismantling stops everything")
    func dismantle() {
        let state = Stage()
        state.pointer = NSPoint(x: 10, y: 10)
        let (view, window, _, show) = stage(in: state)
        defer { close(window) }
        show()
        #expect(view.isLinked)
        MusicMarqueeTrack<Text>.dismantleNSView(view, coordinator: MusicMarqueeTrack<Text>.Coordinator())
        #expect(view.motion == .idle)
        #expect(!view.isLinked)
        #expect(view.slideAnimation == nil)
    }
}

/// Reads what a line sees of the environment, to tell whether the nested hosting view got it.
private struct EnvironmentReader: View {
    final class Sink {
        var terms: [String]?
        var opensArtist: Bool?
        var popupIsVisible: Bool?
        var layoutDirection: LayoutDirection?
    }

    let sink: Sink
    @Environment(\.musicHighlightTerms) private var terms
    @Environment(\.openMusicArtist) private var openArtist
    @Environment(\.musicPopupIsVisible) private var popupIsVisible
    @Environment(\.layoutDirection) private var layoutDirection

    var body: some View {
        sink.terms = terms
        sink.opensArtist = openArtist != nil
        sink.popupIsVisible = popupIsVisible
        sink.layoutDirection = layoutDirection
        return Text(verbatim: "line")
    }
}

/// A hosting view that counts how often its window lays it out.
final class LayoutCountingHostingView<Root: View>: NSHostingView<Root> {
    var layouts = 0

    override func layout() {
        layouts += 1
        super.layout()
    }
}

@MainActor
@Suite("MusicMarquee in SwiftUI")
struct MusicMarqueeIntegrationTests {
    @Test("the nested hosting view sees the environment the marquee sits in")
    func environmentReachesTheNestedView() async throws {
        var environment = EnvironmentValues()
        environment.musicHighlightTerms = ["abc"]
        environment.openMusicArtist = { _ in }
        environment.musicPopupIsVisible = true
        environment.layoutDirection = .rightToLeft
        let sink = EnvironmentReader.Sink()
        let hosting = NSHostingView(rootView: MusicMarqueeRow(content: EnvironmentReader(sink: sink), environment: environment))
        hosting.frame = NSRect(x: 0, y: 0, width: 200, height: 20)
        hosting.layoutSubtreeIfNeeded()
        _ = hosting.fittingSize
        #expect(sink.terms == ["abc"])
        #expect(sink.opensArtist == true)
        #expect(sink.popupIsVisible == true)
        #expect(sink.layoutDirection == .rightToLeft)
    }

    @Test("a host that does not hand the environment over leaves the line with the defaults")
    func plainHostingViewHasDefaults() {
        let sink = EnvironmentReader.Sink()
        let hosting = NSHostingView(rootView: EnvironmentReader(sink: sink))
        hosting.frame = NSRect(x: 0, y: 0, width: 200, height: 20)
        hosting.layoutSubtreeIfNeeded()
        _ = hosting.fittingSize
        #expect(sink.terms == [])
        #expect(sink.opensArtist == false)
    }

    private func findMarquee(in view: NSView) -> MusicMarqueeView? {
        if let found = view as? MusicMarqueeView { return found }
        for subview in view.subviews {
            if let found = findMarquee(in: subview) { return found }
        }
        return nil
    }

    private func show(_ hosting: NSView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 200, height: 60), styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.collectionBehavior = [.transient, .ignoresCycle, .stationary]
        window.contentView = hosting
        window.orderFrontRegardless()
        return window
    }

    private static let title = "A very long song title that cannot possibly fit in the column of the player"

    private func root(visible: Bool, interactive: Bool = true) -> AnyView {
        AnyView(
            VStack(alignment: .leading) {
                MusicMarquee(isPlaying: true, isInteractive: interactive) {
                    Text(Self.title).font(.system(size: 13)).lineLimit(1)
                }
                .frame(width: 120, height: 20)
            }
            .environment(\.musicPopupIsVisible, visible)
        )
    }

    @Test("a long title slides on the render server: no display link, no frame change, no layout of the popup's window")
    func scrollsWithoutLayouts() async throws {
        let hosting = LayoutCountingHostingView(rootView: root(visible: true))
        let window = show(hosting)
        defer {
            window.contentView = nil
            window.close()
        }

        try await Task.sleep(for: .milliseconds(500))
        let marquee = try #require(findMarquee(in: hosting))
        #expect(marquee.isAnimating)
        #expect(!marquee.isLinked)
        #expect(marquee.hosted.frame.width > 240)
        #expect(marquee.hosted.frame.origin.x == 0)
        let frame = marquee.hosted.frame
        let outer = marquee.frame

        // Past the hold the line is on its way, and nothing about any view's geometry or the window's layout changes.
        try await Task.sleep(for: .milliseconds(1_300))
        let layoutsBefore = hosting.layouts
        let movesBefore = marquee.moves
        try await Task.sleep(for: .seconds(1))
        let layouts = hosting.layouts - layoutsBefore
        #expect(layouts < 5)
        #expect(marquee.moves == movesBefore)
        #expect(marquee.hosted.frame == frame)
        #expect(marquee.frame == outer)
        let presentation = try #require(marquee.hosted.layer?.presentation())
        let shown = try #require(presentation.value(forKeyPath: "transform.translation.x") as? Double)
        // Where the path puts the line now (the discrete list is spread evenly over the loop, as the path is): within a
        // few points, which is the clock moving between the two reads.
        let scale = Double(window.backingScaleFactor)
        let expected = MusicMarqueeMotion.frame(
            elapsed: CACurrentMediaTime() - marquee.startedAt, textWidth: Double(marquee.hosted.frame.width - 24) / 2, scale: scale
        ).offset
        #expect(shown < -10)
        #expect(abs(shown - expected) <= 4)
        // The start of the window fades while the line is off it: the mask's first colour is clear, as animated.
        let mask = try #require(marquee.layer?.mask?.presentation() as? CAGradientLayer)
        let alphas = (mask.colors as? [CGColor] ?? []).map(\.alpha)
        #expect(alphas == [0, 1, 1, 0])
    }

    @Test("the popup closing removes the motion, and opening it again starts it again at the hold")
    func popupVisibilityGatesTheMotion() async throws {
        let hosting = NSHostingView(rootView: root(visible: true))
        let window = show(hosting)
        defer {
            window.contentView = nil
            window.close()
        }
        try await Task.sleep(for: .milliseconds(500))
        let first = try #require(findMarquee(in: hosting))
        #expect(first.isAnimating)

        hosting.rootView = root(visible: false)
        try await Task.sleep(for: .milliseconds(300))
        #expect(findMarquee(in: hosting) == nil)
        #expect(first.motion == .idle)
        #expect(first.slideAnimation == nil && first.fadeAnimation == nil)
        #expect(!first.isLinked)

        hosting.rootView = root(visible: true)
        try await Task.sleep(for: .milliseconds(300))
        let second = try #require(findMarquee(in: hosting))
        #expect(second.isAnimating)
        #expect(second.slideAnimation != nil)
        #expect(abs(second.startedAt - CACurrentMediaTime()) < 1)
    }

    @Test("a window that is ordered out stops the motion although the view tree still says visible, and ordering it in starts it")
    func orderingOutStops() async throws {
        let hosting = NSHostingView(rootView: root(visible: true))
        let window = show(hosting)
        defer {
            window.contentView = nil
            window.close()
        }
        try await Task.sleep(for: .milliseconds(500))
        let marquee = try #require(findMarquee(in: hosting))
        #expect(marquee.isAnimating)
        // The default predicate must count a window that is ordered in as seen.
        #expect(marquee.windowIsShowing(window))

        window.orderOut(nil)
        try await Task.sleep(for: .milliseconds(500))
        #expect(!marquee.windowIsShowing(window))
        #expect(marquee.motion == .idle)
        #expect(marquee.slideAnimation == nil && marquee.fadeAnimation == nil)
        #expect(!marquee.isLinked)

        window.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(500))
        #expect(marquee.isAnimating)
        #expect(marquee.slideAnimation != nil)
    }
}
