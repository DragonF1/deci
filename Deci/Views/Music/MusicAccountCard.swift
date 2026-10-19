// Deci/Views/Music/MusicAccountCard.swift
import SwiftUI

/// What the account card says, from what is known about the session. Kept apart from the view so
/// each combination is tested.
struct MusicAccountCardContent: Equatable {
    /// The channel name, or "Signed in" until the account menu has answered or when it has no name.
    let title: String
    /// The @handle, when the account has one.
    let handle: String?
    /// Brand channel or own channel, once the session's channel kind is known.
    let kind: String?
    /// The badge under the name: only a brand channel wears one, an own channel shows nothing.
    let brandBadge: String?

    init(account: MusicAccount?, isBrandChannel: Bool?) {
        title = account?.name ?? "Signed in"
        handle = account?.handle
        kind = switch isBrandChannel {
        case true?: "Brand channel"
        case false?: "Your own channel"
        case nil: nil
        }
        brandBadge = isBrandChannel == true ? "Brand channel" : nil
    }

    /// What VoiceOver reads for the header: the name, the handle and the channel kind, including the "Your own channel"
    /// line that the card leaves out of the picture.
    var spokenLine: String {
        [title, handle, kind].compactMap { $0 }.joined(separator: ", ")
    }
}

/// How the card's action rows look, from which flow is running. Only one flow runs at a time:
/// its row turns into "Show sign-in window" (it brings the open window forward, for one lost behind
/// other windows) and keeps its icon and chevron, and the other row is off. Kept apart from the view so each
/// combination is tested.
struct MusicAccountCardRows: Equatable {
    struct Row: Equatable {
        let title: String
        let symbol: String
        let isEnabled: Bool
        /// A chevron at the trailing edge: the row opens a window.
        var hasChevron = false
        /// Drawn in the destructive colour, at full strength.
        var isDestructive = false
    }

    let switchChannel: Row
    let useAnotherAccount: Row

    init(isSwitchingChannel: Bool, isAddingAccount: Bool) {
        switchChannel = Self.row(
            "Switch channel", symbol: "arrow.left.arrow.right", hasChevron: true,
            isRunning: isSwitchingChannel, otherIsRunning: isAddingAccount
        )
        useAnotherAccount = Self.row(
            "Use another Google account", symbol: "person.badge.plus", hasChevron: false,
            isRunning: isAddingAccount, otherIsRunning: isSwitchingChannel
        )
    }

    static let signOut = Row(
        title: "Sign out", symbol: "rectangle.portrait.and.arrow.right", isEnabled: true, isDestructive: true
    )
    static let showWindowTitle = "Show sign-in window"

    private static func row(
        _ title: String, symbol: String, hasChevron: Bool, isRunning: Bool, otherIsRunning: Bool
    ) -> Row {
        // Both at once cannot happen; if it did, neither row is the one to bring a window forward.
        if otherIsRunning { return Row(title: title, symbol: symbol, isEnabled: false, hasChevron: hasChevron) }
        if isRunning { return Row(title: showWindowTitle, symbol: symbol, isEnabled: true, hasChevron: hasChevron) }
        return Row(title: title, symbol: symbol, isEnabled: true, hasChevron: hasChevron)
    }
}

/// The first letters of an account name, for the avatar while it has no photo: the first letter of the first and of
/// the last word, in capitals. Words with no letter or digit in them (an emoji, a dash) are skipped.
nonisolated enum MusicAccountInitials {
    static func from(_ name: String) -> String {
        let letters = name.split(whereSeparator: \.isWhitespace).compactMap { word in
            word.first(where: { $0.isLetter || $0.isNumber })
        }
        guard let first = letters.first else { return "" }
        guard letters.count > 1, let last = letters.last else { return String(first).uppercased() }
        return (String(first) + String(last)).uppercased()
    }
}

/// Where the account avatar sits, so the shell can leave it out of the dim behind the account card and hang the
/// card under it.
struct MusicAvatarAnchorKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

/// The 32 pt round avatar in a screen header. Opens and closes the account card.
struct MusicAccountButton: View {
    let account: MusicAccount?
    let isOpen: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            MusicAccountAvatar(url: account?.photoURL, size: Self.size, name: account?.name)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .anchorPreference(key: MusicAvatarAnchorKey.self, value: .bounds) { $0 }
        .accessibilityLabel("Account")
        .accessibilityAddTraits(isOpen ? .isSelected : [])
        .help("Account")
    }

    static let size: CGFloat = 32
}

/// The round account photo, in the header button and on the card. It loads through `MusicAvatarModel`,
/// not `AsyncImage`: the photo URL must stay out of the shared URL cache. While the photo loads, when it fails and
/// when there is no URL, the avatar shows the account's initials on the avatar gradient, or a person when the
/// account has no name yet.
struct MusicAccountAvatar: View {
    let url: URL?
    let size: CGFloat
    var name: String?
    /// The initials' size when it is not the usual three eighths of the avatar (the card's 56 pt avatar uses 20).
    var initialsSize: CGFloat?
    @State private var model = MusicAvatarModel()

