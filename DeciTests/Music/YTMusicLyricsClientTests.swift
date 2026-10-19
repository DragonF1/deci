// DeciTests/Music/YTMusicLyricsClientTests.swift
// The YouTube Music lyrics client against a scripted music.youtube.com: the /next tab lookup, the request shapes,
// timed and plain parsing, the credit text, failures and the 60 s pause after a 429. Made-up responses only.

import Foundation
import os
import Testing
@testable import Deci

@Suite("YouTube Music lyrics client")
struct YTMusicLyricsClientTests {

    private static let webVersion = InnerTubeClient.fallbackClientVersion
    private static let safariUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
    private static let androidUserAgent = "com.google.android.apps.youtube.music/7.21.50 (Linux; U; Android 14) gzip"

    private struct Rig {
        let client: YTMusicLyricsClient
        let transport: FakeYTMusic
        let clock: MutableClock
    }

    private func makeRig(_ transport: FakeYTMusic = FakeYTMusic(), clock: MutableClock = MutableClock()) -> Rig {
        Rig(client: YTMusicLyricsClient(transport: transport, now: { clock.now }), transport: transport, clock: clock)
    }

    private func answer(_ rig: Rig, duration: TimeInterval? = 200) async throws -> LyricsAnswer {
        try await rig.client.answer(for: YTSamples.query(duration: duration))
    }

    /// The four sung lines of `YTSamples.fourCues` and the gap after the last cue.
    private static let fourLines = [
        LyricLine(time: 1, text: "Line one"),
        LyricLine(time: 3, text: "Line two"),
        LyricLine(time: 5, text: "Line three"),
        LyricLine(time: 7, text: "Line four"),
        LyricLine(time: 9, text: ""),
    ]

    // MARK: - /next

    @Test("The lyrics tab is the one whose browse id starts with MPLYt, and that id is browsed")
    func findsTheTab() async throws {
        let rig = makeRig(FakeYTMusic(android: [.ok(YTSamples.timedBrowse(YTSamples.fourCues))]))
        let result = try await answer(rig)
        #expect(result.result == .synced(Self.fourLines))
        let browse = try #require(rig.transport.androidRequests.first)
        #expect(FakeYTMusic.body(browse)["browseId"] as? String == YTSamples.browseId)
    }

    @Test("The tab's title does not matter, only its browse id")
    func titleIsIgnored() async throws {
        let rig = makeRig(FakeYTMusic(
            next: [.ok(YTSamples.next(title: "Something else"))],
            android: [.ok(YTSamples.timedBrowse(YTSamples.fourCues))]
        ))
        #expect(try await answer(rig).result == .synced(Self.fourLines))
    }

    @Test("An unselectable lyrics tab means no lyrics and no browse request")
    func unselectableTab() async throws {
        let rig = makeRig(FakeYTMusic(next: [.ok(YTSamples.next(unselectable: true))]))
        let result = try await answer(rig)
        #expect(result == LyricsAnswer(result: .notFound, credit: nil, lengthMatters: false))
        #expect(rig.transport.requests.count == 1)
        #expect(rig.transport.androidRequests.isEmpty)
        #expect(rig.transport.webRequests.isEmpty)
    }

    @Test("A song with no lyrics tab means no lyrics and no browse request")
    func noTab() async throws {
        let rig = makeRig(FakeYTMusic(next: [.ok(YTSamples.next(browseId: nil))]))
        #expect(try await answer(rig).result == .notFound)
        #expect(rig.transport.requests.count == 1)
    }

    @Test("A tab with some other browse id is not the lyrics tab")
    func otherBrowseIdPrefix() async throws {
        let rig = makeRig(FakeYTMusic(next: [.ok(YTSamples.next(browseId: "MPREt_other"))]))
        #expect(try await answer(rig).result == .notFound)
        #expect(rig.transport.requests.count == 1)
    }

    @Test("A /next answer that is not JSON is a parse failure")
    func nextGarbage() async {
        let rig = makeRig(FakeYTMusic(next: [.ok(Data("<html>nope</html>".utf8))]))
        await #expect(throws: LyricsError.parse) { try await answer(rig) }
    }

    @Test("A /next answer that is JSON but not an object is a parse failure")
    func nextNotAnObject() async {
        let rig = makeRig(FakeYTMusic(next: [.ok(Data("[1, 2, 3]".utf8))]))
        await #expect(throws: LyricsError.parse) { try await answer(rig) }
    }

    @Test("A /next answer with no tab anywhere is not a song without lyrics: it is a parse failure, never cached",
          arguments: [
              #"{}"#,
              #"{"contents": {}}"#,
              #"{"responseContext": {}, "error": {"code": 400, "message": "made up"}}"#,
              #"{"contents": {"tabbedRenderer": {"tabs": []}}}"#,
              #"{"contents": {"singleColumnMusicWatchNextResultsRenderer": {"tabbedRenderer": {"watchNextTabbedResultsRenderer": {"tabs": [{"renamedRenderer": {"title": "Lyrics"}}]}}}}}"#,
          ])
    func nextWithoutAnyTab(body: String) async {
        let transport = FakeYTMusic(next: [.ok(Data(body.utf8))])
        let rig = makeRig(transport)
        await #expect(throws: LyricsError.parse) { try await answer(rig) }
        #expect(transport.requests.count == 1)
        #expect(await rig.client.busyUntil == nil)
    }

    // MARK: - Request shape

    @Test("/next is a POST of the video id as the web client, with the web client's headers")
    func nextRequestShape() async throws {
        let rig = makeRig()
        _ = try await answer(rig)
        let request = try #require(rig.transport.nextRequests.first)
        #expect(request.method == "POST")
        #expect(request.url.scheme == "https")
        #expect(request.url.host == "music.youtube.com")
        #expect(request.url.path == "/youtubei/v1/next")
        #expect(URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.query == "prettyPrint=false")

        let body = FakeYTMusic.body(request)
        #expect(Set(body.keys) == ["videoId", "isAudioOnly", "context"])
        #expect(body["videoId"] as? String == YTSamples.videoId)
        #expect(body["isAudioOnly"] as? Bool == true)
        let client = FakeYTMusic.client(of: request)
        #expect(client["clientName"] as? String == "WEB_REMIX")
        #expect(client["clientVersion"] as? String == Self.webVersion)
        #expect(client["hl"] as? String == "en")
        #expect(client["gl"] as? String == "US")

        #expect(request.headers["Content-Type"] == "application/json")
        #expect(request.headers["Origin"] == "https://music.youtube.com")
        #expect(request.headers["X-YouTube-Client-Name"] == "67")
        #expect(request.headers["X-YouTube-Client-Version"] == Self.webVersion)
        #expect(request.headers["User-Agent"] == Self.safariUserAgent)
    }

