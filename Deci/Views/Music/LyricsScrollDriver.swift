// Deci/Views/Music/LyricsScrollDriver.swift
import AppKit
import SwiftUI

/// Moves the synced lyrics list's real scroll view.
///
/// A scroll to a row through SwiftUI's `ScrollPosition` does not animate on macOS: the list snaps from line to line. So
/// the glide is done on the scroll view underneath. A tiny view in the list's content (the probe) finds its
/// `NSScrollView` through the public `enclosingScrollView`, and the clip view's bounds origin is animated with an
/// ease-out curve through AppKit's animator, which steps the clip view's real bounds origin from start to target.
///
/// Where to go comes from the rows themselves: each reports its frame in the content's coordinates, and
/// `LyricsScrollGeometry` works out the offset that puts a row at the anchor. When the scroll view cannot be found, or
/// it has content insets this arithmetic does not account for, or a row's frame has not been reported yet,
/// `scroll(toRow:animated:)` says false and the view falls back to a `ScrollPosition` jump.
@MainActor
final class LyricsScrollDriver {
    /// The coordinate space the rows report their frames in: the content stack, whose top is the document's top.
    nonisolated static let contentSpace = "lyricsContent"

    /// Told true when a glide starts and false when it ends, however it ends: finished, replaced by a jump, or cancelled
    /// by the user's hand. The follow state uses it to tell the list's own moves from the user's scroll.
    var glideChanged: ((Bool) -> Void)?

    private(set) var isGliding = false

    private var frames: [Int: CGRect] = [:]
    private weak var probe: NSView?
    /// Where the glide in flight is going, for telling a repeat of the same request from a new one.
    private var glideTarget: CGFloat?
    /// Names the glide in flight, so the end of one that was replaced or cancelled is not taken for the end of the next.
    private var glideToken = 0
    private var monitor: Any?

    isolated deinit {
        removeMonitor()
    }

    // MARK: - Reports from the view

    /// The probe is in the view tree. Only a reference is kept: the scroll view is looked for when it is needed.
    func attach(_ view: NSView) {
        probe = view
    }

    /// A row's frame in the content's coordinates, from the row's own geometry. Never observed: nothing redraws for it.
    func setFrame(_ frame: CGRect, forRow index: Int) {
        frames[index] = frame
    }

    /// The last frame a row reported, in the content's coordinates; nil before it has reported one.
    func frame(ofRow index: Int) -> CGRect? {
        frames[index]
    }

    /// The scroll view the list is in; nil until the probe is in a window, inside a scroll view.
    var scrollView: NSScrollView? {
        probe?.enclosingScrollView
    }

    // MARK: - Scrolling

    /// Puts row `index` at the anchor (the top of the list for nil): a glide, or a jump when `animated` is false. A
    /// glide on its way is replaced from where it is on screen. True when it was handled; false when the view has to
    /// scroll by other means (see the type's comment).
    @discardableResult
    func scroll(toRow index: Int?, animated: Bool) -> Bool {
        guard let scrollView, let document = scrollView.documentView else { return false }
        let clip = scrollView.contentView
        let insets = scrollView.contentInsets
        guard insets.top == 0, insets.bottom == 0 else { return false }

        let viewport = clip.bounds.height
        let content = document.bounds.height
        var offset: CGFloat = 0
        if let index {
            guard let frame = frames[index] else { return false }
            offset = LyricsScrollGeometry.targetOffset(
                rowTop: frame.minY, rowHeight: frame.height, viewportHeight: viewport, contentHeight: content,
                anchor: MusicLyricScroll.anchorFraction
            )
        }
        let target = LyricsScrollGeometry.boundsOriginY(
            forOffset: offset, contentHeight: content, viewportHeight: viewport, isFlipped: document.isFlipped
        )

        if animated {
            glide(clip, in: scrollView, toY: target)
        } else {
            jump(clip, in: scrollView, toY: target)
        }
        return true
    }

    /// Stops a glide where it is on screen and leaves the list there. For the user's hand, and for tests.
    func cancelGlide() {
        guard isGliding else { return }
        if let scrollView {
            freeze(scrollView.contentView, in: scrollView)
        }
        endGlide()
    }

    private func jump(_ clip: NSClipView, in scrollView: NSScrollView, toY target: CGFloat) {
        let wasGliding = isGliding
        // Always, even when the flag says no glide or the list is within half a point of the target: the watchdog may
        // have cleared the flag while the animator was still stepping, and only setting the origin stops those steps
        // (removing the layer's animations does not). Setting the origin the list already has changes nothing.
        invalidateGlide()
        setOrigin(clip, in: scrollView, y: target)
        if wasGliding { endGlide() }
    }

