// Deci/Views/Music/MusicSpectrumView.swift
import SwiftUI

/// The bars of the spectrum, drawn: 28 horizontal bars from the start of the song at the top to the end at the bottom.
/// The accent runs down them from the top as the song plays, with a soft edge into the white below.
/// The accent is the animated part, so a new song's colour glides in with the rest of the column.
struct MusicSpectrumCanvas: View, Animatable {
    /// The level of each bar.
    let levels: [Double]
    /// How far along the song is, 0...1.
    let progress: Double
    /// The white of an unplayed bar.
    let unplayedOpacity: Double
    /// The opacity of every bar: a paused song's dim.
    var barsOpacity: Double = 1
    /// Every bar this wide, whatever its level (the empty state's flat bars).
    var fixedWidth: Double?
    /// The box's height: it stretches to fill the column, never under the design's.
    var height: Double = MusicSpectrum.boxHeight
    /// The box's width: the design's, or less where the column makes room beside it.
    var boxWidth: Double = MusicSpectrum.boxWidth

    var hue: Double
    var saturation: Double
    var brightness: Double

    init(
        levels: [Double],
        progress: Double,
        unplayedOpacity: Double,
        barsOpacity: Double = 1,
        fixedWidth: Double? = nil,
        height: Double = MusicSpectrum.boxHeight,
        boxWidth: Double = MusicSpectrum.boxWidth,
        accent: MusicTint
    ) {
        self.levels = levels
        self.progress = progress
        self.unplayedOpacity = unplayedOpacity
        self.barsOpacity = barsOpacity
        self.fixedWidth = fixedWidth
        self.height = height
        self.boxWidth = boxWidth
        hue = accent.hue
        saturation = accent.saturation
        brightness = accent.brightness
    }

    var animatableData: AnimatablePair<Double, AnimatablePair<Double, Double>> {
        get { AnimatablePair(hue, AnimatablePair(saturation, brightness)) }
        set {
            hue = newValue.first
            saturation = newValue.second.first
            brightness = newValue.second.second
        }
    }

    var body: some View {
        let accent = Color(hue: hue, saturation: saturation, brightness: brightness)
        let thickness = MusicSpectrum.barThickness(height: height)
        let played = accent.opacity(barsOpacity)
        let unplayed = Color.white.opacity(unplayedOpacity * barsOpacity)
        Canvas { [height, progress] context, size in
            let edge = MusicSpectrum.fillEdge(height: height)
            let edgeY = MusicSpectrum.fillEdgeY(progress: progress, height: height)
            for (index, level) in levels.enumerated() {
                let width = fixedWidth ?? MusicSpectrum.width(forLevel: level, boxWidth: size.width)
                let rect = CGRect(
                    x: (size.width - width) / 2,
                    y: MusicSpectrum.barY(index, height: height),
                    width: width,
                    height: thickness
                )
                let path = Path(roundedRect: rect, cornerRadius: thickness / 2)
                if rect.maxY <= edgeY - edge / 2 {
                    context.fill(path, with: .color(played))
                } else if rect.minY >= edgeY + edge / 2 {
                    context.fill(path, with: .color(unplayed))
                } else {
                    // A bar in the soft edge: the accent above it, the white below.
                    context.fill(path, with: .linearGradient(
                        Gradient(colors: [played, unplayed]),
                        startPoint: CGPoint(x: rect.midX, y: edgeY - edge / 2),
                        endPoint: CGPoint(x: rect.midX, y: edgeY + edge / 2)
                    ))
                }
            }
        }
        .frame(width: boxWidth, height: height)
        .accessibilityHidden(true)
    }
}

/// The canvas's position, animated apart from the accent inside it: a seek while paused slides the fill, and the polls
/// that move it 30 times a second while a song plays never cut short a colour glide on the canvas.
private struct MusicSpectrumProgressLayer<Content: View>: View, Animatable {
    var progress: Double
    @ViewBuilder let content: (Double) -> Content

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View { content(progress) }
}

/// The player column's spectrum, which is also its progress bar: click or drag to seek (the seek lands on release),
/// hover to see where and when. The numbers come from `MusicSpectrum` and `MusicSpectrumDriver`; this only draws them
/// and passes the gestures on.
struct MusicSpectrumView: View {
    let state: MusicPlayerColumnState
    let track: MusicTrack?
    let service: MusicService?
    let spectrum: MusicSpectrumDriver
    /// The box's width: the design's, or less where the column makes room beside it.
    var width: Double = MusicSpectrum.boxWidth