    @Test("The first browse is the Android Music client's, with its user agent and client headers")
    func androidBrowseShape() async throws {
        let rig = makeRig()
        _ = try await answer(rig)
        let request = try #require(rig.transport.androidRequests.first)
        #expect(request.method == "POST")
        #expect(request.url.host == "music.youtube.com")
        #expect(request.url.path == "/youtubei/v1/browse")
        #expect(URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.query == "prettyPrint=false")

        let body = FakeYTMusic.body(request)
        #expect(Set(body.keys) == ["browseId", "context"])
        #expect(body["browseId"] as? String == YTSamples.browseId)
        let client = FakeYTMusic.client(of: request)
        #expect(client["clientName"] as? String == "ANDROID_MUSIC")
        #expect(client["clientVersion"] as? String == "7.21.50")
        #expect(client["hl"] as? String == "en")
        #expect(client["gl"] as? String == "US")

        #expect(request.headers["Content-Type"] == "application/json")
        #expect(request.headers["Origin"] == "https://music.youtube.com")
        #expect(request.headers["X-YouTube-Client-Name"] == "21")
        #expect(request.headers["X-YouTube-Client-Version"] == "7.21.50")
        #expect(request.headers["User-Agent"] == Self.androidUserAgent)
    }

    @Test("The second browse, when the first had no lyrics, is the web client's")
    func webBrowseShape() async throws {
        let rig = makeRig()
        _ = try await answer(rig)
        let request = try #require(rig.transport.webRequests.first)
        #expect(request.method == "POST")
        #expect(request.url.path == "/youtubei/v1/browse")
        #expect(FakeYTMusic.body(request)["browseId"] as? String == YTSamples.browseId)
        let client = FakeYTMusic.client(of: request)
        #expect(client["clientName"] as? String == "WEB_REMIX")
        #expect(client["clientVersion"] as? String == Self.webVersion)
        #expect(request.headers["X-YouTube-Client-Name"] == "67")
        #expect(request.headers["X-YouTube-Client-Version"] == Self.webVersion)
        #expect(request.headers["User-Agent"] == Self.safariUserAgent)
        #expect(request.headers["Origin"] == "https://music.youtube.com")
    }

    @Test("A song that has timed lyrics costs two requests, /next and one browse")
    func timedCostsTwoRequests() async throws {
        let rig = makeRig(FakeYTMusic(android: [.ok(YTSamples.timedBrowse(YTSamples.fourCues))]))
        _ = try await answer(rig)
        #expect(rig.transport.requests.count == 2)
        #expect(rig.transport.webRequests.isEmpty)
    }

    @Test("No request ever carries a Cookie or an Authorization header, on any of the three paths")
    func noCredentialsEver() async throws {
        let transports = [
            FakeYTMusic(android: [.ok(YTSamples.timedBrowse(YTSamples.fourCues))]),
            FakeYTMusic(android: [.ok(YTSamples.plainBrowse(YTSamples.plainText))]),
            FakeYTMusic(web: [.ok(YTSamples.plainBrowse(YTSamples.plainText))]),
        ]
        var checked = 0
        for transport in transports {
            _ = try await answer(makeRig(transport))
            for request in transport.requests {
                let names = Set(request.headers.keys.map { $0.lowercased() })
                #expect(names.isDisjoint(with: ["cookie", "authorization", "x-goog-authuser", "x-goog-visitor-id", "x-origin"]))
                #expect(request.url.user == nil)
                checked += 1
            }
        }
        #expect(checked == 2 + 2 + 3)
    }

    @Test("Only the video id leaves the app: not the title, artist, album or length")
    func onlyTheVideoIdIsSent() async throws {
        let rig = makeRig()
        let query = LyricsQuery(
            videoId: YTSamples.videoId, title: "Private Title", artist: "Private Artist", album: "Private Album", duration: 321
        )
        _ = try await rig.client.answer(for: query)
        for request in rig.transport.requests {
            let text = String(decoding: request.body ?? Data(), as: UTF8.self)
            #expect(!text.contains("Private"))
            #expect(!text.contains("321"))
            #expect(!request.url.absoluteString.contains("Private"))
        }
    }

    @Test("The session is ephemeral with no cookies, cache or credentials, and a 10 s timeout")
    func sessionConfiguration() {
        let config = YTMusicLyricsClient.makeConfiguration()
        #expect(config.timeoutIntervalForRequest == 10)
        #expect(config.timeoutIntervalForResource <= 15)
        #expect(config.httpCookieStorage == nil)
        #expect(config.httpShouldSetCookies == false)
        #expect(config.httpCookieAcceptPolicy == .never)
        #expect(config.urlCache == nil)
        #expect(config.urlCredentialStorage == nil)
        #expect(config.requestCachePolicy == .reloadIgnoringLocalCacheData)
        #expect(config.waitsForConnectivity == false)
        #expect(config.identifier == nil)
    }

    @Test("The response cap is 4 MiB")
    func responseCap() {
        #expect(YTMusicLyricsClient.maximumResponseBytes == 4 * 1024 * 1024)
    }

    // MARK: - Timed lyrics

