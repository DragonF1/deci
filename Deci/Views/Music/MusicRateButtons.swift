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

/// How the two icons are laid out: the glyph, the hit area of each, the room between them and which way they stand. The
/// hit area can also reach past `buttonWidth` on both sides, which takes no layout room.
nonisolated struct MusicRateButtonMetrics: Equatable {
    let glyphSize: Double
    let buttonWidth: Double
    let buttonHeight: Double
    let spacing: Double
    let axis: Axis
    let horizontalReach: Double

    init(
        glyphSize: Double, buttonWidth: Double, buttonHeight: Double, spacing: Double,
        axis: Axis = .horizontal, horizontalReach: Double = 0
    ) {
        self.glyphSize = glyphSize
        self.buttonWidth = buttonWidth
        self.buttonHeight = buttonHeight
        self.spacing = spacing
        self.axis = axis
        self.horizontalReach = horizontalReach
    }

    /// The end of the Now playing card's title row: a hit area as high as the row.
    static let hoverCard = MusicRateButtonMetrics(
        glyphSize: MusicHoverCardMetrics.rateGlyphSize,
        buttonWidth: MusicHoverCardMetrics.rateButtonWidth,
        buttonHeight: MusicHoverCardMetrics.rateButtonHeight,
        spacing: MusicHoverCardMetrics.rateButtonSpacing
    )

    /// Beside the popup's spectrum: one over the other, with the hit area reaching sideways.
    static let popup = MusicRateButtonMetrics(
        glyphSize: MusicPopupMetrics.rateGlyphSize,
        buttonWidth: MusicPopupMetrics.rateButtonWidth,
        buttonHeight: MusicPopupMetrics.rateButtonHeight,
        spacing: MusicPopupMetrics.rateButtonSpacing,
        axis: .vertical,
        horizontalReach: MusicPopupMetrics.rateButtonReach
    )
}

/// The Dislike and Like icons at the end of the Now playing card's title row, and beside the popup's spectrum. Borderless,
/// so a click rates the song and nothing else: the card stays and the popover does not open.
struct MusicRateButtons: View {
    let status: MusicLikeStatus?
    var metrics: MusicRateButtonMetrics = .hoverCard
    let onDislike: () -> Void
    let onLike: () -> Void

    var body: some View {
        let layout = metrics.axis == .vertical
            ? AnyLayout(VStackLayout(spacing: metrics.spacing))
            : AnyLayout(HStackLayout(spacing: metrics.spacing))
        layout {
            button(MusicRateButtonLook(kind: .dislike, status: status), action: onDislike)
            button(MusicRateButtonLook(kind: .like, status: status), action: onLike)
        }
    }

    private func button(_ look: MusicRateButtonLook, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: look.symbolName)
                .font(.system(size: metrics.glyphSize, weight: .medium))
                .foregroundStyle(Color.white.opacity(look.glyphOpacity))
                .frame(width: metrics.buttonWidth, height: metrics.buttonHeight)
                .padding(.horizontal, metrics.horizontalReach)
                .contentShape(Rectangle())
                .padding(.horizontal, -metrics.horizontalReach)
        }
        .buttonStyle(.plain)
        .help(look.title)
        .accessibilityLabel(look.title)
        .accessibilityAddTraits(look.isSelected ? .isSelected : [])
    }
}
