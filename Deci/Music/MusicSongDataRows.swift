// Deci/Music/MusicSongDataRows.swift
import Foundation

/// What the Song data panel knows about the stream of a song: held or resolved, still on its way, or why there is none.
enum MusicSongDataStreamState: Equatable {
    case loading
    case loaded(ResolvedStream)
    /// The network is down, so nothing could be asked.
    case offline
    /// The ask failed for any other reason.
    case unavailable
}

/// One label and value line of the panel. Numbers are set in the mono face (`isNumeric`).
struct MusicSongDataRow: Equatable {
    let label: String
    let value: String
    let isNumeric: Bool
}

/// One block of the panel under its kicker. `note` is the single line that stands in for the rows of a block that has
/// none ("Not analysed yet").
struct MusicSongDataSection: Equatable {
    let title: String
    let rows: [MusicSongDataRow]
    let note: String?

    init(title: String, rows: [MusicSongDataRow], note: String? = nil) {
        self.title = title
        self.rows = rows
        self.note = note
    }
}

/// The panel's rows, worked out from what is known. Pure: no view, no clock but the `now` it is given, so each format
/// and each missing-value text is tested alone. Later tiers add rows here: a BPM and key from an outside source, the
/// analysis of a song that was fetched on demand, and the listener's own stats.
enum MusicSongDataRows {
    static let unknown = "Unknown"

    static func sections(
        track: MusicTrack, like: MusicLikeStatus?, isDownloaded: Bool, stream: MusicSongDataStreamState,
        analysis: MusicAnalysis?, now: Date
    ) -> [MusicSongDataSection] {
        [
            basics(track: track, like: like, stream: stream),
            streamSection(isDownloaded: isDownloaded, stream: stream),
            analysisSection(analysis, now: now)
        ]
    }

    // MARK: - Basics

    private static func basics(track: MusicTrack, like: MusicLikeStatus?, stream: MusicSongDataStreamState) -> MusicSongDataSection {
        var viewCount = track.plays
        if case .loaded(let held) = stream, let views = held.viewCount { viewCount = views }
        return MusicSongDataSection(title: "Basics", rows: [
            text("Title", nonBlank(track.title)),
            text("Artist", nonBlank(track.artist)),
            text("Album", track.album.flatMap(nonBlank)),
            number("Length", track.durationSeconds.map(clock)),
            text("Video ID", nonBlank(track.videoId)),
            number("YouTube plays", viewCount.map(grouped)),
            text("Liked", likedText(like))
        ])
    }

    private static func likedText(_ like: MusicLikeStatus?) -> String? {
        switch like {
        case .like?: "Yes"
        case .indifferent?: "No"
        case .dislike?: "Disliked"
        case nil: nil
        }
    }

    // MARK: - Stream

    private static func streamSection(isDownloaded: Bool, stream: MusicSongDataStreamState) -> MusicSongDataSection {
        switch stream {
        case .loaded(let held):
            let source: String
            if isDownloaded {
                source = "Downloaded"
            } else {
                switch held.origin {
                case .download: source = "Downloaded"
                case .trackCache: source = "Cached copy"
                case .network: source = "Streaming"
                }
            }
            return MusicSongDataSection(title: "Stream", rows: [
                text("Source", source),
                text("Codec", codecText(held.audioCodec)),
                number("Format", held.itag > 0 ? "itag \(held.itag)" : nil),
                number("Bitrate", held.bitrate.flatMap { $0 > 0 ? "\(Int((Double($0) / 1000).rounded())) kbps" : nil }),
                number("Sample rate", held.audioSampleRate.flatMap { $0 > 0 ? kilohertz($0) : nil }),
                number("Channels", held.audioChannels.flatMap { $0 > 0 ? channelsText($0) : nil }),
                number("File size", held.contentLength.flatMap { $0 > 0 ? megabytes($0) : nil }),
                number("YouTube loudness", decibels(held.loudnessDb, unit: "dB")),
                number("YouTube perceptual loudness", decibels(held.perceptualLoudnessDb, unit: "dB"))
            ])
        case .loading, .offline, .unavailable:
            let detail: String
            switch stream {
            case .loading: detail = "Loading"
            case .offline: detail = "Offline"
            default: detail = "Unavailable"
            }
            return MusicSongDataSection(title: "Stream", rows: [
                text("Source", isDownloaded ? "Downloaded" : "Streaming"),
                text("Details", detail)
            ])
        }
    }

