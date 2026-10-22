// DeciTests/Music/InnerTubeParserRelatedTests.swift
// The Related songs parsers against a trimmed real answer pair: finding the Related tab's browse id in a watch-next
// answer, and reading the songs of the first song shelf in the browse answer for that id.

import Foundation
import Testing
@testable import Deci

@Suite("InnerTubeParser related songs")
struct InnerTubeParserRelatedTests {
    // MARK: - The Related tab

    @Test("The Related tab's browse id is found among the four tabs, and the Lyrics tab is not mistaken for it")
    func relatedBrowseIdFromRealAnswer() throws {
        let id = try InnerTubeParser.relatedBrowseId(inNext: YTRelatedSamples.next)
        #expect(id == YTRelatedSamples.relatedBrowseId)
        #expect(id != YTRelatedSamples.lyricsBrowseId)
        #expect(id?.hasPrefix("MPTRt") == true)
    }

    @Test("An answer with no Related tab has no browse id, and that is not an error")
    func noRelatedTab() throws {
        #expect(try InnerTubeParser.relatedBrowseId(inNext: YTRelatedSamples.nextWithoutRelatedTab) == nil)
    }

    @Test("A Related tab YouTube greys out has no browse id")
    func unselectableRelatedTab() throws {
        #expect(try InnerTubeParser.relatedBrowseId(inNext: YTRelatedSamples.nextWithUnselectableRelatedTab) == nil)
    }

