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

    /// The line under the name on the card: the handle, or the channel kind while there is no handle.
    var subtitle: String? { handle ?? kind }

    /// What VoiceOver reads for the header: the name, the handle and the channel kind, including the "Your own channel"
    /// line that the card leaves out of the picture.
    var spokenLine: String {
        [title, handle, kind].compactMap { $0 }.joined(separator: ", ")
    }
}

/// How the card's action rows look, from which flow is running. Only one flow runs at a time:
/// its row turns into "Show sign-in window" (it brings the open window forward, for one lost behind
/// other windows), and the other row is off. Kept apart from the view so each combination is tested.
struct MusicAccountCardRows: Equatable {
    struct Row: Equatable {
        let title: String
        let isEnabled: Bool
    }

    let switchChannel: Row
    let addAccount: Row

    init(isSwitchingChannel: Bool, isAddingAccount: Bool) {
        switchChannel = Self.row("Switch channel\u{2026}", isRunning: isSwitchingChannel, otherIsRunning: isAddingAccount)
        addAccount = Self.row("Add account\u{2026}", isRunning: isAddingAccount, otherIsRunning: isSwitchingChannel)
    }

    static let signOut = Row(title: "Sign out", isEnabled: true)
    static let settings = Row(title: "Settings", isEnabled: true)
    static let showWindowTitle = "Show sign-in window"

    /// The signed-out card's one account row. The sign-in window, once open, is what finishes it: nothing to press.
    static func signIn(isSigningIn: Bool) -> Row {
        Row(title: "Sign in\u{2026}", isEnabled: !isSigningIn)
    }

    private static func row(_ title: String, isRunning: Bool, otherIsRunning: Bool) -> Row {
        // Both at once cannot happen; if it did, neither row is the one to bring a window forward.
        if otherIsRunning { return Row(title: title, isEnabled: false) }
        if isRunning { return Row(title: showWindowTitle, isEnabled: true) }
        return Row(title: title, isEnabled: true)
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

    /// The first letter alone, for the header's small avatar.
    static func letter(_ name: String) -> String {
        String(from(name).prefix(1))
    }
}

/// The round avatar at the trailing edge of the right column's header, 22 pt: a thin ring round the first letter of the
/// account's name (or round its photo), filled a little while the card is open. Opens and closes the account card.
struct MusicAccountButton: View {
    let account: MusicAccount?
    let isOpen: Bool
    let action: () -> Void

    @State private var model = MusicAvatarModel()

    private var letter: String {
        account.map { MusicAccountInitials.letter($0.name) } ?? ""
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                if let image = model.image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else if !letter.isEmpty {
                    Text(letter)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.90))
                } else {
                    Image(systemName: "person.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white.opacity(0.70))
                }
            }
            .frame(width: Self.size, height: Self.size)
            .clipShape(Circle())
            .background(Circle().fill(isOpen ? Color.white.opacity(0.14) : Color.clear))
            .overlay(Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: 1))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        // Starts over when the photo changes (the old one is dropped first) and is cancelled when the view leaves.
        .task(id: account?.photoURL) { await model.load(account?.photoURL) }
        .accessibilityLabel("Account")
        .accessibilityAddTraits(isOpen ? .isSelected : [])
        .help("Account")
    }

    static let size: CGFloat = MusicPopupMetrics.avatarSize
}

/// The avatar before there is a session: the same 22 pt ring with a person in it, on a faint fill. It opens the card
/// with Sign in and Settings.
struct MusicSignedOutAvatarButton: View {
    let isOpen: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "person.fill")
                .font(.system(size: 12))
                .foregroundStyle(Color.white.opacity(0.60))
                .frame(width: MusicAccountButton.size, height: MusicAccountButton.size)
                .background(Circle().fill(Color.white.opacity(isOpen ? 0.14 : 0.06)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Account")
        .accessibilityAddTraits(isOpen ? .isSelected : [])
        .help("Account")
    }
}

/// The round account photo, on the card. It loads through `MusicAvatarModel`, not `AsyncImage`: the photo URL must stay
/// out of the shared URL cache. While the photo loads, when it fails and when there is no URL, the avatar shows the
/// account's initials on the avatar gradient, or a person when the account has no name yet.
struct MusicAccountAvatar: View {
    let url: URL?
    let size: CGFloat
    var name: String?
    /// The initials' size when it is not the usual three eighths of the avatar.
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
                    Rectangle().fill(DesignTokens.Colors.deviceBadgeMonoFill)
                    Text(initials)
                        .font(.system(size: initialsSize ?? size * 0.375, weight: .semibold))
                        .foregroundStyle(Color.white)
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

/// The account card under the avatar, drawn as a native dark menu: who is signed in, the account actions, Settings and
/// Sign out. Plain values and closures in, so it draws without a service. The caller closes it on every action.
///
/// The app has no list of accounts to switch between: a session is one Google account, and a second one replaces it
/// ("Add account"). So the Switch account group holds the account in use, checked, and the channel picker.
struct MusicAccountCard: View {
    let account: MusicAccount?
    let isBrandChannel: Bool?
    let isSwitchingChannel: Bool
    let isAddingAccount: Bool
    let onSwitchChannel: () -> Void
    let onAddAccount: () -> Void
    let onSettings: () -> Void
    let onSignOut: () -> Void
    /// The account in use was picked again: nothing to do but close.
    let onDismiss: () -> Void

    static let width: CGFloat = 232
    static let avatarSize: CGFloat = 32
    static let rowAvatarSize: CGFloat = 18
    static let identityHeight: CGFloat = 46

