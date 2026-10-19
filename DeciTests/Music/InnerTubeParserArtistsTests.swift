// DeciTests/Music/InnerTubeParserArtistsTests.swift
// Artists in search results (the artists filter) and the artist links on song rows. The song, radio, home,
// playlist, album and artist fixtures are the same anonymous captures the other parser suites use;
// search-artists.json is hand-written with made-up names and ids, in the shape of a real artists search.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("InnerTubeParser artists")
struct InnerTubeParserArtistsTests {

    private func fixture(_ name: String) throws -> Data { try MusicFixtures.data(name) }

    // MARK: - Artists search

    @Test("Artists search keeps the artist rows in order and drops albums, songs, user channels and blank ids")
    func artistsKeepsOnlyArtists() throws {
        let artists = try InnerTubeParser.searchArtists(from: fixture("search-artists.json"))
        #expect(artists.map(\.browseId) == ["UCartistA", "UCartistB", "UCartistD", "UCartistZ"])
        #expect(artists.map(\.title) == ["Artist Alpha", "Artist Beta", "Artist Delta", "Artist Zeta"])
        #expect(artists.allSatisfy { $0.kind == .artist })
    }

    @Test("A repeated artist appears once, at its first place and with its first photo")
    func artistsDedupe() throws {
        let artists = try InnerTubeParser.searchArtists(from: fixture("search-artists.json"))
        #expect(artists.filter { $0.browseId == "UCartistA" }.count == 1)
        #expect(artists.first?.thumbnailURL?.absoluteString == "https://img.example.test/alpha=w120-h120")
    }

    @Test("The subtitle is what the row says after Artist, or Artist when it says nothing else")
    func artistsSubtitle() throws {
        let artists = try InnerTubeParser.searchArtists(from: fixture("search-artists.json"))
        #expect(artists.map(\.subtitle) == ["1.2M monthly audience", "3 subscribers", "Artist", "4.5K subscribers"])
    }

