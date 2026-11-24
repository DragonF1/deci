// DeciTests/Music/MusicGlyphTests.swift
import AppKit
import SwiftUI
import Testing

@testable import Deci

@Suite("Music glyph")
@MainActor
struct MusicGlyphTests {
    @Test("Off and Crossfade have the icon we draw, everything else is an SF Symbol")
    func names() {
        #expect(MusicTransitionMode.off.symbol == MusicTransitionMode.crossfadeSymbol)
        #expect(MusicTransitionMode.crossfade.symbol == MusicTransitionMode.crossfadeSymbol)
        #expect(MusicGlyph.isCustom(MusicTransitionMode.crossfadeSymbol))
        #expect(NSImage(systemSymbolName: MusicTransitionMode.crossfadeSymbol, accessibilityDescription: nil) == nil)
        let others = [MusicTransitionMode.mixing.symbol, MusicLoopMode.off.systemImage, MusicLoopMode.song.systemImage, MusicShuffleMode.symbol, MusicShuffleMode.flowSymbol, "infinity"]
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

    private static let canvas = CGSize(width: 20, height: 16)
    private static let scale = 8

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