    private var content: MusicAccountCardContent {
        MusicAccountCardContent(account: account, isBrandChannel: isBrandChannel)
    }

    private var rows: MusicAccountCardRows {
        MusicAccountCardRows(isSwitchingChannel: isSwitchingChannel, isAddingAccount: isAddingAccount)
    }

    var body: some View {
        MusicNativeMenu(width: Self.width) {
            identity
            MusicNativeMenuSeparator()
            MusicNativeMenuSectionHead(title: "Switch account")
            currentAccount
            MusicNativeMenuItem(
                title: rows.switchChannel.title,
                isEnabled: rows.switchChannel.isEnabled,
                action: onSwitchChannel
            )
            MusicNativeMenuSeparator()
            MusicNativeMenuItem(
                title: rows.addAccount.title,
                isEnabled: rows.addAccount.isEnabled,
                action: onAddAccount
            )
            MusicAccountSettingsItem(action: onSettings)
            MusicNativeMenuSeparator()
            MusicNativeMenuItem(title: MusicAccountCardRows.signOut.title, action: onSignOut)
        }
    }

    /// Who is signed in: the avatar, the name, and under it the handle (or the channel kind).
    private var identity: some View {
        HStack(spacing: 10) {
            MusicAccountAvatar(url: account?.photoURL, size: Self.avatarSize, name: account?.name, initialsSize: 13)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(content.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.95))
                    .lineLimit(1)
                if let subtitle = content.subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white.opacity(0.50))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(EdgeInsets(top: 6, leading: 10, bottom: 8, trailing: 10))
        .frame(height: Self.identityHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(content.spokenLine)
    }

    /// The account in use: the check in the slot, then its small avatar on the edge every other title starts on, its
    /// name, and a "Brand" tag on a brand channel.
    private var currentAccount: some View {
        MusicNativeMenuItem(
            title: content.title,
            trailing: isBrandChannel == true ? "Brand" : nil,
            height: MusicNativeMenuMetrics.accountItemHeight,
            leadingWidth: MusicNativeMenuMetrics.checkSlot + MusicNativeMenuMetrics.itemGap + Self.rowAvatarSize,
            leading: {
                HStack(spacing: MusicNativeMenuMetrics.itemGap) {
                    MusicNativeMenuCheck()
                        .frame(width: MusicNativeMenuMetrics.checkSlot)
                    MusicAccountAvatar(
                        url: account?.photoURL, size: Self.rowAvatarSize, name: account?.name, initialsSize: 8
                    )
                    .accessibilityHidden(true)
                }
            },
            action: onDismiss
        )
        .accessibilityAddTraits(.isSelected)
    }
}

/// The card shown before there is a session: Sign in and Settings.
struct MusicSignedOutCard: View {
    let isSigningIn: Bool
    let onSignIn: () -> Void
    let onSettings: () -> Void

    var body: some View {
        let signIn = MusicAccountCardRows.signIn(isSigningIn: isSigningIn)
        MusicNativeMenu(width: MusicAccountCard.width) {
            MusicNativeMenuItem(title: signIn.title, isEnabled: signIn.isEnabled, action: onSignIn)
            MusicNativeMenuSeparator()
            MusicAccountSettingsItem(action: onSettings)
        }
    }
}

/// Settings, with its gear in the check slot and the shortcut that opens it. The gear is the only way to Settings from
/// the Music popup, so the card carries it, signed in or not.
private struct MusicAccountSettingsItem: View {
    let action: () -> Void

    var body: some View {
        MusicNativeMenuItem(
            title: MusicAccountCardRows.settings.title,
            trailing: "\u{2318},",
            trailingIsShortcut: true,
            leading: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.85))
                    .accessibilityHidden(true)
            },
            action: action
        )
        .keyboardShortcut(",", modifiers: .command)
    }
}

/// The account card layer of the popup: an invisible catcher over everything (a tap anywhere closes the card, with no dim
/// behind it, like a menu) and the card hanging under the avatar. An overlay, not a Menu or popover: the popup is a menu
/// bar panel, which a nested popover would dismiss. It sits above the header, so the avatar's tap closes the card too.
/// Signed in it is the account card, otherwise the one with Sign in and Settings.
struct MusicAccountCardLayer: View {
    let service: MusicService?
    @Binding var isOpen: Bool
    let onOpenSettings: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { isOpen = false }
                .accessibilityHidden(true)

            card
                .padding(.top, MusicPopupMetrics.accountCardTop)
                .padding(.trailing, MusicPopupMetrics.accountCardTrailing)
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topTrailing)))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var card: some View {
        if let service, service.authState == .signedIn {
            MusicAccountCard(
                account: service.account,
                isBrandChannel: service.isBrandChannel,
                isSwitchingChannel: service.isSwitchingChannel,
                isAddingAccount: service.isAddingAccount,
                onSwitchChannel: {
                    isOpen = false
                    service.switchChannel()
                },
                onAddAccount: {
                    isOpen = false
                    service.useAnotherAccount()
                },
                onSettings: {
                    isOpen = false
                    onOpenSettings()
                },
                onSignOut: {
                    isOpen = false
                    service.signOut()
                },
                onDismiss: { isOpen = false }
            )
        } else {
            MusicSignedOutCard(
                isSigningIn: service?.authState == .signingIn,
                onSignIn: {
                    isOpen = false
                    service?.signIn()
                },
                onSettings: {
                    isOpen = false
                    onOpenSettings()
                }
            )
        }
    }
}
