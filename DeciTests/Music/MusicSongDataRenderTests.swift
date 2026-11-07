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

    private var facts: MusicSongFacts {
        var facts = MusicSongFacts(fetchedAt: now)
        facts.isrc = "GBAYE8700001"
        facts.bpm = 113
        facts.key = 8
        facts.mode = 1
        facts.energy = 0.82
        facts.danceability = 0.73
        facts.valence = 0.92
        facts.acousticness = 0.15
        facts.instrumentalness = 0
        facts.speechiness = 0.04
        facts.liveness = 0.12
        facts.genres = ["pop", "dance pop", "synth pop"]
        facts.releaseDate = "1987-07-27"
        facts.label = "RCA"
        facts.explicit = false
        for field in [MusicSongFacts.Field.bpm, .key, .energy, .danceability, .valence, .acousticness, .instrumentalness,
                      .speechiness, .liveness] {
            facts.claim(field, .reccobeats)
        }
        for field in [MusicSongFacts.Field.isrc, .releaseDate, .explicit] { facts.claim(field, .deezer) }
        for field in [MusicSongFacts.Field.genres, .label] { facts.claim(field, .musicbrainz) }
        return facts
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

    private func render(_ view: some View, name: String) throws -> NSImage {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(atPath: Self.outDir, withIntermediateDirectories: true)
        try png.write(to: URL(fileURLWithPath: "\(Self.outDir)/\(name)"))
        return image
    }

    @Test("the loading panel renders at the same size as the populated one")
    func loadingPanel() throws {
        let loading = MusicSongDataRows.sections(
            track: track, like: .like, isDownloaded: false, stream: .loading, analysis: nil, now: now,
            music: MusicSongDataMusicState(lookingUp: true)
        )
        let measuring = MusicSongDataRows.sections(
            track: track, like: .like, isDownloaded: false, stream: .loading, analysis: nil, now: now,
            music: MusicSongDataMusicState(measuringTempo: true, measuringAnalysis: true)
        )
        let first = try render(panel(loading), name: "song-data-loading.png")
        let second = try render(panel(measuring), name: "song-data-measuring.png")
        #expect(first.size == second.size)
        #expect(FileManager.default.fileExists(atPath: "\(Self.outDir)/song-data-loading.png"))
    }

    @Test("the populated and the empty panel render at the same size")
    func panels() throws {
        let full = MusicSongDataRows.sections(
            track: track, like: .like, isDownloaded: false, stream: .loaded(stream), analysis: analysis, now: now,
            music: MusicSongDataMusicState(facts: facts)
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
}
