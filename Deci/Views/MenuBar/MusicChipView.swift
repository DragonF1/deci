// Deci/Views/MenuBar/MusicChipView.swift
// The Now playing chip as a view inside the Music status item's button: a rounded pill in the cover's colour that holds
// the current song's MusicChipContent. A new song swaps the content with a cross-fade while the pill grows or shrinks to
// its new width, all by Core Animation, so nothing is drawn per frame.

import AppKit
import QuartzCore

/// The view the chip controller adds to the status item's button. It takes no mouse events: the button's own click, the
/// hover tracking and FluidMenuBarExtra's popover toggle all keep working under it.
@MainActor
final class MusicChipView: NSView {
    private let pill = CALayer()
    private var content: MusicChipContent?
    private var scale: CGFloat

    private static let widthKey = "chipPillWidth"
    private static let fillKey = "chipPillFill"
    private static let appearKey = "chipAppear"

    /// The pill's width the layer is heading for (its model value), in points. Zero before the first song shows.
    var pillWidth: Double { Double(pill.bounds.width) }

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
        centerPill()
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
        centerPill()
    }

    /// The pill stays in the middle of the item, whatever length the item has on the way to its new one.
    private func centerPill() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pill.position = CGPoint(x: bounds.midX, y: bounds.midY)
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

    /// Shows `spec`: a playback change only fades the content to the new strength; a content change fades the old title
    /// and cover out as the new ones fade in, and the pill follows the title's width over `widthDuration` seconds (no
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
            content?.setPlaying(spec.isPlaying)
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
            setPillWidth(geometry.pillWidth, duration: previous == nil ? 0 : widthDuration)
        }
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
