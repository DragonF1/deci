// DeciTests/Music/InnerTubeParserBrowseTests.swift
// The browse parsers (home, library, playlist, album and artist pages, continuations). The home,
// playlist, album, artist and playlist-continuation fixtures are anonymous captures from music.youtube.com
// (visitor data scrubbed, rows trimmed). The library fixtures and the new-style home continuation are
// built by hand from the renderer shapes ytmusicapi documents, because the library needs a signed-in session.
// The "signedin", "empty" and Liked music fixtures copy the renderer structure of real signed-in responses,
// with made-up titles and ids: nothing in them comes from a real library. The three History fixtures
// (browse-history*.json) are hand built the same way from the shapes ytmusicapi's get_history reads; no real
// FEmusic_history response was captured.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("InnerTubeParser browse")
struct InnerTubeParserBrowseTests {

    // MARK: - Helpers

    private func tracks(in shelf: MusicShelf) -> [MusicTrack] {
        shelf.items.compactMap { item in
            if case .track(let track) = item { track } else { nil }
        }
    }

    private func collections(in shelf: MusicShelf) -> [MusicCollection] {
        shelf.items.compactMap { item in
            if case .collection(let collection) = item { collection } else { nil }
        }
    }

    private func shelf(_ title: String, in shelves: [MusicShelf]) throws -> MusicShelf {
        try #require(shelves.first { $0.title == title })
    }

    private func fixture(_ name: String) throws -> Data { try MusicFixtures.data(name) }

    /// One home response whose only shelf holds `tiles` (raw JSON for each entry).
    private func homeData(tiles: [String], title: String = "Mixed") -> Data {
        let json = """
        {"contents":{"singleColumnBrowseResultsRenderer":{"tabs":[{"tabRenderer":{"content":{"sectionListRenderer":{"contents":[
        {"musicCarouselShelfRenderer":{"header":{"musicCarouselShelfBasicHeaderRenderer":{"title":{"runs":[{"text":"\(title)"}]}}},
        "contents":[\(tiles.joined(separator: ","))]}}]}}}}]}}}
        """
        return Data(json.utf8)
    }

    private func tile(title: String, endpoint: String, subtitle: String = "Sub", extra: String = "") -> String {
        """
        {"musicTwoRowItemRenderer":{"title":{"runs":[{"text":"\(title)"}]},"subtitle":{"runs":[{"text":"\(subtitle)"}]},\
        "navigationEndpoint":\(endpoint)\(extra)}}
        """
    }

    private func browseEndpoint(_ id: String, pageType: String?) -> String {
        let config = pageType.map {
            #","browseEndpointContextSupportedConfigs":{"browseEndpointContextMusicConfig":{"pageType":"\#($0)"}}"#
        } ?? ""
        return #"{"browseEndpoint":{"browseId":"\#(id)"\#(config)}}"#
    }

    /// A tile whose subtitle is the given runs (raw JSON, joined with commas), so a run can carry a destination.
    private func tile(title: String, endpoint: String, subtitleRuns: [String], extra: String = "") -> String {
        """
        {"musicTwoRowItemRenderer":{"title":{"runs":[{"text":"\(title)"}]},"subtitle":{"runs":[\(subtitleRuns.joined(separator: ","))]},\
        "navigationEndpoint":\(endpoint)\(extra)}}
        """
    }

