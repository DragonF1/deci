// Deci/Views/Music/MusicSegmentSwitch.swift
import SwiftUI

/// The segmented control of Library: equal segments in a track, the picked one raised. A nil selection highlights
/// nothing. Tapping a segment always reports it, even the selected one.
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
        HStack(spacing: 0) {
            ForEach(segments) { segment in
                let isSelected = selection == segment.value
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
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
                            .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                    }
                    .foregroundStyle(isSelected ? Color.white : MusicStyle.Palette.textSecondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 26)
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .fill(MusicStyle.Palette.fillSelected)
                                .shadow(
                                    color: MusicStyle.Shadow.segment.color,
                                    radius: MusicStyle.Shadow.segment.radius,
                                    y: MusicStyle.Shadow.segment.y
                                )
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
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(MusicStyle.Palette.fillTrack))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(MusicStyle.Palette.lineHairline, lineWidth: 1))
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
