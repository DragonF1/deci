// Deci/Views/Music/MusicRightColumnHeader.swift
import SwiftUI

/// The right column's own header, 32 pt tall: the Home, Library and History tabs, and at the trailing edge Home's
/// refresh (on Home's root only), the magnifier and the avatar. The magnifier opens the search field in their place:
/// the tabs stay, the field fills the rest and the avatar goes while it is open. Where the three tabs would leave the
/// field narrower than `MusicPopupMetrics.openFieldMinWidth`, only the active tab stays beside it. What the field
/// searches depends on the screen (`MusicSearchScope`). The avatar opens the account card, which holds Settings; there
/// is no gear.
///
/// The field slides out of the magnifier's place when it opens and folds back into it when it closes (a plain fade with
/// Reduce Motion on). The tabs swap with no transition, so a label never fades or moves while the field grows.
///
/// Signed out, the tabs dim and answer nothing, there is no magnifier, and the avatar is a placeholder that opens the
/// card with Sign in and Settings. Lyrics and Up next wear their own headers (`MusicPanelHeaders`).
struct MusicRightColumnHeader: View {
    let service: MusicService?
    let navigation: MusicSearchNavigation?
    @Binding var isAccountCardOpen: Bool

    @Environment(\.musicAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isSignedIn: Bool { service?.authState == .signedIn && navigation != nil }

    /// The field is showing in the header, which is what the slide follows.
    private var isFieldShowing: Bool { isSignedIn && navigation?.isFieldOpen == true }

    /// How long the field takes to slide out or back.
    static let slideDuration = 0.2

    /// Between the trailing buttons, which the field replaces.
    private static let trailingSpacing: CGFloat = 10

    var body: some View {
        Group {
            if let field = isSignedIn ? openField : nil {
                // All three tabs beside the field while that leaves it its base width; where they do not, only the
                // active tab stays, so no label is cut and the field keeps its room. The rest return when it closes.
                ViewThatFits(in: .horizontal) {
                    openRow(tabs: MusicHeaderTab.allCases, field: field, fieldMinWidth: MusicPopupMetrics.openFieldMinWidth)
                    openRow(tabs: [navigation?.headerTab ?? .home], field: field, fieldMinWidth: nil)
                }
            } else {
                HStack(spacing: 0) {
                    tabs(MusicHeaderTab.allCases)
                    Spacer(minLength: 8)
                    trailing
                }
            }
        }
        .frame(height: MusicPopupMetrics.headerHeight)
        .padding(.horizontal, MusicPopupMetrics.rightPaddingSide)
        .padding(.top, MusicPopupMetrics.rightPaddingTop)
        // A new song's accent glides into the active tab's underline.
        .animation(.easeInOut(duration: 0.4), value: accent)
        .animation(.easeOut(duration: Self.slideDuration), value: isFieldShowing)
    }

    /// The field's entrance and exit.
    private var fieldTransition: AnyTransition {
        reduceMotion ? .opacity : AnyTransition(MusicFieldSlide(originInset: Self.magnifierInset))
    }

    /// How far the magnifier's centre sits from the trailing edge, where the avatar is next to it.
    private static var magnifierInset: CGFloat {
        MusicPopupMetrics.avatarSize + trailingSpacing + MusicPopupMetrics.avatarSize / 2
    }

    private func openRow(tabs shown: [MusicHeaderTab], field: some View, fieldMinWidth: CGFloat?) -> some View {
        HStack(spacing: 12) {
            tabs(shown)
            field
                .frame(minWidth: fieldMinWidth, idealWidth: fieldMinWidth, maxWidth: .infinity)
                .transition(fieldTransition)
        }
    }

    private func tabs(_ shown: [MusicHeaderTab]) -> some View {
        HStack(spacing: 18) {
            ForEach(shown, id: \.self) { tab in
                MusicHeaderTabButton(
                    tab: tab,
                    isActive: navigation?.headerTab == tab,
                    isEnabled: isSignedIn
                ) { navigation?.select(tab.browseTab) }
            }
        }
        .opacity(isSignedIn ? 1 : 0.35)
        // The same labels sit in the same place with the field open or closed, so they swap with no fade.
        .transition(.identity)
    }

    /// The field, while it is open on this screen.
    private var openField: MusicNavigationSearchField? {
        guard let service, let navigation, navigation.isFieldOpen else { return nil }
        return MusicNavigationSearchField(service: service, navigation: navigation)
    }

    private var trailing: some View {
        HStack(spacing: Self.trailingSpacing) {
            if isSignedIn, let service, let navigation, navigation.showsHomeRefresh {
                MusicRefreshButton(isRefreshing: service.browse.isRefreshingHome || service.browse.home == .loading) {
                    service.browse.refreshHome()
                }
            }
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

/// The open field's entrance and exit: it is uncovered from the magnifier's place outward to both sides, and covered
/// again toward that place on the way out, fading as it goes. The field is only masked, never squeezed, so its words
/// keep their shape. At rest the mask reaches past the field, so it clips nothing.
private struct MusicFieldSlide: Transition {
    /// How far from the field's trailing edge the magnifier's centre sits.
    let originInset: CGFloat

    func body(content: Content, phase: TransitionPhase) -> some View {
        let shown = phase.isIdentity
        content
            .mask {
                GeometryReader { proxy in
                    let origin = max(proxy.size.width - originInset, 0)
                    let left = shown ? -2 : origin
                    let right = shown ? proxy.size.width + 2 : origin
                    Rectangle()
                        .frame(width: right - left, height: proxy.size.height)
                        .offset(x: left)
                }
            }
            .opacity(shown ? 1 : 0)
    }
}

/// Home, Library or History: the label, and under the active one a short underline in the accent. Inactive tabs keep the room.
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

/// Home's refresh: asks YouTube Music for new suggestions while the shelves stay up. A spinner takes the arrow's place
/// while the new shelves load.
struct MusicRefreshButton: View {
    let isRefreshing: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            ZStack {
                if isRefreshing {
                    MusicSpinner(size: 15, lineWidth: 1.5, color: Color.white.opacity(0.75))
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(Color.white.opacity(isHovered ? 0.85 : 0.55))
                }
            }
            .frame(width: MusicPopupMetrics.avatarSize, height: MusicPopupMetrics.avatarSize)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isRefreshing)
        .onHover { isHovered = $0 }
        .animation(DesignTokens.Animation.hover, value: isHovered)
        .accessibilityLabel(isRefreshing ? "Refreshing Home" : "Refresh Home")
        .help("Refresh Home")
    }
}

/// The search field of the screen on top, wired to the navigation: its placeholder, its words and what Return does.
/// A YouTube Music search goes out a moment after typing stops, or at once on Return; a filter has nothing to send, it
/// works as it is typed.
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
