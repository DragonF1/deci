// DeciTests/Music/InnerTubeParserAlbumsTests.swift
// Albums in search results (the albums filter). search-albums.json is hand built, in the shape of a real albums search:
// made-up names and ids, album rows mixed with rows that are not albums.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("InnerTubeParser albums")
struct InnerTubeParserAlbumsTests {

    private func fixture(_ name: String) throws -> Data { try MusicFixtures.data(name) }

    private func albums() throws -> [MusicCollection] {
        try InnerTubeParser.searchAlbums(from: fixture("search-albums.json"))
    }

    /// An albums response holding `rows` (each a `musicResponsiveListItemRenderer` body), as JSON.
    private static func albumsJSON(rows: [String]) -> Data {
        let items = rows.map { "{\"musicResponsiveListItemRenderer\": \($0)}" }.joined(separator: ",")
        return Data("{\"contents\":{\"tabbedSearchResultsRenderer\":{\"tabs\":[{\"tabRenderer\":{\"content\":{\"sectionListRenderer\":{\"contents\":[{\"musicShelfRenderer\":{\"contents\":[\(items)]}}]}}}}]}}}".utf8)
    }

    private static func albumRow(
        _ title: String, id: String, subtitle: [String] = ["Album", " \u{2022} ", "Someone", " \u{2022} ", "2019"]
    ) -> String {
        let runs = subtitle.map { "{\"text\": \"\($0)\"}" }.joined(separator: ",")
        return """
        {"flexColumns":[
          {"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"\(title)"}]}}},
          {"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[\(runs)]}}}],
         "navigationEndpoint":{"browseEndpoint":{"browseId":"\(id)"}}}
        """
    }

    @Test("The fixture says it is hand built")
    func fixtureIsMarked() throws {
        let root = try #require(JSONSerialization.jsonObject(with: fixture("search-albums.json")) as? [String: Any])
        #expect(root["_handBuilt"] is String)
    }

    // MARK: - Which rows

    @Test("Album search keeps the album rows in order, singles and EPs too, and drops every other kind of row")
    func albumsKeepOnlyAlbums() throws {
        let found = try albums()
        #expect(found.map(\.browseId) == ["MPREb_albumA", "MPREb_singleB", "MPREb_epD", "MPREb_albumZ"])
        #expect(found.map(\.title) == ["Alpha Album", "Beta Single", "Delta EP", "Zeta Album"])
        #expect(found.allSatisfy { $0.kind == .album })
    }

    @Test("A row that is a song, an artist, a playlist, greyed out, without a destination or without a title is skipped")
    func notAlbumsSkipped() throws {
        let ids = try albums().map(\.browseId)
        #expect(!ids.contains("UCartistA"))
        #expect(!ids.contains("VLPLalphaMix"))
        #expect(!ids.contains("MPREb_grey"))
        #expect(!ids.contains("MPREb_blank"))
        #expect(try albums().allSatisfy { !$0.title.isEmpty && $0.title != "Alpha Song" && $0.title != "Orphan Album" })
    }

    @Test("A repeated album appears once, at its first place and with its first cover")
    func albumsDedupe() throws {
        let found = try albums()
        #expect(found.filter { $0.browseId == "MPREb_albumA" }.count == 1)
        #expect(found.first?.thumbnailURL?.absoluteString == "https://img.example.test/alpha=w226-h226")
    }

    @Test("An album with no page type is told apart by its MPRE id")
    func typelessAlbum() throws {
        let found = try albums()
        let delta = try #require(found.first { $0.browseId == "MPREb_epD" })
        #expect(delta.kind == .album)
    }

    @Test("A row whose id is not an MPRE id is not an album, whatever its page type says")
    func nonAlbumIdSkipped() throws {
        let json = Self.albumsJSON(rows: [
            Self.albumRow("Good", id: "MPREb_good"),
            Self.albumRow("Channel", id: "UCchannel"),
            Self.albumRow("Mix", id: "VLPLmix"),
        ])
        #expect(try InnerTubeParser.searchAlbums(from: json).map(\.browseId) == ["MPREb_good"])
    }

