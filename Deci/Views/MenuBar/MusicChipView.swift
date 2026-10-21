// Deci/Views/MenuBar/MusicChipView.swift
// The Now playing chip as a view inside the Music status item's button: a rounded pill in the cover's colour that holds
// the current song's MusicChipContent. A new song swaps the content with a cross-fade while the pill grows or shrinks to
// its new width. A paused song fades the content out, narrows the pill and fades a play glyph in at its middle; a play
// brings the content and the title's width back. All by Core Animation, so nothing is drawn per frame.

import AppKit
import QuartzCore

/// The view the chip controller adds to the status item's button. It takes no mouse events: the button's own click, the
/// hover tracking and FluidMenuBarExtra's popover toggle all keep working under it.
@MainActor
final class MusicChipView: NSView {
    private let pill = CALayer()
    /// The play triangle of a paused pill. It sits in the view's layer, over the pill and at the view's middle, so it stays
    /// in the pill's middle while the pill and the item change width.
    private let glyph = CALayer()
    /// The pill's own highlight while the Music popover is open, under the cover and title. It stands in for the
    /// system's, which lights the whole status window and so spreads past the pill.
    private let highlight = CALayer()
    private var content: MusicChipContent?
    private var scale: CGFloat

    private static let highlightAlpha: CGFloat = 0.2
    private static let highlightWidth: CGFloat = 1_000

    private static let widthKey = "chipPillWidth"
    private static let fillKey = "chipPillFill"
    private static let appearKey = "chipAppear"
    private static let glyphKey = "chipPlayGlyphFade"

    /// The pill's width the layer is heading for (its model value), in points. Zero before the first song shows. Read by
    /// the tests.
    var pillWidth: Double { Double(pill.bounds.width) }

    /// How strong the play glyph is drawn (its model value): 1 on a paused pill, 0 on a playing one. Read by the tests.
    var playGlyphOpacity: Double { Double(glyph.opacity) }

    /// How strong the cover and the title are drawn (their model value); zero while paused and before any song shows. Read
    /// by the tests.
    var contentOpacity: Double { Double(content?.layer.opacity ?? 0) }

    /// How strong the pill's highlight is drawn (its model value): 1 while the popover is open, 0 otherwise. Read by the
    /// tests.
    var highlightOpacity: Double { Double(highlight.opacity) }

    init(frame: NSRect, scale: CGFloat) {
        self.scale = scale
        super.init(frame: frame)
        // A layer-hosting view: the layer is set first, so the view draws nothing itself.
        layer = CALayer()
        wantsLayer = true
        setAccessibilityElement(false)

        pill.cornerRadius = MusicChipLayout.cornerRadius
        pill.masksToBounds = true
        pill.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        pill.bounds = CGRect(x: 0, y: 0, width: 0, height: MusicChipLayout.height)
        pill.contentsScale = scale
        layer?.addSublayer(pill)

        // First in the pill, so the content added later sits over it. Wider than any pill: the pill clips it to its own
        // shape at every width, also while the width animates.
        highlight.backgroundColor = NSColor.white.withAlphaComponent(Self.highlightAlpha).cgColor
        highlight.frame = CGRect(x: 0, y: 0, width: Self.highlightWidth, height: MusicChipLayout.height)
        highlight.opacity = 0
        pill.addSublayer(highlight)

        let side = MusicChipLayout.playGlyphSide
        glyph.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        glyph.contentsGravity = .center
        glyph.contentsScale = scale
        glyph.contents = MusicChipRenderer.playGlyphImage(scale: scale)
        glyph.opacity = 0
        layer?.addSublayer(glyph)
        centerLayers()
    }

    required init?(coder: NSCoder) {
        fatalError("MusicChipView is made in code")
    }

    override var isOpaque: Bool { false }

