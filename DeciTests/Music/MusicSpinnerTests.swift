// DeciTests/Music/MusicSpinnerTests.swift
// The loading spinner turns on the render server: one Core Animation rotation that repeats, not a SwiftUI animation. A
// SwiftUI repeating animation redraws its view every display frame (120 a second), and each of those runs the popup
// window's whole update; a layer animation costs the app nothing once it is added. Covered: the ring's measures, the
// layer's one animation (its length, its direction, that it never ends and that it comes back), and the ink.

import AppKit
import SwiftUI
import Testing
@testable import Deci

@Suite("MusicSpinnerGeometry")
struct MusicSpinnerGeometryTests {
    @Test("the ring is three quarters of the box and sits in the middle of it")
    func ring() {
        let rect = MusicSpinnerGeometry.ringRect(size: 20)
        #expect(rect == CGRect(x: 2.5, y: 2.5, width: 15, height: 15))
        #expect(MusicSpinnerGeometry.ringRect(size: 0) == .zero)
    }

    @Test("a turn takes 0.8 s, a quarter ring is lit, and the turn is one full clockwise round")
    func measures() {
        #expect(MusicSpinnerGeometry.period == 0.8)
        #expect(MusicSpinnerGeometry.arcShare == 0.25)
        // The layer's z axis points at the viewer, so a clockwise turn on screen is a negative angle.
        #expect(MusicSpinnerGeometry.turn == -2 * Double.pi)
    }

    @Test("a size that is not a positive number gives no ring")
    func badSize() {
        #expect(MusicSpinnerGeometry.ringRect(size: -4) == .zero)
        #expect(MusicSpinnerGeometry.ringRect(size: .nan) == .zero)
        #expect(MusicSpinnerGeometry.ringRect(size: .infinity) == .zero)
    }
}

@Suite("MusicSpinnerPaint")
struct MusicSpinnerPaintTests {
    @Test("a resolved SwiftUI colour becomes the same sRGB colour, with its opacity")
    func fromResolved() throws {
        let resolved = Color(.sRGB, red: 0.5, green: 0.25, blue: 0.75, opacity: 0.4).resolve(in: EnvironmentValues())
        let cg = MusicSpinnerPaint.cgColor(resolved)
        let srgb = try #require(cg.converted(
            to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil
        ))
        let c = try #require(srgb.components)
        #expect(abs(c[0] - 0.5) < 0.005 && abs(c[1] - 0.25) < 0.005 && abs(c[2] - 0.75) < 0.005)
        #expect(abs(c[3] - 0.4) < 0.005)
    }

    @Test("white is white, whatever the colour space")
    func white() throws {
        let cg = MusicSpinnerPaint.cgColor(Color.white.resolve(in: EnvironmentValues()))
        let srgb = try #require(cg.converted(
            to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil
        ))
        let c = try #require(srgb.components)
        #expect(abs(c[0] - 1) < 0.005 && abs(c[1] - 1) < 0.005 && abs(c[2] - 1) < 0.005 && abs(c[3] - 1) < 0.005)
    }
}

