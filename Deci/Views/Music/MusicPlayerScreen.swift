// Deci/Views/Music/MusicPlayerScreen.swift
import SwiftUI

/// Now Playing, Lyrics and Up next. They fill the popover over the browse screen and share one backdrop (the blurred
/// cover over its tint); each page lays out its own controls. Leaving them is the chevron in the popup's header, or Esc.
struct MusicPlayerScreen: View {
    let service: MusicService
    let navigation: MusicSearchNavigation
    let screen: MusicShellScreen
    /// The Mixer's state, for the volume slider and the output control. Nil where there is no Mixer (tests, previews).
    var mixer: MusicMixerState?

    /// The colour of the cover once it is known; until then the player wears the hash palette's tint of the song's id.
    @State private var coverTint: MusicTint?
    @Environment(\.musicContentTop) private var contentTop

    init(service: MusicService, navigation: MusicSearchNavigation, screen: MusicShellScreen, mixer: MusicMixerState? = nil) {
        self.service = service
        self.navigation = navigation
        self.screen = screen
        self.mixer = mixer
        _coverTint = State(initialValue: MusicCoverTintStore.shared.cachedTint(for: service.player.nowPlaying?.thumbnailURL))
    }

    var body: some View {
        if let track = service.player.nowPlaying {
            let tint = coverTint ?? MusicTint.forKey(track.videoId)
            page(track: track, tint: tint)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    // The backdrop covers the popover's header row too, which the shell's padding leaves above us.
                    MusicPlayerBackdrop(coverURL: track.thumbnailURL, tint: tint, screen: screen)
                        .padding(.top, -contentTop)
                }
                // The backdrop is dark whatever the popover wears, so the controls on it read as on dark, and any glass
                // or blur on it is the pinned dark one.
                .musicDarkScope()
                .animation(DesignTokens.Animation.quick, value: screen)
                // The cover's colour: from the cache at once, else after the cover is fetched. Failing leaves the
                // hash palette's tint. The previous song's colour stays until the new one is known.
                .task(id: track.thumbnailURL) { await loadTint(for: track.thumbnailURL) }
        } else {
            Color.clear
        }
    }

    private func loadTint(for url: URL?) async {
        guard let url else {
            coverTint = nil
            return
        }
        if let cached = MusicCoverTintStore.shared.cachedTint(for: url) {
            coverTint = cached
            return
        }
        let tint = await MusicCoverTintStore.shared.tint(for: url)
        guard !Task.isCancelled else { return }
        withAnimation(.easeInOut(duration: 0.35)) { coverTint = tint }
    }

    @ViewBuilder
    private func page(track: MusicTrack, tint: MusicTint) -> some View {
        switch screen {
        case .lyrics:
            VStack(spacing: 0) {
                MusicPlayerHeader(track: track)
                MusicLyricsView(store: service.lyrics) { service.seek(to: $0) }
                    .frame(maxHeight: .infinity)
                    .padding(.top, 4)
                MusicPlayerFooter(service: service, navigation: navigation)
                    .padding(.horizontal, MusicLyricsView.margin)
                    .padding(.top, 12)
                    .padding(.bottom, Self.footerBottom)
            }
            .transition(.opacity)
        case .queue:
            VStack(spacing: 0) {
                MusicPlayerHeader(track: track)
                MusicQueueView(service: service)
                    .frame(maxHeight: .infinity)
                MusicPlayerFooter(service: service, navigation: navigation)
                    .padding(.horizontal, MusicLyricsView.margin)
                    .padding(.top, 8)
                    .padding(.bottom, Self.footerBottom)
            }
            .transition(.opacity)
        case .nowPlaying, .browse:
            MusicNowPlayingPage(service: service, navigation: navigation, mixer: mixer, track: track, tint: tint)
                .transition(.opacity)
        }
    }

    /// The space under the footer on Lyrics and Up next.
    private static let footerBottom: CGFloat = MusicStyle.Spacing.page
}

