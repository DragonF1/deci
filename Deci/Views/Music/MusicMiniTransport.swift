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

    /// Where a touch at `x` points along a bar `width` wide, clamped to 0...1.
    static func fraction(x: CGFloat, width: CGFloat) -> Double {
        guard x.isFinite, width.isFinite, width > 0 else { return 0 }
        return Double(min(max(x / width, 0), 1))
    }

    /// Time left as "-m:ss"; "-0:00" while the duration is unknown or already passed.
    static func remaining(current: TimeInterval, duration: TimeInterval) -> String {
        guard current.isFinite, duration.isFinite, duration > current else { return "-0:00" }
        return "-" + string(duration - current)
    }
}

/// Pinned under the list: what is playing, previous / play-pause / next and a scrubbable progress bar.
struct MusicMiniTransport: View {
    let service: MusicService
    /// Fraction under the finger while scrubbing; nil otherwise. Seeks on release.
    /// A gesture state, so a drag that is cancelled (the track changed, the window lost focus) lets go by itself.
    @GestureState private var dragFraction: Double? = nil

    private var player: MusicPlayer { service.player }

    var body: some View {
        if let track = player.nowPlaying {
            VStack(spacing: DesignTokens.Spacing.xs) {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    MusicThumbnail(url: track.thumbnailURL, size: 36)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(track.title)
                            .font(DesignTokens.Typography.rowNameBold)
                            .lineLimit(1)
                        if let error = player.error {
                            Text(error)
                                .font(DesignTokens.Typography.rowDescription)
                                .foregroundStyle(DesignTokens.Colors.mutedIndicator)
                                .lineLimit(1)
                        } else {
                            MusicArtistLine(artist: track.artist, links: track.artistLinks)
                        }
                    }

                    Spacer(minLength: DesignTokens.Spacing.sm)

                    HStack(spacing: DesignTokens.Spacing.xs) {
                        transportButtons
                        // The playing song's own actions, on no page. Always shown: the player has no hover.
                        MusicNowPlayingMenu(track: track)
                    }
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

    private var transportButtons: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            modeButton("Shuffle", systemImage: "shuffle", isOn: service.isShuffleOn) {
                service.setShuffle(!service.isShuffleOn)
            }

            skipButton("Previous", systemImage: "backward.fill", enabled: true) { service.previous() }

            ZStack {
                if player.isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button(player.isPlaying ? "Pause" : "Play", systemImage: player.isPlaying ? "pause.fill" : "play.fill") {
                        service.togglePlayback()
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundStyle(DesignTokens.Colors.textPrimary)
                    .contentShape(Rectangle())
                }
            }
            .frame(width: 28, height: 28)

            skipButton("Next", systemImage: "forward.fill", enabled: service.canGoNext) { service.next() }

            modeButton(service.loopMode.label, systemImage: service.loopMode.systemImage, isOn: service.loopMode != .off) {
                service.cycleLoopMode()
            }
        }
    }

    private func skipButton(_ title: String, systemImage: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(title, systemImage: systemImage, action: action)
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(enabled ? DesignTokens.Colors.textPrimary : DesignTokens.Colors.textTertiary)
            .frame(width: 22, height: 28)
            .contentShape(Rectangle())
            .disabled(!enabled)
    }

    /// Shuffle and loop: the size of the skip buttons, dim when off and in the accent colour when on.
    private func modeButton(_ title: String, systemImage: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(title, systemImage: systemImage, action: action)
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(isOn ? DesignTokens.Colors.accentPrimary : DesignTokens.Colors.textTertiary)
            .frame(width: 22, height: 28)
            .contentShape(Rectangle())
            .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private var progressRow: some View {
        let shown = dragFraction.map { $0 * player.duration } ?? player.currentTime
        return HStack(spacing: DesignTokens.Spacing.sm) {
            Text(MusicTimeFormat.string(shown))
                .frame(width: 38, alignment: .trailing)

            MusicScrubber(
                fraction: dragFraction ?? MusicTimeFormat.progress(current: player.currentTime, duration: player.duration),
                isEnabled: player.duration > 0,
                dragFraction: $dragFraction
            ) { fraction in
                service.seek(to: fraction * player.duration)
            }

            Text(MusicTimeFormat.remaining(current: shown, duration: player.duration))
                .frame(width: 38, alignment: .leading)
        }
        .font(DesignTokens.Typography.percentage)
        .foregroundStyle(DesignTokens.Colors.textTertiary)
    }
}

/// A thin progress bar with a taller hit area. Dragging (or clicking) previews the position, release seeks.
private struct MusicScrubber: View {
    let fraction: Double
    let isEnabled: Bool
    let dragFraction: GestureState<Double?>
    let onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(DesignTokens.Colors.sliderTrack)
                    .frame(height: 3)
                Capsule()
                    .fill(DesignTokens.Colors.sliderFill)
                    .frame(width: proxy.size.width * fraction, height: 3)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating(dragFraction) { value, state, _ in
                        state = MusicTimeFormat.fraction(x: value.location.x, width: proxy.size.width)
                    }
                    .onEnded { value in
                        onSeek(MusicTimeFormat.fraction(x: value.location.x, width: proxy.size.width))
                    }
            )
            .allowsHitTesting(isEnabled)
        }
        .frame(height: 14)
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(Int(fraction * 100)) percent")
    }
}

