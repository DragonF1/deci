// DeciTests/Music/MusicSpectrumLayerTests.swift
// The spectrum is drawn by a layer, not by SwiftUI: thirty polls a second must not run the popup's SwiftUI update, so the
// driver keeps its per poll numbers out of observation and tells the layer directly, and only when something that shows
// has changed. Covered here: the quantized picture a poll is compared by, the driver's notifications and what a view
// can still observe, and the layer view's own redraws and pixels. Nothing is shown on screen.

import AppKit
import Observation
import os
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

    /// The view drawn straight into an sRGB bitmap four pixels to the point, so the colours read back are the ones drawn
    /// (no window, no screen profile). Returns the colour at a point `x`, `y` from the top left.
    private func pixels(of view: MusicSpectrumLayerView) throws -> (_ x: Int, _ y: Int) -> (r: Double, g: Double, b: Double, a: Double) {
        let scale = 4
        let width = Int(view.bounds.width) * scale
        let height = Int(view.bounds.height) * scale
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        // Top left origin, as the flipped view draws.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
        let graphics = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        view.draw(view.bounds)
        NSGraphicsContext.restoreGraphicsState()
        let data = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        return { x, y in
            // The closure keeps the bitmap alive: the pixels are read through its memory.
            withExtendedLifetime(context) {}
            let offset = (y * scale * width + x * scale) * 4
            let alpha = Double(data[offset + 3]) / 255
            guard alpha > 0 else { return (0, 0, 0, 0) }
            return (
                Double(data[offset]) / 255 / alpha, Double(data[offset + 1]) / 255 / alpha,
                Double(data[offset + 2]) / 255 / alpha, alpha
            )
        }
    }

    @Test("the layer takes no mouse events, so the column's seek gesture and hover keep working over it")
    func takesNoMouseEvents() {
        let view = makeView()
        #expect(view.hitTest(NSPoint(x: 70, y: 50)) == nil)
    }

    @Test("the same picture again is not redrawn, and a new one is")
    func redrawsOnlyOnAChange() {
        let view = makeView()
        view.update(style: style(), levels: levels, progress: 0.5, live: nil)
        let first = view.invalidations
        #expect(first >= 1)
        view.update(style: style(), levels: levels, progress: 0.5, live: nil)
        #expect(view.invalidations == first)

        view.update(style: style(), levels: levels, progress: 0.5 + 0.0001, live: nil)
        #expect(view.invalidations == first)

        view.update(style: style(), levels: levels, progress: 0.6, live: nil)
        #expect(view.invalidations == first + 1)

        view.update(style: style(hue: 0.3), levels: levels, progress: 0.6, live: nil)
        #expect(view.invalidations == first + 2)

        view.update(style: style(hue: 0.3, barsOpacity: 0.5), levels: levels, progress: 0.6, live: nil)
        #expect(view.invalidations == first + 3)

        var louder = levels
        louder[4] = 0.9
        view.update(style: style(hue: 0.3, barsOpacity: 0.5), levels: louder, progress: 0.6, live: nil)
        #expect(view.invalidations == first + 4)
    }

    @Test("a resize redraws the picture at the new size")
    func resizeRedraws() {
        let view = makeView()
        view.update(style: style(), levels: levels, progress: 0.5, live: nil)
        let before = view.invalidations
        view.setFrameSize(NSSize(width: MusicSpectrum.boxWidth, height: 160))
        #expect(view.invalidations == before + 1)
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

    @Test("with a driver, a poll redraws the view and it shows the driver's bars and fill")
    func followsTheDriver() {
        let feed = Feed()
        let driver = driver(feed)
        let view = makeView()
        view.update(style: style(), levels: levels, progress: 0, live: MusicSpectrumLive(driver: driver, videoId: "song"))
        #expect(driver.frameListenerCount == 1)
        let before = view.invalidations

        feed.position = 100
        feed.level = 0.2
        driver.tick()
        #expect(view.invalidations == before + 1)
        #expect(view.shownProgress == 0.5)
        #expect(view.shownLevels == driver.bars(for: "song"))
    }

    @Test("an unchanged poll does not redraw the view")
    func steadyPollIsSilentForTheView() {
        let feed = Feed()
        let driver = driver(feed)
        let view = makeView()
        view.update(style: style(), levels: levels, progress: 0, live: MusicSpectrumLive(driver: driver, videoId: "song"))
        feed.position = 100
        driver.tick()
        let before = view.invalidations
        driver.tick()
        driver.tick()
        #expect(view.invalidations == before)
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
}
