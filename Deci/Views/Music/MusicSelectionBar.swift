// Deci/Views/Music/MusicSelectionBar.swift
import SwiftUI

/// What the rows and the bar call for a selection of songs: the selection itself, what it can do now, and what a pick
/// does. The Music tab sets it; outside it a song row has no selection.
struct MusicSelectionHandler: Sendable {
    let selection: MusicSongSelection
    let actions: @MainActor () -> [MusicSelectionAction]
    /// The words of an action's button or item, which say how many songs it is for.
    let title: @MainActor (MusicSelectionAction) -> String
    let perform: @MainActor (MusicSelectionAction) -> Void
}

private struct MusicSelectionHandlerKey: EnvironmentKey {
    static let defaultValue: MusicSelectionHandler? = nil
}

/// The list a song row sits in. A list sets it for its own rows; a row outside any list plays on every click.
private struct MusicSelectionScopeKey: EnvironmentKey {
    static let defaultValue: MusicSelectionScope? = nil
}

extension EnvironmentValues {
    var musicSelection: MusicSelectionHandler? {
        get { self[MusicSelectionHandlerKey.self] }
        set { self[MusicSelectionHandlerKey.self] = newValue }
    }

    var musicSelectionScope: MusicSelectionScope? {
        get { self[MusicSelectionScopeKey.self] }
        set { self[MusicSelectionScopeKey.self] = newValue }
    }
}

extension View {
    /// Makes the rows inside one list of songs, in the order they are shown. A range runs between rows of one list and
    /// the selection follows the list as it changes. `id` names the list across changes of its songs; a new `id` is a
    /// new list. Applied to the list's container, never to its rows.
    ///
    /// A list scrolling out of sight does not end its selection (it may sit in a lazy stack that tears it down off screen,
    /// and the songs are still picked). What ends it is the column moving on: see `MusicSearchNavigation.selectionContext`.
    func musicSelectionScope(id: String, tracks: [MusicTrack], isUpNext: Bool = false) -> some View {
        modifier(MusicSelectionScopeModifier(scope: MusicSelectionScope(id: id, tracks: tracks, isUpNext: isUpNext)))
    }
}

private struct MusicSelectionScopeModifier: ViewModifier {
    let scope: MusicSelectionScope
    @Environment(\.musicSelection) private var handler

    func body(content: Content) -> some View {
        content
            .environment(\.musicSelectionScope, scope)
            // A list that became another (a new id) ends the selection of the old one; one that only changed its songs
            // keeps the rows that are still there.
            .background {
                Color.clear
                    .onChange(of: scope) { _, new in handler?.selection.sync(new) }
                    .onChange(of: scope.id) { old, _ in handler?.selection.scopeEnded(old) }
            }
    }
}

/// A selection's actions as menu entries, each naming the number of songs, with a line between the blocks. The row's
/// right click menu, its "..." button and the bar's narrow form share it.
struct MusicSelectionMenuItems: View {
    let title: (MusicSelectionAction) -> String
    let actions: [MusicSelectionAction]
    let perform: (MusicSelectionAction) -> Void

    var body: some View {
        let groups = MusicSelectionAction.groups(of: actions)
        ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
            if index > 0 { Divider() }
            ForEach(group, id: \.self) { action in
                Button(title(action)) { perform(action) }
            }
        }
    }
}

/// What a row of a selection of two or more shows in place of its own song's menu.
struct MusicSelectionMenu {
    let count: Int
    let actions: [MusicSelectionAction]
    let title: (MusicSelectionAction) -> String
    let perform: (MusicSelectionAction) -> Void
}

/// The strip over the top of the right column while songs are selected: how many, a text button for each thing the
/// selection can do, and a button that clears it. It takes the header's place (the header stays mounted under it), so
/// nothing in the list moves when it appears. Where the buttons do not fit the column, they fold into one menu.
struct MusicSelectionBar: View {
    let navigation: MusicSearchNavigation

    @Environment(\.musicAccent) private var accent

    /// The strip is a little shorter than the header it covers.
    private static let barHeight: CGFloat = 28
    /// The page margin less the bar's own inset: the count lines up with the rows' covers.
    private static let innerPadding: CGFloat = MusicBrowseLayout.rowHoverInset
    /// Between the text buttons, and the least between the count, the buttons and the clear button.
    private static let buttonGap: CGFloat = 10
    private static let clearGap: CGFloat = 8

