// Deci/Views/Music/MusicPageComponents.swift
import SwiftUI

// The small views of the detail pages: the pills, the nav button, the playing indicator, the sort note and the tooltip
// of the full Home. The page itself is in MusicPageView.

// MARK: - Scrim colour

/// The colour the bottom scrim of the shell takes. A detail page sets its darker bottom colour here, so the fade the
/// lists dissolve into matches the page; with no page open the shell uses the base colour.
struct MusicScrimColorKey: PreferenceKey {
    static let defaultValue: Color? = nil

    static func reduce(value: inout Color?, nextValue: () -> Color?) {
        value = nextValue() ?? value
    }
}

// MARK: - Pills

/// The pill of the page's action row: 36 tall, a capsule, with the fill and the padding of its kind. The pointer
/// lightens it, a press shrinks it a little and a disabled one dims.
struct MusicPillButtonStyle: ButtonStyle {
    var fill: Color
    var leading: CGFloat = 14
    var trailing: CGFloat = 16
    /// A pill the design gives a fixed width (the artist's Play).
    var width: CGFloat?

    static let height: CGFloat = 36

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
        configuration.label
            .padding(.leading, style.leading)
            .padding(.trailing, style.trailing)
            .frame(width: style.width, height: MusicPillButtonStyle.height)
            .background(Capsule().fill(style.fill))
            .overlay(Capsule().fill(Color.white.opacity(isHovered && isEnabled ? 0.06 : 0)))
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.5)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .onHover { isHovered = $0 }
    }
}

/// An icon and a label side by side, 6 apart: the content of a pill.
private struct MusicPillContent: View {
    let symbol: String
    let symbolSize: CGFloat
    var symbolWeight: Font.Weight = .regular
    let label: String
    let labelStyle: MusicStyle.TextStyle
    var color: Color = .white

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: symbolSize, weight: symbolWeight))
            Text(label)
                .musicText(labelStyle)
                .lineLimit(1)
        }
        .foregroundStyle(color)
    }
}

struct MusicPlayPill: View {
    let fill: Color
    let ink: Color
    /// The artist's Play pill has a fixed width and no padding of its own.
    var width: CGFloat?
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            MusicPillContent(
                symbol: "play.fill", symbolSize: 14, label: "Play", labelStyle: MusicStyle.Typeface.button14, color: ink
            )
        }
        .buttonStyle(MusicPillButtonStyle(fill: fill, leading: 26, trailing: 28, width: width))
        .accessibilityLabel("Play \(title)")
    }
}

struct MusicShufflePill: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            MusicPillContent(
                symbol: "shuffle",
                symbolSize: 18,
                symbolWeight: .medium,
                label: "Shuffle",
                labelStyle: MusicStyle.Typeface.callout,
                color: .white.opacity(0.95)
            )
        }
        .buttonStyle(MusicPillButtonStyle(fill: MusicStyle.Palette.fillControl2))
        .accessibilityLabel("Shuffle \(title)")
    }
}

/// The Sort pill: a plain SwiftUI menu of the sort keys, with a mark on the picked one that shows its direction.
/// Picking it again flips the direction. Once a key is picked the pill is active and names it.
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
            MusicPillContent(
                symbol: pill.symbol,
                symbolSize: pill.symbolSize,
                label: pill.label,
                labelStyle: MusicStyle.Typeface.callout
            )
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(MusicPillButtonStyle(fill: pill.isActive ? MusicStyle.Palette.fillActive : MusicStyle.Palette.fillControl2))
        .fixedSize()
        .accessibilityLabel(pill.isActive ? "Sort: \(pill.label), \(sort.ascending ? "ascending" : "descending")" : "Sort")
    }
}

/// An artist's Pin to Home pill. At the limit it dims to half and says why in a tooltip, on hover and on a click.
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
                symbolSize: 15,
                label: MusicPagePills.pinLabel(isPinned: isPinned),
                labelStyle: MusicStyle.Typeface.button14
            )
        }
        .buttonStyle(MusicPillButtonStyle(fill: MusicStyle.Palette.fillControl3))
        // Dimmed, not disabled: a disabled pill gets no click, and the tooltip answers a click too.
        .opacity(isEnabled ? 1 : 0.5)
        .onHover { isHovered = $0 }
        .overlay(alignment: .bottomTrailing) {
            if !isEnabled, isHovered || clickedAt != nil {
                MusicTooltip(text: MusicPagePills.pinHelp(isPinned: isPinned, isEnabled: isEnabled))
                    .alignmentGuide(.bottom) { $0[.top] - 6 }
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.12), value: isHovered || clickedAt != nil)
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

/// The 36 pt round pin of a playlist or album: it pins to Listen again.
struct MusicRoundPinButton: View {
    let title: String
    let isPinned: Bool
    let action: () -> Void

    var body: some View {
        let item: MusicTrackAction = isPinned ? .unpinFromListenAgain : .pinToListenAgain
        Button(action: action) {
            Image(systemName: isPinned ? "pin.fill" : "pin")
                .font(.system(size: 17))
                .foregroundStyle(.white)
        }
        .buttonStyle(MusicPillButtonStyle(fill: MusicStyle.Palette.fillControl2, leading: 0, trailing: 0, width: MusicPillButtonStyle.height))
        .help(item.title)
        .accessibilityLabel("\(item.title): \(title)")
    }
}

/// A short note over the page: 226 wide, wrapping, on a dark chip.
struct MusicTooltip: View {
    let text: String

    static let width: CGFloat = 226

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Color.white.opacity(0.92))
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
                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5)
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
                    .musicText(MusicStyle.Typeface.caption11)
                    .foregroundStyle(MusicStyle.Palette.textSecondaryAlt)
            }
            .accessibilityElement(children: .combine)
        case .limited(let count):
            Text(MusicSortNote.limitText(count))
                .musicText(MusicStyle.Typeface.caption11)
                .foregroundStyle(MusicStyle.Palette.textSecondaryAlt)
                .help("The sort covers only the start of this playlist.")
        }
    }
}

// MARK: - Nav

/// The 32 pt glass circle of the detail page's nav row.
struct MusicNavBackButton: View {
    let action: () -> Void

    static let size = MusicStyle.Size.screenHeaderButton

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.system(size: 16))
                .foregroundStyle(Color.white.opacity(0.95))
                .frame(width: Self.size, height: Self.size)
                .musicGlass(in: Circle(), fill: MusicStyle.Palette.navButton, stroke: MusicStyle.Palette.lineGlass, shadow: nil)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Back")
        .help("Back")
    }
}

// MARK: - Playing indicator

/// Three bars of the track in the player: 3 wide, 2 apart, 13 by 12 overall, resting at 6, 12 and 9. While audio plays
/// each one moves between 3 and 12 at its own speed.
struct MusicPlayingBars: View {
    let isPlaying: Bool
    var color: Color = .white

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
