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

/// The spectrum's bars, drawn into a layer of their own. The driver polls 30 times a second; if each poll ran a SwiftUI
/// update, the popup's whole window would lay out 30 times a second. This view listens to the driver instead and marks
/// only itself for display, and only when the picture changed by a step the eye can see (`MusicSpectrumFrame`).
/// SwiftUI still sets the style and the song's bars (`update`), which is what happens while the accent glides to a new
/// song's colour.
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
    private var drawnStyle: MusicSpectrumStyle?

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
    /// How many times the view marked itself for display.
    private(set) var invalidations = 0

    /// Whether a slide of the fill is under way.
    var isGliding: Bool { glide != nil }
    /// Whether the slide's display link is running.
    var isGlideLinked: Bool { glideLink != nil }
    /// When the slide in progress began, on the display link's clock.
    var glideStartedAt: CFTimeInterval? { glide?.start }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // Redrawn when marked, never because the window asked: a poll that changes nothing costs nothing.
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        glideTarget.view = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    isolated deinit {
        glideLink?.invalidate()
        detach()
    }

    override var isFlipped: Bool { true }

    override var isOpaque: Bool { false }

    /// The seek gesture and the hover live on the SwiftUI view around this one.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { invalidate() }
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

    // MARK: - Drawing state

    /// Takes the latest bars and fill, and marks the view for display if the picture is not the one on screen.
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
        guard next != picture || style != drawnStyle else { return }
        picture = next
        drawnStyle = style
        invalidate()
    }

    private func invalidate() {
        invalidations += 1
        needsDisplay = true
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let height = style.height
        let thickness = MusicSpectrum.barThickness(height: height)
        let edge = MusicSpectrum.fillEdge(height: height)
        let edgeY = MusicSpectrum.fillEdgeY(progress: shownProgress, height: height)
        let rgb = MusicSpectrum.rgb(hue: style.hue, saturation: style.saturation, brightness: style.brightness)
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let played = CGColor(
            colorSpace: space, components: [rgb.red, rgb.green, rgb.blue, style.barsOpacity].map { CGFloat($0) }
        ) ?? CGColor(gray: 1, alpha: 1)
        let unplayed = CGColor(
            colorSpace: space, components: [1, 1, 1, style.unplayedOpacity * style.barsOpacity].map { CGFloat($0) }
        ) ?? CGColor(gray: 1, alpha: 0.25)
        let gradient = CGGradient(colorsSpace: space, colors: [played, unplayed] as CFArray, locations: nil)

        for (index, level) in shownLevels.enumerated() {
            let width = style.fixedWidth ?? MusicSpectrum.width(forLevel: level)
            let rect = CGRect(
                x: (bounds.width - width) / 2,
                y: MusicSpectrum.barY(index, height: height),
                width: width,
                height: thickness
            )
            let path = CGPath(roundedRect: rect, cornerWidth: thickness / 2, cornerHeight: thickness / 2, transform: nil)
            context.saveGState()
            context.addPath(path)
            if rect.maxY <= edgeY - edge / 2 {
                context.setFillColor(played)
                context.fillPath()
            } else if rect.minY >= edgeY + edge / 2 {
                context.setFillColor(unplayed)
                context.fillPath()
            } else if let gradient {
                // A bar in the soft edge: the accent above it, the white below.
                context.clip()
                context.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: rect.midX, y: edgeY - edge / 2),
                    end: CGPoint(x: rect.midX, y: edgeY + edge / 2),
                    options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
                )
            }
            context.restoreGState()
        }
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
