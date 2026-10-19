// Deci/Views/Music/MusicMiniPlayer.swift
import SwiftUI

/// The floating glass pill above the tab bar: the song that is loaded, with pause and next. A click anywhere
/// outside the two buttons and the artist names opens Now Playing.
struct MusicMiniPlayer: View {
    let service: MusicService
    let track: MusicTrack
    let onOpen: () -> Void

    @State private var isHovered = false

    private var player: MusicPlayer { service.player }

    var body: some View {
        HStack(spacing: 12) {
            MusicThumbnail(url: track.thumbnailURL, size: 36, cornerRadius: MusicStyle.Radius.art)
                .overlay(
                    RoundedRectangle(cornerRadius: MusicStyle.Radius.art, style: .continuous)
                        .strokeBorder(MusicStyle.Palette.lineHairline, lineWidth: 1)
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(track.title)
                    .musicText(MusicStyle.Typeface.miniTitle)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let error = player.error {
                    Text(error)
                        .musicText(MusicStyle.Typeface.caption12)
                        .foregroundStyle(MusicStyle.Palette.textSecondary)
                        .lineLimit(1)
                } else {
                    MusicArtistLine(
                        artist: track.artist,
                        links: track.artistLinks,
                        font: MusicStyle.Typeface.caption12.font,
                        color: MusicStyle.Palette.textSecondaryAlt
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 20) {
                playPause
                Button("Next", systemImage: "forward.fill") { service.next() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .font(.system(size: 19))
                    .foregroundStyle(service.canGoNext ? Color.white : MusicStyle.Palette.textQuaternary)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
                    .disabled(!service.canGoNext)
            }
        }
        .padding(.init(top: 8, leading: 8, bottom: 8, trailing: 20))
        .frame(height: MusicStyle.Size.miniPlayerHeight)
        .musicGlass(
            in: RoundedRectangle(cornerRadius: MusicStyle.Radius.chrome, style: .continuous),
            fill: isHovered ? MusicStyle.Palette.glassFillHover : MusicStyle.Palette.glassFill
        )
        .contentShape(RoundedRectangle(cornerRadius: MusicStyle.Radius.chrome, style: .continuous))
        .onHover { isHovered = $0 }
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
                .environment(\.colorScheme, .dark)
                .frame(width: 22, height: 26)
        } else {
            Button(
                player.isPlaying ? "Pause" : "Play",
                systemImage: player.isPlaying ? "pause.fill" : "play.fill"
            ) {
                service.togglePlayback()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .font(.system(size: 15))
            .foregroundStyle(.white)
            .frame(width: 22, height: 26)
            .contentShape(Rectangle())
        }
    }
}
