// Deci/Views/Music/MusicNowPlayingCard.swift
import SwiftUI

/// The hover card of the Now playing chip: a compact One UI style media card on the song's cover, shown in its own
/// floating panel under the Music menu bar item while the mouse rests on the chip. It reads the player the Music popup
/// reads (nothing is copied), is dark whatever the Mixer wears, and has no timer of its own: it is built when the card
/// opens and gone when it closes, and its numbers move with the player's own half second position ticks.
///
/// `onOpenPlayer` hides the card and opens the full Music popover, for the save button: the playlist picker lives in
/// the popover's right column. A click on the chip opens the popover too, so the card has no button of its own for it.
struct MusicNowPlayingCard: View {
    let musicHost: MusicServiceHost
    let onOpenPlayer: () -> Void

    var body: some View {
        MusicNowPlayingCardContent(musicHost: musicHost, onOpenPlayer: onOpenPlayer)
            .frame(width: MusicHoverCardMetrics.width, height: MusicHoverCardMetrics.height)
            .musicAccentScope(track: musicHost.service?.player.nowPlaying)
            .environment(\.appearancePreference, .dark)
            .musicDarkScope()
    }
}

private struct MusicNowPlayingCardContent: View {
    let musicHost: MusicServiceHost
    let onOpenPlayer: () -> Void

    @Environment(\.musicAccent) private var accent
    /// The cover's small picture, from the tint store's single fetch of it.
    @State private var cover: CGImage?

    private typealias Metrics = MusicHoverCardMetrics

    private var service: MusicService? { musicHost.service }

    var body: some View {
        Group {
            if let service, let track = service.player.nowPlaying {
                card(service: service, track: track)
            } else {
                Color.clear
            }
        }
        .frame(width: Metrics.width, height: Metrics.height)
    }

    // MARK: - Card

    private func card(service: MusicService, track: MusicTrack) -> some View {
        let player = service.player
        let duration = player.duration > 0 ? player.duration : TimeInterval(track.durationSeconds ?? 0)
        return VStack(spacing: 0) {
            titleRow(track)
                .frame(height: Metrics.titleRowHeight)
                .padding(.top, Metrics.topInset)
            Spacer().frame(height: Metrics.afterTitleRow)
            MusicCardProgress(
                levels: musicHost.spectrum.bars(for: track.videoId),
                position: player.currentTime,
                duration: duration,
                canSeek: player.duration > 0 && !player.isLoading,
                tint: accent
            ) { service.seek(to: $0) }
            Spacer().frame(height: Metrics.afterTimesRow)
            controls(service: service, track: track)
                .frame(height: Metrics.controlsRowHeight)
        }
        .padding(.horizontal, Metrics.horizontalInset)
        .frame(width: Metrics.width, height: Metrics.height, alignment: .top)
        .background { background }
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
        .task(id: track.thumbnailURL) { await loadCover(for: track.thumbnailURL) }
    }

    /// The cover scaled to fill and blurred heavily, with a black 0.45 wash over it; with no cover, a gradient of the
    /// song's colour.
    private var background: some View {
        ZStack {
            Color.black
            if let cover {
                Image(decorative: cover, scale: 1)
                    .resizable()
                    .scaledToFill()
                    .frame(width: Metrics.width, height: Metrics.height)
                    // The blur fades the picture's own edges: scaled up, those are clipped away.
                    .scaleEffect(1.4)
                    .blur(radius: 26)
                    .clipped()
            } else {
                LinearGradient(
                    colors: [dimmed(accent, 0.80), dimmed(accent, 0.45)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
            Color.black.opacity(0.45)
        }
    }

    private func dimmed(_ tint: MusicTint, _ factor: Double) -> Color {
        MusicTint(hue: tint.hue, saturation: tint.saturation, brightness: tint.brightness * factor).solid
    }

    private func loadCover(for url: URL?) async {
        let store = MusicCoverTintStore.shared
        guard let url else {
            cover = nil
            return
        }
        if let cached = store.cachedThumbnail(for: url) {
            cover = cached
            return
        }
        cover = nil
        _ = await store.tint(for: url)
        guard !Task.isCancelled else { return }
        cover = store.cachedThumbnail(for: url)
    }

    // MARK: - Rows

    private func titleRow(_ track: MusicTrack) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "music.note")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.85))
                .accessibilityHidden(true)
            // One run of text so it truncates as one line: the title in white, the artist after it in white 0.6.
            Text("\(Text(track.title).fontWeight(.semibold).foregroundStyle(Color.white)) \(Text(track.artist).foregroundStyle(Color.white.opacity(0.6)))")
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Controls

