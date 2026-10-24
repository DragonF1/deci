// DeciTests/Music/MusicSpectrumLayerTests.swift
// The spectrum is built from layers by a view of its own, not by SwiftUI: thirty polls a second must not run the popup's
// SwiftUI update, so the driver keeps its per poll numbers out of observation and tells the layer view directly, and only
// when something that shows has changed; the view then sets a few layer properties and draws nothing on the CPU. Covered
// here: the quantized picture a poll is compared by, the driver's notifications and what a view can still observe, and
// the layer view's own writes, geometry and pixels (against the drawing it replaced). Nothing is shown on screen.

import AppKit
import Metal
import Observation
import os
import QuartzCore
import Testing
@testable import Deci

/// Records that an observation fired, from the nonisolated closure `withObservationTracking` takes.
private nonisolated final class Fired: Sendable {
    private let flag = OSAllocatedUnfairLock(initialState: false)
    var value: Bool { flag.withLock { $0 } }
    func set() { flag.withLock { $0 = true } }
}

/// Counts calls, for a listener closure.
@MainActor
private final class Counter {
    var count = 0
}

/// A premultiplied sRGB bitmap `scale` pixels to the point, read back by point from the top left.
private struct SpectrumBitmap {
    let scale: Int
    let width: Int
    let height: Int
    let bytes: [UInt8]

    /// Draws into a bitmap `points` big with `draw`, in a context whose unit is the point and whose origin is the bottom
    /// left (the layers' space).
    static func render(points: CGSize, scale: Int, draw: (CGContext) -> Void) throws -> SpectrumBitmap {
        let width = Int(points.width) * scale
        let height = Int(points.height) * scale
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let made = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
            draw(context)
            return true
        }
        try #require(made)
        return SpectrumBitmap(scale: scale, width: width, height: height, bytes: bytes)
    }

    /// `layer` as the render server paints it: a `CARenderer` into a Metal texture, `scale` pixels to the point (the
    /// screen's own path for layers, gradients and masks, which `CALayer.render(in:)` is not: it shifts pure primaries).
    /// The renderer is told the target is sRGB, so an sRGB colour comes out as the same bytes, blended as the screen
    /// blends it. The layer is hung from a root of its own for the render and taken off again.
    static func renderOnGPU(_ layer: CALayer, points: CGSize, scale: Int, space: CGColorSpace? = CGColorSpace(name: CGColorSpace.sRGB)) throws -> SpectrumBitmap {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let width = Int(points.width) * scale
        let height = Int(points.height) * scale
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        var options: [AnyHashable: Any] = [kCARendererMetalCommandQueue: queue]
        if let space { options[kCARendererColorSpace] = space }
        let renderer = CARenderer(mtlTexture: texture, options: options)
        let root = CALayer()
        root.anchorPoint = .zero
        root.position = .zero
        root.bounds = CGRect(origin: .zero, size: points)
        root.sublayerTransform = CATransform3DMakeScale(CGFloat(scale), CGFloat(scale), 1)
        renderer.layer = root
        renderer.bounds = CGRect(x: 0, y: 0, width: width, height: height)
        root.addSublayer(layer)
        defer { layer.removeFromSuperlayer() }
        CATransaction.flush()
        renderer.beginFrame(atTime: CACurrentMediaTime(), timeStamp: nil)
        let update = renderer.updateBounds()
        renderer.addUpdate(update)
        renderer.render()
        renderer.endFrame()
        // The render is on the queue given to the renderer: an empty buffer behind it is done when the render is.
        let marker = try #require(queue.makeCommandBuffer())
        marker.commit()
        marker.waitUntilCompleted()
        var bgra = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&bgra, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        // The renderer's rows run from the layers' origin: the bottom of a layer is the first row. Flip them to the top
        // left origin of the CG bitmaps, and take the blue-green-red order to red-green-blue.
        var bytes = bgra
        for row in 0..<height {
            for column in 0..<width {
                let from = ((height - 1 - row) * width + column) * 4
                let to = (row * width + column) * 4
                bytes[to] = bgra[from + 2]
                bytes[to + 1] = bgra[from + 1]
                bytes[to + 2] = bgra[from]
                bytes[to + 3] = bgra[from + 3]
            }
        }
        return SpectrumBitmap(scale: scale, width: width, height: height, bytes: bytes)
    }

    /// The colour at point `x`, `y` from the top left, not premultiplied.
    func pixel(_ x: Int, _ y: Int) -> (r: Double, g: Double, b: Double, a: Double) {
        let offset = (y * scale * width + x * scale) * 4
        let alpha = Double(bytes[offset + 3]) / 255
        guard alpha > 0 else { return (0, 0, 0, 0) }
        return (
            Double(bytes[offset]) / 255 / alpha, Double(bytes[offset + 1]) / 255 / alpha,
            Double(bytes[offset + 2]) / 255 / alpha, alpha
        )
    }

    /// How well this bitmap (the layers) agrees with `old` (the drawing they replace). The two anti-aliasers do not agree
    /// on the pixels along a shape's edge, so those are told apart: a pixel is flat if it and every one of its eight
    /// neighbours are within `flat` of each other in both bitmaps, and a flat pixel must match closely; an edge pixel is
    /// allowed a wider gap. The covered area and its centre must agree as a whole, which a bar or the soft edge out of
    /// place would upset.
    func parity(with old: SpectrumBitmap, flat: Int) -> (flatLargest: Int, edgeLargest: Int, flatPixels: Int, edgePixels: Int, area: Double, shift: Double) {
        func gap(_ a: [UInt8], _ b: [UInt8], _ i: Int, _ j: Int) -> Int {
            var worst = 0
            var channel = 0
            while channel < 4 {
                let apart = Int(a[i * 4 + channel]) - Int(b[j * 4 + channel])
                worst = max(worst, apart < 0 ? -apart : apart)
                channel += 1
            }
            return worst
        }
        var flatLargest = 0
        var edgeLargest = 0
        var flatPixels = 0
        var edgePixels = 0
        for y in 0..<height {
            for x in 0..<width {
                let here = y * width + x
                var isFlat = true
                scan: for dy in -1...1 {
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        let nx = x + dx
                        let ny = y + dy
                        guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                        let there = ny * width + nx
                        if gap(bytes, bytes, here, there) > flat || gap(old.bytes, old.bytes, here, there) > flat {
                            isFlat = false
                            break scan
                        }
                    }
                }
                let apart = gap(bytes, old.bytes, here, here)
                if isFlat {
                    flatLargest = max(flatLargest, apart)
                    flatPixels += 1
                } else {
                    edgeLargest = max(edgeLargest, apart)
                    edgePixels += 1
                }
            }
        }
        // The opacity, summed: the area the shapes cover, and where it is on average (a shift of a bar or of the edge
        // moves it), in points.
        func moments(_ bitmap: SpectrumBitmap) -> (sum: Double, x: Double, y: Double) {
            var sum = 0.0
            var x = 0.0
            var y = 0.0
            for row in 0..<bitmap.height {
                for column in 0..<bitmap.width {
                    let alpha = Double(bitmap.bytes[(row * bitmap.width + column) * 4 + 3])
                    sum += alpha
                    x += alpha * (Double(column) + 0.5)
                    y += alpha * (Double(row) + 0.5)
                }
            }
            return (sum, x / max(sum, 1) / Double(bitmap.scale), y / max(sum, 1) / Double(bitmap.scale))
        }
        let mine = moments(self)
        let theirs = moments(old)
        let area = abs(mine.sum - theirs.sum) / max(theirs.sum, 1)
        let shift = max(abs(mine.x - theirs.x), abs(mine.y - theirs.y))
        return (flatLargest, edgeLargest, flatPixels, edgePixels, area, shift)
    }
}

