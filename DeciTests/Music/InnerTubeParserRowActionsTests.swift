// DeciTests/Music/InnerTubeParserRowActionsTests.swift
// What the parser takes from a row for the song actions: the album's page id, the row's place in an editable
// playlist, whether the page is editable, and how the two write responses (edit playlist, the picker's list)
// are read. Every row here is hand-built with made-up ids, in the shape of YouTube's renderers;
// add-to-playlist-options.json is hand-written the same way.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("InnerTubeParser row actions")
struct InnerTubeParserRowActionsTests {

    private func fixture(_ name: String) throws -> Data { try MusicFixtures.data(name) }

    // MARK: - Album id on search rows

    @Test("A search row's album run gives the album's page id")
    func searchRowAlbumId() throws {
        let row = Self.songRow("s1", subtitle: [
            Self.run("Artist One", id: "UCone"), Self.run(" \u{2022} "),
            Self.run("Album One", id: "MPREbAlbumOne", page: "MUSIC_PAGE_TYPE_ALBUM"), Self.run(" \u{2022} "), Self.run("3:05"),
        ])
        let track = try #require(InnerTubeParser.searchTracks(from: Self.searchJSON(rows: [row])).first)
        #expect(track.album == "Album One")
        #expect(track.albumBrowseId == "MPREbAlbumOne")
    }

    @Test("A row with no album, or an album with no page, has no album id")
    func searchRowWithoutAlbumId() throws {
        let noAlbum = Self.songRow("a", subtitle: [Self.run("Artist", id: "UCone"), Self.run(" \u{2022} "), Self.run("3:05")])
        let unlinked = Self.songRow("b", subtitle: [Self.run("Artist", id: "UCone"), Self.run(" \u{2022} "), Self.run("Plain Album"), Self.run(" \u{2022} "), Self.run("3:05")])
        let tracks = try InnerTubeParser.searchTracks(from: Self.searchJSON(rows: [noAlbum, unlinked]))
        #expect(tracks.map(\.albumBrowseId) == [nil, nil])
    }

    @Test("An artist or playlist link is never taken for the album")
    func otherLinksAreNotTheAlbum() throws {
        let row = Self.songRow("s1", subtitle: [
            Self.run("Artist", id: "UCone"), Self.run(" \u{2022} "),
            Self.run("Some Playlist", id: "VLPLfixture", page: "MUSIC_PAGE_TYPE_PLAYLIST"), Self.run(" \u{2022} "), Self.run("3:05"),
        ])
        let track = try #require(InnerTubeParser.searchTracks(from: Self.searchJSON(rows: [row])).first)
        #expect(track.albumBrowseId == nil)
    }

    @Test("The row menu's Go to album item gives the id when the album run carries none")
    func albumIdFromMenu() throws {
        let row = Self.songRow(
            "s1",
            subtitle: [Self.run("Artist", id: "UCone"), Self.run(" \u{2022} "), Self.run("Plain Album"), Self.run(" \u{2022} "), Self.run("3:05")],
            menu: [Self.albumMenuItem("MPREbFromMenu")]
        )
        let track = try #require(InnerTubeParser.searchTracks(from: Self.searchJSON(rows: [row])).first)
        #expect(track.albumBrowseId == "MPREbFromMenu")
    }

    @Test("The album run wins over the menu when both name an album")
    func albumRunWinsOverMenu() throws {
        let row = Self.songRow(
            "s1",
            subtitle: [Self.run("Artist", id: "UCone"), Self.run(" \u{2022} "), Self.run("Album One", id: "MPREbFromRun", page: "MUSIC_PAGE_TYPE_ALBUM"), Self.run(" \u{2022} "), Self.run("3:05")],
            menu: [Self.albumMenuItem("MPREbFromMenu")]
        )
        let track = try #require(InnerTubeParser.searchTracks(from: Self.searchJSON(rows: [row])).first)
        #expect(track.albumBrowseId == "MPREbFromRun")
    }

    @Test("A menu item that goes somewhere other than an album is not the album")
    func menuArtistItemIsNotTheAlbum() throws {
        let artistItem = Self.navigationItem(icon: "ARTIST", browseId: "UCone", page: "MUSIC_PAGE_TYPE_ARTIST")
        let row = Self.songRow("s1", subtitle: [Self.run("Artist", id: "UCone"), Self.run(" \u{2022} "), Self.run("3:05")], menu: [artistItem])
        let track = try #require(InnerTubeParser.searchTracks(from: Self.searchJSON(rows: [row])).first)
        #expect(track.albumBrowseId == nil)
    }

