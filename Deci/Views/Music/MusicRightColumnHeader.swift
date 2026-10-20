// Deci/Views/Music/MusicRightColumnHeader.swift
import SwiftUI

/// The right column's own header, 32 pt tall: the Home and Library tabs, and at the trailing edge the magnifier and the
/// avatar. The magnifier opens the search field in their place: the tabs stay, the field fills the rest and the avatar
/// goes while it is open. What the field searches depends on the screen (`MusicSearchScope`). The avatar opens the
/// account card, which holds Settings; there is no gear.
///
/// Signed out, the tabs dim and answer nothing, there is no magnifier, and the avatar is a placeholder that opens the
/// card with Sign in and Settings. Lyrics and Up next wear their own headers (`MusicPanelHeaders`).
struct MusicRightColumnHeader: View {
    let service: MusicService?
    let navigation: MusicSearchNavigation?
    @Binding var isAccountCardOpen: Bool

    @Environment(\.musicAccent) private var accent

    private var isSignedIn: Bool { service?.authState == .signedIn && navigation != nil }

    var body: some View {
        let field = isSignedIn ? openField : nil
        HStack(spacing: field == nil ? 0 : 12) {
            HStack(spacing: 18) {
                ForEach(MusicHeaderTab.allCases, id: \.self) { tab in
                    MusicHeaderTabButton(
                        tab: tab,
                        isActive: navigation?.headerTab == tab,
                        isEnabled: isSignedIn
                    ) { navigation?.select(tab.browseTab) }
                }
            }
            .opacity(isSignedIn ? 1 : 0.35)
            if let field {
                field.frame(maxWidth: .infinity)
            } else {
                Spacer(minLength: 8)
                trailing
            }
        }
        .frame(height: MusicPopupMetrics.headerHeight)
        .padding(.horizontal, MusicPopupMetrics.rightPaddingSide)
        .padding(.top, MusicPopupMetrics.rightPaddingTop)
        // A new song's accent glides into the active tab's underline.
        .animation(.easeInOut(duration: 0.4), value: accent)
    }

    /// The field, while it is open on this screen.
    private var openField: MusicNavigationSearchField? {
        guard let service, let navigation, navigation.isFieldOpen else { return nil }
        return MusicNavigationSearchField(service: service, navigation: navigation)
    }

    private var trailing: some View {
        HStack(spacing: 10) {
            if isSignedIn, let navigation, navigation.scope.showsMagnifier {
                MusicSearchButton {
                    // The card hangs from the avatar, which the field replaces.
                    isAccountCardOpen = false
                    navigation.openField()
                }
            }
            if isSignedIn, let service {
                MusicAccountButton(account: service.account, isOpen: isAccountCardOpen) {
                    isAccountCardOpen.toggle()
                }
            } else {
                MusicSignedOutAvatarButton(isOpen: isAccountCardOpen) { isAccountCardOpen.toggle() }
            }
        }
    }
}

/// Home or Library: the label, and under the active one a short underline in the accent. Inactive tabs keep the room.
private struct MusicHeaderTabButton: View {
    let tab: MusicHeaderTab
    let isActive: Bool
    let isEnabled: Bool
    let action: () -> Void

    @Environment(\.musicAccent) private var accent

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Text(tab.title)
                    .musicText(isActive ? MusicStyle.Typeface.tabActive : MusicStyle.Typeface.tabInactive)
                    .foregroundStyle(Color.white.opacity(isActive ? 0.95 : 0.45))
                    .lineLimit(1)
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(isActive ? accent.solid : Color.clear)
                    .frame(width: 14, height: 2)
            }
            .padding(.top, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }
}

/// The magnifier: a 22 pt box that opens the search field.
struct MusicSearchButton: View {
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(Color.white.opacity(isHovered ? 0.85 : 0.55))
                .frame(width: MusicPopupMetrics.avatarSize, height: MusicPopupMetrics.avatarSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(DesignTokens.Animation.hover, value: isHovered)
        .accessibilityLabel("Search")
        .help("Search")
    }
}

/// The search field of the screen on top, wired to the navigation: its placeholder, its words and what Return does.
/// Return sends a YouTube Music search; a filter has nothing to send, it works as it is typed.
struct MusicNavigationSearchField: View {
    let service: MusicService
    let navigation: MusicSearchNavigation

    var body: some View {
        let scope = navigation.scope
        MusicSearchField(
            placeholder: scope.placeholder ?? "",
            text: Binding(get: { navigation.fieldQuery }, set: { navigation.fieldQuery = $0 }),
            isLoading: scope == .global && service.isSearching,
            onSubmit: scope == .global ? { navigation.submit() } : nil,
            onClear: { navigation.clearField() }
        )
    }
}
