// DeciTests/Music/MusicWaveLayerTests.swift
// The hover card's wave as Core Animation layers. A SwiftUI TimelineView(.animation) with a Canvas drew the ripple, which
// made the card's hosting view lay out and render through Metal on every display frame (about 17% of a core while the
// card was up and a song played). The ripple is now one keyframe animation of the curve's path that the render server
// loops. Covered: the paths against MusicWave.profile at sample phases, the linear blend's error between keyframes, the
// animation (keys, count, duration, repeat, begin time), that the ripple does not jump when the animation is rebuilt or
// when it stops and starts, that it is still when paused, with Reduce Motion, and in a window nobody can see, that the
// paths are rebuilt only when an input changes, the layers' colours and lines, that the picture matches the old Canvas
// drawing, and that the card's hosting view is not laid out per frame.

import AppKit
import QuartzCore
import SwiftUI
import Testing
@testable import Deci

// MARK: - Helpers

private let levels: [Double] = (0..<60).map { 0.15 + 0.75 * abs(sin(Double($0) * 0.7)) }
private let sampleTint = MusicTint(hue: 0.55, saturation: 0.7, brightness: 0.8)
private let width = 276.0

private struct Element {
    let type: Int32
    let points: [CGPoint]
}

private func elements(_ path: CGPath) -> [Element] {
    var result: [Element] = []
    path.applyWithBlock { pointer in
        let element = pointer.pointee
        let count: Int
        switch element.type {
        case .moveToPoint, .addLineToPoint: count = 1
        case .addQuadCurveToPoint: count = 2
        case .addCurveToPoint: count = 3
        case .closeSubpath: count = 0
        @unknown default: count = 0
        }
        let points = (0..<count).map { element.points[$0] }
        result.append(Element(type: element.type.rawValue, points: points))
    }
    return result
}

/// The path's points, turned back to the wave's own numbers (y grows downward).
private func points(_ path: CGPath?) -> [CGPoint] {
    guard let path else { return [] }
    return elements(path).flatMap(\.points).map { CGPoint(x: $0.x, y: CGFloat(MusicWave.boxHeight) - $0.y) }
}

/// Where a path goes, in the wave's own numbers: the end of every segment. The render side hands back an interpolated path
/// as cubic segments, with one more line back to the start before the close, so the same curve has the same end points
/// but not the same elements as the one the layer was given.
private func outline(_ path: CGPath?) -> [CGPoint] {
    guard let path else { return [] }
    var ends: [CGPoint] = []
    path.applyWithBlock { pointer in
        let element = pointer.pointee
        let count: Int
        switch element.type {
        case .moveToPoint, .addLineToPoint: count = 1
        case .addQuadCurveToPoint: count = 2
        case .addCurveToPoint: count = 3
        case .closeSubpath: count = 0
        @unknown default: count = 0
        }
        if count > 0 { ends.append(element.points[count - 1]) }
    }
    if ends.count > 1, ends.last == ends.first { ends.removeLast() }
    return ends.map { CGPoint(x: $0.x, y: CGFloat(MusicWave.boxHeight) - $0.y) }
}

private func maxDifference(_ a: [CGPoint], _ b: [CGPoint]) -> Double {
    guard a.count == b.count else { return .infinity }
    var worst = 0.0
    for (p, q) in zip(a, b) {
        worst = max(worst, abs(Double(p.x) - Double(q.x)), abs(Double(p.y) - Double(q.y)))
    }
    return worst
}

private func expectedPoints(progress: Double, phase: Double, width: Double = width) -> [CGPoint] {
    points(MusicWaveShapes.stillPath(levels: levels, progress: progress, width: width, phase: phase))
}

// MARK: - Shapes

@Suite("MusicWaveShapes")
struct MusicWaveShapesTests {
    @Test("a turn of the ripple takes the time the ripple's speed says, in 48 parts")
    func turn() {
        #expect(MusicWaveShapes.parts == 48)
        #expect(abs(MusicWaveShapes.period - 1 / 0.9) < 1e-12)
        #expect(abs(MusicWaveShapes.period * MusicWave.rippleSpeed - 2 * .pi) < 1e-12)
        #expect(MusicWaveShapes.phase(ofKeyframe: 0) == 0)
        #expect(abs(MusicWaveShapes.phase(ofKeyframe: MusicWaveShapes.parts) - 2 * .pi) < 1e-12)
    }

    @Test("the phase after some time is the ripple's, wrapped to a turn and never negative")
    func phaseOfElapsed() {
        #expect(MusicWaveShapes.phase(elapsed: 0) == 0)
        #expect(abs(MusicWaveShapes.phase(elapsed: 0.25) - 0.25 * MusicWave.rippleSpeed) < 1e-12)
        #expect(abs(MusicWaveShapes.phase(elapsed: 0.25 + MusicWaveShapes.period) - 0.25 * MusicWave.rippleSpeed) < 1e-9)
        let before = MusicWaveShapes.phase(elapsed: -0.25)
        #expect(before >= 0 && before < 2 * .pi)
        #expect(abs(cos(before) - cos(0.25 * MusicWave.rippleSpeed)) < 1e-12)
        #expect(MusicWaveShapes.phase(elapsed: .nan) == 0)
        #expect(MusicWaveShapes.phase(elapsed: .infinity) == 0)
    }

    @Test("the nearest keyframe to a phase wraps round at the end of the turn")
    func nearest() {
        #expect(MusicWaveShapes.nearestKeyframe(toPhase: 0) == 0)
        #expect(MusicWaveShapes.nearestKeyframe(toPhase: MusicWaveShapes.phase(ofKeyframe: 7)) == 7)
        #expect(MusicWaveShapes.nearestKeyframe(toPhase: MusicWaveShapes.phase(ofKeyframe: 7) + 0.01) == 7)
        #expect(MusicWaveShapes.nearestKeyframe(toPhase: 2 * .pi - 0.001) == 0)
        #expect(MusicWaveShapes.nearestKeyframe(toPhase: .nan) == 0)
        #expect(MusicWaveShapes.nearestKeyframe(toPhase: 2 * .pi + 0.01) == 0)
    }

