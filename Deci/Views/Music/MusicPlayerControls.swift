// Deci/Views/Music/MusicPlayerControls.swift
import SwiftUI

// The two transport toggles the Up next header carries: Shuffle and Repeat. The player column draws its own transport.

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

/// Shuffle: 28 pt, in the accent colour while on. In the Up next header.
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

/// Repeat: 28 pt, in the accent colour while on; each press goes to the next loop mode. Same place as Shuffle.
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