/// The spectrum as it was drawn before it was built from layers (the view's `draw(_:)`, as it stood), into `context`
/// whose unit is the point and whose origin is the bottom left: the reference the layers are compared with.
private func drawnTheOldWay(
    into context: CGContext, width viewWidth: Double, levels: [Double], progress: Double, style: MusicSpectrumStyle
) {
    // The old view was flipped: y ran down from the top.
    context.translateBy(x: 0, y: CGFloat(style.height))
    context.scaleBy(x: 1, y: -1)
    let height = style.height
    let thickness = MusicSpectrum.barThickness(height: height)
    let edge = MusicSpectrum.fillEdge(height: height)
    let edgeY = MusicSpectrum.fillEdgeY(progress: progress, height: height)
    let rgb = MusicSpectrum.rgb(hue: style.hue, saturation: style.saturation, brightness: style.brightness)
    let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    let played = CGColor(
        colorSpace: space, components: [rgb.red, rgb.green, rgb.blue, style.barsOpacity].map { CGFloat($0) }
    ) ?? CGColor(gray: 1, alpha: 1)
    let unplayed = CGColor(
        colorSpace: space, components: [1, 1, 1, style.unplayedOpacity * style.barsOpacity].map { CGFloat($0) }
    ) ?? CGColor(gray: 1, alpha: 0.25)
    let gradient = CGGradient(colorsSpace: space, colors: [played, unplayed] as CFArray, locations: nil)

    for (index, level) in levels.enumerated() {
        let width = style.fixedWidth ?? MusicSpectrum.width(forLevel: level)
        let rect = CGRect(
            x: (viewWidth - width) / 2,
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

// MARK: - The picture a frame is compared by

@Suite("MusicSpectrumFrame")
struct MusicSpectrumFrameTests {
    private let levels = Array(repeating: 0.5, count: MusicSpectrum.barCount)

    /// The progress that puts the middle of the soft edge at `y` in the design's box.
    private func progress(edgeAt y: Double) -> Double {
        let edge = MusicSpectrum.fillEdge()
        return (y + edge / 2) / (MusicSpectrum.boxHeight + edge)
    }

    @Test("a frame is one width per bar, in half points, and the soft edge in quarter points")
    func shape() {
        let frame = MusicSpectrumFrame(levels: levels, progress: progress(edgeAt: 10), height: MusicSpectrum.boxHeight, fixedWidth: nil)
        #expect(frame.widths.count == MusicSpectrum.barCount)
        #expect(frame.widths.allSatisfy { $0 == Int(MusicSpectrum.width(forLevel: 0.5) * 2) })
        #expect(frame.edge == 40)
    }

    @Test("a level that moves a bar by less than a half point is the same frame")
    func smallLevelChange() {
        var nudged = levels
        nudged[3] = 0.5005
        let a = MusicSpectrumFrame(levels: levels, progress: 0.3, height: 104, fixedWidth: nil)
        let b = MusicSpectrumFrame(levels: nudged, progress: 0.3, height: 104, fixedWidth: nil)
        #expect(a == b)
    }

    @Test("a level that moves a bar by a visible step is a new frame")
    func visibleLevelChange() {
        var louder = levels
        louder[3] = 0.52
        let a = MusicSpectrumFrame(levels: levels, progress: 0.3, height: 104, fixedWidth: nil)
        let b = MusicSpectrumFrame(levels: louder, progress: 0.3, height: 104, fixedWidth: nil)
        #expect(a != b)
    }

    @Test("a fill that moves less than a quarter point is the same frame, and a quarter point or more is a new one")
    func progressSteps() {
        let base = progress(edgeAt: 20)
        let near = progress(edgeAt: 20.1)
        let far = progress(edgeAt: 20.5)
        let a = MusicSpectrumFrame(levels: levels, progress: base, height: 104, fixedWidth: nil)
        let b = MusicSpectrumFrame(levels: levels, progress: near, height: 104, fixedWidth: nil)
        let c = MusicSpectrumFrame(levels: levels, progress: far, height: 104, fixedWidth: nil)
        #expect(a == b)
        #expect(a != c)
    }

    @Test("with a fixed width every bar is that wide, whatever its level")
    func fixedWidth() {
        var other = levels
        other[0] = 1
        let a = MusicSpectrumFrame(levels: levels, progress: 0.3, height: 104, fixedWidth: 40)
        let b = MusicSpectrumFrame(levels: other, progress: 0.3, height: 104, fixedWidth: 40)
        #expect(a == b)
        #expect(a.widths.allSatisfy { $0 == 80 })
    }

    @Test("a progress that is not a number is the start")
    func nonFiniteProgress() {
        let start = MusicSpectrumFrame(levels: levels, progress: 0, height: 104, fixedWidth: nil)
        let nan = MusicSpectrumFrame(levels: levels, progress: .nan, height: 104, fixedWidth: nil)
        #expect(start == nan)
    }
}

@Suite("MusicSpectrum colour")
struct MusicSpectrumColourTests {
    @Test("hue, saturation and brightness come out as the same sRGB the SwiftUI colour has")
    func rgb() {
        func close(_ a: (red: Double, green: Double, blue: Double), _ b: (Double, Double, Double)) -> Bool {
            abs(a.red - b.0) < 1e-9 && abs(a.green - b.1) < 1e-9 && abs(a.blue - b.2) < 1e-9
        }
        #expect(close(MusicSpectrum.rgb(hue: 0, saturation: 1, brightness: 1), (1, 0, 0)))
        #expect(close(MusicSpectrum.rgb(hue: 1.0 / 3, saturation: 1, brightness: 1), (0, 1, 0)))
        #expect(close(MusicSpectrum.rgb(hue: 2.0 / 3, saturation: 1, brightness: 1), (0, 0, 1)))
        #expect(close(MusicSpectrum.rgb(hue: 0.5, saturation: 0, brightness: 0.4), (0.4, 0.4, 0.4)))
        #expect(close(MusicSpectrum.rgb(hue: 1, saturation: 1, brightness: 1), (1, 0, 0)))
        #expect(close(MusicSpectrum.rgb(hue: 0, saturation: 0.5, brightness: 0.8), (0.8, 0.4, 0.4)))
    }

    @Test("values out of range and not numbers are held to the colour's range")
    func clamped() {
        let colour = MusicSpectrum.rgb(hue: .nan, saturation: 3, brightness: -1)
        #expect(colour.red == 0 && colour.green == 0 && colour.blue == 0)
    }
}

// MARK: - The driver's notifications

@MainActor
@Suite("MusicSpectrumDriver frames")
struct MusicSpectrumDriverFrameTests {
    private final class Feed {
        var level: Float = 0
        var position: TimeInterval = 0
        var duration: TimeInterval = 200
        var videoId: String? = "song"
    }

    private func driver(_ feed: Feed) -> MusicSpectrumDriver {
        MusicSpectrumDriver(sources: .init(
            level: { feed.level },
            position: { feed.position },
            duration: { feed.duration },
            videoId: { feed.videoId }
        ))
    }

    private func redraws(read: @MainActor () -> Void, after change: @MainActor () -> Void) -> Bool {
        let fired = Fired()
        withObservationTracking { read() } onChange: { fired.set() }
        change()
        return fired.value
    }

    // MARK: Listeners

    @Test("the first poll tells a listener, and a poll that changes nothing does not")
    func unchangedPollIsSilent() {
        let feed = Feed()
        let driver = driver(feed)
        let counter = Counter()
        _ = driver.addFrameListener { counter.count += 1 }
        feed.position = 20
        driver.tick()
        #expect(counter.count == 1)
        driver.tick()
        driver.tick()
        #expect(counter.count == 1)
    }

    @Test("a fill that moves, a pulse that moves and a playhead that changes bar each tell the listener")
    func changesAreTold() {
        let feed = Feed()
        let driver = driver(feed)
        let counter = Counter()
        _ = driver.addFrameListener { counter.count += 1 }
        feed.position = 20
        driver.tick()
        let afterFirst = counter.count

        feed.position = 21
        driver.tick()
        #expect(counter.count > afterFirst)

        let beforePulse = counter.count
        feed.level = 0.1
        driver.tick()
        #expect(counter.count == beforePulse + 1)

        let beforeLouder = counter.count
        feed.level = 0.5
        driver.tick()
        #expect(counter.count == beforeLouder + 1)
    }

    @Test("resting tells the listener once, and resting again says nothing")
    func restIsTold() {
        let feed = Feed()
        let driver = driver(feed)
        feed.position = 20
        feed.level = 0.2
        driver.tick()
        let counter = Counter()
        _ = driver.addFrameListener { counter.count += 1 }
        driver.rest()
        #expect(counter.count == 1)
        driver.rest()
        #expect(counter.count == 1)
    }

    @Test("a poll with no song to place rests the bars and tells the listener once")
    func noSongRests() {
        let feed = Feed()
        let driver = driver(feed)
        feed.position = 20
        driver.tick()
        let counter = Counter()
        _ = driver.addFrameListener { counter.count += 1 }
        feed.videoId = nil
        driver.tick()
        driver.tick()
        #expect(counter.count == 1)
        #expect(driver.progress == nil)
    }

    @Test("a listener that was removed is not told, and the others still are")
    func removal() {
        let feed = Feed()
        let driver = driver(feed)
        let first = Counter()
        let second = Counter()
        let token = driver.addFrameListener { first.count += 1 }
        _ = driver.addFrameListener { second.count += 1 }
        #expect(driver.frameListenerCount == 2)
        driver.removeFrameListener(token)
        #expect(driver.frameListenerCount == 1)
        feed.position = 20
        driver.tick()
        #expect(first.count == 0)
        #expect(second.count == 1)
    }

    // MARK: What a view can still observe

    @Test("the numbers a poll changes are not observed, so a poll runs no SwiftUI update")
    func pollNumbersAreNotObserved() {
        let feed = Feed()
        let driver = driver(feed)
        feed.position = 20
        feed.level = 0.1
        driver.tick()
        feed.position = 40
        feed.level = 0.4
        let fired1 = redraws(read: { _ = driver.progress }, after: { driver.tick() })
        #expect(fired1 == false)
        feed.position = 60
        feed.level = 0.2
        let fired2 = redraws(read: { _ = driver.pulse; _ = driver.pulseIndex }, after: { driver.tick() })
        #expect(fired2 == false)
        feed.position = 80
        feed.level = 0.5
        let fired3 = redraws(read: { _ = driver.memory }, after: { driver.tick() })
        #expect(fired3 == false)
        feed.position = 100
        feed.level = 0.3
        let fired4 = redraws(read: { _ = driver.bars(for: "song") }, after: { driver.tick() })
        #expect(fired4 == false)
    }

    @Test("a view hears when the live fill starts and when it ends, not on the polls in between")
    func liveFlagIsObserved() {
        let feed = Feed()
        let driver = driver(feed)
        #expect(driver.isLive == false)
        feed.position = 20
        let fired5 = redraws(read: { _ = driver.isLive }, after: { driver.tick() })
        #expect(fired5)
        #expect(driver.isLive)
        feed.position = 30
        let fired6 = redraws(read: { _ = driver.isLive }, after: { driver.tick() })
        #expect(fired6 == false)
        let fired7 = redraws(read: { _ = driver.isLive }, after: { driver.rest() })
        #expect(fired7)
        #expect(driver.isLive == false)
    }

    @Test("starting and stopping the polls is still observed")
    func activeFlagIsObserved() {
        let driver = driver(Feed())
        let fired8 = redraws(read: { _ = driver.isActive }, after: { driver.setActive(true) })
        #expect(fired8)
        let fired9 = redraws(read: { _ = driver.isActive }, after: { driver.setActive(false) })
        #expect(fired9)
    }

    @Test("the spoken percent is heard when the whole percent changes, not on every poll, and is kept at rest")
    func spokenPercentIsObserved() {
        let feed = Feed()
        let driver = driver(feed)
        feed.position = 20
        let first = redraws(read: { _ = driver.spokenPercent }, after: { driver.tick() })
        #expect(first)
        #expect(driver.spokenPercent == 10)

        // 10.25 percent is still 10.
        feed.position = 20.5
        let same = redraws(read: { _ = driver.spokenPercent }, after: { driver.tick() })
        #expect(same == false)

        feed.position = 22
        let moved = redraws(read: { _ = driver.spokenPercent }, after: { driver.tick() })
        #expect(moved)
        #expect(driver.spokenPercent == 11)

        let rested = redraws(read: { _ = driver.spokenPercent }, after: { driver.rest() })
        #expect(rested == false)
        #expect(driver.spokenPercent == 11)
    }
}

// MARK: - The paused seek's slide

@Suite("MusicSpectrum paused seek glide")
struct MusicSpectrumPausedGlideTests {
    @Test("the ease-out curve starts at nothing, ends at all of it, and never goes backwards")
    func easedOutShape() {
        #expect(MusicSpectrum.easedOut(0) == 0)
        #expect(abs(MusicSpectrum.easedOut(1) - 1) < 1e-9)
        var last = 0.0
        for step in 1...100 {
            let value = MusicSpectrum.easedOut(Double(step) / 100)
            #expect(value >= last)
            last = value
        }
    }

    @Test("it is quick at first: more than half of the way is done by half of the time")
    func easedOutIsQuickFirst() {
        let half = MusicSpectrum.easedOut(0.5)
        #expect(half > 0.65)
        #expect(half < 0.72)
    }

    @Test("a time out of range is held to it, and one that is not a number is the end")
    func easedOutOddInput() {
        #expect(MusicSpectrum.easedOut(-1) == 0)
        #expect(abs(MusicSpectrum.easedOut(7) - 1) < 1e-9)
        #expect(MusicSpectrum.easedOut(.nan) == 1)
        #expect(MusicSpectrum.easedOut(.infinity) == 1)
    }

    @Test("a move of the fill's edge of a point or less is not worth a slide, a larger one is")
    func glideIsVisible() {
        let height = MusicSpectrum.boxHeight
        #expect(MusicSpectrum.glideIsVisible(from: 0.5, to: 0.5, height: height) == false)
        #expect(MusicSpectrum.glideIsVisible(from: 0.5, to: 0.5 + 0.5 / (height + MusicSpectrum.fillEdge(height: height)), height: height) == false)
        #expect(MusicSpectrum.glideIsVisible(from: 0.5, to: 0.6, height: height))
        #expect(MusicSpectrum.glideIsVisible(from: 0.6, to: 0.5, height: height))
    }

    @Test("a taller box turns the same step of the song into more points")
    func glideScalesWithHeight() {
        let step = 0.004
        #expect(MusicSpectrum.glideIsVisible(from: 0.5, to: 0.5 + step, height: 100) == false)
        #expect(MusicSpectrum.glideIsVisible(from: 0.5, to: 0.5 + step, height: 600))
    }
}

// MARK: - The layer view

@MainActor
@Suite("MusicSpectrumLayerView")
struct MusicSpectrumLayerViewTests {
    private let levels = Array(repeating: 0.5, count: MusicSpectrum.barCount)

    private func style(
        hue: Double = 0,
        saturation: Double = 1,
        brightness: Double = 1,
        barsOpacity: Double = 1,
        unplayedOpacity: Double = 0.25,
        height: Double = MusicSpectrum.boxHeight,
        fixedWidth: Double? = nil
    ) -> MusicSpectrumStyle {
        MusicSpectrumStyle(
            hue: hue,
            saturation: saturation,
            brightness: brightness,
            barsOpacity: barsOpacity,
            unplayedOpacity: unplayedOpacity,
            height: height,
            fixedWidth: fixedWidth
        )
    }

    private func makeView(height: Double = MusicSpectrum.boxHeight) -> MusicSpectrumLayerView {
        MusicSpectrumLayerView(frame: NSRect(x: 0, y: 0, width: MusicSpectrum.boxWidth, height: height))
    }

    /// How much has been set on the layers so far: bar widths, the fill's points, the colours, full layouts.
    private func writeCounts(_ view: MusicSpectrumLayerView) -> [Int] {
        [view.barWrites, view.edgeWrites, view.colourWrites, view.layoutPasses]
    }

    /// A window the view sits in that is on screen for AppKit and invisible to the user (alpha 0, no focus, no mouse).
    private func show(_ view: MusicSpectrumLayerView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: view.frame.width, height: view.frame.height),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.collectionBehavior = [.transient, .ignoresCycle, .stationary]
        window.contentView?.addSubview(view)
        window.orderFrontRegardless()
        return window
    }

    /// The middle of the soft edge as the layers show it, from the top of the box, read from the gradient's two points.
    private func edgeMiddle(of view: MusicSpectrumLayerView) -> Double {
        let height = Double(view.bounds.height)
        return height * (1 - Double(view.gradientLayer.startPoint.y + view.gradientLayer.endPoint.y) / 2)
    }

    /// The view's layers rendered into an sRGB bitmap two pixels to the point, so the colours read back are the ones
    /// painted (no window, no screen profile). Returns the colour at a point `x`, `y` from the top left.
    private func pixels(of view: MusicSpectrumLayerView) throws -> (_ x: Int, _ y: Int) -> (r: Double, g: Double, b: Double, a: Double) {
        let bitmap = try SpectrumBitmap.renderOnGPU(try #require(view.layer), points: view.bounds.size, scale: 2)
        return { x, y in bitmap.pixel(x, y) }
    }

    @Test("the layer takes no mouse events, so the column's seek gesture and hover keep working over it")
    func takesNoMouseEvents() {
        let view = makeView()
        #expect(view.hitTest(NSPoint(x: 70, y: 50)) == nil)
    }

    @Test("the same picture again is not put on the layers, and a new one is")
    func appliesOnlyOnAChange() {
        let view = makeView()
        view.update(style: style(), levels: levels, progress: 0.5, live: nil)
        let first = view.appliedFrames
        #expect(first >= 1)
        view.update(style: style(), levels: levels, progress: 0.5, live: nil)
        #expect(view.appliedFrames == first)

        view.update(style: style(), levels: levels, progress: 0.5 + 0.0001, live: nil)
        #expect(view.appliedFrames == first)

        view.update(style: style(), levels: levels, progress: 0.6, live: nil)
        #expect(view.appliedFrames == first + 1)

        view.update(style: style(hue: 0.3), levels: levels, progress: 0.6, live: nil)
        #expect(view.appliedFrames == first + 2)

        view.update(style: style(hue: 0.3, barsOpacity: 0.5), levels: levels, progress: 0.6, live: nil)
        #expect(view.appliedFrames == first + 3)

        var louder = levels
        louder[4] = 0.9
        view.update(style: style(hue: 0.3, barsOpacity: 0.5), levels: louder, progress: 0.6, live: nil)
        #expect(view.appliedFrames == first + 4)
    }

    @Test("a resize lays the layers out again at the new size")
    func resizeLaysOutAgain() {
        let view = makeView()
        view.update(style: style(), levels: levels, progress: 0.5, live: nil)
        let before = view.appliedFrames
        let passes = view.layoutPasses
        view.setFrameSize(NSSize(width: MusicSpectrum.boxWidth, height: 160))
        #expect(view.appliedFrames == before + 1)
        #expect(view.layoutPasses == passes + 1)
        // The same size again says nothing.
        view.setFrameSize(NSSize(width: MusicSpectrum.boxWidth, height: 160))
        #expect(view.appliedFrames == before + 1)
        #expect(view.layoutPasses == passes + 1)
    }

    // MARK: Live

    private final class Feed {
        var level: Float = 0
        var position: TimeInterval = 0
        var duration: TimeInterval = 200
        var videoId: String? = "song"
    }

    private func driver(_ feed: Feed) -> MusicSpectrumDriver {
        MusicSpectrumDriver(sources: .init(
            level: { feed.level },
            position: { feed.position },
            duration: { feed.duration },
            videoId: { feed.videoId }
        ))
    }

    @Test("with a driver, a poll puts a frame on the layers and the view shows the driver's bars and fill")
    func followsTheDriver() {
        let feed = Feed()
        let driver = driver(feed)
        let view = makeView()
        view.update(style: style(), levels: levels, progress: 0, live: MusicSpectrumLive(driver: driver, videoId: "song"))
        #expect(driver.frameListenerCount == 1)
        let before = view.appliedFrames

        feed.position = 100
        feed.level = 0.2
        driver.tick()
        #expect(view.appliedFrames == before + 1)
        #expect(view.shownProgress == 0.5)
        #expect(view.shownLevels == driver.bars(for: "song"))
    }

    @Test("an unchanged poll sets nothing on the layers")
    func steadyPollIsSilentForTheView() {
        let feed = Feed()
        let driver = driver(feed)
        let view = makeView()
        view.update(style: style(), levels: levels, progress: 0, live: MusicSpectrumLive(driver: driver, videoId: "song"))
        feed.position = 100
        driver.tick()
        let before = view.appliedFrames
        let writes = writeCounts(view)
        driver.tick()
        driver.tick()
        #expect(view.appliedFrames == before)
        #expect(writeCounts(view) == writes)
    }

    @Test("when the driver rests, the view keeps the polls' last fill until SwiftUI says where the fill is now")
    func keepsTheLastFillWhenTheDriverRests() {
        let feed = Feed()
        let driver = driver(feed)
        let view = makeView()
        view.update(style: style(), levels: levels, progress: 0.9, live: MusicSpectrumLive(driver: driver, videoId: "song"))
        feed.position = 20
        driver.tick()
        #expect(view.shownProgress == 0.1)
        driver.rest()
        #expect(view.shownProgress == 0.1)
        // SwiftUI's own fill, when it comes, is the one shown (no window, so it lands at once).
        view.update(style: style(), levels: levels, progress: 0.9, live: MusicSpectrumLive(driver: driver, videoId: "song"))
        #expect(view.shownProgress == 0.9)
    }

    @Test("without a driver the view shows the fill SwiftUI gave it")
    func showsSwiftUIFillWithoutADriver() {
        let view = makeView()
        view.update(style: style(), levels: levels, progress: 0.9, live: nil)
        #expect(view.shownProgress == 0.9)
        view.update(style: style(), levels: levels, progress: 0.2, live: nil)
        #expect(view.shownProgress == 0.2)
    }

    @Test("a new SwiftUI update while the driver is live keeps the driver's fill")
    func swiftUIUpdateKeepsTheLiveFill() {
        let feed = Feed()
        let driver = driver(feed)
        let view = makeView()
        let live = MusicSpectrumLive(driver: driver, videoId: "song")
        view.update(style: style(), levels: levels, progress: 0, live: live)
        feed.position = 100
        driver.tick()
        view.update(style: style(hue: 0.2), levels: levels, progress: 0.01, live: live)
        #expect(view.shownProgress == 0.5)
    }

    // MARK: Pause and seek

    /// A window the view sits in without being shown: enough for the view to count as being in one.
    private func hold(_ view: MusicSpectrumLayerView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: view.frame.width, height: view.frame.height),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(view)
        return window
    }

    private func send(
        _ view: MusicSpectrumLayerView, progress: Double, isLive: Bool = false, glides: Bool = false,
        live: MusicSpectrumLive?
    ) {
        view.update(
            style: style(), levels: levels, progress: progress, progressIsLive: isLive, glides: glides, live: live
        )
    }

    @Test("pausing after a minute of play keeps the fill where playback is, whichever of the two updates comes first")
    func pauseKeepsTheFill() {
        for restFirst in [false, true] {
            let feed = Feed()
            let driver = driver(feed)
            let view = makeView()
            let window = hold(view)
            defer { window.close() }
            let live = MusicSpectrumLive(driver: driver, videoId: "song")

            // SwiftUI's picture when the polls began: the first poll's value, which it is never told to refresh.
            send(view, progress: 0.01, isLive: true, live: live)
            feed.position = 120
            driver.tick()
            #expect(view.shownProgress == 0.6)

            if restFirst {
                // The driver rests, then SwiftUI's update reads the player's own position.
                driver.rest()
                #expect(view.shownProgress == 0.6)
                send(view, progress: 0.6003, glides: true, live: live)
            } else {
                // SwiftUI's update (the state is paused, the polls have not been stopped yet) reads the poll's value,
                // then the driver rests, then SwiftUI reads the player's own position.
                send(view, progress: 0.6, isLive: true, glides: true, live: live)
                #expect(view.shownProgress == 0.6)
                driver.rest()
                #expect(view.shownProgress == 0.6)
                #expect(view.isGliding == false)
                send(view, progress: 0.6003, glides: true, live: live)
            }
            // No glide, no snap: the fill is where the song is.
            #expect(view.isGliding == false)
            #expect(view.isGlideLinked == false)
            #expect(abs(view.shownProgress - 0.6003) < 1e-9)
        }
    }

    @Test("a stale snapshot taken while the polls ran is never news about the fill")
    func staleSnapshotIsIgnored() {
        let feed = Feed()
        let driver = driver(feed)
        let view = makeView()
        let live = MusicSpectrumLive(driver: driver, videoId: "song")
        send(view, progress: 0.01, isLive: true, live: live)
        feed.position = 120
        driver.tick()
        // An update that rebuilds the view while playing (a colour change, say) still holds the first poll's value.
        send(view, progress: 0.01, isLive: true, live: live)
        driver.rest()
        send(view, progress: 0.01, isLive: true, live: live)
        #expect(view.shownProgress == 0.6)
    }

    @Test("a real seek while paused, after play, still slides the fill from where it stood")
    func seekAfterPlaySlides() {
        let feed = Feed()
        let driver = driver(feed)
        let view = makeView()
        let window = hold(view)
        defer { window.close() }
        let live = MusicSpectrumLive(driver: driver, videoId: "song")
        send(view, progress: 0.01, isLive: true, live: live)
        feed.position = 120
        driver.tick()
        driver.rest()
        send(view, progress: 0.6, glides: true, live: live)
        #expect(view.isGliding == false)

        send(view, progress: 0.9, glides: true, live: live)
        #expect(view.isGliding)
        #expect(view.isGlideLinked)
        #expect(view.shownProgress == 0.6)
    }

    @Test("a seek while paused slides the fill to the new place over the glide, quick at first, and the link goes")
    func pausedSeekGlides() throws {
        let view = makeView()
        let window = hold(view)
        defer { window.close() }
        send(view, progress: 0.2, live: nil)
        send(view, progress: 0.8, glides: true, live: nil)
        #expect(view.isGliding)
        #expect(view.isGlideLinked)
        #expect(view.shownProgress == 0.2)

        let start = try #require(view.glideStartedAt)
        view.advanceGlide(at: start + MusicSpectrum.pausedSeekGlide / 2)
        // Past the middle of the way at the middle of the time, not yet at the end.
        #expect(view.shownProgress > 0.5)
        #expect(view.shownProgress < 0.8)
        let half = view.shownProgress
        #expect(abs(half - (0.2 + 0.6 * MusicSpectrum.easedOut(0.5))) < 1e-9)

        view.advanceGlide(at: start + MusicSpectrum.pausedSeekGlide * 0.9)
        #expect(view.shownProgress > half)
        #expect(view.isGliding)

        view.advanceGlide(at: start + MusicSpectrum.pausedSeekGlide + 0.01)
        #expect(view.shownProgress == 0.8)
        #expect(view.isGliding == false)
        #expect(view.isGlideLinked == false)
    }

    @Test("the slide runs on its own display link and ends by itself")
    func glideEndsByItself() async throws {
        let view = makeView()
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: view.frame.width, height: view.frame.height),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.collectionBehavior = [.transient, .ignoresCycle, .stationary]
        window.contentView?.addSubview(view)
        window.orderFrontRegardless()
        defer { window.close() }

        send(view, progress: 0.2, live: nil)
        send(view, progress: 0.8, glides: true, live: nil)
        #expect(view.isGliding)
        try await Task.sleep(for: .milliseconds(900))
        #expect(view.isGliding == false)
        #expect(view.isGlideLinked == false)
        #expect(view.shownProgress == 0.8)
    }

    @Test("a new seek during a slide slides on from where the fill shows")
    func secondSeekRestartsFromHere() throws {
        let view = makeView()
        let window = hold(view)
        defer { window.close() }
        send(view, progress: 0.2, live: nil)
        send(view, progress: 0.8, glides: true, live: nil)
        let start = try #require(view.glideStartedAt)
        view.advanceGlide(at: start + MusicSpectrum.pausedSeekGlide / 2)
        let here = view.shownProgress
        send(view, progress: 0.4, glides: true, live: nil)
        #expect(view.isGliding)
        #expect(view.shownProgress == here)
        let again = try #require(view.glideStartedAt)
        view.advanceGlide(at: again + MusicSpectrum.pausedSeekGlide + 0.01)
        #expect(view.shownProgress == 0.4)
    }

    @Test("with no slide asked for, or no window, or a move too small to see, the fill lands at once")
    func noGlideCases() {
        // No slide asked for (playing, or Reduce Motion).
        let a = makeView()
        let windowA = hold(a)
        defer { windowA.close() }
        send(a, progress: 0.2, live: nil)
        send(a, progress: 0.8, glides: false, live: nil)
        #expect(a.isGliding == false)
        #expect(a.shownProgress == 0.8)

        // No window to be seen in.
        let b = makeView()
        send(b, progress: 0.2, live: nil)
        send(b, progress: 0.8, glides: true, live: nil)
        #expect(b.isGliding == false)
        #expect(b.shownProgress == 0.8)

        // A move under a point.
        let c = makeView()
        let windowC = hold(c)
        defer { windowC.close() }
        send(c, progress: 0.5, live: nil)
        send(c, progress: 0.5001, glides: true, live: nil)
        #expect(c.isGliding == false)
        #expect(c.shownProgress == 0.5001)
    }

    @Test("the polls starting again end a slide and show the driver's fill")
    func pollsEndTheSlide() {
        let feed = Feed()
        let driver = driver(feed)
        let view = makeView()
        let window = hold(view)
        defer { window.close() }
        let live = MusicSpectrumLive(driver: driver, videoId: "song")
        send(view, progress: 0.2, live: live)
        send(view, progress: 0.8, glides: true, live: live)
        #expect(view.isGliding)
        feed.position = 40
        driver.tick()
        #expect(view.isGliding == false)
        #expect(view.isGlideLinked == false)
        #expect(view.shownProgress == 0.2)
    }

    @Test("a view that leaves its window ends the slide on the target, and one that comes back with none has no link")
    func leavingTheWindowEndsTheSlide() {
        let view = makeView()
        let window = hold(view)
        defer { window.close() }
        send(view, progress: 0.2, live: nil)
        send(view, progress: 0.8, glides: true, live: nil)
        #expect(view.isGlideLinked)
        view.removeFromSuperview()
        #expect(view.isGliding == false)
        #expect(view.isGlideLinked == false)
        #expect(view.shownProgress == 0.8)
        window.contentView?.addSubview(view)
        #expect(view.isGlideLinked == false)
    }

    @Test("dropping the driver, or detaching, stops the listening")
    func detaches() {
        let feed = Feed()
        let driver = driver(feed)
        let view = makeView()
        view.update(style: style(), levels: levels, progress: 0, live: MusicSpectrumLive(driver: driver, videoId: "song"))
        #expect(driver.frameListenerCount == 1)
        view.update(style: style(), levels: levels, progress: 0, live: nil)
        #expect(driver.frameListenerCount == 0)

        view.update(style: style(), levels: levels, progress: 0, live: MusicSpectrumLive(driver: driver, videoId: "song"))
        #expect(driver.frameListenerCount == 1)
        view.detach()
        #expect(driver.frameListenerCount == 0)
    }

    @Test("the same driver and song again keeps the one listener")
    func oneListener() {
        let feed = Feed()
        let driver = driver(feed)
        let view = makeView()
        let live = MusicSpectrumLive(driver: driver, videoId: "song")
        view.update(style: style(), levels: levels, progress: 0, live: live)
        view.update(style: style(), levels: levels, progress: 0, live: live)
        view.update(style: style(), levels: levels, progress: 0, live: MusicSpectrumLive(driver: driver, videoId: "other"))
        #expect(driver.frameListenerCount == 1)
    }

    // MARK: Pixels

    @Test("played bars wear the accent, unplayed bars the faint white, each as wide as its level says")
    func drawsTheBars() throws {
        let view = makeView()
        view.update(style: style(hue: 0, saturation: 1, brightness: 1), levels: levels, progress: 0.5, live: nil)
        let pixel = try pixels(of: view)

        // Bar 0 is far above the fill's edge: red. Bar 27 is far below: white at a quarter.
        let top = pixel(71, Int(MusicSpectrum.barY(0)) + 1)
        #expect(abs(top.r - 1) < 0.03 && top.g < 0.03 && top.b < 0.03 && abs(top.a - 1) < 0.03)
        let bottom = pixel(71, Int(MusicSpectrum.barY(27)) + 1)
        #expect(abs(bottom.r - 1) < 0.03 && abs(bottom.g - 1) < 0.03 && abs(bottom.b - 1) < 0.03)
        #expect(abs(bottom.a - 0.25) < 0.03)

        // Between two bars there is nothing.
        let gap = pixel(71, Int(MusicSpectrum.barY(5)) + 3)
        #expect(gap.a < 0.03)

        // The bar is as wide as its level says, and no wider.
        let width = MusicSpectrum.width(forLevel: 0.5)
        let y = Int(MusicSpectrum.barY(0)) + 1
        let inside = pixel(Int((MusicSpectrum.boxWidth - width) / 2) + 2, y)
        let outside = pixel(Int((MusicSpectrum.boxWidth - width) / 2) - 2, y)
        #expect(inside.a > 0.9)
        #expect(outside.a < 0.03)
    }

    @Test("the fill reaches no bar at the start of the song and every bar at the end")
    func fillExtremes() throws {
        let start = makeView()
        start.update(style: style(), levels: levels, progress: 0, live: nil)
        let atStart = try pixels(of: start)
        for index in 0..<MusicSpectrum.barCount {
            let p = atStart(71, Int(MusicSpectrum.barY(index)) + 1)
            #expect(abs(p.a - 0.25) < 0.03 && p.g > 0.9)
        }

        let end = makeView()
        end.update(style: style(), levels: levels, progress: 1, live: nil)
        let atEnd = try pixels(of: end)
        for index in 0..<MusicSpectrum.barCount {
            let p = atEnd(71, Int(MusicSpectrum.barY(index)) + 1)
            #expect(abs(p.a - 1) < 0.03 && p.g < 0.03)
        }
    }

    @Test("a dimmed spectrum dims the accent and the white alike")
    func barsOpacity() throws {
        let view = makeView()
        view.update(style: style(barsOpacity: 0.5), levels: levels, progress: 0.5, live: nil)
        let pixel = try pixels(of: view)
        let top = pixel(71, Int(MusicSpectrum.barY(0)) + 1)
        let bottom = pixel(71, Int(MusicSpectrum.barY(27)) + 1)
        #expect(abs(top.a - 0.5) < 0.03)
        #expect(abs(bottom.a - 0.125) < 0.03)
    }

    @Test("a bar in the soft edge takes the colour gradually, between the accent and the white")
    func softEdge() throws {
        let view = makeView()
        // The edge's middle on the top of bar 14.
        let edgeY = MusicSpectrum.barY(14)
        let edge = MusicSpectrum.fillEdge()
        view.update(style: style(), levels: levels, progress: (edgeY + edge / 2) / (MusicSpectrum.boxHeight + edge), live: nil)
        let pixel = try pixels(of: view)
        let above = pixel(71, Int(MusicSpectrum.barY(12)) + 1)
        let on = pixel(71, Int(MusicSpectrum.barY(14)) + 1)
        let below = pixel(71, Int(MusicSpectrum.barY(16)) + 1)
        #expect(above.g < 0.05)
        #expect(below.g > 0.9)
        #expect(on.g > 0.05 && on.g < 0.95)
    }

    @Test("a taller box draws the bars further apart, down to the last one")
    func tallerBox() throws {
        let view = makeView(height: 208)
        view.update(style: style(height: 208), levels: levels, progress: 1, live: nil)
        let pixel = try pixels(of: view)
        let thickness = MusicSpectrum.barThickness(height: 208)
        let last = pixel(71, Int(MusicSpectrum.barY(27, height: 208) + thickness / 2))
        #expect(last.a > 0.9)
        let gap = pixel(71, Int(MusicSpectrum.barY(26, height: 208) + thickness) + 2)
        #expect(gap.a < 0.03)
    }

    @Test("flat bars of a fixed width are drawn all the same width")
    func fixedWidthBars() throws {
        let view = makeView()
        var mixed = levels
        mixed[0] = 1
        view.update(style: style(unplayedOpacity: 0.09, fixedWidth: 40), levels: mixed, progress: 0, live: nil)
        let pixel = try pixels(of: view)
        let y = Int(MusicSpectrum.barY(0)) + 1
        #expect(pixel(71 + 18, y).a > 0.05)
        #expect(pixel(71 + 24, y).a < 0.02)
    }

    // MARK: Layers

    private func close(_ a: CGRect, _ b: CGRect, within tolerance: Double = 1e-6) -> Bool {
        abs(a.minX - b.minX) < tolerance && abs(a.minY - b.minY) < tolerance
            && abs(a.width - b.width) < tolerance && abs(a.height - b.height) < tolerance
    }

    /// A spread of levels, so that no two bars are as wide.
    private var spread: [Double] {
        (0..<MusicSpectrum.barCount).map { MusicSpectrum.minLevel + (1 - MusicSpectrum.minLevel) * Double($0 * 7 % 28) / 27 }
    }

    @Test("the picture is 28 bar layers masking one gradient layer")
    func layerStructure() {
        let view = makeView()
        view.update(style: style(), levels: spread, progress: 0.5, live: nil)
        #expect(view.barLayers.count == MusicSpectrum.barCount)
        #expect(view.gradientLayer.superlayer === view.layer)
        #expect(view.gradientLayer.mask === view.barsLayer)
        #expect(view.barLayers.allSatisfy { $0.superlayer === view.barsLayer })
        #expect(view.barsLayer.sublayers?.count == MusicSpectrum.barCount)
        #expect(view.layer?.sublayers?.count == 1)
    }

    @Test("each bar layer stands where the bar stood: centred, as wide as its level, as thick as the box says, round ended")
    func barGeometry() {
        for height in [MusicSpectrum.boxHeight, 160, 208, 300] {
            let view = makeView(height: height)
            let levels = spread
            view.update(style: style(height: height), levels: levels, progress: 0.5, live: nil)
            let thickness = MusicSpectrum.barThickness(height: height)
            for (index, bar) in view.barLayers.enumerated() {
                let width = MusicSpectrum.width(forLevel: levels[index])
                // The layers' space runs up from the bottom left; the box's runs down from the top left.
                let expected = CGRect(
                    x: (MusicSpectrum.boxWidth - width) / 2,
                    y: height - (MusicSpectrum.barY(index, height: height) + thickness),
                    width: width,
                    height: thickness
                )
                #expect(close(bar.frame, expected), "bar \(index) at \(height): \(bar.frame) not \(expected)")
                #expect(abs(Double(bar.cornerRadius) - thickness / 2) < 1e-4)
                #expect(bar.isHidden == false)
            }
        }
    }

    @Test("a bar with no level is not there")
    func missingLevelsHideBars() {
        let view = makeView()
        view.update(style: style(), levels: Array(spread.prefix(10)), progress: 0.5, live: nil)
        #expect(view.barLayers.prefix(10).allSatisfy { !$0.isHidden })
        #expect(view.barLayers.dropFirst(10).allSatisfy { $0.isHidden })
        view.update(style: style(), levels: spread, progress: 0.5, live: nil)
        #expect(view.barLayers.allSatisfy { !$0.isHidden })
    }

    @Test("the gradient's two points are the two sides of the soft edge, and its colours the accent and the dimmed white")
    func gradientPaint() throws {
        let view = makeView()
        let progress = 0.37
        view.update(style: style(hue: 0.6, saturation: 0.7, brightness: 0.9, barsOpacity: 0.5, unplayedOpacity: 0.09), levels: spread, progress: progress, live: nil)
        let edge = MusicSpectrum.fillEdge()
        let middle = MusicSpectrum.fillEdgeY(progress: progress)
        let height = MusicSpectrum.boxHeight
        let start = view.gradientLayer.startPoint
        let end = view.gradientLayer.endPoint
        #expect(abs(Double(start.x) - 0.5) < 1e-9 && abs(Double(end.x) - 0.5) < 1e-9)
        #expect(abs(height * (1 - Double(start.y)) - (middle - edge / 2)) < 1e-6)
        #expect(abs(height * (1 - Double(end.y)) - (middle + edge / 2)) < 1e-6)
        #expect(abs(edgeMiddle(of: view) - middle) < 1e-6)

        let colours = try #require(view.gradientLayer.colors as? [CGColor])
        #expect(colours.count == 2)
        let rgb = MusicSpectrum.rgb(hue: 0.6, saturation: 0.7, brightness: 0.9)
        let played = try #require(colours.first?.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components)
        let unplayed = try #require(colours.last?.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components)
        #expect(abs(Double(played[0]) - rgb.red) < 1e-4 && abs(Double(played[1]) - rgb.green) < 1e-4 && abs(Double(played[2]) - rgb.blue) < 1e-4)
        #expect(abs(Double(played[3]) - 0.5) < 1e-4)
        #expect(abs(Double(unplayed[0]) - 1) < 1e-4 && abs(Double(unplayed[3]) - 0.045) < 1e-4)
    }

    @Test("the layers show the fill the view says it shows, at the start, the end and in between")
    func layersFollowTheFill() {
        let view = makeView()
        for progress in [0.0, 0.01, 0.25, 0.5, 0.9, 1.0] {
            view.update(style: style(), levels: spread, progress: progress, live: nil)
            #expect(abs(edgeMiddle(of: view) - MusicSpectrum.fillEdgeY(progress: view.shownProgress)) < 1e-6, "progress \(progress)")
        }
    }

    // MARK: Writes

    @Test("the same frame sets nothing; a fill that moves under a quarter point sets nothing")
    func unchangedFramesWriteNothing() {
        let view = makeView()
        view.update(style: style(), levels: spread, progress: 0.5, live: nil)
        let counts = writeCounts(view)
        view.update(style: style(), levels: spread, progress: 0.5, live: nil)
        view.update(style: style(), levels: spread, progress: 0.5 + 1e-5, live: nil)
        // A level that moves a bar by under a half point.
        var nudged = spread
        nudged[3] += 0.0005
        view.update(style: style(), levels: nudged, progress: 0.5, live: nil)
        #expect(writeCounts(view) == counts)
    }

    @Test("one bar's new level sets that bar's layer and nothing else")
    func oneBarWritesOneBar() {
        let view = makeView()
        view.update(style: style(), levels: spread, progress: 0.5, live: nil)
        let counts = writeCounts(view)
        let others = view.barLayers.map(\.bounds)
        var louder = spread
        louder[9] = min(1, louder[9] + 0.2)
        view.update(style: style(), levels: louder, progress: 0.5, live: nil)
        #expect(view.barWrites == counts[0] + 1)
        #expect(view.edgeWrites == counts[1])
        #expect(view.colourWrites == counts[2])
        #expect(view.layoutPasses == counts[3])
        for (index, bar) in view.barLayers.enumerated() where index != 9 {
            #expect(bar.bounds == others[index])
        }
        #expect(abs(view.barLayers[9].bounds.width - MusicSpectrum.width(forLevel: louder[9])) < 1e-9)
    }

    @Test("a fill that moves sets the gradient's two points and nothing else")
    func fillWritesTheEdgeOnly() {
        let view = makeView()
        view.update(style: style(), levels: spread, progress: 0.5, live: nil)
        let counts = writeCounts(view)
        view.update(style: style(), levels: spread, progress: 0.52, live: nil)
        #expect(view.barWrites == counts[0])
        #expect(view.edgeWrites == counts[1] + 1)
        #expect(view.colourWrites == counts[2])
        #expect(view.layoutPasses == counts[3])
    }

    @Test("a new accent or dim sets the colours and nothing else")
    func accentWritesColoursOnly() {
        let view = makeView()
        view.update(style: style(), levels: spread, progress: 0.5, live: nil)
        let counts = writeCounts(view)
        view.update(style: style(hue: 0.4), levels: spread, progress: 0.5, live: nil)
        #expect(view.colourWrites == counts[2] + 1)
        view.update(style: style(hue: 0.4, barsOpacity: 0.5), levels: spread, progress: 0.5, live: nil)
        #expect(view.colourWrites == counts[2] + 2)
        view.update(style: style(hue: 0.4, barsOpacity: 0.5, unplayedOpacity: 0.07), levels: spread, progress: 0.5, live: nil)
        #expect(view.colourWrites == counts[2] + 3)
        #expect(view.barWrites == counts[0])
        #expect(view.edgeWrites == counts[1])
        #expect(view.layoutPasses == counts[3])
    }

    @Test("a taller box lays every layer out again")
    func heightRelays() {
        let view = makeView()
        view.update(style: style(), levels: spread, progress: 0.5, live: nil)
        let passes = view.layoutPasses
        view.setFrameSize(NSSize(width: MusicSpectrum.boxWidth, height: 208))
        view.update(style: style(height: 208), levels: spread, progress: 0.5, live: nil)
        // The frame's new size lays them out, and the style's new height may do it again; never more.
        #expect((passes + 1)...(passes + 2) ~= view.layoutPasses)
        let thickness = MusicSpectrum.barThickness(height: 208)
        #expect(thickness > MusicSpectrum.barThickness)
        #expect(view.barLayers.allSatisfy { abs($0.bounds.height - thickness) < 1e-4 && abs(Double($0.cornerRadius) - thickness / 2) < 1e-4 })
    }

    @Test("playing, a poll sets at most the two bars whose width the pulse changes, and the fill's points")
    func pollsWriteLittle() {
        let feed = Feed()
        let driver = driver(feed)
        let view = makeView()
        view.update(style: style(), levels: levels, progress: 0, live: MusicSpectrumLive(driver: driver, videoId: "song"))
        feed.position = 20
        feed.level = 0.1
        driver.tick()
        var polls = 0
        for step in 1...60 {
            feed.position = 20 + Double(step) * 0.3
            feed.level = 0.05 + Float(step % 7) * 0.02
            let before = writeCounts(view)
            driver.tick()
            let after = writeCounts(view)
            polls += 1
            #expect(after[0] - before[0] <= 2, "poll \(step) set \(after[0] - before[0]) bars")
            #expect(after[1] - before[1] <= 1)
            #expect(after[2] == before[2])
            #expect(after[3] == before[3])
        }
        #expect(polls == 60)
    }

    // MARK: Not drawn

    @Test("the view draws nothing: no redraw policy, no backing store, no display requests as the picture changes")
    func neverDraws() async throws {
        let view = makeView()
        let window = show(view)
        defer { window.close() }
        #expect(view.wantsUpdateLayer)
        #expect(view.layerContentsRedrawPolicy == .never)
        view.update(style: style(), levels: spread, progress: 0.2, live: nil)
        window.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        // The first display is over; what is checked is what the changes below ask for.
        view.needsDisplay = false

        for step in 1...30 {
            var changed = spread
            changed[step % 28] = 0.1 + 0.03 * Double(step % 30)
            view.update(
                style: style(hue: Double(step) / 30, barsOpacity: step % 2 == 0 ? 1 : 0.5),
                levels: changed, progress: Double(step) / 30, live: nil
            )
        }
        view.setFrameSize(NSSize(width: MusicSpectrum.boxWidth, height: 150))
        view.update(style: style(height: 150), levels: spread, progress: 0.4, live: nil)
        #expect(view.needsDisplay == false)
        #expect(view.layer?.needsDisplay() == false)
        for layer in [view.gradientLayer, view.barsLayer] + view.barLayers {
            #expect(layer.needsDisplay() == false)
            #expect(layer.contents == nil)
        }
        #expect(view.layer?.contents == nil)
    }

    @Test("a change is never animated implicitly: no layer is left with an animation")
    func noImplicitAnimations() async throws {
        let view = makeView()
        let window = show(view)
        defer { window.close() }
        view.update(style: style(), levels: spread, progress: 0.2, live: nil)
        window.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        var changed = spread
        changed[2] = 0.9
        changed[20] = 0.1
        view.update(style: style(hue: 0.5, barsOpacity: 0.5), levels: changed, progress: 0.8, live: nil)
        view.setFrameSize(NSSize(width: MusicSpectrum.boxWidth, height: 180))
        view.update(style: style(height: 180), levels: changed, progress: 0.8, live: nil)
        for layer in [view.gradientLayer, view.barsLayer] + view.barLayers {
            #expect(layer.animationKeys() == nil)
        }
    }

    // MARK: The hand-off and the slide, as the layers show them

    @Test("pausing keeps the layers' fill where playback was, and SwiftUI's later fill moves it there")
    func layersKeepTheFillAtRest() {
        let feed = Feed()
        let driver = driver(feed)
        let view = makeView()
        let window = hold(view)
        defer { window.close() }
        let live = MusicSpectrumLive(driver: driver, videoId: "song")
        send(view, progress: 0.01, isLive: true, live: live)
        feed.position = 120
        driver.tick()
        #expect(abs(edgeMiddle(of: view) - MusicSpectrum.fillEdgeY(progress: 0.6)) < 1e-6)
        let counts = writeCounts(view)

        // The rest and SwiftUI's stale picture say nothing new: the layers do not move.
        driver.rest()
        send(view, progress: 0.01, isLive: true, glides: true, live: live)
        #expect(abs(edgeMiddle(of: view) - MusicSpectrum.fillEdgeY(progress: 0.6)) < 1e-6)
        #expect(writeCounts(view) == counts)

        send(view, progress: 0.6003, glides: true, live: live)
        // The edge is kept to a quarter point, so it is within an eighth of the exact one.
        #expect(abs(edgeMiddle(of: view) - MusicSpectrum.fillEdgeY(progress: 0.6003)) < 0.13)
    }

    @Test("a seek while paused slides the layers' fill, step by step, and ends on the target")
    func layersSlide() throws {
        let view = makeView()
        let window = hold(view)
        defer { window.close() }
        send(view, progress: 0.2, live: nil)
        send(view, progress: 0.8, glides: true, live: nil)
        #expect(abs(edgeMiddle(of: view) - MusicSpectrum.fillEdgeY(progress: 0.2)) < 1e-6)
        let start = try #require(view.glideStartedAt)
        var last = edgeMiddle(of: view)
        for step in 1...9 {
            view.advanceGlide(at: start + MusicSpectrum.pausedSeekGlide * Double(step) / 10)
            let now = edgeMiddle(of: view)
            #expect(now > last)
            #expect(abs(now - MusicSpectrum.fillEdgeY(progress: view.shownProgress)) < 1e-6)
            last = now
        }
        view.advanceGlide(at: start + MusicSpectrum.pausedSeekGlide + 0.01)
        #expect(abs(edgeMiddle(of: view) - MusicSpectrum.fillEdgeY(progress: 0.8)) < 1e-6)
    }

    // MARK: Parity with the drawing the layers replaced

    private struct Look {
        let name: String
        let levels: [Double]
        let progress: Double
        let style: MusicSpectrumStyle

        /// Every bar is one opacity (all played or all unplayed), so the centre of the picture is the bars' and nothing else.
        var uniform: Bool { progress <= 0 || progress >= 1 }
    }

    private var looks: [Look] {
        let seeded = MusicSpectrum.seededLevels(seed: MusicSpectrum.seed(forVideoId: "parity"))
        func make(
            _ name: String, levels: [Double]? = nil, progress: Double, hue: Double = 0.07, saturation: Double = 0.8,
            brightness: Double = 1, barsOpacity: Double = 1, unplayedOpacity: Double = 0.25,
            height: Double = MusicSpectrum.boxHeight, fixedWidth: Double? = nil
        ) -> Look {
            Look(
                name: name, levels: levels ?? seeded, progress: progress,
                style: style(
                    hue: hue, saturation: saturation, brightness: brightness, barsOpacity: barsOpacity,
                    unplayedOpacity: unplayedOpacity, height: height, fixedWidth: fixedWidth
                )
            )
        }
        return [
            make("start", progress: 0),
            make("just begun", progress: 0.03),
            make("a third", progress: 0.33, hue: 0.6, saturation: 0.7, brightness: 0.9),
            make("half, red", progress: 0.5, hue: 0, saturation: 1),
            make("an edge on a bar", progress: 0.612),
            make("nearly done", progress: 0.97),
            make("end", progress: 1),
            make("paused dim", progress: 0.4, barsOpacity: 0.55),
            make("loading", progress: 0.4, unplayedOpacity: 0.07),
            make("empty state", progress: 0, unplayedOpacity: 0.09, fixedWidth: MusicPlayerColumnState.emptyBarWidth),
            make("taller", progress: 0.55, height: 208),
            make("tallest", progress: 0.21, hue: 0.33, height: 300),
            make("white accent", progress: 0.5, saturation: 0, brightness: 1),
            make("dark accent", progress: 0.5, hue: 0.8, saturation: 1, brightness: 0.3),
            make("taller, nothing played", progress: 0, height: 208),
            make("tallest, all played", progress: 1, hue: 0.33, height: 300),
        ]
    }

    @Test("the layers paint what the old drawing painted, at several levels, fills, tints, dims and heights")
    func paintsLikeTheOldDrawing() throws {
        for look in looks {
            let view = makeView(height: look.style.height)
            view.update(style: look.style, levels: look.levels, progress: look.progress, live: nil)
            let size = view.bounds.size
            let new = try SpectrumBitmap.renderOnGPU(try #require(view.layer), points: size, scale: 2)
            let old = try SpectrumBitmap.render(points: size, scale: 2) {
                drawnTheOldWay(into: $0, width: size.width, levels: look.levels, progress: look.progress, style: look.style)
            }
            let parity = new.parity(with: old, flat: 10)
            // Away from any edge the two agree to a level or two (the gradient's shader rounds a little differently).
            #expect(parity.flatLargest <= 4, "\(look.name): flat pixels differ by \(parity.flatLargest)")
            // Along an edge the GPU's anti-aliasing and Core Graphics' differ by up to a fifth of a pixel's coverage.
            #expect(parity.edgeLargest <= 64, "\(look.name): edge pixels differ by \(parity.edgeLargest)")
            #expect(parity.edgePixels * 100 < parity.flatPixels * 50, "\(look.name): too many edge pixels")
            // The same shapes in the same places: the same area (to the rounding of a translucent bar's opacity) and, for
            // a picture of one opacity, the centre to a hundredth of a point.
            #expect(parity.area < 0.03, "\(look.name): area differs by \(parity.area)")
            #expect(parity.shift < (look.uniform ? 0.02 : 0.12), "\(look.name): centre moved by \(parity.shift) points")
        }
    }
}
