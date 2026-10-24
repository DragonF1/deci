// DeciTests/Music/MusicMiniSpectrumLayerTests.swift
// The playing row's four bars swing as Core Animation keyframes on layers. A SwiftUI TimelineView there made the open
// popup's whole window update and lay out 20 times a second for as long as a playing row was on screen. Covered: the
// sampled sine the animation plays, the layers (rest look, one animation per bar, nothing added twice, rest again when it
// stops) and that the popup's window is not laid out while the bars swing.

import AppKit
import SwiftUI
import Testing
@testable import Deci

@Suite("MusicMiniSpectrum swing")
struct MusicMiniSpectrumSwingTests {
    @Test("a swing is one whole period of samples, back at its first height at the end")
    func closes() {
        for index in 0..<MusicMiniSpectrum.barCount {
            let heights = MusicMiniSpectrum.swingHeights(of: index)
            #expect(heights.count == MusicMiniSpectrum.swingSamples + 1)
            #expect(abs(heights[0] - heights[heights.count - 1]) < 1e-6)
        }
    }

    @Test("every sample is between the least and the greatest height")
    func inRange() {
        for index in 0..<MusicMiniSpectrum.barCount {
            for height in MusicMiniSpectrum.swingHeights(of: index) {
                #expect(height >= MusicMiniSpectrum.minHeight && height <= MusicMiniSpectrum.maxHeight)
            }
        }
    }

    @Test("sample k is the bar's height k steps into its period, as the timeline had it")
    func matchesTheFormula() {
        for index in 0..<MusicMiniSpectrum.barCount {
            let heights = MusicMiniSpectrum.swingHeights(of: index)
            for step in stride(from: 0, through: MusicMiniSpectrum.swingSamples, by: 5) {
                let time = Double(step) / Double(MusicMiniSpectrum.swingSamples) * MusicMiniSpectrum.periods[index]
                #expect(abs(heights[step] - MusicMiniSpectrum.heights(at: time, isAnimating: true)[index]) < 1e-9)
            }
        }
    }

    @Test("straight lines between samples stay within a few hundredths of a point of the sine")
    func linesFollowTheSine() {
        for index in 0..<MusicMiniSpectrum.barCount {
            let heights = MusicMiniSpectrum.swingHeights(of: index)
            let period = MusicMiniSpectrum.periods[index]
            for step in 0..<MusicMiniSpectrum.swingSamples {
                let middle = (Double(step) + 0.5) / Double(MusicMiniSpectrum.swingSamples) * period
                let line = (heights[step] + heights[step + 1]) / 2
                #expect(abs(line - MusicMiniSpectrum.height(of: index, at: middle)) < 0.05)
            }
        }
    }

    @Test("the bars swing differently: no two share a swing")
    func barsDiffer() {
        let swings = (0..<MusicMiniSpectrum.barCount).map { MusicMiniSpectrum.swingHeights(of: $0) }
        #expect(Set(swings).count == MusicMiniSpectrum.barCount)
    }
}

@MainActor
@Suite("MusicMiniSpectrumLayerView")
struct MusicMiniSpectrumLayerViewTests {
    private let color = CGColor(srgbRed: 1, green: 0.5, blue: 0, alpha: 1)

    private func makeView() -> MusicMiniSpectrumLayerView {
        MusicMiniSpectrumLayerView(frame: NSRect(x: 0, y: 0, width: MusicMiniSpectrum.width, height: MusicMiniSpectrum.height))
    }

    private func swing(of bar: CALayer) -> CAKeyframeAnimation? {
        bar.animation(forKey: MusicMiniSpectrumLayerView.swingKey) as? CAKeyframeAnimation
    }

    @Test("at rest the bars stand at the rest heights, 2 wide on a 4 point pitch, from the bottom edge")
    func restLook() {
        let view = makeView()
        view.update(isAnimating: false, color: color)
        for (index, bar) in view.barLayers.enumerated() {
            #expect(bar.bounds.size == CGSize(width: MusicMiniSpectrum.barWidth, height: MusicMiniSpectrum.restHeights[index]))
            #expect(bar.position == CGPoint(x: MusicMiniSpectrum.barX(index), y: 0))
            #expect(bar.anchorPoint == .zero)
            #expect(bar.cornerRadius == MusicMiniSpectrum.radius)
            #expect(bar.backgroundColor == color)
            #expect(swing(of: bar) == nil)
        }
    }

    @Test("the view takes no mouse events")
    func takesNoMouseEvents() {
        #expect(makeView().hitTest(NSPoint(x: 3, y: 3)) == nil)
    }