    @Environment(\.musicAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The pointer's height in the box while it is over it.
    @State private var hoverY: Double?
    /// The finger's height while it is down, which lets go by itself when the drag is cancelled.
    @GestureState private var dragY: Double?
    /// The box's height as laid out: whatever the column leaves it, never under the design's.
    @State private var height: Double = MusicSpectrum.boxHeight

    /// How far VoiceOver's increment moves the song.
    private static let adjustStep: TimeInterval = 10

    private var player: MusicPlayer? { service?.player }

    private var duration: TimeInterval { player?.duration ?? 0 }

    private var canSeek: Bool { state.showsProgress && duration > 0 }

    /// How far along the song is: the live poll while it runs, else the player's own position.
    private var progress: Double {
        guard state.showsProgress, let player else { return 0 }
        return spectrum.progress ?? MusicTimeFormat.progress(current: player.currentTime, duration: player.duration)
    }

    private var levels: [Double] {
        if state.isEmptyLayout || track == nil {
            return Array(repeating: MusicSpectrum.minLevel, count: MusicSpectrum.barCount)
        }
        return spectrum.bars(for: track?.videoId ?? "")
    }

    /// How long a seek while paused slides the fill. Playing, the driver's polls glide it instead.
    private static let pausedSeekGlide: TimeInterval = 0.35

    var body: some View {
        MusicSpectrumProgressLayer(progress: progress) { shown in
            MusicSpectrumCanvas(
                levels: levels,
                progress: shown,
                unplayedOpacity: unplayedOpacity,
                barsOpacity: state.barsOpacity,
                fixedWidth: state.isEmptyLayout ? MusicPlayerColumnState.emptyBarWidth : nil,
                height: height,
                boxWidth: width,
                accent: accent
            )
        }
        // Only adds an animation where none was asked for, so it never overrides another one.
        .transaction(value: progress) { transaction in
            guard state == .paused, !reduceMotion, transaction.animation == nil else { return }
            transaction.animation = .easeOut(duration: Self.pausedSeekGlide)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .onGeometryChange(for: Double.self) { max($0.size.height, MusicSpectrum.boxHeight) } action: { height = $0 }
        .overlay { preview }
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let point): hoverY = canSeek ? point.y : nil
            case .ended: hoverY = nil
            }
        }
        .gesture(seekGesture)
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue(canSeek ? "\(Int((progress * 100).rounded())) percent" : "")
        .accessibilityAdjustableAction { direction in
            guard canSeek, let service, let player else { return }
            switch direction {
            case .increment: service.seek(to: min(player.duration, player.currentTime + Self.adjustStep))
            case .decrement: service.seek(to: max(0, player.currentTime - Self.adjustStep))
            @unknown default: break
            }
        }
    }

    /// The white of an unplayed bar: the design's 0.25 while a song is on, fainter while it loads and when empty.
    private var unplayedOpacity: Double {
        switch state {
        case .playing, .paused: 0.25
        case .loading: 0.07
        case .signedOut, .empty: 0.09
        }
    }

    private var seekGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($dragY) { value, state, _ in state = value.location.y }
            .onEnded { value in
                guard canSeek else { return }
                service?.seek(to: MusicSpectrum.seekTime(atY: value.location.y, duration: duration, height: height))
            }
    }

    /// The thin line under the pointer (or the finger) and the time it points to.
    @ViewBuilder
    private var preview: some View {
        if let y = dragY ?? hoverY, canSeek {
            let lineY = MusicSpectrum.previewLineY(atY: y, height: height)
            let time = MusicSpectrum.seekTime(atY: y, duration: duration, height: height)
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Color.white.opacity(0.55))
                    .frame(width: width, height: 1)
                    .offset(y: lineY)
                Text(MusicTimeFormat.string(time))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.95))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color.black.opacity(0.70))
                    )
                    .fixedSize()
                    .position(x: width / 2, y: min(max(lineY - 9, 8), height - 8))
            }
            .frame(width: width, height: height, alignment: .topLeading)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}
