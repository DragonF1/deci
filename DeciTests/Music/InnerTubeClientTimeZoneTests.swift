// DeciTests/Music/InnerTubeClientTimeZoneTests.swift
// The time zone the InnerTube client puts in every request's client context. YouTube cuts History into days
// ("Today", "Yesterday") with it; without it the days are cut at UTC midnight and an evening in New York lands
// under "Yesterday". The zone is read per request, so a daylight saving change is followed.

import Foundation
import os
import Testing
@testable import Deci

@MainActor
@Suite("InnerTubeClient time zone")
struct InnerTubeClientTimeZoneTests {
    /// 2027-01-15 08:00 UTC (the suite's usual fixed clock): winter in the northern hemisphere.
    private nonisolated static let winter = MusicTestJar.now
    /// 2026-07-25 17:20 UTC: summer in the northern hemisphere.
    private nonisolated static let summer = Date(timeIntervalSince1970: 1_785_000_000)

    private func makeClient(
        _ youtube: FakeYouTube,
        now: Date = MusicTestJar.now,
        zone: @escaping @Sendable () -> TimeZone
    ) -> InnerTubeClient {
        InnerTubeClient(
            transport: youtube,
            secretStore: MusicTestJar.signedInStore(),
            now: { now },
            timeZone: zone
        )
    }

    private func historyYouTube() -> FakeYouTube {
        FakeYouTube { config in
            config.browseBodies = ["FEmusic_history": (try? MusicFixtures.data("browse-history.json")) ?? Data()]
            config.browseContinuationBody = (try? MusicFixtures.data("browse-history-continuation.json")) ?? Data()
        }
    }

    private func clientContext(of request: HTTPRequest) throws -> [String: Any] {
        let body = FakeYouTube.jsonBody(request)
        let context = try #require(body["context"] as? [String: Any])
        return try #require(context["client"] as? [String: Any])
    }

    private func timeZone(_ identifier: String) throws -> TimeZone {
        try #require(TimeZone(identifier: identifier))
    }

    // MARK: - The history request

    @Test(
        "the history browse carries the zone and its offset in minutes",
        arguments: [
            ("America/New_York", 1_785_000_000.0, -240),
            ("America/New_York", 1_800_000_000.0, -300),
            ("Asia/Kolkata", 1_800_000_000.0, 330),
            ("Asia/Kolkata", 1_785_000_000.0, 330),
            ("America/St_Johns", 1_800_000_000.0, -210),
            ("Europe/London", 1_800_000_000.0, 0),
            ("Europe/London", 1_785_000_000.0, 60),
            ("Pacific/Auckland", 1_800_000_000.0, 780),
        ]
    )
    func historyCarriesZone(identifier: String, seconds: Double, minutes: Int) async throws {
        let fake = historyYouTube()
        let zone = try timeZone(identifier)
        let client = makeClient(fake, now: Date(timeIntervalSince1970: seconds)) { zone }
        _ = try await client.history()

        let request = try #require(fake.requests(path: "/youtubei/v1/browse").first)
        #expect(FakeYouTube.jsonBody(request)["browseId"] as? String == "FEmusic_history")
        let sentClient = try clientContext(of: request)
        #expect(sentClient["timeZone"] as? String == identifier)
        #expect(sentClient["utcOffsetMinutes"] as? Int == minutes)
    }

    @Test("the next history page carries the zone too, so every page cuts its days the same way")
    func historyContinuationCarriesZone() async throws {
        let fake = historyYouTube()
        let zone = try timeZone("America/New_York")
        let client = makeClient(fake, now: Self.summer) { zone }
        _ = try await client.moreHistory(continuation: "q:FIXTURE_HISTORY_NEXT%3D")

        let request = try #require(fake.requests(path: "/youtubei/v1/browse").first)
        let sent = try clientContext(of: request)
        #expect(sent["timeZone"] as? String == "America/New_York")
        #expect(sent["utcOffsetMinutes"] as? Int == -240)
    }

    // MARK: - Another endpoint

    @Test("the account menu call carries the zone as well: the web client sends it on every request")
    func accountCarriesZone() async throws {
        let fake = FakeYouTube()
        let zone = try timeZone("Asia/Kolkata")
        let client = makeClient(fake, now: Self.winter) { zone }
        _ = try await client.accountInfo()

        let request = try #require(fake.requests(path: "/youtubei/v1/account/account_menu").first)
        let sent = try clientContext(of: request)
        #expect(sent["timeZone"] as? String == "Asia/Kolkata")
        #expect(sent["utcOffsetMinutes"] as? Int == 330)
        #expect(sent["clientName"] as? String == "WEB_REMIX")
    }

    // MARK: - Per request

    @Test("the zone and offset are read for every request, so a change of zone shows in the next one")
    func readPerRequest() async throws {
        let fake = historyYouTube()
        let current = OSAllocatedUnfairLock(initialState: try timeZone("America/New_York"))
        let client = makeClient(fake, now: Self.summer) { current.withLock { $0 } }

        _ = try await client.history()
        current.withLock { $0 = TimeZone(identifier: "Asia/Kolkata")! }
        _ = try await client.history()

        let sent = try fake.requests(path: "/youtubei/v1/browse").map { try clientContext(of: $0) }
        #expect(sent.map { $0["timeZone"] as? String } == ["America/New_York", "Asia/Kolkata"])
        #expect(sent.map { $0["utcOffsetMinutes"] as? Int } == [-240, 330])
    }

    @Test("the offset follows the clock across a daylight saving change")
    func offsetFollowsClock() async throws {
        let fake = historyYouTube()
        let zone = try timeZone("America/New_York")
        let clock = OSAllocatedUnfairLock(initialState: Self.winter)
        let client = InnerTubeClient(
            transport: fake,
            secretStore: MusicTestJar.signedInStore(),
            now: { clock.withLock { $0 } },
            timeZone: { zone }
        )

        _ = try await client.history()
        clock.withLock { $0 = Self.summer }
        _ = try await client.history()

        let sent = try fake.requests(path: "/youtubei/v1/browse").map { try clientContext(of: $0) }
        #expect(sent.map { $0["utcOffsetMinutes"] as? Int } == [-300, -240])
    }

    @Test("the real client reads the device's zone when none is given")
    func defaultsToDeviceZone() async throws {
        let fake = historyYouTube()
        let client = InnerTubeClient(
            transport: fake,
            secretStore: MusicTestJar.signedInStore(),
            now: { Self.summer }
        )
        _ = try await client.history()

        let request = try #require(fake.requests(path: "/youtubei/v1/browse").first)
        let sent = try clientContext(of: request)
        #expect(sent["timeZone"] as? String == TimeZone.current.identifier)
        #expect(sent["utcOffsetMinutes"] as? Int == TimeZone.current.secondsFromGMT(for: Self.summer) / 60)
    }
}
