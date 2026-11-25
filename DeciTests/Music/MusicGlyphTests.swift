// DeciTests/Music/MusicGlyphTests.swift
import AppKit
import SwiftUI
import Testing

@testable import Deci

@Suite("Music glyph")
@MainActor
struct MusicGlyphTests {
    @Test("Off, Crossfade and Flow Shuffle have icons of ours, everything else is an SF Symbol")
    func names() {
        #expect(MusicTransitionMode.off.symbol == MusicTransitionMode.crossfadeSymbol)
        #expect(MusicTransitionMode.crossfade.symbol == MusicTransitionMode.crossfadeSymbol)
        #expect(MusicGlyph.isCustom(MusicTransitionMode.crossfadeSymbol))
        #expect(NSImage(systemSymbolName: MusicTransitionMode.crossfadeSymbol, accessibilityDescription: nil) == nil)
        #expect(MusicGlyph.isCustom(MusicShuffleMode.flowSymbol))
        #expect(NSImage(systemSymbolName: MusicShuffleMode.flowSymbol, accessibilityDescription: nil) == nil)
        let others = [MusicTransitionMode.mixing.symbol, MusicLoopMode.off.systemImage, MusicLoopMode.song.systemImage, MusicShuffleMode.symbol, "infinity"]
        for symbol in others {
            #expect(!MusicGlyph.isCustom(symbol))
            #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil)
        }
    }

    @Test("the drawing fills the width it asks for and stays inside its frame", arguments: [CGFloat(10), 12, 13, 40])
    func staysInFrame(fontSize: CGFloat) {
        let size = MusicCrossfadeGlyph.size(fontSize: fontSize)
        let frame = CGRect(origin: .zero, size: size).insetBy(dx: -0.01, dy: -0.01)
        for weight in [Font.Weight.regular, .medium] {
            let outline = MusicCrossfadeGlyph.outline(fontSize: fontSize, weight: weight)
            #expect(frame.contains(outline.boundingRect))
            #expect(abs(outline.boundingRect.width - size.width) < fontSize * 0.02)
            #expect(abs(outline.boundingRect.height - size.height) < fontSize * 0.02)
        }
    }

    @Test("its height is between those of the infinity and the shuffle glyph it sits beside")
    func heightSitsBetweenNeighbours() throws {
        for (fontSize, weight) in [(CGFloat(10), Font.Weight.medium), (12, .medium), (13, .regular)] {
            let crossfade = try inkHeight(MusicTransitionMode.crossfadeSymbol, fontSize, weight)
            #expect(try crossfade > inkHeight("infinity", fontSize, weight))
            #expect(try crossfade < inkHeight(MusicShuffleMode.symbol, fontSize, weight))
        }
    }

    @Test("in the transport it spills no further past its slot than half the gap")
    func fitsTheSlot() {
        let size = MusicCrossfadeGlyph.size(fontSize: 12)
        for side in [MusicTransportMetrics.box(.shuffle), MusicTransportMetrics.box(.loop)] {
            #expect((size.width - side) / 2 <= MusicTransportMetrics.gap() / 2)
        }
        #expect(size.height <= MusicTransportMetrics.height)
    }

    @Test("a resting icon keeps the tone of its style: nothing doubles up where the clips meet")
    func evenTone() throws {
        let pixels = try alphas(MusicGlyph(name: MusicTransitionMode.crossfadeSymbol, fontSize: 12, weight: .medium).foregroundStyle(Color.white.opacity(0.5)))
        let peak = try #require(pixels.max())
        #expect(peak > 0.45 && peak < 0.53)
        #expect(pixels.contains { $0 < 0.01 })
    }

    @Test("the sparkle leaves the shuffle arrows where they are", arguments: [CGFloat(10), 12, 13])
    func flowKeepsTheArrows(fontSize: CGFloat) throws {
        let weight = fontSize == 13 ? Font.Weight.regular : .medium
        let plain = try ink(MusicShuffleMode.symbol, fontSize, weight)
        let flow = try ink(MusicShuffleMode.flowSymbol, fontSize, weight)
        #expect(abs(flow.minX - plain.minX) < 0.2)
        #expect(abs(flow.maxY - plain.maxY) < 0.2)
        #expect(flow.maxX > plain.maxX + 2)
        #expect(flow.minY < plain.minY - 2)
    }

