// Deci/Views/Music/MusicMarqueeView.swift
import AppKit
import QuartzCore
import SwiftUI

/// Where the scrolling line stands at one moment: how far its start is off the left edge, and whether the left edge fades.
nonisolated struct MusicMarqueeFrame: Equatable, Sendable {
    /// Zero or negative: the line moves left.
    var offset: Double
    /// The start of the window fades while the line is off its start, so letters slide out instead of being cut.
    var leadingFade: Bool
}

/// The marquee's path over time, as the display link steps it. The numbers are the menu bar chip's (`MusicChipMotion`).
nonisolated enum MusicMarqueeMotion {
    /// The line `elapsed` seconds after the marquee began: the hold, the scroll, and again with no rest between loops.
    /// The offset sits on a whole device pixel, so the text is drawn sharp at every step.
    static func frame(elapsed: Double, textWidth: Double, scale: Double) -> MusicMarqueeFrame {
        let loop = MusicChipMotion.marqueeLoopElapsed(elapsed, textWidth: textWidth)
        let raw = MusicChipMotion.marqueeOffset(elapsed: loop, textWidth: textWidth)
        let pixels = scale.isFinite && scale > 0 ? scale : 1
        let snapped = (raw * pixels).rounded() / pixels
        let offset = snapped == 0 ? 0 : snapped
        return MusicMarqueeFrame(offset: offset, leadingFade: offset < 0)
    }

    /// The two copies of the line and the gap between them, rounded up so the hosting view never cuts the second copy.
    static func trackWidth(textWidth: Double) -> Double {
        let width = textWidth.isFinite ? max(textWidth, 0) : 0
        return (2 * width + MusicChipMotion.marqueeGap).rounded(.up)
    }

    /// One whole loop as a list of offsets, one for every step of a device pixel: the line's place at the start of each
    /// of `offsets.count` equal parts of `duration`. Played as a discrete animation it holds, then moves a pixel at a
    /// time with the same positions `frame(elapsed:textWidth:scale:)` gives, so the text is as sharp as when it was
    /// stepped by hand, and the render server does the stepping.
    struct Loop: Equatable {
        var duration: Double
        var offsets: [Double]
    }

    static func loop(textWidth: Double, scale: Double) -> Loop {
        let duration = MusicChipMotion.marqueeHold + MusicChipMotion.marqueeScrollDuration(textWidth: textWidth)
        let pixels = scale.isFinite && scale > 0 ? scale : 1
        // At least one step for every device pixel of the scroll.
        let count = max(1, Int((duration * MusicChipMotion.marqueeSpeed * pixels).rounded(.up)))
        let step = duration / Double(count)
        let offsets = (0..<count).map { index in
            frame(elapsed: Double(index) * step, textWidth: textWidth, scale: scale).offset
        }
        return Loop(duration: duration, offsets: offsets)
    }

    /// The colours of the mask over the window: the end always fades, the start too once the line is off it.
    static func fadeColors(leading: Bool) -> [CGColor] {
        let opaque = CGColor(gray: 0, alpha: 1)
        let clear = CGColor(gray: 0, alpha: 0)
        return [leading ? clear : opaque, opaque, opaque, clear]
    }
}

/// Receives the display link's steps without being retained by it, so the view can go away while a link is live.
@MainActor
private final class MusicMarqueeLinkTarget: NSObject {
    weak var view: MusicMarqueeView?

    @objc func step(_ link: CADisplayLink) {
        view?.step(at: link.targetTimestamp)
    }
}

/// The scrolling line as a view that is moved by Core Animation, not by the app. A SwiftUI `TimelineView(.animation)` asks
/// the popup's whole window for a render transaction and a layout every display frame, which was most of the open Music
/// popup's cost while a long title scrolled. Here the two copies of the line sit in a hosting view of their own, and the
/// render server slides that view's layer (a discrete animation, a pixel at a time, so the text stays sharp) and changes
/// the edge fade with it: the app does nothing per frame, and no view's geometry changes, which matters because a frame
/// that changes every display frame makes the window re-resolve its tracking areas and set the cursor again every frame
/// while the pointer is over the popup.
///
/// A layer's animation does not move the view for events, so a line with something to click in it (`isInteractive`)
/// moves by frame as before while the pointer is over it: its buttons then are where they show. That is the only time a
/// display link runs. A window that cannot be seen stops all of it, whatever the SwiftUI tree says, and it starts again,
/// from the line's start, when the window can be seen.
@MainActor
final class MusicMarqueeView: NSView {
    enum Motion: Equatable {
        /// Nothing runs: no window, or a window nobody can see.
        case idle
        /// The render server slides the layer; the app does nothing per frame.
        case animating
        /// A display link moves the hosting view's frame (the pointer is over a line with buttons in it).
        case stepping
    }

