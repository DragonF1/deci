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

/// What the panel knows of the song's music data: the facts, and whether the services are still being asked or the song is
/// still being measured. A measurement that could not run says why in `problem`.
struct MusicSongDataMusicState: Equatable {
    enum Problem: Equatable {
        case offline, signedOut, rateLimited, failed
    }

    var facts: MusicSongFacts?
    /// The online services are being asked.
    var lookingUp = false
    /// The song is being downloaded and measured: its tempo, and its analysis when it had none.
    var measuringTempo = false
    var measuringAnalysis = false
    var problem: Problem?
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
/// and each missing-value text is tested alone. Later tiers add rows here, such as the listener's own stats.
enum MusicSongDataRows {
    static let unknown = "Unknown"
    static let lookingUp = "Looking up"
    static let measuring = "Measuring"

    static func sections(
        track: MusicTrack, like: MusicLikeStatus?, isDownloaded: Bool, stream: MusicSongDataStreamState,
        analysis: MusicAnalysis?, now: Date, music: MusicSongDataMusicState = MusicSongDataMusicState()
    ) -> [MusicSongDataSection] {
        [
            basics(track: track, like: like, stream: stream),
            musicSection(music, analysis: analysis),
            streamSection(isDownloaded: isDownloaded, stream: stream),
            analysisSection(analysis, now: now, music: music)
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

    // MARK: - Music

    private static let keyNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

    private static func musicSection(_ music: MusicSongDataMusicState, analysis: MusicAnalysis?) -> MusicSongDataSection {
        // While the services are asked every row waits; after that a row that is missing is Unknown, but the tempo reads
        // Measuring while the beat finder is on it.
        func row(_ label: String, _ value: String?, numeric: Bool = true) -> MusicSongDataRow {
            if music.lookingUp { return MusicSongDataRow(label: label, value: lookingUp, isNumeric: false) }
            return numeric ? number(label, value) : text(label, value)
        }
        let facts = music.facts
        let measuredKey = facts?.key == nil ? measuredKeyText(analysis) : nil
        var tempo = tempoText(facts)
        if tempo == nil, music.measuringTempo, !music.lookingUp { tempo = measuring }
        let tempoRow = music.lookingUp
            ? MusicSongDataRow(label: "BPM", value: lookingUp, isNumeric: false)
            : MusicSongDataRow(label: "BPM", value: tempo ?? unknown, isNumeric: false)
        return MusicSongDataSection(title: "Music", rows: [
            tempoRow,
            row("Key", keyText(facts) ?? measuredKey, numeric: false),
            row("Energy", percent(facts?.energy)),
            row("Danceability", percent(facts?.danceability)),
            row("Mood", percent(facts?.valence)),
            row("Acousticness", percent(facts?.acousticness)),
            row("Instrumentalness", percent(facts?.instrumentalness)),
            row("Speechiness", percent(facts?.speechiness)),
            row("Liveness", percent(facts?.liveness)),
            row("Genres", genresText(facts), numeric: false),
            row("Released", facts?.releaseDate.flatMap(nonBlank)),
            row("Label", facts?.label.flatMap(nonBlank), numeric: false),
            row("Explicit", facts?.explicit.map { $0 ? "Yes" : "No" }, numeric: false),
            row("ISRC", facts?.isrc.flatMap(nonBlank)),
            row("Data from", sourcesText(facts, measuredKey: measuredKey != nil), numeric: false)
        ])
    }

    /// "171 (ReccoBeats)", or "104 (measured)" for Deci's own.
    private static func tempoText(_ facts: MusicSongFacts?) -> String? {
        guard let bpm = facts?.bpm, MusicSongFactsParsers.tempoRange.contains(bpm), let rounded = safeInt(bpm.rounded()) else { return nil }
        let name = facts?.source(of: .bpm).map { $0 == .deci ? "measured" : $0.displayName }
        let whole = "\(rounded)"
        return name.map { "\(whole) (\($0))" } ?? whole
    }

    /// Sharps only ("C# major"). The services estimate the key, so an outside value says approx.
    private static func keyText(_ facts: MusicSongFacts?) -> String? {
        guard let key = facts?.key, keyNames.indices.contains(key) else { return nil }
        var text = keyNames[key]
        switch facts?.mode {
        case 1?: text += " major"
        case 0?: text += " minor"
        default: break
        }
        if let source = facts?.source(of: .key), source != .deci { text += " (approx.)" }
        return text
    }

    /// The key Deci's own analysis found, when it was sure enough: "C# minor (measured)".
    private static func measuredKeyText(_ analysis: MusicAnalysis?) -> String? {
        guard let info = analysis?.keyInfoValue, info.trustedCamelot != nil, keyNames.indices.contains(info.tonic) else { return nil }
        return "\(keyNames[info.tonic]) \(info.isMinor ? "minor" : "major") (measured)"
    }

    private static func percent(_ value: Double?) -> String? {
        guard let value, value.isFinite, value >= 0, value <= 1, let whole = safeInt((value * 100).rounded()) else { return nil }
        return "\(whole)%"
    }

    private static func genresText(_ facts: MusicSongFacts?) -> String? {
        let names = (facts?.genres ?? []).compactMap(nonBlank).prefix(4).map { name in
            name.prefix(1).uppercased() + name.dropFirst()
        }
        return names.isEmpty ? nil : names.joined(separator: ", ")
    }

    private static func sourcesText(_ facts: MusicSongFacts?, measuredKey: Bool) -> String? {
        var sources = facts?.usedSources ?? []
        if measuredKey, !sources.contains(.deci) { sources.append(.deci) }
        let names = sources.map { $0 == .deci ? "Deci (measured)" : $0.displayName }
        return names.isEmpty ? nil : names.joined(separator: ", ")
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
                number("Bitrate", held.bitrate.flatMap { $0 > 0 ? safeInt((Double($0) / 1000).rounded()).map { "\($0) kbps" } : nil }),
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

    private static func analysisSection(_ analysis: MusicAnalysis?, now: Date, music: MusicSongDataMusicState) -> MusicSongDataSection {
        guard let analysis else {
            let note: String
            if music.measuringAnalysis {
                note = measuring
            } else {
                switch music.problem {
                case .offline?: note = "Offline"
                case .signedOut?: note = "Signed out"
                case .rateLimited?: note = "Busy, try again later"
                case .failed?: note = "Could not analyse"
                case nil: note = "Not analysed yet"
                }
            }
            return MusicSongDataSection(title: "Audio analysis", rows: [], note: note)
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
            text("Analysed", analysedText(analysis, now: now))
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
            when = relativeFormatter.localizedString(for: analysis.analyzedAt, relativeTo: now)
        }
        return "\(when) (\(source))"
    }

    // MARK: - Formats

    /// Built once: a formatter is costly to make and the panel's body runs often.
    nonisolated(unsafe) static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.unitsStyle = .full
        return formatter
    }()

    nonisolated(unsafe) private static let groupedFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US")
        return formatter
    }()

    /// A whole number from a double, or nil when it is not finite or too big to be a real count (old cached rows).
    static func safeInt(_ value: Double) -> Int? {
        guard value.isFinite, abs(value) < 1e15 else { return nil }
        return Int(value)
    }

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
        guard value.isFinite, value >= 0, let whole = safeInt(value.rounded(.down)) else { return nil }
        return clock(whole)
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
        if rounded == rounded.rounded(), let whole = safeInt(rounded) { return "\(whole) kHz" }
        return String(format: "%.1f kHz", rounded)
    }

    private static func megabytes(_ bytes: Int) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }

    private static func grouped(_ value: Int) -> String {
        groupedFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}
