// Deci/Music/SongFacts/MusicSongFactsParsers.swift
// Reads the replies of the five services. Every reply is untrusted: a missing, null or oddly typed field is just absent,
// and only a body that is not the expected JSON shape at all is malformed. Pure.

import Foundation

enum MusicSongFactsError: Error, Equatable {
    /// The service asked us to slow down (HTTP 429, or Deezer's code 4 inside a 200).
    case rateLimited(retryAfter: TimeInterval?)
    case http(Int)
    case tooLarge
    case malformed
}

enum MusicSongFactsParsers {
    struct DeezerTrack: Equatable {
        var id: Int?
        var isrc: String?
        /// Only a value above zero: Deezer sends 0 for "unknown".
        var bpm: Double?
        var gain: Double?
        var releaseDate: String?
        var explicit: Bool?
        var albumId: Int?
        var duration: Int?
    }

    struct DeezerAlbum: Equatable {
        var genres: [String]
        var label: String?
    }

    struct ReccoFeatures: Equatable {
        var isrc: String?
        var tempo: Double?
        /// 0 to 11; nil for -1 (unknown).
        var key: Int?
        var mode: Int?
        var energy: Double?
        var danceability: Double?
        var valence: Double?
        var acousticness: Double?
        var instrumentalness: Double?
        var speechiness: Double?
        var liveness: Double?
        var loudness: Double?
    }

    struct MusicBrainzRecording: Equatable {
        var id: String
        /// Milliseconds.
        var length: Int?
        var firstReleaseDate: String?
    }

    struct MusicBrainzDetail: Equatable {
        /// Most voted first.
        var genres: [String]
        var firstReleaseDate: String?
    }

    struct AudioDBTrack: Equatable {
        var artist: String?
        var title: String?
        var isrc: String?
        var tempo: Double?
        /// 0 to 1 (the service sends 0 to 100).
        var energy: Double?
        var danceability: Double?
        var genre: String?
        var mood: String?
    }

    // MARK: - Deezer

    /// The hits of a search. Code 4 (the quota) throws `rateLimited`; any other error body is no hits.
    static func deezerSearch(_ data: Data) throws -> [MusicSongFactsMatcher.Candidate] {
        let root = try object(data)
        try checkDeezerError(root)
        guard let hits = root["data"] as? [Any] else { return [] }
        return hits.compactMap { raw in
            guard let hit = raw as? [String: Any], let id = int(hit["id"]), let title = string(hit["title"]),
                  let duration = int(hit["duration"]) else { return nil }
            let artist = (hit["artist"] as? [String: Any]).flatMap { string($0["name"]) } ?? ""
            return MusicSongFactsMatcher.Candidate(
                id: id, title: title, titleShort: string(hit["title_short"]), titleVersion: string(hit["title_version"]),
                isrc: string(hit["isrc"]), duration: duration, rank: int(hit["rank"]) ?? 0, explicit: bool(hit["explicit_lyrics"]),
                artist: artist
            )
        }
    }

    /// nil when Deezer has no such track (an error body).
    static func deezerTrack(_ data: Data) throws -> DeezerTrack? {
        let root = try object(data)
        try checkDeezerError(root)
        guard root["error"] == nil else { return nil }
        let bpm = number(root["bpm"]).flatMap { $0 > 0 ? $0 : nil }
        return DeezerTrack(
            id: int(root["id"]), isrc: string(root["isrc"]), bpm: bpm, gain: number(root["gain"]),
            releaseDate: string(root["release_date"]), explicit: bool(root["explicit_lyrics"]),
            albumId: (root["album"] as? [String: Any]).flatMap { int($0["id"]) }, duration: int(root["duration"])
        )
    }

    static func deezerAlbum(_ data: Data) throws -> DeezerAlbum? {
        let root = try object(data)
        try checkDeezerError(root)
        guard root["error"] == nil else { return nil }
        let names = ((root["genres"] as? [String: Any])?["data"] as? [Any] ?? [])
            .compactMap { ($0 as? [String: Any]).flatMap { string($0["name"]) } }
        return DeezerAlbum(genres: names, label: string(root["label"]))
    }

    private static func checkDeezerError(_ root: [String: Any]) throws {
        guard let error = root["error"] as? [String: Any] else { return }
        if int(error["code"]) == 4 { throw MusicSongFactsError.rateLimited(retryAfter: nil) }
    }

