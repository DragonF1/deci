// Deci/Views/Music/MusicPageComponents.swift
import SwiftUI

// The small views of the detail pages: the action buttons, the nav button, the playing indicator, the sort note and
// the tooltip of the full Home. The page itself is in MusicPageView.

// MARK: - Buttons

/// The action button of the page header, in the Mixer's small button look: 24 tall, a 6 pt radius, a quiet fill that
/// lightens under the pointer. A press shrinks it a little and a disabled one dims.
struct MusicPillButtonStyle: ButtonStyle {
    var fill: Color = MusicStyle.Palette.fillControl
    var horizontal: CGFloat = 8
    /// A button with a fixed width (the square pin).
    var width: CGFloat?

    static let height: CGFloat = 24

    func makeBody(configuration: Configuration) -> some View {
        MusicPillBody(configuration: configuration, style: self)
    }
}

private struct MusicPillBody: View {
    let configuration: ButtonStyle.Configuration
    let style: MusicPillButtonStyle

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius, style: .continuous)
        configuration.label
            .padding(.horizontal, style.horizontal)
            .frame(width: style.width, height: MusicPillButtonStyle.height)
            .background(shape.fill(style.fill))
            .overlay(shape.fill(Color.primary.opacity(isHovered && isEnabled ? 0.08 : 0)))
            .contentShape(shape)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.5)
            .animation(DesignTokens.Animation.hover, value: configuration.isPressed)
            .animation(DesignTokens.Animation.hover, value: isHovered)
            .onHover { isHovered = $0 }
    }
}

/// An icon and a label side by side, 4 apart: the content of an action button.
private struct MusicPillContent: View {
    let symbol: String
    var symbolWeight: Font.Weight = .medium
    let label: String
    var color: Color = MusicStyle.Palette.textPrimary

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: symbolWeight))
            Text(label)
                .musicText(MusicStyle.Typeface.button)
                .lineLimit(1)
        }
        .foregroundStyle(color)
    }
}

/// The accent-filled Play button. Its ink is white or black, whichever the accent (the system's, which the user picks)
/// can carry: white on the default blue, black on yellow.
struct MusicPlayPill: View {
    let title: String
    let action: () -> Void

    @Environment(\.self) private var environment

    private var ink: Color {
        let accent = MusicStyle.Palette.accent.resolve(in: environment)
        return MusicInk.onFill(red: Double(accent.red), green: Double(accent.green), blue: Double(accent.blue)).color
    }

    var body: some View {
        Button(action: action) {
            MusicPillContent(symbol: "play.fill", symbolWeight: .regular, label: "Play", color: ink)
        }
        .buttonStyle(MusicPillButtonStyle(fill: MusicStyle.Palette.accent, horizontal: 10))
        .accessibilityLabel("Play \(title)")
    }
}

struct MusicShufflePill: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            MusicPillContent(symbol: "shuffle", label: "Shuffle")
        }
        .buttonStyle(MusicPillButtonStyle())
        .accessibilityLabel("Shuffle \(title)")
    }
}

/// The Sort button: a plain SwiftUI menu of the sort keys, with a mark on the picked one that shows its direction.
/// Picking it again flips the direction. Once a key is picked the button is active and names it.
struct MusicSortPill: View {
    let sort: MusicPlaylistSort
    let onPick: (MusicSortField) -> Void

    var body: some View {
        let pill = MusicPagePills.sortPill(sort)
        Menu {
            ForEach(MusicSortField.allCases) { field in
                Button {
                    onPick(field)
                } label: {
                    if field == sort.field {
                        Label(field.label, systemImage: sort.isDefault ? "checkmark" : (sort.ascending ? "arrow.up" : "arrow.down"))
                    } else {
                        Text(field.label)
                    }
                }
            }
        } label: {
            MusicPillContent(symbol: pill.symbol, label: pill.label)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(MusicPillButtonStyle(fill: pill.isActive ? MusicStyle.Palette.accentFill : MusicStyle.Palette.fillControl))
        .fixedSize()
        .accessibilityLabel(pill.isActive ? "Sort: \(pill.label), \(sort.ascending ? "ascending" : "descending")" : "Sort")
    }
}

/// An artist's Pin to Home button. At the limit it dims to half and says why in a tooltip, on hover and on a click.
struct MusicPinHomePill: View {
    let title: String
    let isPinned: Bool
    /// Off while Home is full and this artist is not pinned yet.
    let isEnabled: Bool
    let toggle: () -> Void

    @State private var isHovered = false
    @State private var clickedAt: Date?

