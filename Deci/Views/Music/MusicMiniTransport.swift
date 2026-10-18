// Deci/Views/Music/MusicMiniTransport.swift
import SwiftUI

enum MusicTimeFormat {
    /// "m:ss", or "h:mm:ss" from one hour up. Negative and non-finite values read as zero.
    static func string(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return "\(hours):" + String(format: "%02d:%02d", minutes, secs)
        }
        return "\(minutes):" + String(format: "%02d", secs)
    }

    /// Fraction of the track played, clamped to 0...1; 0 while the duration is unknown.
    static func progress(current: TimeInterval, duration: TimeInterval) -> Double {
        guard current.isFinite, duration.isFinite, duration > 0 else { return 0 }
        return min(max(current / duration, 0), 1)
    }
}

/// Pinned under the results: what is playing, play/pause and a thin progress bar.
struct MusicMiniTransport: View {
    let player: MusicPlayer

    var body: some View {
        if let track = player.nowPlaying {
            VStack(spacing: DesignTokens.Spacing.xs) {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    MusicThumbnail(url: track.thumbnailURL, size: 36)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(track.title)
                            .font(DesignTokens.Typography.rowNameBold)
                            .lineLimit(1)
                        Text(player.error ?? track.artist)
                            .font(DesignTokens.Typography.rowDescription)
                            .foregroundStyle(player.error == nil ? DesignTokens.Colors.textSecondary : DesignTokens.Colors.mutedIndicator)
                            .lineLimit(1)
                    }

                    Spacer(minLength: DesignTokens.Spacing.sm)

                    transportButton
                }

                progressRow
            }
            .padding(DesignTokens.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Dimensions.rowRadius)
                    .fill(DesignTokens.Colors.glassFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignTokens.Dimensions.rowRadius)
                            .strokeBorder(DesignTokens.Colors.glassRowBorder, lineWidth: 0.5)
                    )
            )
        }
    }

    private var transportButton: some View {
        ZStack {
            if player.isLoading {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button(player.isPlaying ? "Pause" : "Play", systemImage: player.isPlaying ? "pause.fill" : "play.fill") {
                    player.toggle()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .font(.system(size: 14))
                .foregroundStyle(DesignTokens.Colors.textPrimary)
                .contentShape(Rectangle())
            }
        }
        .frame(width: 28, height: 28)
    }

    private var progressRow: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Text(MusicTimeFormat.string(player.currentTime))
                .frame(width: 38, alignment: .trailing)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(DesignTokens.Colors.sliderTrack)
                    Capsule()
                        .fill(DesignTokens.Colors.sliderFill)
                        .frame(width: proxy.size.width * MusicTimeFormat.progress(current: player.currentTime, duration: player.duration))
                }
            }
            .frame(height: 3)

            Text(MusicTimeFormat.string(player.duration))
                .frame(width: 38, alignment: .leading)
        }
        .font(DesignTokens.Typography.percentage)
        .foregroundStyle(DesignTokens.Colors.textTertiary)
    }
}

/// Small square cover art with a neutral placeholder while it loads or when a track has none.
struct MusicThumbnail: View {
    let url: URL?
    let size: CGFloat

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            default:
                ZStack {
                    DesignTokens.Colors.glassFillStrong
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.4))
                        .foregroundStyle(DesignTokens.Colors.textTertiary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius))
    }
}
