// Deci/Views/Music/MusicSpectrumLayerView.swift
import AppKit
import QuartzCore
import SwiftUI

/// Everything the spectrum's drawing depends on besides the bars and the fill: the accent, the dim, the box.
struct MusicSpectrumStyle: Equatable {
    var hue: Double
    var saturation: Double
    var brightness: Double
    /// The opacity of every bar: a paused song's dim.
    var barsOpacity: Double
    /// The white of an unplayed bar.
    var unplayedOpacity: Double
    /// The box's height.
    var height: Double
    /// Every bar this wide, whatever its level (the empty state's flat bars).
    var fixedWidth: Double?
}

/// The driver a layer follows and the song it follows it for.
struct MusicSpectrumLive {
    let driver: MusicSpectrumDriver
    let videoId: String
}

/// Receives the slide's display link steps without being retained by the link.
@MainActor
private final class MusicSpectrumGlideTarget: NSObject {
    weak var view: MusicSpectrumLayerView?

    @objc func step(_ link: CADisplayLink) {
        view?.advanceGlide(at: link.targetTimestamp)
    }
}

/// The spectrum's bars, built from layers. The driver polls 30 times a second; if each poll ran a SwiftUI update, the
/// popup's whole window would lay out 30 times a second. This view listens to the driver instead, and a poll that
/// changed the picture by a step the eye can see (`MusicSpectrumFrame`) sets a few layer properties, and nothing is
/// drawn on the CPU: no `draw(_:)`, no backing store, no `needsDisplay`. SwiftUI still sets the style and the song's
/// bars (`update`), which is what happens while the accent glides to a new song's colour.
///
/// The picture is one gradient layer, masked by the bars. The gradient runs down the box from the played colour to the
/// unplayed white across the soft edge (its two ends are the edge's two sides, and it holds its end colours beyond
/// them), so the fill is two points (`startPoint`, `endPoint`) and a bar takes the colour of the gradient where it
/// stands, which is the accent above the edge, the white below it and a blend of the two in it. The mask is 28 rounded
/// layers, one per bar, whose width is the bar's `bounds` (they sit on the box's middle line), so a bar that moves is one
/// property of one layer. Nothing is animated implicitly; the one animation is the accent's and the slide's, which this
/// view is handed frame by frame.
///
/// The fill has two sources. While the driver's polls run, it is the driver's. Otherwise it is the one SwiftUI gives
/// (the player's position), and a change in that while the song is paused (a seek) is slid here, over
/// `MusicSpectrum.pausedSeekGlide`, by a display link that runs only for the slide. When the polls end, as the song is
/// paused, the fill stays exactly where the polls left it: the fill SwiftUI last gave is as old as the moment the polls
/// began (SwiftUI is not told of each poll), so it is not used until SwiftUI says where the fill is now.
@MainActor
final class MusicSpectrumLayerView: NSView {
    private var style = MusicSpectrumStyle(
        hue: 0, saturation: 0, brightness: 1, barsOpacity: 1, unplayedOpacity: 0.25,
        height: MusicSpectrum.boxHeight, fixedWidth: nil
    )
    private var staticLevels: [Double] = []
    private var live: MusicSpectrumLive?
    private var listenerToken: Int?
    private var picture: MusicSpectrumFrame?
    private var shownStyle: MusicSpectrumStyle?

    /// The fill shown when the driver has none: SwiftUI's, or the driver's last, or part of the way between on a slide.
    private(set) var restingProgress = 0.0
    /// The fill SwiftUI last asked for (not a snapshot taken while the polls ran), nil before the first.
    private var restingTarget: Double?
    /// The driver's fill as of the last poll the view saw, and whether the view was showing it a moment ago.
    private var lastLiveProgress: Double?
    private var wasDriven = false

    private struct Glide {
        let from: Double
        let to: Double
        let start: CFTimeInterval
    }

    private var glide: Glide?
    private let glideTarget = MusicSpectrumGlideTarget()
    private var glideLink: CADisplayLink?

    /// The bars and the fill as of the last change, whoever set them.
    private(set) var shownLevels: [Double] = []
    private(set) var shownProgress = 0.0

    // MARK: Layers

    /// The accent above the soft edge and the white below it, seen through the bars.
    let gradientLayer = CAGradientLayer()
    /// The mask of `gradientLayer`: the bars.
    let barsLayer = CALayer()
    /// One layer per bar, top to bottom.
    let barLayers: [CALayer] = (0..<MusicSpectrum.barCount).map { _ in CALayer() }

