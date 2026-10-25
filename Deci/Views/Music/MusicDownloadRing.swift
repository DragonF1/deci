// Deci/Views/Music/MusicDownloadRing.swift
import SwiftUI

/// The measures of the download glyphs at the trailing end of a song row: both are as tall as the Liked row's heart, so a
/// row looks the same whichever it wears.
nonisolated enum MusicDownloadGlyph {
    /// The glyph's box, in points.
    static let size: CGFloat = 12
    /// The ring's stroke.
    static let lineWidth: CGFloat = 1.5

    /// The share of the ring that is lit for a progress, held to 0 through 1. A value that is not a number draws nothing.
    static func litShare(of fraction: Double) -> Double {
        guard fraction.isFinite else { return 0 }
        return min(max(fraction, 0), 1)
    }

    /// What VoiceOver says for a song in this state; nil when the row has nothing to add.
    static func spokenState(_ state: MusicDownloadState) -> String? {
        switch state {
        case .downloaded: "downloaded"
        case .queued: "waiting to download"
        case .downloading: "downloading"
        case .failed: "Download failed"
        case .none: nil
        }
    }
}

/// A song row's mark for a song saved on this Mac: the filled arrow circle, in the tint of the row's other secondary
/// text.
struct MusicDownloadedGlyph: View {
    var body: some View {
        Image(systemName: "arrow.down.circle.fill")
            .font(.system(size: MusicDownloadGlyph.size))
            .foregroundStyle(MusicStyle.Palette.textMeta)
            .accessibilityHidden(true)
    }
}

/// A song row's mark for a download that ended in an error: an exclamation circle at the size and in the tint of the
/// downloaded glyph. The row's own accessibility text says "Download failed"; the menu offers Download again.
struct MusicDownloadFailedGlyph: View {
    var body: some View {
        Image(systemName: "exclamationmark.circle")
            .font(.system(size: MusicDownloadGlyph.size))
            .foregroundStyle(MusicStyle.Palette.textMeta)
            .accessibilityHidden(true)
    }
}

/// A small determinate ring for a song that waits for its download or is being saved: a faint full ring with an arc of the
/// saved share on it, from the top and clockwise. It does not animate; it redraws when the share changes.
struct MusicDownloadRing: View {
    /// 0 through 1. A queued song shows 0, the bare faint ring.
    let fraction: Double

    var body: some View {
        let inset = MusicDownloadGlyph.lineWidth / 2
        ZStack {
            Circle()
                .strokeBorder(MusicStyle.Palette.textMeta.opacity(0.4), lineWidth: MusicDownloadGlyph.lineWidth)
            Circle()
                .inset(by: inset)
                .trim(from: 0, to: MusicDownloadGlyph.litShare(of: fraction))
                .stroke(
                    MusicStyle.Palette.textMeta,
                    style: StrokeStyle(lineWidth: MusicDownloadGlyph.lineWidth, lineCap: .butt)
                )
                .rotationEffect(.degrees(-90))
        }
        .frame(width: MusicDownloadGlyph.size, height: MusicDownloadGlyph.size)
        .accessibilityHidden(true)
    }
}
