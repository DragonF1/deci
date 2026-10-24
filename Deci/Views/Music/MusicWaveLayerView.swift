// Deci/Views/Music/MusicWaveLayerView.swift
import AppKit
import QuartzCore
import SwiftUI

/// What the wave's layers are built from: two equal specs give the same picture.
nonisolated struct MusicWaveSpec: Equatable, Sendable {
    var levels: [Double]
    /// The progress that is shown: the song's own, or a drag's preview.
    var progress: Double
    /// The box's width, as laid out.
    var width: Double
    var tint: MusicTint
}

/// The wave as Core Graphics paths and colours, from `MusicWave`'s numbers. Pure, so it is unit tested. The wave's own
/// numbers grow downward from the top of the box; a layer's grow upward, so every point is turned over the box's height
/// here and nowhere else.
nonisolated enum MusicWaveShapes {
    /// The ripple's turn is cut into this many parts, and the animation has a path at the start of each (and the first
    /// again at the end, so the loop closes). The render server blends two neighbours linearly. The blend's error is
    /// the cosine's curvature over a part, `(2 pi / parts)^2 / 8` of the ripple's swing (14 pt times 0.2), about 0.006 pt.
    static let parts = 48

    /// One turn of the ripple takes this long.
    static var period: TimeInterval { 2 * .pi / MusicWave.rippleSpeed }

    static let lineWidth: CGFloat = 2

    /// The ripple's phase `elapsed` seconds after its origin, in 0 up to a turn.
    static func phase(elapsed: TimeInterval) -> Double {
        guard elapsed.isFinite else { return 0 }
        let turn = 2 * Double.pi
        let wrapped = (elapsed * MusicWave.rippleSpeed).truncatingRemainder(dividingBy: turn)
        return wrapped < 0 ? wrapped + turn : wrapped
    }

    /// The phase at the start of the `index`th part.
    static func phase(ofKeyframe index: Int) -> Double {
        2 * .pi * Double(index) / Double(parts)
    }

    /// The keyframe whose phase is nearest to `phase`.
    static func nearestKeyframe(toPhase phase: Double) -> Int {
        guard phase.isFinite else { return 0 }
        let turns = phase / (2 * .pi)
        let share = turns - turns.rounded(.down)
        return Int((share * Double(parts)).rounded()) % parts
    }

    /// Whether any of the song is played, so there is a curve to draw. The same rule as `MusicWave.profile`'s.
    static func hasCurve(progress: Double, width: Double) -> Bool {
        progress.isFinite && progress > 0 && MusicWave.playheadX(progress: progress, width: width) > MusicWave.inset
    }

    // MARK: - Paths

    private static func point(_ x: Double, _ y: Double) -> CGPoint {
        CGPoint(x: x, y: MusicWave.boxHeight - y)
    }

    /// The unplayed part: a line from the knob to the other end, on the baseline.
    static func restPath(progress: Double, width: Double) -> CGPath {
        let head = MusicWave.playheadX(progress: progress, width: width)
        let path = CGMutablePath()
        path.move(to: point(head, MusicWave.baselineY))
        path.addLine(to: point(max(width - MusicWave.inset, head), MusicWave.baselineY))
        return path
    }

    /// The played curve, closed down to the baseline: from the first sample up along the heights to the last and back
    /// down. Every path made for one song position has the same elements, which is what lets the render server blend
    /// them.
    static func curvePath(_ samples: [MusicWave.Sample]) -> CGPath? {
        guard let first = samples.first, let last = samples.last else { return nil }
        let base = MusicWave.baselineY
        let path = CGMutablePath()
        path.move(to: point(first.x, base))
        for sample in samples {
            path.addLine(to: point(sample.x, base - sample.height))
        }
        path.addLine(to: point(last.x, base))
        path.closeSubpath()
        return path
    }

    /// The played curve at a ripple phase.
    static func stillPath(levels: [Double], progress: Double, width: Double, phase: Double) -> CGPath? {
        curvePath(MusicWave.profile(levels: levels, progress: progress, width: width, phase: phase))
    }

    /// The line along the baseline under the played curve, from the knob's start to the playhead.
    static func baselinePath(progress: Double, width: Double) -> CGPath? {
        guard hasCurve(progress: progress, width: width) else { return nil }
        let path = CGMutablePath()
        path.move(to: point(MusicWave.inset, MusicWave.baselineY))
        path.addLine(to: point(MusicWave.playheadX(progress: progress, width: width), MusicWave.baselineY))
        return path
    }

    /// One whole turn of the ripple as paths: `parts + 1` of them, the last the first again. Nil when nothing is played.
    static func rippleKeyframes(levels: [Double], progress: Double, width: Double) -> [CGPath]? {
        guard hasCurve(progress: progress, width: width) else { return nil }
        var frames: [CGPath] = []
        frames.reserveCapacity(parts + 1)
        for index in 0..<parts {
            guard let path = stillPath(
                levels: levels, progress: progress, width: width, phase: phase(ofKeyframe: index)
            ) else { return nil }
            frames.append(path)
        }
        frames.append(frames[0])
        return frames
    }

    // MARK: - Colours

    private static func srgb(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double) -> CGColor {
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let components = [red, green, blue, alpha].map { CGFloat($0) }
        return CGColor(colorSpace: space, components: components) ?? CGColor(gray: 1, alpha: alpha)
    }

    /// The gradient's colours, left to right: `MusicWave.gradientTints`, as the colours SwiftUI makes of them.
    static func gradientColors(for tint: MusicTint) -> [CGColor] {
        MusicWave.gradientTints(for: tint).map { tint in
            let rgb = MusicSpectrum.rgb(hue: tint.hue, saturation: tint.saturation, brightness: tint.brightness)
            return srgb(rgb.red, rgb.green, rgb.blue, 1)
        }
    }

    /// Where the gradient starts and ends, in the unit square of its layer: from the left inset to the playhead.
    static func gradientPoints(progress: Double, width: Double) -> (start: CGPoint, end: CGPoint) {
        guard width.isFinite, width > 0 else { return (CGPoint(x: 0, y: 0.5), CGPoint(x: 1, y: 0.5)) }
        let head = MusicWave.playheadX(progress: progress, width: width)
        return (
            CGPoint(x: MusicWave.inset / width, y: 0.5),
            CGPoint(x: max(head, MusicWave.inset + 1) / width, y: 0.5)
        )
    }

    /// The unplayed line's white.
    static func restColor() -> CGColor { srgb(1, 1, 1, 0.25) }

    /// Opaque, for the shapes that cut the gradient out.
    static func maskColor() -> CGColor { srgb(0, 0, 0, 1) }
}