    @Test("playing gives each bar one repeating animation of its height over its own period")
    func swings() throws {
        let view = makeView()
        view.update(isAnimating: true, color: color)
        for (index, bar) in view.barLayers.enumerated() {
            let animation = try #require(swing(of: bar))
            #expect(animation.keyPath == "bounds.size.height")
            #expect(animation.duration == MusicMiniSpectrum.periods[index])
            #expect(animation.repeatCount == .infinity)
            #expect(animation.isRemovedOnCompletion == false)
            #expect(animation.calculationMode == .linear)
            let values = (animation.values as? [NSNumber])?.map(\.doubleValue) ?? []
            #expect(values == MusicMiniSpectrum.swingHeights(of: index).map { Double($0) })
        }
    }

    @Test("asking again while it swings adds nothing")
    func swingsOnce() {
        let view = makeView()
        view.update(isAnimating: true, color: color)
        view.update(isAnimating: true, color: color)
        #expect(view.swingsStarted == 1)
    }

    @Test("a pause takes the swing away and the bars stand at rest; a play brings it back")
    func pauseAndPlay() {
        let view = makeView()
        view.update(isAnimating: true, color: color)
        view.update(isAnimating: false, color: color)
        #expect(view.barLayers.allSatisfy { swing(of: $0) == nil })
        #expect(view.barLayers.map { $0.bounds.height } == MusicMiniSpectrum.restHeights)
        view.update(isAnimating: true, color: color)
        #expect(view.barLayers.allSatisfy { swing(of: $0) != nil })
        #expect(view.swingsStarted == 2)
    }

    @Test("an animation the system took away comes back at the next update")
    func comesBack() {
        let view = makeView()
        view.update(isAnimating: true, color: color)
        view.barLayers.forEach { $0.removeAllAnimations() }
        view.update(isAnimating: true, color: color)
        #expect(view.barLayers.allSatisfy { swing(of: $0) != nil })
        #expect(view.swingsStarted == 2)
    }

    @Test("a new colour reaches every bar without touching the swing")
    func recolours() {
        let view = makeView()
        view.update(isAnimating: true, color: color)
        let blue = CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
        view.update(isAnimating: true, color: blue)
        #expect(view.barLayers.allSatisfy { $0.backgroundColor == blue })
        #expect(view.swingsStarted == 1)
    }
}

@MainActor
@Suite("MusicMiniSpectrumView in SwiftUI")
struct MusicMiniSpectrumIntegrationTests {
    private func findLayerView(in view: NSView) -> MusicMiniSpectrumLayerView? {
        if let found = view as? MusicMiniSpectrumLayerView { return found }
        for subview in view.subviews {
            if let found = findLayerView(in: subview) { return found }
        }
        return nil
    }

    @Test("a playing row's bars swing while the popup's window is not laid out for them")
    func swingsWithoutLayouts() async throws {
        let hosting = LayoutCountingHostingView(rootView: MusicMiniSpectrumView(isPlaying: true)
            .environment(\.musicPopupIsVisible, true))
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 60, height: 40), styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.collectionBehavior = [.transient, .ignoresCycle, .stationary]
        window.contentView = hosting
        window.orderFrontRegardless()
        defer {
            window.contentView = nil
            window.close()
        }

        try await Task.sleep(for: .milliseconds(500))
        let view = try #require(findLayerView(in: hosting))
        #expect(view.isAnimating)
        let layoutsBefore = hosting.layouts
        var seen = Set<CGFloat>()
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(50))
            if let height = view.barLayers[0].presentation()?.bounds.height { seen.insert(height) }
        }
        let layouts = hosting.layouts - layoutsBefore
        #expect(layouts < 5)
        // The animation really plays on the layer: its height was read at many different values.
        #expect(seen.count > 5)
        #expect(seen.allSatisfy { $0 >= MusicMiniSpectrum.minHeight - 0.01 && $0 <= MusicMiniSpectrum.maxHeight + 0.01 })
    }

    @Test("a paused or hidden row rests")
    func rests() async throws {
        let hosting = NSHostingView(rootView: MusicMiniSpectrumView(isPlaying: true))
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 60, height: 40), styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.contentView = hosting
        window.orderFrontRegardless()
        defer {
            window.contentView = nil
            window.close()
        }
        try await Task.sleep(for: .milliseconds(300))
        let view = try #require(findLayerView(in: hosting))
        // The popup is not on screen (the default), so the bars do not swing.
        #expect(!view.isAnimating)
        #expect(view.barLayers.allSatisfy { $0.animation(forKey: MusicMiniSpectrumLayerView.swingKey) == nil })
    }
}