    static let slideKey = "deci.marquee.slide"
    static let fadeKey = "deci.marquee.fade"
    /// How many display link steps pass between looks at where the pointer is.
    static let pointerCheckInterval = 15

    /// The two copies of the line, in a hosting view as wide as both and the gap.
    let hosted: NSView
    private let isInteractive: Bool
    private let fade = CAGradientLayer()
    private let target = MusicMarqueeLinkTarget()
    private var link: CADisplayLink?
    private var textWidth = 0.0
    private var hoverArea: NSTrackingArea?
    private var windowObservers: [NSObjectProtocol] = []
    private var stepsSincePointerCheck = 0

    /// When the marquee began, on the media clock: the line stands at its start for the hold from then.
    private(set) var startedAt: CFTimeInterval = CACurrentMediaTime()
    /// The line as of the last step (only a stepping view has one).
    private(set) var shown: MusicMarqueeFrame?
    /// How many times a step moved the line or changed the fade (a step that changes nothing is not counted).
    private(set) var moves = 0
    private(set) var motion: Motion = .idle
    /// Whether the pointer is over a line that has buttons in it.
    private(set) var pointerInside = false

    /// Whether a window can be seen: ordered in and not covered. Replaced in tests.
    var windowIsShowing: @MainActor (NSWindow) -> Bool = { $0.isVisible && $0.occlusionState.contains(.visible) }
    /// Where the pointer is in a window's coordinates. Replaced in tests.
    var pointerLocation: @MainActor (NSWindow) -> NSPoint = { $0.mouseLocationOutsideOfEventStream }

    var isLinked: Bool { link != nil }
    var isAnimating: Bool { motion == .animating }

    /// The slide and the fade, as they are on the layers.
    var slideAnimation: CAKeyframeAnimation? { hosted.layer?.animation(forKey: Self.slideKey) as? CAKeyframeAnimation }
    var fadeAnimation: CAKeyframeAnimation? { fade.animation(forKey: Self.fadeKey) as? CAKeyframeAnimation }

    init(hosted: NSView, isInteractive: Bool) {
        self.hosted = hosted
        self.isInteractive = isInteractive
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.mask = fade
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        fade.actions = [
            "colors": NSNull(), "locations": NSNull(), "bounds": NSNull(), "position": NSNull(),
        ]
        hosted.wantsLayer = true
        hosted.autoresizingMask = []
        addSubview(hosted)
        target.view = self
        layoutParts()
        paintFade(leading: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    isolated deinit {
        link?.invalidate()
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
    }

    /// A line with something to click in it is hit where it shows; one without lets the clicks fall through to the view
    /// behind it, whose tooltip and menu stay on the whole room.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isInteractive else { return nil }
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutParts()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeWindow()
        syncMotion()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        // The pixel grid changed: place the line on the new one.
        placeLine(at: CACurrentMediaTime())
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        hoverArea = nil
        guard isInteractive else { return }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil
        )
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        setPointerInside(true)
    }

    override func mouseExited(with event: NSEvent) {
        setPointerInside(false)
    }

    // MARK: - Input

    /// The width of one copy of the line. A new width begins the marquee again, at its hold.
    func configure(textWidth newWidth: Double) {
        guard newWidth != textWidth else { return }
        textWidth = newWidth
        restart(at: CACurrentMediaTime())
    }

    /// Begins the marquee at `time`: the line stands at its start for the hold.
    func restart(at time: CFTimeInterval) {
        startedAt = time
        layoutParts()
        placeLine(at: time)
    }

    /// Puts the line where the marquee has it at `time` for the motion it is in.
    private func placeLine(at time: CFTimeInterval) {
        if motion == .animating {
            addAnimations()
        } else {
            shown = nil
            advance(at: time)
        }
    }

    /// Puts the line where the marquee has it at `time`, by frame. A step that lands on the picture already shown does
    /// nothing.
    func advance(at time: CFTimeInterval) {
        let next = MusicMarqueeMotion.frame(elapsed: time - startedAt, textWidth: textWidth, scale: scale)
        guard next != shown else { return }
        let previous = shown
        shown = next
        moves += 1
        hosted.setFrameOrigin(NSPoint(x: next.offset, y: 0))
        if previous?.leadingFade != next.leadingFade { paintFade(leading: next.leadingFade) }
    }