    private func run(_ text: String) -> String { #"{"text":"\#(text)"}"# }

    private var bullet: String { run(" \u{2022} ") }

    /// A subtitle run that opens a page of `pageType`.
    private func linkRun(_ text: String, id: String, pageType: String) -> String {
        #"{"text":"\#(text)","navigationEndpoint":\#(browseEndpoint(id, pageType: pageType))}"#
    }

    /// The play button over a tile's cover, with the endpoint under `key` carrying `playlistId`.
    private func playOverlay(_ playlistId: String, key: String = "watchPlaylistEndpoint") -> String {
        """
        ,"thumbnailOverlay":{"musicItemThumbnailOverlayRenderer":{"content":{"musicPlayButtonRenderer":\
        {"playNavigationEndpoint":{"\(key)":{"playlistId":"\(playlistId)"}}}}}}
        """
    }

    // MARK: - Continuation tokens

    @Test("A query-style token carries the q: prefix, a body-style token goes through bare")
    func continuationEncoding() {
        #expect(InnerTubeParser.encodeContinuation("abc%3D", style: .query) == "q:abc%3D")
        #expect(InnerTubeParser.encodeContinuation("abc", style: .body) == "abc")
        #expect(InnerTubeParser.decodeContinuation("q:abc%3D") == .init(value: "abc%3D", style: .query))
        #expect(InnerTubeParser.decodeContinuation("abc") == .init(value: "abc", style: .body))
    }

    @Test("A blank token, or a prefix with nothing after it, is no token")
    func continuationBlank() {
        #expect(InnerTubeParser.decodeContinuation("") == nil)
        #expect(InnerTubeParser.decodeContinuation("  \n") == nil)
        #expect(InnerTubeParser.decodeContinuation("q:") == nil)
        #expect(InnerTubeParser.decodeContinuation(" q:abc ") == .init(value: "abc", style: .query))
    }

    // MARK: - Home

    @Test("Home capture: Quick picks rows, a playlist carousel, and the shelf with no title or items is dropped")
    func homeFromCapture() throws {
        let page = try InnerTubeParser.homePage(from: fixture("browse-home.json"))
        #expect(page.shelves.map(\.title) == ["Quick picks", "Trending community playlists"])

        let quick = try shelf("Quick picks", in: page.shelves)
        let songs = tracks(in: quick)
        #expect(songs.map(\.videoId) == ["xukbqwRuN5w", "CLSuAhT71yU", "977mwECmDs4"])
        #expect(songs.first?.title == "Choosin' Texas")
        #expect(songs.first?.artist == "Ella Langley")
        #expect(songs.first?.album == "Dandelion")
        #expect(songs.allSatisfy { $0.thumbnailURL != nil })

        let community = try shelf("Trending community playlists", in: page.shelves)
        let lists = collections(in: community)
        #expect(lists.count == 3)
        #expect(lists.allSatisfy { $0.kind == .playlist && $0.browseId.hasPrefix("VL") && $0.thumbnailURL != nil })
        #expect(lists.first?.browseId == "VLPLkpaQgbH2nStd0401Ul7-ffbGc-equxdB")
        #expect(lists.first?.title == "Throwback 2000s Hits")
        #expect(lists.first?.subtitle == "Brando • 17M views")
    }

    @Test("Home capture: the old-style continuation becomes a q: token")
    func homeContinuationToken() throws {
        let page = try InnerTubeParser.homePage(from: fixture("browse-home.json"))
        let token = try #require(page.continuation)
        #expect(token.hasPrefix("q:4qmFsgKhAhIMRkVtdXNpY19ob21l"))
        #expect(InnerTubeParser.decodeContinuation(token)?.style == .query)
    }

    @Test("Home capture: old-style sectionListContinuation gives its shelves and no further token")
    func homeContinuationOldStyle() throws {
        let page = try InnerTubeParser.homeContinuationPage(from: fixture("browse-sectionlist-continuation.json"))
        #expect(page.shelves.map(\.title) == ["Related playlists"])
        let lists = collections(in: page.shelves[0])
        #expect(lists.map(\.browseId) == [
            "VLRDCLAK5uy_nevpSx0t0YvKcJXZXxk_3Mig0Jv-AK3vc",
            "VLRDCLAK5uy_lreHzXUqXcoHfNcdPKh-aL-h4k5fckfY4",
            "VLRDCLAK5uy_kVuz2Y7g6AUnbFdB2hLHo6EH8ieytGHbg",
        ])
        #expect(lists.map(\.title) == ["Jung Kook's Love Song Selections", "Morning Drive", "Billion Views Club - Pop"])
        #expect(page.continuation == nil)
    }

    @Test("Hand-built: new-style continuation (appendContinuationItemsAction) gives shelves and a bare token")
    func homeContinuationNewStyle() throws {
        let page = try InnerTubeParser.homeContinuationPage(from: fixture("browse-home-continuation-new.json"))
        #expect(page.shelves.map(\.title) == ["Albums for you"])
        let albums = collections(in: page.shelves[0])
        #expect(albums.map(\.kind) == [.album, .album])
        #expect(albums.map(\.browseId) == ["MPREbFixtureDiscovery", "MPREbFixtureHomework0000"])
        #expect(page.continuation == "FIXTURE_HOME_NEXT2")
        #expect(InnerTubeParser.decodeContinuation(try #require(page.continuation))?.style == .body)
    }

    @Test("A home response with no section list is a parse error, not an empty page")
    func homeWithoutSectionList() {
        #expect(throws: MusicError.self) { try InnerTubeParser.homePage(from: Data(#"{"contents":{}}"#.utf8)) }
        #expect(throws: MusicError.self) { try InnerTubeParser.homePage(from: Data("not json".utf8)) }
        #expect(throws: MusicError.self) { try InnerTubeParser.homePage(from: Data()) }
    }

    @Test("A continuation with nothing to read is a parse error")
    func homeContinuationWithoutPayload() {
        #expect(throws: MusicError.self) { try InnerTubeParser.homeContinuationPage(from: Data("{}".utf8)) }
        #expect(throws: MusicError.self) { try InnerTubeParser.homeContinuationPage(from: Data("[1]".utf8)) }
    }

    @Test("A home continuation answered with the bare page skeleton is the end of the feed, not an error")
    func homeContinuationEndOfFeed() throws {
        let page = try InnerTubeParser.homeContinuationPage(from: fixture("browse-home-continuation-end.json"))
        #expect(page.shelves.isEmpty)
        #expect(page.continuation == nil)
    }

    @Test("A skeleton that still holds a section list is a malformed continuation, not the end of the feed")
    func homeContinuationSkeletonWithSectionList() {
        let json = #"{"contents":{"singleColumnBrowseResultsRenderer":{"tabs":[{"tabRenderer":{"content":{"sectionListRenderer":{}}}}]}}}"#
        #expect(throws: MusicError.self) { try InnerTubeParser.homeContinuationPage(from: Data(json.utf8)) }
        #expect(throws: MusicError.self) { try InnerTubeParser.homeContinuationPage(from: Data(#"{"contents":{}}"#.utf8)) }
    }

    @Test("Home tiles: mixes, a bare playlist id and an unknown destination map by what they open")
    func homeTileMapping() throws {
        let data = homeData(tiles: [
            tile(title: "My Mix 1", endpoint: #"{"watchPlaylistEndpoint":{"playlistId":"RDAMPLmixone"}}"#),
            tile(title: "Radio", endpoint: #"{"watchEndpoint":{"playlistId":"RDCLAKradio"}}"#),
            tile(title: "Already VL", endpoint: #"{"watchPlaylistEndpoint":{"playlistId":"VLPLalready"}}"#),
            tile(title: "Album", endpoint: browseEndpoint("MPREbalbum", pageType: "MUSIC_PAGE_TYPE_ALBUM")),
            tile(title: "Artist", endpoint: browseEndpoint("UCartist", pageType: "MUSIC_PAGE_TYPE_ARTIST")),
            tile(title: "Library artist", endpoint: browseEndpoint("UClibrary", pageType: "MUSIC_PAGE_TYPE_LIBRARY_ARTIST")),
            tile(title: "Nothing", endpoint: #"{"somethingElse":{}}"#),
        ])
        let items = collections(in: try #require(InnerTubeParser.homePage(from: data).shelves.first))
        #expect(items.map(\.browseId) == ["VLRDAMPLmixone", "VLRDCLAKradio", "VLPLalready", "MPREbalbum", "UCartist", "UClibrary"])
        #expect(items.map(\.kind) == [.playlist, .playlist, .playlist, .album, .artist, .artist])
    }

    @Test("Home tiles that Deci cannot open are dropped: podcasts, user channels, episodes, greyed out")
    func homeTileSkips() throws {
        let episode = #"{"watchEndpoint":{"videoId":"ep1","watchEndpointMusicSupportedConfigs":{"watchEndpointMusicConfig":{"musicVideoType":"MUSIC_VIDEO_TYPE_PODCAST_EPISODE"}}}}"#
        let greyed = #","musicItemRendererDisplayPolicy":"MUSIC_ITEM_RENDERER_DISPLAY_POLICY_GREY_OUT""#
        let data = homeData(tiles: [
            tile(title: "Show", endpoint: browseEndpoint("MPSPPLshow", pageType: "MUSIC_PAGE_TYPE_PODCAST_SHOW_DETAIL_PAGE")),
            tile(title: "Channel", endpoint: browseEndpoint("UCuser", pageType: "MUSIC_PAGE_TYPE_USER_CHANNEL")),
            tile(title: "Audiobook", endpoint: browseEndpoint("MPREaudio", pageType: "MUSIC_PAGE_TYPE_AUDIOBOOK")),
            tile(title: "Episode", endpoint: episode),
            tile(title: "Greyed", endpoint: browseEndpoint("MPREbgrey", pageType: "MUSIC_PAGE_TYPE_ALBUM"), extra: greyed),
            tile(title: "Kept", endpoint: browseEndpoint("MPREbkept", pageType: "MUSIC_PAGE_TYPE_ALBUM")),
        ])
        let page = try InnerTubeParser.homePage(from: data)
        #expect(collections(in: page.shelves[0]).map(\.browseId) == ["MPREbkept"])
    }

    @Test("A tile with a missing page type is told apart by its browse id prefix")
    func homeTileWithoutPageType() throws {
        let data = homeData(tiles: [
            tile(title: "PL", endpoint: browseEndpoint("VLPLx", pageType: nil)),
            tile(title: "AL", endpoint: browseEndpoint("MPREbx", pageType: nil)),
            tile(title: "AR", endpoint: browseEndpoint("UCx", pageType: nil)),
            tile(title: "Other", endpoint: browseEndpoint("FEsomething", pageType: nil)),
        ])
        let items = collections(in: try InnerTubeParser.homePage(from: data).shelves[0])
        #expect(items.map(\.kind) == [.playlist, .album, .artist])
    }

    @Test("A watch tile with a video id is a song with its artist and view line from the subtitle")
    func homeTileSong() throws {
        let data = homeData(tiles: [
            tile(title: "Never Gonna Give You Up", endpoint: #"{"watchEndpoint":{"videoId":"dQw4w9WgXcQ"}}"#, subtitle: "Rick Astley"),
        ])
        let songs = tracks(in: try InnerTubeParser.homePage(from: data).shelves[0])
        #expect(songs.map(\.videoId) == ["dQw4w9WgXcQ"])
        #expect(songs.first?.title == "Never Gonna Give You Up")
        #expect(songs.first?.artist == "Rick Astley")
    }

    @Test("A shelf with a title but no usable items is dropped, and repeated items appear once")
    func homeShelfFiltering() throws {
        let page = try InnerTubeParser.homePage(from: homeData(tiles: [
            tile(title: "Show", endpoint: browseEndpoint("MPSPPLshow", pageType: "MUSIC_PAGE_TYPE_PODCAST_SHOW_DETAIL_PAGE")),
        ]))
        #expect(page.shelves.isEmpty)

        let twice = try InnerTubeParser.homePage(from: homeData(tiles: [
            tile(title: "Same", endpoint: browseEndpoint("MPREbsame", pageType: "MUSIC_PAGE_TYPE_ALBUM")),
            tile(title: "Same", endpoint: browseEndpoint("MPREbsame", pageType: "MUSIC_PAGE_TYPE_ALBUM")),
        ]))
        #expect(twice.shelves.first?.items.count == 1)
    }

    @Test("Emoji and CJK titles pass through untouched")
    func homeUnicodeTitles() throws {
        let data = homeData(tiles: [
            tile(title: "🎵 夜に駆ける \\\"live\\\"", endpoint: browseEndpoint("MPREbunicode", pageType: "MUSIC_PAGE_TYPE_ALBUM")),
        ], title: "Für dich 💿")
        let page = try InnerTubeParser.homePage(from: data)
        #expect(page.shelves.first?.title == "Für dich 💿")
        #expect(collections(in: page.shelves[0]).first?.title == "🎵 夜に駆ける \"live\"")
    }

    @Test("A home page with thousands of tiles parses completely")
    func homeLargePage() throws {
        let tiles = (0..<5_000).map { tile(title: "Album \($0)", endpoint: browseEndpoint("MPREb\($0)", pageType: "MUSIC_PAGE_TYPE_ALBUM")) }
        let page = try InnerTubeParser.homePage(from: homeData(tiles: tiles))
        #expect(page.shelves.first?.items.count == 5_000)
    }

    // MARK: - Collection tiles: artist link and album playlist id

    @Test("An album tile keeps the artist its subtitle links to and the OLAK playlist id behind its play button")
    func homeAlbumTileKeepsArtistAndAudioPlaylist() throws {
        let data = homeData(tiles: [
            tile(
                title: "Random Access Memories",
                endpoint: browseEndpoint("MPREbalbum", pageType: "MUSIC_PAGE_TYPE_ALBUM"),
                subtitleRuns: [
                    run("Album"), bullet, linkRun("Daft Punk", id: "UCdaft", pageType: "MUSIC_PAGE_TYPE_ARTIST"), bullet, run("2013"),
                ],
                extra: playOverlay("OLAK5uy_random")
            ),
        ])
        let album = try #require(collections(in: InnerTubeParser.homePage(from: data).shelves[0]).first)
        #expect(album.kind == .album)
        #expect(album.browseId == "MPREbalbum")
        #expect(album.subtitle == "Album \u{2022} Daft Punk \u{2022} 2013")
        #expect(album.artistLinks == [MusicArtistLink(name: "Daft Punk", browseId: "UCdaft")])
        #expect(album.audioPlaylistId == "OLAK5uy_random")
    }

    @Test("An album tile with several credited artists keeps each once, in order, and a library artist opens its channel")
    func homeAlbumTileKeepsEveryArtist() throws {
        let data = homeData(tiles: [
            tile(
                title: "Collab",
                endpoint: browseEndpoint("MPREbcollab", pageType: "MUSIC_PAGE_TYPE_ALBUM"),
                subtitleRuns: [
                    run("Album"), bullet,
                    linkRun("First", id: "UCfirst", pageType: "MUSIC_PAGE_TYPE_ARTIST"), run(", "),
                    linkRun("Second", id: "MPLAUCsecond", pageType: "MUSIC_PAGE_TYPE_LIBRARY_ARTIST"), run(" & "),
                    linkRun("First", id: "UCfirst", pageType: "MUSIC_PAGE_TYPE_ARTIST"), run(" & Plain Name"),
                ]
            ),
        ])
        let album = try #require(collections(in: InnerTubeParser.homePage(from: data).shelves[0]).first)
        #expect(album.artistLinks == [
            MusicArtistLink(name: "First", browseId: "UCfirst"),
            MusicArtistLink(name: "Second", browseId: "UCsecond"),
        ])
    }

    @Test("An album tile reads the OLAK id from a watch endpoint too, and ignores an id that is not an album's")
    func homeAlbumTileAudioPlaylistVariants() throws {
        let album = browseEndpoint("MPREbalbum", pageType: "MUSIC_PAGE_TYPE_ALBUM")
        let data = homeData(tiles: [
            tile(title: "Watch", endpoint: browseEndpoint("MPREb1", pageType: "MUSIC_PAGE_TYPE_ALBUM"), extra: playOverlay("OLAK5uy_watch", key: "watchEndpoint")),
            tile(title: "Radio", endpoint: browseEndpoint("MPREb2", pageType: "MUSIC_PAGE_TYPE_ALBUM"), extra: playOverlay("RDAMPLOLAK5uy_radio")),
            tile(title: "Blank", endpoint: browseEndpoint("MPREb3", pageType: "MUSIC_PAGE_TYPE_ALBUM"), extra: playOverlay("")),
            tile(title: "No button", endpoint: album),
        ])
        let items = collections(in: try InnerTubeParser.homePage(from: data).shelves[0])
        #expect(items.map(\.audioPlaylistId) == ["OLAK5uy_watch", nil, nil, nil])
        #expect(items.allSatisfy { $0.artistLinks.isEmpty })
    }

    @Test("An album subtitle without a linked artist, or with an artist name that has no page, keeps no artist link")
    func homeAlbumTileWithoutArtistLink() throws {
        let data = homeData(tiles: [
            tile(title: "Single", endpoint: browseEndpoint("MPREb1", pageType: "MUSIC_PAGE_TYPE_ALBUM"), subtitle: "Single \u{2022} 2021"),
            tile(
                title: "Unlinked",
                endpoint: browseEndpoint("MPREb2", pageType: "MUSIC_PAGE_TYPE_ALBUM"),
                subtitleRuns: [run("Album"), bullet, run("Nobody")]
            ),
            tile(
                title: "User channel",
                endpoint: browseEndpoint("MPREb3", pageType: "MUSIC_PAGE_TYPE_ALBUM"),
                subtitleRuns: [run("Album"), bullet, linkRun("Someone", id: "UCuser", pageType: "MUSIC_PAGE_TYPE_USER_CHANNEL")]
            ),
        ])
        let items = collections(in: try InnerTubeParser.homePage(from: data).shelves[0])
        #expect(items.count == 3)
        #expect(items.allSatisfy { $0.artistLinks.isEmpty })
    }

    @Test("A playlist tile and a mix tile keep no artist and no album playlist id, even with a play button")
    func homePlaylistTileKeepsNoArtist() throws {
        let data = homeData(tiles: [
            tile(
                title: "Road Trip",
                endpoint: browseEndpoint("VLPLroad", pageType: "MUSIC_PAGE_TYPE_PLAYLIST"),
                subtitleRuns: [run("Playlist"), bullet, run("50 songs")],
                extra: playOverlay("PLroad")
            ),
            tile(title: "My Mix 1", endpoint: #"{"watchPlaylistEndpoint":{"playlistId":"RDAMPLmixone"}}"#, extra: playOverlay("RDAMPLmixone")),
        ])
        let items = collections(in: try InnerTubeParser.homePage(from: data).shelves[0])
        #expect(items.map(\.kind) == [.playlist, .playlist])
        #expect(items.map(\.browseId) == ["VLPLroad", "VLRDAMPLmixone"])
        #expect(items.allSatisfy { $0.artistLinks.isEmpty && $0.audioPlaylistId == nil })
    }

    @Test("An artist tile keeps no artist link and no album playlist id")
    func homeArtistTileKeepsNothingExtra() throws {
        let data = homeData(tiles: [
            tile(
                title: "Daft Punk",
                endpoint: browseEndpoint("UCdaft", pageType: "MUSIC_PAGE_TYPE_ARTIST"),
                subtitleRuns: [run("Artist"), bullet, run("9.1M subscribers")],
                extra: playOverlay("RDEMdaft")
            ),
        ])
        let artist = try #require(collections(in: InnerTubeParser.homePage(from: data).shelves[0]).first)
        #expect(artist.kind == .artist)
        #expect(artist.browseId == "UCdaft")
        #expect(artist.artistLinks.isEmpty)
        #expect(artist.audioPlaylistId == nil)
    }

    @Test("The captured home keeps its playlists as they were: no artist, no album playlist id")
    func homeCaptureCollectionsUnchanged() throws {
        let page = try InnerTubeParser.homePage(from: fixture("browse-home.json"))
        let lists = collections(in: try shelf("Trending community playlists", in: page.shelves))
        #expect(lists.count == 3)
        #expect(lists.allSatisfy { $0.artistLinks.isEmpty && $0.audioPlaylistId == nil })
    }

    // MARK: - History

    @Test("Hand-built history: day shelves in order, a repeat inside a day shows once, a greyed-out row is dropped")
    func historyFromFixture() throws {
        let page = try InnerTubeParser.homePage(from: fixture("browse-history.json"))
        #expect(page.shelves.map(\.title) == ["Today", "Yesterday"])

        let today = tracks(in: try shelf("Today", in: page.shelves))
        #expect(today.map(\.videoId) == ["fixHist0001", "fixHist0002"])
        #expect(today.first?.title == "Fixture Song One")
        #expect(today.first?.artist == "Fixture Artist A")
        #expect(today.first?.album == "Fixture Album One")
        #expect(today.first?.albumBrowseId == "MPREbFixtureAlbumOne")
        #expect(today.first?.artistLinks.map(\.browseId) == ["UCfixtureArtistA0000001"])
        #expect(today.first?.durationSeconds == 201)
        #expect(today.allSatisfy { $0.thumbnailURL != nil })

        // The same song may sit on two days: each day keeps its own row. A video has no album.
        let yesterday = tracks(in: try shelf("Yesterday", in: page.shelves))
        #expect(yesterday.map(\.videoId) == ["fixHist0002", "fixHist0003"])
        #expect(yesterday.last?.album == nil)
    }

    @Test("Hand-built history: the first page hands on an old-style q: token")
    func historyContinuationToken() throws {
        let page = try InnerTubeParser.homePage(from: fixture("browse-history.json"))
        #expect(page.continuation == "q:FIXTURE_HISTORY_NEXT%3D")
        #expect(InnerTubeParser.decodeContinuation(try #require(page.continuation))?.style == .query)
    }

    @Test("Hand-built history continuation: further day shelves and the next token")
    func historyContinuationPage() throws {
        let page = try InnerTubeParser.homeContinuationPage(from: fixture("browse-history-continuation.json"))
        #expect(page.shelves.map(\.title) == ["This week", "Last week"])
        #expect(tracks(in: page.shelves[0]).map(\.videoId) == ["fixHist0005", "fixHist0006"])
        #expect(tracks(in: page.shelves[1]).map(\.videoId) == ["fixHist0007"])
        #expect(page.continuation == "q:FIXTURE_HISTORY_NEXT2%3D")
    }

    @Test("Paused or empty history (a notifier shelf) is an empty list with no token, not an error")
    func historyPausedIsEmpty() throws {
        let page = try InnerTubeParser.homePage(from: fixture("browse-history-paused.json"))
        #expect(page.shelves.isEmpty)
        #expect(page.continuation == nil)
    }

    @Test("A history response with no section list at all is still a parse error")
    func historyWithoutSectionList() {
        #expect(throws: MusicError.self) { try InnerTubeParser.homePage(from: Data("{}".utf8)) }
    }

    @Test("History shelves of one day that hold only unplayable rows vanish instead of showing an empty header")
    func historyShelfOfOnlyGreyedRows() throws {
        let page = try InnerTubeParser.homePage(from: historyData(shelves: [
            ("Today", [historyRow(id: "gone1", greyed: true), historyRow(id: "gone2", greyed: true)]),
            ("Yesterday", [historyRow(id: "kept1")]),
        ]))
        #expect(page.shelves.map(\.title) == ["Yesterday"])
    }

    @Test("History titles with emoji, accents and quotes survive")
    func historyUnicodeTitles() throws {
        let page = try InnerTubeParser.homePage(from: historyData(shelves: [
            ("Earlier this month", [historyRow(id: "uni1", title: "夜に駆ける 🎵 \\\"live\\\"")]),
        ]))
        #expect(tracks(in: page.shelves[0]).first?.title == "夜に駆ける 🎵 \"live\"")
    }

    @Test("A history of thousands of rows parses completely")
    func historyLargePage() throws {
        let rows = (0..<5_000).map { historyRow(id: "big\($0)") }
        let page = try InnerTubeParser.homePage(from: historyData(shelves: [("Earlier", rows)]))
        #expect(page.shelves.first?.items.count == 5_000)
    }

    /// One history response made of `shelves` (title and raw row JSON).
    private func historyData(shelves: [(String, [String])]) -> Data {
        let bodies = shelves.map { title, rows in
            #"{"musicShelfRenderer":{"title":{"runs":[{"text":"\#(title)"}]},"contents":[\#(rows.joined(separator: ","))]}}"#
        }
        let json = """
        {"contents":{"singleColumnBrowseResultsRenderer":{"tabs":[{"tabRenderer":{"content":{"sectionListRenderer":{"contents":[\(bodies.joined(separator: ","))]}}}}]}}}
        """
        return Data(json.utf8)
    }

    private func historyRow(id: String, title: String = "Song", greyed: Bool = false) -> String {
        let policy = greyed ? #","musicItemRendererDisplayPolicy":"MUSIC_ITEM_RENDERER_DISPLAY_POLICY_GREY_OUT""# : ""
        return """
        {"musicResponsiveListItemRenderer":{"playlistItemData":{"videoId":"\(id)"},\
        "flexColumns":[{"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"\(title)","navigationEndpoint":{"watchEndpoint":{"videoId":"\(id)"}}}]}}},\
        {"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"Artist"}]}}}]\(policy)}}
        """
    }

    // MARK: - Playlist pages

    @Test("Playlist capture: header, subtitle with the song count, cover, and the greyed-out row is dropped")
    func playlistFromCapture() throws {
        let page = try InnerTubeParser.browsePage(from: fixture("browse-playlist.json"), browseId: "VLPL4fGSI1pDJn6puJdseH2Rt9sMvt9E2M4i")
        #expect(page.browseId == "VLPL4fGSI1pDJn6puJdseH2Rt9sMvt9E2M4i")
        #expect(page.title == "Top 100 Songs Global")
        #expect(page.subtitle == "Chart • 2026 • 100 songs")
        #expect(page.thumbnailURL != nil)
        #expect(page.tracks.map(\.videoId) == ["fcnDmrtj6Sk", "xvT1jH8B9AM", "fRIhCiUVaKs"])
        #expect(page.tracks.map(\.durationSeconds) == [241, 288, 226])
        #expect(page.tracks.first?.title == "Dai Dai")
        #expect(page.tracks.allSatisfy { !$0.artist.isEmpty && $0.thumbnailURL != nil })
        #expect(page.continuation == nil)
        #expect(page.shelves.isEmpty)
    }

    @Test("Long playlist capture: the page token is the track list's own, not the related-shelves one")
    func longPlaylistContinuation() throws {
        let page = try InnerTubeParser.browsePage(from: fixture("browse-playlist-long.json"), browseId: "VLPLFgquLnL59alCl_2TQvOiD5Vgm1hCaGSI")
        #expect(page.title == "Popular Music Videos")
        #expect(page.subtitle == "Playlist • 2026 • 182 tracks")
        #expect(page.tracks.map(\.videoId) == ["fOT0BUpITw8", "NFvDHYMzj9U", "8c7KOGxeY3w", "s6cdjJvGM2o"])
        let token = try #require(page.continuation)
        #expect(token.hasPrefix("4qmFsgKHARIkVkxQTEZncXVMbkw1OWFs"))
        // The section list's own nextContinuationData (4qmFsgI0...) continues with related shelves.
        #expect(InnerTubeParser.decodeContinuation(token)?.style == .body)
        #expect(!token.hasPrefix("q:"))
    }

    @Test("Long playlist capture: a row with an album in its third column keeps the album")
    func longPlaylistAlbumColumn() throws {
        let page = try InnerTubeParser.browsePage(from: fixture("browse-playlist-long.json"), browseId: "VLPLFgquLnL59alCl_2TQvOiD5Vgm1hCaGSI")
        let diabla = try #require(page.tracks.first { $0.videoId == "s6cdjJvGM2o" })
        #expect(diabla.title == "La Diabla")
        #expect(diabla.artist == "Xavi")
        #expect(diabla.album == "La Diabla")
        #expect(diabla.durationSeconds == 173)
        #expect(page.tracks.first?.album == nil)
    }

    @Test("Playlist continuation capture (new style): rows, albums, and no token at the end")
    func playlistContinuationNewStyle() throws {
        let page = try InnerTubeParser.tracksContinuationPage(from: fixture("browse-playlist-continuation.json"))
        #expect(page.tracks.map(\.videoId) == ["1STyaZA7-BY", "Ke9A6XV2H38", "_db-mfu8y1k", "23v1sAktHkc"])
        #expect(page.tracks.map(\.album) == [nil, "Federal Contraband 2", "THE WORLD EP.FIN : WILL", nil])
        #expect(page.tracks.map(\.durationSeconds) == [266, 438, 199, 201])
        #expect(page.continuation == nil)
    }

    @Test("Hand-built: old-style musicPlaylistShelfContinuation gives rows and a q: token")
    func playlistContinuationOldStyle() throws {
        let page = try InnerTubeParser.tracksContinuationPage(from: fixture("browse-tracks-continuation-old.json"))
        #expect(page.tracks.map(\.videoId) == ["fixtureVid0001", "fixtureVid0002"])
        #expect(page.tracks.map(\.durationSeconds) == [320, 212])
        #expect(page.tracks.map(\.artist) == ["Daft Punk", "Daft Punk"])
        #expect(page.continuation == "q:FIXTURE_TRACKS_NEXT2%3D")
    }

    @Test("A tracks continuation with nothing to read is a parse error")
    func tracksContinuationWithoutPayload() {
        #expect(throws: MusicError.self) { try InnerTubeParser.tracksContinuationPage(from: Data("{}".utf8)) }
        #expect(throws: MusicError.self) { try InnerTubeParser.tracksContinuationPage(from: Data("oops".utf8)) }
    }

    @Test("A tracks continuation answered with the bare page skeleton is the last page")
    func tracksContinuationEndOfList() throws {
        let page = try InnerTubeParser.tracksContinuationPage(from: fixture("browse-home-continuation-end.json"))
        #expect(page.tracks.isEmpty)
        #expect(page.continuation == nil)
    }

    @Test("Liked music with no liked songs: the header says 0 songs and the playlist shelf has an empty state, no rows")
    func likedMusicEmpty() throws {
        let page = try InnerTubeParser.browsePage(from: fixture("browse-liked-music.json"), browseId: "VLLM")
        #expect(page.browseId == "VLLM")
        #expect(page.title == "Liked music")
        #expect(page.subtitle == "Auto playlist \u{2022} 0 songs")
        #expect(page.thumbnailURL != nil)
        #expect(page.tracks.isEmpty)
        #expect(page.continuation == nil)
        #expect(page.shelves.isEmpty)
    }

    @Test("A page response with no header is a parse error")
    func pageWithoutHeader() {
        #expect(throws: MusicError.self) { try InnerTubeParser.browsePage(from: Data(#"{"contents":{}}"#.utf8), browseId: "VLx") }
        #expect(throws: MusicError.self) { try InnerTubeParser.browsePage(from: Data("nope".utf8), browseId: "VLx") }
    }

    // MARK: - Album pages

    @Test("Album capture: rows with no artist or album of their own get the album's artist, name and cover")
    func albumFromCapture() throws {
        let page = try InnerTubeParser.browsePage(from: fixture("browse-album.json"), browseId: "MPREb_Me5NUhDIBWQ")
        #expect(page.title == "Are We There Yet?")
        #expect(page.subtitle == "Album • 2023 • 12 songs")
        let cover = try #require(page.thumbnailURL)
        #expect(page.tracks.map(\.videoId) == ["zVRaZlwLyJw", "Jy70c9u0yeo", "DSIaExtrG9k", "qWNQUvIk954"])
        #expect(page.tracks.map(\.title) == ["Dippin My Feet", "Letting Go", "Golden Hour", "Never Gonna Stop"])
        #expect(page.tracks.map(\.durationSeconds) == [194, 203, 226, 198])
        #expect(page.tracks.allSatisfy { $0.artist == "Rick Astley" })
        #expect(page.tracks.allSatisfy { $0.album == "Are We There Yet?" })
        #expect(page.tracks.allSatisfy { $0.thumbnailURL == cover })
    }

    @Test("Album capture: the play counts in the third column are not taken for the album name")
    func albumIgnoresPlayCounts() throws {
        let page = try InnerTubeParser.browsePage(from: fixture("browse-album.json"), browseId: "MPREb_Me5NUhDIBWQ")
        #expect(page.tracks.allSatisfy { !($0.album ?? "").contains("plays") })
    }

    @Test("Album capture: the Releases for you carousel is not an album page shelf")
    func albumHasNoShelves() throws {
        let page = try InnerTubeParser.browsePage(from: fixture("browse-album.json"), browseId: "MPREb_Me5NUhDIBWQ")
        #expect(page.shelves.isEmpty)
        #expect(page.continuation == nil)
    }

    private static let albumPlaylistId = "OLAK5uy_kKuGqoUQo37hejjtZXF1ALYGh1gSXjcUQ"

    /// The album capture's text with the first `count` occurrences of its OLAK id replaced by `replacement`.
    private func albumData(replacingOlak count: Int, with replacement: String) throws -> Data {
        var text = try MusicFixtures.string("browse-album.json")
        for _ in 0..<count {
            let range = try #require(text.range(of: Self.albumPlaylistId))
            text.replaceSubrange(range, with: replacement)
        }
        return Data(text.utf8)
    }

    @Test("Album capture: the page keeps the OLAK playlist its rows play from, and asks the automix of it")
    func albumKeepsAudioPlaylistId() throws {
        let page = try InnerTubeParser.browsePage(from: fixture("browse-album.json"), browseId: "MPREb_Me5NUhDIBWQ")
        #expect(page.audioPlaylistId == Self.albumPlaylistId)
        #expect(page.automixPlaylistId == Self.albumPlaylistId)
    }

    @Test("Hand-built album: a first row without an OLAK playlist is passed over for the next row that has one")
    func albumAudioPlaylistIdFromLaterRow() throws {
        let data = try albumData(replacingOlak: 1, with: "RDAMVMzVRaZlwLyJw")
        let page = try InnerTubeParser.browsePage(from: data, browseId: "MPREb_Me5NUhDIBWQ")
        #expect(page.audioPlaylistId == Self.albumPlaylistId)
        #expect(page.tracks.count == 4)
    }

    @Test("Hand-built album: rows that play from a radio or a plain playlist leave the album with no audio playlist")
    func albumWithoutOlak() throws {
        let data = try albumData(replacingOlak: 4, with: "PLnotAnAlbum")
        let page = try InnerTubeParser.browsePage(from: data, browseId: "MPREb_Me5NUhDIBWQ")
        #expect(page.audioPlaylistId == nil)
        #expect(page.automixPlaylistId == nil)
        #expect(page.tracks.count == 4)
    }

    @Test("Playlist, Liked Music and artist captures carry no audio playlist id")
    func otherPagesHaveNoAudioPlaylistId() throws {
        let playlist = try InnerTubeParser.browsePage(from: fixture("browse-playlist.json"), browseId: "VLPL4fGSI1pDJn6puJdseH2Rt9sMvt9E2M4i")
        let liked = try InnerTubeParser.browsePage(from: fixture("browse-liked-music.json"), browseId: "VLLM")
        let artist = try InnerTubeParser.browsePage(from: fixture("browse-artist.json"), browseId: "UCuAXFkgsw1L7xaCfnd5JJOw")
        #expect(playlist.audioPlaylistId == nil)
        #expect(liked.audioPlaylistId == nil)
        #expect(artist.audioPlaylistId == nil)
        // The automix of a playlist page is its own playlist, of an artist page there is none.
        #expect(playlist.automixPlaylistId == "PL4fGSI1pDJn6puJdseH2Rt9sMvt9E2M4i")
        #expect(liked.automixPlaylistId == "LM")
        #expect(artist.automixPlaylistId == nil)
    }

    // MARK: - Artist pages

    @Test("Artist capture: name, subscriber line and the top songs as tracks")
    func artistFromCapture() throws {
        let page = try InnerTubeParser.browsePage(from: fixture("browse-artist.json"), browseId: "UCuAXFkgsw1L7xaCfnd5JJOw")
        #expect(page.title == "Rick Astley")
        #expect(page.subtitle == "4.55M subscribers")
        #expect(page.thumbnailURL != nil)
        #expect(page.tracks.map(\.videoId) == ["lYBUbBu4W08", "i_Q88T1HI_w"])
        #expect(page.tracks.map(\.title) == ["Never Gonna Give You Up", "Together Forever"])
        #expect(page.tracks.allSatisfy { $0.artist == "Rick Astley" })
        #expect(page.tracks.map(\.album) == ["Whenever You Need Somebody", "Whenever You Need Somebody"])
        #expect(page.continuation == nil)
    }

    @Test("Artist capture: every carousel is a shelf, in page order")
    func artistShelves() throws {
        let page = try InnerTubeParser.browsePage(from: fixture("browse-artist.json"), browseId: "UCuAXFkgsw1L7xaCfnd5JJOw")
        #expect(page.shelves.map(\.title) == [
            "Albums", "Singles & EPs", "Videos", "Live performances", "Featured on", "Playlists by Rick Astley", "Fans might also like",
        ])
    }

    @Test("Artist capture: albums, videos, playlists and related artists map to the right item types")
    func artistShelfItems() throws {
        let page = try InnerTubeParser.browsePage(from: fixture("browse-artist.json"), browseId: "UCuAXFkgsw1L7xaCfnd5JJOw")

        let albums = collections(in: try shelf("Albums", in: page.shelves))
        #expect(albums.map(\.browseId) == ["MPREb_Me5NUhDIBWQ", "MPREb_YKPggt0KgW1"])
        #expect(albums.allSatisfy { $0.kind == .album })
        #expect(albums.first?.title == "Are We There Yet?")
        #expect(albums.first?.subtitle == "2023")

        let singles = collections(in: try shelf("Singles & EPs", in: page.shelves))
        #expect(singles.map(\.browseId) == ["MPREb_SslJVn92SLw", "MPREb_1cjGnxYuQzu"])

        let videos = tracks(in: try shelf("Videos", in: page.shelves))
        #expect(videos.map(\.videoId) == ["dQw4w9WgXcQ", "yPYZpwSpKmA"])
        #expect(videos.first?.title == "Never Gonna Give You Up")

        let playlists = collections(in: try shelf("Playlists by Rick Astley", in: page.shelves))
        #expect(playlists.allSatisfy { $0.kind == .playlist && $0.browseId.hasPrefix("VLPL") })

        let related = collections(in: try shelf("Fans might also like", in: page.shelves))
        #expect(related.map(\.browseId) == ["UCB3qJDg2Dtzw7_cTGKn8dqw", "UCak2_SOTrC61nzqli-cNThw"])
        #expect(related.allSatisfy { $0.kind == .artist })
        #expect(related.first?.title == "Paul Young")
    }

    // MARK: - Library

    @Test("Hand-built playlists grid: New playlist and a podcast show are dropped, Liked music is kept for the store to filter")
    func libraryPlaylists() throws {
        let list = try InnerTubeParser.libraryPage(from: fixture("browse-library-playlists.json"))
        #expect(list.items.map(\.browseId) == ["VLLM", "VLPLfixtureRoadTrip0000000000000000", "VLPLfixtureFocus00000000000000000000"])
        #expect(list.items.allSatisfy { $0.kind == .playlist })
        #expect(list.items.map(\.title) == ["Liked music", "Road trip", "Focus"])
        #expect(list.items.map(\.subtitle) == ["Auto playlist", "Playlist • 42 songs", "Playlist • 17 songs"])
        #expect(list.items.allSatisfy { $0.thumbnailURL != nil })
        #expect(list.continuation == "q:FIXTURE_LIB_PLAYLISTS_NEXT%3D")
    }

    @Test("Hand-built albums grid: new-style continuationItemRenderer gives a bare token")
    func libraryAlbums() throws {
        let list = try InnerTubeParser.libraryPage(from: fixture("browse-library-albums.json"))
        #expect(list.items.map(\.browseId) == ["MPREbFixtureRam0000", "MPREbFixtureDiscovery"])
        #expect(list.items.allSatisfy { $0.kind == .album })
        #expect(list.items.first?.title == "Random Access Memories")
        #expect(list.continuation == "FIXTURE_LIB_ALBUMS_NEXT")
    }

    @Test("Hand-built artists shelf: rows with a browse endpoint become artists, an MPLA id opens the channel")
    func libraryArtists() throws {
        let list = try InnerTubeParser.libraryPage(from: fixture("browse-library-artists.json"))
        #expect(list.items.map(\.browseId) == ["UCfixtureDaftPunk000000000", "UCfixtureJustice0000000000"])
        #expect(list.items.allSatisfy { $0.kind == .artist })
        #expect(list.items.map(\.title) == ["Daft Punk", "Justice"])
        #expect(list.items.map(\.subtitle) == ["12 songs", "3 songs"])
        #expect(list.items.allSatisfy { $0.thumbnailURL != nil })
        #expect(list.continuation == "q:FIXTURE_LIB_ARTISTS_NEXT%3D")
    }

    @Test("Hand-built: destinations with no page type are told apart by their browse id")
    func libraryTypeless() throws {
        let list = try InnerTubeParser.libraryPage(from: fixture("browse-library-typeless.json"))
        #expect(list.items.map(\.kind) == [.playlist, .album])
        #expect(list.continuation == nil)
    }

    @Test("A library response with no list is an empty list, not an error")
    func libraryEmpty() throws {
        for json in [#"{"contents":{}}"#, "{}", #"{"contents":{"singleColumnBrowseResultsRenderer":{"tabs":[{"tabRenderer":{}}]}}}"#] {
            let list = try InnerTubeParser.libraryPage(from: Data(json.utf8))
            #expect(list.items.isEmpty)
            #expect(list.continuation == nil)
        }
    }

    @Test("A library response that is not JSON is a parse error")
    func libraryGarbage() {
        #expect(throws: MusicError.self) { try InnerTubeParser.libraryPage(from: Data("<html>".utf8)) }
    }

    @Test("Hand-built: old-style gridContinuation gives its tiles and the next q: token")
    func libraryContinuationGrid() throws {
        let list = try InnerTubeParser.libraryContinuationPage(from: fixture("browse-library-continuation-grid.json"))
        #expect(list.items.map(\.browseId) == ["VLPLfixtureWorkout0000000000000000", "VLPLfixtureFocus00000000000000000000"])
        #expect(list.continuation == "q:FIXTURE_LIB_PLAYLISTS_NEXT2%3D")
    }

    @Test("Hand-built: old-style musicShelfContinuation gives its rows and no token at the end")
    func libraryContinuationShelf() throws {
        let list = try InnerTubeParser.libraryContinuationPage(from: fixture("browse-library-continuation-shelf.json"))
        #expect(list.items.map(\.browseId) == ["UCfixtureAir00000000000000"])
        #expect(list.items.first?.kind == .artist)
        #expect(list.continuation == nil)
    }

    @Test("Hand-built: new-style continuation gives its tiles and a bare token")
    func libraryContinuationNewStyle() throws {
        let list = try InnerTubeParser.libraryContinuationPage(from: fixture("browse-library-continuation-new.json"))
        #expect(list.items.map(\.browseId) == ["MPREbFixtureHomework0000"])
        #expect(list.continuation == "FIXTURE_LIB_ALBUMS_NEXT2")
    }

    @Test("A library continuation with nothing to read is a parse error")
    func libraryContinuationWithoutPayload() {
        #expect(throws: MusicError.self) { try InnerTubeParser.libraryContinuationPage(from: Data("{}".utf8)) }
        #expect(throws: MusicError.self) { try InnerTubeParser.libraryContinuationPage(from: Data("nope".utf8)) }
    }

    @Test("A library continuation answered with the bare page skeleton is the end of the list")
    func libraryContinuationEndOfList() throws {
        let list = try InnerTubeParser.libraryContinuationPage(from: fixture("browse-home-continuation-end.json"))
        #expect(list.items.isEmpty)
        #expect(list.continuation == nil)
    }

    @Test("Signed-in playlists: New playlist and Episodes for later are dropped, and the other tab's reload token is not a next page")
    func libraryPlaylistsSignedIn() throws {
        let list = try InnerTubeParser.libraryPage(from: fixture("browse-library-playlists-signedin.json"))
        #expect(list.items.map(\.browseId) == ["VLPLfixtureSavedRoadMix0000000000000000"])
        #expect(list.items.first?.kind == .playlist)
        #expect(list.items.first?.title == "Fixture Road Mix")
        #expect(list.items.first?.subtitle == "Fixture1 \u{2022} 12 songs")
        #expect(list.items.first?.thumbnailURL != nil)
        #expect(list.continuation == nil)
    }

    @Test("Signed-in albums with none saved: an item section with only the empty-state message is an empty list")
    func libraryAlbumsEmptyMessage() throws {
        let list = try InnerTubeParser.libraryPage(from: fixture("browse-library-albums-empty.json"))
        #expect(list.items.isEmpty)
        #expect(list.continuation == nil)
    }

    @Test("Signed-in artists: a LIBRARY_ARTIST row linking to MPLAUC opens the UC channel")
    func libraryArtistsSignedIn() throws {
        let list = try InnerTubeParser.libraryPage(from: fixture("browse-library-artists-signedin.json"))
        #expect(list.items.map(\.browseId) == ["UCfixtureLibraryArtist0"])
        #expect(list.items.first?.kind == .artist)
        #expect(list.items.first?.title == "Fixture Artist")
        #expect(list.items.first?.subtitle == "1 song")
        #expect(list.items.first?.thumbnailURL != nil)
        #expect(list.continuation == nil)
    }

    // MARK: - Search rows still parse

    @Test("The search fixture still parses to the same rows after the browse changes")
    func searchUnchanged() throws {
        let rows = try InnerTubeParser.searchTracks(from: fixture("search-songs.json"))
        #expect(rows.count == 6)
        #expect(rows.allSatisfy { !$0.videoId.isEmpty && !$0.title.isEmpty && $0.durationSeconds != nil })
    }
}