    var body: some View {
        Button {
            if isEnabled {
                toggle()
            } else {
                clickedAt = Date()
            }
        } label: {
            MusicPillContent(
                symbol: MusicPagePills.pinSymbol(isPinned: isPinned),
                label: MusicPagePills.pinLabel(isPinned: isPinned)
            )
        }
        .buttonStyle(MusicPillButtonStyle())
        // Dimmed, not disabled: a disabled button gets no click, and the tooltip answers a click too.
        .opacity(isEnabled ? 1 : 0.5)
        .onHover { isHovered = $0 }
        .overlay(alignment: .bottomLeading) {
            if !isEnabled, isHovered || clickedAt != nil {
                MusicTooltip(text: MusicPagePills.pinHelp(isPinned: isPinned, isEnabled: isEnabled))
                    .alignmentGuide(.bottom) { $0[.top] - 6 }
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .animation(DesignTokens.Animation.hover, value: isHovered || clickedAt != nil)
        // A click leaves the tooltip up for a moment after the pointer is gone.
        .task(id: clickedAt) {
            guard clickedAt != nil else { return }
            try? await Task.sleep(for: .seconds(2.5))
            if !Task.isCancelled { clickedAt = nil }
        }
        .accessibilityLabel(MusicPagePills.pinAccessibilityLabel(isPinned: isPinned, title: title))
        .accessibilityHint(isEnabled ? "" : MusicPagePills.pinHelp(isPinned: isPinned, isEnabled: false))
    }
}

/// The square pin of a playlist or album: it pins to Listen again.
struct MusicRoundPinButton: View {
    let title: String
    let isPinned: Bool
    let action: () -> Void

    var body: some View {
        let item: MusicTrackAction = isPinned ? .unpinFromListenAgain : .pinToListenAgain
        Button(action: action) {
            Image(systemName: isPinned ? "pin.fill" : "pin")
                .font(.system(size: 11))
                .foregroundStyle(MusicStyle.Palette.textPrimary)
        }
        .buttonStyle(MusicPillButtonStyle(horizontal: 0, width: MusicPillButtonStyle.height))
        .help(item.title)
        .accessibilityLabel("\(item.title): \(title)")
    }
}

/// A short note over the page: 226 wide, wrapping, on a Mixer popover chip.
struct MusicTooltip: View {
    let text: String

    static let width: CGFloat = 226

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(MusicStyle.Palette.textPrimary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(width: Self.width, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: MusicStyle.Radius.small, style: .continuous)
                    .fill(MusicStyle.Palette.toast.opacity(0.97))
            )
            .overlay(
                RoundedRectangle(cornerRadius: MusicStyle.Radius.small, style: .continuous)
                    .strokeBorder(DesignTokens.Colors.menuBorder, lineWidth: 0.5)
            )
            .shadow(color: MusicStyle.Shadow.glass.color, radius: MusicStyle.Shadow.glass.radius, y: MusicStyle.Shadow.glass.y)
    }
}

// MARK: - Sort note

/// "First 2000 songs", or a spinner and "Loading all songs": what a sort has not reached or is waiting for.
struct MusicSortNoteView: View {
    let note: MusicSortNote

    var body: some View {
        switch note {
        case .none:
            EmptyView()
        case .loadingAll:
            HStack(spacing: 6) {
                MusicSpinner(size: 11, lineWidth: 1.2)
                Text("Loading all songs")
                    .musicText(MusicStyle.Typeface.secondary)
                    .foregroundStyle(MusicStyle.Palette.textSecondary)
            }
            .accessibilityElement(children: .combine)
        case .limited(let count):
            Text(MusicSortNote.limitText(count))
                .musicText(MusicStyle.Typeface.secondary)
                .foregroundStyle(MusicStyle.Palette.textSecondary)
                .help("The sort covers only the start of this playlist.")
        }
    }
}

// MARK: - Nav

/// The back button of the detail page's nav row: the Mixer's 26 pt header button with a chevron.
struct MusicNavBackButton: View {
    let action: () -> Void

    static let size = MusicStyle.Size.headerButton

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.system(size: 12, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(isHovered ? DesignTokens.Colors.interactiveHover : DesignTokens.Colors.interactiveDefault)
                .frame(width: Self.size, height: Self.size)
                .background(
                    RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius, style: .continuous)
                        .fill(isHovered ? DesignTokens.Colors.hoverSurface : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(DesignTokens.Animation.hover, value: isHovered)
        .accessibilityLabel("Back")
        .help("Back")
    }
}

// MARK: - Playing indicator

/// Three bars of the track in the player: 3 wide, 2 apart, 13 by 12 overall, resting at 6, 12 and 9. While audio plays
/// each one moves between 3 and 12 at its own speed.
struct MusicPlayingBars: View {
    let isPlaying: Bool
    var color: Color = .primary

    static let restHeights: [CGFloat] = [6, 12, 9]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !isPlaying)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<3, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(color)
                        .frame(width: 3, height: height(of: index, at: time))
                }
            }
            .frame(width: 13, height: 12, alignment: .bottom)
        }
        .accessibilityHidden(true)
    }

    /// Between 3 and 12, each bar with its own period; the resting height while paused.
    private func height(of index: Int, at time: TimeInterval) -> CGFloat {
        guard isPlaying else { return Self.restHeights[index] }
        let periods: [Double] = [0.9, 0.7, 1.1]
        let wave = (sin(time * 2 * .pi / periods[index] + Double(index)) + 1) / 2
        return 3 + 9 * CGFloat(wave)
    }
}
