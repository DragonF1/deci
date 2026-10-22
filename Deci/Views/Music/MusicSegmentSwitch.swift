// Deci/Views/Music/MusicSegmentSwitch.swift
import SwiftUI

/// The segmented control of Library: text segments in a small rounded track, the picked one on a raised fill that
/// slides between them. A nil selection highlights nothing. Tapping a segment always reports it, even the selected one.
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

    /// The track's padding and the gap between segments, and the radii of the track and of a segment.
    static var trackPadding: CGFloat { 2 }
    static var trackRadius: CGFloat { 7 }
    static var segmentRadius: CGFloat { 5 }

    var body: some View {
        HStack(spacing: Self.trackPadding) {
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
                            .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                    }
                    .foregroundStyle(Color.white.opacity(isSelected ? MusicStyle.Opacity.heading : MusicStyle.Opacity.idleControl))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: Self.segmentRadius, style: .continuous)
                                .fill(MusicStyle.Palette.segmentSelected)
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
        .padding(Self.trackPadding)
        .background(
            RoundedRectangle(cornerRadius: Self.trackRadius, style: .continuous)
                .fill(MusicStyle.Palette.segmentTrack)
        )
    }
}

extension MusicLibrarySection {
    var title: String {
        switch self {
        case .playlists: "Playlists"
        case .albums: "Albums"
        }
    }

    /// Shown when the list loaded empty.
    var emptyText: String {
        switch self {
        case .playlists: "No playlists yet."
        case .albums: "No albums yet."
        }
    }

    static var segments: [MusicSegmentSwitch<Self>.Segment] {
        allCases.map { .init(value: $0, title: $0.title) }
    }
}
