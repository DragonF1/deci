// Deci/Views/Settings/Components/VolumeKeyRecorderField.swift
import SwiftUI

/// The button at the front of a volume keybind row: it shows the row's modifiers and keys (`⇧⌘ F11 / F12`)
/// and is styled like the neighbouring `KeyboardShortcuts.Recorder` fields, a bordered capsule of the
/// same size. A click starts recording and the field asks for the key press in the accent tint; a click
/// while recording cancels. Disabled, it says how to enable it.
struct VolumeKeyRecorderField: View {
    let combo: VolumeKeyCombo
    let isRecording: Bool
    let isEnabled: Bool
    let action: () -> Void

    /// The size `KeyboardShortcuts.Recorder` lays out at.
    private static let width: CGFloat = 130
    private static let height: CGFloat = 24

    var body: some View {
        Button(action: action) {
            Text(isRecording ? "Press F11 / F12" : combo.label)
                .font(.system(size: 13))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(isRecording ? Color.accentColor : DesignTokens.Colors.textPrimary)
                .padding(.horizontal, 6)
                .frame(width: Self.width, height: Self.height)
                .background(Capsule().fill(isRecording ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.03)))
                .overlay(
                    Capsule().strokeBorder(
                        isRecording ? Color.accentColor : Color.primary.opacity(0.12),
                        lineWidth: isRecording ? 1.5 : 1
                    )
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .controlSize(.small)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.5)
        .help(isEnabled ? "Hold the modifiers, then press F11 or F12" : "Turn on Media Keys to record")
        .accessibilityLabel("Volume keybind modifiers")
        .accessibilityValue(isRecording ? "Recording" : combo.label)
    }
}