    private var scale: Double {
        Double(window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2)
    }

    // MARK: - Motion

    /// Puts the motion right for the window as it is now: nothing if nobody can see it, the render server's slide, or
    /// the frame stepping while the pointer is over a line with buttons in it.
    func syncMotion() {
        guard let window, windowIsShowing(window) else {
            stopMotion()
            return
        }
        if motion == .idle { pointerInside = pointerIsInside() }
        if isInteractive && pointerInside { beginStepping() } else { beginAnimating() }
    }

    /// Stops everything: the slide, the display link, and the line is put back at its start.
    func stopMotion() {
        guard motion != .idle else { return }
        motion = .idle
        removeAnimations()
        stopLink()
        shown = nil
        setLinePlaceDirectly(offset: 0, leading: false)
    }

    private func beginAnimating() {
        guard motion != .animating else { return }
        let wasIdle = motion == .idle
        stopLink()
        motion = .animating
        // Coming back from a window nobody could see, the line starts again at its hold.
        if wasIdle { startedAt = CACurrentMediaTime() }
        shown = nil
        setLinePlaceDirectly(offset: 0, leading: false)
        addAnimations()
    }

    private func beginStepping() {
        guard motion != .stepping else { return }
        let wasIdle = motion == .idle
        removeAnimations()
        motion = .stepping
        if wasIdle { startedAt = CACurrentMediaTime() }
        // The line is where the slide has it now: its path is a function of the clock, so no read of the layer is needed.
        shown = nil
        advance(at: CACurrentMediaTime())
        stepsSincePointerCheck = 0
        startLink()
    }

    /// Notes that the pointer came over the line or left it. Only a line with buttons in it follows the pointer.
    func setPointerInside(_ inside: Bool) {
        let inside = inside && isInteractive
        guard inside != pointerInside else { return }
        pointerInside = inside
        syncMotion()
    }

    private func pointerIsInside() -> Bool {
        guard isInteractive, let window else { return false }
        return bounds.contains(convert(pointerLocation(window), from: nil))
    }

    /// One step of the display link, which runs only while the line is stepped by frame.
    func step(at time: CFTimeInterval) {
        guard motion == .stepping else { return }
        guard let window, windowIsShowing(window) else {
            stopMotion()
            return
        }
        stepsSincePointerCheck += 1
        if stepsSincePointerCheck >= Self.pointerCheckInterval {
            stepsSincePointerCheck = 0
            // A pointer that left without the tracking area saying so must not hold the display link for good.
            if !pointerIsInside() {
                setPointerInside(false)
                return
            }
        }
        advance(at: time)
    }