    private var allLayers: [CALayer] { [gradientLayer, barsLayer] + barLayers }

    /// What the layers show, so that a frame sets only what differs from it.
    private var shownWidths = [Int](repeating: 0, count: MusicSpectrum.barCount)
    private var shownGeometry: Geometry?
    private var shownEdge: Int?
    private var shownColours: Colours?

    /// How many times a frame (a change that shows) was put on the layers.
    private(set) var appliedFrames = 0
    /// How many bars had their width (or their being there) set, over all frames.
    private(set) var barWrites = 0
    /// How many times the fill's two points were set.
    private(set) var edgeWrites = 0
    /// How many times the gradient's colours were set.
    private(set) var colourWrites = 0
    /// How many times every layer was laid out again: the first frame, a new size or a new box height.
    private(set) var layoutPasses = 0

    /// The box as the layers are laid out: where the bars stand and how thick they are.
    private struct Geometry: Equatable {
        /// The view's size.
        var width: Double
        var height: Double
        /// The box height the bars are spread over (`MusicSpectrumStyle.height`).
        var box: Double
    }

    /// What the gradient is painted with.
    private struct Colours: Equatable {
        var hue: Double
        var saturation: Double
        var brightness: Double
        var barsOpacity: Double
        var unplayedOpacity: Double
    }

    /// Whether a slide of the fill is under way.
    var isGliding: Bool { glide != nil }
    /// Whether the slide's display link is running.
    var isGlideLinked: Bool { glideLink != nil }
    /// When the slide in progress began, on the display link's clock.
    var glideStartedAt: CFTimeInterval? { glide?.start }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // The view never draws: its layers are the picture, so the window's asks for a redraw have nothing to do.
        layerContentsRedrawPolicy = .never
        glideTarget.view = self
        buildLayers()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    isolated deinit {
        glideLink?.invalidate()
        detach()
    }

    override var isOpaque: Bool { false }

    /// The layers are the picture: AppKit asks `updateLayer` (which has nothing to do) and never `draw(_:)`, and gives
    /// the view no backing store of its own.
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {}

