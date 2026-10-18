// Deci/Views/Music/PopupTabSwitch.swift
import SwiftUI

enum PopupTab: String, CaseIterable, Identifiable {
    case mixer
    case music

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mixer: "Mixer"
        case .music: "Music"
        }
    }

    var icon: String {
        switch self {
        case .mixer: "slider.horizontal.3"
        case .music: "music.note"
        }
    }
}

/// "Mixer | Music" pill, built like the Output / Input toggle in the popup header.
struct PopupTabSwitch: View {
    @Binding var selection: PopupTab
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(PopupTab.allCases) { tab in
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                        selection = tab
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 11, weight: .medium))
                            .symbolRenderingMode(.hierarchical)
                        Text(tab.title)
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(selection == tab ? DesignTokens.Colors.textPrimary : DesignTokens.Colors.textTertiary)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background {
                        if selection == tab {
                            RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius)
                                .fill(DesignTokens.Colors.glassFillStrong)
                                .matchedGeometryEffect(id: "popupTab", in: namespace)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == tab ? .isSelected : [])
                .help(tab.title)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius + 3)
                .fill(DesignTokens.Colors.glassFill)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius + 3)
                        .strokeBorder(DesignTokens.Colors.glassRowBorder, lineWidth: 0.5)
                )
        )
    }
}