    // MARK: - Album id on page rows

    @Test("A playlist row names its album in a later column, and that link gives the id")
    func playlistRowAlbumColumn() throws {
        let row = Self.pageRow("p1", artist: [Self.run("Artist", id: "UCone")], album: [Self.run("Album Col", id: "MPREbColumn", page: "MUSIC_PAGE_TYPE_ALBUM")])
        let page = try InnerTubeParser.browsePage(from: Self.playlistJSON(rows: [row]), browseId: "VLPLfixtureList")
        #expect(page.tracks.first?.album == "Album Col")
        #expect(page.tracks.first?.albumBrowseId == "MPREbColumn")
    }

    @Test("Every row of an album page opens that same album")
    func albumPageRowsOpenThePage() throws {
        let rows = [Self.pageRow("a1", artist: []), Self.pageRow("a2", artist: [])]
        let page = try InnerTubeParser.browsePage(from: Self.albumJSON(rows: rows), browseId: "MPREbThisAlbum")
        #expect(page.tracks.map(\.albumBrowseId) == ["MPREbThisAlbum", "MPREbThisAlbum"])
    }

    @Test("Album rows keep their place when the page fills in the rest")
    func albumRemapKeepsRowOptions() throws {
        let rows = [Self.pageRow("a1", artist: [], setVideoId: "setA1")]
        let page = try InnerTubeParser.browsePage(from: Self.albumJSON(rows: rows), browseId: "MPREbThisAlbum")
        #expect(page.tracks.first?.playlistSetVideoId == "setA1")
    }

    // MARK: - Album id on queue, tile and continuation rows

    @Test("A radio row's album run gives the album id, and so does its menu")
    func radioRowAlbumId() throws {
        let linked = Self.panelItem("q1", byline: [
            Self.run("Artist", id: "UCone"), Self.run(" \u{2022} "), Self.run("Album Q", id: "MPREbQueue", page: "MUSIC_PAGE_TYPE_ALBUM"),
        ])
        let menuOnly = Self.panelItem("q2", byline: [Self.run("Artist", id: "UCone"), Self.run(" \u{2022} "), Self.run("Album Plain")], menu: [Self.albumMenuItem("MPREbQueueMenu")])
        let bare = Self.panelItem("q3", byline: [Self.run("Artist", id: "UCone")])
        let tracks = try InnerTubeParser.radioPage(from: Self.radioJSON(items: [linked, menuOnly, bare])).tracks
        #expect(tracks.map(\.albumBrowseId) == ["MPREbQueue", "MPREbQueueMenu", nil])
    }

    @Test("A song tile on Home takes its album id from its menu")
    func homeTileMenu() throws {
        let tile: [String: Any] = ["musicTwoRowItemRenderer": [
            "title": ["runs": [["text": "Tile Song"]]],
            "subtitle": ["runs": [Self.run("Tile Artist", id: "UCtile"), Self.run(" \u{2022} "), Self.run("1M views")]],
            "navigationEndpoint": ["watchEndpoint": ["videoId": "tileVideo"]],
            "menu": Self.menu([Self.albumMenuItem("MPREbTile")]),
        ]]
        let carousel: [String: Any] = ["musicCarouselShelfRenderer": [
            "header": ["musicCarouselShelfBasicHeaderRenderer": ["title": ["runs": [["text": "Shelf"]]]]],
            "contents": [tile],
        ]]
        let root: [String: Any] = ["contents": ["singleColumnBrowseResultsRenderer": ["tabs": [
            ["tabRenderer": ["content": ["sectionListRenderer": ["contents": [carousel]]]]],
        ]]]]
        let page = try InnerTubeParser.homePage(from: JSONSerialization.data(withJSONObject: root))
        guard case .track(let song)? = page.shelves.first?.items.first else {
            Issue.record("the tile did not parse to a song")
            return
        }
        #expect(song.albumBrowseId == "MPREbTile")
    }

    @Test("Rows from a later page of a long playlist carry their album id and their place")
    func continuationRowOptions() throws {
        let row = Self.pageRow("c1", artist: [], album: [Self.run("Album C", id: "MPREbLater", page: "MUSIC_PAGE_TYPE_ALBUM")], setVideoId: "setC1")
        let root: [String: Any] = ["continuationContents": ["musicPlaylistShelfContinuation": ["contents": [row]]]]
        let page = try InnerTubeParser.tracksContinuationPage(from: JSONSerialization.data(withJSONObject: root))
        #expect(page.tracks.first?.albumBrowseId == "MPREbLater")
        #expect(page.tracks.first?.playlistSetVideoId == "setC1")
    }