/// The hover card's wave, as layers that Core Animation runs. The ripple that moves along the played curve is a loop of
/// one turn, so the render server plays it and the app does nothing per frame. A SwiftUI `TimelineView(.animation)` with
/// a `Canvas` instead asked the card's hosting view for a layout and a Metal render every display frame, about 17% of a
/// core while the card was up and a song played.
///
/// The picture is a gradient layer cut by a mask: the mask is the played curve (filled) and the line under it, the
/// gradient runs from the left inset to the playhead, and the unplayed line is a layer of its own. The curve's path is
/// the animated property: a keyframe animation through `MusicWaveShapes.parts` paths, one turn of the ripple, repeating
/// for ever. The paths are rebuilt only when what they are built from changes (the playhead, which moves with the
/// player's half second ticks; the levels; the width; the tint), and each rebuild begins its animation at the same
/// origin on the media clock, so the ripple does not jump.
///
/// It ripples only while the song plays, Reduce Motion is off, and the window can be seen. Paused, with Reduce Motion
/// on, or in a window nobody can see, it holds one path and no animation is added: where it stood when it stopped (at
/// the start with Reduce Motion), and a hidden window does no work. It starts again from the phase it stopped at.
@MainActor
final class MusicWaveLayerView: NSView {
    static let rippleKey = "deci.wave.ripple"

    /// What the curve's layer shows.
    private enum Fill: Equatable {
        /// One path at this phase of the ripple.
        case still(Double)
        /// The loop.
        case rippling
    }

    let restLayer = CAShapeLayer()
    let gradientLayer = CAGradientLayer()
    let fillLayer = CAShapeLayer()
    let lineLayer = CAShapeLayer()
    private let content = CALayer()
    private let maskLayer = CALayer()

    private var spec: MusicWaveSpec?
    private var isPlaying = false
    private var reduceMotion = false
    private var windowObservers: [NSObjectProtocol] = []
    /// The window is closing: whatever it reports, it is not showing.
    private var windowIsClosing = false

    /// The spec the layers show, and what the curve's layer shows of it.
    private var shownSpec: MusicWaveSpec?
    private var fill: Fill?

