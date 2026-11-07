// DeciTests/Music/SongFacts/SongFactsTestSupport.swift
// A stub transport, a manual clock and trimmed service replies shared by the song facts tests. No live network.

import Foundation
import os
import Testing
@testable import Deci

/// Answers by URL fragment, in the order the routes were given, and records every request. An unrouted URL is a 404.
nonisolated final class StubSongFactsTransport: HTTPTransport, @unchecked Sendable {
    struct Route {
        var fragment: String
        var replies: [Result<HTTPResponse, URLError>]
    }

    private struct State {
        var routes: [Route]
        var requests: [HTTPRequest] = []
    }

    private let state: OSAllocatedUnfairLock<State>

    init(_ routes: [(String, HTTPResponse)] = []) {
        state = OSAllocatedUnfairLock(initialState: State(routes: routes.map { Route(fragment: $0.0, replies: [.success($0.1)]) }))
    }

    /// A route that answers each call in turn, the last answer repeating.
    func route(_ fragment: String, _ replies: [Result<HTTPResponse, URLError>]) {
        state.withLock { $0.routes.insert(Route(fragment: fragment, replies: replies), at: 0) }
    }

    var requests: [HTTPRequest] { state.withLock { $0.requests } }
    var urls: [String] { requests.map(\.url.absoluteString) }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let reply: Result<HTTPResponse, URLError>? = state.withLock { state in
            state.requests.append(request)
            let url = request.url.absoluteString
            guard let index = state.routes.firstIndex(where: { url.contains($0.fragment) }) else { return nil }
            if state.routes[index].replies.count > 1 { return state.routes[index].replies.removeFirst() }
            return state.routes[index].replies.first
        }
        guard let reply else { return SongFactsFixtures.ok("{}", status: 404) }
        return try reply.get()
    }
}

/// A clock and a sleep that costs nothing: the sleeps asked for are recorded.
nonisolated final class SongFactsClock: @unchecked Sendable {
    private let state: OSAllocatedUnfairLock<(date: Date, sleeps: [Int])>

    init(_ date: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        state = OSAllocatedUnfairLock(initialState: (date, []))
    }

    var date: Date { state.withLock { $0.date } }
    /// Milliseconds, in the order asked.
    var sleeps: [Int] { state.withLock { $0.sleeps } }

    func advance(days: Double) { state.withLock { $0.date = $0.date.addingTimeInterval(days * 86_400) } }

    func now() -> Date { date }

    func sleep(_ duration: Duration) async throws {
        let parts = duration.components
        let ms = Int(parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000)
        state.withLock { $0.sleeps.append(ms) }
    }
}

nonisolated enum SongFactsFixtures {
    static let isrc = "USUG11904206"
    static let mbid = "6493b1ac-87ca-4da5-8eaa-db254186e702"

    static func ok(_ json: String, status: Int = 200, headers: [String: String] = [:]) -> HTTPResponse {
        HTTPResponse(statusCode: status, headers: headers, data: Data(json.utf8))
    }

    /// One Deezer search hit.
    static func hit(
        id: Int = 908_604_612, title: String = "Blinding Lights", version: String = "", duration: Int = 200, rank: Int = 984_833,
        artist: String = "The Weeknd", isrc: String = SongFactsFixtures.isrc, explicit: Bool = false
    ) -> String {
        """
        {"id":\(id),"title":"\(title)","title_short":"\(title)","title_version":"\(version)","isrc":"\(isrc)","duration":\(duration),\
        "rank":\(rank),"explicit_lyrics":\(explicit),"artist":{"id":4050205,"name":"\(artist)"}}
        """
    }

    static func search(_ hits: String...) -> String { "{\"data\":[\(hits.joined(separator: ","))],\"total\":\(hits.count)}" }

    static func deezerTrack(bpm: Double = 0) -> String {
        """
        {"id":908604612,"title":"Blinding Lights","isrc":"\(isrc)","duration":200,"rank":984833,"release_date":"2020-03-20",\
        "explicit_lyrics":false,"bpm":\(bpm),"gain":-8.2,"album":{"id":137217782,"title":"After Hours"}}
        """
    }

    static let deezerAlbum = """
    {"id":137217782,"title":"After Hours","label":"Republic Records","genres":{"data":[{"id":165,"name":"R&B"}]}}
    """

    static func recco(isrc: String = SongFactsFixtures.isrc, tempo: Double = 171.005, key: Int = 1) -> String {
        """
        {"content":[{"id":"e0dda98e-cf71-49f0-bf02-3ae34a66f584","isrc":"\(isrc)","acousticness":0.00146,"danceability":0.514,\
        "energy":0.73,"instrumentalness":0.0000954,"key":\(key),"liveness":0.0897,"loudness":-5.934,"mode":1,\
        "speechiness":0.0598,"tempo":\(tempo),"valence":0.334}]}
        """
    }

    static let reccoEmpty = "{\"content\":[]}"

    static let musicBrainzISRC = """
    {"isrc":"\(isrc)","recordings":[{"id":"\(mbid)","title":"Blinding Lights","length":200040,"first-release-date":"2019-11-29"}]}
    """

    static let musicBrainzRecording = """
    {"id":"\(mbid)","genres":[{"count":1,"name":"synth-pop"},{"count":3,"name":"pop"}],"first-release-date":"2019-11-29","length":200040}
    """

    static let musicBrainzError = """
    {"help":"For usage, please see: https://musicbrainz.org/development/mmd","error":"genres is not a valid inc parameter for the isrc resource."}
    """

    static func audioDB(isrc: String? = nil) -> String {
        let code = isrc.map { "\"\($0)\"" } ?? "null"
        return """
        {"track":[{"strTrack":"Blinding Lights","strArtist":"The Weeknd","strISRC":\(code),"strGenre":"R&B","strMood":"",\
        "intTempo":"171","intDanceability":"52","intEnergy":"73"}]}
        """
    }

    /// The whole happy path: every service answers.
    static func fullRoutes() -> [(String, HTTPResponse)] {
        [
            ("api.deezer.com/search", ok(search(hit()))),
            ("api.deezer.com/track/908604612", ok(deezerTrack())),
            ("api.deezer.com/album/137217782", ok(deezerAlbum)),
            ("api.reccobeats.com/v1/audio-features", ok(recco())),
            ("musicbrainz.org/ws/2/isrc/", ok(musicBrainzISRC)),
            ("musicbrainz.org/ws/2/recording/", ok(musicBrainzRecording)),
            ("theaudiodb.com", ok(audioDB()))
        ]
    }

    static let query = MusicSongFactsQuery(artist: "The Weeknd", title: "Blinding Lights", durationSeconds: 200)
}