    private func controls(service: MusicService, track: MusicTrack) -> some View {
        let player = service.player
        let size = Metrics.controlCircleSize
        let isShuffleOn = service.isShuffleOn
        let canSave = musicHost.navigation?.actions(for: track, in: .none).contains(.saveToPlaylist) ?? false
        return HStack(spacing: 0) {
            MusicCardButton(
                systemImage: "shuffle",
                title: "Shuffle",
                size: size,
                glyphSize: 13,
                fill: 0,
                glyphColor: isShuffleOn ? accent.solid : Color.white.opacity(0.7)
            ) { service.setShuffle(!isShuffleOn) }
            Spacer(minLength: 0)
            MusicCardButton(
                systemImage: "backward.fill",
                title: "Previous",
                size: size,
                glyphSize: 12,
                fill: 0.15
            ) { service.previous() }
            Spacer(minLength: 0)
            playPause(service: service, player: player)
            Spacer(minLength: 0)
            MusicCardButton(
                systemImage: "forward.fill",
                title: "Next",
                size: size,
                glyphSize: 12,
                fill: 0.15,
                isDisabled: !service.canGoNext
            ) { service.next() }
            if canSave {
                Spacer(minLength: 0)
                MusicCardButton(
                    systemImage: "plus.circle",
                    title: "Save to playlist",
                    size: size,
                    glyphSize: 18,
                    fill: 0
                ) {
                    musicHost.navigation?.perform(.saveToPlaylist, for: track, in: .none)
                    onOpenPlayer()
                }
                .help("Save to playlist")
            }
        }
    }

    private func playPause(service: MusicService, player: MusicPlayer) -> some View {
        let isLoading = player.isLoading
        let isPlaying = player.isPlaying
        return MusicCardButton(
            systemImage: isPlaying ? "pause.fill" : "play.fill",
            title: isLoading ? "Loading" : (isPlaying ? "Pause" : "Play"),
            size: Metrics.controlCircleSize,
            glyphSize: 13,
            fill: 0.15,
            isDisabled: isLoading,
            showsSpinner: isLoading
        ) { service.togglePlayback() }
    }
}

/// The wave progress with the elapsed and total times under it. The played part is a filled smooth curve of the song's
/// levels, drawn in a gradient of the song's colour and ending in a point at the knob; the rest is a thin line on the
/// baseline. A click or a drag moves the knob; the song seeks when the finger lets go, as the spectrum does.
private struct MusicCardProgress: View {
    let levels: [Double]
    let position: TimeInterval
    let duration: TimeInterval
    let canSeek: Bool
    let tint: MusicTint
    let onSeek: (TimeInterval) -> Void

    /// The box's width as laid out.
    @State private var width: Double = MusicHoverCardMetrics.contentWidth
    /// The finger's x while it is down, which lets go by itself when the drag is cancelled.
    @GestureState private var dragX: Double?

    private var progress: Double {
        if let dragX, canSeek { return MusicWave.progress(atX: dragX, width: width) }
        return MusicTimeFormat.progress(current: position, duration: duration)
    }

    private var elapsed: TimeInterval {
        if let dragX, canSeek { return MusicWave.seekTime(atX: dragX, duration: duration, width: width) }
        return position
    }

    var body: some View {
        VStack(spacing: 0) {
            wave
                .frame(height: MusicWave.boxHeight)
            HStack(spacing: 0) {
                time(elapsed)
                Spacer(minLength: 0)
                time(duration)
            }
            .frame(height: MusicHoverCardMetrics.timesRowHeight)
        }
    }