    // MARK: - What an album carries

    @Test("The subtitle keeps YouTube's own line: kind, artist and year, with the bullets")
    func albumsSubtitle() throws {
        #expect(try albums().map(\.subtitle) == [
            "Album \u{2022} Artist Alpha \u{2022} 2019",
            "Single \u{2022} Artist Beta \u{2022} 2021",
            "EP \u{2022} Artist Delta \u{2022} 2020",
            "Album \u{2022} Artist Zeta",
        ])
    }

    @Test("The release year reads from the subtitle, and an album with none has no year")
    func albumsYear() throws {
        #expect(try albums().map(\.releaseYear) == [2019, 2021, 2020, nil])
    }

    @Test("A linked artist in the subtitle is an artist link; a name with no page is not")
    func albumsArtistLinks() throws {
        let found = try albums()
        #expect(found[0].artistLinks == [MusicArtistLink(name: "Artist Alpha", browseId: "UCartistA")])
        #expect(found[2].artistLinks.isEmpty)
    }

    @Test("The play button's OLAK playlist is the album's audio playlist; a row without one has none")
    func albumsAudioPlaylist() throws {
        #expect(try albums().map(\.audioPlaylistId) == ["OLAK5uy_alphaAlbum", nil, nil, nil])
    }

    @Test("The cover is the largest one the row offers, and a row with none has a nil cover")
    func albumsLargestThumbnail() throws {
        let found = try albums()
        #expect(found[0].thumbnailURL?.absoluteString == "https://img.example.test/alpha=w226-h226")
        #expect(found[1].thumbnailURL?.absoluteString == "https://img.example.test/beta=w226-h226")
        #expect(found[2].thumbnailURL == nil)
    }

    // MARK: - Empty and broken responses

    @Test("An empty response, an empty shelf and a message shelf give no albums")
    func albumsEmpty() throws {
        #expect(try InnerTubeParser.searchAlbums(from: Data("{}".utf8)).isEmpty)
        #expect(try InnerTubeParser.searchAlbums(from: Self.albumsJSON(rows: [])).isEmpty)
        let message = "{\"contents\":{\"tabbedSearchResultsRenderer\":{\"tabs\":[{\"tabRenderer\":{\"content\":{\"sectionListRenderer\":{\"contents\":[{\"itemSectionRenderer\":{\"contents\":[{\"messageRenderer\":{\"text\":{\"runs\":[{\"text\":\"No results found\"}]}}}]}}]}}}}]}}}"
        #expect(try InnerTubeParser.searchAlbums(from: Data(message.utf8)).isEmpty)
    }

    @Test("A body that is not JSON throws a parse error")
    func albumsBrokenBody() {
        #expect(throws: MusicError.self) { try InnerTubeParser.searchAlbums(from: Data("<html>".utf8)) }
        #expect(throws: MusicError.self) { try InnerTubeParser.searchAlbums(from: Data()) }
    }

    @Test("A songs response has no album rows, and an artists response gives only the one album row it holds")
    func otherSearchesHoldFewAlbums() throws {
        #expect(try InnerTubeParser.searchAlbums(from: fixture("search-songs.json")).isEmpty)
        #expect(try InnerTubeParser.searchAlbums(from: fixture("search-artists.json")).map(\.browseId) == ["MPREbAlbumC"])
    }

    @Test("Unicode, emoji and quotes in a title survive")
    func albumsUnicodeTitle() throws {
        let row = Self.albumRow("夜に駆ける \u{1F3B5} caf\u{00E9} \\\"x\\\"", id: "MPREb_u")
        #expect(try InnerTubeParser.searchAlbums(from: Self.albumsJSON(rows: [row])).first?.title == "夜に駆ける \u{1F3B5} caf\u{00E9} \"x\"")
    }

    @Test("A large response is read whole")
    func albumsLarge() throws {
        let rows = (0..<2_000).map { Self.albumRow("Album \($0)", id: "MPREb_\($0)") }
        #expect(try InnerTubeParser.searchAlbums(from: Self.albumsJSON(rows: rows)).count == 2_000)
    }
}
