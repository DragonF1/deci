// Deci/Views/Music/MusicPageComponents.swift
import SwiftUI

// The small views of the detail pages: the Back row, the action pills, the sort chip and the sort note. The page itself
// is in MusicPageView, its header in MusicPageHeader.

// MARK: - Back

/// The Back row at the top of a page: a chevron and the name of the screen it goes back to, quiet until the pointer is on
/// it.
struct MusicBackRow: View {
    let label: String
    let action: () -> Void
    /// The tooltip, when "Back to <label>" does not read right (the playlist picker has no screen of its own to name).
    var help: String?

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                Text(label)
                    .musicText(MusicStyle.Typeface.chip)
                    .lineLimit(1)
            }
            .foregroundStyle(Color.white.opacity(isHovered ? MusicStyle.Opacity.row : MusicStyle.Opacity.idleControl))
            .frame(height: MusicBrowseLayout.backRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(DesignTokens.Animation.hover, value: isHovered)
        .accessibilityLabel("Back")
        .accessibilityHint(label)
        .help(help ?? "Back to \(label)")
    }
}

// MARK: - Pills

/// What every action pill does when pressed: it dims a little.
private struct MusicPillPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(DesignTokens.Animation.hover, value: configuration.isPressed)
    }
}

/// An icon and a label side by side, 5 apart, in a 26 pt capsule: the content of Play and Shuffle.
private struct MusicPillLabel: View {
    let symbol: String
    let label: String
    var iconOpacity = 1.0
    var labelOpacity = 1.0
    /// Replaces the white of the icon and the label (the ink on the Play fill).
    var ink: Color?

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(ink ?? Color.white.opacity(iconOpacity))
            Text(label)
                .musicText(MusicStyle.Typeface.button)
                .foregroundStyle(ink ?? Color.white.opacity(labelOpacity))
                .lineLimit(1)
        }
        .padding(.top, 5)
        .padding(.bottom, 5)
        .padding(.leading, 10)
        .padding(.trailing, 12)
        .frame(height: MusicBrowseLayout.actionsHeight)
    }
}

/// The white Play pill. Its ink goes by the fill, through `MusicInk`: black on this near white fill, taken as the
/// popup's own background so the pill reads as cut out of the page.
struct MusicPlayPill: View {
    let title: String
    let action: () -> Void

    /// The pill's fill: white at 95%, as the other bright controls of the popup.
    static let fillOpacity = 0.95

    /// The ink on the fill.
    static var ink: Color {
        let ink = MusicInk.onFill(red: fillOpacity, green: fillOpacity, blue: fillOpacity)
        return ink == .black ? MusicStyle.Palette.popupBackground : ink.color
    }

    var body: some View {
        Button(action: action) {
            MusicPillLabel(symbol: "play.fill", label: "Play", ink: Self.ink)
                .background(Capsule(style: .continuous).fill(Color.white.opacity(Self.fillOpacity)))
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(MusicPillPress())
        .accessibilityLabel("Play \(title)")
    }
}

/// The outlined Shuffle pill.
struct MusicShufflePill: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            MusicPillLabel(symbol: "shuffle", label: "Shuffle", iconOpacity: 0.80, labelOpacity: 0.85)
                .overlay(Capsule(style: .continuous).strokeBorder(MusicStyle.Palette.strokeButton, lineWidth: 1))
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(MusicPillPress())
        .accessibilityLabel("Shuffle \(title)")
    }
}

/// The round "..." button with the page's own actions. A plain SwiftUI menu, which draws as the native dark menu in the
/// popup's forced dark window: text only, like the song menu.
struct MusicPageMoreMenu: View {
    let title: String
    let items: [MusicPageMenuItem]
    let perform: (MusicPageMenuItem) -> Void

    var body: some View {
        Menu {
            ForEach(items, id: \.self) { item in
                Button(item.title) { perform(item) }
                    .disabled(!item.isEnabled)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.70))
                .frame(width: MusicBrowseLayout.actionsHeight, height: MusicBrowseLayout.actionsHeight)
                .overlay(Circle().strokeBorder(MusicStyle.Palette.strokeButton, lineWidth: 1))
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel("More actions for \(title)")
    }
}

// MARK: - Sort

/// The sort keys as menu entries, with a mark on the picked one that shows its direction. Picking it again flips it.
private struct MusicSortMenuItems: View {
    let sort: MusicPlaylistSort
    let onPick: (MusicSortField) -> Void

    var body: some View {
        ForEach(MusicSortField.allCases) { field in
            Button {
                onPick(field)
            } label: {
                if field == sort.field {
                    Label(field.label, systemImage: MusicSortChip.menuSymbol(for: sort))
                } else {
                    Text(field.label)
                }
            }
        }
    }
}

/// A playlist's sort chip, on the right of its "SONGS" kicker: "Sort: Default order", or the picked key with an arrow
/// that tells the direction.
struct MusicSortChipView: View {
    let sort: MusicPlaylistSort
    let onPick: (MusicSortField) -> Void

    var body: some View {
        let chip = MusicSortChip.resolve(sort)
        Menu {
            MusicSortMenuItems(sort: sort, onPick: onPick)
        } label: {
            HStack(spacing: 4) {
                if let symbol = chip.directionSymbol {
                    Image(systemName: symbol)
                        .font(.system(size: 9, weight: .semibold))
                }
                Text(chip.label)
                    .musicText(MusicStyle.Typeface.chip)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .opacity(0.8)
            }
            .foregroundStyle(Color.white.opacity(0.75))
            .padding(.top, 4)
            .padding(.bottom, 4)
            .padding(.leading, 11)
            .padding(.trailing, 9)
            .frame(height: MusicBrowseLayout.chipBarHeight)
            .overlay(Capsule(style: .continuous).strokeBorder(MusicStyle.Palette.strokeSoft, lineWidth: 1))
            .contentShape(Capsule(style: .continuous))
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel(chip.directionSymbol == nil ? "Sort" : "\(chip.label), \(sort.ascending ? "ascending" : "descending")")
    }
}

/// Liked music's small sort, on the right of its "SONGS" kicker: "Recently liked" at rest, else the picked key.
struct MusicLikedSortView: View {
    let sort: MusicPlaylistSort
    let onPick: (MusicSortField) -> Void

    var body: some View {
        Menu {
            MusicSortMenuItems(sort: sort, onPick: onPick)
        } label: {
            HStack(spacing: 3) {
                Text(MusicSortChip.likedLabel(sort))
                    .musicText(MusicStyle.Typeface.seeAll)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(MusicStyle.Palette.textMeta)
            .frame(height: MusicBrowseLayout.miniBarHeight)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel(sort.isDefault ? "Sort" : "Sort: \(sort.field.label), \(sort.ascending ? "ascending" : "descending")")
    }
}

/// The small uppercase "SONGS" over a page's list.
struct MusicSongsKicker: View {
    var body: some View {
        Text("SONGS")
            .musicText(MusicStyle.Typeface.kicker)
            .foregroundStyle(MusicStyle.Palette.textMeta)
            .accessibilityAddTraits(.isHeader)
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
                    .foregroundStyle(MusicStyle.Palette.textMeta)
            }
            .accessibilityElement(children: .combine)
        case .limited(let count):
            Text(MusicSortNote.limitText(count))
                .musicText(MusicStyle.Typeface.secondary)
                .foregroundStyle(MusicStyle.Palette.textMeta)
                .help("The sort covers only the start of this playlist.")
        }
    }
}
