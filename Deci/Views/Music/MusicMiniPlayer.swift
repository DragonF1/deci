// Deci/Views/Music/MusicMiniPlayer.swift
import SwiftUI

/// The slim glass bar near the bottom edge: the song that is loaded, with pause and next. A click anywhere outside
/// the two buttons and the artist names opens Now Playing.
struct MusicMiniPlayer: View {
    let service: MusicService
    let track: MusicTrack
    let onOpen: () -> Void

    @State private var isHovered = false

    private var player: MusicPlayer { service.player }

    private static let artSize: CGFloat = 30

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DesignTokens.Dimensions.cornerRadius, style: .continuous)
        HStack(spacing: DesignTokens.Spacing.sm) {
            MusicThumbnail(url: track.thumbnailURL, size: Self.artSize, cornerRadius: MusicStyle.Radius.art)
                .overlay(
                    RoundedRectangle(cornerRadius: MusicStyle.Radius.art, style: .continuous)
                        .strokeBorder(MusicStyle.Palette.lineHairline, lineWidth: 1)
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 0) {
                Text(track.title)
                    .musicText(MusicStyle.Typeface.heading)
                    .foregroundStyle(MusicStyle.Palette.textPrimary)
                    .lineLimit(1)
                if let error = player.error {
                    Text(error)
                        .musicText(MusicStyle.Typeface.secondary)
                        .foregroundStyle(MusicStyle.Palette.textSecondary)
                        .lineLimit(1)
                } else {
                    MusicArtistLine(
                        artist: track.artist,
                        links: track.artistLinks,
                        font: MusicStyle.Typeface.secondary.font,
                        color: MusicStyle.Palette.textSecondary
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: DesignTokens.Spacing.xs) {
                playPause
                Button("Next", systemImage: "forward.fill") { service.next() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(service.canGoNext ? MusicStyle.Palette.textPrimary : MusicStyle.Palette.textQuaternary)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
                    .disabled(!service.canGoNext)
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, DesignTokens.Spacing.sm)
        .frame(height: MusicStyle.Size.miniPlayerHeight)
        .musicGlass(in: shape)
        .overlay(shape.fill(isHovered ? DesignTokens.Colors.hoverSurface : .clear).allowsHitTesting(false))
        .contentShape(shape)
        .onHover { isHovered = $0 }
        .animation(DesignTokens.Animation.hover, value: isHovered)
        .onTapGesture(perform: onOpen)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Now playing: \(track.title), \(track.artist)")
        .accessibilityAction(named: "Open Now Playing", onOpen)
    }

    @ViewBuilder
    private var playPause: some View {
        if player.isLoading {
            ProgressView()
                .controlSize(.small)
                .frame(width: 26, height: 26)
        } else {
            Button(
                player.isPlaying ? "Pause" : "Play",
                systemImage: player.isPlaying ? "pause.fill" : "play.fill"
            ) {
                service.togglePlayback()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .font(.system(size: 14))
            .foregroundStyle(MusicStyle.Palette.textPrimary)
            .frame(width: 26, height: 26)
            .contentShape(Rectangle())
        }
    }
}
