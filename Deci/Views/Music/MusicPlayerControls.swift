// Deci/Views/Music/MusicPlayerControls.swift
import SwiftUI

// The controls the player screens share: a thin slider (the scrubber and the volume), the scrubber with its times, the
// transport, the volume row, the output control and the round buttons that open Lyrics and Up next.

/// The Mixer's slider look: a 4 pt capsule track with the accent level, and under the pointer a 12 pt knob. Dragging or clicking
/// reports the position; the owner decides what it means. The owner keeps the gesture state, so a drag that is
/// cancelled (the track changed, the window lost focus) lets go by itself, and passes what to show.
struct MusicSlider: View {
    /// The position to draw, 0...1: the finger's while dragging, else the real one.
    let fraction: Double
    let isDragging: Bool
    var isEnabled = true
    let dragFraction: GestureState<Double?>
    /// Called as the finger moves, from the first touch.
    var onChange: ((Double) -> Void)?
    /// Called when the finger lifts.
    var onEnd: ((Double) -> Void)?
    let label: String
    let valueText: String
    /// VoiceOver's increment and decrement.
    var adjust: ((AccessibilityAdjustmentDirection) -> Void)?

    @State private var isHovered = false

    static let trackHeight: CGFloat = 4
    static let knob: CGFloat = DesignTokens.Dimensions.sliderThumbSize
    /// The height of the area that takes the pointer: a thin track is hard to hit.
    static let hitHeight: CGFloat = 22

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let engaged = isEnabled && (isHovered || isDragging)
            let height = Self.trackHeight
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(MusicStyle.Palette.sliderTrack)
                    .frame(height: height)
                Capsule()
                    .fill(DesignTokens.Colors.accentPrimary)
                    .frame(width: MusicSliderGeometry.filledWidth(fraction: fraction, width: width), height: height)
                if engaged {
                    Circle()
                        .fill(.white)
                        .frame(width: Self.knob, height: Self.knob)
                        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                        .offset(x: MusicSliderGeometry.knobOffset(fraction: fraction, width: width, knob: Self.knob))
                        .transition(.opacity)
                }
            }
            .frame(width: width, height: proxy.size.height, alignment: .leading)
            .contentShape(Rectangle())
            .animation(DesignTokens.Animation.hover, value: engaged)
            .onHover { isHovered = $0 }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating(dragFraction) { value, state, _ in
                        state = MusicTimeFormat.fraction(x: value.location.x, width: width)
                    }
                    .onChanged { value in
                        onChange?(MusicTimeFormat.fraction(x: value.location.x, width: width))
                    }
                    .onEnded { value in
                        onEnd?(MusicTimeFormat.fraction(x: value.location.x, width: width))
                    }
            )
            .allowsHitTesting(isEnabled)
        }
        // The hit area is taller than the track, but the slider takes only the track's room in a layout.
        .frame(height: Self.hitHeight)
        .padding(.vertical, -(Self.hitHeight - Self.trackHeight) / 2)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(valueText)
        .accessibilityAdjustableAction { adjust?($0) }
    }
}

/// The scrubber: the song's progress as a slider, and under it the time played and the time left. Dragging previews the
/// position and the release seeks.
struct MusicPlayerScrubber: View {
    let service: MusicService
    /// Fraction under the finger while scrubbing; nil otherwise.
    @GestureState private var dragFraction: Double?

    /// How far VoiceOver's increment moves the song.
    private static let adjustStep: TimeInterval = 10

    var body: some View {
        let player = service.player
        let progress = MusicTimeFormat.progress(current: player.currentTime, duration: player.duration)
        let shown = dragFraction.map { $0 * player.duration } ?? player.currentTime
        VStack(spacing: 2) {
            MusicSlider(
                fraction: dragFraction ?? progress,
                isDragging: dragFraction != nil,
                isEnabled: player.duration > 0,
                dragFraction: $dragFraction,
                onEnd: { fraction in
                    service.seek(to: fraction * service.player.duration)
                },
                label: "Playback position",
                valueText: "\(Int(((dragFraction ?? progress) * 100).rounded())) percent",
                adjust: { direction in
                    let player = service.player
                    switch direction {
                    case .increment: service.seek(to: min(player.duration, player.currentTime + Self.adjustStep))
                    case .decrement: service.seek(to: max(0, player.currentTime - Self.adjustStep))
                    @unknown default: break
                    }
                }
            )

            HStack {
                Text(MusicTimeFormat.string(shown))
                Spacer(minLength: 8)
                Text(MusicTimeFormat.remaining(current: shown, duration: player.duration))
            }
            .musicText(MusicStyle.Typeface.caption)
            .monospacedDigit()
            .foregroundStyle(MusicStyle.Palette.textSecondary)
            .frame(height: 14)
            .accessibilityHidden(true)
        }
    }
}

