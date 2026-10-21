// Deci/Views/Music/MusicRateButtons.swift
import SwiftUI

/// How one of the two icons looks for the song's state: the outline glyph in white 0.6 (or the brightness the surface
/// asks for), or the filled one in full white when it is the song's current rating. Pure, so it is unit tested.
nonisolated struct MusicRateButtonLook: Equatable {
    enum Kind: Equatable {
        case dislike
        case like
    }

    let kind: Kind
    /// The song's rating; nil while it is not known.
    let status: MusicLikeStatus?
    /// How bright the outline glyph is. The Now playing card keeps 0.6; the popup's strip rests at the transport's
    /// 0.50.
    var inactiveOpacity = 0.6

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

    var glyphOpacity: Double { isActive ? 1 : inactiveOpacity }

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

/// The Like and Dislike icons of the popup's player column, in the strip between the times row and the transport. Like
/// stands over the gap between Shuffle and Previous, Dislike over the gap between Next and Loop: each is centred where
/// the transport's rule (`MusicTransportMetrics`) puts the middle of that gap. The strip is always the column's width
/// and `MusicPopupMetrics.rateStripHeight` high, so the column does not move when there is nothing to rate: the icons
/// are then not drawn at all. Each icon's hit area reaches past its box, out of the layout.
struct MusicRateStrip: View {
    /// Whether the song can be rated: signed in, with a song playing.
    let isAvailable: Bool
    let status: MusicLikeStatus?
    let onDislike: () -> Void
    let onLike: () -> Void

    private typealias Metrics = MusicPopupMetrics

    var body: some View {
        let width = Metrics.playerColumnContentWidth
        let box = Metrics.rateGlyphSize
        let like = MusicTransportMetrics.likeCentreX(width: width) - box / 2
        let dislike = MusicTransportMetrics.dislikeCentreX(width: width) - box / 2
        let rest = MusicTransportMetrics.restingGlyphOpacity
        HStack(spacing: 0) {
            if isAvailable {
                Color.clear.frame(width: max(0, like), height: 1)
                button(MusicRateButtonLook(kind: .like, status: status, inactiveOpacity: rest), action: onLike)
                Color.clear.frame(width: max(0, dislike - like - box), height: 1)
                button(MusicRateButtonLook(kind: .dislike, status: status, inactiveOpacity: rest), action: onDislike)
            }
            Spacer(minLength: 0)
        }
        .frame(width: width, height: Metrics.rateStripHeight, alignment: .leading)
    }

    private func button(_ look: MusicRateButtonLook, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: look.symbolName)
                .font(.system(size: Metrics.rateGlyphSize, weight: .medium))
                .foregroundStyle(Color.white.opacity(look.glyphOpacity))
                .frame(width: Metrics.rateGlyphSize, height: Metrics.rateStripHeight)
                .padding(.horizontal, Metrics.rateReachX)
                .padding(.vertical, Metrics.rateReachY)
                .contentShape(Rectangle())
                .padding(.horizontal, -Metrics.rateReachX)
                .padding(.vertical, -Metrics.rateReachY)
        }
        .buttonStyle(.plain)
        .help(look.title)
        .accessibilityLabel(look.title)
        .accessibilityAddTraits(look.isSelected ? .isSelected : [])
    }
}
