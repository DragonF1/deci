// DeciTests/Music/InnerTubeParserTopResultTests.swift
// The Top result of an unfiltered search: a card whose title carries a watch endpoint is a track (an uploaded video
// the songs filter leaves out); any other card, or no card, is no track. The two fixtures are hand built in the
// shape ytmusicapi reads, not live captures; the other shapes are written inline so each test shows what it feeds in.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("InnerTubeParser top result")
struct InnerTubeParserTopResultTests {

    private func fixture(_ name: String) throws -> Data { try MusicFixtures.data(name) }

    private func data(_ json: String) -> Data { Data(json.utf8) }

    /// A response with one card shelf. `titleEndpoint` and `subtitle` are raw JSON for the title run's endpoint and the
    /// subtitle's runs.
    private func card(title: String, titleEndpoint: String, subtitle: String) -> Data {
        data("""
        {"contents":{"tabbedSearchResultsRenderer":{"tabs":[{"tabRenderer":{"content":{"sectionListRenderer":{"contents":[
          {"musicCardShelfRenderer":{
            "thumbnail":{"musicThumbnailRenderer":{"thumbnail":{"thumbnails":[
              {"url":"https://img.example.test/card=w60-h60","width":60,"height":60},
              {"url":"https://img.example.test/card=w120-h120","width":120,"height":120}]}}},
            "title":{"runs":[{"text":"\(title)","navigationEndpoint":\(titleEndpoint)}]},
            "subtitle":{"runs":\(subtitle)}}}
        ]}}}}]}}}
        """)
    }

    private let watch = #"{"watchEndpoint":{"videoId":"vid12345"}}"#

    /// A response with only a shelf titled `title` holding one row.
    private func shelf(title: String, row: String) -> Data {
        data("""
        {"contents":{"tabbedSearchResultsRenderer":{"tabs":[{"tabRenderer":{"content":{"sectionListRenderer":{"contents":[
          {"musicShelfRenderer":{"title":{"runs":[{"text":"\(title)"}]},"contents":[\(row)]}}
        ]}}}}]}}}
        """)
    }

    // MARK: - Card shelf

    @Test("A top video card gives a track with its title, linked artist, thumbnail and no album or duration")
    func videoCard() throws {
        let track = try #require(try InnerTubeParser.searchTopResult(from: fixture("search-unfiltered-top-video.json")))
        #expect(track.videoId == "topVideo001")
        #expect(track.title == "Crab Rave Bass Boosted")
        #expect(track.artist == "Bass Channel")
        #expect(track.artistLinks == [MusicArtistLink(name: "Bass Channel", browseId: "UCbassChannel")])
        #expect(track.album == nil)
        #expect(track.durationSeconds == nil)
        #expect(track.thumbnailURL?.absoluteString == "https://img.example.test/topvideo=w120-h120")
    }

    @Test("The track comes from the card, not from the songs shelf under it")
    func cardNotShelfRow() throws {
        let track = try #require(try InnerTubeParser.searchTopResult(from: fixture("search-unfiltered-top-video.json")))
        #expect(track.videoId != "songRow001")
    }

    @Test("A top artist card is no track")
    func artistCard() throws {
        #expect(try InnerTubeParser.searchTopResult(from: fixture("search-unfiltered-top-artist.json")) == nil)
    }

    @Test("A card whose title opens an album or a playlist is no track")
    func albumAndPlaylistCards() throws {
        let album = card(
            title: "Some Album",
            titleEndpoint: #"{"browseEndpoint":{"browseId":"MPREb_x"}}"#,
            subtitle: #"[{"text":"Album"},{"text":" • "},{"text":"Artist"}]"#
        )
        let playlist = card(
            title: "Some Playlist",
            titleEndpoint: #"{"watchPlaylistEndpoint":{"playlistId":"PLx"}}"#,
            subtitle: #"[{"text":"Playlist"}]"#
        )
        #expect(try InnerTubeParser.searchTopResult(from: album) == nil)
        #expect(try InnerTubeParser.searchTopResult(from: playlist) == nil)
    }