    private func observeWindow() {
        let center = NotificationCenter.default
        for observer in windowObservers { center.removeObserver(observer) }
        windowObservers = []
        guard let window else { return }
        windowObservers.append(center.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncMotion() }
        })
        windowObservers.append(center.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopMotion() }
        })
    }

    // MARK: - Render server animation

    /// The slide and the fade, begun at `startedAt` on the media clock so that the line's place is a function of the
    /// clock whoever moves it: the render server, or the display link when the pointer is over the line.
    private func addAnimations() {
        guard let hostedLayer = hosted.layer else { return }
        let loop = MusicMarqueeMotion.loop(textWidth: textWidth, scale: scale)
        let begin = hostedLayer.convertTime(startedAt, from: nil)

        let slide = CAKeyframeAnimation(keyPath: "transform.translation.x")
        slide.values = loop.offsets.map { NSNumber(value: $0) }
        slide.calculationMode = .discrete
        slide.duration = loop.duration
        slide.repeatCount = .infinity
        slide.beginTime = begin
        slide.isRemovedOnCompletion = false
        hostedLayer.add(slide, forKey: Self.slideKey)

        // Clear through the hold, in over the first moments of the scroll, out over the last ones: the chip's.
        let holding = MusicMarqueeMotion.fadeColors(leading: false)
        let scrolling = MusicMarqueeMotion.fadeColors(leading: true)
        let dim = CAKeyframeAnimation(keyPath: "colors")
        dim.values = [holding, holding, scrolling, scrolling, holding]
        dim.keyTimes = MusicChipMotion.edgeFadeKeyTimes(textWidth: textWidth).map { NSNumber(value: $0) }
        dim.calculationMode = .linear
        dim.duration = loop.duration
        dim.repeatCount = .infinity
        dim.beginTime = begin
        dim.isRemovedOnCompletion = false
        fade.add(dim, forKey: Self.fadeKey)
    }

    private func removeAnimations() {
        hosted.layer?.removeAnimation(forKey: Self.slideKey)
        fade.removeAnimation(forKey: Self.fadeKey)
    }

    /// The model place of the line and the fade, with no implicit animation.
    private func setLinePlaceDirectly(offset: Double, leading: Bool) {
        hosted.setFrameOrigin(NSPoint(x: offset, y: 0))
        paintFade(leading: leading)
    }

    // MARK: - Display link

    /// Steps the line with the screen, at up to 60 a second: at 25 points a second that is under a pixel a step.
    func startLink() {
        guard link == nil, window != nil else { return }
        let newLink = displayLink(target: target, selector: #selector(MusicMarqueeLinkTarget.step(_:)))
        newLink.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        newLink.add(to: .main, forMode: .common)
        link = newLink
    }

    func stopLink() {
        link?.invalidate()
        link = nil
    }

    // MARK: - Layout

    /// The hosting view as wide as both copies and as high as the window; the mask as big as the window.
    private func layoutParts() {
        hosted.setFrameSize(NSSize(width: MusicMarqueeMotion.trackWidth(textWidth: textWidth), height: bounds.height))
        hosted.setFrameOrigin(NSPoint(x: shown?.offset ?? 0, y: 0))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fade.frame = bounds
        fade.locations = MusicChipMotion.edgeFadeLocations(windowWidth: bounds.width).map { NSNumber(value: $0) }
        CATransaction.commit()
    }

    /// The end always fades; the start fades too once the line is off it.
    private func paintFade(leading: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fade.colors = MusicMarqueeMotion.fadeColors(leading: leading)
        CATransaction.commit()
    }
}

/// The line twice with the gap between, for the hosting view inside the marquee. A hosting view of its own does not see
/// the environment of the view it sits in, so it is handed over whole: the artist line reads `openMusicArtist`, the
/// accent and the highlight terms from it, and the font and colours come down from the column.
struct MusicMarqueeRow<Content: View>: View {
    let content: Content
    let environment: EnvironmentValues

    var body: some View {
        HStack(spacing: MusicChipMotion.marqueeGap) {
            content.fixedSize()
            content.fixedSize().accessibilityHidden(true)
        }
        // The hosting view is the track's width rounded up: start the copies at its left edge, not centred in it, so the
        // text is not shifted by up to half a point onto a soft position.
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.self, environment)
    }
}

/// The moving line in SwiftUI.
struct MusicMarqueeTrack<Content: View>: NSViewRepresentable {
    let content: Content
    let textWidth: CGFloat
    let isInteractive: Bool

    final class Coordinator {
        var hosting: NSHostingView<MusicMarqueeRow<Content>>?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MusicMarqueeView {
        let hosting = NSHostingView(rootView: row(in: context))
        // The marquee sets its size; the hosting view must not ask the window for one.
        hosting.sizingOptions = []
        // A hosting view that sees its place move reads that as a change of its safe area and asks the window it sits in
        // for a layout (`-[NSView setFrameOrigin:]` to `NSHostingView.invalidateSafeAreaInsets` to the outer hosting view's
        // `needsLayout`), once per step: 23 layouts of the whole popup a second, from a view that only slides. With no
        // safe area to follow, sliding it costs the popup nothing.
        hosting.safeAreaRegions = []
        context.coordinator.hosting = hosting
        let view = MusicMarqueeView(hosted: hosting, isInteractive: isInteractive)
        view.configure(textWidth: Double(textWidth))
        return view
    }

    func updateNSView(_ view: MusicMarqueeView, context: Context) {
        context.coordinator.hosting?.rootView = row(in: context)
        view.configure(textWidth: Double(textWidth))
        // A window that opened again, or was covered and uncovered, without the view hearing of it.
        view.syncMotion()
    }

    static func dismantleNSView(_ view: MusicMarqueeView, coordinator: Coordinator) {
        view.stopMotion()
    }

    private func row(in context: Context) -> MusicMarqueeRow<Content> {
        MusicMarqueeRow(content: content, environment: context.environment)
    }
}
