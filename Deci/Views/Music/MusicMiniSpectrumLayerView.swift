// Deci/Views/Music/MusicMiniSpectrumLayerView.swift
import AppKit
import SwiftUI

/// The playing row's four bars as layers. While the song plays each bar's height runs one repeating keyframe animation
/// (a sampled sine, `MusicMiniSpectrum.swingHeights`) that the render server plays; at rest the bars stand at their rest
/// heights. Nothing in the app runs per frame, so the popup's window is not updated for it.
@MainActor
final class MusicMiniSpectrumLayerView: NSView {
    static let swingKey = "swing"

    let barLayers: [CALayer]
    /// How many times the swing was added to the bars (once when the song starts, and again only if the system took
    /// it away).
    private(set) var swingsStarted = 0
    private(set) var isAnimating = false

    override init(frame frameRect: NSRect) {
        barLayers = (0..<MusicMiniSpectrum.barCount).map { _ in CALayer() }
        super.init(frame: frameRect)
        wantsLayer = true
        for (index, bar) in barLayers.enumerated() {
            // Anchored at the bottom left corner, so a bar's height grows upward from the row's baseline.
            bar.anchorPoint = .zero
            bar.cornerRadius = MusicMiniSpectrum.radius
            bar.cornerCurve = .continuous
            bar.actions = ["bounds": NSNull(), "position": NSNull(), "backgroundColor": NSNull()]
            bar.bounds = CGRect(x: 0, y: 0, width: MusicMiniSpectrum.barWidth, height: MusicMiniSpectrum.restHeights[index])
            bar.position = CGPoint(x: MusicMiniSpectrum.barX(index), y: 0)
            layer?.addSublayer(bar)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // A layer that leaves the screen can lose its animations: bring the swing back with the view.
        if window != nil { swing() }
    }

    /// The look: whether the bars swing, and their colour.
    func update(isAnimating shouldAnimate: Bool, color: CGColor) {
        for bar in barLayers { bar.backgroundColor = color }
        isAnimating = shouldAnimate
        if shouldAnimate {
            swing()
        } else {
            for bar in barLayers { bar.removeAnimation(forKey: Self.swingKey) }
        }
    }

    /// Adds the swing to every bar that is not swinging.
    private func swing() {
        guard isAnimating else { return }
        var added = false
        for (index, bar) in barLayers.enumerated() where bar.animation(forKey: Self.swingKey) == nil {
            let swing = CAKeyframeAnimation(keyPath: "bounds.size.height")
            swing.values = MusicMiniSpectrum.swingHeights(of: index).map { NSNumber(value: Double($0)) }
            swing.calculationMode = .linear
            swing.duration = MusicMiniSpectrum.periods[index]
            swing.repeatCount = .infinity
            swing.isRemovedOnCompletion = false
            bar.add(swing, forKey: Self.swingKey)
            added = true
        }
        if added { swingsStarted += 1 }
    }
}

/// The bars in SwiftUI.
struct MusicMiniSpectrumLayer: NSViewRepresentable {
    let isAnimating: Bool
    let color: Color

    func makeNSView(context: Context) -> MusicMiniSpectrumLayerView {
        let view = MusicMiniSpectrumLayerView(frame: NSRect(x: 0, y: 0, width: MusicMiniSpectrum.width, height: MusicMiniSpectrum.height))
        view.update(isAnimating: isAnimating, color: MusicSpinnerPaint.cgColor(color.resolve(in: context.environment)))
        return view
    }

    func updateNSView(_ view: MusicMiniSpectrumLayerView, context: Context) {
        view.update(isAnimating: isAnimating, color: MusicSpinnerPaint.cgColor(color.resolve(in: context.environment)))
    }
}