    @Test("the sparkle stays inside half the transport's gap, the header's button and the player column's padding")
    func flowFitsItsPlaces() throws {
        let transport = try ink(MusicShuffleMode.flowSymbol, 12, .medium)
        #expect(transport.maxX - MusicTransportMetrics.box(.shuffle) / 2 <= MusicTransportMetrics.gap() / 2)
        #expect(-transport.minY <= MusicTransportMetrics.height / 2)
        let shift = MusicFlowShuffleGlyph.centering(fontSize: 13)
        let header = try ink(MusicShuffleMode.flowSymbol, 13, .regular).offsetBy(dx: shift.width, dy: shift.height)
        #expect(abs(header.midX) < 0.3 && abs(header.midY) < 0.3)
        #expect(CGRect(x: -13, y: -11, width: 26, height: 22).insetBy(dx: 2.5, dy: 2.5).contains(header))
        let plain = try ink(MusicShuffleMode.symbol, MusicKickerToggleMetrics.glyphSize, .medium)
        let kicker = try ink(MusicShuffleMode.flowSymbol, MusicKickerToggleMetrics.glyphSize, .medium)
        #expect(kicker.maxX - plain.maxX < MusicKickerToggleMetrics.gap - 2)
        #expect(-kicker.minY - MusicKickerToggleMetrics.lineHeight / 2 < MusicPopupMetrics.playerColumnPadding)
    }

    @Test("a translucent Flow Shuffle icon keeps one tone: the sparkle does not lie on the arrows")
    func flowEvenTone() throws {
        let pixels = try alphas(MusicGlyph(name: MusicShuffleMode.flowSymbol, fontSize: 12, weight: .medium).foregroundStyle(Color.white.opacity(0.5)))
        let peak = try #require(pixels.max())
        #expect(peak > 0.45 && peak < 0.53)
    }

    private static let canvas = CGSize(width: 28, height: 24)
    private static let scale = 8

    /// What the glyph draws, in points from the middle of its frame.
    private func ink(_ name: String, _ fontSize: CGFloat, _ weight: Font.Weight) throws -> CGRect {
        let pixels = try alphas(MusicGlyph(name: name, fontSize: fontSize, weight: weight).foregroundStyle(Color.white))
        let width = Int(Self.canvas.width) * Self.scale
        let inked = pixels.indices.filter { pixels[$0] > 0.3 }
        let xs = inked.map { $0 % width }, ys = inked.map { $0 / width }
        let x0 = try #require(xs.min()), x1 = try #require(xs.max()), y0 = try #require(ys.min()), y1 = try #require(ys.max())
        func points(_ pixel: Int, _ side: CGFloat) -> CGFloat { CGFloat(pixel) / CGFloat(Self.scale) - side / 2 }
        let left = points(x0, Self.canvas.width), top = points(y0, Self.canvas.height)
        return CGRect(
            x: left, y: top, width: points(x1 + 1, Self.canvas.width) - left, height: points(y1 + 1, Self.canvas.height) - top
        )
    }

    /// The height of what the glyph draws, in points.
    private func inkHeight(_ name: String, _ fontSize: CGFloat, _ weight: Font.Weight) throws -> CGFloat {
        let pixels = try alphas(MusicGlyph(name: name, fontSize: fontSize, weight: weight).foregroundStyle(Color.white))
        let width = Int(Self.canvas.width) * Self.scale
        let rows = pixels.indices.filter { pixels[$0] > 0.3 }.map { $0 / width }
        let first = try #require(rows.first)
        let last = try #require(rows.last)
        return CGFloat(last - first + 1) / CGFloat(Self.scale)
    }

    private func alphas(_ view: some View) throws -> [CGFloat] {
        let renderer = ImageRenderer(content: view.frame(width: Self.canvas.width, height: Self.canvas.height))
        renderer.scale = CGFloat(Self.scale)
        let bitmap = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
        return (0..<bitmap.pixelsHigh).flatMap { y in
            (0..<bitmap.pixelsWide).map { x in bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0 }
        }
    }
}
