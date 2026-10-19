// Deci/Views/Music/MusicSegmentSwitch.swift
import SwiftUI

/// A small pill switch in the style of the Output / Input toggle in the Mixer popup, for "Home | Library" and the library
/// sections. A nil selection highlights nothing (search results or the queue are on screen).
/// Tapping a segment always reports it, even the selected one, so it can pop back to the root.
struct MusicSegmentSwitch<Value: Hashable>: View {
    struct Segment: Identifiable {
        let value: Value
        let title: String
        var icon: String?

        var id: Value { value }
    }

    let segments: [Segment]
    let selection: Value?
    var height: CGFloat = 22
    let onSelect: (Value) -> Void
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(segments) { segment in
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                        onSelect(segment.value)
                    }
                } label: {
                    HStack(spacing: 4) {
                        if let icon = segment.icon {
                            Image(systemName: icon)
                                .font(.system(size: 10, weight: .medium))
                                .symbolRenderingMode(.hierarchical)
                        }
                        Text(segment.title)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(selection == segment.value ? DesignTokens.Colors.textPrimary : DesignTokens.Colors.textTertiary)
                    .padding(.horizontal, DesignTokens.Spacing.sm)
                    .frame(height: height)
                    .background {
                        if selection == segment.value {
                            RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius)
                                .fill(DesignTokens.Colors.glassFillStrong)
                                .matchedGeometryEffect(id: "segment", in: namespace)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(segment.title)
                .accessibilityAddTraits(selection == segment.value ? .isSelected : [])
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius + 2)
                .fill(DesignTokens.Colors.glassFill)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius + 2)
                        .strokeBorder(DesignTokens.Colors.glassRowBorder, lineWidth: 0.5)
                )
        )
    }
}

extension MusicBrowseStore.Tab {
    static var segments: [MusicSegmentSwitch<Self>.Segment] {
        [
            .init(value: .home, title: "Home", icon: "house"),
            .init(value: .library, title: "Library", icon: "books.vertical"),
        ]
    }
}

extension MusicLibrarySection {
    var title: String {
        switch self {
        case .playlists: "Playlists"
        case .albums: "Albums"
        case .artists: "Artists"
        }
    }

    /// Shown when the list loaded empty.
    var emptyText: String {
        switch self {
        case .playlists: "No playlists yet."
        case .albums: "No albums yet."
        case .artists: "No artists yet."
        }
    }

    static var segments: [MusicSegmentSwitch<Self>.Segment] {
        allCases.map { .init(value: $0, title: $0.title) }
    }
}
