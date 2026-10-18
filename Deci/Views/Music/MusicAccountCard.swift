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

/// The 20pt round avatar at the end of the search row. Opens and closes the account card.
struct MusicAccountButton: View {
    let account: MusicAccount?
    let isOpen: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            MusicThumbnail(url: account?.photoURL, size: Self.size, circular: true, placeholder: "person.fill")
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

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.xs) {
            identity
            Divider()
                .overlay(DesignTokens.Colors.separator)
            action("Switch channel", symbol: "arrow.triangle.2.circlepath", isDisabled: isSwitchingChannel, perform: onSwitchChannel)
            action("Use another Google account", symbol: "person.badge.plus", isDisabled: isAddingAccount, perform: onUseAnotherAccount)
            action("Sign out", symbol: "rectangle.portrait.and.arrow.right", isDisabled: false, perform: onSignOut)
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
            MusicThumbnail(url: account?.photoURL, size: 36, circular: true, placeholder: "person.fill")
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

    private func action(_ title: String, symbol: String, isDisabled: Bool, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Image(systemName: symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                    .frame(width: 16)
                    .accessibilityHidden(true)
                Text(title)
                    .font(DesignTokens.Typography.rowName)
                    .foregroundStyle(DesignTokens.Colors.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .hoverableRow()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isDisabled ? 0.5 : 1)
        .disabled(isDisabled)
    }
}