    var body: some View {
        let count = navigation.selection.count
        let actions = navigation.selectionActions
        ViewThatFits(in: .horizontal) {
            row(count: count, actions: actions, folded: false)
            row(count: count, actions: actions, folded: true)
        }
        .padding(.horizontal, Self.innerPadding)
        .frame(height: Self.barHeight)
        .background(
            RoundedRectangle(cornerRadius: MusicStyle.Radius.small, style: .continuous)
                .fill(accent.solid.opacity(MusicStyle.Opacity.accentFill))
        )
        // As wide as the rows' own highlight, so a picked row and the bar line up, and the buttons have the room.
        .padding(.horizontal, MusicStyle.Spacing.page - MusicBrowseLayout.rowHoverInset)
        .frame(height: MusicPopupMetrics.headerHeight)
        .padding(.top, MusicPopupMetrics.rightPaddingTop)
        .accessibilityElement(children: .contain)
        .onChange(of: count) { _, new in
            if new > 0 { AccessibilityNotification.Announcement(MusicSelectionBarText.count(new)).post() }
        }
    }

    private func row(count: Int, actions: [MusicSelectionAction], folded: Bool) -> some View {
        HStack(spacing: Self.clearGap) {
            Text(MusicSelectionBarText.count(count))
                .musicText(MusicStyle.Typeface.secondaryMedium)
                .foregroundStyle(MusicStyle.Palette.textHeading)
                .lineLimit(1)
                .fixedSize()
            Spacer(minLength: 0)
            HStack(spacing: Self.buttonGap) {
                if folded {
                    if !actions.isEmpty { foldedMenu(count: count, actions: actions) }
                } else {
                    ForEach(actions, id: \.self) { action in
                        Button { navigation.performSelection(action) } label: {
                            Text(action.title)
                                .musicText(MusicStyle.Typeface.button)
                                .foregroundStyle(MusicStyle.Palette.textHeading)
                                .lineLimit(1)
                                .fixedSize()
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(navigation.selectionTitle(action))
                    }
                }
            }
            clearButton
        }
    }

    private func foldedMenu(count: Int, actions: [MusicSelectionAction]) -> some View {
        Menu {
            MusicSelectionMenuItems(
                title: { navigation.selectionTitle($0) }, actions: actions, perform: { navigation.performSelection($0) }
            )
        } label: {
            HStack(spacing: 3) {
                Text("Actions")
                    .musicText(MusicStyle.Typeface.button)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(MusicStyle.Palette.textHeading)
            .fixedSize()
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel("Actions for \(count) selected songs")
    }

    private var clearButton: some View {
        Button { navigation.selection.clear() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(MusicStyle.Palette.textHeading)
                .frame(width: 18, height: 18)
                .background(Circle().fill(MusicStyle.Palette.chipSelected))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Clear selection")
        .help("Clear selection")
    }
}

/// The right column's header slot while a selection may cover it: the header stays mounted (a field keeps its words),
/// but while songs are selected it is hidden and the bar shows in its place. A field in the hidden header gives up the
/// keyboard when the bar comes, or it would go on editing a filter nobody can see.
struct MusicSelectionBarSlot<Header: View>: View {
    let navigation: MusicSearchNavigation?
    @ViewBuilder let header: Header

    var body: some View {
        let showsBar = navigation.map { $0.selection.count > 0 } ?? false
        header
            .opacity(showsBar ? 0 : 1)
            .allowsHitTesting(!showsBar)
            .accessibilityHidden(showsBar)
            .onChange(of: showsBar) { _, shows in
                if shows { Self.resignKeyboardFocus() }
            }
            .overlay(alignment: .top) {
                if showsBar, let navigation {
                    MusicSelectionBar(navigation: navigation)
                        .transition(.opacity)
                }
            }
            .animation(DesignTokens.Animation.quick, value: showsBar)
    }

    /// Ends editing in whatever field holds the keyboard (a focused field in the header, or a row under Full Keyboard
    /// Access); the popup stays the key window, so Escape and the arrow keys still reach it.
    private static func resignKeyboardFocus() {
        NSApp.keyWindow?.makeFirstResponder(nil)
    }
}