    private var wave: some View {
        let shown = progress
        let playheadX = MusicWave.playheadX(progress: shown, width: width)
        let gradient = Gradient(colors: MusicWave.gradientTints(for: tint).map(\.solid))
        return Canvas { context, size in
            let base = MusicWave.baselineY
            let head = MusicWave.playheadX(progress: shown, width: size.width)

            // The unplayed part: a thin line from the knob to the end.
            var rest = Path()
            rest.move(to: CGPoint(x: head, y: base))
            rest.addLine(to: CGPoint(x: max(size.width - MusicWave.inset, head), y: base))
            context.stroke(rest, with: .color(Color.white.opacity(0.25)), style: StrokeStyle(lineWidth: 2, lineCap: .round))

            // The played part: the curve filled down to the baseline, in the gradient.
            let samples = MusicWave.profile(levels: levels, progress: shown, width: size.width)
            guard let first = samples.first, let last = samples.last else { return }
            let shading = GraphicsContext.Shading.linearGradient(
                gradient,
                startPoint: CGPoint(x: MusicWave.inset, y: 0),
                endPoint: CGPoint(x: max(head, MusicWave.inset + 1), y: 0)
            )
            var curve = Path()
            curve.move(to: CGPoint(x: first.x, y: base))
            for sample in samples {
                curve.addLine(to: CGPoint(x: sample.x, y: base - sample.height))
            }
            curve.addLine(to: CGPoint(x: last.x, y: base))
            curve.closeSubpath()
            context.fill(curve, with: shading)

            var line = Path()
            line.move(to: CGPoint(x: first.x, y: base))
            line.addLine(to: CGPoint(x: last.x, y: base))
            context.stroke(line, with: shading, style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }
        .overlay(alignment: .topLeading) {
            Circle()
                .fill(tint.solid)
                .overlay(Circle().strokeBorder(Color.white, lineWidth: 2.5))
                .frame(width: MusicWave.knobDiameter, height: MusicWave.knobDiameter)
                .shadow(color: tint.solid.opacity(0.75), radius: 5)
                .offset(x: playheadX - MusicWave.knobDiameter / 2, y: MusicWave.baselineY - MusicWave.knobDiameter / 2)
                .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .onGeometryChange(for: Double.self) { $0.size.width } action: { width = $0 }
        .gesture(
            DragGesture(minimumDistance: 0)
                .updating($dragX) { value, state, _ in state = value.location.x }
                .onEnded { value in
                    guard canSeek else { return }
                    onSeek(MusicWave.seekTime(atX: value.location.x, duration: duration, width: width))
                }
        )
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue(canSeek ? "\(Int((MusicTimeFormat.progress(current: position, duration: duration) * 100).rounded())) percent" : "")
        .accessibilityAdjustableAction { direction in
            guard canSeek else { return }
            switch direction {
            case .increment: onSeek(min(duration, position + 10))
            case .decrement: onSeek(max(0, position - 10))
            @unknown default: break
            }
        }
    }

    private func time(_ seconds: TimeInterval) -> some View {
        Text(MusicTimeFormat.string(seconds))
            .font(.system(size: 10, design: .monospaced))
            .monospacedDigit()
            .foregroundStyle(Color.white.opacity(0.7))
    }
}

/// A round glyph button of the card: white at `fill` behind it (none for a bare glyph), a little brighter under the
/// pointer.
private struct MusicCardButton: View {
    let systemImage: String
    let title: String
    let size: Double
    let glyphSize: Double
    /// The white opacity of the circle behind the glyph; 0 for none.
    let fill: Double
    var glyphColor: Color = Color.white.opacity(0.92)
    var isDisabled = false
    var showsSpinner = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(Color.white.opacity(circleOpacity))
                if showsSpinner {
                    MusicSpinner(size: 13, lineWidth: 1.5, color: Color.white.opacity(0.85), track: Color.white.opacity(0.18))
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: glyphSize, weight: .semibold))
                        .foregroundStyle(glyphColor)
                }
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled && !showsSpinner ? 0.35 : 1)
        .onHover { isHovering = $0 }
        .accessibilityLabel(title)
    }

    private var circleOpacity: Double {
        if fill > 0 { return isHovering && !isDisabled ? fill + 0.10 : fill }
        return isHovering && !isDisabled ? 0.12 : 0
    }
}
