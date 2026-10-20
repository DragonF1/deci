// Deci/Views/Music/MusicSearchField.swift
import SwiftUI

/// The search field the magnifier opens in the right column's header: 26 pt tall on a faint white fill with the song's
/// accent as its outline, a magnifier, the words, and at the end a clear button (or a spinner while YouTube Music
/// answers) and an "esc" keycap. It takes the keyboard when it appears. It knows nothing of what it searches: the
/// placeholder says, and the screen under it reads the words from the navigation.
struct MusicSearchField: View {
    let placeholder: String
    @Binding var text: String
    var isLoading = false
    /// Return. Nil for a field that filters as you type.
    var onSubmit: (() -> Void)?
    let onClear: () -> Void

    @FocusState private var isFocused: Bool
    @Environment(\.musicAccent) private var accent

    static let height: CGFloat = 26
    static let radius: CGFloat = 7

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(Color.white.opacity(0.55))
                .accessibilityHidden(true)
            TextField(
                "",
                text: $text,
                prompt: Text(placeholder).foregroundStyle(Color.white.opacity(0.35))
            )
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(Color.white.opacity(MusicStyle.Opacity.heading))
            .tint(accent.solid)
            .focused($isFocused)
            .onSubmit { onSubmit?() }
            .accessibilityLabel(placeholder)

            if isLoading {
                MusicSpinner(size: 11, lineWidth: 1.5, color: Color.white.opacity(0.60))
            } else if !text.isEmpty {
                MusicSearchClearButton(action: onClear)
            }
            MusicEscKeycap()
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .frame(height: Self.height)
        .background(RoundedRectangle(cornerRadius: Self.radius, style: .continuous).fill(Color.white.opacity(0.07)))
        .overlay(
            RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                .strokeBorder(accent.solid.opacity(0.55), lineWidth: 1)
        )
        // Typing starts the moment the field opens.
        .task { isFocused = true }
    }
}

/// The 14 pt round clear button: a faint circle with a small cross.
private struct MusicSearchClearButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.85))
                .frame(width: 14, height: 14)
                .background(Circle().fill(Color.white.opacity(0.18)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Clear search")
        .help("Clear search")
    }
}

/// The small "esc" keycap at the end of the field: what closes it.
private struct MusicEscKeycap: View {
    var body: some View {
        Text("esc")
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(Color.white.opacity(0.45))
            .padding(.vertical, 1)
            .padding(.horizontal, 4)
            .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
            .accessibilityHidden(true)
    }
}