@MainActor
@Suite("MusicSpinnerView")
struct MusicSpinnerViewTests {
    private let red = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
    private let blue = CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)

    private func makeView(size: CGFloat = 40) -> MusicSpinnerView {
        let view = MusicSpinnerView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        view.configure(lineWidth: 4, color: red, track: blue)
        return view
    }

    private func turn(of view: MusicSpinnerView) -> CABasicAnimation? {
        view.arcLayer.animation(forKey: MusicSpinnerView.turnKey) as? CABasicAnimation
    }

    @Test("the view takes no mouse events")
    func takesNoMouseEvents() {
        #expect(makeView().hitTest(NSPoint(x: 20, y: 20)) == nil)
    }

    @Test("one rotation repeats for ever, in 0.8 s, evenly, a clockwise turn")
    func theAnimation() throws {
        let view = makeView()
        view.startTurning()
        let animation = try #require(turn(of: view))
        #expect(animation.keyPath == "transform.rotation.z")
        #expect(animation.duration == MusicSpinnerGeometry.period)
        #expect(animation.repeatCount == .infinity)
        #expect(animation.isRemovedOnCompletion == false)
        #expect(animation.timingFunction == CAMediaTimingFunction(name: .linear))
        #expect(animation.fromValue as? Double == 0)
        #expect(animation.toValue as? Double == MusicSpinnerGeometry.turn)
    }

    @Test("starting again does not add a second animation")
    func startsOnce() {
        let view = makeView()
        view.startTurning()
        view.startTurning()
        #expect(view.turnsStarted == 1)
    }

    @Test("an animation the system took away comes back when the view is asked to turn")
    func comesBack() {
        let view = makeView()
        view.startTurning()
        view.arcLayer.removeAllAnimations()
        #expect(turn(of: view) == nil)
        view.startTurning()
        #expect(turn(of: view) != nil)
        #expect(view.turnsStarted == 2)
    }

    @Test("a new look or size does not restart the turn")
    func reconfigureKeepsTurning() {
        let view = makeView()
        view.startTurning()
        view.configure(lineWidth: 2, color: blue, track: red)
        view.setFrameSize(NSSize(width: 18, height: 18))
        #expect(view.turnsStarted == 1)
        #expect(turn(of: view) != nil)
    }

    @Test("the ring and the arc are laid out in the middle of the box, and follow its size")
    func layout() {
        let view = makeView(size: 40)
        #expect(view.arcLayer.bounds.size == CGSize(width: 40, height: 40))
        #expect(view.arcLayer.position == CGPoint(x: 20, y: 20))
        #expect(view.trackLayer.lineWidth == 4)
        view.setFrameSize(NSSize(width: 18, height: 18))
        #expect(view.arcLayer.bounds.size == CGSize(width: 18, height: 18))
        #expect(view.arcLayer.position == CGPoint(x: 9, y: 9))
        let path = view.trackLayer.path?.boundingBox ?? .zero
        #expect(path == MusicSpinnerGeometry.ringRect(size: 18))
    }

    // MARK: Ink

    /// The pure `channel` ink of the layer, drawn without its animation, counted per quadrant of the box.
    private func quadrants(of view: MusicSpinnerView, channel: Int, rotatedBy angle: CGFloat = 0) throws -> (upperLeft: Int, upperRight: Int, lowerLeft: Int, lowerRight: Int) {
        let side = 80
        let context = try #require(CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.scaleBy(x: CGFloat(side) / view.bounds.width, y: CGFloat(side) / view.bounds.height)
        view.arcLayer.transform = CATransform3DMakeRotation(angle, 0, 0, 1)
        view.layer?.render(in: context)
        let image = try #require(context.makeImage())
        let rep = NSBitmapImageRep(cgImage: image)
        var counts = (upperLeft: 0, upperRight: 0, lowerLeft: 0, lowerRight: 0)
        for y in 0..<side {
            for x in 0..<side {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                let channels = [color.redComponent, color.greenComponent, color.blueComponent]
                let others = channels.enumerated().filter { $0.offset != channel }.map(\.element)
                guard color.alphaComponent > 0.5, channels[channel] > 0.8, others.allSatisfy({ $0 < 0.2 }) else { continue }
                switch (x < side / 2, y < side / 2) {
                case (true, true): counts.upperLeft += 1
                case (false, true): counts.upperRight += 1
                case (true, false): counts.lowerLeft += 1
                case (false, false): counts.lowerRight += 1
                }
            }
        }
        return counts
    }

    @Test("the arc is the quarter from three o'clock down to six, and the ring runs all the way round")
    func arcQuadrant() throws {
        let view = makeView()
        // The round caps spill a few points past the quarter; the quarter itself is many times that.
        let arc = try quadrants(of: view, channel: 0)
        #expect(arc.lowerRight > 150)
        #expect(arc.upperLeft == 0)
        #expect(arc.upperRight < 80 && arc.lowerLeft < 80)

        let ring = try quadrants(of: view, channel: 2)
        #expect(ring.upperLeft > 150 && ring.upperRight > 150 && ring.lowerLeft > 150)
    }

    @Test("a quarter of the turn carries the arc clockwise on screen, from the lower right to the lower left")
    func turnsClockwise() throws {
        let view = makeView()
        let arc = try quadrants(of: view, channel: 0, rotatedBy: CGFloat(MusicSpinnerGeometry.turn / 4))
        #expect(arc.lowerLeft > 150)
        #expect(arc.upperRight == 0)
        #expect(arc.upperLeft < 80 && arc.lowerRight < 80)
    }
}

@MainActor
@Suite("MusicSpinner in SwiftUI")
struct MusicSpinnerIntegrationTests {
    private func findSpinner(in view: NSView) -> MusicSpinnerView? {
        if let found = view as? MusicSpinnerView { return found }
        for subview in view.subviews {
            if let found = findSpinner(in: subview) { return found }
        }
        return nil
    }

    private func root(visible: Bool) -> AnyView {
        AnyView(MusicSpinner().environment(\.musicPopupIsVisible, visible))
    }

    private func show(_ hosting: NSView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 60, height: 60), styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.collectionBehavior = [.transient, .ignoresCycle, .stationary]
        window.contentView = hosting
        window.orderFrontRegardless()
        return window
    }

    @Test("a turn the window took away while the popup was closed is back when the popup opens, and the turn does not wait for it")
    func turnsAgainAfterTheWindowReopens() async throws {
        let hosting = NSHostingView(rootView: root(visible: false))
        let window = show(hosting)
        defer {
            window.contentView = nil
            window.close()
        }
        try await Task.sleep(for: .milliseconds(300))
        let view = try #require(findSpinner(in: hosting))
        // A spinner that never sees the popup open (the hover card's) turns anyway.
        #expect(view.arcLayer.animation(forKey: MusicSpinnerView.turnKey) != nil)
        let started = view.turnsStarted

        // The window was ordered out and the system dropped the layers' animations.
        view.arcLayer.removeAllAnimations()
        hosting.rootView = root(visible: true)
        try await Task.sleep(for: .milliseconds(300))
        #expect(view.arcLayer.animation(forKey: MusicSpinnerView.turnKey) != nil)
        #expect(view.turnsStarted == started + 1)

        // Another update while it turns changes nothing.
        hosting.rootView = root(visible: false)
        try await Task.sleep(for: .milliseconds(300))
        #expect(view.turnsStarted == started + 1)
    }
}
