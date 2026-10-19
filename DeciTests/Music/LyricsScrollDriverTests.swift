// DeciTests/Music/LyricsScrollDriverTests.swift
// The lyrics list's scroll driver against a real SwiftUI ScrollView: the probe finds the NSScrollView, the rows report
// their frames, and a scroll moves the clip view to where the geometry says. The window is built but never ordered
// front, so nothing shows on screen. The tests give the main actor back while they wait: the animation's completion
// is queued on it.

import AppKit
import SwiftUI
import Testing
@testable import Deci

private let rowCount = 40
private let viewport = CGSize(width: 320, height: 360)

@MainActor
private final class Rig {
    let window: NSWindow
    let driver = LyricsScrollDriver()
    private(set) var started = 0
    private(set) var ended = 0

    init() {
        let host = NSHostingView(rootView: SampleList(driver: driver))
        window = NSWindow(contentRect: NSRect(origin: .zero, size: viewport), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: viewport)
        // Weak: a glide that outlives a test (its watchdog or completion still queued) must not reach a rig that is gone.
        driver.glideChanged = { [weak self] gliding in
            guard let self else { return }
            if gliding { started += 1 } else { ended += 1 }
        }
    }

    /// Lets SwiftUI lay out and report geometry, and the animations run, without showing anything.
    func settle(_ seconds: TimeInterval = 0.3) async {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            window.contentView?.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// A rig whose rows have reported their frames.
    static func ready() async -> Rig {
        let rig = Rig()
        await rig.settle(0.1)
        // The last row reports last. A busy machine takes longer to get there, and that is all it changes.
        let begin = Date()
        while rig.driver.frame(ofRow: rowCount - 1) == nil || rig.scrollView == nil, Date().timeIntervalSince(begin) < 20 {
            await rig.settle(0.05)
        }
        await rig.settle(0.05)
        return rig
    }

    var scrollView: NSScrollView? { driver.scrollView }
    var clip: NSClipView? { scrollView?.contentView }
    var originY: CGFloat { clip?.bounds.origin.y ?? -1 }

    /// The origin every `step` seconds for `seconds`.
    func sample(_ seconds: TimeInterval, every step: TimeInterval = 0.03) async -> [CGFloat] {
        var values: [CGFloat] = []
        let begin = Date()
        while Date().timeIntervalSince(begin) < seconds {
            try? await Task.sleep(for: .seconds(step))
            values.append(originY)
        }
        return values
    }

    /// The origin on every poll until the glide is over, so a busy machine only makes this longer, never wrong. The
    /// main actor is shared with the other tests, so the wait is generous.
    func sampleUntilGlideEnds(timeout: TimeInterval = 20) async -> [CGFloat] {
        var values: [CGFloat] = []
        let begin = Date()
        var last = begin
        while driver.isGliding, Date().timeIntervalSince(begin) < timeout {
            try? await Task.sleep(for: .milliseconds(10))
            let now = Date()
            longestStall = max(longestStall, now.timeIntervalSince(last))
            last = now
            values.append(originY)
        }
        return values
    }

    /// The longest the main actor went without getting back to the wait loop. The animator steps on the main thread, so a
    /// stall while the glide ran (another test holding the thread) means steps were skipped, not that the glide was bad.
    private(set) var longestStall: TimeInterval = 0

    /// Starts recording the clip view's origin on every step the animator takes, so the count of steps does not depend
    /// on how often the test gets the main actor back. Call before the glide; read `steps` after.
    func recordSteps() {
        guard let clip, stepObserver == nil else { return }
        stepObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: clip, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Each step is reported twice, once as the animator set it and once snapped to a whole point: one step.
                let whole = self.originY.rounded()
                guard self.steps.last != whole else { return }
                self.steps.append(whole)
            }
        }
    }

    private(set) var steps: [CGFloat] = []
    private var stepObserver: NSObjectProtocol?

    isolated deinit {
        if let stepObserver { NotificationCenter.default.removeObserver(stepObserver) }
    }

    /// Waits until a glide has visibly started moving (or is over), so a test can step in mid-glide however busy the
    /// machine is.
    func waitUntilMoving(beyond y: CGFloat = 40, timeout: TimeInterval = 20) async {
        let begin = Date()
        while driver.isGliding, originY < y, Date().timeIntervalSince(begin) < timeout {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Waits for the glide to be over, up to `timeout`.
    func waitForGlideToEnd(timeout: TimeInterval = 20) async {
        _ = await sampleUntilGlideEnds(timeout: timeout)
    }

    /// Where the offset that puts the row at the anchor is, worked out here from the reported frame.
    func expectedOffset(row: Int) -> CGFloat {
        guard let frame = driver.frame(ofRow: row), let document = scrollView?.documentView else { return -1 }
        return LyricsScrollGeometry.targetOffset(
            rowTop: frame.minY, rowHeight: frame.height, viewportHeight: viewport.height,
            contentHeight: document.bounds.height, anchor: MusicLyricScroll.anchorFraction
        )
    }
}

private struct SampleList: View {
    let driver: LyricsScrollDriver

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Color.clear.frame(height: viewport.height * MusicLyricScroll.anchorFraction)
                ForEach(0..<rowCount, id: \.self) { index in
                    Text("Invented test line number \(index)")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: 28)
                        .id(index)
                        .lyricsRowFrame(index, to: driver)
                }
                Color.clear.frame(height: viewport.height * (1 - MusicLyricScroll.anchorFraction))
            }
            .scrollTargetLayout()
            .lyricsScrollDriven(by: driver)
        }
        .scrollIndicators(.never)
    }
}