    /// The ripple's phase where it last stopped.
    private(set) var frozenPhase = 0.0
    /// The moment on the media clock at which the ripple stood at phase 0: the loop's phase at any moment is a function
    /// of the clock and this, whoever replaces the animation.
    private(set) var phaseOrigin: CFTimeInterval = 0

    /// How many times the static layers (colours, lines, mask) were painted, the loop's paths were built, and a single
    /// path was set.
    private(set) var paints = 0
    private(set) var keyframeBuilds = 0
    private(set) var stillBuilds = 0

    /// Whether a window can be seen: ordered in and not covered. Replaced in tests.
    var windowIsShowing: @MainActor (NSWindow) -> Bool = { $0.isVisible && $0.occlusionState.contains(.visible) }
    /// The media clock. Replaced in tests.
    var now: @MainActor () -> CFTimeInterval = { CACurrentMediaTime() }

    var isRippling: Bool { fill == .rippling }

    /// The loop, as it is on the layer.
    var rippleAnimation: CAKeyframeAnimation? { fillLayer.animation(forKey: Self.rippleKey) as? CAKeyframeAnimation }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        buildLayers()
        layoutLayers()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    isolated deinit {
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
    }

    /// The seek gesture lives on the SwiftUI view around this one.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override var isOpaque: Bool { false }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutLayers()
        guard var current = spec, current.width != Double(newSize.width) else { return }
        current.width = Double(newSize.width)
        spec = current
        sync()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowIsClosing = false
        observeWindow()
        sync()
    }

    // MARK: - Input

    /// SwiftUI's side: what to draw and whether it moves. Cheap when nothing changed.
    func update(levels: [Double], progress: Double, tint: MusicTint, isPlaying: Bool, reduceMotion: Bool) {
        self.isPlaying = isPlaying
        self.reduceMotion = reduceMotion
        spec = MusicWaveSpec(levels: levels, progress: progress, width: Double(bounds.width), tint: tint)
        sync()
    }

    /// Puts the layers right for the inputs and the window as they are now: the static parts when the spec changed, the
    /// curve when the spec or the motion did. Called by every update, and by the window's notices.
    func sync() {
        guard let spec, spec.width.isFinite, spec.width > 0 else { return }
        let curved = MusicWaveShapes.hasCurve(progress: spec.progress, width: spec.width)
        let showing = !windowIsClosing && (window.map { windowIsShowing($0) } ?? false)
        let rippling = curved && isPlaying && !reduceMotion && showing
        let wasRippling = fill == .rippling

        if wasRippling && !rippling {
            frozenPhase = reduceMotion ? 0 : MusicWaveShapes.phase(elapsed: now() - phaseOrigin)
        } else if rippling && !wasRippling {
            // From where it stopped, so a pause or a hidden window does not make the ripple jump.
            phaseOrigin = now() - frozenPhase / MusicWave.rippleSpeed
        }

        let specChanged = spec != shownSpec
        if specChanged {
            paint(spec, curved: curved)
        }
        let wanted: Fill = rippling ? .rippling : .still(reduceMotion ? 0 : frozenPhase)
        guard specChanged || wanted != fill else { return }
        shownSpec = spec
        fill = wanted
        switch wanted {
        case .rippling: startRipple(spec)
        case .still(let phase): showStill(spec, phase: phase)
        }
    }

    /// Takes the loop off and forgets what is shown, for a view that is going away.
    func stop() {
        removeRipple()
        shownSpec = nil
        fill = nil
    }

    // MARK: - Layers

    private func buildLayers() {
        // Nothing here is ever animated implicitly: the loop is the only motion.
        let off: [String: any CAAction] = [
            "path": NSNull(), "bounds": NSNull(), "position": NSNull(), "colors": NSNull(), "startPoint": NSNull(),
            "endPoint": NSNull(), "hidden": NSNull(), "strokeColor": NSNull(), "fillColor": NSNull(),
            "lineWidth": NSNull(), "opacity": NSNull(),
        ]
        for layer in [content, maskLayer, restLayer, gradientLayer, fillLayer, lineLayer] as [CALayer] {
            layer.actions = off
        }
        restLayer.fillColor = nil
        restLayer.strokeColor = MusicWaveShapes.restColor()
        restLayer.lineWidth = MusicWaveShapes.lineWidth
        restLayer.lineCap = .round

        fillLayer.fillColor = MusicWaveShapes.maskColor()
        fillLayer.strokeColor = nil
        lineLayer.fillColor = nil
        lineLayer.strokeColor = MusicWaveShapes.maskColor()
        lineLayer.lineWidth = MusicWaveShapes.lineWidth
        lineLayer.lineCap = .round

        maskLayer.addSublayer(fillLayer)
        maskLayer.addSublayer(lineLayer)
        gradientLayer.mask = maskLayer
        content.addSublayer(restLayer)
        content.addSublayer(gradientLayer)
        layer?.addSublayer(content)
    }

    /// The box sits at the top of the view, as high as the wave's measures say.
    private func layoutLayers() {
        let box = CGRect(x: 0, y: bounds.height - MusicWave.boxHeight, width: bounds.width, height: MusicWave.boxHeight)
        let local = CGRect(origin: .zero, size: box.size)
        withoutActions {
            content.frame = box
            for layer in [restLayer, gradientLayer, maskLayer, fillLayer, lineLayer] as [CALayer] {
                layer.frame = local
            }
        }
    }

    /// The parts that do not ripple: the unplayed line, the line under the curve, the gradient.
    private func paint(_ spec: MusicWaveSpec, curved: Bool) {
        paints += 1
        let points = MusicWaveShapes.gradientPoints(progress: spec.progress, width: spec.width)
        withoutActions {
            restLayer.path = MusicWaveShapes.restPath(progress: spec.progress, width: spec.width)
            lineLayer.path = MusicWaveShapes.baselinePath(progress: spec.progress, width: spec.width)
            gradientLayer.colors = MusicWaveShapes.gradientColors(for: spec.tint)
            gradientLayer.startPoint = points.start
            gradientLayer.endPoint = points.end
            gradientLayer.isHidden = !curved
        }
    }

    private func showStill(_ spec: MusicWaveSpec, phase: Double) {
        stillBuilds += 1
        removeRipple()
        let path = MusicWaveShapes.stillPath(levels: spec.levels, progress: spec.progress, width: spec.width, phase: phase)
        withoutActions { fillLayer.path = path }
    }

    private func startRipple(_ spec: MusicWaveSpec) {
        keyframeBuilds += 1
        guard let frames = MusicWaveShapes.rippleKeyframes(levels: spec.levels, progress: spec.progress, width: spec.width)
        else {
            removeRipple()
            withoutActions { fillLayer.path = nil }
            return
        }
        let loop = CAKeyframeAnimation(keyPath: "path")
        loop.values = frames
        loop.calculationMode = .linear
        loop.duration = MusicWaveShapes.period
        loop.repeatCount = .infinity
        loop.isRemovedOnCompletion = false
        loop.beginTime = fillLayer.convertTime(phaseOrigin, from: nil)
        let phase = MusicWaveShapes.phase(elapsed: now() - phaseOrigin)
        withoutActions {
            // The model holds the loop's path nearest to now, for the moments no animation is evaluated.
            fillLayer.path = frames[MusicWaveShapes.nearestKeyframe(toPhase: phase)]
            fillLayer.add(loop, forKey: Self.rippleKey)
        }
    }

    private func removeRipple() {
        fillLayer.removeAnimation(forKey: Self.rippleKey)
    }

    private func withoutActions(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    // MARK: - The window

    private func observeWindow() {
        let center = NotificationCenter.default
        for observer in windowObservers { center.removeObserver(observer) }
        windowObservers = []
        guard let window else { return }
        windowObservers.append(center.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync() }
        })
        windowObservers.append(center.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            // A window that is closing may still report as seen: the loop comes off regardless.
            MainActor.assumeIsolated {
                self?.windowIsClosing = true
                self?.sync()
            }
        })
    }
}

/// The wave's layers in SwiftUI. The box is as wide as it is given and `MusicWave.boxHeight` high.
struct MusicWaveLayer: NSViewRepresentable {
    let levels: [Double]
    let progress: Double
    let tint: MusicTint
    let isPlaying: Bool
    let reduceMotion: Bool

    func makeNSView(context: Context) -> MusicWaveLayerView {
        let view = MusicWaveLayerView(
            frame: NSRect(x: 0, y: 0, width: MusicHoverCardMetrics.contentWidth, height: MusicWave.boxHeight)
        )
        apply(to: view)
        return view
    }

    func updateNSView(_ view: MusicWaveLayerView, context: Context) {
        apply(to: view)
    }

    private func apply(to view: MusicWaveLayerView) {
        view.update(levels: levels, progress: progress, tint: tint, isPlaying: isPlaying, reduceMotion: reduceMotion)
    }

    static func dismantleNSView(_ view: MusicWaveLayerView, coordinator: ()) {
        view.stop()
    }
}
