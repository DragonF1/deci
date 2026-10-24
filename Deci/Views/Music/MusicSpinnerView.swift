// Deci/Views/Music/MusicSpinnerView.swift
import AppKit
import SwiftUI

/// The spinner's measures: a ring three quarters of its box with an arc of a quarter of the ring that goes round once
/// per 0.8 s.
nonisolated enum MusicSpinnerGeometry {
    /// One turn takes this long.
    static let period: TimeInterval = 0.8
    /// The lit arc, as a share of the ring.
    static let arcShare = 0.25
    /// The ring's diameter, as a share of the box.
    static let ringShare = 0.75
    /// The angle of one turn on a layer. The layer's z axis points at the viewer, so a turn that is clockwise on screen
    /// is negative.
    static let turn = -2 * Double.pi

    /// The ring in a box `size` square: its diameter is `ringShare` of the box, in the middle of it.
    static func ringRect(size: Double) -> CGRect {
        guard size.isFinite, size > 0 else { return .zero }
        let diameter = size * ringShare
        let inset = (size - diameter) / 2
        return CGRect(x: inset, y: inset, width: diameter, height: diameter)
    }
}

nonisolated enum MusicSpinnerPaint {
    /// A SwiftUI colour as resolved in its environment, as a Core Graphics colour.
    static func cgColor(_ resolved: Color.Resolved) -> CGColor {
        let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) ?? CGColorSpaceCreateDeviceRGB()
        let components = [resolved.linearRed, resolved.linearGreen, resolved.linearBlue, resolved.opacity].map { CGFloat($0) }
        return CGColor(colorSpace: space, components: components) ?? CGColor(gray: 1, alpha: 1)
    }
}

/// A faint ring with an arc of a quarter turn that goes round once per 0.8 s, as layers: the turn is one Core Animation
/// rotation that repeats, which the render server runs. A SwiftUI repeating animation instead redraws its view every
/// display frame, and each of those frames runs the popup window's whole update and layout, which was most of what the
/// open Music popup cost while a spinner was on screen.
@MainActor
final class MusicSpinnerView: NSView {
    static let turnKey = "turn"

    let trackLayer = CAShapeLayer()
    let arcLayer = CAShapeLayer()
    /// How many times the turn was added (it is added once, and again only if the system took it away).
    private(set) var turnsStarted = 0

    private var lineWidth: CGFloat = 2

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        for layer in [trackLayer, arcLayer] {
            layer.fillColor = nil
            layer.actions = ["path": NSNull(), "strokeColor": NSNull(), "lineWidth": NSNull(), "bounds": NSNull(), "position": NSNull()]
        }
        arcLayer.lineCap = .round
        layer?.addSublayer(trackLayer)
        layer?.addSublayer(arcLayer)
        rebuild()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        rebuild()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { startTurning() }
    }

    /// The look: the stroke's width, the arc's colour and the ring's. Changes nothing about the turn.
    func configure(lineWidth: CGFloat, color: CGColor, track: CGColor) {
        self.lineWidth = lineWidth
        arcLayer.strokeColor = color
        trackLayer.strokeColor = track
        rebuild()
    }

    /// Adds the turn if the arc is not already turning.
    func startTurning() {
        guard arcLayer.animation(forKey: Self.turnKey) == nil else { return }
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = 0.0
        turn.toValue = MusicSpinnerGeometry.turn
        turn.duration = MusicSpinnerGeometry.period
        turn.repeatCount = .infinity
        turn.timingFunction = CAMediaTimingFunction(name: .linear)
        turn.isRemovedOnCompletion = false
        arcLayer.add(turn, forKey: Self.turnKey)
        turnsStarted += 1
    }

    /// The ring and the arc for the box as it is now. The arc layer is as big as the box, so it turns about the ring's
    /// own middle.
    private func rebuild() {
        let box = bounds.size
        let ring = MusicSpinnerGeometry.ringRect(size: Double(min(box.width, box.height)))
        let side = min(box.width, box.height)
        let center = CGPoint(x: box.width / 2, y: box.height / 2)
        let arcBounds = CGRect(x: 0, y: 0, width: box.width, height: box.height)
        let ringCenter = CGPoint(x: ring.midX + (box.width - side) / 2, y: ring.midY + (box.height - side) / 2)

        let circle = CGPath(
            ellipseIn: ring.offsetBy(dx: (box.width - side) / 2, dy: (box.height - side) / 2), transform: nil
        )
        let arc = CGMutablePath()
        arc.addArc(
            center: ringCenter,
            radius: ring.width / 2,
            startAngle: 0,
            endAngle: -2 * .pi * MusicSpinnerGeometry.arcShare,
            clockwise: true
        )
        trackLayer.bounds = arcBounds
        trackLayer.position = center
        trackLayer.path = circle
        trackLayer.lineWidth = lineWidth
        arcLayer.bounds = arcBounds
        arcLayer.position = center
        arcLayer.path = arc
        arcLayer.lineWidth = lineWidth
    }
}

/// The spinner's layers in SwiftUI.
private struct MusicSpinnerLayer: NSViewRepresentable {
    let lineWidth: CGFloat
    let color: Color
    let track: Color

    /// Read only so that the popup closing and opening again updates the layer (the turn is not gated on it: the hover
    /// card's spinner is outside the popup and never sees it true). A window that was ordered out can lose the
    /// animation of its layers; this update gives it back.
    @Environment(\.musicPopupIsVisible) private var isPopupVisible

    func makeNSView(context: Context) -> MusicSpinnerView {
        let view = MusicSpinnerView(frame: .zero)
        configure(view, in: context)
        view.startTurning()
        return view
    }

    func updateNSView(_ view: MusicSpinnerView, context: Context) {
        configure(view, in: context)
        // Asking for a turn that is running does nothing.
        view.startTurning()
    }

    private func configure(_ view: MusicSpinnerView, in context: Context) {
        view.configure(
            lineWidth: lineWidth,
            color: MusicSpinnerPaint.cgColor(color.resolve(in: context.environment)),
            track: MusicSpinnerPaint.cgColor(track.resolve(in: context.environment))
        )
    }
}

/// A faint ring with an arc of a quarter turn that goes round once per 0.8 s. It has no accessibility label of its
/// own: the card or row that holds it says what is loading.
struct MusicSpinner: View {
    var size: CGFloat = 18
    var lineWidth: CGFloat = 2
    /// The turning arc, and the ring it runs on. The usual pair reads on the dark popup; the play button's dark
    /// spinner asks for its own.
    var color: Color = .primary
    var track: Color = MusicStyle.Palette.sliderTrack

    var body: some View {
        // The ring sits inside its box, as drawn: its diameter is three quarters of the box.
        MusicSpinnerLayer(lineWidth: lineWidth, color: color, track: track)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