    private var initials: String {
        name.map(MusicAccountInitials.from) ?? ""
    }

    var body: some View {
        Group {
            if let image = model.image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else if !initials.isEmpty {
                ZStack {
                    Rectangle().fill(MusicStyle.Palette.avatarGradient)
                    Text(initials)
                        .font(.system(size: initialsSize ?? size * 0.375, weight: .semibold))
                        .foregroundStyle(.white)
                }
            } else {
                MusicCoverPlaceholder(symbol: "person.fill", size: size)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        // Starts over when the URL changes (the old photo is dropped first) and is cancelled when the view leaves.
        .task(id: url) { await model.load(url) }
    }
}

/// The account card under the avatar: who is signed in, and the three things to do about it. A 240 pt glass card,
/// the header (56 pt avatar, name, handle, and a badge for a brand channel), then the two window rows and Sign out
/// between hairlines. Plain values and closures in, so it draws without a service. The caller closes it on every action.
struct MusicAccountCard: View {
    let account: MusicAccount?
    let isBrandChannel: Bool?
    let isSwitchingChannel: Bool
    let isAddingAccount: Bool
    let onSwitchChannel: () -> Void
    let onUseAnotherAccount: () -> Void
    let onSignOut: () -> Void

    static let width: CGFloat = 240
    static let avatarSize: CGFloat = 56

    private var content: MusicAccountCardContent {
        MusicAccountCardContent(account: account, isBrandChannel: isBrandChannel)
    }

    private var rows: MusicAccountCardRows {
        MusicAccountCardRows(isSwitchingChannel: isSwitchingChannel, isAddingAccount: isAddingAccount)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: MusicStyle.Radius.pill, style: .continuous)
        // Inside the 1 pt edge, as the mock lays it out.
        VStack(spacing: 0) {
            header
            divider
            VStack(spacing: 0) {
                MusicAccountActionRow(row: rows.switchChannel, perform: onSwitchChannel)
                MusicAccountActionRow(row: rows.useAnotherAccount, perform: onUseAnotherAccount)
            }
            .padding(.vertical, 6)
            divider
            MusicAccountActionRow(row: MusicAccountCardRows.signOut, perform: onSignOut)
                .padding(.vertical, 6)
        }
        .padding(1)
        .frame(width: Self.width)
        .clipShape(shape)
        .musicGlass(in: shape, fill: MusicStyle.Palette.cardGlassFill, stroke: MusicStyle.Palette.lineGlass, shadow: .glass)
    }

    private var divider: some View {
        Rectangle()
            .fill(MusicStyle.Palette.lineDivider)
            .frame(height: 1)
            .accessibilityHidden(true)
    }

    private var header: some View {
        HStack(spacing: 14) {
            MusicAccountAvatar(url: account?.photoURL, size: Self.avatarSize, name: account?.name, initialsSize: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(content.title)
                        .musicText(MusicStyle.Typeface.name17)
                        .foregroundStyle(MusicStyle.Palette.textPrimary)
                        .lineLimit(1)
                    if let handle = content.handle {
                        Text(handle)
                            .musicText(MusicStyle.Typeface.body13)
                            .foregroundStyle(MusicStyle.Palette.textSecondary)
                            .lineLimit(1)
                    }
                }
                if let badge = content.brandBadge {
                    Text(badge)
                        .musicText(MusicStyle.Typeface.badge10)
                        .foregroundStyle(Color.white.opacity(0.7))
                        .lineLimit(1)
                        .padding(.vertical, 2)
                        .padding(.horizontal, 6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .strokeBorder(MusicStyle.Palette.lineBadge, lineWidth: 1)
                        )
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(content.spokenLine)
    }
}

/// One 40 pt action row of the account card: an 18 pt icon, the label, and a trailing chevron on a row that opens a
/// window. The pointer lays the hover fill across the full width; a row that is off shows dimmed and takes no click.
private struct MusicAccountActionRow: View {
    let row: MusicAccountCardRows.Row
    let perform: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: perform) {
            HStack(spacing: 12) {
                Image(systemName: row.symbol)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(row.isDestructive ? MusicStyle.Palette.destructive : MusicStyle.Palette.textTile)
                    .frame(width: 18, height: 18)
                    .accessibilityHidden(true)
                Text(row.title)
                    .musicText(MusicStyle.Typeface.body13)
                    .foregroundStyle(row.isDestructive ? MusicStyle.Palette.destructive : MusicStyle.Palette.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if row.hasChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(MusicStyle.Palette.textQuaternary)
                        .frame(width: 16, height: 16)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 40)
            .background(isHovered && row.isEnabled ? MusicStyle.Palette.fillHover : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(DesignTokens.Animation.hover, value: isHovered)
        .opacity(row.isEnabled ? 1 : 0.5)
        .disabled(!row.isEnabled)
    }
}