    /// The seek gesture and the hover live on the SwiftUI view around this one.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed, let picture { apply(picture) }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        for layer in allLayers { layer.contentsScale = scale }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard glide != nil else { return }
        if window != nil {
            startGlideLink()
        } else {
            // A slide nobody can see is over at once.
            finishGlide()
            refresh()
        }
    }

    // MARK: - Input

    /// SwiftUI's side: the style, the song's bars, the fill as SwiftUI has it, and the driver to follow.
    ///
    /// `progressIsLive` says that `progress` was read while the driver's polls ran: it is a snapshot the polls have moved
    /// past (SwiftUI is not told of each poll), so it is not news about where the fill should be. `glides` says a change
    /// in the fill is to be slid (the song is paused and Reduce Motion is off). While the driver has a fill of its own (a
    /// song is playing) that is the one drawn.
    func update(
        style: MusicSpectrumStyle,
        levels: [Double],
        progress: Double,
        progressIsLive: Bool = false,
        glides: Bool = false,
        live: MusicSpectrumLive?
    ) {
        self.style = style
        staticLevels = levels
        follow(live)
        settle(progress: progress, isLive: progressIsLive, glides: glides)
        refresh()
    }

    /// Stops listening to the driver. The fill stays where the polls left it.
    func detach() {
        if let live, let listenerToken { live.driver.removeFrameListener(listenerToken) }
        listenerToken = nil
        live = nil
        endDriven()
    }

    private func follow(_ next: MusicSpectrumLive?) {
        if let next, let live, next.driver === live.driver, listenerToken != nil {
            // The same driver: only the song can have changed.
            self.live = next
            return
        }
        detach()
        guard let next else { return }
        live = next
        listenerToken = next.driver.addFrameListener { [weak self] in self?.refresh() }
    }

    /// Takes in the fill SwiftUI asks for when the driver has none: at once, or slid there if it is a change worth
    /// seeing and the song is paused.
    private func settle(progress: Double, isLive: Bool, glides: Bool) {
        let target = progress.isFinite ? min(max(progress, 0), 1) : 0
        guard let previous = restingTarget else {
            restingTarget = target
            restingProgress = target
            return
        }
        guard !isLive, target != previous else { return }
        restingTarget = target
        let driven = live?.driver.progress != nil
        if driven || !glides || window == nil
            || !MusicSpectrum.glideIsVisible(from: restingProgress, to: target, height: style.height) {
            glide = nil
            stopGlideLink()
            restingProgress = target
        } else {
            beginGlide(to: target, at: CACurrentMediaTime())
        }
    }

    /// The polls ended: the fill stays where they left it, and SwiftUI's fill is not used until it asks for one.
    private func endDriven() {
        guard wasDriven else { return }
        wasDriven = false
        guard let last = lastLiveProgress else { return }
        finishGlide()
        restingProgress = last
        restingTarget = last
    }

    // MARK: - The slide

    /// Starts sliding the fill to `target`, from wherever it shows now.
    func beginGlide(to target: Double, at time: CFTimeInterval) {
        glide = Glide(from: restingProgress, to: target, start: time)
        startGlideLink()
    }

    /// Puts the sliding fill where it is `time` into the slide; the end of the slide puts it on the target.
    func advanceGlide(at time: CFTimeInterval) {
        guard let glide else { return }
        let done = (time - glide.start) / MusicSpectrum.pausedSeekGlide
        if done >= 1 {
            finishGlide()
        } else {
            restingProgress = glide.from + (glide.to - glide.from) * MusicSpectrum.easedOut(done)
        }
        refresh()
    }

    private func finishGlide() {
        if let glide { restingProgress = glide.to }
        glide = nil
        stopGlideLink()
    }

    private func startGlideLink() {
        guard glideLink == nil, window != nil else { return }
        let link = displayLink(target: glideTarget, selector: #selector(MusicSpectrumGlideTarget.step(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        glideLink = link
    }

    private func stopGlideLink() {
        glideLink?.invalidate()
        glideLink = nil
    }

    // MARK: - The picture

    /// Takes the latest bars and fill, and puts them on the layers if the picture is not the one on screen.
    private func refresh() {
        if let live {
            shownLevels = live.driver.bars(for: live.videoId)
            if let driven = live.driver.progress {
                lastLiveProgress = driven
                wasDriven = true
                if glide != nil { finishGlide() }
                shownProgress = driven
            } else {
                endDriven()
                shownProgress = restingProgress
            }
        } else {
            shownLevels = staticLevels
            shownProgress = restingProgress
        }
        let next = MusicSpectrumFrame(
            levels: shownLevels, progress: shownProgress, height: style.height, fixedWidth: style.fixedWidth
        )
        guard next != picture || style != shownStyle else { return }
        picture = next
        shownStyle = style
        apply(next)
    }

    // MARK: - Layers

    private func buildLayers() {
        // Nothing here is ever animated implicitly: a layer's property is the picture, set when the picture changes.
        let off: [String: any CAAction] = [
            "bounds": NSNull(), "position": NSNull(), "colors": NSNull(), "startPoint": NSNull(), "endPoint": NSNull(),
            "hidden": NSNull(), "cornerRadius": NSNull(), "contentsScale": NSNull(),
        ]
        for layer in allLayers {
            layer.actions = off
        }
        gradientLayer.type = .axial
        // Any opaque colour: a mask reads the alpha.
        let opaque = CGColor(gray: 0, alpha: 1)
        for bar in barLayers {
            bar.backgroundColor = opaque
            bar.isHidden = true
            barsLayer.addSublayer(bar)
        }
        gradientLayer.mask = barsLayer
        layer?.addSublayer(gradientLayer)
    }

    /// Puts a frame on the layers, setting only what differs from what they show: the bars whose width changed, the
    /// fill's two points if the soft edge moved, the colours if the accent or the dim changed. A new size or box height
    /// lays every layer out again.
    private func apply(_ frame: MusicSpectrumFrame) {
        appliedFrames += 1
        let geometry = Geometry(
            width: bounds.width, height: bounds.height > 0 ? bounds.height : style.height, box: style.height
        )
        let relaid = geometry != shownGeometry
        let colours = Colours(
            hue: style.hue, saturation: style.saturation, brightness: style.brightness,
            barsOpacity: style.barsOpacity, unplayedOpacity: style.unplayedOpacity
        )
        withoutActions {
            if relaid {
                layoutPasses += 1
                shownGeometry = geometry
                layOut(geometry)
            }
            let thickness = MusicSpectrum.barThickness(height: geometry.box)
            for index in 0..<MusicSpectrum.barCount {
                let half = index < frame.widths.count ? max(frame.widths[index], 0) : 0
                guard half != shownWidths[index] || relaid else { continue }
                shownWidths[index] = half
                barWrites += 1
                let bar = barLayers[index]
                bar.isHidden = half == 0
                bar.bounds = CGRect(x: 0, y: 0, width: Double(half) / 2, height: thickness)
            }
            if relaid || frame.edge != shownEdge {
                shownEdge = frame.edge
                edgeWrites += 1
                let points = Self.gradientPoints(progress: shownProgress, box: geometry.box, height: geometry.height)
                gradientLayer.startPoint = points.start
                gradientLayer.endPoint = points.end
            }
            if colours != shownColours {
                shownColours = colours
                colourWrites += 1
                let paint = Self.paint(for: style)
                gradientLayer.colors = [paint.played, paint.unplayed]
            }
        }
    }

    /// Everything that depends on the size: the layers' frames, and where each bar stands and how round it is.
    private func layOut(_ geometry: Geometry) {
        let size = CGRect(x: 0, y: 0, width: geometry.width, height: geometry.height)
        gradientLayer.frame = size
        barsLayer.frame = size
        let thickness = MusicSpectrum.barThickness(height: geometry.box)
        for (index, bar) in barLayers.enumerated() {
            bar.cornerRadius = thickness / 2
            bar.position = Self.barPosition(index, box: geometry.box, thickness: thickness, width: geometry.width, height: geometry.height)
        }
    }

    private func withoutActions(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    // MARK: - Measures

    /// The middle of bar `index`. The layers' space has its origin at the bottom left, the box's at the top left, and the
    /// bars hang from the top of the view whatever its height; every bar is on the middle line.
    static func barPosition(_ index: Int, box: Double, thickness: Double, width: Double, height: Double) -> CGPoint {
        CGPoint(x: width / 2, y: height - (MusicSpectrum.barY(index, height: box) + thickness / 2))
    }

    /// The gradient's two ends, in the unit square of the layer (y up): the played colour at the top of the soft edge, the
    /// unplayed white at its bottom. They may lie outside the layer, and the gradient holds its end colours beyond them.
    static func gradientPoints(progress: Double, box: Double, height: Double) -> (start: CGPoint, end: CGPoint) {
        let edge = MusicSpectrum.fillEdge(height: box)
        let edgeY = MusicSpectrum.fillEdgeY(progress: progress, height: box)
        let height = max(height, 1)
        return (
            CGPoint(x: 0.5, y: 1 - (edgeY - edge / 2) / height),
            CGPoint(x: 0.5, y: 1 - (edgeY + edge / 2) / height)
        )
    }

    /// The accent and the white, with the dim in their alpha, in sRGB.
    static func paint(for style: MusicSpectrumStyle) -> (played: CGColor, unplayed: CGColor) {
        let rgb = MusicSpectrum.rgb(hue: style.hue, saturation: style.saturation, brightness: style.brightness)
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let played = CGColor(
            colorSpace: space, components: [rgb.red, rgb.green, rgb.blue, style.barsOpacity].map { CGFloat($0) }
        ) ?? CGColor(gray: 1, alpha: 1)
        let unplayed = CGColor(
            colorSpace: space, components: [1, 1, 1, style.unplayedOpacity * style.barsOpacity].map { CGFloat($0) }
        ) ?? CGColor(gray: 1, alpha: 0.25)
        return (played, unplayed)
    }
}

/// The layer view in SwiftUI. The view is an animatable wrapper's body (`MusicSpectrumCanvas`), so the accent's glide
/// reaches `updateNSView` frame by frame, and nothing else does.
struct MusicSpectrumLayer: NSViewRepresentable {
    let style: MusicSpectrumStyle
    let levels: [Double]
    let progress: Double
    /// `progress` was read while the driver's polls ran, so it is a snapshot of the live fill, not news.
    var progressIsLive = false
    /// A change in the fill is slid: the song is paused and Reduce Motion is off.
    var glides = false
    let live: MusicSpectrumLive?

    func makeNSView(context: Context) -> MusicSpectrumLayerView {
        let view = MusicSpectrumLayerView(frame: NSRect(x: 0, y: 0, width: MusicSpectrum.boxWidth, height: style.height))
        update(view)
        return view
    }

    func updateNSView(_ view: MusicSpectrumLayerView, context: Context) {
        update(view)
    }

    private func update(_ view: MusicSpectrumLayerView) {
        view.update(
            style: style, levels: levels, progress: progress, progressIsLive: progressIsLive, glides: glides, live: live
        )
    }

    static func dismantleNSView(_ view: MusicSpectrumLayerView, coordinator: ()) {
        view.detach()
    }
}