/// One glyph of the transport: bare, in a box, with the Mixer's hover fill under the pointer.
private struct MusicTransportButton: View {
    let title: String
    let systemImage: String
    let fontSize: CGFloat
    var weight: Font.Weight = .regular
    let box: CGFloat
    var color: Color = MusicStyle.Palette.textPrimary
    var isSelected = false
    var isDisabled = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: fontSize, weight: weight))
                .foregroundStyle(color)
                .frame(width: box, height: box)
                .background(
                    RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius, style: .continuous)
                        .fill(isHovered && !isDisabled ? DesignTokens.Colors.hoverSurface : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { isHovered = $0 }
        .animation(DesignTokens.Animation.hover, value: isHovered)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help(title)
    }
}

/// Shuffle: 28 pt, in the accent colour while on. On Now Playing's transport and in the Up next header.
struct MusicShuffleButton: View {
    let service: MusicService

    var body: some View {
        MusicTransportButton(
            title: "Shuffle", systemImage: "shuffle", fontSize: 13, weight: .medium, box: MusicStyle.Size.headerButton + 2,
            color: service.isShuffleOn ? MusicStyle.Palette.accent : MusicStyle.Palette.textSecondary,
            isSelected: service.isShuffleOn
        ) { service.setShuffle(!service.isShuffleOn) }
    }
}

/// Repeat: 28 pt, in the accent colour while on; each press goes to the next loop mode. Same places as Shuffle.
struct MusicLoopButton: View {
    let service: MusicService

    var body: some View {
        MusicTransportButton(
            title: service.loopMode.label, systemImage: service.loopMode.systemImage, fontSize: 13, weight: .medium,
            box: MusicStyle.Size.headerButton + 2,
            color: service.loopMode != .off ? MusicStyle.Palette.accent : MusicStyle.Palette.textSecondary,
            isSelected: service.loopMode != .off
        ) { service.cycleLoopMode() }
    }
}

/// Previous, play or pause and next, and in the full size also Shuffle, Repeat and the song's "..." menu. The compact
/// size is the three middle buttons a little tighter, for the Lyrics and Up next screens.
struct MusicPlayerTransport: View {
    let service: MusicService
    var isCompact = false

    private var player: MusicPlayer { service.player }

    var body: some View {
        HStack(spacing: isCompact ? 28 : 18) {
            if !isCompact { MusicShuffleButton(service: service) }
            MusicTransportButton(
                title: "Previous", systemImage: "backward.fill", fontSize: 15, box: 30
            ) { service.previous() }
            playPause
            MusicTransportButton(
                title: "Next", systemImage: "forward.fill", fontSize: 15, box: 30,
                color: service.canGoNext ? MusicStyle.Palette.textPrimary : MusicStyle.Palette.textTertiary,
                isDisabled: !service.canGoNext
            ) { service.next() }
            if !isCompact {
                MusicLoopButton(service: service)
                if let track = player.nowPlaying {
                    MusicNowPlayingMenu(track: track, style: .player)
                        .frame(width: MusicTrackMoreButton.playerSize, height: MusicTrackMoreButton.playerSize)
                } else {
                    Color.clear.frame(width: MusicTrackMoreButton.playerSize, height: MusicTrackMoreButton.playerSize)
                }
            }
        }
    }

    private var playPause: some View {
        ZStack {
            if player.isLoading {
                MusicSpinner(size: 22, lineWidth: 2.4)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Loading")
            } else {
                MusicTransportButton(
                    title: player.isPlaying ? "Pause" : "Play",
                    systemImage: player.isPlaying ? "pause.fill" : "play.fill",
                    fontSize: 20, box: 36
                ) { service.togglePlayback() }
            }
        }
        .frame(width: 36, height: 36)
    }
}

/// The player's volume: the music row's own volume (the Mixer's Deci row), on the same curve, between a quiet and a loud
/// speaker.
struct MusicPlayerVolumeRow: View {
    let mixer: MusicMixerState
    @GestureState private var dragFraction: Double?

    /// How far VoiceOver's increment moves the slider.
    private static let adjustStep = 0.1

    var body: some View {
        let position = dragFraction ?? mixer.sliderPosition
        HStack(spacing: 8) {
            Image(systemName: "speaker.fill")
                .font(.system(size: 11))
                .foregroundStyle(MusicStyle.Palette.textSecondary)
                .accessibilityHidden(true)
            MusicSlider(
                fraction: position,
                isDragging: dragFraction != nil,
                dragFraction: $dragFraction,
                onChange: { mixer.setSliderPosition($0) },
                label: "Volume",
                valueText: "\(Int((position * 100).rounded())) percent",
                adjust: { direction in
                    switch direction {
                    case .increment: mixer.setSliderPosition(min(1, mixer.sliderPosition + Self.adjustStep))
                    case .decrement: mixer.setSliderPosition(max(0, mixer.sliderPosition - Self.adjustStep))
                    @unknown default: break
                    }
                }
            )
            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 11))
                .foregroundStyle(MusicStyle.Palette.textSecondary)
                .accessibilityHidden(true)
        }
        .frame(height: 16)
    }
}

/// The small button that opens Lyrics or Up next. It is lit while its panel is open, and pressing it then goes back to
/// Now Playing.
struct MusicPanelToggle: View {
    enum Panel {
        case lyrics
        case queue

        var title: String {
            switch self {
            case .lyrics: "Lyrics"
            case .queue: "Up next"
            }
        }