    // MARK: - Place in a playlist and editable pages

    @Test("A row's remove item gives the setVideoId that removing it needs")
    func setVideoIdFromRemoveItem() throws {
        let row = Self.pageRow("p1", artist: [], menu: [Self.removeMenuItem(videoId: "p1", setVideoId: "setFromMenu")])
        let page = try InnerTubeParser.browsePage(from: Self.playlistJSON(rows: [row]), browseId: "VLPLfixtureList")
        #expect(page.tracks.first?.playlistSetVideoId == "setFromMenu")
    }

    @Test("Without a remove item the row's own playlistSetVideoId is used")
    func setVideoIdFromRowData() throws {
        let row = Self.pageRow("p1", artist: [], setVideoId: "setFromData")
        let page = try InnerTubeParser.browsePage(from: Self.playlistJSON(rows: [row]), browseId: "VLPLfixtureList")
        #expect(page.tracks.first?.playlistSetVideoId == "setFromData")
    }

    @Test("A row with neither has no setVideoId")
    func noSetVideoId() throws {
        let page = try InnerTubeParser.browsePage(from: Self.playlistJSON(rows: [Self.pageRow("p1", artist: [])]), browseId: "VLPLfixtureList")
        #expect(page.tracks.first?.playlistSetVideoId == nil)
    }

    @Test("A page with the editable playlist header is editable")
    func editableHeaderMakesEditable() throws {
        let page = try InnerTubeParser.browsePage(from: Self.playlistJSON(rows: [Self.pageRow("p1", artist: [])], editableHeader: true), browseId: "VLPLfixtureMine")
        #expect(page.isEditable)
        #expect(page.title == "A Playlist")
    }

    @Test("A page whose rows offer Remove from playlist is editable, even with a plain header")
    func removeItemsMakeEditable() throws {
        let row = Self.pageRow("p1", artist: [], menu: [Self.removeMenuItem(videoId: "p1", setVideoId: "set1")])
        let page = try InnerTubeParser.browsePage(from: Self.playlistJSON(rows: [row]), browseId: "VLPLfixtureMine")
        #expect(page.isEditable)
    }

    @Test("A playlist the user does not own is not editable, though its rows carry a playlistSetVideoId")
    func publicPlaylistNotEditable() throws {
        let row = Self.pageRow("p1", artist: [], setVideoId: "setPublic")
        let page = try InnerTubeParser.browsePage(from: Self.playlistJSON(rows: [row]), browseId: "VLPLfixtureTheirs")
        #expect(page.isEditable == false)
    }

    @Test("Albums, artist pages and the captured playlist and Liked Music pages are not editable")
    func otherPagesNotEditable() throws {
        #expect(try InnerTubeParser.browsePage(from: Self.albumJSON(rows: [Self.pageRow("a1", artist: [])]), browseId: "MPREbThisAlbum").isEditable == false)
        #expect(try InnerTubeParser.browsePage(from: fixture("browse-album.json"), browseId: "MPREb_Me5NUhDIBWQ").isEditable == false)
        #expect(try InnerTubeParser.browsePage(from: fixture("browse-artist.json"), browseId: "UCuAXFkgsw1L7xaCfnd5JJOw").isEditable == false)
        #expect(try InnerTubeParser.browsePage(from: fixture("browse-playlist.json"), browseId: "VLPL4fGSI1pDJn6puJdseH2Rt9sMvt9E2M4i").isEditable == false)
        #expect(try InnerTubeParser.browsePage(from: fixture("browse-liked-music.json"), browseId: "VLLM").isEditable == false)
    }

    // MARK: - Rows without menus, and garbage