    @Test("a curve exists exactly when MusicWave.profile has samples", arguments: [
        (0.0, 276.0), (0.0001, 276.0), (0.5, 276.0), (1.0, 276.0), (-1.0, 276.0), (.nan, 276.0), (.infinity, 276.0),
        (0.5, 0.0), (0.5, 12.0), (0.5, 13.0), (0.5, .nan), (0.00001, 276.0),
    ])
    func hasCurve(progress: Double, width: Double) {
        let expected = !MusicWave.profile(levels: levels, progress: progress, width: width, phase: 0).isEmpty
        #expect(MusicWaveShapes.hasCurve(progress: progress, width: width) == expected)
    }

    @Test("the curve is the profile's samples: up from the baseline, along the heights, back to the baseline, closed",
          arguments: [0.0, 0.7, 2.5, 4.4, 6.0])
    func curveMatchesProfile(phase: Double) throws {
        let samples = MusicWave.profile(levels: levels, progress: 0.6, width: width, phase: phase)
        let path = try #require(MusicWaveShapes.stillPath(levels: levels, progress: 0.6, width: width, phase: phase))
        let parts = elements(path)
        // A move, a line to every sample, a line down to the baseline, and the close.
        #expect(parts.count == samples.count + 3)
        #expect(parts.first?.type == CGPathElementType.moveToPoint.rawValue)
        #expect(parts.last?.type == CGPathElementType.closeSubpath.rawValue)
        let found = points(path)
        #expect(found.count == samples.count + 2)
        let base = MusicWave.baselineY
        #expect(Double(found[0].x) == samples[0].x && Double(found[0].y) == base)
        for (index, sample) in samples.enumerated() {
            #expect(abs(Double(found[index + 1].x) - sample.x) < 1e-9)
            #expect(abs(Double(found[index + 1].y) - (base - sample.height)) < 1e-9)
        }
        #expect(Double(found[found.count - 1].y) == base)
        #expect(Double(found[found.count - 1].x) == samples[samples.count - 1].x)
    }

    @Test("in the layer's own numbers the baseline is 15 pt from the top and a tall swell rises toward the top of the box")
    func orientation() throws {
        let path = try #require(MusicWaveShapes.stillPath(levels: levels, progress: 0.6, width: width, phase: 0))
        let raw = elements(path).flatMap(\.points)
        let lowest = raw.map(\.y).min() ?? 0
        #expect(Double(raw[0].y) == MusicWave.boxHeight - MusicWave.baselineY)
        #expect(Double(lowest) == MusicWave.boxHeight - MusicWave.baselineY)
        #expect(Double(raw.map(\.y).max() ?? 0) > MusicWave.boxHeight - MusicWave.baselineY + 6)
        #expect(Double(raw.map(\.y).max() ?? 0) <= MusicWave.boxHeight - MusicWave.baselineY + MusicWave.maxAmplitude)
    }

    @Test("a turn of the ripple is 49 paths with the same elements, and the last is the first again")
    func keyframes() throws {
        let frames = try #require(MusicWaveShapes.rippleKeyframes(levels: levels, progress: 0.6, width: width))
        #expect(frames.count == MusicWaveShapes.parts + 1)
        #expect(frames[0] == frames[MusicWaveShapes.parts])
        let types = elements(frames[0]).map(\.type)
        for frame in frames {
            #expect(elements(frame).map(\.type) == types)
        }
        // Each is the profile at the phase of its part.
        for index in stride(from: 0, through: MusicWaveShapes.parts, by: 6) {
            let expected = expectedPoints(progress: 0.6, phase: MusicWaveShapes.phase(ofKeyframe: index))
            #expect(maxDifference(points(frames[index]), expected) < 1e-9)
        }
    }

    @Test("the turn starts and ends on the same picture, so the loop has no seam")
    func seamless() {
        let start = expectedPoints(progress: 0.6, phase: 0)
        let end = expectedPoints(progress: 0.6, phase: 2 * .pi)
        #expect(maxDifference(start, end) < 1e-9)
    }

    @Test("blending two neighbouring keyframes linearly stays within a hundredth of a point of the true curve")
    func blendError() throws {
        let frames = try #require(MusicWaveShapes.rippleKeyframes(levels: levels, progress: 0.8, width: width))
        let step = 2 * Double.pi / Double(MusicWaveShapes.parts)
        var worst = 0.0
        for index in 0..<MusicWaveShapes.parts {
            let a = points(frames[index])
            let b = points(frames[index + 1])
            for fraction in [0.25, 0.5, 0.75] {
                let exact = expectedPoints(progress: 0.8, phase: MusicWaveShapes.phase(ofKeyframe: index) + fraction * step)
                let blended = zip(a, b).map { CGPoint(x: $0.x, y: $0.y + (CGFloat(fraction) * ($1.y - $0.y))) }
                worst = max(worst, maxDifference(blended, exact))
            }
        }
        #expect(worst < 0.01)
    }

    @Test("the loop, the ripple's cosine, is slow enough that a part is under two and a half hundredths of a second")
    func partIsShort() {
        #expect(MusicWaveShapes.period / Double(MusicWaveShapes.parts) < 0.025)
    }

    @Test("nothing played gives no keyframes, no baseline and no curve")
    func nothingPlayed() {
        #expect(MusicWaveShapes.rippleKeyframes(levels: levels, progress: 0, width: width) == nil)
        #expect(MusicWaveShapes.baselinePath(progress: 0, width: width) == nil)
        #expect(MusicWaveShapes.stillPath(levels: levels, progress: 0, width: width, phase: 0) == nil)
        #expect(MusicWaveShapes.rippleKeyframes(levels: levels, progress: 0.5, width: 8) == nil)
    }

