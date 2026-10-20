// Deci/Views/Music/MusicSpectrumView.swift
import SwiftUI

/// The bars of the spectrum and the playhead, drawn: 28 horizontal bars from the start of the song at the top to the
/// end at the bottom. The accent is the animated part, so a new song's colour glides in with the rest of the column.
struct MusicSpectrumCanvas: View, Animatable {
    /// The level of each bar.
    let levels: [Double]
    /// How many bars are played, from the top.
    let played: Int
    /// The bar under the playhead, which takes the accent while the song plays.
    var pulseIndex: Int?
    /// The playhead line across the box.
    let showsPlayhead: Bool
    /// The white of an unplayed bar.
    let unplayedOpacity: Double
    /// The opacity of every bar: a paused song's dim, its playhead does not.
    var barsOpacity: Double = 1
    /// Every bar this wide, whatever its level (the empty state's flat bars).
    var fixedWidth: Double?
    /// The box's height: it stretches to fill the column, never under the design's.
    var height: Double = MusicSpectrum.boxHeight

    var hue: Double
    var saturation: Double
    var brightness: Double

    init(
        levels: [Double],
        played: Int,
        pulseIndex: Int? = nil,
        showsPlayhead: Bool,
        unplayedOpacity: Double,
        barsOpacity: Double = 1,
        fixedWidth: Double? = nil,
        height: Double = MusicSpectrum.boxHeight,
        accent: MusicTint
    ) {
        self.levels = levels
        self.played = played
        self.pulseIndex = pulseIndex
        self.showsPlayhead = showsPlayhead
        self.unplayedOpacity = unplayedOpacity
        self.barsOpacity = barsOpacity
        self.fixedWidth = fixedWidth
        self.height = height
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
        Canvas { [height] context, size in
            for (index, level) in levels.enumerated() {
                let width = fixedWidth ?? MusicSpectrum.width(forLevel: level)
                let rect = CGRect(
                    x: (size.width - width) / 2,
                    y: MusicSpectrum.barY(index, height: height),
                    width: width,
                    height: thickness
                )
                let isPlayed = index < played || index == pulseIndex
                let color = isPlayed ? accent.opacity(barsOpacity) : Color.white.opacity(unplayedOpacity * barsOpacity)
                context.fill(Path(roundedRect: rect, cornerRadius: thickness / 2), with: .color(color))
            }
            if showsPlayhead {
                let line = CGRect(x: 0, y: MusicSpectrum.playheadY(playedCount: played, height: height), width: size.width, height: 1)
                context.fill(Path(line), with: .color(Color.white.opacity(0.90)))
            }
        }
        .frame(width: MusicSpectrum.boxWidth, height: height)
        .accessibilityHidden(true)
    }
}

/// The player column's spectrum, which is also its progress bar: click or drag to seek (the seek lands on release),
/// hover to see where and when. The numbers come from `MusicSpectrum` and `MusicSpectrumDriver`; this only draws them
/// and passes the gestures on.
struct MusicSpectrumView: View {
    let state: MusicPlayerColumnState
    let track: MusicTrack?
    let service: MusicService?
    let spectrum: MusicSpectrumDriver

    @Environment(\.musicAccent) private var accent
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

    var body: some View {
        let played = state.showsProgress ? MusicSpectrum.playedCount(progress: progress) : 0
        let pulses = state == .playing && spectrum.pulse != nil
        MusicSpectrumCanvas(
            levels: levels,
            played: played,
            pulseIndex: pulses ? spectrum.pulseIndex : nil,
            showsPlayhead: state.showsPlayhead,
            unplayedOpacity: unplayedOpacity,
            barsOpacity: state.barsOpacity,
            fixedWidth: state.isEmptyLayout ? MusicPlayerColumnState.emptyBarWidth : nil,
            height: height,
            accent: accent
        )
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
                    .frame(width: MusicSpectrum.boxWidth, height: 1)
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
                    .position(x: MusicSpectrum.boxWidth / 2, y: min(max(lineY - 9, 8), height - 8))
            }
            .frame(width: MusicSpectrum.boxWidth, height: height, alignment: .topLeading)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}