    @Test("A row with no menu, an empty menu or a menu of the wrong shape parses with no options and no crash")
    func rowsWithoutMenus() throws {
        let none = Self.pageRow("n1", artist: [])
        let empty = Self.pageRow("n2", artist: [], menu: [])
        var broken = Self.pageRow("n3", artist: [])
        var renderer = try #require(broken["musicResponsiveListItemRenderer"] as? [String: Any])
        renderer["menu"] = ["menuRenderer": ["items": "not a list"]]
        broken["musicResponsiveListItemRenderer"] = renderer
        var weird = Self.pageRow("n4", artist: [])
        var weirdRenderer = try #require(weird["musicResponsiveListItemRenderer"] as? [String: Any])
        weirdRenderer["menu"] = ["menuRenderer": ["items": [["menuServiceItemRenderer": "nope"], ["toggleMenuServiceItemRenderer": 7], 5]]]
        weird["musicResponsiveListItemRenderer"] = weirdRenderer
        let page = try InnerTubeParser.browsePage(from: Self.playlistJSON(rows: [none, empty, broken, weird]), browseId: "VLPLfixtureList")
        #expect(page.tracks.count == 4)
        for track in page.tracks {
            #expect(track.albumBrowseId == nil)
            #expect(track.playlistSetVideoId == nil)
        }
        #expect(page.isEditable == false)
    }

    @Test("The captured search, radio, home, playlist and album pages still parse with the same rows")
    func capturedFixturesStillParse() throws {
        let search = try InnerTubeParser.searchTracks(from: fixture("search-songs.json"))
        #expect(!search.isEmpty)
        #expect(search.allSatisfy { $0.playlistSetVideoId == nil })
        #expect(try InnerTubeParser.radioPage(from: fixture("next-radio-first.json")).tracks.count > 1)
        #expect(try InnerTubeParser.homePage(from: fixture("browse-home.json")).shelves.isEmpty == false)
    }

    // MARK: - Write responses

    @Test("An edit that STATUS_SUCCEEDED worked, and anything else did not")
    func editResponses() throws {
        #expect(try InnerTubeParser.playlistEditSucceeded(in: Data(#"{"status":"STATUS_SUCCEEDED"}"#.utf8)))
        #expect(try InnerTubeParser.playlistEditSucceeded(in: Data(#"{"status":"STATUS_SUCCEEDED","playlistEditResults":[{"x":1}]}"#.utf8)))
        #expect(try InnerTubeParser.playlistEditSucceeded(in: Data(#"{"status":"STATUS_FAILED"}"#.utf8)) == false)
        #expect(try InnerTubeParser.playlistEditSucceeded(in: Data("{}".utf8)) == false)
        #expect(try InnerTubeParser.playlistEditSucceeded(in: Data(#"{"status":7}"#.utf8)) == false)
    }

    @Test("A write response that is not JSON is a parse error")
    func writeResponsesNotJSON() {
        #expect(throws: MusicError.self) { try InnerTubeParser.playlistEditSucceeded(in: Data("<html>".utf8)) }
        #expect(throws: MusicError.self) { try InnerTubeParser.addToPlaylistOptions(from: Data("nope".utf8)) }
    }

    // MARK: - The picker's list

    @Test("The picker list keeps each playlist with its id, title, cover and whether it holds the song")
    func pickerList() throws {
        let options = try InnerTubeParser.addToPlaylistOptions(from: fixture("add-to-playlist-options.json"))
        #expect(options.map(\.playlistId) == ["PLfixtureRoadTrip0001", "PLfixtureWorkout0002", "PLfixtureNoCover0003"])
        #expect(options.map(\.title) == ["Fixture Road Trip", "Fixture Workout", "Fixture No Cover"])
        #expect(options.map(\.containsVideo) == [false, true, false])
        #expect(options[0].thumbnailURL?.absoluteString == "https://img.example.test/road=w226-h226")
        #expect(options[1].thumbnailURL?.absoluteString == "https://img.example.test/workout=w48-h48")
        #expect(options[2].thumbnailURL == nil)
    }

    @Test("Liked music, a playlist with no title and one with no id are left out of the picker")
    func pickerLeavesOutUnusable() throws {
        let options = try InnerTubeParser.addToPlaylistOptions(from: fixture("add-to-playlist-options.json"))
        #expect(!options.contains { $0.playlistId == "LM" })
        #expect(options.allSatisfy { !$0.title.isEmpty && !$0.playlistId.isEmpty })
    }

    @Test("A playlist id that came back in its browse form loses the VL")
    func pickerStripsVL() throws {
        let json = #"{"x":{"addToPlaylistRenderer":{"playlists":[{"playlistAddToOptionRenderer":{"playlistId":"VLPLfixtureV","title":{"runs":[{"text":"V"}]},"containsSelectedVideos":"NONE"}}]}}}"#
        #expect(try InnerTubeParser.addToPlaylistOptions(from: Data(json.utf8)).map(\.playlistId) == ["PLfixtureV"])
    }

