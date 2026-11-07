// DeciTests/Music/MusicSongDataRowsTests.swift
// The Song data panel's rows: what each value reads like and what a missing one says, for Basics, Stream and Audio
// analysis. Pure, no view.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("Music song data rows")
struct MusicSongDataRowsTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func stream(
        itag: Int = 251, origin: ResolvedStream.Origin = .network, codec: String? = "opus", viewCount: Int? = 1_234_567,
        loudness: Double? = -6.2, perceptual: Double? = -7.5, bitrate: Int? = 130_000, rate: Int? = 48_000,
        channels: Int? = 2, length: Int? = 3_500_000
    ) -> ResolvedStream {
        ResolvedStream(
            videoId: "vid1", url: URL(string: "https://example.com/a")!, itag: itag, durationSeconds: 215,
            expiresAt: now.addingTimeInterval(3600), playbackTrackingURL: nil, viewCount: viewCount, httpHeaders: [:],
            origin: origin, audioCodec: codec, loudnessDb: loudness, perceptualLoudnessDb: perceptual,
            bitrate: bitrate, audioSampleRate: rate, audioChannels: channels, contentLength: length
        )
    }

    private func analysis(
        silenceStart: Double = 0.8, silenceEnd: Double = 213.8, introEnd: Double = 12, outroStart: Double = 200,
        lufs: Double = -14.2, peak: Double = -0.3, intro: Double? = -15, outro: Double? = -16.5,
        source: MusicAnalysis.Source = .playbackCache, age: TimeInterval = 2 * 86_400
    ) -> MusicAnalysis {
        MusicAnalysis(
            videoId: "vid1", version: 1, format: .init(codec: "opus", itag: 251, durationMs: 215_000),
            analyzedAt: now.addingTimeInterval(-age), source: source, silenceStart: silenceStart, silenceEnd: silenceEnd,
            introEnd: introEnd, outroStart: outroStart, integratedLUFS: lufs, samplePeakDb: peak, introLUFS: intro,
            outroLUFS: outro, energy: [], youtubeLoudnessDb: nil, youtubePerceptualLoudnessDb: nil
        )
    }

    private func sections(
        track: MusicTrack = MusicSamples.track("vid1", title: "Song", artist: "Artist", seconds: 215, album: "Album", plays: nil),
        like: MusicLikeStatus? = .like, isDownloaded: Bool = false,
        stream state: MusicSongDataStreamState = .loading, analysis: MusicAnalysis? = nil
    ) -> [MusicSongDataSection] {
        MusicSongDataRows.sections(
            track: track, like: like, isDownloaded: isDownloaded, stream: state, analysis: analysis, now: now
        )
    }

    private func value(_ label: String, in sections: [MusicSongDataSection]) -> String? {
        sections.flatMap(\.rows).first { $0.label == label }?.value
    }

    private func section(_ title: String, in sections: [MusicSongDataSection]) -> MusicSongDataSection? {
        sections.first { $0.title == title }
    }

    // MARK: - Shape

    @Test("three sections in order: Basics, Stream and Audio analysis")
    func order() {
        #expect(sections().map(\.title) == ["Basics", "Stream", "Audio analysis"])
    }

    // MARK: - Basics

    @Test("Basics lists title, artist, album, length, video id, plays and liked in order")
    func basicsOrder() {
        let s = sections(stream: .loaded(stream()))
        #expect(section("Basics", in: s)?.rows.map(\.label) == ["Title", "Artist", "Album", "Length", "Video ID", "YouTube plays", "Liked"])
    }

    @Test("Basics values read plainly, the length as m:ss")
    func basicsValues() {
        let s = sections()
        #expect(value("Title", in: s) == "Song")
        #expect(value("Artist", in: s) == "Artist")
        #expect(value("Album", in: s) == "Album")
        #expect(value("Length", in: s) == "3:35")
        #expect(value("Video ID", in: s) == "vid1")
    }

    @Test("a length under a minute pads the seconds, and one over an hour keeps counting minutes")
    func lengthBoundaries() {
        #expect(value("Length", in: sections(track: MusicSamples.track("v", seconds: 5))) == "0:05")
        #expect(value("Length", in: sections(track: MusicSamples.track("v", seconds: 60))) == "1:00")
        #expect(value("Length", in: sections(track: MusicSamples.track("v", seconds: 3725))) == "62:05")
    }

    @Test("a missing album, length or plays says Unknown")
    func basicsMissing() {
        let s = sections(track: MusicSamples.track("v", seconds: nil))
        #expect(value("Album", in: s) == "Unknown")
        #expect(value("Length", in: s) == "Unknown")
        #expect(value("YouTube plays", in: s) == "Unknown")
    }

    @Test("a blank album counts as missing")
    func blankAlbum() {
        #expect(value("Album", in: sections(track: MusicSamples.track("v", album: "  "))) == "Unknown")
    }

    @Test("plays come from the stream's view count, grouped, and from the row when the stream has none")
    func plays() {
        #expect(value("YouTube plays", in: sections(stream: .loaded(stream(viewCount: 1_234_567)))) == "1,234,567")
        let fromRow = sections(track: MusicSamples.track("v", plays: 2_000), stream: .loaded(stream(viewCount: nil)))
        #expect(value("YouTube plays", in: fromRow) == "2,000")
        #expect(value("YouTube plays", in: sections(track: MusicSamples.track("v", plays: 42))) == "42")
    }

    @Test("Liked reads Yes, No, Disliked or Unknown")
    func liked() {
        #expect(value("Liked", in: sections(like: .like)) == "Yes")
        #expect(value("Liked", in: sections(like: .indifferent)) == "No")
        #expect(value("Liked", in: sections(like: .dislike)) == "Disliked")
        #expect(value("Liked", in: sections(like: nil)) == "Unknown")
    }

    @Test("an empty title or artist stays a row, reading Unknown")
    func blankTitle() {
        let s = sections(track: MusicSamples.track("v", title: "", artist: ""))
        #expect(value("Title", in: s) == "Unknown")
        #expect(value("Artist", in: s) == "Unknown")
    }

    // MARK: - Stream

    @Test("a loaded stream lists source, codec, format, bitrate, sample rate, channels, size and YouTube's loudness")
    func streamOrder() {
        let s = sections(stream: .loaded(stream()))
        #expect(section("Stream", in: s)?.rows.map(\.label) == [
            "Source", "Codec", "Format", "Bitrate", "Sample rate", "Channels", "File size", "YouTube loudness",
            "YouTube perceptual loudness"
        ])
    }

    @Test("a loaded stream's values read with their units")
    func streamValues() {
        let s = sections(stream: .loaded(stream()))
        #expect(value("Source", in: s) == "Streaming")
        #expect(value("Codec", in: s) == "Opus (opus)")
        #expect(value("Format", in: s) == "itag 251")
        #expect(value("Bitrate", in: s) == "130 kbps")
        #expect(value("Sample rate", in: s) == "48 kHz")
        #expect(value("Channels", in: s) == "2 (stereo)")
        #expect(value("File size", in: s) == "3.3 MB")
        #expect(value("YouTube loudness", in: s) == "-6.2 dB")
        #expect(value("YouTube perceptual loudness", in: s) == "-7.5 dB")
    }

    @Test("source follows where the bytes come from")
    func source() {
        #expect(value("Source", in: sections(stream: .loaded(stream(origin: .network)))) == "Streaming")
        #expect(value("Source", in: sections(stream: .loaded(stream(origin: .download)))) == "Downloaded")
        #expect(value("Source", in: sections(stream: .loaded(stream(origin: .trackCache)))) == "Cached copy")
    }

    @Test("a downloaded song reads Downloaded even when no stream is held, and an ordinary one Streaming")
    func sourceWithoutStream() {
        #expect(value("Source", in: sections(isDownloaded: true, stream: .offline)) == "Downloaded")
        #expect(value("Source", in: sections(isDownloaded: false, stream: .offline)) == "Streaming")
    }

    @Test("codec names: AAC, Opus, Vorbis, and any other string as it is")
    func codecs() {
        func codec(_ raw: String?) -> String? { value("Codec", in: sections(stream: .loaded(stream(codec: raw)))) }
        #expect(codec("mp4a.40.2") == "AAC (mp4a.40.2)")
        #expect(codec("opus") == "Opus (opus)")
        #expect(codec("vorbis") == "Vorbis (vorbis)")
        #expect(codec("ec-3") == "ec-3")
        #expect(codec(nil) == "Unknown")
        #expect(codec("") == "Unknown")
    }

    @Test("sample rates drop a trailing zero: 44.1 kHz and 48 kHz")
    func sampleRates() {
        func rate(_ hz: Int?) -> String? { value("Sample rate", in: sections(stream: .loaded(stream(rate: hz)))) }
        #expect(rate(44_100) == "44.1 kHz")
        #expect(rate(48_000) == "48 kHz")
        #expect(rate(32_000) == "32 kHz")
        #expect(rate(nil) == "Unknown")
    }

    @Test("channels: mono, stereo, any other count, and a missing one")
    func channels() {
        func channels(_ n: Int?) -> String? { value("Channels", in: sections(stream: .loaded(stream(channels: n)))) }
        #expect(channels(1) == "1 (mono)")
        #expect(channels(2) == "2 (stereo)")
        #expect(channels(6) == "6")
        #expect(channels(nil) == "Unknown")
    }

    @Test("a missing bitrate, size, itag or loudness says Unknown, and itag 0 (a file) too")
    func streamMissing() {
        let s = sections(stream: .loaded(stream(
            itag: 0, loudness: nil, perceptual: nil, bitrate: nil, rate: nil, channels: nil, length: nil
        )))
        for label in ["Format", "Bitrate", "Sample rate", "Channels", "File size", "YouTube loudness", "YouTube perceptual loudness"] {
            #expect(value(label, in: s) == "Unknown", "\(label)")
        }
    }

    @Test("non-finite loudness reads Unknown")
    func nonFiniteLoudness() {
        let s = sections(stream: .loaded(stream(loudness: .nan, perceptual: .infinity)))
        #expect(value("YouTube loudness", in: s) == "Unknown")
        #expect(value("YouTube perceptual loudness", in: s) == "Unknown")
    }

    @Test("while the stream is out the section keeps Source and says Loading")
    func streamLoading() {
        let rows = section("Stream", in: sections(stream: .loading))?.rows
        #expect(rows?.map(\.label) == ["Source", "Details"])
        #expect(rows?.last?.value == "Loading")
    }

    @Test("offline and failure say Offline and Unavailable, quietly")
    func streamOfflineAndUnavailable() {
        #expect(value("Details", in: sections(stream: .offline)) == "Offline")
        #expect(value("Details", in: sections(stream: .unavailable)) == "Unavailable")
    }

    // MARK: - Audio analysis

    @Test("no analysis row is one line, Not analysed yet")
    func notAnalysed() {
        let analysisSection = section("Audio analysis", in: sections(analysis: nil))
        #expect(analysisSection?.rows.isEmpty == true)
        #expect(analysisSection?.note == "Not analysed yet")
    }

    @Test("an analysis lists its rows in order and ends with a BPM that is not measured yet")
    func analysisOrder() {
        let s = sections(analysis: analysis())
        #expect(section("Audio analysis", in: s)?.rows.map(\.label) == [
            "Loudness", "Sample peak", "Silence at start", "Silence at end", "Intro ends at", "Outro starts at",
            "Intro loudness", "Outro loudness", "Smart fade trim in", "Smart fade trim out", "Analysed", "BPM"
        ])
        #expect(section("Audio analysis", in: s)?.note == nil)
        #expect(value("BPM", in: s) == "Not measured yet")
    }

    @Test("analysis values read with their units")
    func analysisValues() {
        let s = sections(analysis: analysis())
        #expect(value("Loudness", in: s) == "-14.2 LUFS")
        #expect(value("Sample peak", in: s) == "-0.3 dBFS")
        #expect(value("Silence at start", in: s) == "0.80 s")
        #expect(value("Silence at end", in: s) == "1.20 s")
        #expect(value("Intro ends at", in: s) == "0:12")
        #expect(value("Outro starts at", in: s) == "3:20")
        #expect(value("Intro loudness", in: s) == "-15.0 LUFS")
        #expect(value("Outro loudness", in: s) == "-16.5 LUFS")
    }

    @Test("the smart fade trims are the planner's: the leading silence in, the dead air out")
    func trims() {
        let s = sections(analysis: analysis(silenceStart: 0.8, silenceEnd: 213.8))
        #expect(value("Smart fade trim in", in: s) == "0.80 s")
        #expect(value("Smart fade trim out", in: s) == "1.20 s")
    }

    @Test("a silence too short to trim reads None for both trims")
    func noTrims() {
        let s = sections(analysis: analysis(silenceStart: 0.1, silenceEnd: 214.9))
        #expect(value("Smart fade trim in", in: s) == "None")
        #expect(value("Smart fade trim out", in: s) == "None")
    }

    @Test("a row the planner cannot use trims nothing")
    func unusableAnalysisTrims() {
        let s = sections(analysis: analysis(silenceStart: 5, silenceEnd: 2))
        #expect(value("Smart fade trim in", in: s) == "None")
        #expect(value("Smart fade trim out", in: s) == "None")
    }

    @Test("an all-silent song's loudness reads Silent, and missing intro and outro loudness Unknown")
    func analysisMissing() {
        let s = sections(analysis: analysis(lufs: -.infinity, intro: nil, outro: nil))
        #expect(value("Loudness", in: s) == "Silent")
        #expect(value("Intro loudness", in: s) == "Unknown")
        #expect(value("Outro loudness", in: s) == "Unknown")
    }

    @Test("Analysed reads a relative date and where the audio came from")
    func analysed() {
        #expect(value("Analysed", in: sections(analysis: analysis(source: .playbackCache, age: 2 * 86_400))) == "2 days ago (playback)")
        #expect(value("Analysed", in: sections(analysis: analysis(source: .download, age: 3 * 3_600))) == "3 hours ago (download)")
        #expect(value("Analysed", in: sections(analysis: analysis(source: .backgroundCache, age: 10))) == "Just now (background)")
    }

    // MARK: - Numbers

    @Test("every number in a value column is marked for the mono face, the words are not")
    func numericMarks() {
        let s = sections(stream: .loaded(stream()), analysis: analysis())
        let rows = s.flatMap(\.rows)
        #expect(rows.first { $0.label == "Length" }?.isNumeric == true)
        #expect(rows.first { $0.label == "Bitrate" }?.isNumeric == true)
        #expect(rows.first { $0.label == "Loudness" }?.isNumeric == true)
        #expect(rows.first { $0.label == "Title" }?.isNumeric == false)
        #expect(rows.first { $0.label == "Source" }?.isNumeric == false)
        #expect(rows.first { $0.label == "BPM" }?.isNumeric == false)
    }

    @Test("a missing value is not set in the mono face")
    func missingNotNumeric() {
        let s = sections(track: MusicSamples.track("v", seconds: nil))
        #expect(s.flatMap(\.rows).first { $0.label == "Length" }?.isNumeric == false)
    }
}
