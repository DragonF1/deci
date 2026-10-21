// Deci/Views/Music/MusicRateBurstView.swift
// Draws the like animation (MusicRateBurst) for one burst: the thumb that collapses and pops back filled, and the ring of
// sparks around it, or, for a rating taken back, the outline thumb that fades in and settles. One view serves the popup's
// Like and Dislike buttons and the menu bar pill; they differ only in the size of the thumb and in how far the sparks may
// reach. The sparks are painted over the thumb's box and past it, out of
// the layout, so they never move a neighbour and take no clicks.

import SwiftUI

/// The colours of YouTube's like burst: red dashes and pink dots, read off its frames.
private enum MusicRateBurstPalette {
    static let dash = Color(red: 1, green: 0, blue: 0.2)
    static let dot = Color(red: 1, green: 0.306, blue: 0.525)
}

/// The burst for `event`, following the clock from the event's start. After the animation it is a still thumb, filled for a
/// burst and the outline for a removal, and the clock stops. A `pinnedElapsed` draws one instant instead, for a render.
struct MusicRateBurstView: View {
    let event: MusicRateBurstCenter.Event
    /// The side of the thumb's box.
    let glyphSize: CGFloat
    /// How bright the outline thumb is at the start. The strip rests at the transport's 0.5; the pill is full.
    let restingOpacity: Double
    /// How far from the thumb's middle the sparks may reach; `.infinity` for no limit.
    let sparkReach: CGFloat
    var pinnedElapsed: TimeInterval?
    /// How far the thumb's ink is moved inside its box, in points, to centre it where the surface draws it low or to one
    /// side. The sparks stay on the box's middle.
    var inkOffset: CGSize = .zero
    /// Whether a removal's thumb comes in from nothing. False when it comes onto a thumb that is already showing, which
    /// would otherwise vanish and return.
    var fadesIn = true

    var body: some View {
        if let pinnedElapsed {
            frameView(at: pinnedElapsed)
        } else {
            TimelineView(.animation(paused: Date().timeIntervalSince(event.startedAt) > event.duration)) { context in
                frameView(at: context.date.timeIntervalSince(event.startedAt))
            }
        }
    }

    /// The frame drawn `elapsed` seconds into the event.
    func drawnFrame(at elapsed: TimeInterval) -> MusicRateBurst.Frame {
        var frame = MusicRateBurst.frame(at: elapsed, kind: event.kind, reduceMotion: event.reduceMotion, isRemoval: event.isRemoval)
        if !fadesIn { frame.opacity = 1 }
        return frame
    }

    private func frameView(at elapsed: TimeInterval) -> some View {
        MusicRateBurstFrameView(
            kind: event.kind,
            frame: drawnFrame(at: elapsed),
            glyphSize: glyphSize,
            restingOpacity: restingOpacity,
            sparkReach: sparkReach,
            inkOffset: inkOffset
        )
    }
}

/// One instant of the burst. Exactly `glyphSize` square, whatever the frame: the thumb scales and tilts inside that box
/// and the sparks overflow it from an overlay.
struct MusicRateBurstFrameView: View {
    let kind: MusicRateBurst.Kind
    let frame: MusicRateBurst.Frame
    let glyphSize: CGFloat
    let restingOpacity: Double
    let sparkReach: CGFloat
    /// Moves the thumb's ink inside the box, with the scale and the tilt; the box and the sparks stay where they are.
    var inkOffset: CGSize = .zero

    /// The ring has eight dashes, and eight dots between them.
    private static let dashCount = 8

    var body: some View {
        ZStack {
            thumb(filled: false)
                .opacity(restingOpacity * (1 - frame.fill))
            thumb(filled: true)
                .opacity(frame.fill)
        }
        .opacity(frame.opacity)
        .offset(inkOffset)
        .scaleEffect(frame.scale)
        .rotationEffect(.degrees(frame.rotation))
        .frame(width: glyphSize, height: glyphSize)
        .overlay {
            if let sparks = frame.sparks {
                sparkCanvas(sparks)
            }
        }
    }

    private func thumb(filled: Bool) -> some View {
        let base = kind == .like ? "hand.thumbsup" : "hand.thumbsdown"
        return Image(systemName: filled ? base + ".fill" : base)
            .font(.system(size: glyphSize, weight: .medium))
            .foregroundStyle(Color.white)
    }

    /// The ring, in a canvas big enough for the farthest spark. The canvas is larger than the glyph's box, and an overlay
    /// does not grow its parent, so the layout stays the size of the thumb.
    private func sparkCanvas(_ sparks: MusicRateBurst.Sparks) -> some View {
        let scale = MusicRateBurst.sparkScale(glyphSize: Double(glyphSize), reach: Double(sparkReach))
        let reach = glyphSize * MusicRateBurst.sparkExtent * scale
        let side = 2 * reach + 4
        return Canvas { context, size in
            let middle = CGPoint(x: size.width / 2, y: size.height / 2)
            let unit = Double(glyphSize) * scale
            let radius = sparks.radius * unit
            let width = sparks.dotDiameter * unit
            let length = max(sparks.dashLength * unit, width)
            context.opacity = sparks.opacity
            for index in 0..<Self.dashCount {
                let angle = Double(index) * 2 * .pi / Double(Self.dashCount)
                // A dash: a capsule lying along the ray from the middle, its middle on the ring.
                var dash = Path(roundedRect: CGRect(x: -length / 2, y: -width / 2, width: length, height: width), cornerRadius: width / 2)
                dash = dash.applying(
                    CGAffineTransform(rotationAngle: angle).concatenating(
                        CGAffineTransform(translationX: middle.x + cos(angle) * radius, y: middle.y + sin(angle) * radius)
                    )
                )
                context.fill(dash, with: .color(MusicRateBurstPalette.dash))

                // A dot half-way round to the next dash.
                let between = angle + .pi / Double(Self.dashCount)
                let dot = CGRect(
                    x: middle.x + cos(between) * radius - width / 2,
                    y: middle.y + sin(between) * radius - width / 2,
                    width: width,
                    height: width
                )
                context.fill(Path(ellipseIn: dot), with: .color(MusicRateBurstPalette.dot))
            }
        }
        .frame(width: side, height: side)
        .allowsHitTesting(false)
    }
}