    /// Lets every click, hover and drag reach the button underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // MARK: - Geometry

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        centerLayers()
    }

    /// The pill stays in the middle of the item, whatever length the item has on the way to its new one, and the play
    /// glyph with it, a point to the right of the middle so the triangle looks centred.
    private func centerLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pill.position = CGPoint(x: bounds.midX, y: bounds.midY)
        glyph.position = CGPoint(x: bounds.midX + MusicChipLayout.playGlyphNudge, y: bounds.midY)
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let newScale = window?.backingScaleFactor ?? scale
        guard newScale != scale else { return }
        scale = newScale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contentsScale = newScale
        pill.contentsScale = newScale
        glyph.contentsScale = newScale
        glyph.contents = MusicChipRenderer.playGlyphImage(scale: newScale)
        CATransaction.commit()
        content?.setScale(newScale)
    }

    // MARK: - Show

    /// Fades the whole chip in, for the first time it shows on the item.
    func appear() {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = MusicChipMotion.fadeDuration
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer?.add(fade, forKey: Self.appearKey)
    }

    /// Shows `spec`: a playback change only trades the content and the play glyph and moves the pill to its width; a
    /// cover change also brings in the cover and the colour that arrived late, with the title left alone; a content change
    /// fades the old title and cover out as the new ones fade in. A paused song shows the glyph on a narrow pill, a
    /// playing one the title on a pill as wide as `geometry` says, and the pill follows over `widthDuration` seconds (no
    /// time: at once). The first content on a view shows without any fade.
    func show(
        spec: MusicChipSpec,
        geometry: MusicChipGeometry,
        thumbnail: CGImage?,
        change: MusicChipMotion.Change,
        widthDuration: Double
    ) {
        switch change {
        case .none:
            return
        case .playback:
            showPlayback(spec: spec, geometry: geometry, widthDuration: widthDuration, animated: true)
        case .cover:
            // The same song: its title and its marquee stay as they are.
            content?.setCover(thumbnail)
            setFill(MusicChipRenderer.fillColor(for: spec.tint), animated: true)
            showPlayback(spec: spec, geometry: geometry, widthDuration: widthDuration, animated: true)
        case .content:
            let next = MusicChipContent(spec: spec, geometry: geometry, thumbnail: thumbnail, scale: scale)
            let previous = content
            content = next
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            pill.addSublayer(next.layer)
            CATransaction.commit()
            next.begin()
            if let previous {
                previous.fadeOutAndRemove()
                next.fadeIn()
            }
            setFill(MusicChipRenderer.fillColor(for: spec.tint), animated: previous != nil)
            showPlayback(
                spec: spec,
                geometry: geometry,
                widthDuration: previous == nil ? 0 : widthDuration,
                animated: previous != nil
            )
        }
    }

    /// Brings the content, the play glyph and the pill's width in line with whether the song plays. The content is already
    /// built for `spec` after a content change, so only the glyph and the width move then. Nothing to do before any
    /// content shows.
    private func showPlayback(spec: MusicChipSpec, geometry: MusicChipGeometry, widthDuration: Double, animated: Bool) {
        guard let content else { return }
        let fade = animated ? MusicChipMotion.playbackFadeDuration(reduceMotion: spec.reduceMotion) : 0
        content.setPlaying(spec.isPlaying, fadeDuration: fade)
        setGlyph(isPlaying: spec.isPlaying, duration: fade)
        setPillWidth(MusicChipLayout.shownPillWidth(for: geometry, isPlaying: spec.isPlaying), duration: widthDuration)
    }

    /// Lights the pill while the Music popover is open, as the system lights an open item, but only as big as the pill.
    /// The change fades by the layer's own implicit animation.
    func setHighlighted(_ isOn: Bool) {
        highlight.opacity = isOn ? 1 : 0
    }

    /// Stops the marquee from starting again, before the view comes off the button.
    func teardown() {
        content?.cancelRearm()
    }

    /// The pill's colour follows the cover's, cross-fading when a song replaces another.
    private func setFill(_ color: CGColor, animated: Bool) {
        let from = pill.presentation()?.backgroundColor ?? pill.backgroundColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pill.backgroundColor = color
        CATransaction.commit()
        guard animated, let from else { return }
        let fade = CABasicAnimation(keyPath: "backgroundColor")
        fade.fromValue = from
        fade.toValue = color
        fade.duration = MusicChipMotion.fadeDuration
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        pill.add(fade, forKey: Self.fillKey)
    }

    /// The play glyph fades in on a paused pill and out on a playing one, over `duration` seconds (no time: at once).
    private func setGlyph(isPlaying: Bool, duration: Double) {
        let alpha = Float(MusicChipLayout.playGlyphAlpha(isPlaying: isPlaying))
        guard glyph.opacity != alpha else { return }
        let from = glyph.presentation()?.opacity ?? glyph.opacity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glyph.opacity = alpha
        CATransaction.commit()
        if duration > 0 {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = from
            fade.toValue = alpha
            fade.duration = duration
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            glyph.add(fade, forKey: Self.glyphKey)
        } else {
            glyph.removeAnimation(forKey: Self.glyphKey)
        }
    }

    /// Resizes the pill to `width`, easing from the width it shows now when `duration` is above zero.
    private func setPillWidth(_ width: Double, duration: Double) {
        let from = pill.presentation()?.bounds.width ?? pill.bounds.width
        guard abs(from - CGFloat(width)) > 0.01 || pill.bounds.width != CGFloat(width) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pill.bounds = CGRect(x: 0, y: 0, width: width, height: MusicChipLayout.height)
        CATransaction.commit()
        if duration > 0 {
            let grow = CABasicAnimation(keyPath: "bounds.size.width")
            grow.fromValue = from
            grow.toValue = width
            grow.duration = duration
            grow.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            pill.add(grow, forKey: Self.widthKey)
        } else {
            pill.removeAnimation(forKey: Self.widthKey)
        }
    }
}