    @Test("A song card reads its artists, album and length from the subtitle")
    func songCard() throws {
        let song = card(
            title: "Crab Rave",
            titleEndpoint: watch,
            subtitle: """
            [{"text":"Song"},{"text":" \\u2022 "},
             {"text":"Noisestorm","navigationEndpoint":{"browseEndpoint":{"browseId":"UCnoise","browseEndpointContextSupportedConfigs":{"browseEndpointContextMusicConfig":{"pageType":"MUSIC_PAGE_TYPE_ARTIST"}}}}},
             {"text":" \\u2022 "},
             {"text":"Crab Rave EP","navigationEndpoint":{"browseEndpoint":{"browseId":"MPREb_ep","browseEndpointContextSupportedConfigs":{"browseEndpointContextMusicConfig":{"pageType":"MUSIC_PAGE_TYPE_ALBUM"}}}}},
             {"text":" \\u2022 "},{"text":"3:05"}]
            """
        )
        let track = try #require(try InnerTubeParser.searchTopResult(from: song))
        #expect(track.videoId == "vid12345")
        #expect(track.artist == "Noisestorm")
        #expect(track.artistLinks.map(\.browseId) == ["UCnoise"])
        #expect(track.album == "Crab Rave EP")
        #expect(track.albumBrowseId == "MPREb_ep")
        #expect(track.durationSeconds == 185)
        #expect(track.thumbnailURL?.absoluteString == "https://img.example.test/card=w120-h120")
    }

    @Test("An artist with no page behind the name is taken from the subtitle text")
    func unlinkedArtist() throws {
        let video = card(
            title: "Live Set",
            titleEndpoint: watch,
            subtitle: #"[{"text":"Video"},{"text":" • "},{"text":"Some Uploader"},{"text":" • "},{"text":"3.1K views"}]"#
        )
        let track = try #require(try InnerTubeParser.searchTopResult(from: video))
        #expect(track.artist == "Some Uploader")
        #expect(track.artistLinks.isEmpty)
    }

    @Test("A card with a blank title or a blank video id is no track")
    func blankTitleOrId() throws {
        let blankTitle = card(title: "", titleEndpoint: watch, subtitle: "[]")
        let blankId = card(title: "Name", titleEndpoint: #"{"watchEndpoint":{"videoId":""}}"#, subtitle: "[]")
        #expect(try InnerTubeParser.searchTopResult(from: blankTitle) == nil)
        #expect(try InnerTubeParser.searchTopResult(from: blankId) == nil)
    }

    // MARK: - No card

    @Test("A response with no card and no Top result shelf is no track, even with song rows in it")
    func noCard() throws {
        #expect(try InnerTubeParser.searchTopResult(from: fixture("search-songs.json")) == nil)
    }

    @Test("An empty result is no track")
    func emptyResult() throws {
        #expect(try InnerTubeParser.searchTopResult(from: data("{}")) == nil)
    }

    @Test("A body that is not JSON throws")
    func notJSON() {
        #expect(throws: MusicError.self) { try InnerTubeParser.searchTopResult(from: Data("<html>".utf8)) }
    }

    // MARK: - Older shape

    private let row = """
    {"musicResponsiveListItemRenderer":{"flexColumns":[
      {"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"Old Shape","navigationEndpoint":{"watchEndpoint":{"videoId":"oldVid1"}}}]}}},
      {"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"Video"},{"text":" \\u2022 "},{"text":"Uploader"},{"text":" \\u2022 "},{"text":"1K views"}]}}}
    ]}}
    """

    @Test("With no card, the first row of a shelf titled Top result is the track")
    func topResultShelf() throws {
        let track = try #require(try InnerTubeParser.searchTopResult(from: shelf(title: "Top result", row: row)))
        #expect(track.videoId == "oldVid1")
        #expect(track.title == "Old Shape")
        #expect(track.artist == "Uploader")
    }

    @Test("A Top result shelf whose first row has no video id is no track")
    func topResultShelfWithoutVideo() throws {
        let artistRow = """
        {"musicResponsiveListItemRenderer":{"flexColumns":[
          {"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"Some Artist","navigationEndpoint":{"browseEndpoint":{"browseId":"UCx"}}}]}}}
        ]}}
        """
        #expect(try InnerTubeParser.searchTopResult(from: shelf(title: "Top result", row: artistRow)) == nil)
    }

    @Test("A shelf with another title is not the top result")
    func otherShelf() throws {
        #expect(try InnerTubeParser.searchTopResult(from: shelf(title: "Songs", row: row)) == nil)
    }

    @Test("A non-song card is no track even when a Top result shelf is also there")
    func cardWinsOverShelf() throws {
        // The card is what YouTube Music shows as the top result, so a shelf of the old shape is only a fallback for
        // responses that have no card at all.
        let both = data("""
        {"contents":{"tabbedSearchResultsRenderer":{"tabs":[{"tabRenderer":{"content":{"sectionListRenderer":{"contents":[
          {"musicCardShelfRenderer":{"title":{"runs":[{"text":"Artist","navigationEndpoint":{"browseEndpoint":{"browseId":"UCx"}}}]}}},
          {"musicShelfRenderer":{"title":{"runs":[{"text":"Top result"}]},"contents":[\(row)]}}
        ]}}}}]}}}
        """)
        #expect(try InnerTubeParser.searchTopResult(from: both) == nil)
    }
}