    @Test("the unplayed line runs from the playhead to the inset at the far end, on the baseline")
    func rest() {
        let found = points(MusicWaveShapes.restPath(progress: 0.25, width: width))
        #expect(found.count == 2)
        #expect(Double(found[0].x) == MusicWave.playheadX(progress: 0.25, width: width))
        #expect(Double(found[1].x) == width - MusicWave.inset)
        #expect(Double(found[0].y) == MusicWave.baselineY && Double(found[1].y) == MusicWave.baselineY)
        // At the end of the song it has no length to speak of.
        let end = points(MusicWaveShapes.restPath(progress: 1, width: width))
        #expect(Double(end[0].x) == Double(end[1].x))
    }

    @Test("the line under the curve runs from the inset to the playhead")
    func baseline() throws {
        let found = points(try #require(MusicWaveShapes.baselinePath(progress: 0.4, width: width)))
        #expect(found.count == 2)
        #expect(Double(found[0].x) == MusicWave.inset)
        #expect(Double(found[1].x) == MusicWave.playheadX(progress: 0.4, width: width))
        #expect(Double(found[0].y) == MusicWave.baselineY && Double(found[1].y) == MusicWave.baselineY)
    }

    @Test("the gradient has the three tints, ending on the tint itself, and runs from the inset to the playhead")
    func gradient() {
        let colors = MusicWaveShapes.gradientColors(for: sampleTint)
        #expect(colors.count == 3)
        let tints = MusicWave.gradientTints(for: sampleTint)
        for (color, one) in zip(colors, tints) {
            let rgb = MusicSpectrum.rgb(hue: one.hue, saturation: one.saturation, brightness: one.brightness)
            let parts = color.components ?? []
            #expect(parts.count == 4)
            #expect(abs(Double(parts[0]) - rgb.red) < 1e-6 && abs(Double(parts[1]) - rgb.green) < 1e-6)
            #expect(abs(Double(parts[2]) - rgb.blue) < 1e-6 && Double(parts[3]) == 1)
        }
        let span = MusicWaveShapes.gradientPoints(progress: 0.5, width: width)
        #expect(abs(Double(span.start.x) - MusicWave.inset / width) < 1e-12)
        #expect(abs(Double(span.end.x) - MusicWave.playheadX(progress: 0.5, width: width) / width) < 1e-12)
        // Near the start the gradient is still a point wide, as the Canvas had it.
        let early = MusicWaveShapes.gradientPoints(progress: 0.0001, width: width)
        #expect(abs(Double(early.end.x) - (MusicWave.inset + 1) / width) < 1e-12)
        let none = MusicWaveShapes.gradientPoints(progress: 0.5, width: 0)
        #expect(none.start.x == 0 && none.end.x == 1)
    }
}

// MARK: - The layers

@MainActor
@Suite("MusicWaveLayerView")
struct MusicWaveLayerViewTests {
    /// Whether the test's window counts as one that can be seen, and the media clock.
    private final class Stage {
        var showing = true
        var clock = 100.0
    }

