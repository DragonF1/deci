// DeciTests/Music/SongFacts/MusicSongFactsParsersTests.swift
// Each service reply parsed from a trimmed fixture, and the odd replies the services really send.

import Foundation
import Testing
@testable import Deci

@Suite("Music song facts parsers")
struct MusicSongFactsParsersTests {
    private typealias Parsers = MusicSongFactsParsers

    private func data(_ json: String) -> Data { Data(json.utf8) }

    // MARK: - Deezer

    @Test("a search lists its hits")
    func deezerSearch() throws {
        let hits = try Parsers.deezerSearch(data(SongFactsFixtures.search(SongFactsFixtures.hit())))
        #expect(hits.count == 1)
        #expect(hits[0].id == 908_604_612)
        #expect(hits[0].title == "Blinding Lights")
        #expect(hits[0].artist == "The Weeknd")
        #expect(hits[0].duration == 200)
        #expect(hits[0].rank == 984_833)
        #expect(hits[0].isrc == "USUG11904206")
        #expect(hits[0].explicit == false)
    }

    @Test("a search with no hits is an empty list")
    func deezerSearchEmpty() throws {
        #expect(try Parsers.deezerSearch(data("{\"data\":[],\"total\":0}")).isEmpty)
    }

    @Test("Deezer error code 4 inside a 200 is rate limited")
    func deezerQuota() {
        let body = data("{\"error\":{\"type\":\"Exception\",\"message\":\"Quota limit exceeded\",\"code\":4}}")
        #expect(throws: MusicSongFactsError.rateLimited(retryAfter: nil)) { try Parsers.deezerSearch(body) }
    }

    @Test("another Deezer error body is no hits")
    func deezerOtherError() throws {
        let body = data("{\"error\":{\"type\":\"DataException\",\"message\":\"no data\",\"code\":800}}")
        #expect(try Parsers.deezerSearch(body).isEmpty)
    }

    @Test("a body that is not JSON is malformed")
    func notJSON() {
        #expect(throws: MusicSongFactsError.malformed) { try Parsers.deezerSearch(data("<html>")) }
        #expect(throws: MusicSongFactsError.malformed) { try Parsers.reccoFeatures(data("nope")) }
    }

    @Test("a Deezer track gives the ISRC, release date, explicit flag and album id")
    func deezerTrack() throws {
        let track = try #require(try Parsers.deezerTrack(data(SongFactsFixtures.deezerTrack(bpm: 171))))
        #expect(track.isrc == "USUG11904206")
        #expect(track.bpm == 171)
        #expect(track.gain == -8.2)
        #expect(track.releaseDate == "2020-03-20")
        #expect(track.explicit == false)
        #expect(track.albumId == 137_217_782)
    }

    @Test("a Deezer bpm of 0 means unknown")
    func deezerZeroBPM() throws {
        let track = try #require(try Parsers.deezerTrack(data(SongFactsFixtures.deezerTrack(bpm: 0))))
        #expect(track.bpm == nil)
    }

    @Test("a Deezer album gives genres and a label")
    func deezerAlbum() throws {
        let album = try #require(try Parsers.deezerAlbum(data(SongFactsFixtures.deezerAlbum)))
        #expect(album.genres == ["R&B"])
        #expect(album.label == "Republic Records")
    }

    // MARK: - ReccoBeats

    @Test("ReccoBeats features read every number")
    func reccoFeatures() throws {
        let features = try #require(try Parsers.reccoFeatures(data(SongFactsFixtures.recco())))
        #expect(features.isrc == "USUG11904206")
        #expect(features.tempo == 171.005)
        #expect(features.key == 1)
        #expect(features.mode == 1)
        #expect(features.energy == 0.73)
        #expect(features.danceability == 0.514)
        #expect(features.valence == 0.334)
        #expect(features.acousticness == 0.00146)
        #expect(features.instrumentalness == 0.0000954)
        #expect(features.speechiness == 0.0598)
        #expect(features.liveness == 0.0897)
        #expect(features.loudness == -5.934)
    }

    @Test("a ReccoBeats key of -1 is unknown")
    func reccoUnknownKey() throws {
        let features = try #require(try Parsers.reccoFeatures(data(SongFactsFixtures.recco(key: -1))))
        #expect(features.key == nil)
    }

    @Test("an empty ReccoBeats reply has no features")
    func reccoEmpty() throws {
        #expect(try Parsers.reccoFeatures(data(SongFactsFixtures.reccoEmpty)) == nil)
    }

    @Test("a feel number outside 0 to 1 is dropped")
    func reccoOutOfRange() throws {
        let body = "{\"content\":[{\"isrc\":\"USUG11904206\",\"energy\":7.5,\"valence\":0.5,\"tempo\":120}]}"
        let features = try #require(try Parsers.reccoFeatures(data(body)))
        #expect(features.energy == nil)
        #expect(features.valence == 0.5)
    }

    // MARK: - MusicBrainz

    @Test("an ISRC reply lists recordings with their lengths")
    func musicBrainzRecordings() throws {
        let recordings = try Parsers.musicBrainzRecordings(data(SongFactsFixtures.musicBrainzISRC))
        #expect(recordings == [
            .init(id: SongFactsFixtures.mbid, length: 200_040, firstReleaseDate: "2019-11-29")
        ])
    }

    @Test("an error body lists no recordings")
    func musicBrainzErrorBody() throws {
        #expect(try Parsers.musicBrainzRecordings(data(SongFactsFixtures.musicBrainzError)).isEmpty)
    }

    @Test("a recording gives genres, most voted first, and its first release date")
    func musicBrainzDetail() throws {
        let detail = try Parsers.musicBrainzDetail(data(SongFactsFixtures.musicBrainzRecording))
        #expect(detail.genres == ["pop", "synth-pop"])
        #expect(detail.firstReleaseDate == "2019-11-29")
    }

    // MARK: - TheAudioDB

    @Test("TheAudioDB reads its numbers from strings, percent as 0 to 1")
    func audioDB() throws {
        let tracks = try Parsers.audioDBTracks(data(SongFactsFixtures.audioDB(isrc: "USUG11904206")))
        let track = try #require(tracks.first)
        #expect(track.title == "Blinding Lights")
        #expect(track.artist == "The Weeknd")
        #expect(track.isrc == "USUG11904206")
        #expect(track.tempo == 171)
        #expect(track.energy == 0.73)
        #expect(track.danceability == 0.52)
        #expect(track.genre == "R&B")
    }

    @Test("TheAudioDB zero means unknown, and a null track list is empty")
    func audioDBZeroAndNull() throws {
        let zero = "{\"track\":[{\"strTrack\":\"A\",\"strArtist\":\"B\",\"intTempo\":\"0\",\"intEnergy\":\"0\"}]}"
        let track = try #require(try Parsers.audioDBTracks(data(zero)).first)
        #expect(track.tempo == nil)
        #expect(track.energy == nil)
        #expect(try Parsers.audioDBTracks(data("{\"track\":null}")).isEmpty)
    }
}
