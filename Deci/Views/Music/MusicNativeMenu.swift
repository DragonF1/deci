// Deci/Views/Music/MusicNativeMenu.swift
import SwiftUI

// The look of a native dark macOS menu, drawn by hand: the Music popup is a menu bar panel, which a real `Menu` or popover
// would dismiss, so its menus (the account card first) are overlays that wear this look. The pieces are plain views a
// menu is built from: the container, an item, a separator and a section head.

/// The numbers of the menu look.
nonisolated enum MusicNativeMenuMetrics {
    static let padding: CGFloat = 5
    static let cornerRadius: CGFloat = 8
    static let itemRadius: CGFloat = 4
    static let itemHeight: CGFloat = 22
    /// An item that carries an avatar: a little taller.
    static let accountItemHeight: CGFloat = 26
    /// The room an item keeps for its check, at its leading edge: a check in the menu's own rows, an icon or an avatar.
    static let checkSlot: CGFloat = 14
    static let itemGap: CGFloat = 6
    static let itemLeading: CGFloat = 4
    static let itemTrailing: CGFloat = 10
    static let separatorHeight: CGFloat = 11
    static let separatorInsetTop: CGFloat = 5
    static let separatorInsetSide: CGFloat = 9
}

/// The menu's body: a rounded dark card with a hairline border and a soft double shadow, `width` wide, with items
/// stacked at its inner padding.
struct MusicNativeMenu<Content: View>: View {
    let width: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: MusicNativeMenuMetrics.cornerRadius, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .padding(MusicNativeMenuMetrics.padding)
        .frame(width: width, alignment: .leading)
        .background(shape.fill(MusicStyle.Palette.menuFill))
        .overlay(shape.strokeBorder(MusicStyle.Palette.menuBorder, lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 12, x: 0, y: 8)
        .shadow(color: .black.opacity(0.30), radius: 0.5, x: 0, y: 0)
    }
}

/// One item of a menu. The pointer highlights it in the menu blue (its text goes to full white), and a click runs
/// `action`. A disabled item dims and answers nothing.
///
/// At the leading edge sits a 14 pt slot: `leading` fills it (a check, an icon, an avatar). Trailing text, such as a
/// shortcut or a tag, is quieter than the title.
struct MusicNativeMenuItem<Leading: View>: View {
    let title: String
    var trailing: String?
    var height: CGFloat = MusicNativeMenuMetrics.itemHeight
    var isEnabled = true
    /// What the trailing text is: a shortcut reads a little brighter when the item is highlighted.
    var trailingIsShortcut = false
    /// The width of the leading slot: the check's, or wider where an icon and an avatar share it.
    var leadingWidth: CGFloat = MusicNativeMenuMetrics.checkSlot
    @ViewBuilder let leading: Leading
    let action: () -> Void

    @State private var isHovered = false

    private var isHighlighted: Bool { isHovered && isEnabled }

    var body: some View {
        Button(action: action) {
            HStack(spacing: MusicNativeMenuMetrics.itemGap) {
                leading
                    .frame(width: leadingWidth, height: MusicNativeMenuMetrics.checkSlot)
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.white.opacity(isHighlighted ? 1.0 : 0.92))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let trailing {
                    Text(trailing)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.white.opacity(isHighlighted && trailingIsShortcut ? 0.80 : 0.45))
                        .lineLimit(1)
                }
            }
            .padding(.leading, MusicNativeMenuMetrics.itemLeading)
            .padding(.trailing, MusicNativeMenuMetrics.itemTrailing)
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: MusicNativeMenuMetrics.itemRadius, style: .continuous)
                    .fill(isHighlighted ? MusicStyle.Palette.menuHighlight : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .opacity(isEnabled ? 1 : 0.45)
        .disabled(!isEnabled)
        .accessibilityLabel(title)
    }
}

extension MusicNativeMenuItem where Leading == EmptyView {
    /// An item with nothing in the slot, so its title lines up with the titles of the items that have a check.
    init(
        title: String,
        trailing: String? = nil,
        height: CGFloat = MusicNativeMenuMetrics.itemHeight,
        isEnabled: Bool = true,
        trailingIsShortcut: Bool = false,
        action: @escaping () -> Void
    ) {
        self.init(
            title: title,
            trailing: trailing,
            height: height,
            isEnabled: isEnabled,
            trailingIsShortcut: trailingIsShortcut,
            leading: { EmptyView() },
            action: action
        )
    }
}

/// The check at the leading edge of the item that is on.
struct MusicNativeMenuCheck: View {
    var body: some View {
        Image(systemName: "checkmark")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.95))
            .accessibilityHidden(true)
    }
}

/// The line between two groups of items: 11 pt of room with a hairline in it.
struct MusicNativeMenuSeparator: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.10))
            .frame(height: 1)
            .padding(.horizontal, MusicNativeMenuMetrics.separatorInsetSide)
            .padding(.top, MusicNativeMenuMetrics.separatorInsetTop)
            .frame(height: MusicNativeMenuMetrics.separatorHeight, alignment: .top)
            .accessibilityHidden(true)
    }
}

/// A small heading over a group of items, in the quiet semi bold of a native menu.
struct MusicNativeMenuSectionHead: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.45))
            .lineLimit(1)
            .padding(.top, 3)
            .padding(.trailing, 10)
            .padding(.bottom, 3)
            .padding(.leading, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}
