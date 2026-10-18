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

    init(account: MusicAccount?, isBrandChannel: Bool?) {
        title = account?.name ?? "Signed in"
        handle = account?.handle
        kind = switch isBrandChannel {
        case true?: "Brand channel"
        case false?: "Your own channel"
        case nil: nil
        }
    }
}

/// How the card's action rows look, from which flow is running. Only one flow runs at a time:
/// its row turns into "Show sign-in window" (it brings the open window forward, for one lost behind
/// other windows) and the other row is off. Kept apart from the view so each combination is tested.
struct MusicAccountCardRows: Equatable {
    struct Row: Equatable {
        let title: String
        let symbol: String
        let isEnabled: Bool
    }

    let switchChannel: Row
    let useAnotherAccount: Row

    init(isSwitchingChannel: Bool, isAddingAccount: Bool) {
        switchChannel = Self.row(
            "Switch channel", symbol: "arrow.triangle.2.circlepath", isRunning: isSwitchingChannel, otherIsRunning: isAddingAccount
        )
        useAnotherAccount = Self.row(
            "Use another Google account", symbol: "person.badge.plus", isRunning: isAddingAccount, otherIsRunning: isSwitchingChannel
        )
    }

    static let signOut = Row(title: "Sign out", symbol: "rectangle.portrait.and.arrow.right", isEnabled: true)
    static let showWindowTitle = "Show sign-in window"
    static let showWindowSymbol = "macwindow"

    private static func row(_ title: String, symbol: String, isRunning: Bool, otherIsRunning: Bool) -> Row {
        // Both at once cannot happen; if it did, neither row is the one to bring a window forward.
        if otherIsRunning { return Row(title: title, symbol: symbol, isEnabled: false) }
        if isRunning { return Row(title: showWindowTitle, symbol: showWindowSymbol, isEnabled: true) }
        return Row(title: title, symbol: symbol, isEnabled: true)
    }
}

/// The 20pt round avatar at the end of the search row. Opens and closes the account card.
struct MusicAccountButton: View {
    let account: MusicAccount?
    let isOpen: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            MusicAccountAvatar(url: account?.photoURL, size: Self.size)
                .overlay {
                    Circle()
                        .strokeBorder(
                            isOpen ? DesignTokens.Colors.accentPrimary : DesignTokens.Colors.eqCardBorder,
                            lineWidth: isOpen ? 1.5 : 0.5
                        )
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Account")
        .accessibilityAddTraits(isOpen ? .isSelected : [])
        .help("Account")
    }

    static let size: CGFloat = 20
}

/// The round account photo, in the search-row button and on the card. It loads through `MusicAvatarModel`,
/// not `AsyncImage`: the photo URL must stay out of the shared URL cache. The person placeholder shows while
/// it loads, when it fails and when there is no URL.
struct MusicAccountAvatar: View {
    let url: URL?
    let size: CGFloat
    @State private var model = MusicAvatarModel()

    var body: some View {
        Group {
            if let image = model.image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
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

/// The account card under the search row: who is signed in, and the three things to do about it.
/// Plain values and closures in, so it draws without a service. The caller closes it on every action.
struct MusicAccountCard: View {
    let account: MusicAccount?
    let isBrandChannel: Bool?
    let isSwitchingChannel: Bool
    let isAddingAccount: Bool
    let onSwitchChannel: () -> Void
    let onUseAnotherAccount: () -> Void
    let onSignOut: () -> Void

    static let width: CGFloat = 240

    private var content: MusicAccountCardContent {
        MusicAccountCardContent(account: account, isBrandChannel: isBrandChannel)
    }

    private var rows: MusicAccountCardRows {
        MusicAccountCardRows(isSwitchingChannel: isSwitchingChannel, isAddingAccount: isAddingAccount)
    }

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.xs) {
            identity
            Divider()
                .overlay(DesignTokens.Colors.separator)
            action(rows.switchChannel, perform: onSwitchChannel)
            action(rows.useAnotherAccount, perform: onUseAnotherAccount)
            action(MusicAccountCardRows.signOut, perform: onSignOut)
        }
        .padding(DesignTokens.Spacing.sm)
        .frame(width: Self.width)
        .background {
            // Opaque base so the lists behind never show through; the lifted-card fill and edge on top.
            RoundedRectangle(cornerRadius: DesignTokens.Dimensions.rowRadius)
                .fill(Color(nsColor: .windowBackgroundColor))
                .overlay {
                    RoundedRectangle(cornerRadius: DesignTokens.Dimensions.rowRadius)
                        .fill(DesignTokens.Colors.eqCardBackground)
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: DesignTokens.Dimensions.rowRadius)
                .strokeBorder(DesignTokens.Colors.eqCardBorder, lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 3)
    }

    private var identity: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            MusicAccountAvatar(url: account?.photoURL, size: 36)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(content.title)
                    .font(DesignTokens.Typography.rowName)
                    .foregroundStyle(DesignTokens.Colors.textPrimary)
                    .lineLimit(1)
                if let handle = content.handle {
                    Text(handle)
                        .font(DesignTokens.Typography.rowDescription)
                        .foregroundStyle(DesignTokens.Colors.textSecondary)
                        .lineLimit(1)
                }
                if let kind = content.kind {
                    Text(kind)
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.Colors.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DesignTokens.Spacing.xs)
        .padding(.vertical, DesignTokens.Spacing.xs)
        .accessibilityElement(children: .combine)
    }

    private func action(_ row: MusicAccountCardRows.Row, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Image(systemName: row.symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                    .frame(width: 16)
                    .accessibilityHidden(true)
                Text(row.title)
                    .font(DesignTokens.Typography.rowName)
                    .foregroundStyle(DesignTokens.Colors.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .hoverableRow()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(row.isEnabled ? 1 : 0.5)
        .disabled(!row.isEnabled)
    }
}