    @Test("Millisecond strings become seconds, and a gap closes the song at the last cue's end")
    func timedParsing() async throws {
        let rig = makeRig(FakeYTMusic(android: [.ok(YTSamples.timedBrowse([
            YTSamples.cue("Line one", "12340", "15000"),
            YTSamples.cue("Line two", "15000", "18500"),
            YTSamples.cue("Line three", "18500", "21250"),
        ]))]))
        let result = try await answer(rig).result
        #expect(result == .synced([
            LyricLine(time: 12.34, text: "Line one"),
            LyricLine(time: 15, text: "Line two"),
            LyricLine(time: 18.5, text: "Line three"),
            LyricLine(time: 21.25, text: ""),
        ]))
    }

    @Test("Cues out of order are sorted by start time, and the gap follows the last one by time")
    func timedSorting() async throws {
        let rig = makeRig(FakeYTMusic(android: [.ok(YTSamples.timedBrowse([
            YTSamples.cue("Line three", "5000", "8000"),
            YTSamples.cue("Line one", "1000", "3000"),
            YTSamples.cue("Line two", "3000", "5000"),
        ]))]))
        #expect(try await answer(rig).result == .synced([
            LyricLine(time: 1, text: "Line one"),
            LyricLine(time: 3, text: "Line two"),
            LyricLine(time: 5, text: "Line three"),
            LyricLine(time: 8, text: ""),
        ]))
    }

    @Test("Cues that share a start time keep the order they came in")
    func timedStableSort() async throws {
        let rig = makeRig(FakeYTMusic(android: [.ok(YTSamples.timedBrowse([
            YTSamples.cue("Line one", "1000", "2000"),
            YTSamples.cue("Line two", "1000", "2000"),
            YTSamples.cue("Line three", "1000", "2000"),
        ]))]))
        guard case .synced(let lines) = try await answer(rig).result else {
            Issue.record("expected synced lyrics")
            return
        }
        #expect(lines.map(\.text) == ["Line one", "Line two", "Line three", ""])
    }

    @Test("Lines with no letters or digits are gaps", arguments: ["\u{266A}", "\u{266A} \u{266A}", "...", "  ", "", "\u{266A}\n"])
    func letterlessLinesAreGaps(_ symbol: String) async throws {
        let rig = makeRig(FakeYTMusic(android: [.ok(YTSamples.timedBrowse([
            YTSamples.cue("Line one", "1000", "2000"),
            YTSamples.cue(symbol, "2000", "3000"),
            YTSamples.cue("Line two", "3000", "4000"),
            YTSamples.cue("Line three", "4000", "5000"),
        ]))]))
        #expect(try await answer(rig).result == .synced([
            LyricLine(time: 1, text: "Line one"),
            LyricLine(time: 2, text: ""),
            LyricLine(time: 3, text: "Line two"),
            LyricLine(time: 4, text: "Line three"),
            LyricLine(time: 5, text: ""),
        ]))
    }

    @Test("A line made of digits is a sung line, not a gap")
    func digitsAreSung() async throws {
        let rig = makeRig(FakeYTMusic(android: [.ok(YTSamples.timedBrowse([
            YTSamples.cue("1, 2, 3", "1000", "2000"),
            YTSamples.cue("Line two", "2000", "3000"),
            YTSamples.cue("Line three", "3000", "4000"),
        ]))]))
        guard case .synced(let lines) = try await answer(rig).result else {
            Issue.record("expected synced lyrics")
            return
        }
        #expect(lines.first == LyricLine(time: 1, text: "1, 2, 3"))
    }

    @Test("Fewer than three sung lines is not timed lyrics")
    func belowTheMinimum() async throws {
        let rig = makeRig(FakeYTMusic(android: [.ok(YTSamples.timedBrowse([
            YTSamples.cue("Line one", "1000", "2000"),
            YTSamples.cue("\u{266A}", "2000", "3000"),
            YTSamples.cue("Line two", "3000", "4000"),
            YTSamples.cue("\u{266A}", "4000", "5000"),
        ]))]))
        #expect(LRCLibClient.minimumLines == 3)
        let result = try await answer(rig)
        #expect(result.result == .notFound)
        // It fell through to the web client's page, which has nothing either.
        #expect(rig.transport.webRequests.count == 1)
    }

    @Test("Exactly three sung lines is enough")
    func atTheMinimum() async throws {
        let rig = makeRig(FakeYTMusic(android: [.ok(YTSamples.timedBrowse([
            YTSamples.cue("Line one", "1000", "2000"),
            YTSamples.cue("\u{266A}", "2000", "3000"),
            YTSamples.cue("Line two", "3000", "4000"),
            YTSamples.cue("Line three", "4000", "5000"),
        ]))]))
        guard case .synced = try await answer(rig).result else {
            Issue.record("expected synced lyrics")
            return
        }
    }

    @Test("A page of nothing but gaps is not timed lyrics")
    func allGaps() async throws {
        let rig = makeRig(FakeYTMusic(android: [.ok(YTSamples.timedBrowse((0..<6).map {
            YTSamples.cue("\u{266A}", "\($0 * 1000)", "\($0 * 1000 + 900)")
        }))]))
        #expect(try await answer(rig).result == .notFound)
    }

    @Test("An empty list of cues is not timed lyrics")
    func noCues() async throws {
        let rig = makeRig(FakeYTMusic(android: [.ok(YTSamples.timedBrowse([]))]))
        #expect(try await answer(rig).result == .notFound)
    }

    @Test("A final gap is not added when the last cue already is one")
    func noDoubleGap() async throws {
        let rig = makeRig(FakeYTMusic(android: [.ok(YTSamples.timedBrowse([
            YTSamples.cue("Line one", "1000", "2000"),
            YTSamples.cue("Line two", "2000", "3000"),
            YTSamples.cue("Line three", "3000", "4000"),
            YTSamples.cue("\u{266A}", "4000", "6000"),
        ]))]))
        guard case .synced(let lines) = try await answer(rig).result else {
            Issue.record("expected synced lyrics")
            return
        }
        #expect(lines.last == LyricLine(time: 4, text: ""))
        #expect(lines.count == 4)
    }

    @Test("A last cue whose end is not after its start adds no final gap")
    func endBeforeStart() async throws {
        let rig = makeRig(FakeYTMusic(android: [.ok(YTSamples.timedBrowse([
            YTSamples.cue("Line one", "1000", "2000"),
            YTSamples.cue("Line two", "2000", "3000"),
            YTSamples.cue("Line three", "3000", "3000"),
        ]))]))
        guard case .synced(let lines) = try await answer(rig).result else {
            Issue.record("expected synced lyrics")
            return
        }
        #expect(lines.map(\.text) == ["Line one", "Line two", "Line three"])
    }

    @Test("Numbers are accepted where the API usually sends strings")
    func numericTimes() async throws {
        let rig = makeRig(FakeYTMusic(android: [.ok(YTSamples.timedBrowse([
            YTSamples.cue("Line one", 1000, 2000),
            YTSamples.cue("Line two", 2000, 3000),
            YTSamples.cue("Line three", 3000, 4000),
        ]))]))
        #expect(try await answer(rig).result == .synced([
            LyricLine(time: 1, text: "Line one"),
            LyricLine(time: 2, text: "Line two"),
            LyricLine(time: 3, text: "Line three"),
            LyricLine(time: 4, text: ""),
        ]))
    }

    @Test("A cue with no usable start time is skipped, the rest are kept")
    func unusableCuesAreSkipped() async throws {
        let rig = makeRig(FakeYTMusic(android: [.ok(YTSamples.timedBrowse([
            YTSamples.cue("Skipped one", "soon", "2000"),
            YTSamples.cue("Line one", "1000", "2000"),
            YTSamples.cue("Skipped two", "-5", "2000"),
            YTSamples.cue("Line two", "2000", "3000"),
            YTSamples.cue("Line three", "3000", "4000"),
        ]))]))
        guard case .synced(let lines) = try await answer(rig).result else {
            Issue.record("expected synced lyrics")
            return
        }
        #expect(lines.map(\.text) == ["Line one", "Line two", "Line three", ""])
    }

    @Test("The lyrics model is found wherever it sits in the page, not at a fixed path")
    func nestedModel() async throws {
        let rig = makeRig(FakeYTMusic(android: [.ok(YTSamples.timedBrowse(YTSamples.fourCues, nested: true))]))
        #expect(try await answer(rig).result == .synced(Self.fourLines))
    }

    @Test("Timed lyrics found only on the web client's page count too")
    func timedOnTheWebPage() async throws {
        let rig = makeRig(FakeYTMusic(web: [.ok(YTSamples.timedBrowse(YTSamples.fourCues))]))
        let result = try await answer(rig)
        #expect(result.result == .synced(Self.fourLines))
        #expect(rig.transport.androidRequests.count == 1)
        #expect(rig.transport.webRequests.count == 1)
    }

    @Test("Timed lyrics win over a description shelf in the same page, and the web page is not asked")
    func timedBeatsPlain() async throws {
        var page = try #require(JSONSerialization.jsonObject(with: YTSamples.timedBrowse(YTSamples.fourCues)) as? [String: Any])
        page["extra"] = [
            "musicDescriptionShelfRenderer": ["description": ["runs": [["text": YTSamples.plainText]]]],
        ]
        let rig = makeRig(FakeYTMusic(android: [.ok(YTSamples.json(page))]))
        #expect(try await answer(rig).result == .synced(Self.fourLines))
        #expect(rig.transport.webRequests.isEmpty)
    }

    // MARK: - Plain lyrics

    @Test("A description shelf in the Android page is plain lyrics, and the web page is not asked")
    func plainFromAndroid() async throws {
        let rig = makeRig(FakeYTMusic(android: [.ok(YTSamples.plainBrowse(YTSamples.plainText))]))
        let result = try await answer(rig)
        #expect(result.result == .plain(YTSamples.plainText))
        #expect(rig.transport.webRequests.isEmpty)
    }

    @Test("With no shelf in the Android page the web client's page is asked, and its shelf is plain lyrics")
    func plainFromWeb() async throws {
        let rig = makeRig(FakeYTMusic(web: [.ok(YTSamples.plainBrowse(YTSamples.plainText))]))
        let result = try await answer(rig)
        #expect(result.result == .plain(YTSamples.plainText))
        #expect(rig.transport.androidRequests.count == 1)
        #expect(rig.transport.webRequests.count == 1)
    }

    @Test("The runs of a shelf are joined as they are, and the text is trimmed")
    func runsAreJoined() async throws {
        let rig = makeRig(FakeYTMusic(android: [.ok(YTSamples.plainBrowse(
            ["\n", "Line one\nLine two\n", "Line three\n"], footer: nil
        ))]))
        #expect(try await answer(rig).result == .plain("Line one\nLine two\nLine three"))
    }

    @Test("Plain text with fewer than three non-empty lines is not lyrics, in either page", arguments: [
        "Line one",
        "Line one\nLine two",
        "Line one\n\n\nLine two\n \n",
        "Line one Line two Line three Line four",
    ])
    func plainBelowTheMinimum(text: String) async throws {
        let android = makeRig(FakeYTMusic(android: [.ok(YTSamples.plainBrowse(text))]))
        #expect(try await answer(android).result == .notFound)
        // It fell through to the web page, which has nothing either.
        #expect(android.transport.webRequests.count == 1)

        let web = makeRig(FakeYTMusic(web: [.ok(YTSamples.plainBrowse(text))]))
        #expect(try await answer(web) == LyricsAnswer(result: .notFound, credit: nil, lengthMatters: false))
    }

    @Test("A short shelf in the Android page does not stop the web page's real lyrics")
    func shortAndroidShelfThenWebLyrics() async throws {
        let rig = makeRig(FakeYTMusic(
            android: [.ok(YTSamples.plainBrowse("Line one\nLine two"))],
            web: [.ok(YTSamples.plainBrowse(YTSamples.plainText, footer: "Source: Other Provider"))]
        ))
        let result = try await answer(rig)
        #expect(result.result == .plain(YTSamples.plainText))
        #expect(result.credit == "Lyrics from Other Provider via YouTube Music")
    }

    @Test("Exactly three non-empty lines are enough, with blank lines between them")
    func plainAtTheMinimum() async throws {
        let rig = makeRig(FakeYTMusic(android: [.ok(YTSamples.plainBrowse("Line one\n\nLine two\n \nLine three"))]))
        #expect(try await answer(rig).result == .plain("Line one\n\nLine two\n \nLine three"))
        #expect(rig.transport.webRequests.isEmpty)
    }

    @Test("A shelf with no text is no lyrics, and the web page is asked next")
    func emptyShelf() async throws {
        let rig = makeRig(FakeYTMusic(android: [.ok(YTSamples.plainBrowse("  \n "))]))
        #expect(try await answer(rig).result == .notFound)
        #expect(rig.transport.webRequests.count == 1)
    }

    @Test("A tab with no lyrics in either page is no lyrics: not an instrumental")
    func nothingInEitherPage() async throws {
        let rig = makeRig()
        let result = try await answer(rig)
        #expect(result == LyricsAnswer(result: .notFound, credit: nil, lengthMatters: false))
        #expect(rig.transport.androidRequests.count == 1)
        #expect(rig.transport.webRequests.count == 1)
    }

    @Test("A browse answer that is not JSON is a parse failure")
    func browseGarbage() async {
        let rig = makeRig(FakeYTMusic(android: [.ok(Data("nope".utf8))]))
        await #expect(throws: LyricsError.parse) { try await answer(rig) }
    }

    // MARK: - Credit

    @Test("The credit names the provider from the page, via YouTube Music")
    func creditFromTimed() async throws {
        let rig = makeRig(FakeYTMusic(android: [.ok(YTSamples.timedBrowse(YTSamples.fourCues))]))
        #expect(try await answer(rig).credit == "Lyrics from Test Provider via YouTube Music")
    }

    @Test("The credit of plain lyrics comes from the shelf's footer")
    func creditFromFooter() async throws {
        let rig = makeRig(FakeYTMusic(web: [.ok(YTSamples.plainBrowse(YTSamples.plainText, footer: "Source: Other Provider"))]))
        #expect(try await answer(rig).credit == "Lyrics from Other Provider via YouTube Music")
    }

    @Test("A footer split over runs is joined")
    func creditFromSplitFooter() async throws {
        let rig = makeRig(FakeYTMusic(android: [.ok(YTSamples.plainBrowse([YTSamples.plainText], footer: ["Source: ", "Test Provider"]))]))
        #expect(try await answer(rig).credit == "Lyrics from Test Provider via YouTube Music")
    }

    @Test("Without a source the credit only names YouTube Music")
    func creditWithoutSource() async throws {
        let timed = makeRig(FakeYTMusic(android: [.ok(YTSamples.timedBrowse(YTSamples.fourCues, source: nil))]))
        #expect(try await answer(timed).credit == "Lyrics from YouTube Music")
        let plain = makeRig(FakeYTMusic(android: [.ok(YTSamples.plainBrowse(YTSamples.plainText, footer: nil))]))
        #expect(try await answer(plain).credit == "Lyrics from YouTube Music")
    }

    @Test("No lyrics, no credit")
    func noCreditWithoutLyrics() async throws {
        #expect(try await answer(makeRig()).credit == nil)
    }

    @Test("The credit text is cleaned: the Source prefix goes, spaces collapse, and a long name is cut")
    func creditText() {
        let ytm = "Lyrics from YouTube Music"
        #expect(YTMusicLyricsClient.credit(forSource: nil) == ytm)
        #expect(YTMusicLyricsClient.credit(forSource: "") == ytm)
        #expect(YTMusicLyricsClient.credit(forSource: "   ") == ytm)
        #expect(YTMusicLyricsClient.credit(forSource: "Source:") == ytm)
        #expect(YTMusicLyricsClient.credit(forSource: "Source:   \n") == ytm)
        #expect(YTMusicLyricsClient.credit(forSource: "Source: Test Provider") == "Lyrics from Test Provider via YouTube Music")
        #expect(YTMusicLyricsClient.credit(forSource: "source: Test Provider") == "Lyrics from Test Provider via YouTube Music")
        #expect(YTMusicLyricsClient.credit(forSource: "SOURCE:Test Provider") == "Lyrics from Test Provider via YouTube Music")
        #expect(YTMusicLyricsClient.credit(forSource: "Test Provider") == "Lyrics from Test Provider via YouTube Music")
        #expect(YTMusicLyricsClient.credit(forSource: "  Source:  Test \n  Provider  ") == "Lyrics from Test Provider via YouTube Music")
        // A name that merely starts with the word is a name.
        #expect(YTMusicLyricsClient.credit(forSource: "Sourcery Lyrics") == "Lyrics from Sourcery Lyrics via YouTube Music")
        // Control and invisible format characters are dropped: a bidi override has no place in a credit line.
        #expect(YTMusicLyricsClient.credit(forSource: "Source: Test\u{202E}Prov\u{0007}ider") == "Lyrics from TestProvider via YouTube Music")
        #expect(YTMusicLyricsClient.credit(forSource: "Source: \u{200B}") == "Lyrics from YouTube Music")

        let long = String(repeating: "a", count: 90)
        #expect(YTMusicLyricsClient.credit(forSource: "Source: \(long)")
            == "Lyrics from \(String(repeating: "a", count: 40)) via YouTube Music")
        #expect(YTMusicLyricsClient.maximumProviderLength == 40)
    }

    @Test("The credit is capped in scalars too: one character built from a pile of combining marks cannot flood it")
    func creditScalarCap() {
        let ytm = "Lyrics from YouTube Music"
        let marks = String(repeating: "\u{0301}", count: 500)

        // A single character with 500 marks on it is not a name: it is dropped, and nothing of it reaches the line.
        #expect(YTMusicLyricsClient.credit(forSource: "Source: e\(marks)") == ytm)

        // Forty plain characters, then a heavy one: the heavy one is left out whole, not cut in half.
        let plain = String(repeating: "a", count: 39)
        #expect(YTMusicLyricsClient.credit(forSource: "Source: \(plain)e\(marks)") == "Lyrics from \(plain) via YouTube Music")

        // Many characters that each carry a few marks stop at the scalar cap, well under the character cap's worst case.
        let accented = String(repeating: "e\u{0301}\u{0302}\u{0303}\u{0304}", count: 40)
        let credit = YTMusicLyricsClient.credit(forSource: "Source: \(accented)")
        let name = credit.dropFirst("Lyrics from ".count).dropLast(" via YouTube Music".count)
        #expect(name.unicodeScalars.count <= YTMusicLyricsClient.maximumProviderScalars)
        #expect(name.unicodeScalars.count == 80)
        #expect(name.count == 16)
        #expect(credit.hasPrefix("Lyrics from ") && credit.hasSuffix(" via YouTube Music"))
        #expect(YTMusicLyricsClient.maximumProviderScalars == 80)
    }

    // MARK: - Failures

    @Test("An HTTP failure on /next or on a browse throws it", arguments: [401, 403, 404, 500, 503])
    func httpFailures(_ status: Int) async {
        let onNext = makeRig(FakeYTMusic(next: [.status(status)]))
        await #expect(throws: LyricsError.http(status)) { try await answer(onNext) }
        // On the Android page the web page is still tried, except after a 5xx, whose pause forbids it. Either way,
        // with nothing found there the Android failure is what is thrown, so it is never read as "no lyrics".
        let onAndroid = makeRig(FakeYTMusic(android: [.status(status)]))
        await #expect(throws: LyricsError.http(status)) { try await answer(onAndroid) }
        #expect(onAndroid.transport.webRequests.count == (status >= 500 ? 0 : 1))
        let onWeb = makeRig(FakeYTMusic(web: [.status(status)]))
        await #expect(throws: LyricsError.http(status)) { try await answer(onWeb) }
    }

    @Test("A failure on the Android page does not stop the web page, whose plain lyrics are used", arguments: [401, 403, 404])
    func androidHttpFailureStillTriesWeb(_ status: Int) async throws {
        let rig = makeRig(FakeYTMusic(
            android: [.status(status)],
            web: [.ok(YTSamples.plainBrowse(YTSamples.plainText, footer: "Source: Other Provider"))]
        ))
        let result = try await answer(rig)
        #expect(result.result == .plain(YTSamples.plainText))
        #expect(result.credit == "Lyrics from Other Provider via YouTube Music")
        #expect(rig.transport.androidRequests.count == 1)
        #expect(rig.transport.webRequests.count == 1)
    }

    @Test("An Android page that is not JSON does not stop the web page either")
    func androidParseFailureStillTriesWeb() async throws {
        let rig = makeRig(FakeYTMusic(
            android: [.ok(Data("<html>nope</html>".utf8))],
            web: [.ok(YTSamples.timedBrowse(YTSamples.fourCues))]
        ))
        #expect(try await answer(rig).result == .synced(Self.fourLines))
        #expect(rig.transport.webRequests.count == 1)
    }

    @Test("Android failed and the web page has nothing: the Android failure is thrown, so nothing is cached as not found")
    func androidFailureThenNothingThrows() async {
        let http = makeRig(FakeYTMusic(android: [.status(404)]))
        await #expect(throws: LyricsError.http(404)) { try await answer(http) }
        #expect(http.transport.webRequests.count == 1)

        let parse = makeRig(FakeYTMusic(android: [.ok(Data("nope".utf8))]))
        await #expect(throws: LyricsError.parse) { try await answer(parse) }
        #expect(parse.transport.webRequests.count == 1)
    }

    @Test("Once Android has failed the web page is only a second chance: its own failure does not replace the first")
    func webFailureAfterAndroidFailure() async {
        let rig = makeRig(FakeYTMusic(android: [.status(404)], web: [.status(403)]))
        await #expect(throws: LyricsError.http(404)) { try await answer(rig) }
        #expect(rig.transport.webRequests.count == 1)

        let limited = makeRig(FakeYTMusic(android: [.status(404)], web: [.status(429)]))
        await #expect(throws: LyricsError.http(404)) { try await answer(limited) }
        // The web page's 429 still pauses the source.
        #expect(await limited.client.busyUntil == limited.clock.now.addingTimeInterval(60))

        let dropped = makeRig(FakeYTMusic(android: [.status(404)], web: [.fail(.timedOut)]))
        await #expect(throws: LyricsError.http(404)) { try await answer(dropped) }
    }

    @Test("A web page that fails after an Android page with no lyrics is still the failure thrown")
    func webFailureAfterCleanAndroid() async {
        let rig = makeRig(FakeYTMusic(web: [.status(403)]))
        await #expect(throws: LyricsError.http(403)) { try await answer(rig) }
    }

    @Test("An Android failure that is a 5xx or a network error pauses the source, so the web page is not sent", arguments: [
        500, 502, 503, 504,
    ])
    func androidServerErrorPausesBeforeWeb(_ status: Int) async {
        let transport = FakeYTMusic(android: [.status(status)], web: [.ok(YTSamples.plainBrowse(YTSamples.plainText))])
        let rig = makeRig(transport)
        await #expect(throws: LyricsError.http(status)) { try await answer(rig) }
        #expect(transport.webRequests.isEmpty)
        #expect(await rig.client.busyUntil == rig.clock.now.addingTimeInterval(15))

        let network = FakeYTMusic(android: [.fail(.timedOut)], web: [.ok(YTSamples.plainBrowse(YTSamples.plainText))])
        let networkRig = makeRig(network)
        await #expect(throws: URLError.self) { try await answer(networkRig) }
        #expect(network.webRequests.isEmpty)
    }

    @Test("A 429 on the Android page ends the lookup at once, with no web request")
    func androidBusyEndsTheLookup() async {
        let transport = FakeYTMusic(android: [.status(429)], web: [.ok(YTSamples.plainBrowse(YTSamples.plainText))])
        let rig = makeRig(transport)
        await #expect(throws: LyricsError.busy(until: rig.clock.now.addingTimeInterval(60))) { try await answer(rig) }
        #expect(transport.webRequests.isEmpty)
    }

    @Test("A cancellation on the Android page is thrown at once, with no web request")
    func androidCancellationEndsTheLookup() async {
        let transport = FakeYTMusic(android: [.fail(.cancelled)], web: [.ok(YTSamples.plainBrowse(YTSamples.plainText))])
        let rig = makeRig(transport)
        await #expect(throws: CancellationError.self) { try await answer(rig) }
        #expect(transport.webRequests.isEmpty)
        #expect(await rig.client.busyUntil == nil)
    }

    @Test("A network failure is thrown as it is")
    func networkFailure() async {
        let rig = makeRig(FakeYTMusic(next: [.fail(.notConnectedToInternet)]))
        await #expect(throws: URLError.self) { try await answer(rig) }
        let onBrowse = makeRig(FakeYTMusic(android: [.fail(.timedOut)]))
        await #expect(throws: URLError.self) { try await answer(onBrowse) }
    }

    @Test("A request cancelled in flight is a cancellation, not a failure")
    func cancelledRequest() async {
        let rig = makeRig(FakeYTMusic(next: [.fail(.cancelled)]))
        await #expect(throws: CancellationError.self) { try await answer(rig) }
    }

    @Test("A cancelled task stops after the request in flight and sends nothing more")
    func cancellation() async {
        let transport = FakeYTMusic()
        let gate = MusicTestGate()
        transport.setGate(gate)
        let rig = makeRig(transport)
        let task = Task { try await answer(rig) }
        #expect(await eventually { transport.requests.count == 1 })
        task.cancel()
        await gate.open()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(transport.requests.count == 1)
    }

    @Test("A body over the cap is a parse failure")
    func bodyOverTheCap() async {
        let big = Data(repeating: 0x20, count: YTMusicLyricsClient.maximumResponseBytes + 1)
        let onNext = makeRig(FakeYTMusic(next: [.ok(big)]))
        await #expect(throws: LyricsError.parse) { try await answer(onNext) }
        let onBrowse = makeRig(FakeYTMusic(android: [.ok(big)]))
        await #expect(throws: LyricsError.parse) { try await answer(onBrowse) }
    }

    @Test("lyrics(for:) is the answer without the credit")
    func lyricsIsTheAnswersResult() async throws {
        let rig = makeRig(FakeYTMusic(android: [.ok(YTSamples.timedBrowse(YTSamples.fourCues))]))
        #expect(try await rig.client.lyrics(for: YTSamples.query()) == .synced(Self.fourLines))
    }

    @Test("What YouTube Music answers does not depend on the length the player knows")
    func lengthDoesNotMatter() async throws {
        let rig = makeRig(FakeYTMusic(android: [.ok(YTSamples.timedBrowse(YTSamples.fourCues))]))
        #expect(try await answer(rig, duration: nil).lengthMatters == false)
        #expect(try await answer(rig, duration: 200).lengthMatters == false)
    }

    // MARK: - The 60 s pause after a 429

    @Test("A 429 on /next pauses YouTube Music for 60 s: nothing is sent until then")
    func cooldownAfterNext() async throws {
        let transport = FakeYTMusic(next: [.status(429), .ok(YTSamples.next())])
        let rig = makeRig(transport)
        let until = rig.clock.now.addingTimeInterval(60)
        await #expect(throws: LyricsError.busy(until: until)) { try await answer(rig) }
        #expect(transport.requests.count == 1)
        #expect(await rig.client.busyUntil == until)

        rig.clock.advance(by: 59)
        await #expect(throws: LyricsError.busy(until: until)) { try await answer(rig) }
        #expect(transport.requests.count == 1)

        rig.clock.advance(by: 1)
        #expect(await rig.client.busyUntil == nil)
        _ = try await answer(rig)
        #expect(transport.nextRequests.count == 2)
    }

    @Test("A 429 on a browse pauses it too")
    func cooldownAfterBrowse() async throws {
        let transport = FakeYTMusic(android: [.status(429), .ok(YTSamples.timedBrowse(YTSamples.fourCues))])
        let rig = makeRig(transport)
        let until = rig.clock.now.addingTimeInterval(60)
        await #expect(throws: LyricsError.busy(until: until)) { try await answer(rig) }
        #expect(transport.requests.count == 2)
        await #expect(throws: LyricsError.busy(until: until)) { try await answer(rig) }
        #expect(transport.requests.count == 2)

        rig.clock.advance(by: 61)
        #expect(try await answer(rig).result == .synced(Self.fourLines))
    }

    @Test("A 429 on the web client's page pauses it too")
    func cooldownAfterWebBrowse() async throws {
        let transport = FakeYTMusic(web: [.status(429)])
        let rig = makeRig(transport)
        let until = rig.clock.now.addingTimeInterval(60)
        await #expect(throws: LyricsError.busy(until: until)) { try await answer(rig) }
        await #expect(throws: LyricsError.busy(until: until)) { try await answer(rig) }
        #expect(transport.requests.count == 3)
    }

    @Test("The pause is kept in memory only: a new client asks again")
    func cooldownIsNotPersisted() async throws {
        let transport = FakeYTMusic(next: [.status(429), .ok(YTSamples.next(browseId: nil))])
        let first = makeRig(transport)
        await #expect(throws: LyricsError.self) { try await answer(first) }
        let second = makeRig(transport)
        #expect(try await answer(second).result == .notFound)
        #expect(transport.nextRequests.count == 2)
    }

    @Test("A client error or a page that does not parse opens no pause")
    func otherFailuresDoNotPause() async throws {
        let transport = FakeYTMusic(next: [
            .status(400), .status(401), .status(403), .status(404), .ok(Data("<html>nope</html>".utf8)),
            .ok(YTSamples.next(browseId: nil)),
        ])
        let rig = makeRig(transport)
        await #expect(throws: LyricsError.http(400)) { try await answer(rig) }
        await #expect(throws: LyricsError.http(401)) { try await answer(rig) }
        await #expect(throws: LyricsError.http(403)) { try await answer(rig) }
        await #expect(throws: LyricsError.http(404)) { try await answer(rig) }
        await #expect(throws: LyricsError.parse) { try await answer(rig) }
        #expect(await rig.client.busyUntil == nil)
        #expect(try await answer(rig).result == .notFound)
        #expect(transport.nextRequests.count == 6)
    }

    // MARK: - The 15 s pause after a server error or a network failure

    @Test("A 5xx pauses YouTube Music for 15 s: the failure is thrown once, then it is busy and nothing is sent",
          arguments: [500, 502, 503, 504])
    func serverErrorPauses(_ status: Int) async throws {
        let transport = FakeYTMusic(next: [.status(status), .ok(YTSamples.next(browseId: nil))])
        let rig = makeRig(transport)
        let until = rig.clock.now.addingTimeInterval(15)
        await #expect(throws: LyricsError.http(status)) { try await answer(rig) }
        #expect(await rig.client.busyUntil == until)

        rig.clock.advance(by: 14)
        await #expect(throws: LyricsError.busy(until: until)) { try await answer(rig) }
        #expect(transport.requests.count == 1)

        rig.clock.advance(by: 1)
        #expect(await rig.client.busyUntil == nil)
        #expect(try await answer(rig).result == .notFound)
        #expect(transport.nextRequests.count == 2)
    }

    @Test("A timeout or a connection error pauses it for 15 s too", arguments: [
        URLError.Code.timedOut, .notConnectedToInternet, .cannotConnectToHost, .networkConnectionLost,
        .cannotFindHost, .dnsLookupFailed, .secureConnectionFailed,
    ])
    func networkErrorPauses(_ code: URLError.Code) async throws {
        let transport = FakeYTMusic(next: [.fail(code), .ok(YTSamples.next(browseId: nil))])
        let rig = makeRig(transport)
        let until = rig.clock.now.addingTimeInterval(15)
        await #expect(throws: URLError.self) { try await answer(rig) }
        #expect(await rig.client.busyUntil == until)

        await #expect(throws: LyricsError.busy(until: until)) { try await answer(rig) }
        #expect(transport.requests.count == 1)

        rig.clock.advance(by: 15)
        #expect(try await answer(rig).result == .notFound)
    }

    @Test("A hung server costs one wait, not one per track: the next songs fail at once until the pause ends")
    func hungServerIsSkipped() async throws {
        let transport = FakeYTMusic(next: [.fail(.timedOut)])
        let rig = makeRig(transport)
        await #expect(throws: URLError.self) { try await answer(rig) }
        for _ in 0..<3 {
            await #expect(throws: LyricsError.self) { try await answer(rig) }
        }
        #expect(transport.requests.count == 1)
    }

    @Test("A pause from a failure on a browse holds the next /next back too")
    func browseFailurePausesEverything() async throws {
        let transport = FakeYTMusic(android: [.status(502)])
        let rig = makeRig(transport)
        await #expect(throws: LyricsError.http(502)) { try await answer(rig) }
        #expect(transport.requests.count == 2)
        await #expect(throws: LyricsError.busy(until: rig.clock.now.addingTimeInterval(15))) { try await answer(rig) }
        #expect(transport.requests.count == 2)
    }

    @Test("A 429 after a short pause has ended opens the full 60 s pause")
    func rateLimitAfterShortPause() async throws {
        let transport = FakeYTMusic(next: [.status(500), .status(429)])
        let rig = makeRig(transport)
        await #expect(throws: LyricsError.http(500)) { try await answer(rig) }
        rig.clock.advance(by: 15)
        let until = rig.clock.now.addingTimeInterval(60)
        await #expect(throws: LyricsError.busy(until: until)) { try await answer(rig) }
        #expect(await rig.client.busyUntil == until)
    }

    @Test("A cancelled request opens no pause")
    func cancelledOpensNoPause() async {
        let rig = makeRig(FakeYTMusic(next: [.fail(.cancelled)]))
        await #expect(throws: CancellationError.self) { try await answer(rig) }
        #expect(await rig.client.busyUntil == nil)
    }

    @Test("The short pause is kept in memory only: a new client asks again")
    func shortPauseIsNotPersisted() async throws {
        let transport = FakeYTMusic(next: [.status(500), .ok(YTSamples.next(browseId: nil))])
        await #expect(throws: LyricsError.http(500)) { try await answer(makeRig(transport)) }
        #expect(try await answer(makeRig(transport)).result == .notFound)
        #expect(transport.nextRequests.count == 2)
    }

    // MARK: - Redirects

    @Test("A redirect is followed only when it stays on https music.youtube.com", arguments: [
        ("https://music.youtube.com/youtubei/v1/next", true),
        ("https://MUSIC.YouTube.com/other", true),
        ("https://music.youtube.com:443/other", true),
        ("http://music.youtube.com/other", false),
        ("https://www.youtube.com/other", false),
        ("https://youtube.com/other", false),
        ("https://example.test/other", false),
        ("https://music.youtube.com.example.test/other", false),
        ("https://music.youtube.com@example.test/other", false),
        ("https://user@music.youtube.com/other", false),
        ("https://music.youtube.com:8443/other", false),
        ("ftp://music.youtube.com/other", false),
    ] as [(String, Bool)])
    func redirectTargets(url: String, allowed: Bool) throws {
        let request = URLRequest(url: try #require(URL(string: url)))
        let permitted = YTMusicLyricsClient.permittedRedirect(request)
        #expect((permitted != nil) == allowed, "\(url)")
        if allowed { #expect(permitted == request) }
    }

    @Test("A redirect with no usable URL is refused")
    func redirectWithoutURL() {
        #expect(YTMusicLyricsClient.permittedRedirect(URLRequest(url: URL(fileURLWithPath: "/tmp/made-up"))) == nil)
    }

    @Test("The live session's delegate refuses an off-host redirect: the 307 itself becomes the answer, with no body sent on")
    func redirectDelegate() throws {
        let session = URLSession(configuration: YTMusicLyricsClient.makeConfiguration())
        defer { session.invalidateAndCancel() }
        let origin = try #require(URL(string: "https://music.youtube.com/youtubei/v1/next"))
        let task = session.dataTask(with: origin)
        let delegate = YTMusicRedirectGuard()

        for (target, allowed) in [
            ("https://music.youtube.com/elsewhere", true), ("https://example.test/elsewhere", false),
            ("http://music.youtube.com/elsewhere", false),
        ] as [(String, Bool)] {
            let url = try #require(URL(string: target))
            let response = try #require(HTTPURLResponse(
                url: origin, statusCode: 307, httpVersion: nil, headerFields: ["Location": target]
            ))
            var redirected = URLRequest(url: url)
            redirected.httpMethod = "POST"
            redirected.httpBody = Data("made-up body".utf8)
            let seen = OSAllocatedUnfairLock(initialState: (called: false, request: URLRequest?.none))
            delegate.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: redirected) { request in
                seen.withLock { $0 = (true, request) }
            }
            let outcome = seen.withLock { $0 }
            #expect(outcome.called, "\(target) was never answered")
            #expect((outcome.request != nil) == allowed, "\(target)")
        }
    }

    // MARK: - Live

    @Test("live() builds a client")
    func liveBuilds() async {
        let client = YTMusicLyricsClient.live()
        #expect(await client.busyUntil == nil)
    }
}
