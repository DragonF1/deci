// Deci/Views/Music/MusicRightColumnHeader.swift
import SwiftUI

/// The right column's own header, 32 pt tall: the Home and Library tabs, and at the trailing edge the magnifier and the
/// avatar. Search is not a tab: the magnifier opens it, and the tab it was opened from stays lit. The avatar opens the
/// account card, which holds Settings; there is no gear.
///
/// Signed out, the tabs dim and answer nothing, there is no magnifier, and the avatar is a placeholder that opens the
/// card with Sign in and Settings.
struct MusicRightColumnHeader: View {
    let service: MusicService?
    let navigation: MusicSearchNavigation?
    @Binding var isAccountCardOpen: Bool

    @Environment(\.musicAccent) private var accent

    private var isSignedIn: Bool { service?.authState == .signedIn && navigation != nil }

    var body: some View {
        HStack(spacing: 0) {
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
            Spacer(minLength: 8)
            HStack(spacing: 10) {
                // Lyrics has no search to open: the magnifier is not there.
                if isSignedIn, let navigation, navigation.rightColumn != .lyrics {
                    MusicSearchButton(isOpen: navigation.isSearchOpen) { navigation.toggleSearch() }
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
        .frame(height: MusicPopupMetrics.headerHeight)
        .padding(.horizontal, MusicPopupMetrics.rightPaddingSide)
        .padding(.top, MusicPopupMetrics.rightPaddingTop)
        // A new song's accent glides into the active tab's underline.
        .animation(.easeInOut(duration: 0.4), value: accent)
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

/// The magnifier: a 22 pt box that opens search, and closes it again while it is open.
private struct MusicSearchButton: View {
    let isOpen: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Color.white.opacity(isOpen ? 0.90 : 0.55))
                .frame(width: MusicPopupMetrics.avatarSize, height: MusicPopupMetrics.avatarSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Search")
        .accessibilityAddTraits(isOpen ? .isSelected : [])
        .help("Search")
    }
}