@MainActor
@Suite("Lyrics scroll driver: the real scroll view")
struct LyricsScrollDriverTests {

    // MARK: - What the geometry assumes of the scroll view

    @Test("The probe finds the scroll view the list is in")
    func probeFindsTheScrollView() async {
        let rig = await Rig.ready()
        #expect(rig.scrollView != nil)
        #expect(rig.scrollView?.documentView != nil)
    }

    @Test("The document is flipped, so the bounds origin is the offset from the top")
    func documentIsFlipped() async {
        let rig = await Rig.ready()
        #expect(rig.scrollView?.documentView?.isFlipped == true)
        #expect(rig.clip?.isFlipped == true)
    }

    @Test("The scroll view has no content insets the arithmetic would miss")
    func noInsets() async {
        let rig = await Rig.ready()
        let insets = rig.scrollView?.contentInsets
        #expect(insets?.top == 0)
        #expect(insets?.bottom == 0)
    }

    @Test("The document is exactly as tall as the content stack: both spacers and every row")
    func documentHeight() async {
        let rig = await Rig.ready()
        let expected = viewport.height + CGFloat(rowCount) * 28
        #expect(rig.scrollView?.documentView?.bounds.height == expected)
    }

    @Test("Rows report their frames in the content's coordinates, below the top spacer, one after another")
    func rowFrames() async {
        let rig = await Rig.ready()
        let top = viewport.height * MusicLyricScroll.anchorFraction
        #expect(rig.driver.frame(ofRow: 0)?.minY == top)
        #expect(rig.driver.frame(ofRow: 1)?.minY == top + 28)
        #expect(rig.driver.frame(ofRow: rowCount - 1)?.minY == top + CGFloat(rowCount - 1) * 28)
        #expect(rig.driver.frame(ofRow: rowCount - 1)?.height == 28)
    }

    // MARK: - Jumping

    @Test("A jump puts the row's anchor point at the visible area's anchor point")
    func jumpAnchors() async throws {
        let rig = await Rig.ready()
        #expect(rig.driver.scroll(toRow: 20, animated: false))
        let frame = try #require(rig.driver.frame(ofRow: 20))
        let anchorInView = frame.minY + frame.height * MusicLyricScroll.anchorFraction - rig.originY
        #expect(abs(anchorInView - viewport.height * MusicLyricScroll.anchorFraction) < 0.5)
    }

    @Test("A jump lands where the geometry says, for the first line, a middle line and the last line")
    func jumpTargets() async {
        let rig = await Rig.ready()
        for row in [0, 7, 20, rowCount - 1] {
            #expect(rig.driver.scroll(toRow: row, animated: false))
            #expect(abs(rig.originY - rig.expectedOffset(row: row)) < 0.5)
        }
    }

    @Test("A jump is not a glide: nothing starts, and the origin is there at once")
    func jumpIsImmediate() async {
        let rig = await Rig.ready()
        rig.driver.scroll(toRow: 20, animated: false)
        #expect(rig.started == 0)
        #expect(!rig.driver.isGliding)
        #expect(abs(rig.originY - rig.expectedOffset(row: 20)) < 0.5)
    }

