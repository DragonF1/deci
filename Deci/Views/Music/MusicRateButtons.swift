// Deci/Views/Music/MusicRateButtons.swift
import SwiftUI

/// How one of the Now playing card's two icons looks for the song's state: the outline glyph in white 0.6, or the filled
/// one in full white when it is the song's current rating. Pure, so it is unit tested.
nonisolated struct MusicRateButtonLook: Equatable {
    enum Kind: Equatable {
        case dislike
        case like
    }

    let kind: Kind
    /// The song's rating; nil while it is not known.
    let status: MusicLikeStatus?

    var isActive: Bool {
        switch kind {
        case .like: status == .like
        case .dislike: status == .dislike
        }
    }

    var symbolName: String {
        let base = kind == .like ? "hand.thumbsup" : "hand.thumbsdown"
        return isActive ? base + ".fill" : base
    }

    var glyphOpacity: Double { isActive ? 1 : 0.6 }

    /// The help text and the accessibility label.
    var title: String { kind == .like ? "Like" : "Dislike" }

    var isSelected: Bool { isActive }
}

/// The Dislike and Like icons at the end of the Now playing card's title row. Borderless, so a click rates the song and
/// nothing else: the card stays and the popover does not open.
struct MusicRateButtons: View {
    let status: MusicLikeStatus?
    let onDislike: () -> Void
    let onLike: () -> Void

    private typealias Metrics = MusicHoverCardMetrics

    var body: some View {
        HStack(spacing: Metrics.rateButtonSpacing) {
            button(MusicRateButtonLook(kind: .dislike, status: status), action: onDislike)
            button(MusicRateButtonLook(kind: .like, status: status), action: onLike)
        }
    }

    private func button(_ look: MusicRateButtonLook, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: look.symbolName)
                .font(.system(size: Metrics.rateGlyphSize, weight: .medium))
                .foregroundStyle(Color.white.opacity(look.glyphOpacity))
                .frame(width: Metrics.rateButtonWidth, height: Metrics.rateButtonHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(look.title)
        .accessibilityLabel(look.title)
        .accessibilityAddTraits(look.isSelected ? .isSelected : [])
    }
}
