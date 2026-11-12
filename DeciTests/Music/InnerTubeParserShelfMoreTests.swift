// DeciTests/Music/InnerTubeParserShelfMoreTests.swift
// The "Show all" link of an artist page's shelves, the full-list parse of a shelf's more page, and creator channels
// (MUSIC_PAGE_TYPE_USER_CHANNEL) read as artist pages. browse-artist-releases.json, browse-creator-channel.json and
// browse-artist-playlists-grid.json are anonymous captures from music.youtube.com (visitor data scrubbed, shelves
// trimmed to two tiles, menus removed).

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("InnerTubeParser shelf more links")
struct InnerTubeParserShelfMoreTests {
    private static let taylor = "UCPC0L1d253x-KuMNwa05TpA"

    private func fixture(_ name: String) throws -> Data { try MusicFixtures.data(name) }

    private func releases() throws -> MusicBrowsePage {
        try InnerTubeParser.browsePage(from: fixture("browse-artist-releases.json"), browseId: Self.taylor)
    }

    private func shelf(_ title: String, in page: MusicBrowsePage) throws -> MusicShelf {
        try #require(page.shelves.first { $0.title == title })
    }

    // MARK: - Capture

    @Test("Artist capture: Albums and Singles & EPs keep their discography page and params")
    func releasesLinks() throws {
        let page = try releases()
        #expect(try shelf("Albums", in: page).more == MusicDiscographyLink(browseId: "MPAD" + Self.taylor, params: "ggMIegYIARoCAQI%3D"))
        #expect(try shelf("Singles & EPs", in: page).more == MusicDiscographyLink(browseId: "MPAD" + Self.taylor, params: "ggMIegYIAhoCAQI%3D"))
    }

    @Test("Artist capture: Videos links a playlist page, the playlists and live shelves link the channel with long params")
    func otherLinks() throws {
        let page = try releases()
        let videos = try #require(try shelf("Videos", in: page).more)
        #expect(videos.browseId.hasPrefix("VL"))
        #expect(videos.params == "ggMCCAI%3D")
        for title in ["Playlists by Taylor Swift", "Live performances"] {
            let link = try #require(try shelf(title, in: page).more)
            #expect(link.browseId == Self.taylor)
            #expect(link.params?.hasPrefix("6gPg") == true)
        }
    }

    @Test("Artist capture: Featured on and Fans might also like have no more link")
    func shelvesWithoutMore() throws {
        let page = try releases()
        #expect(try shelf("Featured on", in: page).more == nil)
        #expect(try shelf("Fans might also like", in: page).more == nil)
    }

    @Test("Artist capture: every shelf keeps the id it had before the link was read")
    func shelfIdsUnchanged() throws {
        let page = try releases()
        for shelf in page.shelves {
            #expect(shelf.id == shelf.title + "|" + (shelf.items.first?.id ?? ""))
        }
    }

    @Test("Artist capture: discography links still hold the two MPAD pages and nothing else")
    func discographyLinksUnchanged() throws {
        #expect(try releases().discographyLinks.count == 2)
    }

    @Test("Home capture: no shelf carries a more link, only artist pages read them")
    func homeShelvesHaveNone() throws {
        let page = try InnerTubeParser.homePage(from: fixture("browse-home.json"))
        #expect(page.shelves.allSatisfy { $0.more == nil })
    }

    @Test("Playlist and album captures have no shelf links")
    func playlistPagesHaveNone() throws {
        let playlist = try InnerTubeParser.browsePage(from: fixture("browse-playlist.json"), browseId: "VLPL4fGSI1pDJn6puJdseH2Rt9sMvt9E2M4i")
        #expect(playlist.shelves.allSatisfy { $0.more == nil })
    }

    // MARK: - Hand-built headers