    @Test("No row means the top of the list")
    func nilRowIsTheTop() async {
        let rig = await Rig.ready()
        rig.driver.scroll(toRow: 20, animated: false)
        #expect(rig.driver.scroll(toRow: nil, animated: false))
        #expect(rig.originY == 0)
    }

    // MARK: - When the driver says no

    @Test("A row that has not reported a frame is left to the fallback, and nothing moves")
    func unknownRow() async {
        let rig = await Rig.ready()
        let before = rig.originY
        #expect(!rig.driver.scroll(toRow: 9_999, animated: true))
        #expect(!rig.driver.scroll(toRow: 9_999, animated: false))
        #expect(rig.originY == before)
        #expect(rig.started == 0)
    }

    @Test("A driver whose probe was never placed says no")
    func noProbe() {
        let driver = LyricsScrollDriver()
        driver.setFrame(CGRect(x: 0, y: 100, width: 100, height: 30), forRow: 0)
        #expect(driver.scrollView == nil)
        #expect(!driver.scroll(toRow: 0, animated: true))
        #expect(!driver.scroll(toRow: 0, animated: false))
    }

    // MARK: - Gliding

    @Test("A glide moves from where the list is to the target, never backwards, and slows down as it arrives")
    func glideEasesOut() async {
        // The animator steps on the main thread, which the other tests share: a run in which something held it for a
        // moment skips steps and says nothing about the glide. Such a run is repeated; a run the machine did not
        // disturb has to show a glide made of many steps that get smaller.
        var measured = false
        for _ in 0..<8 where !measured {
            let rig = await Rig.ready()
            rig.recordSteps()
            #expect(rig.driver.scroll(toRow: 20, animated: true))
            #expect(rig.started == 1)
            #expect(rig.driver.isGliding)
            await rig.waitForGlideToEnd()
            let target = rig.expectedOffset(row: 20)
            let steps = rig.steps
            for (earlier, later) in zip(steps, steps.dropFirst()) { #expect(later >= earlier) }
            #expect(abs(rig.originY - target) < 0.5)
            guard rig.longestStall < 0.1 else { continue }
            measured = true

            // Ease-out: the steps while it moves get smaller towards the end, compared by thirds of the run. A glide
            // that took a few big steps is a snap, not an ease.
            let moving = steps.filter { $0 < target - 0.5 }
            #expect(moving.count >= 9)
            let third = moving.count / 3
            guard third > 0 else { continue }
            let first = moving[third] - moving[0]
            let last = moving[moving.count - 1] - moving[moving.count - 1 - third]
            #expect(first > last)
        }
        #expect(measured, "every attempt was disturbed by other tests holding the main thread")
    }

    @Test("A glide is not a snap: straight after the request the list has not moved to the target, and it gets there")
    func glideIsNotASnap() async {
        let rig = await Rig.ready()
        let start = rig.originY
        rig.driver.scroll(toRow: 20, animated: true)
        let target = rig.expectedOffset(row: 20)
        #expect(abs(rig.originY - target) > 100)
        #expect(abs(rig.originY - start) < 100)
        let values = await rig.sampleUntilGlideEnds()
        #expect(values.contains { $0 > start + 1 })
        #expect(abs(rig.originY - target) < 0.5)
    }

    @Test("A glide ends once, on its own, with the list at the target")
    func glideEnds() async {
        let rig = await Rig.ready()
        rig.driver.scroll(toRow: 20, animated: true)
        await rig.waitForGlideToEnd()
        #expect(!rig.driver.isGliding)
        #expect(rig.started == 1)
        #expect(rig.ended == 1)
        #expect(abs(rig.originY - rig.expectedOffset(row: 20)) < 0.5)
    }

    @Test("Asking for the place the list is already gliding to does not start another glide")
    func sameTargetTwice() async {
        let rig = await Rig.ready()
        rig.driver.scroll(toRow: 20, animated: true)
        await rig.waitUntilMoving()
        rig.driver.scroll(toRow: 20, animated: true)
        await rig.waitForGlideToEnd()
        #expect(rig.started == 1)
        #expect(rig.ended == 1)
        #expect(abs(rig.originY - rig.expectedOffset(row: 20)) < 0.5)
    }

    @Test("Asking for the place the list is already at starts no glide")
    func alreadyThere() async {
        let rig = await Rig.ready()
        rig.driver.scroll(toRow: 20, animated: false)
        rig.driver.scroll(toRow: 20, animated: true)
        #expect(rig.started == 0)
        #expect(!rig.driver.isGliding)
    }

    @Test("A glide can run in either direction")
    func glideUp() async {
        let rig = await Rig.ready()
        rig.driver.scroll(toRow: 30, animated: false)
        rig.driver.scroll(toRow: 10, animated: true)
        let values = await rig.sampleUntilGlideEnds()
        for (earlier, later) in zip(values, values.dropFirst()) { #expect(later <= earlier) }
        #expect(abs(rig.originY - rig.expectedOffset(row: 10)) < 0.5)
    }

    // MARK: - Interrupting a glide

    @Test("A new glide replaces the one on its way from where the list is: no jump, one start, one end")
    func replaced() async {
        let rig = await Rig.ready()
        rig.driver.scroll(toRow: 35, animated: true)
        await rig.waitUntilMoving()
        let midway = rig.originY
        #expect(midway > 0)
        // A machine busy enough to have let the first glide finish before this line only changes the count below.
        let stillGliding = rig.driver.isGliding
        rig.driver.scroll(toRow: 0, animated: true)
        let values = await rig.sampleUntilGlideEnds()
        // From where it was, straight to the new target.
        for (earlier, later) in zip([midway] + values, values) { #expect(later <= earlier + 0.5) }
        #expect(abs(rig.originY - rig.expectedOffset(row: 0)) < 0.5)
        #expect(rig.started == (stillGliding ? 1 : 2))
        #expect(rig.ended == rig.started)
    }

    @Test("A jump during a glide stops it, lands on the target and ends the glide")
    func jumpDuringAGlide() async {
        let rig = await Rig.ready()
        rig.driver.scroll(toRow: 30, animated: true)
        await rig.waitUntilMoving()
        rig.driver.scroll(toRow: 5, animated: false)
        #expect(!rig.driver.isGliding)
        let values = await rig.sample(0.8)
        let target = rig.expectedOffset(row: 5)
        for value in values { #expect(abs(value - target) < 0.5) }
        #expect(rig.started == 1)
        #expect(rig.ended == 1)
    }

    @Test("A jump stops an animation the driver no longer counts as a glide, instead of being walked over by it")
    func jumpStopsAStaleAnimation() async {
        let rig = await Rig.ready()
        // The watchdog can clear the glide flag while the animation is still stepping. Start one the driver does not
        // know about: the flag is off, the clip view is moving.
        guard let clip = rig.clip else { Issue.record("no clip view"); return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = MusicLyricScroll.glideDuration
            context.allowsImplicitAnimation = true
            clip.animator().setBoundsOrigin(NSPoint(x: 0, y: 900))
        }, completionHandler: nil)
        #expect(!rig.driver.isGliding)
        let begin = Date()
        while rig.originY < 40, Date().timeIntervalSince(begin) < 20 {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(rig.originY >= 40)
        rig.driver.scroll(toRow: 5, animated: false)
        let target = rig.expectedOffset(row: 5)
        let values = await rig.sample(0.8)
        for value in values { #expect(abs(value - target) < 0.5) }
    }

    @Test("A jump to where the list already is still stops an animation that is carrying it away")
    func jumpToTheSamePlaceStopsAStaleAnimation() async {
        let rig = await Rig.ready()
        guard let clip = rig.clip else { Issue.record("no clip view"); return }
        rig.driver.scroll(toRow: 5, animated: false)
        let target = rig.expectedOffset(row: 5)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = MusicLyricScroll.glideDuration
            context.allowsImplicitAnimation = true
            clip.animator().setBoundsOrigin(NSPoint(x: 0, y: 900))
        }, completionHandler: nil)
        // Straight away, so the list is still within half a point of the target: nothing to move, but something to stop.
        rig.driver.scroll(toRow: 5, animated: false)
        let values = await rig.sample(0.8)
        for value in values { #expect(abs(value - target) < 0.5) }
    }

    @Test("Cancelling a glide leaves the list where it is on screen, and it stays there")
    func cancelStaysPut() async {
        let rig = await Rig.ready()
        rig.driver.scroll(toRow: 20, animated: true)
        await rig.waitUntilMoving()
        let before = rig.originY
        rig.driver.cancelGlide()
        #expect(!rig.driver.isGliding)
        let values = await rig.sample(0.7)
        #expect(before > 0)
        for value in values { #expect(abs(value - before) < 1) }
        #expect(rig.started == 1)
        #expect(rig.ended == 1)
    }

    @Test("Cancelling with no glide on its way does nothing")
    func cancelWithoutAGlide() async {
        let rig = await Rig.ready()
        rig.driver.scroll(toRow: 20, animated: false)
        let before = rig.originY
        rig.driver.cancelGlide()
        #expect(rig.originY == before)
        #expect(rig.started == 0)
        #expect(rig.ended == 0)
    }

    @Test("After a cancelled glide the next one starts from where the list stopped")
    func glideAfterCancel() async {
        let rig = await Rig.ready()
        rig.driver.scroll(toRow: 20, animated: true)
        await rig.waitUntilMoving()
        rig.driver.cancelGlide()
        rig.driver.scroll(toRow: 30, animated: true)
        await rig.waitForGlideToEnd()
        #expect(abs(rig.originY - rig.expectedOffset(row: 30)) < 0.5)
        #expect(rig.started == 2)
        #expect(rig.ended == 2)
    }

    // MARK: - The user's hand

    @Test("A scroll event over the list during a glide stops it")
    func userScrollStopsTheGlide() async {
        let rig = await Rig.ready()
        rig.driver.scroll(toRow: 20, animated: true)
        await rig.waitUntilMoving()
        rig.driver.userScrolled(in: rig.window, at: NSPoint(x: 100, y: 100), phase: .began)
        #expect(!rig.driver.isGliding)
        #expect(rig.ended == 1)
        let before = rig.originY
        let values = await rig.sample(0.5)
        for value in values { #expect(abs(value - before) < 1) }
    }

    @Test("A finger resting on the trackpad has not scrolled anything: the glide goes on")
    func mayBeginIsNotAScroll() async {
        let rig = await Rig.ready()
        rig.driver.scroll(toRow: 20, animated: true)
        rig.driver.userScrolled(in: rig.window, at: NSPoint(x: 100, y: 100), phase: .mayBegin)
        #expect(rig.driver.isGliding)
        await rig.waitForGlideToEnd()
        #expect(abs(rig.originY - rig.expectedOffset(row: 20)) < 0.5)
    }

    @Test("A scroll in another window, or outside the list, is not the user's hand on it")
    func otherScrollsAreNotTheUsers() async {
        let rig = await Rig.ready()
        rig.driver.scroll(toRow: 20, animated: true)
        let other = NSWindow(contentRect: NSRect(origin: .zero, size: viewport), styleMask: [.borderless], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        rig.driver.userScrolled(in: other, at: NSPoint(x: 100, y: 100), phase: .began)
        rig.driver.userScrolled(in: nil, at: NSPoint(x: 100, y: 100), phase: .began)
        rig.driver.userScrolled(in: rig.window, at: NSPoint(x: 5_000, y: 5_000), phase: .began)
        #expect(rig.driver.isGliding)
        await rig.waitForGlideToEnd()
        #expect(abs(rig.originY - rig.expectedOffset(row: 20)) < 0.5)
    }

    @Test("A scroll event with no glide on its way changes nothing")
    func userScrollWithoutAGlide() async {
        let rig = await Rig.ready()
        rig.driver.userScrolled(in: rig.window, at: NSPoint(x: 100, y: 100), phase: .began)
        #expect(rig.started == 0)
        #expect(rig.ended == 0)
    }
}

@Suite("Lyrics scroll constants")
struct LyricsScrollConstantsTests {

    @Test("The lines lead the clock by a tenth of a second")
    func lead() {
        #expect(MusicLyricScroll.lineLead == 0.1)
    }

    @Test("The glide is a bit over half a second, with the ease-out curve the brief names")
    func glide() {
        #expect(MusicLyricScroll.glideDuration == 0.55)
        #expect(MusicLyricScroll.glideControlPoints == [0.25, 0.1, 0.25, 1])
    }

    @Test("The anchor is a third of the way down")
    func anchor() {
        #expect(abs(MusicLyricScroll.anchorFraction - 1.0 / 3.0) < 1e-9)
    }
}
