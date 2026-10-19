// Deci/Views/Music/MusicArtistLine.swift
import SwiftUI

/// Opens an artist's page from a name anywhere in the Music tab. The Music tab sets it; outside it the names
/// stay plain text.
private struct OpenMusicArtistKey: EnvironmentKey {
    static let defaultValue: (@MainActor (MusicCollection) -> Void)? = nil
}

extension EnvironmentValues {
    var openMusicArtist: (@MainActor (MusicCollection) -> Void)? {
        get { self[OpenMusicArtistKey.self] }
        set { self[OpenMusicArtistKey.self] = newValue }
    }
}

/// The artist line under a song. Every name that has an artist page is its own button; the commas, the "&" and
/// any name with no page stay plain text. With no links, or outside the Music tab, it is one plain line, the
/// same as before. The names are real buttons beside the row's own tap, so a click on a name opens the artist
/// and a click anywhere else on the row still plays.
struct MusicArtistLine: View {
    let artist: String
    let links: [MusicArtistLink]
    /// Set by a row whose own accessibility label already reads the whole line, so VoiceOver does not say it twice.
    var hidesPlainTextFromVoiceOver = false

    @Environment(\.openMusicArtist) private var openArtist

    var body: some View {
        let segments = openArtist == nil ? [] : MusicArtistSegment.split(artist, links: links)
        if let openArtist, segments.contains(where: { $0.link != nil }) {
            // The first names keep their room and the last ones give way, so a long line cuts off at its end.
            HStack(spacing: 0) {
                ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                    piece(segment, open: openArtist)
                        .layoutPriority(Double(segments.count - index))
                }
            }
        } else {
            plain(artist)
        }
    }

    @ViewBuilder
    private func piece(_ segment: MusicArtistSegment, open: @escaping @MainActor (MusicCollection) -> Void) -> some View {
        if let link = segment.link {
            MusicArtistButton(link: link, open: open)
        } else {
            plain(segment.text)
        }
    }

    private func plain(_ text: String) -> some View {
        Text(text)
            .font(DesignTokens.Typography.rowDescription)
            .foregroundStyle(DesignTokens.Colors.textSecondary)
            .lineLimit(1)
            .accessibilityHidden(hidesPlainTextFromVoiceOver)
    }
}

/// One artist name as a plain button: underlined under the pointer, with the hand cursor.
private struct MusicArtistButton: View {
    let link: MusicArtistLink
    let open: @MainActor (MusicCollection) -> Void
    @State private var isHovered = false

    var body: some View {
        Button {
            open(link.opener)
        } label: {
            Text(link.name)
                .font(DesignTokens.Typography.rowDescription)
                .foregroundStyle(isHovered ? DesignTokens.Colors.textPrimary : DesignTokens.Colors.textSecondary)
                .underline(isHovered)
                .lineLimit(1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(link.openLabel)
        // The system gives the cursor back when the name scrolls or closes under the pointer.
        .pointerStyle(.link)
        .onHover { isHovered = $0 }
    }
}