/// The song at the top of Lyrics and Up next: a small cover, the title and artist, and the "..." button, as a Mixer row.
private struct MusicPlayerHeader: View {
    let track: MusicTrack

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            MusicThumbnail(url: track.thumbnailURL, size: 36, cornerRadius: MusicStyle.Radius.small)
                .overlay(
                    RoundedRectangle(cornerRadius: MusicStyle.Radius.small, style: .continuous)
                        .strokeBorder(MusicStyle.Palette.lineHairline, lineWidth: 1)
                )
                .shadow(
                    color: MusicStyle.Shadow.headerArt.color,
                    radius: MusicStyle.Shadow.headerArt.radius,
                    y: MusicStyle.Shadow.headerArt.y
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 0) {
                Text(track.title)
                    .musicText(MusicStyle.Typeface.heading)
                    .foregroundStyle(MusicStyle.Palette.textPrimary)
                    .lineLimit(1)
                MusicArtistLine(
                    artist: track.artist,
                    links: track.artistLinks,
                    font: MusicStyle.Typeface.secondary.font,
                    color: MusicStyle.Palette.playerSubtitle
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            MusicNowPlayingMenu(track: track, style: .player)
        }
        .padding(.horizontal, MusicStyle.Spacing.page)
        .padding(.top, 4)
    }
}

/// Now Playing: the cover, the title and artist, the scrubber, the transport, the volume and the row that opens
/// Lyrics and Up next, at the Mixer's scale. The gaps between the blocks stretch when the popover is taller.
private struct MusicNowPlayingPage: View {
    let service: MusicService
    let navigation: MusicSearchNavigation
    let mixer: MusicMixerState?
    let track: MusicTrack
    let tint: MusicTint

    /// The side margin of every block under the cover.
    private static let margin: CGFloat = 28

    /// The cover's side.
    private static let artSize: CGFloat = 160

    var body: some View {
        VStack(spacing: 0) {
            artwork
                .padding(.top, 8)
            Spacer(minLength: 12)
            titleBlock
                .padding(.horizontal, Self.margin)
            Spacer(minLength: 8)
            MusicPlayerScrubber(service: service)
                .padding(.horizontal, Self.margin)
            Spacer(minLength: 8)
            MusicPlayerTransport(service: service)
            if let mixer {
                Spacer(minLength: 12)
                MusicPlayerVolumeRow(mixer: mixer)
                    .padding(.horizontal, Self.margin)
            }
            Spacer(minLength: 12)
            MusicPlayerBottomRow(service: service, navigation: navigation, mixer: mixer, tint: tint)
                .padding(.horizontal, Self.margin)
                .padding(.bottom, MusicStyle.Spacing.page)
        }
    }

    private var artwork: some View {
        MusicThumbnail(url: track.thumbnailURL, size: Self.artSize, cornerRadius: MusicStyle.Radius.card)
            .overlay(
                RoundedRectangle(cornerRadius: MusicStyle.Radius.card, style: .continuous)
                    .strokeBorder(MusicStyle.Palette.lineHairline, lineWidth: 1)
            )
            .shadow(
                color: MusicStyle.Shadow.npArt.color,
                radius: MusicStyle.Shadow.npArt.radius,
                y: MusicStyle.Shadow.npArt.y
            )
            .accessibilityHidden(true)
    }

    /// The title over the artist, both on the left. A playback error takes the artist's place.
    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(track.title)
                .musicText(MusicStyle.Typeface.songTitle)
                .foregroundStyle(MusicStyle.Palette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .help(track.title)
            if let error = service.player.error {
                Text(error)
                    .musicText(MusicStyle.Typeface.row)
                    .foregroundStyle(MusicStyle.Palette.playerSubtitle)
                    .lineLimit(1)
            } else {
                MusicArtistLine(
                    artist: track.artist,
                    links: track.artistLinks,
                    font: MusicStyle.Typeface.row.font,
                    color: MusicStyle.Palette.playerSubtitle
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