    @Test("A tab whose browse id only looks like a related one is not taken")
    func lookalikePrefix() throws {
        let tab = #"{"tabRenderer":{"title":"Related","endpoint":{"browseEndpoint":{"browseId":"MPREt_fake"}}}}"#
        let data = Data(#"{"contents":{"tabs":[\#(tab)]}}"#.utf8)
        #expect(try InnerTubeParser.relatedBrowseId(inNext: data) == nil)
    }

    @Test("A tab is greyed out only by `unselectable: true`, or by a value that is not a boolean", arguments: [
        (#","unselectable":true"#, false),
        (#","unselectable":false"#, true),
        ("", true),
        (#","unselectable":null"#, true),
        (#","unselectable":{}"#, false),
        (#","unselectable":"true""#, false),
        (#","unselectable":[]"#, false),
    ])
    func unselectableReadings(extra: String, isSelectable: Bool) throws {
        let tab = #"{"tabRenderer":{"title":"Related","endpoint":{"browseEndpoint":{"browseId":"MPTRt_x"}}\#(extra)}}"#
        let data = Data(#"{"contents":{"tabs":[\#(tab)]}}"#.utf8)
        #expect(try InnerTubeParser.relatedBrowseId(inNext: data) == (isSelectable ? "MPTRt_x" : nil))
    }

    @Test("An answer with no tabs at all has no Related tab: no related songs, not an error")
    func noTabsMeansNoRelatedTab() throws {
        #expect(try InnerTubeParser.relatedBrowseId(inNext: Data("{}".utf8)) == nil)
        #expect(try InnerTubeParser.relatedBrowseId(inNext: Data(#"{"contents":{"tabs":[]}}"#.utf8)) == nil)
    }

    @Test("An answer that is not JSON is a parse error")
    func notAWatchNextAnswer() {
        #expect(throws: MusicError.self) { try InnerTubeParser.relatedBrowseId(inNext: Data("<html>".utf8)) }
        #expect(throws: MusicError.self) { try InnerTubeParser.relatedBrowseId(inNext: Data()) }
    }

    // MARK: - The songs

    @Test("The first shelf's songs come back in order, and the playlist shelf and the second song shelf are left out")
    func songsOfTheFirstShelf() throws {
        let tracks = try InnerTubeParser.relatedTracks(from: YTRelatedSamples.browse)
        #expect(tracks.map(\.videoId) == YTRelatedSamples.songShelfVideoIds)
        #expect(tracks.map(\.title) == ["Africa", "Everybody Wants To Rule The World", "Every Breath You Take"])
    }

    @Test("A song row carries its artist and artist page, album and album page, and a 120 px cover")
    func songFields() throws {
        let africa = try #require(try InnerTubeParser.relatedTracks(from: YTRelatedSamples.browse).first)
        #expect(africa.artist == "Toto")
        #expect(africa.artistLinks == [MusicArtistLink(name: "Toto", browseId: "UCewH1MBbYlEZMWx3ZUNywyg")])
        #expect(africa.album == "Toto IV")
        #expect(africa.albumBrowseId == "MPREb_dL9I6V1S1Ta")
        #expect(africa.thumbnailURL?.absoluteString.contains("=w120-h120") == true)
        // Related rows come without a length, so none is invented.
        #expect(africa.durationSeconds == nil)
        #expect(africa.playlistSetVideoId == nil)
    }

    @Test("A playlist shelf that comes first is skipped for the first shelf that holds songs")
    func skipsATileShelfAtTheFront() throws {
        let data = YTRelatedSamples.browse(shelves: [1, 2])
        let tracks = try InnerTubeParser.relatedTracks(from: data)
        #expect(tracks.map(\.videoId) == YTRelatedSamples.otherShelfVideoIds)
    }

    @Test("Two song shelves are not merged: only the first one counts")
    func firstSongShelfOnly() throws {
        let data = YTRelatedSamples.browse(shelves: [0, 1, 2])
        let tracks = try InnerTubeParser.relatedTracks(from: data)
        #expect(tracks.map(\.videoId) == YTRelatedSamples.songShelfVideoIds)
    }

    @Test("An answer whose shelves hold no songs is an empty list, not an error")
    func noSongShelf() throws {
        let data = YTRelatedSamples.browse(shelves: [1])
        #expect(try InnerTubeParser.relatedTracks(from: data).isEmpty)
    }

    @Test("A section list with no shelves is an empty list")
    func emptySectionList() throws {
        let data = Data(#"{"contents":{"sectionListRenderer":{"contents":[]}}}"#.utf8)
        #expect(try InnerTubeParser.relatedTracks(from: data).isEmpty)
    }

    @Test("An answer with no section list, or that is not JSON, is a parse error")
    func notABrowseAnswer() {
        #expect(throws: MusicError.self) { try InnerTubeParser.relatedTracks(from: Data("{}".utf8)) }
        #expect(throws: MusicError.self) { try InnerTubeParser.relatedTracks(from: Data("<html>".utf8)) }
        #expect(throws: MusicError.self) { try InnerTubeParser.relatedTracks(from: Data()) }
    }

    @Test("The songs come from the first section list that has a song shelf, however many lists come before it")
    func firstListWithASongShelf() throws {
        let tiles = try shelfJSON(index: 1)
        let songs = try shelfJSON(index: 0)
        let data = try JSONSerialization.data(withJSONObject: [
            "contents": [
                ["sectionListRenderer": ["contents": [tiles]]],
                ["sectionListRenderer": ["contents": []]],
                ["sectionListRenderer": ["contents": [songs]]],
            ],
        ])
        let tracks = try InnerTubeParser.relatedTracks(from: data)
        #expect(tracks.map(\.videoId) == YTRelatedSamples.songShelfVideoIds)
    }

    @Test("Section lists with no song shelf at all are an empty list")
    func listsWithoutSongs() throws {
        let tiles = try shelfJSON(index: 1)
        let data = try JSONSerialization.data(withJSONObject: [
            "contents": [
                ["sectionListRenderer": ["contents": [tiles]]],
                ["sectionListRenderer": ["contents": []]],
            ],
        ])
        #expect(try InnerTubeParser.relatedTracks(from: data).isEmpty)
    }

    @Test("A song shelf with a tile mixed in keeps the songs and drops the tile")
    func songsOnlyInAMixedShelf() throws {
        let songs = try shelfJSON(index: 0)
        let tiles = try shelfJSON(index: 1)
        let mixed = try replacingContents(of: songs, with: contents(of: songs) + contents(of: tiles))
        let data = try JSONSerialization.data(withJSONObject: [
            "contents": ["sectionListRenderer": ["contents": [mixed]]],
        ])
        let tracks = try InnerTubeParser.relatedTracks(from: data)
        #expect(tracks.map(\.videoId) == YTRelatedSamples.songShelfVideoIds)
    }

    // MARK: - Helpers

    private func shelves() throws -> [[String: Any]] {
        let root = try #require(try JSONSerialization.jsonObject(with: YTRelatedSamples.browse) as? [String: Any])
        let list = try #require((root["contents"] as? [String: Any])?["sectionListRenderer"] as? [String: Any])
        return try #require(list["contents"] as? [[String: Any]])
    }

    private func shelfJSON(index: Int) throws -> [String: Any] {
        try shelves()[index]
    }

    private func contents(of shelf: [String: Any]) throws -> [Any] {
        let carousel = try #require(shelf["musicCarouselShelfRenderer"] as? [String: Any])
        return try #require(carousel["contents"] as? [Any])
    }

    private func replacingContents(of shelf: [String: Any], with contents: [Any]) throws -> [String: Any] {
        var carousel = try #require(shelf["musicCarouselShelfRenderer"] as? [String: Any])
        carousel["contents"] = contents
        return ["musicCarouselShelfRenderer": carousel]
    }
}