    private func glide(_ clip: NSClipView, in scrollView: NSScrollView, toY target: CGFloat) {
        // Already there, or already on the way there, is nothing to do: a glide keeps going instead of starting over.
        let heading = isGliding ? (glideTarget ?? clip.bounds.origin.y) : clip.bounds.origin.y
        guard !LyricsScrollGeometry.isAtTarget(current: heading, target: target) else { return }
        glideToken += 1
        glideTarget = target
        let token = glideToken
        beginGlide()

        let points = MusicLyricScroll.glideControlPoints
        NSAnimationContext.runAnimationGroup { context in
            context.duration = MusicLyricScroll.glideDuration
            context.timingFunction = CAMediaTimingFunction(controlPoints: points[0], points[1], points[2], points[3])
            context.allowsImplicitAnimation = true
            clip.animator().setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: target))
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.finishGlide(token) }
        }
        scrollView.reflectScrolledClipView(clip)

        // Whatever happens to the animation, the glide is over soon after its length: a flag that never cleared would
        // keep the list from noticing the user's scroll.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(MusicLyricScroll.glideDuration + 0.2))
            self?.finishGlide(token)
        }
    }

    private func finishGlide(_ token: Int) {
        guard token == glideToken else { return }
        endGlide()
    }

    // MARK: - The origin

    /// Where the clip view is on screen. The animator steps the real bounds origin, so this is also where a glide in
    /// flight has got to. The presentation layer is not used: after a plain jump it can still hold an older origin.
    private func shownOriginY(of clip: NSClipView) -> CGFloat {
        clip.bounds.origin.y
    }

    /// The end of a glide already started is no longer the end of the current one.
    private func invalidateGlide() {
        glideToken += 1
    }

    private func setOrigin(_ clip: NSClipView, in scrollView: NSScrollView, y: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: y))
        scrollView.reflectScrolledClipView(clip)
        CATransaction.commit()
    }

    /// Ends the animation where it stands: setting the origin to the one on screen stops the animator's steps, so the
    /// list stays put.
    private func freeze(_ clip: NSClipView, in scrollView: NSScrollView) {
        let shown = shownOriginY(of: clip)
        invalidateGlide()
        setOrigin(clip, in: scrollView, y: shown)
    }

    // MARK: - Glide state

    private func beginGlide() {
        guard !isGliding else { return }
        isGliding = true
        installMonitor()
        glideChanged?(true)
    }

    private func endGlide() {
        guard isGliding else { return }
        isGliding = false
        glideTarget = nil
        removeMonitor()
        glideChanged?(false)
    }

    // MARK: - The user's hand

    /// While a glide runs, a scroll wheel or trackpad event over the list is the user taking over: the glide stops where
    /// it is, so their scroll moves from there instead of fighting it. The monitor sees the event before the scroll view,
    /// so the glide is over before the scroll view reports the scroll.
    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated { self?.scrollEvent(event) }
            return event
        }
    }

    private func removeMonitor() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
    }

    private func scrollEvent(_ event: NSEvent) {
        userScrolled(in: event.window, at: event.locationInWindow, phase: event.phase)
    }

    /// A scroll event at `locationInWindow` of `window`. Stops the glide when it is the user's hand on this list.
    func userScrolled(in window: NSWindow?, at locationInWindow: NSPoint, phase: NSEvent.Phase) {
        guard isGliding, let scrollView, let window, window === scrollView.window else { return }
        let point = scrollView.convert(locationInWindow, from: nil)
        guard scrollView.bounds.contains(point) else { return }
        // A finger resting on the trackpad has not scrolled anything yet.
        if phase == .mayBegin { return }
        cancelGlide()
    }
}

// MARK: - SwiftUI side

/// A view with no size of its own that finds the scroll view it sits in.
final class LyricsProbeView: NSView {
    weak var driver: LyricsScrollDriver? {
        didSet { driver?.attach(self) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        driver?.attach(self)
    }

    /// Never takes a click: the rows under it do.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct LyricsScrollProbe: NSViewRepresentable {
    let driver: LyricsScrollDriver

    func makeNSView(context: Context) -> LyricsProbeView {
        let view = LyricsProbeView()
        view.driver = driver
        return view
    }

    func updateNSView(_ view: LyricsProbeView, context: Context) {
        view.driver = driver
    }
}

extension View {
    /// Marks the list's content stack: the coordinate space its rows report their frames in, and the probe that finds the
    /// scroll view. Goes on the stack inside the `ScrollView`.
    func lyricsScrollDriven(by driver: LyricsScrollDriver) -> some View {
        coordinateSpace(.named(LyricsScrollDriver.contentSpace))
            .background { LyricsScrollProbe(driver: driver) }
    }

    /// Reports this row's frame to the driver, now and whenever it changes (a new width re-wraps the line).
    func lyricsRowFrame(_ index: Int, to driver: LyricsScrollDriver) -> some View {
        onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named(LyricsScrollDriver.contentSpace))
        } action: { frame in
            driver.setFrame(frame, forRow: index)
        }
    }
}
