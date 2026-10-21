// DeciTests/Music/MusicChipBurstRender.swift
// Test support: the menu bar pill and the like overlay laid over it, drawn offscreen the way the status item draws them
// (the layer-hosting chip view, and the hosting view of MusicChipBurstOverlay over it), and the ink in the result measured
// to a fraction of a point. Nothing is put on screen: the views sit in a window that is never ordered in, which only
// gives them the backing scale of the display they stand in for.

import AppKit
import SwiftUI
@testable import Deci

/// A window that is never shown, and reports the backing scale of the display it stands in for. A view with no window
/// draws at 1x, where SwiftUI snaps what it places to whole points; a status item on a Retina screen snaps to half a
/// point. The scale is what the snapping depends on, so the render needs the display's.
final class RenderWindow: NSWindow {
    var factor: CGFloat = 1
    override var backingScaleFactor: CGFloat { factor }
}

@MainActor
struct MusicChipBurstRender {
    /// A box found in a render, in points from the top left, to a fraction of a pixel.
    struct Box: Equatable {
        var top = 0.0, bottom = 0.0, left = 0.0, right = 0.0
        var centerX: Double { (left + right) / 2 }
        var centerY: Double { (top + bottom) / 2 }
    }

    let scale: Int
    let height: Double
    let geometry: MusicChipGeometry
    let container: NSView
    let chip: MusicChipView
    /// The window that stands in for the display; it holds the container and is never shown.
    let window: RenderWindow

    /// A playing pill for `title`, with a white cover, in a container `height` points high and as wide as the pill. The
    /// pill is 18 pt high and centred in it, as it is in the status item. The container stands in a display of `scale`.
    init(scale: Int, height: Double = MusicChipLayout.statusItemHeight, title: String = "Night Drive") {
        self.scale = scale
        self.height = height
        let spec = MusicChipSpec(
            title: title,
            isPlaying: true,
            tint: MusicTint(hue: 0.55, saturation: 0.9, brightness: 0.5),
            hasThumbnail: true,
            coverURL: nil,
            reduceMotion: false
        )
        geometry = MusicChipLayout.geometry(title: title, measure: MusicChipRenderer.titleWidth)
        container = NSView(frame: NSRect(x: 0, y: 0, width: geometry.pillWidth, height: height))
        chip = MusicChipView(frame: container.bounds, scale: CGFloat(scale))
        chip.autoresizingMask = [.width, .height]
        container.addSubview(chip)
        window = RenderWindow(contentRect: container.bounds, styleMask: [.borderless], backing: .buffered, defer: true)
        window.factor = CGFloat(scale)
        window.isReleasedWhenClosed = false
        window.contentView = container
        chip.show(spec: spec, geometry: geometry, thumbnail: Self.whiteCover(), change: .content, widthDuration: 0)
    }

    var size: CGSize { container.bounds.size }

    /// The columns of the cover's slot: from the pill's left edge to just before the title.
    var slotColumns: Range<Int> { 0..<Int((MusicChipLayout.titleOriginX - 1) * Double(scale)) }

    /// Where the thumb stands, as the overlay is given it.
    var slotOffset: Double {
        MusicChipLayout.burstSlotOffset(pillWidth: geometry.pillWidth, isPlaying: true)
    }

    // MARK: - Drawing

    /// A bitmap `size` points across, `scale` pixels to the point, for `cacheDisplay` to draw into.
    func makeRep() -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width) * scale,
            pixelsHigh: Int(size.height) * scale,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        rep.size = size
        return rep
    }

    /// The pill with its cover, and no thumb.
    func drawCover() -> NSBitmapImageRep {
        chip.setBurstShown(false, duration: 0)
        let rep = makeRep()
        container.cacheDisplay(in: container.bounds, to: rep)
        return rep
    }

    /// The pill with its cover away and the overlay's thumb for `event`, `elapsed` seconds into it. `fadesIn` as the
    /// burster would set it.
    func drawThumb(of event: MusicRateBurstCenter.Event, elapsed: TimeInterval, fadesIn: Bool = false) -> NSBitmapImageRep {
        chip.setBurstShown(true, duration: 0)
        let model = MusicChipBurstModel()
        model.event = event
        model.isShown = true
        model.fadesIn = fadesIn
        model.pinnedElapsed = elapsed
        model.slotOffset = slotOffset
        let host = MusicChipBurstHost(model: model)
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        host.layoutSubtreeIfNeeded()
        let rep = makeRep()
        container.cacheDisplay(in: container.bounds, to: rep)
        host.removeFromSuperview()
        chip.setBurstShown(false, duration: 0)
        return rep
    }

    /// An event for the pill, as the center would make it.
    static func event(_ kind: MusicRateBurst.Kind, isRemoval: Bool) -> MusicRateBurstCenter.Event {
        MusicRateBurstCenter.Event(
            id: 1,
            kind: kind,
            surface: .pill,
            reduceMotion: false,
            startedAt: Date(timeIntervalSince1970: 1_000),
            isRemoval: isRemoval
        )
    }

    // MARK: - Measuring

    /// The pill: every pixel that is drawn at all.
    func pillBox(in rep: NSBitmapImageRep) -> Box? {
        Self.box(in: rep, scale: scale, columns: 0..<rep.pixelsWide) { $0.alphaComponent > 0.5 ? 1 : 0 }
    }

    /// How light the pill's fill is, read from its trailing inset, so white ink can be told from it.
    func fillLevel(of rep: NSBitmapImageRep) -> Double {
        let color = rep.colorAt(x: rep.pixelsWide - 2 * scale, y: rep.pixelsHigh / 2)!
        return Double(min(color.redComponent, color.greenComponent, color.blueComponent))
    }

    /// The white in the cover's slot: how much of the way from the pill's fill to full white each pixel is.
    func whiteBox(in rep: NSBitmapImageRep, fill: Double) -> Box? {
        Self.box(in: rep, scale: scale, columns: slotColumns) { color in
            guard color.alphaComponent > 0.5 else { return 0 }
            let level = Double(min(color.redComponent, color.greenComponent, color.blueComponent))
            return max(0, min(1, (level - fill) / (1 - fill)))
        }
    }

    /// The box of the ink in `columns`, with the edges placed within a pixel by how much of the edge pixel is covered.
    static func box(in rep: NSBitmapImageRep, scale: Int, columns: Range<Int>, coverage: (NSColor) -> Double) -> Box? {
        var rowMax = [Double](repeating: 0, count: rep.pixelsHigh)
        var columnMax = [Double](repeating: 0, count: rep.pixelsWide)
        for y in 0..<rep.pixelsHigh {
            for x in columns {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                let value = coverage(color)
                rowMax[y] = max(rowMax[y], value)
                columnMax[x] = max(columnMax[x], value)
            }
        }
        func edges(_ maxima: [Double], _ range: Range<Int>) -> (Double, Double)? {
            guard let first = range.first(where: { maxima[$0] > 0.03 }),
                  let last = range.last(where: { maxima[$0] > 0.03 }) else { return nil }
            return ((Double(first) + 1 - maxima[first]) / Double(scale), (Double(last) + maxima[last]) / Double(scale))
        }
        guard let vertical = edges(rowMax, 0..<rep.pixelsHigh), let horizontal = edges(columnMax, columns) else { return nil }
        return Box(top: vertical.0, bottom: vertical.1, left: horizontal.0, right: horizontal.1)
    }

    /// A white square for a cover: the cover then shows as a clean white disc.
    static func whiteCover() -> CGImage? {
        let context = CGContext(
            data: nil,
            width: 24,
            height: 24,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
        return context.makeImage()
    }
}