    private static func codecText(_ raw: String?) -> String? {
        guard let raw = raw.flatMap(nonBlank) else { return nil }
        let lower = raw.lowercased()
        let name: String?
        if lower.hasPrefix("mp4a") {
            name = "AAC"
        } else if lower == "opus" {
            name = "Opus"
        } else if lower == "vorbis" {
            name = "Vorbis"
        } else {
            name = nil
        }
        return name.map { "\($0) (\(raw))" } ?? raw
    }

    private static func channelsText(_ count: Int) -> String {
        switch count {
        case 1: "1 (mono)"
        case 2: "2 (stereo)"
        default: "\(count)"
        }
    }

    // MARK: - Audio analysis

    private static func analysisSection(_ analysis: MusicAnalysis?, now: Date) -> MusicSongDataSection {
        guard let analysis else {
            return MusicSongDataSection(title: "Audio analysis", rows: [], note: "Not analysed yet")
        }
        let duration = Double(analysis.format.durationMs) / 1000
        let trimIn = MusicTransitionPlanner.trimmedStart(of: analysis, duration: duration)
        let trimOut = MusicTransitionPlanner.trimmedEnd(of: analysis, duration: duration).map { duration - $0 }
        let silenceAtEnd = duration - analysis.silenceEnd
        return MusicSongDataSection(title: "Audio analysis", rows: [
            number("Loudness", analysis.integratedLUFS == -.infinity ? "Silent" : decibels(analysis.integratedLUFS, unit: "LUFS")),
            number("Sample peak", decibels(analysis.samplePeakDb, unit: "dBFS")),
            number("Silence at start", seconds(analysis.silenceStart)),
            number("Silence at end", silenceAtEnd.isFinite && silenceAtEnd >= 0 ? seconds(silenceAtEnd) : nil),
            number("Intro ends at", position(analysis.introEnd)),
            number("Outro starts at", position(analysis.outroStart)),
            number("Intro loudness", decibels(analysis.introLUFS, unit: "LUFS")),
            number("Outro loudness", decibels(analysis.outroLUFS, unit: "LUFS")),
            number("Smart fade trim in", trimIn.map(seconds) ?? "None"),
            number("Smart fade trim out", trimOut.map(seconds) ?? "None"),
            text("Analysed", analysedText(analysis, now: now)),
            text("BPM", "Not measured yet")
        ])
    }

    private static func analysedText(_ analysis: MusicAnalysis, now: Date) -> String {
        let source: String
        switch analysis.source {
        case .playbackCache: source = "playback"
        case .download: source = "download"
        case .backgroundCache: source = "background"
        }
        let age = now.timeIntervalSince(analysis.analyzedAt)
        let when: String
        if age < 60 {
            when = "Just now"
        } else {
            let formatter = RelativeDateTimeFormatter()
            formatter.locale = Locale(identifier: "en_US")
            formatter.unitsStyle = .full
            when = formatter.localizedString(for: analysis.analyzedAt, relativeTo: now)
        }
        return "\(when) (\(source))"
    }

    // MARK: - Formats

    /// A text row; a missing value says Unknown.
    private static func text(_ label: String, _ value: String?) -> MusicSongDataRow {
        MusicSongDataRow(label: label, value: value ?? unknown, isNumeric: false)
    }

    /// A row whose value is a number; the mono face is for real numbers, not for Unknown.
    private static func number(_ label: String, _ value: String?) -> MusicSongDataRow {
        MusicSongDataRow(label: label, value: value ?? unknown, isNumeric: value != nil)
    }

    private static func nonBlank(_ value: String) -> String? {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
    }

    /// m:ss, the minutes counting past the hour.
    private static func clock(_ totalSeconds: Int) -> String {
        let whole = max(totalSeconds, 0)
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    private static func position(_ value: Double) -> String? {
        value.isFinite && value >= 0 ? clock(Int(value.rounded(.down))) : nil
    }

    private static func seconds(_ value: Double) -> String? {
        value.isFinite ? String(format: "%.2f s", value) : nil
    }

    private static func decibels(_ value: Double?, unit: String) -> String? {
        guard let value, value.isFinite else { return nil }
        return String(format: "%.1f %@", value, unit)
    }

    private static func kilohertz(_ hertz: Int) -> String {
        let value = Double(hertz) / 1000
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded() ? "\(Int(rounded)) kHz" : String(format: "%.1f kHz", rounded)
    }

    private static func megabytes(_ bytes: Int) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }

    private static func grouped(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US")
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}
