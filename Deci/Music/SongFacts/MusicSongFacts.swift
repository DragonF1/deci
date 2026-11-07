// Deci/Music/SongFacts/MusicSongFacts.swift
// What outside music data services (and Deci's own beat finder) know about one song, with the source of every field.
// Pure value types, no I/O.

import Foundation

struct MusicSongFacts: Sendable, Equatable, Codable {
    /// Where a field came from. The chain asks them in this order and the first to supply a field keeps it.
    enum Source: String, Sendable, Codable, CaseIterable {
        case deezer, reccobeats, musicbrainz, theaudiodb, deci

        /// The name the panel shows.
        var displayName: String {
            switch self {
            case .deezer: "Deezer"
            case .reccobeats: "ReccoBeats"
            case .musicbrainz: "MusicBrainz"
            case .theaudiodb: "TheAudioDB"
            case .deci: "Deci"
            }
        }
    }

    /// The fields that carry a source. Key and mode share one.
    enum Field: String, Sendable, Codable, CaseIterable {
        case isrc, bpm, key, energy, danceability, valence, acousticness, instrumentalness, speechiness, liveness
        case genres, releaseDate, label, explicit, deezerId, mbid
    }

    var isrc: String?
    var bpm: Double?
    /// How sure Deci's own beat finder was, 0 to 1. Set only when `bpm` was measured.
    var bpmConfidence: Double?
    /// Pitch class 0 to 11 (0 is C); nil when unknown.
    var key: Int?
    /// 1 major, 0 minor.
    var mode: Int?
    /// 0 to 1 each.
    var energy: Double?
    var danceability: Double?
    var valence: Double?
    var acousticness: Double?
    var instrumentalness: Double?
    var speechiness: Double?
    var liveness: Double?
    var genres: [String] = []
    /// As the service wrote it: "2020-03-20", sometimes only a year.
    var releaseDate: String?
    var label: String?
    var explicit: Bool?
    var deezerId: Int?
    var mbid: String?
    var fetchedAt: Date
    /// When Deci's own measurement last failed (a download or decode); the song is not fetched again for a day.
    var measureFailedAt: Date?
    /// Field raw value to source. A string key keeps the stored JSON a plain object.
    var sources: [String: Source] = [:]

    init(fetchedAt: Date) {
        self.fetchedAt = fetchedAt
    }

    func source(of field: Field) -> Source? { sources[field.rawValue] }

    /// Records `source` for `field` when the field has no source yet.
    mutating func claim(_ field: Field, _ source: Source) {
        if sources[field.rawValue] == nil { sources[field.rawValue] = source }
    }

    /// True when nothing but the time is set: a miss.
    var isEmpty: Bool {
        isrc == nil && bpm == nil && key == nil && energy == nil && danceability == nil && valence == nil
            && acousticness == nil && instrumentalness == nil && speechiness == nil && liveness == nil
            && genres.isEmpty && releaseDate == nil && label == nil && explicit == nil && deezerId == nil && mbid == nil
    }

    /// The sources in use, in chain order, each once.
    var usedSources: [Source] {
        let used = Set(sources.values)
        return Source.allCases.filter(used.contains)
    }

    /// Sets the tempo Deci measured, unless an outside source already gave one.
    mutating func setMeasuredTempo(bpm: Double, confidence: Double) {
        guard self.bpm == nil || sources[Field.bpm.rawValue] == .deci else { return }
        self.bpm = bpm
        bpmConfidence = confidence
        sources[Field.bpm.rawValue] = .deci
    }
}

/// What the chain is asked about: only these ever go out.
struct MusicSongFactsQuery: Sendable, Equatable {
    var artist: String
    var title: String
    var durationSeconds: Double?

    init(artist: String, title: String, durationSeconds: Double?) {
        self.artist = artist
        self.title = title
        self.durationSeconds = durationSeconds
    }

    init(track: MusicTrack) {
        self.init(artist: track.artist, title: track.title, durationSeconds: track.durationSeconds.map(Double.init))
    }
}

/// How one lookup ended. `failed` is a lookup that could not be made (the network, a limit) and is never cached.
/// `partial` found something, but a step could not be asked, so the cache keeps it only briefly.
enum MusicSongFactsLookup: Sendable, Equatable {
    case found(MusicSongFacts)
    case partial(MusicSongFacts)
    case notFound
    case failed
}
