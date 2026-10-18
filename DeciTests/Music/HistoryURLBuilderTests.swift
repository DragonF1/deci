// DeciTests/Music/HistoryURLBuilderTests.swift
// The history ping URL: the tracking URL moved to music.youtube.com plus the web client's parameters.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("HistoryURLBuilder")
struct HistoryURLBuilderTests {

    private func build(
        _ url: String,
        kind: HistoryPing.Kind = .playback,
        cpn: String = "AbCd_-0123456789",
        mediaTime: TimeInterval = 30.5,
        version: String = "1.20261013.15.00"
    ) -> URL {
        HistoryURLBuilder.url(
            for: HistoryPing(kind: kind, url: URL(string: url)!, cpn: cpn, mediaTime: mediaTime),
            clientVersion: version
        )
    }

    private func items(_ url: URL) -> [URLQueryItem] {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    }

    private func value(_ name: String, in url: URL) -> String? {
        items(url).first { $0.name == name }?.value
    }

    // MARK: - Parameters

    @Test("The playback ping gets the client parameters and cmt after the existing query, el only when absent")
    func appendsParameters() {
        let url = build("https://s.youtube.com/api/stats/playback?cl=1&docid=abc&ei=E")
        #expect(url.absoluteString == "https://music.youtube.com/api/stats/playback?cl=1&docid=abc&ei=E&ver=2&c=WEB_REMIX&cpn=AbCd_-0123456789&cver=1.20261013.15.00&cmt=30.500&el=detailpage")
    }

    @Test("A URL with no query gets just the client parameters")
    func noExistingQuery() {
        let url = build("https://s.youtube.com/api/stats/playback")
        #expect(url.absoluteString == "https://music.youtube.com/api/stats/playback?ver=2&c=WEB_REMIX&cpn=AbCd_-0123456789&cver=1.20261013.15.00&cmt=30.500&el=detailpage")
    }

    @Test("Existing percent-encoded values are preserved byte for byte")
    func preservesEncoding() {
        let url = build("https://s.youtube.com/api/stats/playback?fexp=1%2C2%2C3&plid=A%3D%3D")
        #expect(url.absoluteString.contains("fexp=1%2C2%2C3&plid=A%3D%3D&ver=2"))
    }

    @Test("A parameter that is already present is replaced, not repeated")
    func replacesDuplicates() {
        let url = build("https://s.youtube.com/api/stats/playback?ver=1&cpn=OLD&c=WEB&cver=0&cmt=9&docid=abc")
        for name in ["ver", "c", "cpn", "cver", "cmt"] {
            #expect(items(url).filter { $0.name == name }.count == 1, "\(name) repeated")
        }
        #expect(value("ver", in: url) == "2")
        #expect(value("cpn", in: url) == "AbCd_-0123456789")
        #expect(value("cmt", in: url) == "30.500")
        #expect(value("docid", in: url) == "abc")
    }

    @Test("The cpn alphabet (dash and underscore) survives")
    func cpnAlphabet() {
        #expect(build("https://s.youtube.com/a?x=1", cpn: "-_-_-_-_-_-_-_-_").absoluteString.contains("cpn=-_-_-_-_-_-_-_-_"))
    }

    @Test("Characters outside the cpn alphabet are encoded, not injected")
    func cpnInjection() {
        let url = build("https://s.youtube.com/a?x=1", cpn: "a&b=c#d")
        #expect(value("cpn", in: url) == "a&b=c#d")
        #expect(items(url).first { $0.name == "b" } == nil)
    }

    // MARK: - Host

    @Test("The s.youtube.com host moves to music.youtube.com; scheme, path and query stay")
    func hostRewriteFromS() {
        let url = build("https://s.youtube.com/api/stats/playback?docid=abc")
        #expect(url.scheme == "https")
        #expect(url.host == "music.youtube.com")
        #expect(url.path == "/api/stats/playback")
        #expect(value("docid", in: url) == "abc")
    }

    @Test("The www.youtube.com host moves to music.youtube.com too")
    func hostRewriteFromWWW() {
        let url = build("https://www.youtube.com/api/stats/watchtime?docid=abc", kind: .watchtime)
        #expect(url.host == "music.youtube.com")
        #expect(url.path == "/api/stats/watchtime")
        #expect(value("docid", in: url) == "abc")
    }

