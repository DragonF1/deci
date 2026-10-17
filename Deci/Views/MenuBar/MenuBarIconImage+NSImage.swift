// FineTune/Views/MenuBar/MenuBarIconImage+NSImage.swift
// AppKit bridge for MenuBarIconImage — kept separate so the value types
// file (MenuBarIconState.swift) stays AppKit-free and the Equatable
// conformances remain nonisolated under Swift 6 strict concurrency.

import AppKit

@MainActor
extension MenuBarIconImage {
    /// The status item is variable-length: icons of differing sizes resize it and shift every neighboring menu bar item.
    static let canvasSize = NSSize(width: 22, height: 18)

    func nsImage(accessibilityDescription: String = "Deci") -> NSImage? {
        let source: NSImage?
        switch self {
        case .asset(let name):
            source = NSImage(named: name) ?? Bundle.main.image(forResource: name)
        case .systemSymbol(let name):
            source = NSImage(systemSymbolName: name, accessibilityDescription: accessibilityDescription)
        }
        guard let source else { return nil }

        // The emblem asset is 18x18 and symbols vary, so everything is centered on one canvas.
        let canvas = Self.canvasSize
        let scale = min(1, canvas.width / source.size.width, canvas.height / source.size.height)
        let drawRect = NSRect(
            x: (canvas.width - source.size.width * scale) / 2,
            y: (canvas.height - source.size.height * scale) / 2,
            width: source.size.width * scale,
            height: source.size.height * scale
        )
        let image = NSImage(size: canvas, flipped: false) { _ in
            source.draw(in: drawRect)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = accessibilityDescription
        return image
    }
}
