// DeciTests/Music/MusicRateBurstViewTests.swift
// The like animation as drawn: the strip's Like and Dislike buttons wear it for the event they are given and no other,
// it never changes the strip's size or moves a neighbour, a finished one looks exactly like the plain icon, and the
// sparks are painted outside the layout. Rendered offscreen at four times the size.

import AppKit
import SwiftUI
import Testing
@testable import Deci

@MainActor
@Suite("Music rate burst view")
struct MusicRateBurstViewTests {
    private let longAgo = Date(timeIntervalSince1970: 1_000)

    private func event(
        _ kind: MusicRateBurst.Kind,
        surface: MusicRateBurst.Surface = .strip,
        reduceMotion: Bool = false,
        isRemoval: Bool = false
    ) -> MusicRateBurstCenter.Event {
        MusicRateBurstCenter.Event(
            id: 7,
            kind: kind,
            surface: surface,
            reduceMotion: reduceMotion,
            startedAt: longAgo,
            isRemoval: isRemoval
        )
    }

    /// All the white on a view drawn on black: the sum of the red channel, in points squared.
    private func ink<V: View>(of view: V, scale: CGFloat = 4) throws -> Double {
        let renderer = ImageRenderer(content: view.background(Color.black))
        renderer.scale = scale
        let rep = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
        var total = 0.0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                total += Double(rep.colorAt(x: x, y: y)?.redComponent ?? 0)
            }
        }
        return total / Double(scale * scale)
    }

    /// Where the white is on a view drawn on black, as the middle of its box in points from the view's top left.
    private func inkMiddle<V: View>(of view: V, scale: CGFloat = 4) throws -> CGPoint {
        let renderer = ImageRenderer(content: view.background(Color.black))
        renderer.scale = scale
        let rep = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
        var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.redComponent ?? 0) > 0.5 {
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= minX else { return .zero }
        return CGPoint(x: Double(minX + maxX + 1) / 2 / scale, y: Double(minY + maxY + 1) / 2 / scale)
    }

    /// The brightest red channel on each half of a view drawn on black.
    private struct Halves {
        let leftPeak: Double
        let rightPeak: Double
    }

    private func halves<V: View>(of view: V, scale: CGFloat = 4) throws -> Halves {
        let renderer = ImageRenderer(content: view.background(Color.black))
        renderer.scale = scale
        let image = try #require(renderer.cgImage)
        let rep = NSBitmapImageRep(cgImage: image)
        let middle = rep.pixelsWide / 2
        func peak(_ columns: Range<Int>) -> Double {
            var best = 0.0
            for y in 0..<rep.pixelsHigh {
                for x in columns {
                    best = max(best, Double(rep.colorAt(x: x, y: y)?.redComponent ?? 0))
                }
            }
            return best
        }
        let left = peak(0..<middle), right = peak(middle..<rep.pixelsWide)
        return Halves(leftPeak: left, rightPeak: right)
    }

    private func strip(status: MusicLikeStatus?, burst: MusicRateBurstCenter.Event?) -> MusicRateStrip {
        MusicRateStrip(isAvailable: true, status: status, burst: burst, onDislike: {}, onLike: {})
    }

    // MARK: - The strip

    @Test("The strip keeps its size with a burst on either button, so nothing around it moves")
    func stripKeepsItsSize() {
        let width = MusicPopupMetrics.playerColumnContentWidth
        for kind in [MusicRateBurst.Kind.like, .dislike] {
            for status in [nil, .like, .dislike] as [MusicLikeStatus?] {
                let size = NSHostingView(rootView: strip(status: status, burst: event(kind))).fittingSize
                #expect(size.width == width)
                #expect(size.height == MusicPopupMetrics.rateStripHeight)
            }
        }
    }

    @Test("A finished burst on Like is the plain filled icon, and the Dislike beside it is untouched")
    func finishedLikeLooksPlain() throws {
        let plain = try halves(of: strip(status: .like, burst: nil))
        let finished = try halves(of: strip(status: .like, burst: event(.like)))
        #expect(finished.leftPeak == plain.leftPeak)
        #expect(finished.rightPeak == plain.rightPeak)
        #expect(finished.leftPeak > 0.9)
    }

    @Test("A finished burst on Dislike is the plain filled icon, and the Like beside it is untouched")
    func finishedDislikeLooksPlain() throws {
        let plain = try halves(of: strip(status: .dislike, burst: nil))
        let finished = try halves(of: strip(status: .dislike, burst: event(.dislike)))
        #expect(finished.leftPeak == plain.leftPeak)
        #expect(finished.rightPeak == plain.rightPeak)
        #expect(finished.rightPeak > 0.9)
    }

    @Test("A burst for the pill is not drawn on the strip")
    func pillEventsAreIgnored() throws {
        let plain = try halves(of: strip(status: .like, burst: nil))
        let other = try halves(of: strip(status: .like, burst: event(.like, surface: .pill)))
        #expect(other.leftPeak == plain.leftPeak)
        #expect(other.rightPeak == plain.rightPeak)
    }

    // MARK: - The pieces

    @Test("The first frame is the outline thumb at the resting brightness, and the last is the filled one in full white")
    func outlineThenFilled() throws {
        let glyph: CGFloat = 12
        let start = MusicRateBurst.frame(at: 0, kind: .like, reduceMotion: false)
        let outline = MusicRateBurstFrameView(kind: .like, frame: start, glyphSize: glyph, restingOpacity: 0.5, sparkReach: .infinity)
        let dim = try halves(of: outline.padding(8))
        #expect(dim.leftPeak > 0.45)
        #expect(dim.leftPeak <= 0.52)

        let end = MusicRateBurst.frame(at: 1, kind: .like, reduceMotion: false)
        let filled = MusicRateBurstFrameView(kind: .like, frame: end, glyphSize: glyph, restingOpacity: 0.5, sparkReach: .infinity)
        let bright = try halves(of: filled.padding(8))
        #expect(bright.leftPeak > 0.9)
    }

    @Test("A frame view is as big as its glyph, whatever the frame, so the sparks add no layout")
    func frameViewKeepsItsBox() {
        let glyph: CGFloat = 12
        for seconds in [0, 0.06, 0.133, 0.25, 0.4, 0.6, 0.9] {
            let frame = MusicRateBurst.frame(at: seconds, kind: .like, reduceMotion: false)
            let view = MusicRateBurstFrameView(kind: .like, frame: frame, glyphSize: glyph, restingOpacity: 0.5, sparkReach: .infinity)
            let size = NSHostingView(rootView: view).fittingSize
            #expect(size.width <= glyph + 2)
            #expect(size.height <= glyph + 2)
            #expect(size.width >= glyph - 2)
        }
    }

    @Test("The sparks are drawn out of the layout, past the glyph's box, and a dislike's frame has none")
    func sparksSpillPastTheBox() throws {
        let glyph: CGFloat = 12
        let pop = MusicRateBurst.frame(at: 0.25, kind: .like, reduceMotion: false)
        let like = MusicRateBurstFrameView(kind: .like, frame: pop, glyphSize: glyph, restingOpacity: 0.5, sparkReach: .infinity)
        let withSparks = try redInkBounds(of: like.padding(12), glyph: glyph)
        // Red ink: the sparks, further out than the box of the glyph itself (6 pt each way from the middle).
        #expect(withSparks.width > glyph + 2)
        #expect(withSparks.height > glyph + 2)

        let flat = MusicRateBurst.frame(at: 0.25, kind: .dislike, reduceMotion: false)
        let dislike = MusicRateBurstFrameView(kind: .dislike, frame: flat, glyphSize: glyph, restingOpacity: 0.5, sparkReach: .infinity)
        let none = try redInkBounds(of: dislike.padding(12), glyph: glyph)
        #expect(none.width == 0)
    }

    @Test("With a reach given the sparks stay inside it")
    func sparksStayInTheReach() throws {
        let glyph: CGFloat = 11
        let reach: CGFloat = 11
        let pop = MusicRateBurst.frame(at: 0.33, kind: .like, reduceMotion: false)
        let view = MusicRateBurstFrameView(kind: .like, frame: pop, glyphSize: glyph, restingOpacity: 1, sparkReach: reach)
        let bounds = try redInkBounds(of: view.padding(14), glyph: glyph)
        #expect(bounds.width > 0)
        #expect(bounds.width <= 2 * reach + 0.5)
        #expect(bounds.height <= 2 * reach + 0.5)
    }

    @Test("Reduce Motion draws the filled icon with no red anywhere, at every moment")
    func reducedFramesHaveNoRed() throws {
        let glyph: CGFloat = 12
        for seconds in [0, 0.05, 0.1, 0.2, 0.5] {
            let frame = MusicRateBurst.frame(at: seconds, kind: .like, reduceMotion: true)
            let view = MusicRateBurstFrameView(kind: .like, frame: frame, glyphSize: glyph, restingOpacity: 0.5, sparkReach: .infinity)
            let bounds = try redInkBounds(of: view.padding(12), glyph: glyph)
            #expect(bounds.width == 0)
        }
    }

    // MARK: - A removal

    @Test("A removal draws the timeline's removal frames: the outline thumb, never filled, tilted or sparked")
    func removalDrawsRemovalFrames() {
        for kind in [MusicRateBurst.Kind.like, .dislike] {
            let view = MusicRateBurstView(
                event: event(kind, surface: .pill, isRemoval: true),
                glyphSize: 11,
                restingOpacity: 1,
                sparkReach: 11
            )
            for seconds in [0, 0.03, 0.1, 0.2, 0.6] {
                let drawn = view.drawnFrame(at: seconds)
                #expect(drawn == MusicRateBurst.frame(at: seconds, kind: kind, reduceMotion: false, isRemoval: true))
                #expect(drawn.fill == 0)
                #expect(drawn.sparks == nil)
                #expect(drawn.rotation == 0)
            }
        }
    }

    @Test("A burst draws the burst frames, as before, in full from the first frame")
    func burstDrawsBurstFrames() {
        let view = MusicRateBurstView(event: event(.like, surface: .pill), glyphSize: 11, restingOpacity: 1, sparkReach: 11)
        for seconds in [0, 0.04, 0.133, 0.25, 0.6, 1.2] {
            #expect(view.drawnFrame(at: seconds) == MusicRateBurst.frame(at: seconds, kind: .like, reduceMotion: false))
            #expect(view.drawnFrame(at: seconds).opacity == 1)
        }
    }

    @Test("With Reduce Motion a removal draws the plain fade, with no scale")
    func removalReduceMotionFrames() {
        let view = MusicRateBurstView(
            event: event(.like, surface: .pill, reduceMotion: true, isRemoval: true),
            glyphSize: 11,
            restingOpacity: 1,
            sparkReach: 11
        )
        for seconds in [0, 0.05, 0.15, 0.5] {
            #expect(view.drawnFrame(at: seconds) == MusicRateBurst.frame(at: seconds, kind: .like, reduceMotion: true, isRemoval: true))
            #expect(view.drawnFrame(at: seconds).scale == 1)
        }
    }

    @Test("A removal onto a thumb that is already shown is drawn in full from the start, but still settles")
    func removalOverAShownThumbDoesNotFadeIn() {
        let view = MusicRateBurstView(
            event: event(.like, surface: .pill, isRemoval: true),
            glyphSize: 11,
            restingOpacity: 1,
            sparkReach: 11,
            fadesIn: false
        )
        let start = view.drawnFrame(at: 0)
        #expect(start.opacity == 1)
        #expect(start.scale == MusicRateBurst.Metrics.removalScaleFrom)
        #expect(start.fill == 0)
        #expect(view.drawnFrame(at: 5).scale == 1)

        let fading = MusicRateBurstView(
            event: event(.like, surface: .pill, isRemoval: true),
            glyphSize: 11,
            restingOpacity: 1,
            sparkReach: 11
        )
        #expect(fading.drawnFrame(at: 0).opacity == 0)
    }

    @Test("A pinned instant draws that instant of the removal, not the clock's")
    func pinnedRemovalInstant() throws {
        let settled = MusicRateBurstView(
            event: event(.like, surface: .pill, isRemoval: true),
            glyphSize: 11,
            restingOpacity: 1,
            sparkReach: 11,
            pinnedElapsed: 5
        )
        let early = MusicRateBurstView(
            event: event(.like, surface: .pill, isRemoval: true),
            glyphSize: 11,
            restingOpacity: 1,
            sparkReach: 11,
            pinnedElapsed: 0
        )
        #expect(try ink(of: settled.padding(8)) > 5)
        // At the start the outline thumb is not drawn yet.
        #expect(try ink(of: early.padding(8)) == 0)
    }

    @Test("A frame with no opacity draws nothing, and one at half draws the thumb at half strength")
    func frameOpacityDimsTheThumb() throws {
        var frame = MusicRateBurst.Frame(scale: 1, fill: 0, rotation: 0, sparks: nil)
        frame.opacity = 0
        let hidden = MusicRateBurstFrameView(kind: .like, frame: frame, glyphSize: 12, restingOpacity: 1, sparkReach: .infinity)
        #expect(try halves(of: hidden.padding(8)).leftPeak == 0)

        frame.opacity = 0.5
        let half = MusicRateBurstFrameView(kind: .like, frame: frame, glyphSize: 12, restingOpacity: 1, sparkReach: .infinity)
        let peak = try halves(of: half.padding(8)).leftPeak
        #expect(peak > 0.45)
        #expect(peak <= 0.52)
    }

    @Test("The removal's outline thumb carries less white than the filled one, for both kinds: it really is the outline")
    func removalIsTheOutline() throws {
        for kind in [MusicRateBurst.Kind.like, .dislike] {
            let outline = MusicRateBurstFrameView(
                kind: kind,
                frame: MusicRateBurst.frame(at: 5, kind: kind, reduceMotion: false, isRemoval: true),
                glyphSize: 11,
                restingOpacity: 1,
                sparkReach: 11
            )
            let filled = MusicRateBurstFrameView(
                kind: kind,
                frame: MusicRateBurst.frame(at: 5, kind: kind, reduceMotion: false),
                glyphSize: 11,
                restingOpacity: 1,
                sparkReach: 11
            )
            let outlineInk = try ink(of: outline.padding(8))
            let filledInk = try ink(of: filled.padding(8))
            #expect(outlineInk > 5)
            #expect(outlineInk < filledInk * 0.85)
        }
    }

    // MARK: - The ink offset

    @Test("An ink offset moves the thumb inside its box and nothing else: the box keeps its size")
    func inkOffsetMovesTheThumb() throws {
        let frame = MusicRateBurst.frame(at: 5, kind: .like, reduceMotion: false)
        let plain = MusicRateBurstFrameView(kind: .like, frame: frame, glyphSize: 11, restingOpacity: 1, sparkReach: 11)
        let moved = MusicRateBurstFrameView(
            kind: .like,
            frame: frame,
            glyphSize: 11,
            restingOpacity: 1,
            sparkReach: 11,
            inkOffset: CGSize(width: -2, height: -3)
        )
        let before = try inkMiddle(of: plain.padding(10))
        let after = try inkMiddle(of: moved.padding(10))
        #expect(abs((after.x - before.x) - -2) < 0.3)
        #expect(abs((after.y - before.y) - -3) < 0.3)
        #expect(NSHostingView(rootView: moved).fittingSize == NSHostingView(rootView: plain).fittingSize)
    }

    @Test("No ink offset is the default, and it leaves the thumb where it was")
    func noInkOffsetByDefault() throws {
        let frame = MusicRateBurst.frame(at: 5, kind: .dislike, reduceMotion: false)
        let plain = MusicRateBurstFrameView(kind: .dislike, frame: frame, glyphSize: 11, restingOpacity: 1, sparkReach: 11)
        let zero = MusicRateBurstFrameView(
            kind: .dislike,
            frame: frame,
            glyphSize: 11,
            restingOpacity: 1,
            sparkReach: 11,
            inkOffset: .zero
        )
        #expect(try inkMiddle(of: plain.padding(10)) == inkMiddle(of: zero.padding(10)))
    }

    @Test("The sparks stay put when the thumb is moved: the ring is centred on the box, not on the nudged ink")
    func sparksIgnoreTheInkOffset() throws {
        let pop = MusicRateBurst.frame(at: 0.25, kind: .like, reduceMotion: false)
        let plain = MusicRateBurstFrameView(kind: .like, frame: pop, glyphSize: 11, restingOpacity: 1, sparkReach: 11)
        let moved = MusicRateBurstFrameView(
            kind: .like,
            frame: pop,
            glyphSize: 11,
            restingOpacity: 1,
            sparkReach: 11,
            inkOffset: CGSize(width: -2, height: -3)
        )
        let before = try redInkBounds(of: plain.padding(14), glyph: 11)
        let after = try redInkBounds(of: moved.padding(14), glyph: 11)
        #expect(before == after)
        #expect(before.width > 0)
    }

    // MARK: - The pill's overlay

    @Test("The pill's overlay is empty with no event, and its host view takes no mouse events")
    func overlayHostTakesNoClicks() {
        let model = MusicChipBurstModel()
        let host = MusicChipBurstHost(model: model)
        host.frame = NSRect(x: 0, y: 0, width: 120, height: 24)
        #expect(host.hitTest(NSPoint(x: 10, y: 10)) == nil)
        #expect(host.hitTest(NSPoint(x: 60, y: 12)) == nil)
    }

    // MARK: - Helpers

    /// Where there is clearly red ink (the sparks are red or pink; the glyph is white), in points. Zero width if none.
    private func redInkBounds<V: View>(of view: V, glyph: CGFloat) throws -> CGRect {
        let renderer = ImageRenderer(content: view.background(Color.black))
        renderer.scale = 4
        let image = try #require(renderer.cgImage)
        let rep = NSBitmapImageRep(cgImage: image)
        var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                // Red ink: red well above green and blue. White and grey have all three alike.
                guard color.redComponent > 0.3, color.redComponent - color.greenComponent > 0.2 else { continue }
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= minX else { return .zero }
        return CGRect(x: Double(minX) / 4, y: Double(minY) / 4, width: Double(maxX - minX + 1) / 4, height: Double(maxY - minY + 1) / 4)
    }
}