    @Test("The host match ignores case")
    func hostRewriteIgnoresCase() {
        #expect(build("https://S.YouTube.com/api/stats/playback?x=1").host == "music.youtube.com")
    }

    @Test("A music.youtube.com tracking URL keeps its host")
    func hostAlreadyMusic() {
        #expect(build("https://music.youtube.com/api/stats/playback?x=1").host == "music.youtube.com")
    }

    @Test("Hosts other than s. and www. are left alone")
    func otherHostsUntouched() {
        #expect(build("https://m.youtube.com/api/stats/playback?x=1").host == "m.youtube.com")
        #expect(build("https://example.com/api/stats/playback?x=1").host == "example.com")
    }

    // MARK: - el

    @Test("el=detailpage is added when the base URL has no el")
    func elAddedWhenAbsent() {
        let url = build("https://s.youtube.com/api/stats/playback?docid=abc")
        #expect(items(url).filter { $0.name == "el" }.map(\.value) == ["detailpage"])
    }

    @Test("An el already in the base URL is kept as it is, never doubled")
    func elKeptWhenPresent() {
        for kind in [HistoryPing.Kind.playback, .watchtime] {
            let url = build("https://s.youtube.com/api/stats/playback?el=music&docid=abc", kind: kind)
            #expect(items(url).filter { $0.name == "el" }.map(\.value) == ["music"], "\(kind)")
        }
    }

    // MARK: - Media time and watchtime

    @Test("cmt carries the media time in seconds with three decimals")
    func cmtFormat() {
        #expect(value("cmt", in: build("https://s.youtube.com/a?x=1", mediaTime: 30)) == "30.000")
        #expect(value("cmt", in: build("https://s.youtube.com/a?x=1", mediaTime: 123.45678)) == "123.457")
        #expect(value("cmt", in: build("https://s.youtube.com/a?x=1", mediaTime: 0)) == "0.000")
    }

    @Test("A negative or non-finite media time is sent as zero")
    func cmtClamped() {
        for time in [-5, .nan, .infinity, -.infinity] as [TimeInterval] {
            let url = build("https://s.youtube.com/a?x=1", kind: .watchtime, mediaTime: time)
            #expect(value("cmt", in: url) == "0.000", "\(time)")
            #expect(value("et", in: url) == "0.000", "\(time)")
        }
    }

    @Test("The playback ping has no st or et")
    func playbackHasNoWatchtimeParameters() {
        let url = build("https://s.youtube.com/api/stats/playback?docid=abc")
        #expect(value("st", in: url) == nil)
        #expect(value("et", in: url) == nil)
    }

    @Test("The watchtime ping adds st=0 and et=<media time> to the same parameters")
    func watchtimeParameters() {
        let url = build("https://s.youtube.com/api/stats/watchtime?cl=1&docid=abc", kind: .watchtime, mediaTime: 31.25)
        #expect(url.absoluteString == "https://music.youtube.com/api/stats/watchtime?cl=1&docid=abc&ver=2&c=WEB_REMIX&cpn=AbCd_-0123456789&cver=1.20261013.15.00&cmt=31.250&st=0&et=31.250&el=detailpage")
    }

    @Test("A st or et already in the watchtime URL is replaced, not repeated")
    func watchtimeReplacesDuplicates() {
        let url = build("https://s.youtube.com/api/stats/watchtime?st=7&et=9&cmt=3", kind: .watchtime, mediaTime: 30)
        for name in ["st", "et", "cmt"] {
            #expect(items(url).filter { $0.name == name }.count == 1, "\(name) repeated")
        }
        #expect(value("st", in: url) == "0")
        #expect(value("et", in: url) == "30.000")
        #expect(value("cmt", in: url) == "30.000")
    }

    @Test("Both pings of one session carry the same cpn when given the same one")
    func sameCPNAcrossKinds() {
        let playback = build("https://s.youtube.com/api/stats/playback?docid=abc", kind: .playback, cpn: "SameCpn_SameCpn_")
        let watchtime = build("https://s.youtube.com/api/stats/watchtime?docid=abc", kind: .watchtime, cpn: "SameCpn_SameCpn_")
        #expect(value("cpn", in: playback) == "SameCpn_SameCpn_")
        #expect(value("cpn", in: watchtime) == "SameCpn_SameCpn_")
    }

