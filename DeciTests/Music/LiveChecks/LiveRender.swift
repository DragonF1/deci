// DeciTests/Music/LiveChecks/LiveRender.swift
// Offscreen PNGs of the real views. The hosting view lives in a window that is never ordered in, so nothing flashes and
// nothing takes focus. Vision reads the text back, so a check can say what the picture shows.

import AppKit
import SwiftUI
import Vision
@testable import Deci

@MainActor
enum LiveRender {
    struct Shot {
        var url: URL
        var text: [String]
        var inkFraction: Double
    }

    static func shot<V: View>(_ view: V, width: CGFloat, height: CGFloat, name: String) -> Shot? {
        LiveDirs.make()
        let content = view
            .frame(width: width, height: height, alignment: .topLeading)
            .background(MusicStyle.Palette.popupBackground)
            .environment(\.colorScheme, .dark)
        let hosting = NSHostingView(rootView: content)
        let rect = NSRect(x: 0, y: 0, width: width, height: height)
        hosting.frame = rect
        let window = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        hosting.layoutSubtreeIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        hosting.cacheDisplay(in: rect, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let url = LiveDirs.root.appendingPathComponent(name)
        do { try png.write(to: url) } catch { return nil }
        return Shot(url: url, text: recognise(rep), inkFraction: ink(rep))
    }

    /// ImageRenderer route for views that are not lazy (the header).
    static func rendered<V: View>(_ view: V, width: CGFloat, height: CGFloat, name: String) -> Shot? {
        LiveDirs.make()
        let content = view
            .frame(width: width, height: height, alignment: .topLeading)
            .background(MusicStyle.Palette.popupBackground)
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let url = LiveDirs.root.appendingPathComponent(name)
        do { try png.write(to: url) } catch { return nil }
        return Shot(url: url, text: recognise(rep), inkFraction: ink(rep))
    }

    private static func recognise(_ rep: NSBitmapImageRep) -> [String] {
        guard let cg = rep.cgImage else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        do { try handler.perform([request]) } catch { return [] }
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    }

    /// Share of pixels that differ from the corner colour: 0 means the picture is blank.
    private static func ink(_ rep: NSBitmapImageRep) -> Double {
        guard let base = rep.colorAt(x: 1, y: 1) else { return 0 }
        var different = 0, total = 0
        let step = 3
        for y in stride(from: 0, to: rep.pixelsHigh, by: step) {
            for x in stride(from: 0, to: rep.pixelsWide, by: step) {
                total += 1
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                if abs(c.redComponent - base.redComponent) + abs(c.greenComponent - base.greenComponent)
                    + abs(c.blueComponent - base.blueComponent) > 0.06 { different += 1 }
            }
        }
        return total == 0 ? 0 : Double(different) / Double(total)
    }
}
