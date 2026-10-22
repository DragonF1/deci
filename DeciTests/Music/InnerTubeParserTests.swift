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

    @Test("DATASYNC_ID tells a brand channel from the account's own channel")
    func bootstrapChannelIdentity() {
        #expect(InnerTubeParser.isBrandChannel(dataSyncId: "brand123||user456") == true)
        #expect(InnerTubeParser.isBrandChannel(dataSyncId: "user456||") == false)
        #expect(InnerTubeParser.isBrandChannel(dataSyncId: "user456") == nil)
        #expect(InnerTubeParser.isBrandChannel(dataSyncId: "||user456") == nil)
        #expect(InnerTubeParser.isBrandChannel(dataSyncId: "") == nil)

        let html = #"""
        ytcfg.set({"INNERTUBE_CLIENT_VERSION":"4.4","DATASYNC_ID":"brand123||user456"});
        """#
        #expect(InnerTubeParser.bootstrapConfig(fromHTML: html).isBrandChannel == true)
        #expect(InnerTubeParser.bootstrapConfig(fromHTML: "<html></html>").isBrandChannel == nil)
    }

    @Test("The brand page id is DELEGATED_SESSION_ID, else the brand half of DATASYNC_ID, and nil on the own channel")
    func bootstrapBrandPageId() {
        #expect(InnerTubeParser.brandPageId(delegatedSessionId: "delegated789", dataSyncId: "brand123||user456") == "delegated789")
        #expect(InnerTubeParser.brandPageId(delegatedSessionId: nil, dataSyncId: "brand123||user456") == "brand123")
        #expect(InnerTubeParser.brandPageId(delegatedSessionId: "", dataSyncId: "brand123||user456") == "brand123")
        #expect(InnerTubeParser.brandPageId(delegatedSessionId: nil, dataSyncId: "user456||") == nil)
        #expect(InnerTubeParser.brandPageId(delegatedSessionId: nil, dataSyncId: "user456") == nil)
        #expect(InnerTubeParser.brandPageId(delegatedSessionId: nil, dataSyncId: nil) == nil)

        let brand = #"ytcfg.set({"INNERTUBE_CLIENT_VERSION":"4.4","DATASYNC_ID":"brand123||user456"});"#
        #expect(InnerTubeParser.bootstrapConfig(fromHTML: brand).brandPageId == "brand123")
        let own = #"ytcfg.set({"INNERTUBE_CLIENT_VERSION":"4.4","DATASYNC_ID":"user456||"});"#
        #expect(InnerTubeParser.bootstrapConfig(fromHTML: own).brandPageId == nil)
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
        #expect(response.watchtimeTrackingURL?.host == "s.youtube.com")
        #expect(response.watchtimeTrackingURL?.path == "/api/stats/watchtime")
        let itags = response.formats.map(\.itag)
        #expect(itags.contains(140))
        #expect(itags.contains(251))
        let aac = try #require(response.formats.first { $0.itag == 140 })
        #expect(aac.mimeType == #"audio/mp4; codecs="mp4a.40.2""#)
        #expect(aac.bitrate == 137_064)
        #expect(aac.url == nil)
        #expect(aac.signatureCipher?.hasPrefix("s=") == true)
    }

    @Test("The watchtime URL is read independently of the playback URL")
    func playerWatchtimeURL() throws {
        let both = #"""
        {"playabilityStatus":{"status":"OK"},"playbackTracking":{
          "videostatsPlaybackUrl":{"baseUrl":"https://s.youtube.com/api/stats/playback?docid=a"},
          "videostatsWatchtimeUrl":{"baseUrl":"https://s.youtube.com/api/stats/watchtime?docid=a"}}}
        """#
        let response = try InnerTubeParser.playerResponse(from: Data(both.utf8))
        #expect(response.playbackTrackingURL?.absoluteString == "https://s.youtube.com/api/stats/playback?docid=a")
        #expect(response.watchtimeTrackingURL?.absoluteString == "https://s.youtube.com/api/stats/watchtime?docid=a")

        let onlyPlayback = #"""
        {"playabilityStatus":{"status":"OK"},"playbackTracking":{
          "videostatsPlaybackUrl":{"baseUrl":"https://s.youtube.com/api/stats/playback?docid=a"}}}
        """#
        let partial = try InnerTubeParser.playerResponse(from: Data(onlyPlayback.utf8))
        #expect(partial.playbackTrackingURL != nil)
        #expect(partial.watchtimeTrackingURL == nil)

        let onlyWatchtime = #"""
        {"playabilityStatus":{"status":"OK"},"playbackTracking":{
          "videostatsWatchtimeUrl":{"baseUrl":"https://s.youtube.com/api/stats/watchtime?docid=a"}}}
        """#
        let other = try InnerTubeParser.playerResponse(from: Data(onlyWatchtime.utf8))
        #expect(other.playbackTrackingURL == nil)
        #expect(other.watchtimeTrackingURL != nil)
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
        #expect(response.watchtimeTrackingURL == nil)
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

    @Test("The view count is read from videoDetails, as the string YouTube sends")
    func playerViewCount() throws {
        let json = #"{"playabilityStatus":{"status":"OK"},"videoDetails":{"lengthSeconds":"215","viewCount":"1234567"}}"#
        #expect(try InnerTubeParser.playerResponse(from: Data(json.utf8)).viewCount == 1_234_567)

        let number = #"{"playabilityStatus":{"status":"OK"},"videoDetails":{"viewCount":42}}"#
        #expect(try InnerTubeParser.playerResponse(from: Data(number.utf8)).viewCount == 42)
    }

    @Test("A missing or unreadable view count is nil, never a failure")
    func playerViewCountMissing() throws {
        let missing = #"{"playabilityStatus":{"status":"OK"},"videoDetails":{"lengthSeconds":"215"}}"#
        #expect(try InnerTubeParser.playerResponse(from: Data(missing.utf8)).viewCount == nil)

        let noDetails = #"{"playabilityStatus":{"status":"OK"}}"#
        #expect(try InnerTubeParser.playerResponse(from: Data(noDetails.utf8)).viewCount == nil)

        for bad in [#""viewCount":"many""#, #""viewCount":"""#, #""viewCount":null"#, #""viewCount":true"#, #""viewCount":{"n":1}"#] {
            let json = #"{"playabilityStatus":{"status":"OK"},"videoDetails":{\#(bad)}}"#
            #expect(try InnerTubeParser.playerResponse(from: Data(json.utf8)).viewCount == nil)
        }
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

    // MARK: - Radio queue

    @Test("The first radio page fixture parses in order, seed first, with its continuation")
    func radioFirstPageFixture() throws {
        let page = try InnerTubeParser.radioPage(from: MusicFixtures.data("next-radio-first.json"))
        #expect(page.tracks.map(\.videoId) == ["4D7u5KF7SP8", "wU26xVT_vBU", "dJqxQzxLbHM", "tOaWhRATZqk"])
        #expect(page.continuation == "SCRUBBED_RADIO_CONTINUATION_2")

        let seed = try #require(page.tracks.first)
        #expect(seed.title == "Get Lucky (feat. Pharrell Williams and Nile Rodgers)")
        #expect(seed.artist == "Daft Punk, Pharrell Williams, Nile Rodgers")
        #expect(seed.album == "Random Access Memories")
        #expect(seed.durationSeconds == 370)
        #expect(seed.thumbnailURL?.absoluteString.hasSuffix("=w544-h544-l90-rj") == true)
    }

    @Test("Artists split on the first bullet; an ampersand pair and a single artist both read cleanly")
    func radioArtistsAndAlbums() throws {
        let tracks = try InnerTubeParser.radioPage(from: MusicFixtures.data("next-radio-first.json")).tracks
        #expect(tracks[1].artist == "Daft Punk")
        #expect(tracks[1].album == "One More Time")
        #expect(tracks[1].durationSeconds == 321)
        #expect(tracks[3].artist == "j-hope, Nile Rodgers")
        #expect(tracks[3].album == "HOPE ON THE STREET VOL.1")
    }

    @Test("The continuation page fixture parses with its next token")
    func radioContinuationFixture() throws {
        let page = try InnerTubeParser.radioContinuationPage(from: MusicFixtures.data("next-radio-continuation.json"))
        #expect(page.tracks.map(\.videoId) == ["noiy7ajORtA", "vP709vKwkD0", "JWxoRY7AFSw", "2pzs39z2VMk"])
        #expect(page.continuation == "SCRUBBED_RADIO_CONTINUATION_3")
        #expect(page.tracks[0].artist == "Two Door Cinema Club")
        #expect(page.tracks[0].album == "Tourist History")
        #expect(page.tracks[0].durationSeconds == 192)
    }

    @Test("Four credited artists stay in order and the album run is still found")
    func radioManyArtists() throws {
        let page = try InnerTubeParser.radioContinuationPage(from: MusicFixtures.data("next-radio-continuation.json"))
        let track = try #require(page.tracks.first { $0.videoId == "JWxoRY7AFSw" })
        #expect(track.artist == "Justice, Tame Impala, SZA, Grand Theft Auto VI")
        #expect(track.album?.hasPrefix("Flower In A Hurricane") == true)
        #expect(track.durationSeconds == 225)
    }

    @Test("An uploaded video has no album, and its views and likes never become one")
    func radioVideoRowHasNoAlbum() throws {
        let page = try InnerTubeParser.radioContinuationPage(from: MusicFixtures.data("next-radio-continuation.json"))
        let video = try #require(page.tracks.first { $0.videoId == "2pzs39z2VMk" })
        #expect(video.artist == "Example Uploader")
        #expect(video.album == nil)
        #expect(video.durationSeconds == 403)
        #expect(video.thumbnailURL?.absoluteString.hasSuffix("Qjl1cK1GNzlhmoYnJOZ4wIRQ") == true)
    }

    @Test("A wrapper item contributes its primary renderer and never the counterpart")
    func radioWrapperItem() throws {
        let wrapper: [String: Any] = ["playlistPanelVideoWrapperRenderer": [
            "primaryRenderer": Self.panelItem(videoId: "audio", title: "Song"),
            "counterpart": [["counterpartRenderer": Self.panelItem(videoId: "video", title: "Song (Official Video)")]],
        ]]
        let json = Self.radioFirstPageJSON(items: [Self.panelItem(videoId: "a", title: "A"), wrapper, Self.panelItem(videoId: "b", title: "B")])
        let page = try InnerTubeParser.radioPage(from: json)
        #expect(page.tracks.map(\.videoId) == ["a", "audio", "b"])
        #expect(page.tracks[1].title == "Song")
    }

    @Test("Automix previews, unknown renderers and items without a video id are skipped")
    func radioSkipsOtherItems() throws {
        let items: [[String: Any]] = [
            Self.panelItem(videoId: "a", title: "A"),
            ["automixPreviewVideoRenderer": ["content": ["automixPlaylistVideoRenderer": ["navigationEndpoint": ["watchPlaylistEndpoint": ["playlistId": "RDAMPLx"]]]]]],
            ["somethingNew": ["videoId": "ghost", "title": ["runs": [["text": "Ghost"]]]]],
            Self.panelItem(videoId: nil, title: "No id"),
            ["playlistPanelVideoWrapperRenderer": ["primaryRenderer": [:]]],
            Self.panelItem(videoId: "b", title: "B"),
        ]
        let page = try InnerTubeParser.radioPage(from: Self.radioFirstPageJSON(items: items))
        #expect(page.tracks.map(\.videoId) == ["a", "b"])
    }

    @Test("A row with an empty title is skipped")
    func radioSkipsEmptyTitle() throws {
        let items = [Self.panelItem(videoId: "a", title: ""), Self.panelItem(videoId: "b", title: "B")]
        #expect(try InnerTubeParser.radioPage(from: Self.radioFirstPageJSON(items: items)).tracks.map(\.videoId) == ["b"])
    }

    @Test("The video id falls back to the watch endpoint")
    func radioVideoIdFromWatchEndpoint() throws {
        var renderer = Self.panelRenderer(videoId: nil, title: "Via endpoint")
        renderer["navigationEndpoint"] = ["watchEndpoint": ["videoId": "fromEndpoint"]]
        let json = Self.radioFirstPageJSON(items: [["playlistPanelVideoRenderer": renderer]])
        #expect(try InnerTubeParser.radioPage(from: json).tracks.map(\.videoId) == ["fromEndpoint"])
    }

    @Test("Durations read as m:ss and h:mm:ss; anything else, or nothing, is nil")
    func radioDurations() throws {
        let lengths: [String?] = ["3:45", "1:02:03", "0:59", "10:00", nil, "LIVE", "", "1:2"]
        let items = lengths.enumerated().map { index, length in Self.panelItem(videoId: "v\(index)", title: "T", length: length) }
        let tracks = try InnerTubeParser.radioPage(from: Self.radioFirstPageJSON(items: items)).tracks
        #expect(tracks.map(\.durationSeconds) == [225, 3723, 59, 600, nil, nil, nil, nil])
    }

    @Test("The largest thumbnail wins, and none gives nil")
    func radioThumbnailPick() throws {
        let sizes: [[Int]] = [[60, 120, 544, 226], [400, 853], [], [120]]
        let items = sizes.enumerated().map { index, widths in Self.panelItem(videoId: "v\(index)", title: "T", thumbnailWidths: widths) }
        let tracks = try InnerTubeParser.radioPage(from: Self.radioFirstPageJSON(items: items)).tracks
        #expect(tracks[0].thumbnailURL?.absoluteString == "https://img.test/544")
        #expect(tracks[1].thumbnailURL?.absoluteString == "https://img.test/853")
        #expect(tracks[2].thumbnailURL == nil)
        #expect(tracks[3].thumbnailURL?.absoluteString == "https://img.test/120")
    }

    @Test("A byline with only an artist, or none at all, still gives a track")
    func radioSparseBylines() throws {
        let alone = Self.panelItem(videoId: "alone", title: "T", byline: [("Solo Artist", "MUSIC_PAGE_TYPE_ARTIST")])
        let missing = Self.panelItem(videoId: "missing", title: "T", byline: nil)
        let tracks = try InnerTubeParser.radioPage(from: Self.radioFirstPageJSON(items: [alone, missing])).tracks
        #expect(tracks[0].artist == "Solo Artist")
        #expect(tracks[0].album == nil)
        #expect(tracks[1].artist == "")
        #expect(tracks[1].album == nil)
    }

    @Test("Order is kept and a repeated track is not dropped")
    func radioKeepsOrderAndDuplicates() throws {
        let items = ["a", "b", "a", "c", "b"].map { Self.panelItem(videoId: $0, title: "T") }
        #expect(try InnerTubeParser.radioPage(from: Self.radioFirstPageJSON(items: items)).tracks.map(\.videoId) == ["a", "b", "a", "c", "b"])
    }

    @Test("Unicode titles survive parsing")
    func radioUnicode() throws {
        let items = [Self.panelItem(videoId: "u1", title: "夜に駆ける 🎵 café", byline: [("YOASOBI", "MUSIC_PAGE_TYPE_ARTIST")])]
        #expect(try InnerTubeParser.radioPage(from: Self.radioFirstPageJSON(items: items)).tracks[0].title == "夜に駆ける 🎵 café")
    }

    @Test("Large queues parse")
    func radioManyItems() throws {
        let items = (0..<2_000).map { Self.panelItem(videoId: "v\($0)", title: "T\($0)") }
        #expect(try InnerTubeParser.radioPage(from: Self.radioFirstPageJSON(items: items)).tracks.count == 2_000)
    }

    @Test("A page with no continuation entry gives a nil continuation")
    func radioMissingContinuation() throws {
        let items = [Self.panelItem(videoId: "a", title: "A")]
        let variants: [[[String: Any]]?] = [nil, [], [["somethingElse": ["x": 1]]]]
        for continuations in variants {
            let first = try InnerTubeParser.radioPage(from: Self.radioFirstPageJSON(items: items, continuations: continuations))
            let next = try InnerTubeParser.radioContinuationPage(from: Self.radioContinuationJSON(items: items, continuations: continuations))
            #expect(first.tracks.count == 1)
            #expect(first.continuation == nil)
            #expect(next.continuation == nil)
        }
    }

    @Test("An empty or non-string continuation token counts as no continuation")
    func radioBlankContinuation() throws {
        let items = [Self.panelItem(videoId: "a", title: "A")]
        for token in ["", 5, NSNull()] as [Any] {
            let continuations: [[String: Any]] = [["nextRadioContinuationData": ["continuation": token]]]
            #expect(try InnerTubeParser.radioPage(from: Self.radioFirstPageJSON(items: items, continuations: continuations)).continuation == nil)
        }
    }

    @Test("nextContinuationData is accepted too, and the first usable entry wins")
    func radioContinuationKinds() throws {
        let items = [Self.panelItem(videoId: "a", title: "A")]
        let plain: [[String: Any]] = [["nextContinuationData": ["continuation": "TOKEN_PLAIN"]]]
        #expect(try InnerTubeParser.radioPage(from: Self.radioFirstPageJSON(items: items, continuations: plain)).continuation == "TOKEN_PLAIN")

        let mixed: [[String: Any]] = [
            ["reloadContinuationData": ["continuation": "RELOAD"]],
            ["nextRadioContinuationData": ["continuation": "TOKEN_RADIO"]],
            ["nextContinuationData": ["continuation": "TOKEN_LATER"]],
        ]
        #expect(try InnerTubeParser.radioContinuationPage(from: Self.radioContinuationJSON(items: items, continuations: mixed)).continuation == "TOKEN_RADIO")
    }

    @Test("A panel with no items is an empty page, not an error")
    func radioEmptyPanel() throws {
        let page = try InnerTubeParser.radioPage(from: Self.radioFirstPageJSON(items: []))
        #expect(page == MusicQueuePage(tracks: [], continuation: nil))
    }

    @Test("A response without the queue panel is a parse error, so a bad seed is not a silent empty radio")
    func radioMissingPanel() {
        let noQueue = #"{"contents":{"singleColumnMusicWatchNextResultsRenderer":{"tabbedRenderer":{"watchNextTabbedResultsRenderer":{"tabs":[{"tabRenderer":{"content":{"musicQueueRenderer":{"hack":true}}}}]}}}}}"#
        for json in [noQueue, "{}", #"{"contents":{}}"#] {
            #expect(throws: MusicError.self) { try InnerTubeParser.radioPage(from: Data(json.utf8)) }
        }
        #expect(throws: MusicError.self) { try InnerTubeParser.radioContinuationPage(from: Data("{}".utf8)) }
        #expect(throws: MusicError.self) { try InnerTubeParser.radioContinuationPage(from: Data(#"{"continuationContents":{}}"#.utf8)) }
    }

    @Test("Each parser only accepts its own page shape, so a rejected token cannot replay the first page")
    func radioPageShapesAreNotInterchangeable() throws {
        let first = try MusicFixtures.data("next-radio-first.json")
        let next = try MusicFixtures.data("next-radio-continuation.json")
        #expect(throws: MusicError.self) { try InnerTubeParser.radioContinuationPage(from: first) }
        #expect(throws: MusicError.self) { try InnerTubeParser.radioPage(from: next) }
    }

    // MARK: - Playlist automix

    private static func previewItem(playlistId: Any? = "RDAMPLPLx", params: Any? = "wAEB8gECeAE%3D") -> [String: Any] {
        var endpoint: [String: Any] = [:]
        if let playlistId { endpoint["playlistId"] = playlistId }
        if let params { endpoint["params"] = params }
        return ["automixPreviewVideoRenderer": ["content": ["automixPlaylistVideoRenderer": ["navigationEndpoint": ["watchPlaylistEndpoint": endpoint]]]]]
    }

    @Test("The playlist fixture's last entry is the automix preview, and its playlist id and params are read")
    func automixEndpointFixture() throws {
        let endpoint = try InnerTubeParser.automixEndpoint(from: MusicFixtures.data("next-playlist-automix.json"))
        #expect(endpoint == MusicAutomixEndpoint(playlistId: "RDAMPLPLhandBuiltAutomix01", params: "wAEB8gECeAE%3D"))
    }

    @Test("The preview row is not a song: the playlist fixture parses as its three songs")
    func automixPreviewIsNotASong() throws {
        let page = try InnerTubeParser.radioPage(from: MusicFixtures.data("next-playlist-automix.json"))
        #expect(page.tracks.map(\.videoId) == ["hbPlSong001", "hbPlSong002", "hbPlSong003"])
        #expect(page.continuation == nil)
    }

    @Test("The params stay exactly as YouTube sent them, percent escapes and all")
    func automixParamsVerbatim() throws {
        let params = ["wAEB8gECeAE%3D", "8gECGAE%3D", "a%2Bb%2Fc%3D%3D", "plain", "wAEB%2BwAEB%25", "has space", "日本語"]
        for value in params {
            let json = Self.radioFirstPageJSON(items: [Self.panelItem(videoId: "a", title: "A"), Self.previewItem(params: value)])
            #expect(try InnerTubeParser.automixEndpoint(from: json)?.params == value, "\(value)")
        }
    }

    @Test("A preview with a playlist id and no params still gives an endpoint, with nil params")
    func automixWithoutParams() throws {
        for params in [nil, "", NSNull(), 5] as [Any?] {
            let json = Self.radioFirstPageJSON(items: [Self.panelItem(videoId: "a", title: "A"), Self.previewItem(params: params)])
            let endpoint = try InnerTubeParser.automixEndpoint(from: json)
            #expect(endpoint == MusicAutomixEndpoint(playlistId: "RDAMPLPLx", params: nil), "\(String(describing: params))")
        }
    }

    @Test("A preview without a usable playlist id gives no endpoint")
    func automixWithoutPlaylistId() throws {
        for playlistId in [nil, "", NSNull(), 5] as [Any?] {
            let json = Self.radioFirstPageJSON(items: [Self.panelItem(videoId: "a", title: "A"), Self.previewItem(playlistId: playlistId)])
            #expect(try InnerTubeParser.automixEndpoint(from: json) == nil, "\(String(describing: playlistId))")
        }
    }

    @Test("A panel with no preview gives no endpoint")
    func automixAbsent() throws {
        let radio = try MusicFixtures.data("next-radio-first.json")
        #expect(try InnerTubeParser.automixEndpoint(from: radio) == nil)
        #expect(try InnerTubeParser.automixEndpoint(from: Self.radioFirstPageJSON(items: [])) == nil)
        #expect(try InnerTubeParser.automixEndpoint(from: Self.radioFirstPageJSON(items: [Self.panelItem(videoId: "a", title: "A")])) == nil)
    }

    @Test("Only the last entry of the panel is the preview: one buried among songs is not read")
    func automixOnlyAtTheEnd() throws {
        let items = [Self.panelItem(videoId: "a", title: "A"), Self.previewItem(), Self.panelItem(videoId: "b", title: "B")]
        #expect(try InnerTubeParser.automixEndpoint(from: Self.radioFirstPageJSON(items: items)) == nil)
    }

    @Test("A preview missing its content, renderer or watch endpoint gives no endpoint")
    func automixBrokenShapes() throws {
        let broken: [[String: Any]] = [
            ["automixPreviewVideoRenderer": [:]],
            ["automixPreviewVideoRenderer": ["content": [:]]],
            ["automixPreviewVideoRenderer": ["content": ["automixPlaylistVideoRenderer": [:]]]],
            ["automixPreviewVideoRenderer": ["content": ["automixPlaylistVideoRenderer": ["navigationEndpoint": [:]]]]],
            ["automixPreviewVideoRenderer": ["content": ["automixPlaylistVideoRenderer": ["navigationEndpoint": ["watchEndpoint": ["videoId": "x", "playlistId": "RDAMPLPLx"]]]]]],
            ["automixPreviewVideoRenderer": "not an object"],
            ["somethingNew": ["content": [:]]],
        ]
        for item in broken {
            let json = Self.radioFirstPageJSON(items: [Self.panelItem(videoId: "a", title: "A"), item])
            #expect(try InnerTubeParser.automixEndpoint(from: json) == nil, "\(item)")
        }
    }

    @Test("The automix's first page parses as an endless queue with its continuation, and has no preview of its own")
    func automixFirstPageFixture() throws {
        let data = try MusicFixtures.data("next-automix-first.json")
        let page = try InnerTubeParser.radioPage(from: data)
        #expect(page.tracks.map(\.videoId) == ["hbPlSong003", "hbAmxSong01", "hbAmxSong02", "hbAmxSong03"])
        #expect(page.continuation == "HANDBUILT_AUTOMIX_CONTINUATION_2")
        #expect(try InnerTubeParser.automixEndpoint(from: data) == nil)
    }

    @Test("A response without the queue panel, or that is not JSON, is a parse error")
    func automixMissingPanel() {
        for json in ["{}", #"{"contents":{}}"#, "<html>", ""] {
            #expect(throws: MusicError.self) { try InnerTubeParser.automixEndpoint(from: Data(json.utf8)) }
        }
    }

    @Test("Radio garbage that is not JSON throws a parse error")
    func radioInvalidJSON() {
        #expect(throws: MusicError.self) { try InnerTubeParser.radioPage(from: Data("<html>".utf8)) }
        #expect(throws: MusicError.self) { try InnerTubeParser.radioPage(from: Data()) }
        #expect(throws: MusicError.self) { try InnerTubeParser.radioContinuationPage(from: Data("nope".utf8)) }
        #expect(throws: MusicError.self) { try InnerTubeParser.radioContinuationPage(from: Data()) }
    }

    // MARK: - Builders for hand-written radio responses

    private static func panelRenderer(
        videoId: String?,
        title: String,
        byline: [(text: String, page: String?)]? = [("A", "MUSIC_PAGE_TYPE_ARTIST")],
        length: String? = "3:45",
        thumbnailWidths: [Int] = [60, 120]
    ) -> [String: Any] {
        var renderer: [String: Any] = [
            "title": ["runs": [["text": title]]],
            "thumbnail": ["thumbnails": thumbnailWidths.map { ["url": "https://img.test/\($0)", "width": $0, "height": $0] as [String: Any] }],
        ]
        if let byline { renderer["longBylineText"] = ["runs": byline.map { run($0.text, $0.page) }] }
        if let length { renderer["lengthText"] = ["runs": [["text": length]]] }
        if let videoId { renderer["videoId"] = videoId }
        return renderer
    }

    private static func panelItem(
        videoId: String?,
        title: String,
        byline: [(text: String, page: String?)]? = [("A", "MUSIC_PAGE_TYPE_ARTIST")],
        length: String? = "3:45",
        thumbnailWidths: [Int] = [60, 120]
    ) -> [String: Any] {
        ["playlistPanelVideoRenderer": panelRenderer(videoId: videoId, title: title, byline: byline, length: length, thumbnailWidths: thumbnailWidths)]
    }

    private static func radioPanel(items: [[String: Any]], continuations: [[String: Any]]?) -> [String: Any] {
        var panel: [String: Any] = ["contents": items]
        if let continuations { panel["continuations"] = continuations }
        return panel
    }

    private static func radioFirstPageJSON(items: [[String: Any]], continuations: [[String: Any]]? = nil) -> Data {
        let root: [String: Any] = [
            "contents": ["singleColumnMusicWatchNextResultsRenderer": ["tabbedRenderer": ["watchNextTabbedResultsRenderer": ["tabs": [
                ["tabRenderer": ["content": ["musicQueueRenderer": ["content": ["playlistPanelRenderer": radioPanel(items: items, continuations: continuations)]]]]],
            ]]]]],
        ]
        return (try? JSONSerialization.data(withJSONObject: root)) ?? Data()
    }

    private static func radioContinuationJSON(items: [[String: Any]], continuations: [[String: Any]]? = nil) -> Data {
        let root: [String: Any] = ["continuationContents": ["playlistPanelContinuation": radioPanel(items: items, continuations: continuations)]]
        return (try? JSONSerialization.data(withJSONObject: root)) ?? Data()
    }

    // MARK: - Builders for hand-written search responses

    private static func run(_ text: String, _ page: String?) -> [String: Any] {
        guard let page else { return ["text": text] }
        let endpoint: [String: Any] = page == "MUSIC_PAGE_TYPE_ARTIST" || page == "MUSIC_PAGE_TYPE_ALBUM"
            ? ["browseEndpoint": ["browseId": "B", "browseEndpointContextSupportedConfigs": ["browseEndpointContextMusicConfig": ["pageType": page]]]]
            : [:]
        return ["text": text, "navigationEndpoint": endpoint]
    }

    private static func row(
        videoId: String?,
        title: String,
        subtitleRuns: [(text: String, page: String?)],
        thumbnailWidths: [Int] = [60, 120]
    ) -> [String: Any] {
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