    private func stage(
        showing: Bool = true, inWindow: Bool = true
    ) -> (view: MusicWaveLayerView, window: NSWindow, stage: Stage) {
        let state = Stage()
        state.showing = showing
        let view = MusicWaveLayerView(frame: NSRect(x: 0, y: 0, width: width, height: MusicWave.boxHeight))
        view.windowIsShowing = { [state] _ in state.showing }
        view.now = { [state] in state.clock }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: MusicWave.boxHeight),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: width, height: MusicWave.boxHeight))
        if inWindow { window.contentView?.addSubview(view) }
        return (view, window, state)
    }

    private func close(_ window: NSWindow) {
        window.contentView = nil
        window.close()
    }

    private func play(
        _ view: MusicWaveLayerView, progress: Double = 0.4, levels: [Double] = levels, tint: MusicTint = sampleTint,
        playing: Bool = true, reduceMotion: Bool = false
    ) {
        view.update(levels: levels, progress: progress, tint: tint, isPlaying: playing, reduceMotion: reduceMotion)
    }

    private func fillPoints(_ view: MusicWaveLayerView) -> [CGPoint] {
        points(view.fillLayer.path)
    }

    private func notifyOcclusion(_ window: NSWindow) {
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
    }

    // MARK: Loop

    @Test("a playing wave in a window that can be seen loops one animation of the curve's path for ever")
    func loopSetup() throws {
        let (view, window, _) = stage()
        defer { close(window) }
        play(view)
        #expect(view.isRippling)
        let loop = try #require(view.rippleAnimation)
        #expect(loop.keyPath == "path")
        #expect(loop.calculationMode == .linear)
        #expect(loop.duration == MusicWaveShapes.period)
        #expect(loop.repeatCount == .infinity)
        #expect(loop.isRemovedOnCompletion == false)
        let values = try #require(loop.values)
        #expect(values.count == MusicWaveShapes.parts + 1)
        // No key times: the render server spaces the paths evenly, which is how they were made.
        #expect(loop.keyTimes == nil)
        let frames = try #require(MusicWaveShapes.rippleKeyframes(levels: levels, progress: 0.4, width: width))
        for index in [0, 5, 24, 47, 48] {
            let layerPath = values[index] as! CGPath
            #expect(maxDifference(points(layerPath), points(frames[index])) < 1e-9)
        }
        #expect(loop.beginTime == view.fillLayer.convertTime(view.phaseOrigin, from: nil))
        #expect(view.fillLayer.animationKeys() == [MusicWaveLayerView.rippleKey])
        #expect(view.keyframeBuilds == 1)
    }

    @Test("the first loop begins at phase 0, now")
    func startsAtPhaseZero() {
        let (view, window, state) = stage()
        defer { close(window) }
        state.clock = 250.5
        play(view)
        #expect(view.phaseOrigin == 250.5)
        #expect(maxDifference(fillPoints(view), expectedPoints(progress: 0.4, phase: 0)) < 1e-9)
    }

    @Test("a wave made before its window holds one path, and the loop begins when the window has it")
    func windowArrives() throws {
        let (view, window, _) = stage(inWindow: false)
        defer { close(window) }
        play(view)
        #expect(view.rippleAnimation == nil)
        #expect(view.keyframeBuilds == 0)
        #expect(maxDifference(fillPoints(view), expectedPoints(progress: 0.4, phase: 0)) < 1e-9)
        window.contentView?.addSubview(view)
        #expect(view.isRippling)
        #expect(view.rippleAnimation != nil)
        #expect(view.keyframeBuilds == 1)
    }

    @Test("the layers do not animate on their own: only the loop is on any layer")
    func noImplicitAnimations() {
        let (view, window, _) = stage()
        defer { close(window) }
        play(view)
        play(view, progress: 0.5)
        play(view, progress: 0.6, tint: MusicTint(hue: 0.1, saturation: 0.5, brightness: 0.6))
        #expect(view.fillLayer.animationKeys() == [MusicWaveLayerView.rippleKey])
        #expect(view.lineLayer.animationKeys() == nil)
        #expect(view.restLayer.animationKeys() == nil)
        #expect(view.gradientLayer.animationKeys() == nil)
    }

    @Test("a click lands on the SwiftUI view around the wave, not on the layers")
    func takesNoClicks() {
        let (view, window, _) = stage()
        defer { close(window) }
        #expect(view.hitTest(NSPoint(x: 50, y: 10)) == nil)
    }

    // MARK: Rebuild

    @Test("the loop is rebuilt for a new playhead with the same origin and the same timing: the ripple does not jump")
    func rebuildKeepsThePhase() throws {
        let (view, window, state) = stage()
        defer { close(window) }
        play(view, progress: 0.40)
        let first = try #require(view.rippleAnimation)
        let origin = view.phaseOrigin

        state.clock = 100.37
        play(view, progress: 0.41)
        let second = try #require(view.rippleAnimation)
        #expect(second !== first)
        #expect(view.keyframeBuilds == 2)
        #expect(view.phaseOrigin == origin)
        #expect(second.beginTime == first.beginTime)
        #expect(second.duration == first.duration)
        #expect(second.repeatCount == .infinity)
        #expect(second.values?.count == MusicWaveShapes.parts + 1)
        // The new loop is for the new playhead.
        let newFrames = try #require(MusicWaveShapes.rippleKeyframes(levels: levels, progress: 0.41, width: width))
        #expect(maxDifference(points(second.values?[10] as! CGPath), points(newFrames[10])) < 1e-9)
        // The model path is the loop's picture nearest to now.
        let nearest = MusicWaveShapes.nearestKeyframe(toPhase: MusicWaveShapes.phase(elapsed: 0.37))
        #expect(maxDifference(fillPoints(view), points(newFrames[nearest])) < 1e-9)
    }

    @Test("the paths are rebuilt only when an input changes")
    func rebuildsOnlyOnChange() {
        let (view, window, state) = stage()
        defer { close(window) }
        play(view)
        #expect(view.paints == 1 && view.keyframeBuilds == 1 && view.stillBuilds == 0)

        // The same inputs again and again, and the window's notices with nothing new in them: no work.
        for _ in 0..<20 {
            play(view)
            view.sync()
            notifyOcclusion(window)
        }
        #expect(view.paints == 1 && view.keyframeBuilds == 1 && view.stillBuilds == 0)

        play(view, progress: 0.41)
        #expect(view.paints == 2 && view.keyframeBuilds == 2)
        play(view, progress: 0.41, tint: MusicTint(hue: 0.9, saturation: 0.6, brightness: 0.7))
        #expect(view.paints == 3 && view.keyframeBuilds == 3)
        play(view, progress: 0.41, levels: levels.reversed(), tint: MusicTint(hue: 0.9, saturation: 0.6, brightness: 0.7))
        #expect(view.paints == 4 && view.keyframeBuilds == 4)
        view.setFrameSize(NSSize(width: 300, height: MusicWave.boxHeight))
        #expect(view.paints == 5 && view.keyframeBuilds == 5)
        // The same size again is nothing.
        view.setFrameSize(NSSize(width: 300, height: MusicWave.boxHeight))
        #expect(view.paints == 5 && view.keyframeBuilds == 5)
        #expect(view.stillBuilds == 0)
        _ = state
    }

    @Test("a window that grows or shrinks makes the loop for the new width")
    func resize() throws {
        let (view, window, _) = stage()
        defer { close(window) }
        play(view)
        view.setFrameSize(NSSize(width: 200, height: MusicWave.boxHeight))
        let loop = try #require(view.rippleAnimation)
        let frames = try #require(MusicWaveShapes.rippleKeyframes(levels: levels, progress: 0.4, width: 200))
        #expect(maxDifference(points(loop.values?[3] as! CGPath), points(frames[3])) < 1e-9)
        #expect(view.gradientLayer.frame.width == 200)
        #expect(view.fillLayer.frame.width == 200)
    }

    // MARK: Still

    @Test("a song that is not playing holds one path at phase 0 and has no animation")
    func pausedFromTheStart() {
        let (view, window, _) = stage()
        defer { close(window) }
        play(view, playing: false)
        #expect(!view.isRippling)
        #expect(view.rippleAnimation == nil)
        #expect(view.fillLayer.animationKeys() == nil)
        #expect(view.keyframeBuilds == 0 && view.stillBuilds == 1)
        #expect(maxDifference(fillPoints(view), expectedPoints(progress: 0.4, phase: 0)) < 1e-9)
    }

    @Test("Reduce Motion holds the curve at phase 0 while the song plays, and the loop comes back without it")
    func reduceMotion() {
        let (view, window, _) = stage()
        defer { close(window) }
        play(view, reduceMotion: true)
        #expect(view.rippleAnimation == nil)
        #expect(maxDifference(fillPoints(view), expectedPoints(progress: 0.4, phase: 0)) < 1e-9)
        #expect(view.keyframeBuilds == 0)

        play(view, reduceMotion: false)
        #expect(view.rippleAnimation != nil)
        #expect(view.keyframeBuilds == 1)

        play(view, reduceMotion: true)
        #expect(view.rippleAnimation == nil)
        #expect(view.frozenPhase == 0)
        #expect(maxDifference(fillPoints(view), expectedPoints(progress: 0.4, phase: 0)) < 1e-9)
    }

    @Test("pausing stops the loop where it stands, with one path at that phase, and no more keyframes are built")
    func pause() throws {
        let (view, window, state) = stage()
        defer { close(window) }
        play(view)
        state.clock = 100.31
        play(view, playing: false)
        #expect(view.rippleAnimation == nil)
        #expect(view.fillLayer.animationKeys() == nil)
        let phase = MusicWaveShapes.phase(elapsed: 0.31)
        #expect(abs(view.frozenPhase - phase) < 1e-9)
        #expect(maxDifference(fillPoints(view), expectedPoints(progress: 0.4, phase: phase)) < 1e-9)
        #expect(view.keyframeBuilds == 1 && view.stillBuilds == 1)

        // A new playhead while paused moves the curve and keeps the phase; there is still nothing to loop.
        state.clock = 140
        play(view, progress: 0.42, playing: false)
        #expect(view.rippleAnimation == nil)
        #expect(abs(view.frozenPhase - phase) < 1e-9)
        #expect(maxDifference(fillPoints(view), expectedPoints(progress: 0.42, phase: phase)) < 1e-9)
        #expect(view.keyframeBuilds == 1)
    }

    @Test("playing again continues the ripple from the phase it stopped at")
    func resume() throws {
        let (view, window, state) = stage()
        defer { close(window) }
        play(view)
        state.clock = 100.31
        play(view, playing: false)
        let stopped = view.frozenPhase

        state.clock = 190.0
        play(view, playing: true)
        let loop = try #require(view.rippleAnimation)
        #expect(view.keyframeBuilds == 2)
        // The phase on the loop's own clock right now is where it stopped.
        let now = state.clock
        #expect(abs(MusicWaveShapes.phase(elapsed: now - view.phaseOrigin) - stopped) < 1e-9)
        #expect(loop.beginTime == view.fillLayer.convertTime(view.phaseOrigin, from: nil))
        // And a little later, the phase has moved on by the time.
        #expect(abs(MusicWaveShapes.phase(elapsed: now + 0.1 - view.phaseOrigin) - (stopped + 0.1 * MusicWave.rippleSpeed)) < 1e-9)
    }

    @Test("nothing played yet has no curve, no gradient and no loop, and the unplayed line shows")
    func nothingPlayedYet() throws {
        let (view, window, _) = stage()
        defer { close(window) }
        play(view, progress: 0)
        #expect(view.rippleAnimation == nil)
        #expect(view.fillLayer.path == nil)
        #expect(view.lineLayer.path == nil)
        #expect(view.gradientLayer.isHidden)
        let rest = points(view.restLayer.path)
        #expect(Double(rest[0].x) == MusicWave.inset && Double(rest[1].x) == width - MusicWave.inset)

        play(view, progress: 0.2)
        #expect(view.rippleAnimation != nil)
        #expect(!view.gradientLayer.isHidden)
        #expect(view.lineLayer.path != nil)
    }

    // MARK: The window

    @Test("a window nobody can see gets no loop and builds none, however the inputs change, until it can be seen")
    func hiddenWindow() throws {
        let (view, window, state) = stage(showing: false)
        defer { close(window) }
        play(view)
        play(view, progress: 0.45)
        play(view, progress: 0.5, playing: true)
        #expect(view.rippleAnimation == nil)
        #expect(view.keyframeBuilds == 0)
        #expect(view.fillLayer.animationKeys() == nil)
        // It still holds the picture, one path of it, for a window that turns up without a notice.
        #expect(maxDifference(fillPoints(view), expectedPoints(progress: 0.5, phase: 0)) < 1e-9)

        state.showing = true
        notifyOcclusion(window)
        #expect(view.isRippling)
        #expect(view.keyframeBuilds == 1)
        #expect(view.rippleAnimation != nil)
    }

    @Test("a window that is ordered out or covered takes the loop off and does no more work; showing it again brings it back")
    func hidingStops() throws {
        let (view, window, state) = stage()
        defer { close(window) }
        play(view)
        state.clock = 100.4
        state.showing = false
        notifyOcclusion(window)
        #expect(view.rippleAnimation == nil)
        #expect(view.fillLayer.animationKeys() == nil)
        let stopped = view.frozenPhase
        #expect(abs(stopped - MusicWaveShapes.phase(elapsed: 0.4)) < 1e-9)

        // Inputs that change while it is hidden build nothing that moves.
        play(view, progress: 0.43)
        play(view, progress: 0.44)
        #expect(view.keyframeBuilds == 1)
        #expect(view.rippleAnimation == nil)

        state.clock = 130
        state.showing = true
        notifyOcclusion(window)
        #expect(view.rippleAnimation != nil)
        #expect(view.keyframeBuilds == 2)
        #expect(abs(MusicWaveShapes.phase(elapsed: state.clock - view.phaseOrigin) - stopped) < 1e-9)
    }

    @Test("a window that is closing takes the loop off even if it still reports as seen")
    func closing() {
        let (view, window, _) = stage()
        defer { close(window) }
        play(view)
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
        #expect(view.rippleAnimation == nil)
        play(view, progress: 0.5)
        #expect(view.rippleAnimation == nil)
    }

    @Test("an update from the view tree puts the loop right when the window changed without a notice")
    func updateCatchesUp() {
        let (view, window, state) = stage()
        defer { close(window) }
        play(view)
        state.showing = false
        play(view)
        #expect(view.rippleAnimation == nil)
        state.showing = true
        play(view)
        #expect(view.rippleAnimation != nil)
    }

    @Test("leaving the window takes the loop off")
    func leavingTheWindow() {
        let (view, window, _) = stage()
        defer { close(window) }
        play(view)
        view.removeFromSuperview()
        #expect(view.rippleAnimation == nil)
        #expect(!view.isRippling)
    }

    @Test("a view the tree lets go of stops, and starts again when it is asked")
    func dismantle() {
        let (view, window, _) = stage()
        defer { close(window) }
        play(view)
        view.stop()
        #expect(view.rippleAnimation == nil)
        play(view)
        #expect(view.rippleAnimation != nil)
    }

    // MARK: Layers

    @Test("the unplayed line, the gradient and the cut that makes the curve are set from the inputs")
    func staticLayers() throws {
        let (view, window, _) = stage()
        defer { close(window) }
        play(view, progress: 0.4)
        #expect(maxDifference(points(view.restLayer.path), points(MusicWaveShapes.restPath(progress: 0.4, width: width))) < 1e-9)
        #expect(maxDifference(points(view.lineLayer.path), points(MusicWaveShapes.baselinePath(progress: 0.4, width: width))) < 1e-9)
        let colors = try #require(view.gradientLayer.colors as? [CGColor])
        #expect(colors.count == 3)
        let span = MusicWaveShapes.gradientPoints(progress: 0.4, width: width)
        #expect(view.gradientLayer.startPoint == span.start && view.gradientLayer.endPoint == span.end)
        #expect(view.gradientLayer.mask?.sublayers?.count == 2)
        #expect(view.gradientLayer.mask?.sublayers?.contains(view.fillLayer) == true)
        #expect(view.gradientLayer.mask?.sublayers?.contains(view.lineLayer) == true)
        #expect(view.lineLayer.lineWidth == 2 && view.lineLayer.lineCap == .round)
        #expect(view.restLayer.lineWidth == 2 && view.restLayer.lineCap == .round)
        #expect(view.restLayer.strokeColor?.alpha == 0.25)
        #expect(view.fillLayer.fillColor?.alpha == 1)
    }

    @Test("the layers fill a 22 pt box at the top of the view, whatever the view's height")
    func boxAtTheTop() {
        let (view, window, _) = stage()
        defer { close(window) }
        view.setFrameSize(NSSize(width: 276, height: 30))
        #expect(view.restLayer.superlayer?.frame == CGRect(x: 0, y: 8, width: 276, height: 22))
        #expect(view.restLayer.frame == CGRect(x: 0, y: 0, width: 276, height: 22))
        #expect(view.gradientLayer.frame == CGRect(x: 0, y: 0, width: 276, height: 22))
    }

    // MARK: In a window that is on screen

    private func show(_ content: NSView, size: NSSize = NSSize(width: 300, height: 60)) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: 200, y: 200), size: size), styleMask: [.borderless], backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.collectionBehavior = [.transient, .ignoresCycle, .stationary]
        window.contentView = content
        window.orderFrontRegardless()
        return window
    }

    /// The largest difference in y between the path on the screen now and the one the profile gives for the phase of the
    /// loop on the media clock, taking the middle of the clock's reading across the read.
    private func presentedError(_ view: MusicWaveLayerView, progress: Double) throws -> Double {
        let before = CACurrentMediaTime()
        let presentation = try #require(view.fillLayer.presentation())
        let path = try #require(presentation.path)
        let after = CACurrentMediaTime()
        let phase = MusicWaveShapes.phase(elapsed: (before + after) / 2 - view.phaseOrigin)
        return maxDifference(outline(path), outline(MusicWaveShapes.stillPath(levels: levels, progress: progress, width: width, phase: phase)))
    }

    @Test("on the render side the curve follows the loop: the picture is the profile at the clock's phase")
    func presentationFollowsTheClock() async throws {
        let holder = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 60))
        let view = MusicWaveLayerView(frame: NSRect(x: 0, y: 20, width: width, height: MusicWave.boxHeight))
        holder.addSubview(view)
        let window = show(holder)
        defer { close(window) }
        play(view)
        try await Task.sleep(for: .milliseconds(200))
        #expect(view.isRippling)
        // The loop is between keyframes most of the time: the error is the blend's and the clock's.
        for _ in 0..<6 {
            let error = try presentedError(view, progress: 0.4)
            #expect(error < 1.0)
            try await Task.sleep(for: .milliseconds(137))
        }
        // And the picture does move: one read and a later one differ.
        let a = outline(view.fillLayer.presentation()?.path)
        try await Task.sleep(for: .milliseconds(300))
        let b = outline(view.fillLayer.presentation()?.path)
        #expect(maxDifference(a, b) > 1)
    }

    @Test("a rebuild in the middle of the loop does not move the ripple")
    func presentationIsContinuousAcrossARebuild() async throws {
        let holder = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 60))
        let view = MusicWaveLayerView(frame: NSRect(x: 0, y: 20, width: width, height: MusicWave.boxHeight))
        holder.addSubview(view)
        let window = show(holder)
        defer { close(window) }
        play(view, progress: 0.40)
        try await Task.sleep(for: .milliseconds(380))
        let origin = view.phaseOrigin
        var progress = 0.40
        for _ in 0..<5 {
            progress += 0.002
            play(view, progress: progress)
            #expect(view.phaseOrigin == origin)
            // Straight after the rebuild the picture is at the same phase of the same clock, for the new playhead.
            let error = try presentedError(view, progress: progress)
            #expect(error < 1.0)
            try await Task.sleep(for: .milliseconds(97))
        }
        #expect(view.keyframeBuilds == 6)
    }

    @Test("in a window that is ordered out, the render side holds one picture; ordered in again, the loop is back")
    func orderingOutAndIn() async throws {
        let holder = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 60))
        let view = MusicWaveLayerView(frame: NSRect(x: 0, y: 20, width: width, height: MusicWave.boxHeight))
        holder.addSubview(view)
        let window = show(holder)
        defer { close(window) }
        play(view)
        try await Task.sleep(for: .milliseconds(100))
        #expect(view.rippleAnimation != nil)

        window.orderOut(nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(view.rippleAnimation == nil)
        #expect(view.fillLayer.animationKeys() == nil)
        let builds = view.keyframeBuilds
        play(view, progress: 0.41)
        #expect(view.keyframeBuilds == builds)

        window.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(100))
        #expect(view.rippleAnimation != nil)
        #expect(view.keyframeBuilds == builds + 1)
    }

    @Test("a card whose content was made before the window was ordered in starts its loop from the window's own notice")
    func firstShow() async throws {
        let holder = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 60))
        let view = MusicWaveLayerView(frame: NSRect(x: 0, y: 20, width: width, height: MusicWave.boxHeight))
        holder.addSubview(view)
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 300, height: 60), styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.contentView = holder
        defer { close(window) }
        // The content is set, the window is not on screen: one path, no loop, no keyframes built.
        play(view)
        #expect(view.rippleAnimation == nil)
        #expect(view.keyframeBuilds == 0)

        window.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(150))
        #expect(view.rippleAnimation != nil)
        #expect(view.keyframeBuilds == 1)
    }

    // MARK: The picture

    /// The old drawing, as the card had it, at a phase: the parity target.
    private struct ReferenceWave: View {
        let progress: Double
        let phase: Double

        var body: some View {
            let gradient = Gradient(colors: MusicWave.gradientTints(for: sampleTint).map(\.solid))
            Canvas { context, size in
                let base = MusicWave.baselineY
                let head = MusicWave.playheadX(progress: progress, width: size.width)
                var rest = Path()
                rest.move(to: CGPoint(x: head, y: base))
                rest.addLine(to: CGPoint(x: max(size.width - MusicWave.inset, head), y: base))
                context.stroke(rest, with: .color(Color.white.opacity(0.25)), style: StrokeStyle(lineWidth: 2, lineCap: .round))

                let samples = MusicWave.profile(levels: levels, progress: progress, width: size.width, phase: phase)
                guard let first = samples.first, let last = samples.last else { return }
                let shading = GraphicsContext.Shading.linearGradient(
                    gradient,
                    startPoint: CGPoint(x: MusicWave.inset, y: 0),
                    endPoint: CGPoint(x: max(head, MusicWave.inset + 1), y: 0)
                )
                var curve = Path()
                curve.move(to: CGPoint(x: first.x, y: base))
                for sample in samples {
                    curve.addLine(to: CGPoint(x: sample.x, y: base - sample.height))
                }
                curve.addLine(to: CGPoint(x: last.x, y: base))
                curve.closeSubpath()
                context.fill(curve, with: shading)

                var line = Path()
                line.move(to: CGPoint(x: first.x, y: base))
                line.addLine(to: CGPoint(x: last.x, y: base))
                context.stroke(line, with: shading, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            }
            .frame(width: width, height: MusicWave.boxHeight)
        }
    }

    private static let scale = 2

    /// The RGBA bytes (premultiplied, sRGB) of an image drawn into a 276 by 22 point box at two pixels to the point.
    private func bytes(drawing draw: (CGContext) -> Void) -> [UInt8] {
        let pixelsWide = Int(width) * Self.scale
        let pixelsHigh = Int(MusicWave.boxHeight) * Self.scale
        var data = [UInt8](repeating: 0, count: pixelsWide * pixelsHigh * 4)
        data.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: pixelsWide, height: pixelsHigh, bitsPerComponent: 8,
                bytesPerRow: pixelsWide * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            draw(context)
        }
        return data
    }

    private func layerBytes(_ view: MusicWaveLayerView) -> [UInt8] {
        bytes { context in
            context.scaleBy(x: CGFloat(Self.scale), y: CGFloat(Self.scale))
            view.layer?.render(in: context)
        }
    }

    private func referenceBytes(progress: Double, phase: Double) -> [UInt8]? {
        let renderer = ImageRenderer(content: ReferenceWave(progress: progress, phase: phase))
        renderer.scale = CGFloat(Self.scale)
        guard let image = renderer.cgImage else { return nil }
        return bytes { context in
            context.draw(image, in: CGRect(x: 0, y: 0, width: Int(width) * Self.scale, height: Int(MusicWave.boxHeight) * Self.scale))
        }
    }

    private struct Difference {
        var mean = 0.0
        var farShare = 0.0
        var inked = 0.0
    }

    private func compare(_ a: [UInt8], _ b: [UInt8]) -> Difference {
        guard a.count == b.count, !a.isEmpty else { return Difference(mean: .infinity, farShare: 1, inked: 0) }
        var total = 0
        var far = 0
        var inked = 0
        let pixels = a.count / 4
        for pixel in 0..<pixels {
            var worst = 0
            for channel in 0..<4 {
                worst = max(worst, abs(Int(a[pixel * 4 + channel]) - Int(b[pixel * 4 + channel])))
            }
            total += worst
            if worst > 48 { far += 1 }
            if a[pixel * 4 + 3] > 0 || b[pixel * 4 + 3] > 0 { inked += 1 }
        }
        return Difference(mean: Double(total) / Double(pixels), farShare: Double(far) / Double(pixels), inked: Double(inked) / Double(pixels))
    }

    @Test("the layers draw what the old Canvas drew, at phase 0 and at a phase in the middle of the turn")
    func matchesTheCanvas() throws {
        for (progress, phase) in [(0.4, 0.0), (0.4, 2.2), (0.85, 4.9)] {
            let (view, window, state) = stage()
            defer { close(window) }
            view.setFrameSize(NSSize(width: width, height: MusicWave.boxHeight))
            play(view, progress: progress)
            // Reach the phase by playing from the start and pausing at the time that has it.
            state.clock = 100 + phase / MusicWave.rippleSpeed
            play(view, progress: progress, playing: false)
            #expect(abs(view.frozenPhase - phase) < 1e-9)
            let drawn = layerBytes(view)
            let reference = try #require(referenceBytes(progress: progress, phase: phase))
            let difference = compare(drawn, reference)
            // The same shape, in the same place and colours, up to the edges' anti-aliasing.
            #expect(difference.inked > 0.05)
            #expect(difference.mean < 1.5)
            #expect(difference.farShare < 0.012)
        }
    }

    @Test("the picture is not upside down or mirrored: the played part is under the playhead and above the baseline")
    func orientationOnScreen() {
        let (view, window, _) = stage()
        defer { close(window) }
        play(view, progress: 0.5, playing: false)
        let data = layerBytes(view)
        let pixelsWide = Int(width) * Self.scale
        func alpha(x: Double, y: Double) -> UInt8 {
            data[(Int(y * Double(Self.scale)) * pixelsWide + Int(x * Double(Self.scale))) * 4 + 3]
        }
        // The baseline at 15 pt from the top, inked from the inset to the playhead (half way: 138).
        #expect(alpha(x: 50, y: MusicWave.baselineY) > 200)
        // The unplayed line to the right of the playhead.
        #expect(alpha(x: 200, y: MusicWave.baselineY) > 40)
        // Nothing at the very top-right or under the baseline.
        #expect(alpha(x: 200, y: 2) == 0)
        #expect(alpha(x: 50, y: 20) == 0)
        // The swell rises above the baseline on the played side.
        var inkedAbove = 0
        for x in stride(from: 20.0, to: 120.0, by: 1) where alpha(x: x, y: 8) > 100 { inkedAbove += 1 }
        #expect(inkedAbove > 20)
    }

    // MARK: Per frame work

    private struct Host: View {
        let playing: Bool
        var body: some View {
            VStack {
                MusicWaveLayer(levels: levels, progress: 0.4, tint: sampleTint, isPlaying: playing, reduceMotion: false)
                    .frame(height: MusicWave.boxHeight)
            }
            .frame(width: 300, height: 60)
        }
    }

    /// The wave as it was: a timeline with a canvas, to show that the count below can tell the two apart.
    private struct OldHost: View {
        var body: some View {
            VStack {
                TimelineView(.animation(minimumInterval: 1.0 / 60, paused: false)) { timeline in
                    Canvas { context, size in
                        var line = Path()
                        let phase = MusicWave.ripplePhase(at: timeline.date.timeIntervalSinceReferenceDate)
                        line.move(to: CGPoint(x: 6, y: 15))
                        line.addLine(to: CGPoint(x: 100 + 20 * sin(phase), y: 15))
                        context.stroke(line, with: .color(.white), lineWidth: 2)
                    }
                }
                .frame(height: MusicWave.boxHeight)
            }
            .frame(width: 300, height: 60)
        }
    }

    @Test("a playing wave costs its hosting view no layout per frame; the timeline it replaces cost one every frame")
    func noLayoutsPerFrame() async throws {
        let old = LayoutCountingHostingView(rootView: OldHost())
        let oldWindow = show(old)
        try await Task.sleep(for: .milliseconds(300))
        let oldBefore = old.layouts
        try await Task.sleep(for: .seconds(1))
        let oldLayouts = old.layouts - oldBefore
        close(oldWindow)

        let hosting = LayoutCountingHostingView(rootView: Host(playing: true))
        let window = show(hosting)
        defer { close(window) }
        try await Task.sleep(for: .milliseconds(300))
        let before = hosting.layouts
        try await Task.sleep(for: .seconds(1))
        let layouts = hosting.layouts - before
        #expect(oldLayouts > 20)
        #expect(layouts < 5)
    }
}

