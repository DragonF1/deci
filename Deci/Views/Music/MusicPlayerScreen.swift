// Deci/Views/Music/MusicPlayerScreen.swift
import SwiftUI

/// What is behind a player screen: the base colour with the tint of the song poured over it. The tint comes from a
/// palette keyed by the song, the same every run, because the player does not read the cover's pixels.
struct MusicPlayerBackdrop: View {
    let track: MusicTrack?

    var body: some View {
        let tint = track.map { MusicTint.forKey($0.videoId) }
        ZStack {
            MusicStyle.Palette.base
            if let tint {
                LinearGradient(colors: [tint.page, tint.pageBottom], startPoint: .top, endPoint: .bottom)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.4), value: track?.videoId)
    }
}

/// Now Playing, Lyrics and Up next. They fill the popover over the browse screen and share one transport card and
/// one row of panel buttons; only the middle changes. Leaving them is the chevron in the popup's header, or Esc.
struct MusicPlayerScreen: View {
    let service: MusicService
    let navigation: MusicSearchNavigation
    let screen: MusicShellScreen

    var body: some View {
        if let track = service.player.nowPlaying {
            VStack(spacing: DesignTokens.Spacing.sm) {
                switch screen {
                case .lyrics:
                    songLine(track)
                    MusicLyricsView(store: service.lyrics) { service.seek(to: $0) }
                        .frame(maxHeight: .infinity)
                case .queue:
                    queueList
                case .nowPlaying, .browse:
                    nowPlaying(track)
                }

                MusicMiniTransport(service: service, showsNowPlayingInfo: false)

                panelButtons
            }
            .padding(.horizontal, MusicStyle.Spacing.page)
            .padding(.top, 8)
            .padding(.bottom, 16)
        } else {
            Color.clear
        }
    }

    // MARK: - Now Playing

    private func nowPlaying(_ track: MusicTrack) -> some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            MusicThumbnail(url: track.thumbnailURL, size: 220, cornerRadius: MusicStyle.Radius.card)
                .overlay(
                    RoundedRectangle(cornerRadius: MusicStyle.Radius.card, style: .continuous)
                        .strokeBorder(MusicStyle.Palette.lineHairline, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.4), radius: 20, y: 12)
                .accessibilityHidden(true)

            VStack(spacing: 4) {
                Text(track.title)
                    .musicText(MusicStyle.Typeface.title3)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                if let error = service.player.error {
                    Text(error)
                        .musicText(MusicStyle.Typeface.body14)
                        .foregroundStyle(MusicStyle.Palette.textSecondary)
                        .lineLimit(1)
                } else {
                    MusicArtistLine(
                        artist: track.artist,
                        links: track.artistLinks,
                        font: MusicStyle.Typeface.body14.font,
                        color: MusicStyle.Palette.textSecondaryAlt
                    )
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    /// The cover, title and artist as one small line over the lyrics.
    private func songLine(_ track: MusicTrack) -> some View {
        HStack(spacing: 12) {
            MusicThumbnail(url: track.thumbnailURL, size: 36, cornerRadius: MusicStyle.Radius.art)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(track.title)
                    .musicText(MusicStyle.Typeface.miniTitle)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                MusicArtistLine(
                    artist: track.artist,
                    links: track.artistLinks,
                    font: MusicStyle.Typeface.caption12.font,
                    color: MusicStyle.Palette.textSecondaryAlt
                )
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Up next

    private var queueList: some View {
        VStack(spacing: DesignTokens.Spacing.xs) {
            MusicQueueHeader(isAutoplayOn: service.isAutoplayOn) {
                service.setAutoplay(!service.isAutoplayOn)
            }

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(service.queue.fromCurrent) { track in
                        MusicResultRow(
                            track: track,
                            isCurrent: service.queue.current?.videoId == track.videoId,
                            isPlaying: service.queue.current?.videoId == track.videoId && service.player.isPlaying
                        ) {
                            service.jump(to: track)
                        }
                    }
                }
            }
            .scrollIndicators(.never)
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - Panel buttons

    /// Lyrics and Up next, each only while it has something to show. The open one is lit; pressing it again goes
    /// back to Now Playing.
    private var panelButtons: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            if service.lyrics.track != nil {
                chip("Lyrics", systemImage: "quote.bubble", isOn: navigation.showsLyrics) { navigation.toggleLyrics() }
            }
            if !service.queue.isEmpty {
                chip("Up next", systemImage: "list.bullet", isOn: navigation.showsQueue) { navigation.toggleQueue() }
            }
        }
    }

    private func chip(_ title: String, systemImage: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 14))
                Text(title)
                    .musicText(MusicStyle.Typeface.callout)
            }
            .foregroundStyle(isOn ? MusicStyle.Palette.accent : Color.white)
            .padding(.leading, 12)
            .padding(.trailing, 14)
            .frame(height: 36)
            .background(Capsule().fill(isOn ? MusicStyle.Palette.accentFill : MusicStyle.Palette.fillControl))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
