// Deci/Views/Music/MusicColumnMixerRows.swift
import SwiftUI

// The two rows at the foot of the player column, which stay live whatever the player is doing, because the Mixer's
// music row still works: its volume, and where the sound goes.

/// The music row's own volume (the Mixer's Deci row, on the same curve): a speaker, and a thin slider of the column's
/// width. A 2 pt track in white, filled up to a 10 pt thumb.
struct MusicColumnVolumeRow: View {
    let mixer: MusicMixerState
    @GestureState private var dragFraction: Double?

    static let thumb: CGFloat = 10
    static let trackHeight: CGFloat = 2
    /// The height of the area that takes the pointer: a thin track is hard to hit.
    static let hitHeight: CGFloat = 20

    /// How far VoiceOver's increment moves the slider.
    private static let adjustStep = 0.1

    var body: some View {
        let position = dragFraction ?? mixer.sliderPosition
        HStack(spacing: 8) {
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 11))
                .foregroundStyle(Color.white.opacity(0.60))
                .frame(width: 13)
                .accessibilityHidden(true)
            slider(position: position)
        }
        .frame(height: 13)
    }

    private func slider(position: Double) -> some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            // The fill ends at the thumb's centre, so the thumb never sits on a bare track.
            let thumbOffset = MusicSliderGeometry.knobOffset(fraction: position, width: width, knob: Self.thumb)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.18))
                    .frame(height: Self.trackHeight)
                Capsule()
                    .fill(Color.white.opacity(0.85))
                    .frame(width: thumbOffset + Self.thumb / 2, height: Self.trackHeight)
                Circle()
                    .fill(Color.white)
                    .frame(width: Self.thumb, height: Self.thumb)
                    .offset(x: thumbOffset)
            }
            .frame(width: width, height: proxy.size.height, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($dragFraction) { value, state, _ in
                        state = Self.fraction(x: value.location.x, width: width)
                    }
                    .onChanged { value in
                        mixer.setSliderPosition(Self.fraction(x: value.location.x, width: width))
                    }
            )
        }
        .frame(height: Self.hitHeight)
        .padding(.vertical, -(Self.hitHeight - 13) / 2)
        .accessibilityElement()
        .accessibilityLabel("Volume")
        .accessibilityValue("\(Int((position * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: mixer.setSliderPosition(min(1, mixer.sliderPosition + Self.adjustStep))
            case .decrement: mixer.setSliderPosition(max(0, mixer.sliderPosition - Self.adjustStep))
            @unknown default: break
            }
        }
    }

    /// Where a touch at `x` points along a track `width` wide, with the thumb's centre as the pointer: the thumb's
    /// travel is one thumb short of the track.
    static func fraction(x: CGFloat, width: CGFloat) -> Double {
        MusicTimeFormat.fraction(x: x - thumb / 2, width: width - thumb)
    }
}

/// The output control: a headphones glyph and the name of the device in use (with its EQ profile). A click lists the
/// connected devices and the system default, with a check on the one in use.
struct MusicColumnOutputChip: View {
    let mixer: MusicMixerState

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
            HStack(spacing: 6) {
                Image(systemName: "headphones")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.60))
                Text(mixer.outputLabel)
                    .musicText(MusicStyle.Typeface.columnLabel)
                    .foregroundStyle(Color.white.opacity(0.70))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: MusicPopupMetrics.playerColumnContentWidth, alignment: .leading)
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