    // MARK: - Watchtime details

    private func details(
        _ segments: [WatchtimeSegment] = [WatchtimeSegment(start: 0, end: 30, volume: 100, muted: false)],
        realTime: TimeInterval = 30,
        next: TimeInterval? = 70,
        scheduled: TimeInterval? = nil,
        idle: Int = 1234,
        playing: Bool = true,
        final: Bool = false
    ) -> WatchtimeDetails {
        WatchtimeDetails(
            segments: segments,
            realTime: realTime,
            nextRealTime: next,
            scheduledRealTime: scheduled,
            idleMilliseconds: idle,
            isPlaying: playing,
            isFinal: final
        )
    }

    private func buildWatchtime(
        _ base: String = "https://s.youtube.com/api/stats/watchtime?cl=1&docid=abc&len=370",
        details: WatchtimeDetails,
        kind: HistoryPing.Kind = .watchtime,
        mediaTime: TimeInterval = 30.5
    ) -> URL {
        HistoryURLBuilder.url(
            for: HistoryPing(kind: kind, url: URL(string: base)!, cpn: "AbCd_-0123456789", mediaTime: mediaTime, details: details),
            clientVersion: "1.20261013.15.00"
        )
    }

    @Test("A watchtime ping with details carries the web player's own parameters after the base query")
    func detailsParameters() {
        let url = buildWatchtime(details: details())
        #expect(url.absoluteString == "https://music.youtube.com/api/stats/watchtime?cl=1&docid=abc&len=370&ver=2&c=WEB_REMIX&cpn=AbCd_-0123456789&cver=1.20261013.15.00&cmt=30.500&st=0.000&et=30.000&rt=30.000&rtn=70.000&lact=1234&state=playing&volume=100&muted=0&el=detailpage")
    }

    @Test("Several stretches ride as comma lists, with the comma percent-encoded, one entry per stretch")
    func detailsSegmentLists() {
        let url = buildWatchtime(details: details([
            WatchtimeSegment(start: 30, end: 50, volume: 100, muted: false),
            WatchtimeSegment(start: 200, end: 220.1234, volume: 50, muted: true),
        ]))
        #expect(url.absoluteString.contains("&st=30.000%2C200.000&et=50.000%2C220.123&"))
        #expect(url.absoluteString.contains("&volume=100%2C50&muted=0%2C1"))
        #expect(value("st", in: url) == "30.000,200.000")
        #expect(value("muted", in: url) == "0,1")
    }

    @Test("A scheduled ping names the time it was due (rti) as well as the next one (rtn)")
    func detailsScheduledTimes() {
        let url = buildWatchtime(details: details(realTime: 70.5, next: 110, scheduled: 70))
        #expect(value("rt", in: url) == "70.500")
        #expect(value("rtn", in: url) == "110.000")
        #expect(value("rti", in: url) == "70.000")
    }

    @Test("rtn and rti are left out when there is nothing to say")
    func detailsOmitsAbsentTimes() {
        let url = buildWatchtime(details: details(next: nil, scheduled: nil))
        #expect(value("rtn", in: url) == nil)
        #expect(value("rti", in: url) == nil)
    }

    @Test("state says paused for a flush and the final ping, and final=1 appears only on the final one")
    func detailsStateAndFinal() {
        let playing = buildWatchtime(details: details())
        #expect(value("state", in: playing) == "playing")
        #expect(value("final", in: playing) == nil)

        let paused = buildWatchtime(details: details(next: nil, playing: false))
        #expect(value("state", in: paused) == "paused")
        #expect(value("final", in: paused) == nil)

        let final = buildWatchtime(details: details(next: nil, playing: false, final: true))
        #expect(value("state", in: final) == "paused")
        #expect(value("final", in: final) == "1")
        #expect(items(final).filter { $0.name == "final" }.count == 1)
    }

    @Test("lact is whole milliseconds and never negative")
    func detailsIdle() {
        #expect(value("lact", in: buildWatchtime(details: details(idle: 0))) == "0")
        #expect(value("lact", in: buildWatchtime(details: details(idle: -50))) == "0")
        #expect(value("lact", in: buildWatchtime(details: details(idle: 86_400_000))) == "86400000")
    }