        var systemImage: String {
            switch self {
            case .lyrics: "quote.bubble"
            case .queue: "list.bullet"
            }
        }
    }

    let panel: Panel
    let isActive: Bool
    var weight: Font.Weight = .medium
    let action: () -> Void

    @State private var isHovered = false

    static let size: CGFloat = 28

    var body: some View {
        Button(action: action) {
            Image(systemName: panel.systemImage)
                .font(.system(size: 13, weight: weight))
                .foregroundStyle(isActive ? MusicStyle.Palette.textPrimary : MusicStyle.Palette.textSecondary)
                .frame(width: Self.size, height: Self.size)
                .background(
                    RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius, style: .continuous)
                        .fill(isActive ? DesignTokens.Colors.glassFillStrong : (isHovered ? DesignTokens.Colors.hoverSurface : Color.clear))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(DesignTokens.Animation.hover, value: isHovered)
        .accessibilityLabel(panel.title)
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .help(panel.title)
    }
}

/// The Lyrics or Up next toggle of a player screen, wired to the navigation. A toggle whose panel has nothing to show
/// keeps its room and draws nothing, so the controls between the toggles do not move.
struct MusicPanelButton: View {
    let panel: MusicPanelToggle.Panel
    let service: MusicService
    let navigation: MusicSearchNavigation
    var weight: Font.Weight = .medium

    var body: some View {
        switch panel {
        case .lyrics:
            slot(isAvailable: service.lyrics.track != nil, isActive: navigation.showsLyrics) { navigation.toggleLyrics() }
        case .queue:
            slot(isAvailable: !service.queue.isEmpty, isActive: navigation.showsQueue) { navigation.toggleQueue() }
        }
    }

    @ViewBuilder
    private func slot(isAvailable: Bool, isActive: Bool, action: @escaping () -> Void) -> some View {
        if isAvailable {
            MusicPanelToggle(panel: panel, isActive: isActive, weight: weight, action: action)
        } else {
            Color.clear.frame(width: MusicPanelToggle.size, height: MusicPanelToggle.size)
        }
    }
}

/// The row under Now Playing's volume: Lyrics on the left, where the sound goes in the middle (a menu of the output
/// devices) and Up next on the right.
struct MusicPlayerBottomRow: View {
    let service: MusicService
    let navigation: MusicSearchNavigation
    let mixer: MusicMixerState?
    let tint: MusicTint

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            MusicPanelButton(panel: .lyrics, service: service, navigation: navigation)
            Spacer(minLength: 8)
            if let mixer {
                MusicOutputMenu(mixer: mixer, tint: tint)
            }
            Spacer(minLength: 8)
            MusicPanelButton(panel: .queue, service: service, navigation: navigation)
        }
        .frame(height: MusicPanelToggle.size, alignment: .center)
    }
}

/// The output control: an AirPlay glyph beside the name of the device in use and the EQ profile on it. A click lists the
/// connected devices and the system default, with a check on the one in use.
struct MusicOutputMenu: View {
    let mixer: MusicMixerState
    let tint: MusicTint

    var body: some View {
        Menu {
            // The checks follow where the music really goes: with the chosen device gone, the default is checked.
            if mixer.isChosenDeviceMissing {
                Text("Output not found, using default")
            }
            Button {
                mixer.followDefaultDevice()
            } label: {
                checked("System default", isOn: mixer.outputDeviceUID == nil)
            }
            let devices = mixer.outputDevices
            if !devices.isEmpty { Divider() }
            ForEach(devices) { device in
                Button {
                    mixer.selectDevice(uid: device.uid)
                } label: {
                    checked(device.name, isOn: mixer.outputDeviceUID == device.uid)
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "airplayaudio")
                    .font(.system(size: 12))
                    .foregroundStyle(tint.light)
                Text(mixer.outputLabel)
                    .musicText(MusicStyle.Typeface.secondaryMedium)
                    .foregroundStyle(tint.light.opacity(0.95))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: 240)
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .frame(height: MusicPanelToggle.size - 4)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius, style: .continuous)
                    .fill(DesignTokens.Colors.pickerBackground)
            )
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel("Output")
        .accessibilityValue(mixer.outputLabel)
        .help("Choose where the music plays")
    }

    @ViewBuilder
    private func checked(_ title: String, isOn: Bool) -> some View {
        if isOn {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }
}

/// The part Lyrics and Up next share at the bottom: the scrubber, and a row with the Lyrics button, the compact transport
/// and the Up next button.
struct MusicPlayerFooter: View {
    let service: MusicService
    let navigation: MusicSearchNavigation

    var body: some View {
        VStack(spacing: 8) {
            MusicPlayerScrubber(service: service)
            HStack(spacing: 0) {
                MusicPanelButton(panel: .lyrics, service: service, navigation: navigation)
                Spacer(minLength: 8)
                MusicPlayerTransport(service: service, isCompact: true)
                Spacer(minLength: 8)
                MusicPanelButton(panel: .queue, service: service, navigation: navigation)
            }
            .frame(height: 36)
        }
    }
}