    @Test("A response with no playlists, or a user with none, is an empty list, not an error")
    func pickerEmpty() throws {
        #expect(try InnerTubeParser.addToPlaylistOptions(from: Data("{}".utf8)).isEmpty)
        #expect(try InnerTubeParser.addToPlaylistOptions(from: Data(#"{"contents":[{"addToPlaylistRenderer":{"playlists":[]}}]}"#.utf8)).isEmpty)
    }

    @Test("A long picker list parses")
    func pickerLarge() throws {
        let entries = (0..<3_000).map { index in
            ["playlistAddToOptionRenderer": ["playlistId": "PL\(index)", "title": ["runs": [["text": "List \(index)"]]], "containsSelectedVideos": index.isMultiple(of: 2) ? "ALL" : "NONE"]]
        }
        let root: [String: Any] = ["contents": [["addToPlaylistRenderer": ["playlists": entries]]]]
        let options = try InnerTubeParser.addToPlaylistOptions(from: JSONSerialization.data(withJSONObject: root))
        #expect(options.count == 3_000)
        #expect(options.filter(\.containsVideo).count == 1_500)
    }

    @Test("Unicode titles survive the picker list")
    func pickerUnicode() throws {
        let json = #"{"a":{"addToPlaylistRenderer":{"playlists":[{"playlistAddToOptionRenderer":{"playlistId":"PLu","title":{"runs":[{"text":"Café 🎵 日本"}]},"containsSelectedVideos":"NONE"}}]}}}"#
        #expect(try InnerTubeParser.addToPlaylistOptions(from: Data(json.utf8)).first?.title == "Caf\u{00E9} \u{1F3B5} \u{65E5}\u{672C}")
    }

    // MARK: - Builders

    private static func run(_ text: String, id: String? = nil, page: String? = "MUSIC_PAGE_TYPE_ARTIST") -> [String: Any] {
        guard let id else { return ["text": text] }
        var browse: [String: Any] = ["browseId": id]
        if let page { browse["browseEndpointContextSupportedConfigs"] = ["browseEndpointContextMusicConfig": ["pageType": page]] }
        return ["text": text, "navigationEndpoint": ["browseEndpoint": browse]]
    }

    private static func thumbnails() -> [String: Any] {
        ["musicThumbnailRenderer": ["thumbnail": ["thumbnails": [["url": "https://img.example.test/60", "width": 60, "height": 60]]]]]
    }

