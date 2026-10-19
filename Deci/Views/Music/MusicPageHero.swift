// Deci/Views/Music/MusicPageHero.swift
import SwiftUI

/// The hero of a detail page, the first item of its scroll view: the cover (or the artist's photo, or Liked music's
/// heart) bleeding to the top of the popover and fading into the page colour, then the title block and the pills over
/// its bottom edge. An artist's hero has the name and the pills on one row instead.
struct MusicPageHero<Actions: View>: View {
    let kind: MusicPageKind
    let palette: MusicPagePalette
    /// The popover's width: the cover is as wide as it.
    let width: CGFloat
    let coverURL: URL?
    let text: MusicPageHeroText
    @ViewBuilder let actions: Actions

    var body: some View {
        ZStack(alignment: .top) {
            visual
            if kind == .artist {
                artistRow
            } else {
                titleBlock
            }
        }
        .frame(width: width, height: kind.heroHeight, alignment: .top)
    }

    // MARK: - Visual

    /// The cover's lower part, the fade into the page colour and the shade under the header, clipped to the hero's top.
    private var visual: some View {
        ZStack(alignment: .top) {
            cover
                .frame(width: width, height: width)
                .offset(y: kind.coverTop(width: width))

            LinearGradient(
                stops: kind.fadeStops.map { .init(color: palette.page.opacity($0.opacity), location: $0.location) },
                startPoint: .top,
                endPoint: .bottom
            )

            LinearGradient(
                colors: [Color.black.opacity(0.38), Color.black.opacity(0)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 96)
            .frame(maxHeight: .infinity, alignment: .top)

            if kind == .liked {
                Image(systemName: "heart.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 104)
                    .foregroundStyle(Color.white.opacity(0.96))
                    .shadow(color: MusicStyle.Palette.hex(0x59000F, opacity: 0.35), radius: 14, y: 10)
                    .padding(.top, kind.visualHeight - 234)
            }
        }
        .frame(width: width, height: kind.visualHeight, alignment: .top)
        .clipped()
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var cover: some View {
        if kind == .liked {
            Rectangle().fill(MusicStyle.Palette.likedGradient)
        } else {
            AsyncImage(url: coverURL) { phase in
                if case .success(let image) = phase {
                    image.resizable().scaledToFill()
                } else {
                    Color.clear
                }
            }
        }
    }

    // MARK: - Text

    /// Title, the accent line and the meta line, centred over the pills, which end at the hero's bottom edge.
    private var titleBlock: some View {
        VStack(spacing: 14) {
            VStack(spacing: 4) {
                Text(text.title)
                    .musicText(MusicStyle.Typeface.title2)
                    .foregroundStyle(MusicStyle.Palette.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                if let accent = text.accent {
                    Text(accent)
                        .musicText(MusicStyle.Typeface.subtitle15)
                        .foregroundStyle(palette.accentText)
                        .lineLimit(1)
                }
                if let meta = text.meta {
                    Text(meta)
                        .musicText(MusicStyle.Typeface.caption12M)
                        .foregroundStyle(MusicStyle.Palette.textSecondaryAlt)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 32)

            HStack(spacing: 12) {
                actions
            }
        }
        .frame(maxHeight: .infinity, alignment: .bottom)
    }

    /// The artist's name, one line that shrinks before it cuts, and the Play and Pin to Home pills at its trailing edge.
    private var artistRow: some View {
        HStack(spacing: 10) {
            Text(text.title)
                .musicText(MusicStyle.Typeface.display)
                .foregroundStyle(MusicStyle.Palette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
            actions
        }
        .frame(height: 48)
        .padding(.horizontal, 22)
        .padding(.bottom, 16)
        .frame(maxHeight: .infinity, alignment: .bottom)
    }
}
