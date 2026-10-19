// Deci/Views/Music/MusicPageHeader.swift
import SwiftUI

/// The header of a detail page, the first item of its scroll view: the cover (the artist's round photo, or Liked
/// music's heart) on the left, and on its right the title, the lines under it and the small action buttons. The cover's
/// colour is the wash behind it, drawn by the page.
struct MusicPageHeader<Actions: View>: View {
    let kind: MusicPageKind
    let coverURL: URL?
    let text: MusicPageHeroText
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(alignment: .bottom, spacing: DesignTokens.Spacing.md) {
            art
            VStack(alignment: .leading, spacing: 2) {
                Text(text.title)
                    .musicText(MusicStyle.Typeface.title)
                    .foregroundStyle(MusicStyle.Palette.textPrimary)
                    .lineLimit(2)
                    .accessibilityAddTraits(.isHeader)
                if let accent = text.accent {
                    Text(accent)
                        .musicText(MusicStyle.Typeface.rowMedium)
                        .foregroundStyle(MusicStyle.Palette.textSecondary)
                        .lineLimit(1)
                }
                if let meta = text.meta {
                    Text(meta)
                        .musicText(MusicStyle.Typeface.secondary)
                        .foregroundStyle(MusicStyle.Palette.textTertiary)
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    actions
                }
                .padding(.top, DesignTokens.Spacing.sm)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, MusicStyle.Spacing.page)
        .padding(.top, 4)
        .padding(.bottom, 12)
        .frame(height: kind.heroHeight, alignment: .bottom)
    }

    // MARK: - Art

    private var art: some View {
        let size = kind.artSize
        return Group {
            if kind == .liked {
                MusicStyle.Palette.likedGradient
                    .overlay {
                        Image(systemName: "heart.fill")
                            .font(.system(size: size * 0.36))
                            .foregroundStyle(Color.white.opacity(0.96))
                    }
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: MusicStyle.Radius.card, style: .continuous))
            } else {
                MusicThumbnail(
                    url: coverURL,
                    size: size,
                    circular: kind.isRound,
                    placeholder: kind == .artist ? MusicCollection.Kind.artist.placeholderSymbol : "music.note",
                    cornerRadius: MusicStyle.Radius.card
                )
            }
        }
        .shadow(color: MusicStyle.Shadow.headerArt.color, radius: MusicStyle.Shadow.headerArt.radius, y: MusicStyle.Shadow.headerArt.y)
        .accessibilityHidden(true)
    }
}
