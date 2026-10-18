// DeciTests/Music/InnerTubeParserTests.swift
// The InnerTube response parsers, run against responses captured from the public endpoints
// (visitor data, tracking tokens and IPs scrubbed) plus hand-written edge cases.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("InnerTubeParser")
struct InnerTubeParserTests {

    // MARK: - Bootstrap page

    @Test("ytcfg yields the client version, visitor data and player JS URL")
    func bootstrapFromFixture() throws {
        let html = try MusicFixtures.string("music-home-bootstrap.html")
        let config = InnerTubeParser.bootstrapConfig(fromHTML: html)
        #expect(config.clientVersion == "1.20261013.15.00")
        #expect(config.visitorData == "SCRUBBED_VISITOR_DATA")
        #expect(config.playerJSURL?.absoluteString == "https://music.youtube.com/s/player/0229cd64/player_es6.vflset/en_US/base.js")
    }

    @Test("A page with no ytcfg yields nothing instead of failing")
    func bootstrapWithoutYTCfg() {
        let config = InnerTubeParser.bootstrapConfig(fromHTML: "<html><body>consent</body></html>")
        #expect(config == BootstrapConfig(clientVersion: nil, visitorData: nil, playerJSURL: nil))
    }

    @Test("A top-level PLAYER_JS_URL wins over the nested jsUrl")
    func bootstrapPrefersPlayerJSURL() {
        let html = #"""
        ytcfg.set({"INNERTUBE_CLIENT_VERSION":"1.1","PLAYER_JS_URL":"/s/player/aaaa1111/player_es6.vflset/en_US/base.js","WEB_PLAYER_CONTEXT_CONFIGS":{"X":{"jsUrl":"/s/player/bbbb2222/player_es6.vflset/en_US/base.js"}}});
        """#
        let config = InnerTubeParser.bootstrapConfig(fromHTML: html)
        #expect(config.playerJSURL?.path == "/s/player/aaaa1111/player_es6.vflset/en_US/base.js")
    }

    @Test("A jsUrl that is not inside a parsable ytcfg block is still found")
    func bootstrapJSURLFallback() {
        let html = #"""
        ytcfg.set({"INNERTUBE_CLIENT_VERSION":"2.2", broken json here});
        var x = {"jsUrl":"/s/player/cccc3333/player_es6.vflset/en_US/base.js"};
        """#
        let config = InnerTubeParser.bootstrapConfig(fromHTML: html)
        #expect(config.playerJSURL?.path == "/s/player/cccc3333/player_es6.vflset/en_US/base.js")
    }

    @Test("Braces and escaped quotes inside strings do not end the ytcfg block early")
    func bootstrapBraceInString() {
        let html = #"""
        ytcfg.set({"NOTE":"a } b \" } c","INNERTUBE_CLIENT_VERSION":"3.3","VISITOR_DATA":"v{d}"});
        """#
        let config = InnerTubeParser.bootstrapConfig(fromHTML: html)
        #expect(config.clientVersion == "3.3")
        #expect(config.visitorData == "v{d}")
    }

    // MARK: - Player JS

    @Test("The player hash is the path segment after /s/player/")
    func playerHash() {
        let url = URL(string: "https://music.youtube.com/s/player/0229cd64/player_es6.vflset/en_US/base.js")!
        #expect(InnerTubeParser.playerHash(fromPlayerJSURL: url) == "0229cd64")
        #expect(InnerTubeParser.playerHash(fromPlayerJSURL: URL(string: "https://music.youtube.com/other/x.js")!) == nil)
    }

    @Test("signatureTimestamp is read from the player JS")
    func signatureTimestamp() {
        let js = "var a=1;foo({referer:document.location.toString(),signatureTimestamp:20739},r=g.tI());"
        #expect(InnerTubeParser.signatureTimestamp(fromPlayerJS: js) == 20739)
    }

    @Test("The sts alias is used when signatureTimestamp is absent")
    func signatureTimestampAlias() {
        #expect(InnerTubeParser.signatureTimestamp(fromPlayerJS: "x={sts: 20123,a:1}") == 20123)
    }

    @Test("A player JS without a timestamp gives nil")
    func signatureTimestampMissing() {
        #expect(InnerTubeParser.signatureTimestamp(fromPlayerJS: "var nothing = 1;") == nil)
        #expect(InnerTubeParser.signatureTimestamp(fromPlayerJS: "signatureTimestamp:abc") == nil)
        #expect(InnerTubeParser.signatureTimestamp(fromPlayerJS: "") == nil)
    }

    // MARK: - Search

    @Test("Search fixture parses to song rows with artist, album, duration and thumbnail")
    func searchFixture() throws {
        let tracks = try InnerTubeParser.searchTracks(from: MusicFixtures.data("search-songs.json"))
        #expect(tracks.count == 6)
        let first = try #require(tracks.first)
        #expect(first.videoId == "4D7u5KF7SP8")
        #expect(first.title == "Get Lucky (feat. Pharrell Williams and Nile Rodgers)")
        #expect(first.artist == "Daft Punk, Pharrell Williams, Nile Rodgers")
        #expect(first.album == "Random Access Memories")
        #expect(first.durationSeconds == 370)
        #expect(first.thumbnailURL?.absoluteString.hasSuffix("=w120-h120-l90-rj") == true)
        #expect(first.id == "4D7u5KF7SP8")
    }

    @Test("A row with a single artist and no extra credits keeps just that artist")
    func searchSingleArtist() throws {
        let tracks = try InnerTubeParser.searchTracks(from: MusicFixtures.data("search-songs.json"))
        let kids = try #require(tracks.first { $0.videoId == "28DL6VcWIb0" })
        #expect(kids.artist == "The Countdown Kids")
        #expect(kids.album == "Covers By Kids")
        #expect(kids.durationSeconds == 247)
    }

    @Test("Every fixture row has a video id, a title and a duration")
    func searchRowsComplete() throws {
        let tracks = try InnerTubeParser.searchTracks(from: MusicFixtures.data("search-songs.json"))
        for track in tracks {
            #expect(!track.videoId.isEmpty)
            #expect(!track.title.isEmpty)
            #expect(!track.artist.isEmpty)
            #expect(track.durationSeconds != nil)
        }
        #expect(Set(tracks.map(\.videoId)).count == tracks.count)
    }

    @Test("A row without an album parses with a nil album")
    func searchWithoutAlbum() throws {
        let json = Self.searchJSON(rows: [
            Self.row(videoId: "abc", title: "Solo", subtitleRuns: [("Some Artist", "MUSIC_PAGE_TYPE_ARTIST"), (" • ", nil), ("3:05", nil)]),
        ])
        let tracks = try InnerTubeParser.searchTracks(from: json)
        #expect(tracks.count == 1)
        #expect(tracks[0].artist == "Some Artist")
        #expect(tracks[0].album == nil)
        #expect(tracks[0].durationSeconds == 185)
    }

    @Test("An artist with no browse link still shows up as the artist")
    func searchArtistWithoutLink() throws {
        let json = Self.searchJSON(rows: [
            Self.row(videoId: "abc", title: "T", subtitleRuns: [("Plain Uploader", nil), (" • ", nil), ("Album X", "MUSIC_PAGE_TYPE_ALBUM"), (" • ", nil), ("1:02:03", nil)]),
        ])
        let tracks = try InnerTubeParser.searchTracks(from: json)
        #expect(tracks[0].artist == "Plain Uploader")
        #expect(tracks[0].album == "Album X")
        #expect(tracks[0].durationSeconds == 3723)
    }

    @Test("Rows without a video id are skipped")
    func searchSkipsRowsWithoutVideoId() throws {
        let json = Self.searchJSON(rows: [
            Self.row(videoId: nil, title: "No id", subtitleRuns: [("A", nil), (" • ", nil), ("1:00", nil)]),
            Self.row(videoId: "keep", title: "Has id", subtitleRuns: [("A", nil), (" • ", nil), ("1:00", nil)]),
        ])
        #expect(try InnerTubeParser.searchTracks(from: json).map(\.videoId) == ["keep"])
    }

    @Test("A row with no duration text gives a nil duration")
    func searchWithoutDuration() throws {
        let json = Self.searchJSON(rows: [
            Self.row(videoId: "abc", title: "T", subtitleRuns: [("A", "MUSIC_PAGE_TYPE_ARTIST")]),
        ])
        #expect(try InnerTubeParser.searchTracks(from: json)[0].durationSeconds == nil)
    }

    @Test("The thumbnail closest to 120 px wins, and none gives nil")
    func searchThumbnailPick() throws {
        let sizes: [[Int]] = [[60, 120], [226, 544], [60], []]
        let rows = sizes.enumerated().map { index, widths in
            Self.row(videoId: "v\(index)", title: "T", subtitleRuns: [("A", nil)], thumbnailWidths: widths)
        }
        let tracks = try InnerTubeParser.searchTracks(from: Self.searchJSON(rows: rows))
        #expect(tracks[0].thumbnailURL?.absoluteString == "https://img.test/120")
        #expect(tracks[1].thumbnailURL?.absoluteString == "https://img.test/226")
        #expect(tracks[2].thumbnailURL?.absoluteString == "https://img.test/60")
        #expect(tracks[3].thumbnailURL == nil)
    }

    @Test("A response with no results shelf is an empty list, not an error")
    func searchEmpty() throws {
        #expect(try InnerTubeParser.searchTracks(from: Data("{}".utf8)).isEmpty)
        let message = #"{"contents":{"tabbedSearchResultsRenderer":{"tabs":[{"tabRenderer":{"content":{"sectionListRenderer":{"contents":[{"itemSectionRenderer":{"contents":[{"messageRenderer":{}}]}}]}}}}]}}}"#
        #expect(try InnerTubeParser.searchTracks(from: Data(message.utf8)).isEmpty)
    }

    @Test("Garbage that is not JSON throws a parse error")
    func searchInvalidJSON() {
        #expect(throws: MusicError.self) { try InnerTubeParser.searchTracks(from: Data("<html>".utf8)) }
        #expect(throws: MusicError.self) { try InnerTubeParser.searchTracks(from: Data()) }
    }

    @Test("Unicode titles survive parsing")
    func searchUnicode() throws {
        let json = Self.searchJSON(rows: [
            Self.row(videoId: "u1", title: "夜に駆ける 🎵 café", subtitleRuns: [("YOASOBI", "MUSIC_PAGE_TYPE_ARTIST"), (" • ", nil), ("4:21", nil)]),
        ])
        #expect(try InnerTubeParser.searchTracks(from: json)[0].title == "夜に駆ける 🎵 café")
    }

    @Test("Large result lists parse")
    func searchManyRows() throws {
        let rows = (0..<2_000).map { Self.row(videoId: "v\($0)", title: "T\($0)", subtitleRuns: [("A", nil), (" • ", nil), ("2:00", nil)]) }
        let tracks = try InnerTubeParser.searchTracks(from: Self.searchJSON(rows: rows))
        #expect(tracks.count == 2_000)
    }

    // MARK: - Player

    @Test("Player fixture parses status, formats, expiry, tracking URL and length")
    func playerFixture() throws {
        let response = try InnerTubeParser.playerResponse(from: MusicFixtures.data("player-ok.json"))
        #expect(response.status == "OK")
        #expect(response.reason == nil)
        #expect(response.expiresInSeconds == 21540)
        #expect(response.lengthSeconds == 370)
        #expect(response.playbackTrackingURL?.host == "s.youtube.com")
        #expect(response.playbackTrackingURL?.path == "/api/stats/playback")
        let itags = response.formats.map(\.itag)
        #expect(itags.contains(140))
        #expect(itags.contains(251))
        let aac = try #require(response.formats.first { $0.itag == 140 })
        #expect(aac.mimeType == #"audio/mp4; codecs="mp4a.40.2""#)
        #expect(aac.bitrate == 137_064)
        #expect(aac.url == nil)
        #expect(aac.signatureCipher?.hasPrefix("s=") == true)
    }

    @Test("A format with a direct url keeps it and has no cipher")
    func playerDirectURL() throws {
        let json = #"""
        {"playabilityStatus":{"status":"OK"},"streamingData":{"adaptiveFormats":[
          {"itag":141,"mimeType":"audio/mp4; codecs=\"mp4a.40.2\"","bitrate":256000,"url":"https://rr1.googlevideo.com/videoplayback?itag=141"}]}}
        """#
        let response = try InnerTubeParser.playerResponse(from: Data(json.utf8))
        #expect(response.formats.count == 1)
        #expect(response.formats[0].url == "https://rr1.googlevideo.com/videoplayback?itag=141")
        #expect(response.formats[0].signatureCipher == nil)
    }

    @Test("An unplayable response carries the status and YouTube's reason")
    func playerLoginRequired() throws {
        let response = try InnerTubeParser.playerResponse(from: MusicFixtures.data("player-login-required.json"))
        #expect(response.status == "LOGIN_REQUIRED")
        #expect(response.reason == "Sign in to confirm you are not a bot")
        #expect(response.formats.isEmpty)
        #expect(response.playbackTrackingURL == nil)
    }

    @Test("A missing playabilityStatus is reported as UNKNOWN, never a crash")
    func playerMissingStatus() throws {
        let response = try InnerTubeParser.playerResponse(from: Data("{}".utf8))
        #expect(response.status == "UNKNOWN")
        #expect(response.formats.isEmpty)
        #expect(response.expiresInSeconds == nil)
    }

    @Test("Numeric fields may arrive as strings or numbers")
    func playerNumericTolerance() throws {
        let json = #"""
        {"playabilityStatus":{"status":"OK"},"streamingData":{"expiresInSeconds":3600,"adaptiveFormats":[{"itag":"140","mimeType":"audio/mp4","bitrate":"128000","approxDurationMs":"5000"}]},"videoDetails":{"lengthSeconds":"215"}}
        """#
        let response = try InnerTubeParser.playerResponse(from: Data(json.utf8))
        #expect(response.expiresInSeconds == 3600)
        #expect(response.lengthSeconds == 215)
        #expect(response.formats.first?.itag == 140)
        #expect(response.formats.first?.bitrate == 128_000)
    }

    @Test("A format with no itag is dropped")
    func playerDropsFormatWithoutItag() throws {
        let json = #"{"playabilityStatus":{"status":"OK"},"streamingData":{"adaptiveFormats":[{"mimeType":"audio/mp4"},{"itag":140,"mimeType":"audio/mp4"}]}}"#
        #expect(try InnerTubeParser.playerResponse(from: Data(json.utf8)).formats.map(\.itag) == [140])
    }

    @Test("Player garbage throws a parse error")
    func playerInvalidJSON() {
        #expect(throws: MusicError.self) { try InnerTubeParser.playerResponse(from: Data("nope".utf8)) }
    }

    // MARK: - Builders for hand-written search responses

    private static func row(
        videoId: String?,
        title: String,
        subtitleRuns: [(text: String, page: String?)],
        thumbnailWidths: [Int] = [60, 120]
    ) -> [String: Any] {
        func run(_ text: String, _ page: String?) -> [String: Any] {
            guard let page else { return ["text": text] }
            let endpoint: [String: Any] = page == "MUSIC_PAGE_TYPE_ARTIST" || page == "MUSIC_PAGE_TYPE_ALBUM"
                ? ["browseEndpoint": ["browseId": "B", "browseEndpointContextSupportedConfigs": ["browseEndpointContextMusicConfig": ["pageType": page]]]]
                : [:]
            return ["text": text, "navigationEndpoint": endpoint]
        }
        var renderer: [String: Any] = [
            "thumbnail": ["musicThumbnailRenderer": ["thumbnail": ["thumbnails": thumbnailWidths.map {
                ["url": "https://img.test/\($0)", "width": $0, "height": $0] as [String: Any]
            }]]],
            "flexColumns": [
                ["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": [["text": title]]]]],
                ["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": subtitleRuns.map { run($0.text, $0.page) }]]],
            ],
        ]
        if let videoId { renderer["playlistItemData"] = ["videoId": videoId] }
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
}