    @Test("The photo is the largest one the row offers")
    func artistsLargestThumbnail() throws {
        let artists = try InnerTubeParser.searchArtists(from: fixture("search-artists.json"))
        #expect(artists.map { $0.thumbnailURL?.absoluteString } == [
            "https://img.example.test/alpha=w120-h120",
            "https://img.example.test/beta=w120-h120",
            "https://img.example.test/delta=w120-h120",
            "https://img.example.test/zeta=w120-h120",
        ])
    }

    @Test("A row with no photos gives an artist with a nil photo")
    func artistsWithoutPhoto() throws {
        let json = Self.artistsJSON(rows: [Self.artistRow("Bare", id: "UCbare", subtitle: ["Artist", " \u{2022} ", "1 subscriber"], thumbnailWidths: [])])
        let artist = try #require(InnerTubeParser.searchArtists(from: json).first)
        #expect(artist.thumbnailURL == nil)
        #expect(artist.subtitle == "1 subscriber")
    }

    @Test("A subtitle that does not start with the Artist label is kept whole")
    func artistsSubtitleWithoutLabel() throws {
        let json = Self.artistsJSON(rows: [
            Self.artistRow("No Label", id: "UCnolabel", subtitle: ["72M monthly audience"]),
            Self.artistRow("Empty", id: "UCempty", subtitle: []),
            Self.artistRow("Label And Bullet", id: "UCbullet", subtitle: ["Artist", " \u{2022} "]),
        ])
        #expect(try InnerTubeParser.searchArtists(from: json).map(\.subtitle) == ["72M monthly audience", "Artist", "Artist"])
    }

    @Test("A library-style artist id (MPLAUC...) opens the channel page, as everywhere else")
    func artistsLibraryPrefix() throws {
        let json = Self.artistsJSON(rows: [Self.artistRow("Prefixed", id: "MPLAUCchannel", subtitle: ["Artist"])])
        #expect(try InnerTubeParser.searchArtists(from: json).map(\.browseId) == ["UCchannel"])
    }

    @Test("An artist with no page type is told apart by its UC id")
    func artistsWithoutPageType() throws {
        let json = Self.artistsJSON(rows: [
            Self.artistRow("Typeless", id: "UCtypeless", subtitle: ["Artist"], pageType: nil),
            Self.artistRow("Not an artist", id: "RDsomething", subtitle: ["Artist"], pageType: nil),
        ])
        #expect(try InnerTubeParser.searchArtists(from: json).map(\.browseId) == ["UCtypeless"])
    }

    @Test("A greyed-out artist row is dropped")
    func artistsGreyedOut() throws {
        var row = Self.artistRow("Grey", id: "UCgrey", subtitle: ["Artist"])
        var renderer = try #require(row["musicResponsiveListItemRenderer"] as? [String: Any])
        renderer["musicItemRendererDisplayPolicy"] = "MUSIC_ITEM_RENDERER_DISPLAY_POLICY_GREY_OUT"
        row["musicResponsiveListItemRenderer"] = renderer
        #expect(try InnerTubeParser.searchArtists(from: Self.artistsJSON(rows: [row])).isEmpty)
    }

    @Test("A response with no artists, or none of the expected shape, is an empty list, not an error")
    func artistsEmpty() throws {
        #expect(try InnerTubeParser.searchArtists(from: Data("{}".utf8)).isEmpty)
        #expect(try InnerTubeParser.searchArtists(from: Self.artistsJSON(rows: [])).isEmpty)
        let message = #"{"contents":{"tabbedSearchResultsRenderer":{"tabs":[{"tabRenderer":{"content":{"sectionListRenderer":{"contents":[{"itemSectionRenderer":{"contents":[{"messageRenderer":{}}]}}]}}}}]}}}"#
        #expect(try InnerTubeParser.searchArtists(from: Data(message.utf8)).isEmpty)
    }

    @Test("Garbage that is not JSON throws a parse error")
    func artistsInvalidJSON() {
        #expect(throws: MusicError.self) { try InnerTubeParser.searchArtists(from: Data("<html>".utf8)) }
        #expect(throws: MusicError.self) { try InnerTubeParser.searchArtists(from: Data()) }
    }

    @Test("Unicode names survive parsing")
    func artistsUnicode() throws {
        let json = Self.artistsJSON(rows: [Self.artistRow("YOASOBI \u{1F3B5} caf\u{00E9}", id: "UCunicode", subtitle: ["Artist"])])
        #expect(try InnerTubeParser.searchArtists(from: json).first?.title == "YOASOBI \u{1F3B5} caf\u{00E9}")
    }

    @Test("A long list parses")
    func artistsManyRows() throws {
        let rows = (0..<2_000).map { Self.artistRow("A\($0)", id: "UC\($0)", subtitle: ["Artist"]) }
        #expect(try InnerTubeParser.searchArtists(from: Self.artistsJSON(rows: rows)).count == 2_000)
    }

    @Test("A songs response has no artist rows")
    func artistsFromSongsResponse() throws {
        #expect(try InnerTubeParser.searchArtists(from: fixture("search-songs.json")).isEmpty)
    }

    // MARK: - MusicTrack

    @Test("A track built the old way has no artist links, and equals the same track built with an empty list")
    func trackDefaultsToNoLinks() {
        let old = MusicTrack(videoId: "v", title: "T", artist: "A", album: nil, durationSeconds: 60, thumbnailURL: nil)
        #expect(old.artistLinks.isEmpty)
        #expect(old == MusicTrack(videoId: "v", title: "T", artist: "A", album: nil, durationSeconds: 60, thumbnailURL: nil, artistLinks: []))
    }

    @Test("An artist link opens an artist page with its name and no photo")
    func linkOpener() {
        let opener = MusicArtistLink(name: "Some Band", browseId: "UCfixtureSomeBand0000000").opener
        #expect(opener == MusicCollection(browseId: "UCfixtureSomeBand0000000", kind: .artist, title: "Some Band", subtitle: "", thumbnailURL: nil))
    }

    // MARK: - Links on search rows

    @Test("Search rows link each credited artist, in order, and keep the joined artist text")
    func searchRowLinks() throws {
        let tracks = try InnerTubeParser.searchTracks(from: fixture("search-songs.json"))
        let first = try #require(tracks.first)
        #expect(first.artist == "Daft Punk, Pharrell Williams, Nile Rodgers")
        #expect(first.artistLinks == [
            MusicArtistLink(name: "Daft Punk", browseId: "UCRr1xG_2WIDs18a6cIiCxeA"),
            MusicArtistLink(name: "Pharrell Williams", browseId: "UCJw8VyO6e3v6S0327AsgwcQ"),
            MusicArtistLink(name: "Nile Rodgers", browseId: "UCThde8ccpEr6sP8dIHZ-ceQ"),
        ])
        let kids = try #require(tracks.first { $0.videoId == "28DL6VcWIb0" })
        #expect(kids.artistLinks == [MusicArtistLink(name: "The Countdown Kids", browseId: "UCJ31-d77OU6CNGqWZAZBg8g")])
    }

    @Test("The album run and the duration are never taken for an artist link")
    func searchRowAlbumIsNotALink() throws {
        let tracks = try InnerTubeParser.searchTracks(from: fixture("search-songs.json"))
        for track in tracks {
            #expect(!track.artistLinks.contains { $0.browseId.hasPrefix("MPRE") })
            #expect(track.artistLinks.allSatisfy { $0.browseId.hasPrefix("UC") })
        }
    }

    @Test("An artist with no browse link gives no link, and a linked one beside it still does")
    func searchRowUnlinkedArtists() throws {
        let plain = Self.songRow("p", subtitle: [Self.run("Plain Uploader"), Self.run(" \u{2022} "), Self.run("3:05")])
        let mixed = Self.songRow("m", subtitle: [
            Self.run("Various Artists"), Self.run(" & "), Self.run("Linked One", id: "UClinked"), Self.run(" \u{2022} "), Self.run("3:05"),
        ])
        let tracks = try InnerTubeParser.searchTracks(from: Self.songsJSON(rows: [plain, mixed]))
        #expect(tracks[0].artist == "Plain Uploader")
        #expect(tracks[0].artistLinks.isEmpty)
        #expect(tracks[1].artist == "Various Artists, Linked One")
        #expect(tracks[1].artistLinks == [MusicArtistLink(name: "Linked One", browseId: "UClinked")])
    }

    @Test("The same artist twice on one row is linked once")
    func searchRowRepeatedArtist() throws {
        let row = Self.songRow("r", subtitle: [Self.run("Twin", id: "UCtwin"), Self.run(", "), Self.run("Twin", id: "UCtwin"), Self.run(" \u{2022} "), Self.run("1:00")])
        let track = try #require(InnerTubeParser.searchTracks(from: Self.songsJSON(rows: [row])).first)
        #expect(track.artistLinks == [MusicArtistLink(name: "Twin", browseId: "UCtwin")])
    }

    @Test("A library-style id and a typeless UC id both link to the channel page; other page types do not")
    func searchRowLinkKinds() throws {
        let row = Self.songRow("k", subtitle: [
            Self.run("Library Style", id: "MPLAUClibrary"), Self.run(", "),
            Self.run("Typeless", id: "UCtypeless", page: nil), Self.run(", "),
            Self.run("Playlist Like", id: "VLPLsomething", page: "MUSIC_PAGE_TYPE_PLAYLIST"), Self.run(", "),
            Self.run("User", id: "UCuser", page: "MUSIC_PAGE_TYPE_USER_CHANNEL"),
            Self.run(" \u{2022} "), Self.run("2:00"),
        ])
        let track = try #require(InnerTubeParser.searchTracks(from: Self.songsJSON(rows: [row])).first)
        #expect(track.artistLinks == [
            MusicArtistLink(name: "Library Style", browseId: "UClibrary"),
            MusicArtistLink(name: "Typeless", browseId: "UCtypeless"),
        ])
    }

    // MARK: - Links on Home

    @Test("Home Quick picks rows carry their artist link")
    func homeRowLinks() throws {
        let page = try InnerTubeParser.homePage(from: fixture("browse-home.json"))
        let quick = try #require(page.shelves.first { $0.title == "Quick picks" })
        let songs = quick.items.compactMap { item -> MusicTrack? in
            if case .track(let track) = item { track } else { nil }
        }
        #expect(songs.first?.artistLinks == [MusicArtistLink(name: "Ella Langley", browseId: "UCecnyZYofHiBVDJpx1XNYOQ")])
        #expect(songs.map { $0.artistLinks.map(\.name) } == [["Ella Langley"], ["Alyssa Grace"], ["Zeddy Will"]])
    }

    @Test("A Home tile that plays a song carries the artist link from its subtitle")
    func homeTileLinks() throws {
        let tile: [String: Any] = ["musicTwoRowItemRenderer": [
            "title": ["runs": [["text": "Tile Song"]]],
            "subtitle": ["runs": [Self.run("Tile Artist", id: "UCtile"), Self.run(" \u{2022} "), Self.run("1M views")]],
            "navigationEndpoint": ["watchEndpoint": ["videoId": "tileVideo"]],
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
        #expect(song.artist == "Tile Artist")
        #expect(song.artistLinks == [MusicArtistLink(name: "Tile Artist", browseId: "UCtile")])
    }

    // MARK: - Links on pages

    @Test("Playlist rows link their artists, and a credited artist with no page stays plain text")
    func playlistRowLinks() throws {
        let page = try InnerTubeParser.browsePage(from: fixture("browse-playlist.json"), browseId: "VLPL4fGSI1pDJn6puJdseH2Rt9sMvt9E2M4i")
        #expect(page.tracks[0].artistLinks.map(\.name) == ["Shakira", "Burna Boy"])
        #expect(page.tracks[0].artistLinks.map(\.browseId) == ["UCo6JijJGA3IvIiPsawDK3Ww", "UCr61sufuLt7_eB7ak1bXHIg"])
        #expect(page.tracks[1].artistLinks.map(\.name) == ["ARJN", "KDS", "FIFTY4", "Shreya Ghoshal"])
        #expect(page.tracks[2].artist == "KAROL G, Judeline, rusowsky")
        #expect(page.tracks[2].artistLinks.map(\.name) == ["KAROL G", "rusowsky"])
    }

    @Test("Artist page top songs link the artist")
    func artistPageRowLinks() throws {
        let page = try InnerTubeParser.browsePage(from: fixture("browse-artist.json"), browseId: "UCuAXFkgsw1L7xaCfnd5JJOw")
        #expect(page.tracks.count == 2)
        #expect(page.tracks.allSatisfy { $0.artistLinks == [MusicArtistLink(name: "Rick Astley", browseId: "UCwZEU0wAwIyZb4x5G_KJp2w")] })
    }

    @Test("Album rows that name no artist take the header's artist links")
    func albumRowsTakeHeaderLinks() throws {
        let page = try InnerTubeParser.browsePage(from: fixture("browse-album.json"), browseId: "MPREb_Me5NUhDIBWQ")
        #expect(page.tracks.count == 4)
        #expect(page.tracks.allSatisfy { $0.artist == "Rick Astley" })
        #expect(page.tracks.allSatisfy { $0.artistLinks == [MusicArtistLink(name: "Rick Astley", browseId: "UCwZEU0wAwIyZb4x5G_KJp2w")] })
    }

    @Test("An older album header's subtitle links give the rows their artists too")
    func albumOlderHeaderLinks() throws {
        let header: [String: Any] = [
            "title": ["runs": [["text": "Old Album"]]],
            "subtitle": ["runs": [Self.run("Album"), Self.run(" \u{2022} "), Self.run("Header Artist", id: "UCheader"), Self.run(" \u{2022} "), Self.run("2001")]],
        ]
        let page = try InnerTubeParser.browsePage(from: Self.albumJSON(header: header, rows: [Self.pageRow("a1", artist: [])]), browseId: "MPREbOld")
        #expect(page.tracks.first?.artist == "Header Artist")
        #expect(page.tracks.first?.artistLinks == [MusicArtistLink(name: "Header Artist", browseId: "UCheader")])
    }

    @Test("An album row with its own artists keeps those, and an unlinked own artist is not swapped for the header's link")
    func albumRowOwnArtists() throws {
        let header = Self.albumHeader(artist: Self.run("Header Artist", id: "UCheader"))
        let rows = [
            Self.pageRow("own", artist: [Self.run("Guest", id: "UCguest")]),
            Self.pageRow("plain", artist: [Self.run("Plain Credit")]),
            Self.pageRow("none", artist: []),
        ]
        let page = try InnerTubeParser.browsePage(from: Self.albumJSON(header: header, rows: rows), browseId: "MPREbOwn")
        #expect(page.tracks[0].artistLinks == [MusicArtistLink(name: "Guest", browseId: "UCguest")])
        #expect(page.tracks[1].artist == "Plain Credit")
        #expect(page.tracks[1].artistLinks.isEmpty)
        #expect(page.tracks[2].artist == "Header Artist")
        #expect(page.tracks[2].artistLinks == [MusicArtistLink(name: "Header Artist", browseId: "UCheader")])
    }

    @Test("An album whose header artist has no page gives rows with the name and no link")
    func albumHeaderWithoutLink() throws {
        let header = Self.albumHeader(artist: Self.run("Unlinked Artist"))
        let page = try InnerTubeParser.browsePage(from: Self.albumJSON(header: header, rows: [Self.pageRow("a1", artist: [])]), browseId: "MPREbPlain")
        #expect(page.tracks.first?.artist == "Unlinked Artist")
        #expect(page.tracks.first?.artistLinks.isEmpty == true)
    }

    @Test("Rows from a later page of a long list carry their links")
    func continuationRowLinks() throws {
        let rows = [Self.pageRow("c1", artist: [Self.run("Later Artist", id: "UClater")])]
        let root: [String: Any] = ["continuationContents": ["musicPlaylistShelfContinuation": ["contents": rows]]]
        let page = try InnerTubeParser.tracksContinuationPage(from: JSONSerialization.data(withJSONObject: root))
        #expect(page.tracks.first?.artistLinks == [MusicArtistLink(name: "Later Artist", browseId: "UClater")])
    }

    // MARK: - Links in the radio queue

    @Test("Radio queue rows link their artists, from the long byline")
    func radioRowLinks() throws {
        let page = try InnerTubeParser.radioPage(from: fixture("next-radio-first.json"))
        #expect(page.tracks[0].artistLinks.map(\.name) == ["Daft Punk", "Pharrell Williams", "Nile Rodgers"])
        #expect(page.tracks[0].artistLinks.map(\.browseId) == ["UCRr1xG_2WIDs18a6cIiCxeA", "UCJw8VyO6e3v6S0327AsgwcQ", "UCThde8ccpEr6sP8dIHZ-ceQ"])
        #expect(page.tracks[1].artistLinks == [MusicArtistLink(name: "Daft Punk", browseId: "UCRr1xG_2WIDs18a6cIiCxeA")])
        #expect(page.tracks[3].artistLinks.map(\.name) == ["j-hope", "Nile Rodgers"])
    }

    @Test("Radio continuation rows link their artists too, four credits included")
    func radioContinuationLinks() throws {
        let page = try InnerTubeParser.radioContinuationPage(from: fixture("next-radio-continuation.json"))
        let many = try #require(page.tracks.first { $0.videoId == "JWxoRY7AFSw" })
        #expect(many.artistLinks.map(\.name) == ["Justice", "Tame Impala", "SZA", "Grand Theft Auto VI"])
        // An uploaded video links its channel, and the views and likes after it are not links.
        let upload = try #require(page.tracks.first { $0.videoId == "2pzs39z2VMk" })
        #expect(upload.artistLinks == [MusicArtistLink(name: "Example Uploader", browseId: "UC_SCRUBBED_CHANNEL")])
    }

    @Test("A radio byline with no artist link, or none at all, gives no links")
    func radioUnlinkedByline() throws {
        let plain = Self.panelItem("plain", byline: [Self.run("No Page")])
        let missing = Self.panelItem("missing", byline: nil)
        let linked = Self.panelItem("linked", byline: [Self.run("With Page", id: "UCwith"), Self.run(" \u{2022} "), Self.run("Album", id: "MPREbAlbum", page: "MUSIC_PAGE_TYPE_ALBUM")])
        let tracks = try InnerTubeParser.radioPage(from: Self.radioJSON(items: [plain, missing, linked])).tracks
        #expect(tracks[0].artist == "No Page")
        #expect(tracks[0].artistLinks.isEmpty)
        #expect(tracks[1].artistLinks.isEmpty)
        #expect(tracks[2].artistLinks == [MusicArtistLink(name: "With Page", browseId: "UCwith")])
    }

    // MARK: - Builders

    private static func run(_ text: String, id: String? = nil, page: String? = "MUSIC_PAGE_TYPE_ARTIST") -> [String: Any] {
        guard let id else { return ["text": text] }
        var browse: [String: Any] = ["browseId": id]
        if let page { browse["browseEndpointContextSupportedConfigs"] = ["browseEndpointContextMusicConfig": ["pageType": page]] }
        return ["text": text, "navigationEndpoint": ["browseEndpoint": browse]]
    }

    private static func thumbnails(_ widths: [Int]) -> [String: Any] {
        ["musicThumbnailRenderer": ["thumbnail": ["thumbnails": widths.map {
            ["url": "https://img.example.test/\($0)", "width": $0, "height": $0] as [String: Any]
        }]]]
    }

    private static func flexColumn(_ runs: [[String: Any]]) -> [String: Any] {
        ["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": runs]]]
    }

    /// An artist row of the artists search: no video, the destination on the row itself.
    private static func artistRow(
        _ name: String,
        id: String,
        subtitle: [String],
        pageType: String? = "MUSIC_PAGE_TYPE_ARTIST",
        thumbnailWidths: [Int] = [60, 120]
    ) -> [String: Any] {
        var browse: [String: Any] = ["browseId": id]
        if let pageType { browse["browseEndpointContextSupportedConfigs"] = ["browseEndpointContextMusicConfig": ["pageType": pageType]] }
        let renderer: [String: Any] = [
            "thumbnail": thumbnails(thumbnailWidths),
            "flexColumns": [flexColumn([["text": name]]), flexColumn(subtitle.map { ["text": $0] })],
            "navigationEndpoint": ["browseEndpoint": browse],
        ]
        return ["musicResponsiveListItemRenderer": renderer]
    }

    private static func searchResponse(rows: [[String: Any]]) -> Data {
        let root: [String: Any] = [
            "contents": ["tabbedSearchResultsRenderer": ["tabs": [["tabRenderer": ["content": ["sectionListRenderer": ["contents": [
                ["musicShelfRenderer": ["contents": rows]],
            ]]]]]]]],
        ]
        return (try? JSONSerialization.data(withJSONObject: root)) ?? Data()
    }

    private static func artistsJSON(rows: [[String: Any]]) -> Data { searchResponse(rows: rows) }

    private static func songsJSON(rows: [[String: Any]]) -> Data { searchResponse(rows: rows) }

    private static func songRow(_ videoId: String, subtitle: [[String: Any]]) -> [String: Any] {
        let renderer: [String: Any] = [
            "thumbnail": thumbnails([60, 120]),
            "flexColumns": [flexColumn([["text": "Song \(videoId)"]]), flexColumn(subtitle)],
            "playlistItemData": ["videoId": videoId],
        ]
        return ["musicResponsiveListItemRenderer": renderer]
    }

    /// A row of a playlist or album page: the artists in the second column.
    private static func pageRow(_ videoId: String, artist: [[String: Any]]) -> [String: Any] {
        let renderer: [String: Any] = [
            "playlistItemData": ["videoId": videoId],
            "flexColumns": [flexColumn([["text": "Track \(videoId)"]]), flexColumn(artist)],
            "fixedColumns": [["musicResponsiveListItemFixedColumnRenderer": ["text": ["runs": [["text": "3:00"]]]]]],
        ]
        return ["musicResponsiveListItemRenderer": renderer]
    }

    private static func albumHeader(artist: [String: Any]) -> [String: Any] {
        ["title": ["runs": [["text": "An Album"]]], "straplineTextOne": ["runs": [artist]], "subtitle": ["runs": [["text": "Album"]]]]
    }

    private static func albumJSON(header: [String: Any], rows: [[String: Any]]) -> Data {
        let root: [String: Any] = ["contents": ["twoColumnBrowseResultsRenderer": [
            "tabs": [["tabRenderer": ["content": ["sectionListRenderer": ["contents": [["musicResponsiveHeaderRenderer": header]]]]]]],
            "secondaryContents": ["sectionListRenderer": ["contents": [["musicShelfRenderer": ["contents": rows]]]]],
        ]]]
        return (try? JSONSerialization.data(withJSONObject: root)) ?? Data()
    }

    private static func panelItem(_ videoId: String, byline: [[String: Any]]?) -> [String: Any] {
        var renderer: [String: Any] = [
            "videoId": videoId,
            "title": ["runs": [["text": "Queue \(videoId)"]]],
            "lengthText": ["runs": [["text": "3:00"]]],
            "thumbnail": ["thumbnails": [["url": "https://img.example.test/q", "width": 120, "height": 120]]],
        ]
        if let byline { renderer["longBylineText"] = ["runs": byline] }
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
