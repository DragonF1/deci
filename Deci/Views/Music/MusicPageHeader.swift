// Deci/Views/Music/MusicPageHeader.swift
import SwiftUI

/// The header of a detail page: a 72 pt cover (the artist's round photo, or Liked music's heart) with its text centred
/// beside it, a small uppercase kicker, the title, the line under it and a quiet meta line. The action row and the list
/// bar are laid under it by the page.
struct MusicPageHeader: View {
    let kind: MusicPageKind
    let coverURL: URL?
    let text: MusicPageHeroText

    var body: some View {
        HStack(alignment: .center, spacing: MusicBrowseLayout.pageArtGap) {
            art
            VStack(alignment: .leading, spacing: MusicBrowseLayout.pageInfoGap) {
                Text(text.kicker)
                    .musicText(MusicStyle.Typeface.kicker)
                    .foregroundStyle(MusicStyle.Palette.textMeta)
                    .lineLimit(1)
                Text(text.title)
                    .musicText(MusicStyle.Typeface.pageTitle)
                    .foregroundStyle(MusicStyle.Palette.textTitle)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if let sub = text.sub {
                    Text(sub)
                        .musicText(MusicStyle.Typeface.pageSub)
                        .foregroundStyle(MusicStyle.Palette.textPageSub)
                        .lineLimit(1)
                }
                if let meta = text.meta {
                    Text(meta)
                        .musicText(MusicStyle.Typeface.secondary)
                        .foregroundStyle(MusicStyle.Palette.textMeta)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, MusicStyle.Spacing.page)
    }

    // MARK: - Art

    @ViewBuilder
    private var art: some View {
        let size = MusicBrowseLayout.pageArt
        if kind == .liked {
            MusicLikedArt(size: size, cornerRadius: MusicBrowseLayout.pageArtRadius)
        } else {
            MusicThumbnail(
                url: coverURL,
                size: size,
                circular: kind.isRound,
                placeholder: kind == .artist ? MusicCollection.Kind.artist.placeholderSymbol : "music.note",
                cornerRadius: MusicBrowseLayout.pageArtRadius
            )
            .accessibilityHidden(true)
        }
    }
}