    @Test("Nothing the base URL already has is repeated, and what it has stays as it was")
    func detailsDoNotDuplicate() {
        let url = buildWatchtime(
            "https://s.youtube.com/api/stats/watchtime?cl=1&docid=abc&len=370&ns=yt&fexp=1%2C2&el=detailpage",
            details: details(next: nil, scheduled: 70, final: true)
        )
        let names = items(url).map(\.name)
        #expect(names.count == Set(names).count, "\(names)")
        #expect(url.absoluteString.hasPrefix("https://music.youtube.com/api/stats/watchtime?cl=1&docid=abc&len=370&ns=yt&fexp=1%2C2&el=detailpage&ver=2"))
    }

    @Test("A st, et, rt, state or final already in the base URL gives way to the ping's own")
    func detailsReplaceBaseDuplicates() {
        let url = buildWatchtime(
            "https://s.youtube.com/api/stats/watchtime?st=7&et=9&rt=1&rtn=2&rti=3&lact=4&state=x&volume=5&muted=6&final=7&cmt=8",
            details: details()
        )
        let names = items(url).map(\.name)
        #expect(names.count == Set(names).count, "\(names)")
        #expect(value("st", in: url) == "0.000")
        #expect(value("state", in: url) == "playing")
        #expect(value("final", in: url) == nil)
        #expect(value("rti", in: url) == nil)
    }

    @Test("A negative or non-finite real time is sent as zero")
    func detailsRealTimeClamped() {
        for time in [-5, .nan, .infinity] as [TimeInterval] {
            #expect(value("rt", in: buildWatchtime(details: details(realTime: time))) == "0.000", "\(time)")
        }
    }

    @Test("Details with no stretch fall back to the one-stretch ping rather than an empty list")
    func detailsWithoutSegments() {
        let url = buildWatchtime(details: details([]), mediaTime: 12)
        #expect(value("st", in: url) == "0.000")
        #expect(value("et", in: url) == "12.000")
    }

    @Test("A playback ping never takes the watchtime details")
    func playbackIgnoresDetails() {
        let url = buildWatchtime("https://s.youtube.com/api/stats/playback?docid=abc", details: details(final: true), kind: .playback)
        for name in ["st", "et", "rt", "rtn", "rti", "lact", "state", "volume", "muted", "final"] {
            #expect(value(name, in: url) == nil, "\(name)")
        }
        #expect(value("cmt", in: url) == "30.500")
    }

    // MARK: - Fixture

    @Test("The fixture tracking URLs keep their docid and gain the parameters")
    func fixtureTrackingURLs() throws {
        let response = try InnerTubeParser.playerResponse(from: MusicFixtures.data("player-ok.json"))
        let tracking = try #require(response.playbackTrackingURL)
        let watchtime = try #require(response.watchtimeTrackingURL)

        let playbackURL = HistoryURLBuilder.url(
            for: HistoryPing(kind: .playback, url: tracking, cpn: "AbCd_-0123456789", mediaTime: 30),
            clientVersion: "1.2"
        )
        #expect(playbackURL.host == "music.youtube.com")
        #expect(playbackURL.path == "/api/stats/playback")
        #expect(value("docid", in: playbackURL) == "4D7u5KF7SP8")
        #expect(value("ver", in: playbackURL) == "2")
        #expect(value("c", in: playbackURL) == "WEB_REMIX")
        #expect(value("cver", in: playbackURL) == "1.2")
        #expect(value("cmt", in: playbackURL) == "30.000")
        #expect(items(playbackURL).filter { $0.name == "el" }.count == 1)

        let watchtimeURL = HistoryURLBuilder.url(
            for: HistoryPing(kind: .watchtime, url: watchtime, cpn: "AbCd_-0123456789", mediaTime: 30),
            clientVersion: "1.2"
        )
        #expect(watchtimeURL.host == "music.youtube.com")
        #expect(watchtimeURL.path == "/api/stats/watchtime")
        #expect(value("docid", in: watchtimeURL) == "4D7u5KF7SP8")
        #expect(value("st", in: watchtimeURL) == "0")
        #expect(value("et", in: watchtimeURL) == "30.000")
    }
}