    // MARK: - ReccoBeats

    /// The first entry of `content`; nil when there is none.
    static func reccoFeatures(_ data: Data) throws -> ReccoFeatures? {
        let root = try object(data)
        guard let first = (root["content"] as? [Any])?.first as? [String: Any] else { return nil }
        let key = int(first["key"]).flatMap { (0...11).contains($0) ? $0 : nil }
        return ReccoFeatures(
            isrc: string(first["isrc"]), tempo: number(first["tempo"]).flatMap { $0 > 0 ? $0 : nil }, key: key,
            mode: int(first["mode"]).flatMap { ($0 == 0 || $0 == 1) ? $0 : nil }, energy: unit(first["energy"]),
            danceability: unit(first["danceability"]), valence: unit(first["valence"]), acousticness: unit(first["acousticness"]),
            instrumentalness: unit(first["instrumentalness"]), speechiness: unit(first["speechiness"]),
            liveness: unit(first["liveness"]), loudness: number(first["loudness"])
        )
    }

    // MARK: - MusicBrainz

    static func musicBrainzRecordings(_ data: Data) throws -> [MusicBrainzRecording] {
        let root = try object(data)
        return (root["recordings"] as? [Any] ?? []).compactMap { raw in
            guard let recording = raw as? [String: Any], let id = string(recording["id"]) else { return nil }
            return MusicBrainzRecording(
                id: id, length: int(recording["length"]), firstReleaseDate: string(recording["first-release-date"])
            )
        }
    }

    static func musicBrainzDetail(_ data: Data) throws -> MusicBrainzDetail {
        let root = try object(data)
        let genres = (root["genres"] as? [Any] ?? []).compactMap { raw -> (name: String, count: Int)? in
            guard let genre = raw as? [String: Any], let name = string(genre["name"]) else { return nil }
            return (name, int(genre["count"]) ?? 0)
        }
        // Stable: the service's own order breaks a tie.
        let ordered = genres.enumerated().sorted { ($0.element.count, -$0.offset) > ($1.element.count, -$1.offset) }
        return MusicBrainzDetail(genres: ordered.map(\.element.name), firstReleaseDate: string(root["first-release-date"]))
    }

    // MARK: - TheAudioDB

    static func audioDBTracks(_ data: Data) throws -> [AudioDBTrack] {
        let root = try object(data)
        // No match is `{"track":null}`.
        return (root["track"] as? [Any] ?? []).compactMap { raw in
            guard let track = raw as? [String: Any] else { return nil }
            return AudioDBTrack(
                artist: string(track["strArtist"]), title: string(track["strTrack"]), isrc: string(track["strISRC"]),
                tempo: number(track["intTempo"]).flatMap { $0 > 0 ? $0 : nil },
                energy: percent(track["intEnergy"]), danceability: percent(track["intDanceability"]),
                genre: string(track["strGenre"]), mood: string(track["strMood"])
            )
        }
    }

    // MARK: - Reading

    private static func object(_ data: Data) throws -> [String: Any] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw MusicSongFactsError.malformed
        }
        return root
    }

    private static func string(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// A number, or a string that holds one ("171"); never a Bool.
    private static func number(_ value: Any?) -> Double? {
        if let text = value as? String { return Double(text.trimmingCharacters(in: .whitespaces)).flatMap { $0.isFinite ? $0 : nil } }
        guard let raw = value as? NSNumber, CFGetTypeID(raw) != CFBooleanGetTypeID() else { return nil }
        return raw.doubleValue.isFinite ? raw.doubleValue : nil
    }

    private static func int(_ value: Any?) -> Int? {
        number(value).flatMap { abs($0) < 1e15 ? Int($0) : nil }
    }

    private static func bool(_ value: Any?) -> Bool? {
        if let flag = value as? Bool { return flag }
        return nil
    }

    /// 0 to 1 only; anything else is not a measure.
    private static func unit(_ value: Any?) -> Double? {
        number(value).flatMap { (0...1).contains($0) ? $0 : nil }
    }

    /// TheAudioDB writes 0 for "not measured", so 0 is no value.
    private static func percent(_ value: Any?) -> Double? {
        number(value).flatMap { ($0 > 0 && $0 <= 100) ? $0 / 100 : nil }
    }
}
