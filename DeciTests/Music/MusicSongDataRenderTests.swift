// DeciTests/Music/MusicSongDataRenderTests.swift
// Offscreen renders of the Song data panel, populated and empty, for review. No window is opened.

import AppKit
import SwiftUI
import Testing
@testable import Deci

@MainActor
@Suite("Music song data render")
struct MusicSongDataRenderTests {
    static let outDir = "/Volumes/Storage/_test/deci-songdata"

    private let now = Date()

    private var track: MusicTrack {
        MusicSamples.track("dQw4w9WgXcQ", title: "Never Gonna Give You Up", artist: "Rick Astley", seconds: 213, album: "Whenever You Need Somebody")
    }

    private var stream: ResolvedStream {
        ResolvedStream(
            videoId: "dQw4w9WgXcQ", url: URL(string: "https://example.com/a")!, itag: 251, durationSeconds: 213,
            expiresAt: .distantFuture, playbackTrackingURL: nil, viewCount: 1_500_000_000, httpHeaders: [:],
            audioCodec: "opus", loudnessDb: -6.2, perceptualLoudnessDb: -7.5, bitrate: 130_000, audioSampleRate: 48_000,
            audioChannels: 2, contentLength: 3_500_000
        )
    }

    private var analysis: MusicAnalysis {
        MusicAnalysis(
            videoId: "dQw4w9WgXcQ", version: 1, format: .init(codec: "opus", itag: 251, durationMs: 213_000),
            analyzedAt: now.addingTimeInterval(-2 * 86_400), source: .playbackCache, silenceStart: 0.8, silenceEnd: 211.8,
            introEnd: 12, outroStart: 195, integratedLUFS: -14.2, samplePeakDb: -0.3, introLUFS: -15, outroLUFS: -16.5,
            energy: [], youtubeLoudnessDb: nil, youtubePerceptualLoudnessDb: nil
        )
    }

    private func panel(_ sections: [MusicSongDataSection]) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Song data").musicText(MusicStyle.Typeface.heading).foregroundStyle(MusicStyle.Palette.textHeading)
                Text("Never Gonna Give You Up").musicText(MusicStyle.Typeface.secondary).foregroundStyle(MusicStyle.Palette.textMeta)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, MusicStyle.Spacing.page)
            .frame(height: 32)
            MusicSongDataBody(sections: sections, scrolls: false)
        }
        .frame(width: 340, height: 960)
        .background(MusicStyle.Palette.popupBackground)
        .environment(\.colorScheme, .dark)
    }

    private func render(_ view: some View, name: String, dir: String = outDir) throws -> NSImage {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try png.write(to: URL(fileURLWithPath: "\(dir)/\(name)"))
        return image
    }

    @Test("the populated and the empty panel render at the same size")
    func panels() throws {
        let full = MusicSongDataRows.sections(
            track: track, like: .like, isDownloaded: false, stream: .loaded(stream), analysis: analysis, now: now
        )
        let empty = MusicSongDataRows.sections(
            track: track, like: nil, isDownloaded: false, stream: .offline, analysis: nil, now: now
        )
        let populated = try render(panel(full), name: "song-data-populated.png")
        let bare = try render(panel(empty), name: "song-data-empty.png")
        #expect(populated.size.width > 0)
        #expect(populated.size == bare.size)
        #expect(FileManager.default.fileExists(atPath: "\(Self.outDir)/song-data-populated.png"))
        #expect(FileManager.default.fileExists(atPath: "\(Self.outDir)/song-data-empty.png"))
    }

    @Test("the populated panel with YOUR LISTENING renders, and a song with no row renders the same size")
    func listeningPanel() throws {
        let dir = "/Volumes/Storage/_test/deci-p4"
        let played = MusicListeningEntry(
            videoId: "dQw4w9WgXcQ", playCount: 14, totalSeconds: 3_725,
            firstPlayed: now.addingTimeInterval(-40 * 86_400), lastPlayed: now.addingTimeInterval(-3 * 3_600)
        )
        let base = MusicSongDataRows.sections(
            track: track, like: .like, isDownloaded: false, stream: .loaded(stream), analysis: analysis, now: now
        )
        let withRow = base + [MusicSongDataRows.listeningSection(played, now: now)]
        let withoutRow = base + [MusicSongDataRows.listeningSection(nil, now: now)]
        #expect(withRow.last?.title == "Your listening")
        #expect(withRow.last?.rows.count == 4)
        let image = try render(panel(withRow), name: "song-data-listening.png", dir: dir)
        let bare = try render(panel(withoutRow), name: "song-data-listening-none.png", dir: dir)
        #expect(image.size.width > 0)
        #expect(image.size == bare.size)
        #expect(FileManager.default.fileExists(atPath: "\(dir)/song-data-listening.png"))
    }
}
