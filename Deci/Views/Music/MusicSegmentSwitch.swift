// Deci/Views/Music/MusicSegmentSwitch.swift
import SwiftUI

/// The segmented control of Library in the Mixer's pill style: text segments in a small pill, the picked one on a raised
/// fill that slides between them. A nil selection highlights nothing. Tapping a segment always reports it, even the
/// selected one.
struct MusicSegmentSwitch<Value: Hashable>: View {
    struct Segment: Identifiable {
        let value: Value
        let title: String
        var icon: String?

        var id: Value { value }
    }

    let segments: [Segment]
    let selection: Value?
    let onSelect: (Value) -> Void
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(segments) { segment in
                let isSelected = selection == segment.value
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
                            .musicText(MusicStyle.Typeface.secondaryMedium)
                    }
                    .foregroundStyle(isSelected ? DesignTokens.Colors.textPrimary : DesignTokens.Colors.textTertiary)
                    .padding(.horizontal, DesignTokens.Spacing.md)
                    .frame(height: MusicStyle.Size.headerButton)
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius)
                                .fill(DesignTokens.Colors.glassFillStrong)
                                .matchedGeometryEffect(id: "segment", in: namespace)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(segment.title)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
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