    private static func flexColumn(_ runs: [[String: Any]]) -> [String: Any] {
        ["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": runs]]]
    }

    private static func menu(_ items: [[String: Any]]) -> [String: Any] {
        ["menuRenderer": ["items": items]]
    }

    /// "Go to album": a menu item that navigates to the album's page.
    private static func albumMenuItem(_ browseId: String) -> [String: Any] {
        navigationItem(icon: "ALBUM", browseId: browseId, page: "MUSIC_PAGE_TYPE_ALBUM")
    }

    private static func navigationItem(icon: String, browseId: String, page: String) -> [String: Any] {
        ["menuNavigationItemRenderer": [
            "text": ["runs": [["text": "Go somewhere"]]],
            "icon": ["iconType": icon],
            "navigationEndpoint": ["browseEndpoint": [
                "browseId": browseId,
                "browseEndpointContextSupportedConfigs": ["browseEndpointContextMusicConfig": ["pageType": page]],
            ]],
        ]]
    }

    /// "Remove from playlist": a service item that edits the playlist.
    private static func removeMenuItem(videoId: String, setVideoId: String) -> [String: Any] {
        ["menuServiceItemRenderer": [
            "text": ["runs": [["text": "Remove from playlist"]]],
            "icon": ["iconType": "REMOVE_FROM_PLAYLIST"],
            "serviceEndpoint": ["playlistEditEndpoint": [
                "playlistId": "PLfixtureMine",
                "actions": [["action": "ACTION_REMOVE_VIDEO", "setVideoId": setVideoId, "removedVideoId": videoId]],
            ]],
        ]]
    }

    private static func songRow(_ videoId: String, subtitle: [[String: Any]], menu items: [[String: Any]]? = nil) -> [String: Any] {
        var renderer: [String: Any] = [
            "thumbnail": thumbnails(),
            "flexColumns": [flexColumn([["text": "Song \(videoId)"]]), flexColumn(subtitle)],
            "playlistItemData": ["videoId": videoId],
        ]
        if let items { renderer["menu"] = menu(items) }
        return ["musicResponsiveListItemRenderer": renderer]
    }

    /// A row of a playlist or album page: the artists in the second column, the album in the third when given.
    private static func pageRow(
        _ videoId: String,
        artist: [[String: Any]],
        album: [[String: Any]]? = nil,
        menu items: [[String: Any]]? = nil,
        setVideoId: String? = nil
    ) -> [String: Any] {
        var data: [String: Any] = ["videoId": videoId]
        if let setVideoId { data["playlistSetVideoId"] = setVideoId }
        var columns = [flexColumn([["text": "Track \(videoId)"]]), flexColumn(artist)]
        if let album { columns.append(flexColumn(album)) }
        var renderer: [String: Any] = [
            "playlistItemData": data,
            "flexColumns": columns,
            "fixedColumns": [["musicResponsiveListItemFixedColumnRenderer": ["text": ["runs": [["text": "3:00"]]]]]],
        ]
        if let items { renderer["menu"] = menu(items) }
        return ["musicResponsiveListItemRenderer": renderer]
    }

    private static func searchJSON(rows: [[String: Any]]) -> Data {
        let root: [String: Any] = [
            "contents": ["tabbedSearchResultsRenderer": ["tabs": [["tabRenderer": ["content": ["sectionListRenderer": ["contents": [
                ["musicShelfRenderer": ["contents": rows]],
            ]]]]]]]],
        ]
        return (try? JSONSerialization.data(withJSONObject: root)) ?? Data()
    }

    /// A playlist page in the two-column layout. The editable header wraps the plain one, as YouTube's does.
    private static func playlistJSON(rows: [[String: Any]], editableHeader: Bool = false) -> Data {
        let header: [String: Any] = ["title": ["runs": [["text": "A Playlist"]]], "subtitle": ["runs": [["text": "Playlist"]]]]
        let headerSection: [String: Any] = editableHeader
            ? ["musicEditablePlaylistDetailHeaderRenderer": ["header": ["musicResponsiveHeaderRenderer": header], "playlistId": "PLfixtureMine"]]
            : ["musicResponsiveHeaderRenderer": header]
        let root: [String: Any] = ["contents": ["twoColumnBrowseResultsRenderer": [
            "tabs": [["tabRenderer": ["content": ["sectionListRenderer": ["contents": [headerSection]]]]]],
            "secondaryContents": ["sectionListRenderer": ["contents": [["musicPlaylistShelfRenderer": ["contents": rows]]]]],
        ]]]
        return (try? JSONSerialization.data(withJSONObject: root)) ?? Data()
    }

    private static func albumJSON(rows: [[String: Any]]) -> Data {
        let header: [String: Any] = [
            "title": ["runs": [["text": "An Album"]]],
            "straplineTextOne": ["runs": [run("Album Artist", id: "UCalbumartist")]],
            "subtitle": ["runs": [["text": "Album"]]],
        ]
        let root: [String: Any] = ["contents": ["twoColumnBrowseResultsRenderer": [
            "tabs": [["tabRenderer": ["content": ["sectionListRenderer": ["contents": [["musicResponsiveHeaderRenderer": header]]]]]]],
            "secondaryContents": ["sectionListRenderer": ["contents": [["musicShelfRenderer": ["contents": rows]]]]],
        ]]]
        return (try? JSONSerialization.data(withJSONObject: root)) ?? Data()
    }

    private static func panelItem(_ videoId: String, byline: [[String: Any]]?, menu items: [[String: Any]]? = nil) -> [String: Any] {
        var renderer: [String: Any] = [
            "videoId": videoId,
            "title": ["runs": [["text": "Queue \(videoId)"]]],
            "lengthText": ["runs": [["text": "3:00"]]],
            "thumbnail": ["thumbnails": [["url": "https://img.example.test/q", "width": 120, "height": 120]]],
        ]
        if let byline { renderer["longBylineText"] = ["runs": byline] }
        if let items { renderer["menu"] = menu(items) }
        return ["playlistPanelVideoRenderer": renderer]
    }

    private static func radioJSON(items: [[String: Any]]) -> Data {
        let root: [String: Any] = [
            "contents": ["singleColumnMusicWatchNextResultsRenderer": ["tabbedRenderer": ["watchNextTabbedResultsRenderer": ["tabs": [
                ["tabRenderer": ["content": ["musicQueueRenderer": ["content": ["playlistPanelRenderer": ["contents": items]]]]]],
            ]]]]],
        ]
        return (try? JSONSerialization.data(withJSONObject: root)) ?? Data()
    }
}