/// Small square cover art with a neutral placeholder while it loads or when a track has none.
/// Artists get a round one.
struct MusicThumbnail: View {
    let url: URL?
    let size: CGFloat
    var circular = false
    var placeholder = "music.note"

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            default:
                MusicCoverPlaceholder(symbol: placeholder, size: size)
            }
        }
        .frame(width: size, height: size)
        .clipShape(MusicCoverShape(circular: circular))
    }
}

/// A small pushpin on a dark dot, for the top-right corner of a pinned song, playlist, album or artist cover. It
/// scales with the cover. A round cover is inset further, so the dot sits on the edge of the circle and not in the
/// empty corner of its square.
struct MusicPinBadge: View {
    let coverSize: CGFloat
    var circular = false

    /// The dot is about a fifth of the cover, never under `minDiameter`: 18 on a 96 tile, 14 on a row.
    static let minDiameter: CGFloat = 14

    static func diameter(coverSize: CGFloat) -> CGFloat {
        max(minDiameter, (coverSize * 0.1875).rounded())
    }

    /// The gap from the cover's top and right edges.
    static func inset(coverSize: CGFloat, circular: Bool) -> CGFloat {
        circular ? max(4, coverSize * 0.1) : 4
    }

    var body: some View {
        let diameter = Self.diameter(coverSize: coverSize)
        let inset = Self.inset(coverSize: coverSize, circular: circular)
        Image(systemName: "pin.fill")
            .font(.system(size: diameter * 0.55, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: diameter, height: diameter)
            .background(Circle().fill(Color.black.opacity(0.6)))
            .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5))
            .padding(.top, inset)
            .padding(.trailing, inset)
            .accessibilityHidden(true)
    }
}

extension View {
    /// Puts the pin badge on this cover's top-right corner while `isPinned`. Apply it after the playing overlay, so
    /// the badge stays on top while the song plays.
    func musicPinBadge(_ isPinned: Bool, coverSize: CGFloat, circular: Bool = false) -> some View {
        overlay(alignment: .topTrailing) {
            if isPinned {
                MusicPinBadge(coverSize: coverSize, circular: circular)
            }
        }
    }
}

/// What stands in for a cover or a photo that is still loading, failed, or does not exist.
struct MusicCoverPlaceholder: View {
    let symbol: String
    let size: CGFloat

    var body: some View {
        ZStack {
            DesignTokens.Colors.glassFillStrong
            Image(systemName: symbol)
                .font(.system(size: size * 0.4))
                .foregroundStyle(DesignTokens.Colors.textTertiary)
        }
    }
}

/// The cover clip: the button radius, or a circle for artists.
struct MusicCoverShape: Shape {
    let circular: Bool

    func path(in rect: CGRect) -> Path {
        circular
            ? Circle().path(in: rect)
            : RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius).path(in: rect)
    }
}

extension MusicLoopMode {
    /// What the loop button says it is doing; also its accessibility label.
    var label: String {
        switch self {
        case .off: "Loop off"
        case .playlist: "Loop playlist"
        case .song: "Loop song"
        }
    }

    var systemImage: String {
        switch self {
        case .off, .playlist: "repeat"
        case .song: "repeat.1"
        }
    }
}

extension MusicCollection.Kind {
    /// Placeholder symbol while the cover loads or when there is none.
    var placeholderSymbol: String {
        switch self {
        case .playlist: "music.note.list"
        case .album: "opticaldisc"
        case .artist: "person.fill"
        }
    }
}
