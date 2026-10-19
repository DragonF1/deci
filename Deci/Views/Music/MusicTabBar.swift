// Deci/Views/Music/MusicTabBar.swift
import SwiftUI

/// The floating glass bar at the bottom of every browse screen: Home, Library and Search.
struct MusicTabBar: View {
    let selection: MusicBrowseStore.Tab
    /// The width of the whole bar; the three tabs share what is left inside its padding.
    let width: CGFloat
    /// Tapping a tab always reports it, the selected one too, so it can pop back to the tab's root.
    let onSelect: (MusicBrowseStore.Tab) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(MusicBrowseStore.Tab.allCases, id: \.self) { tab in
                MusicTabButton(
                    tab: tab,
                    isSelected: tab == selection,
                    width: MusicShellLayout.tabWidth(forBarWidth: width)
                ) {
                    onSelect(tab)
                }
            }
        }
        .padding(4)
        .frame(width: width, height: MusicStyle.Size.tabBarHeight)
        .musicGlass(in: RoundedRectangle(cornerRadius: MusicStyle.Radius.chrome, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Music tabs")
    }
}

private struct MusicTabButton: View {
    let tab: MusicBrowseStore.Tab
    let isSelected: Bool
    let width: CGFloat
    let action: () -> Void

    @State private var isHovered = false

    private var foreground: Color {
        isSelected ? MusicStyle.Palette.accent : MusicStyle.Palette.textTab
    }

    private var fill: Color {
        if isSelected { return MusicStyle.Palette.fillControl2 }
        return isHovered ? Color.white.opacity(0.06) : .clear
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: tab.symbol(selected: isSelected))
                    .font(.system(size: 20, weight: .medium))
                    .frame(height: 24)
                Text(tab.title)
                    .musicText(MusicStyle.Typeface.tab)
            }
            .foregroundStyle(foreground)
            .frame(width: width, height: MusicStyle.Size.tabHeight)
            .background(
                RoundedRectangle(cornerRadius: MusicStyle.Radius.tab, style: .continuous).fill(fill)
            )
            .contentShape(RoundedRectangle(cornerRadius: MusicStyle.Radius.tab, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