    private func carousel(title: String, titleEndpoint: String?, moreEndpoint: String?) -> String {
        let endpoint = titleEndpoint.map { #","navigationEndpoint":{"browseEndpoint":\#($0)}"# } ?? ""
        let more = moreEndpoint.map { #","moreContentButton":{"buttonRenderer":{"navigationEndpoint":{"browseEndpoint":\#($0)}}}"# } ?? ""
        let tile = """
        {"musicTwoRowItemRenderer":{"title":{"runs":[{"text":"Tile"}]},"navigationEndpoint":{"browseEndpoint":{"browseId":"VLPLtile"}}}}
        """
        return """
        {"musicCarouselShelfRenderer":{"header":{"musicCarouselShelfBasicHeaderRenderer":{"title":{"runs":[{"text":"\(title)"\(endpoint)}]}\(more)}},"contents":[\(tile)]}}
        """
    }

    private func page(_ sections: [String], header: String = "musicImmersiveHeaderRenderer") throws -> MusicBrowsePage {
        let json = """
        {"header":{"\(header)":{"title":{"runs":[{"text":"Someone"}]}}},\
        "contents":{"singleColumnBrowseResultsRenderer":{"tabs":[{"tabRenderer":{"content":{"sectionListRenderer":{"contents":[\
        \(sections.joined(separator: ","))]}}}}]}}}
        """
        return try InnerTubeParser.browsePage(from: Data(json.utf8), browseId: "UCsomeone")
    }

    private func endpoint(_ id: String, params: String? = nil) -> String {
        #"{"browseId":"\#(id)"\#(params.map { #","params":"\#($0)""# } ?? "")}"#
    }

    @Test("Hand-built: the title run's endpoint wins over the more button")
    func titleBeforeMore() throws {
        let sections = [carousel(title: "Albums", titleEndpoint: endpoint("MPADt", params: "PT"), moreEndpoint: endpoint("MPADm", params: "PM"))]
        #expect(try page(sections).shelves.first?.more == MusicDiscographyLink(browseId: "MPADt", params: "PT"))
    }

    @Test("Hand-built: the more button gives the link when the title has no endpoint")
    func moreButtonAlone() throws {
        let sections = [carousel(title: "Playlists", titleEndpoint: nil, moreEndpoint: endpoint("UCsomeone", params: "6gPx"))]
        #expect(try page(sections).shelves.first?.more == MusicDiscographyLink(browseId: "UCsomeone", params: "6gPx"))
    }

    @Test("Hand-built: a header that only names a page (an artist with no params, an album) is no more link")
    func plainDestinationsAreNotMore() throws {
        let sections = [
            carousel(title: "Fans might also like", titleEndpoint: endpoint("UCother"), moreEndpoint: nil),
            carousel(title: "From the album", titleEndpoint: endpoint("MPREb_album"), moreEndpoint: nil),
        ]
        #expect(try page(sections).shelves.allSatisfy { $0.more == nil })
    }

    @Test("Hand-built: a creator channel's visual header reads its shelf links too")
    func visualHeaderReadsLinks() throws {
        let sections = [carousel(title: "Playlists", titleEndpoint: nil, moreEndpoint: endpoint("UCsomeone", params: "6gPy"))]
        let creator = try page(sections, header: "musicVisualHeaderRenderer")
        #expect(creator.shelves.first?.more == MusicDiscographyLink(browseId: "UCsomeone", params: "6gPy"))
    }

    private func typed(_ id: String, params: String? = nil, pageType: String) -> String {
        #"{"browseId":"\#(id)"\#(params.map { #","params":"\#($0)""# } ?? ""),"browseEndpointContextSupportedConfigs":{"browseEndpointContextMusicConfig":{"pageType":"\#(pageType)"}}}"#
    }

    private func moreOf(_ endpoint: String) throws -> MusicDiscographyLink? {
        try page([carousel(title: "Shelf", titleEndpoint: endpoint, moreEndpoint: nil)]).shelves.first?.more
    }

    @Test("Page type: a discography page, a playlist, and a channel (artist or user channel) with params are links")
    func typedAccepted() throws {
        #expect(try moreOf(typed("MPADx", params: "P", pageType: "MUSIC_PAGE_TYPE_ARTIST_DISCOGRAPHY")) == MusicDiscographyLink(browseId: "MPADx", params: "P"))
        #expect(try moreOf(typed("VLOLAKx", params: "P", pageType: "MUSIC_PAGE_TYPE_PLAYLIST")) == MusicDiscographyLink(browseId: "VLOLAKx", params: "P"))
        #expect(try moreOf(typed("UCx", params: "6gP", pageType: "MUSIC_PAGE_TYPE_ARTIST")) == MusicDiscographyLink(browseId: "UCx", params: "6gP"))
        #expect(try moreOf(typed("UCx", params: "6gP", pageType: "MUSIC_PAGE_TYPE_USER_CHANNEL")) == MusicDiscographyLink(browseId: "UCx", params: "6gP"))
    }

    @Test("Page type: album, artist and user-channel endpoints with no list behind them are not links, even with params on an album")
    func typedRejected() throws {
        #expect(try moreOf(typed("MPREb_a", pageType: "MUSIC_PAGE_TYPE_ALBUM")) == nil)
        #expect(try moreOf(typed("MPREb_a", params: "P", pageType: "MUSIC_PAGE_TYPE_ALBUM")) == nil)
        #expect(try moreOf(typed("UCx", pageType: "MUSIC_PAGE_TYPE_ARTIST")) == nil)
        #expect(try moreOf(typed("UCx", pageType: "MUSIC_PAGE_TYPE_USER_CHANNEL")) == nil)
        // The page type outranks the id, as it does for the discography links.
        #expect(try moreOf(typed("MPADx", params: "P", pageType: "MUSIC_PAGE_TYPE_ALBUM")) == nil)
    }

    @Test("No page type: the id prefix decides, and an album id with params is still not a link")
    func untypedByPrefix() throws {
        #expect(try moreOf(endpoint("MPADx")) != nil)
        #expect(try moreOf(endpoint("VLx")) != nil)
        #expect(try moreOf(endpoint("UCx", params: "6gP")) != nil)
        #expect(try moreOf(endpoint("UCx")) == nil)
        #expect(try moreOf(endpoint("MPREb_a", params: "P")) == nil)
    }

    // MARK: - Creator channels

    private func endpointConfig(pageType: String, id: String) -> [String: Any] {
        [
            "browseId": id,
            "browseEndpointContextSupportedConfigs": ["browseEndpointContextMusicConfig": ["pageType": pageType]],
        ]
    }

    @Test("A user channel page type is an artist, with or without the UC prefix")
    func userChannelKind() {
        #expect(InnerTubeParser.collectionKind(of: endpointConfig(pageType: "MUSIC_PAGE_TYPE_USER_CHANNEL", id: "UCOxqgCwgOqC2lMqC5PYz_Dg")) == .artist)
        #expect(InnerTubeParser.collectionKind(of: endpointConfig(pageType: "MUSIC_PAGE_TYPE_USER_CHANNEL", id: "weird")) == .artist)
    }

    @Test("Page types Deci still does not open stay dropped")
    func unknownKindsStayDropped() {
        #expect(InnerTubeParser.collectionKind(of: endpointConfig(pageType: "MUSIC_PAGE_TYPE_PODCAST_SHOW_DETAIL_PAGE", id: "MPSPPLx")) == nil)
        #expect(InnerTubeParser.collectionKind(of: endpointConfig(pageType: "MUSIC_PAGE_TYPE_AUDIOBOOK", id: "MPAB")) == nil)
    }

    @Test("A search or shelf tile for a creator channel becomes an artist collection")
    func userChannelTile() throws {
        let tile = """
        {"musicTwoRowItemRenderer":{"title":{"runs":[{"text":"Chillhop Music"}]},\
        "subtitle":{"runs":[{"text":"Channel"}]},\
        "navigationEndpoint":{"browseEndpoint":{"browseId":"UCOxqgCwgOqC2lMqC5PYz_Dg","browseEndpointContextSupportedConfigs":{"browseEndpointContextMusicConfig":{"pageType":"MUSIC_PAGE_TYPE_USER_CHANNEL"}}}}}}
        """
        let section = try #require(try JSONSerialization.jsonObject(with: Data("""
        {"musicCarouselShelfRenderer":{"header":{"musicCarouselShelfBasicHeaderRenderer":{"title":{"runs":[{"text":"Channels"}]}}},"contents":[\(tile)]}}
        """.utf8)) as? [String: Any])
        let shelf = try #require(InnerTubeParser.shelf(from: section))
        guard case .collection(let channel)? = shelf.items.first else { Issue.record("no collection"); return }
        #expect(channel.kind == .artist)
        #expect(channel.browseId == "UCOxqgCwgOqC2lMqC5PYz_Dg")
    }

    @Test("Creator capture: the page reads as an artist page with its Videos and Playlists shelves and their more links")
    func creatorPage() throws {
        let page = try InnerTubeParser.browsePage(from: fixture("browse-creator-channel.json"), browseId: "UCOxqgCwgOqC2lMqC5PYz_Dg")
        #expect(page.title == "Chillhop Music")
        #expect(page.shelves.map(\.title) == ["Videos", "Playlists"])
        #expect(page.shelves.allSatisfy { $0.more?.browseId == "UCOxqgCwgOqC2lMqC5PYz_Dg" && $0.more?.params?.hasPrefix("6gP") == true })
        let playlists = try shelf("Playlists", in: page)
        let collections = playlists.items.compactMap { item -> MusicCollection? in
            if case .collection(let collection) = item { collection } else { nil }
        }
        #expect(collections.count == playlists.items.count)
        #expect(collections.allSatisfy { $0.kind == .playlist })
    }

    // MARK: - Full list parse

    @Test("Playlists capture: the grid under the tab parses to every playlist, with no continuation")
    func playlistsGrid() throws {
        let list = try InnerTubeParser.libraryPage(from: fixture("browse-artist-playlists-grid.json"))
        #expect(list.items.count == 3)
        #expect(list.items.allSatisfy { $0.kind == .playlist && $0.browseId.hasPrefix("VLPL") })
        #expect(list.items.allSatisfy { !$0.title.isEmpty && $0.thumbnailURL != nil })
        #expect(list.items.first?.subtitle.hasPrefix("Playlist") == true)
        #expect(list.continuation == nil)
    }
}