// MARK: - The real card

/// The whole hover card with a song playing, in a window that is on screen but invisible, as the controller shows it.
@MainActor
@Suite("Hover card per frame work")
struct MusicCardFrameWorkTests {
    private func makeHost(engine: FakePlaybackEngine) async -> (MusicServiceHost, MusicService) {
        let service = MusicService(
            backend: FakeMusicBackend(signedIn: true),
            player: MusicPlayer(engine: engine),
            presentSignIn: { _ in },
            presentChannelPicker: { _, _ in },
            closeSignInWindow: {},
            raiseSignInWindow: {},
            nowPlaying: NowPlayingController(surface: FakeNowPlayingSurface(), fetchArtwork: { _ in nil }),
            savePreferences: { _ in },
            shuffleSeed: 1,
            queueRetryDelay: .seconds(60),
            sleep: { _ in },
            refreshOnCreate: false
        )
        let host = MusicServiceHost(makeService: { service })
        host.loadIfNeeded()
        service.play(MusicSamples.track("card", title: "Song card"))
        await service.playTask?.value
        engine.emit(.playingChanged(true))
        return (host, service)
    }

    private func window(showing view: NSView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: 200, y: 200), size: MusicHoverCardMetrics.size),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.collectionBehavior = [.transient, .ignoresCycle, .stationary]
        window.contentView = view
        window.orderFrontRegardless()
        return window
    }

    private func waves(in view: NSView) -> [MusicWaveLayerView] {
        var found: [MusicWaveLayerView] = []
        func walk(_ view: NSView) {
            if let wave = view as? MusicWaveLayerView { found.append(wave) }
            view.subviews.forEach(walk)
        }
        walk(view)
        return found
    }

    @Test("with a song playing the card's hosting view lays out a few times a second at most, and its wave is a loop")
    func cardIsQuiet() async throws {
        let engine = FakePlaybackEngine()
        let (host, _) = await makeHost(engine: engine)
        let hosting = LayoutCountingHostingView(
            rootView: MusicNowPlayingCard(musicHost: host, onOpenPlayer: {}, onRated: { _ in })
        )
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: MusicHoverCardMetrics.size)
        let window = window(showing: hosting)
        defer {
            window.contentView = nil
            window.close()
        }
        engine.tick(10, playing: true)
        try await Task.sleep(for: .milliseconds(400))
        let wave = try #require(waves(in: hosting).first)
        #expect(wave.isRippling)
        #expect(wave.rippleAnimation != nil)

        // The player's own half second ticks, as they come while a song plays.
        let before = hosting.layouts
        let builds = wave.keyframeBuilds
        var position = 10.0
        for _ in 0..<4 {
            position += 0.5
            engine.tick(position, playing: true)
            try await Task.sleep(for: .milliseconds(500))
        }
        let layouts = hosting.layouts - before
        // About one per tick (4 in 2 s). The timeline it replaced made one per frame: 120 or more.
        #expect(layouts < 16)
        // The ripple rebuilt at the tick rate at most, and is still on.
        #expect(wave.keyframeBuilds - builds <= 6)
        #expect(wave.rippleAnimation != nil)
    }
}
