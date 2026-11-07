// Deci/Views/Music/MusicSongDataView.swift
import SwiftUI

/// The body of the Song data panel, under its header (`MusicSongDataHeader`): everything Deci knows about one song, in
/// blocks under small uppercase labels, as label and value rows with a hairline between them. It reads the store for
/// the song, its stream and its analysis row, and the like and download state of the song from the service.
struct MusicSongDataView: View {
    let service: MusicService

    private var store: MusicSongDataStore { service.songData }

    var body: some View {
        if let track = store.track {
            MusicSongDataBody(
                sections: MusicSongDataRows.sections(
                    track: track,
                    like: service.likes.status(of: track.videoId),
                    isDownloaded: service.downloads?.state(for: track.videoId) == .downloaded,
                    stream: store.stream,
                    analysis: store.analysis,
                    now: Date(),
                    music: store.music
                ) + [MusicSongDataRows.listeningSection(store.listening, now: Date())]
            )
            // Another song starts at the top.
            .id(track.videoId)
        }
    }
}

/// The sections as a scrolling column with a fade at its bottom, like the queue. A pure view of its rows, so it renders
/// without a service.
struct MusicSongDataBody: View {
    let sections: [MusicSongDataSection]
    /// False only for offscreen renders, where `ImageRenderer` does not draw a ScrollView's content.
    var scrolls: Bool = true

    private static let fadeHeight: CGFloat = 24

    var body: some View {
        Group {
            if scrolls {
                ScrollView { column }
                    .scrollIndicators(.never)
            } else {
                column.frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .mask(bottomFade)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var column: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
                MusicSongDataSectionView(section: section)
                    .padding(.top, index == 0 ? 0 : 16)
            }
        }
        .padding(.top, 10)
        .padding(.bottom, Self.fadeHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var bottomFade: some View {
        VStack(spacing: 0) {
            Rectangle().fill(.black)
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: Self.fadeHeight)
        }
    }
}

private struct MusicSongDataSectionView: View {
    let section: MusicSongDataSection

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(section.title.uppercased())
                .musicText(MusicStyle.Typeface.kicker)
                .foregroundStyle(MusicStyle.Palette.textMeta)
                .lineLimit(1)
                .padding(.horizontal, MusicStyle.Spacing.page)
                .accessibilityAddTraits(.isHeader)
            if let note = section.note {
                Text(note)
                    .musicText(MusicStyle.Typeface.secondary)
                    .foregroundStyle(MusicStyle.Palette.textMeta)
                    .padding(.horizontal, MusicStyle.Spacing.page)
                    .padding(.vertical, 6)
            }
            VStack(spacing: 0) {
                ForEach(Array(section.rows.enumerated()), id: \.offset) { index, row in
                    MusicSongDataRowView(row: row)
                        .musicRowHairline(index > 0)
                }
            }
        }
    }
}

private struct MusicSongDataRowView: View {
    let row: MusicSongDataRow

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(row.label)
                .musicText(MusicStyle.Typeface.secondary)
                .foregroundStyle(MusicStyle.Palette.textMeta)
                .lineLimit(1)
                .fixedSize()
            Spacer(minLength: 8)
            Text(row.value)
                .musicText(row.isNumeric ? MusicStyle.Typeface.mono : MusicStyle.Typeface.secondary)
                .foregroundStyle(MusicStyle.Palette.textRow)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .padding(.horizontal, MusicStyle.Spacing.page)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}
