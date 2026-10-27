// FineTune/Views/Components/BoostChevrons.swift
import SwiftUI

/// Stacked chevron boost indicator — 3 SF Symbol chevrons that light up based on boost level.
/// Click to cycle: 1x → 2x → 3x → 4x → 1x. Right-click steps down.
struct BoostChevrons: View {
    let level: BoostLevel
    let onTap: () -> Void
    var onSecondaryTap: () -> Void = {}

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    /// Number of lit chevrons for each boost level
    private var litCount: Int {
        switch level {
        case .x1: 0
        case .x2: 1
        case .x3: 2
        case .x4: 3
        }
    }

    /// Color for each chevron position (bottom=0, top=2)
    private func chevronColor(at index: Int) -> Color {
        if index < litCount {
            return DesignTokens.Colors.accentPrimary
        } else {
            return isHovered
                ? .primary.opacity(0.25)
                : .primary.opacity(0.15)
        }
    }

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: -2) {
                ForEach((0..<3).reversed(), id: \.self) { index in
                    Image(systemName: "chevron.compact.up")
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(chevronColor(at: index))
                }
            }
            .frame(
                minWidth: DesignTokens.Dimensions.minTouchTarget,
                minHeight: DesignTokens.Dimensions.minTouchTarget
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(RightClickCatcher { if isEnabled { onSecondaryTap() } })
        .onHover { isHovered = $0 }
        .help("Volume boost: \(level.label)")
        .accessibilityLabel("Volume boost \(level.label)")
        .animation(.snappy(duration: 0.2), value: level)
        .animation(DesignTokens.Animation.hover, value: isHovered)
    }
}

// MARK: - Right click

/// Takes right clicks and Control-clicks only. Every other event (left clicks, hover) hits the views below.
private struct RightClickCatcher: NSViewRepresentable {
    let onRightClick: () -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onRightClick = onRightClick
        return view
    }

    func updateNSView(_ nsView: CatcherView, context: Context) {
        nsView.onRightClick = onRightClick
    }

    final class CatcherView: NSView {
        var onRightClick: (() -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent else { return nil }
            switch event.type {
            case .rightMouseDown, .rightMouseUp:
                return super.hitTest(point)
            case .leftMouseDown, .leftMouseUp:
                return event.modifierFlags.contains(.control) ? super.hitTest(point) : nil
            default:
                return nil
            }
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func rightMouseDown(with event: NSEvent) {
            onRightClick?()
        }

        override func mouseDown(with event: NSEvent) {
            onRightClick?()
        }
    }
}

// MARK: - Previews

#Preview("Boost Chevrons") {
    ComponentPreviewContainer {
        HStack(spacing: DesignTokens.Spacing.lg) {
            VStack {
                BoostChevrons(level: .x1, onTap: {})
                Text("1x").font(.caption)
            }
            VStack {
                BoostChevrons(level: .x2, onTap: {})
                Text("2x").font(.caption)
            }
            VStack {
                BoostChevrons(level: .x3, onTap: {})
                Text("3x").font(.caption)
            }
            VStack {
                BoostChevrons(level: .x4, onTap: {})
                Text("4x").font(.caption)
            }
        }
    }
}
