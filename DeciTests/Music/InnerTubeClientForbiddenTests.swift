// DeciTests/Music/InnerTubeClientForbiddenTests.swift
// A 403 from music.youtube.com against the recording fake transport: a playlist edit that names a brand channel and is
// refused is tried once more without it (as a 401 is), a 403 on the account's own channel, on a read or on a like is not,
// a retry never goes out for a session that ended or a task that was cancelled while the refusal was in flight, a 403 is
// thrown as `.forbidden` while every other status keeps its error, and the line logged for a failed answer carries the
// endpoint, the status and two short tokens, never a message or an id. Nothing here reaches the network.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("InnerTubeClient forbidden")
struct InnerTubeClientForbiddenTests {
    private static let brandHTML = #"<script>ytcfg.set({"INNERTUBE_CLIENT_VERSION":"1.2","DATASYNC_ID":"brand123||user456"});</script>"#
    private static let ownHTML = #"<script>ytcfg.set({"INNERTUBE_CLIENT_VERSION":"1.2","DATASYNC_ID":"user456||"});</script>"#
    private static let editPath = "/youtubei/v1/browse/edit_playlist"
    private static let forbiddenBody = Data(
        #"{"error":{"code":403,"message":"The caller does not have permission","errors":[{"message":"Forbidden","domain":"global","reason":"forbidden"}],"status":"PERMISSION_DENIED"}}"#.utf8
    )

    private func makeClient(_ youtube: FakeYouTube) -> InnerTubeClient {
        InnerTubeClient(transport: youtube, secretStore: MusicTestJar.signedInStore(), now: { MusicTestJar.now })
    }

    private func brandYouTube(_ configure: (inout FakeYouTube.Config) -> Void = { _ in }) -> FakeYouTube {
        FakeYouTube {
            $0.bootstrapHTML = Self.brandHTML
            configure(&$0)
        }
    }

    private func ownYouTube(_ configure: (inout FakeYouTube.Config) -> Void = { _ in }) -> FakeYouTube {
        FakeYouTube {
            $0.bootstrapHTML = Self.ownHTML
            configure(&$0)
        }
    }

    /// The channel each request of `path` named, in the order they went out; nil for a request that named none.
    private func channels(_ youtube: FakeYouTube, _ path: String) -> [String?] {
        youtube.requests(path: path).map(FakeYouTube.onBehalfOfUser)
    }

    /// A brand channel that YouTube refuses on `path` with the usual permission answer.
    private func refusing(_ path: String) -> (inout FakeYouTube.Config) -> Void {
        { $0.brandedAnswers[path] = .init(status: 403, body: Self.forbiddenBody) }
    }

    private func edit(_ client: InnerTubeClient) async throws {
        try await client.removeVideo("vid-1", setVideoId: "set-1", fromPlaylist: "VLPLfixtureMine")
    }

    // MARK: - The retry without the channel

    @Test("A playlist edit that the brand channel is refused with a 403 is sent once more without the channel, and goes through")
    func editRetriesWithoutChannel() async throws {
        let youtube = brandYouTube(refusing(Self.editPath))
        try await edit(makeClient(youtube))

        #expect(channels(youtube, Self.editPath) == ["brand123", nil])
        let sent = youtube.requests(path: Self.editPath).map(FakeYouTube.jsonBody)
        #expect(sent.count == 2)
        // The same call goes out again, only without the channel.
        #expect(sent.last?["playlistId"] as? String == "PLfixtureMine")
        let first = sent.first?["actions"] as? [[String: Any]]
        let second = sent.last?["actions"] as? [[String: Any]]
        #expect(second?.first?["action"] as? String == "ACTION_REMOVE_VIDEO")
        #expect(second?.first?["setVideoId"] as? String == "set-1")
        #expect(second?.first?["removedVideoId"] as? String == "vid-1")
        #expect(first?.first?["setVideoId"] as? String == "set-1")
        // Both carry the sign-in headers.
        for request in youtube.requests(path: Self.editPath) {
            #expect(request.headers["Authorization"]?.hasPrefix("SAPISIDHASH 1800000000_") == true)
        }
    }

    @Test("Adding a song and adding a whole playlist retry the same way")
    func addsRetryWithoutChannel() async throws {
        let song = brandYouTube(refusing(Self.editPath))
        try await makeClient(song).addVideo("vid-1", toPlaylist: "PLfixtureMine")
        #expect(channels(song, Self.editPath) == ["brand123", nil])

        let list = brandYouTube(refusing(Self.editPath))
        try await makeClient(list).addPlaylist("OLAK5uy_tile", toPlaylist: "PLfixtureMine")
        #expect(channels(list, Self.editPath) == ["brand123", nil])
    }

    @Test("A retry that is refused too throws forbidden after exactly two requests")
    func retryRefusedToo() async {
        let youtube = brandYouTube {
            $0.editPlaylistStatus = 403
            $0.editPlaylistBody = Self.forbiddenBody
        }
        await #expect(throws: MusicError.forbidden) { try await edit(makeClient(youtube)) }
        #expect(channels(youtube, Self.editPath) == ["brand123", nil])
    }

    @Test("A retry that answers something else throws that answer")
    func retryAnswersOtherwise() async {
        let signedOut = brandYouTube {
            $0.brandedAnswers[Self.editPath] = .init(status: 403, body: Self.forbiddenBody)
            $0.editPlaylistStatus = 401
        }
        await #expect(throws: MusicError.signedOut) { try await edit(makeClient(signedOut)) }

        let broken = brandYouTube {
            $0.brandedAnswers[Self.editPath] = .init(status: 403, body: Self.forbiddenBody)
            $0.editPlaylistStatus = 503
        }
        await #expect(throws: MusicError.http(503)) { try await edit(makeClient(broken)) }

        let notDone = brandYouTube {
            $0.brandedAnswers[Self.editPath] = .init(status: 403, body: Self.forbiddenBody)
            $0.editPlaylistBody = Data(#"{"status":"STATUS_FAILED"}"#.utf8)
        }
        await #expect(throws: MusicError.rejected) { try await edit(makeClient(notDone)) }
    }

    @Test("The cookies that either answer sets are kept, the refused one's too")
    func retryKeepsCookies() async throws {
        let youtube = brandYouTube {
            $0.brandedAnswers[Self.editPath] = .init(
                status: 403,
                body: Self.forbiddenBody,
                headers: ["Set-Cookie": "FROM_REFUSAL=one; Domain=.youtube.com; Path=/; Secure; Max-Age=7776000"]
            )
            $0.editPlaylistHeaders = ["Set-Cookie": "FROM_RETRY=two; Domain=.youtube.com; Path=/; Secure; Max-Age=7776000"]
        }
        let client = makeClient(youtube)
        try await edit(client)

        let jar = await client.sessionCookies()
        #expect(jar.first { $0.name == "FROM_REFUSAL" }?.value == "one")
        #expect(jar.first { $0.name == "FROM_RETRY" }?.value == "two")
    }

    // MARK: - Before the retry

    @Test("A retry is signed with the cookies the refused answer just set, not the ones the first request went out with")
    func retryIsSignedAnew() async throws {
        let youtube = brandYouTube {
            $0.brandedAnswers[Self.editPath] = .init(
                status: 403,
                body: Self.forbiddenBody,
                headers: ["Set-Cookie": "SAPISID=rotated-sapisid; Domain=.youtube.com; Path=/; Secure; Max-Age=7776000"]
            )
        }
        try await edit(makeClient(youtube))

        let sent = youtube.requests(path: Self.editPath)
        #expect(sent.count == 2)
        #expect(sent.first?.headers["Cookie"]?.contains("SAPISID=sapisid-secret") == true)
        #expect(sent.last?.headers["Cookie"]?.contains("SAPISID=rotated-sapisid") == true)
        #expect(sent.last?.headers["Cookie"]?.contains("SAPISID=sapisid-secret") == false)
        #expect(sent.first?.headers["Authorization"] != sent.last?.headers["Authorization"])
        #expect(sent.last?.headers["Authorization"]?.hasPrefix("SAPISIDHASH 1800000000_") == true)
    }

    @Test("A refused edit is not sent again when the session ended while the refusal was in flight, on a 403 or a 401")
    func endedSessionIsNotRetried() async throws {
        for status in [403, 401] {
            let gate = MusicTestGate()
            let youtube = brandYouTube { $0.brandedAnswers[Self.editPath] = .init(status: status, body: Self.forbiddenBody) }
            let client = makeClient(youtube)
            _ = try await client.session()
            youtube.update { $0.gate = gate }
            let call = Task { try await edit(client) }
            #expect(await eventually { youtube.requests(path: Self.editPath).count == 1 }, "status \(status)")

            await client.signOut()
            await gate.open()

            await #expect(throws: MusicError.signedOut) { try await call.value }
            #expect(channels(youtube, Self.editPath) == ["brand123"], "status \(status)")
        }
    }

    @Test("A refused edit is not sent again when its task was cancelled while the refusal was in flight, on a 403 or a 401")
    func cancelledCallIsNotRetried() async throws {
        for status in [403, 401] {
            let gate = MusicTestGate()
            let youtube = brandYouTube { $0.brandedAnswers[Self.editPath] = .init(status: status, body: Self.forbiddenBody) }
            let client = makeClient(youtube)
            _ = try await client.session()
            youtube.update { $0.gate = gate }
            let call = Task { try await edit(client) }
            #expect(await eventually { youtube.requests(path: Self.editPath).count == 1 }, "status \(status)")

            call.cancel()
            await gate.open()

            await #expect(throws: CancellationError.self) { try await call.value }
            #expect(channels(youtube, Self.editPath) == ["brand123"], "status \(status)")
        }
    }

    // MARK: - No retry

    @Test("A like, dislike or remove like that the brand channel is refused with a 403 is not retried, since it would land on the wrong channel")
    func ratesNotRetried() async {
        for (status, path) in [
            (MusicLikeStatus.like, "/youtubei/v1/like/like"),
            (.dislike, "/youtubei/v1/like/dislike"),
            (.indifferent, "/youtubei/v1/like/removelike"),
        ] {
            let youtube = brandYouTube(refusing(path))
            await #expect(throws: MusicError.forbidden) { try await makeClient(youtube).rate(videoId: "vid-1", status: status) }
            #expect(channels(youtube, path) == ["brand123"], "path \(path)")
        }
    }

    @Test("A 403 on the account's own channel is not retried, and is thrown as forbidden")
    func ownChannelNotRetried() async {
        let youtube = ownYouTube {
            $0.editPlaylistStatus = 403
            $0.editPlaylistBody = Self.forbiddenBody
            $0.rateStatus = 403
        }
        let client = makeClient(youtube)
        await #expect(throws: MusicError.forbidden) { try await edit(client) }
        await #expect(throws: MusicError.forbidden) { try await client.rate(videoId: "vid-1", status: .like) }

        #expect(channels(youtube, Self.editPath) == [nil])
        #expect(channels(youtube, "/youtubei/v1/like/like") == [nil])
    }

    @Test("A 403 on a read is not retried, on a brand channel or off it, and is thrown as forbidden")
    func readsNotRetried() async {
        let brand = brandYouTube {
            $0.searchStatus = 403
            $0.browseStatus = 403
            $0.nextStatus = 403
            $0.accountMenuStatus = 403
            $0.addToPlaylistStatus = 403
        }
        let client = makeClient(brand)
        await #expect(throws: MusicError.forbidden) { _ = try await client.search("a") }
        await #expect(throws: MusicError.forbidden) { _ = try await client.page(browseId: "VLPLfixtureMine") }
        await #expect(throws: MusicError.forbidden) { _ = try await client.radio(seedVideoId: "x") }
        await #expect(throws: MusicError.forbidden) { _ = try await client.accountInfo() }
        await #expect(throws: MusicError.forbidden) { _ = try await client.addToPlaylistOptions(videoId: "vid-1") }

        for path in [
            "/youtubei/v1/search", "/youtubei/v1/browse", "/youtubei/v1/next",
            "/youtubei/v1/account/account_menu", "/youtubei/v1/playlist/get_add_to_playlist",
        ] {
            #expect(channels(brand, path) == ["brand123"], "path \(path)")
        }
    }

    @Test("A browse read is not mistaken for the playlist edit, which is also under browse")
    func browseIsNotTheEdit() async {
        let youtube = brandYouTube(refusing("/youtubei/v1/browse"))
        await #expect(throws: MusicError.forbidden) { _ = try await makeClient(youtube).home() }
        #expect(channels(youtube, "/youtubei/v1/browse") == ["brand123"])
    }

    // MARK: - The other statuses

    @Test("A 401 to an edit that named the brand channel is still tried once more without it, and an own channel is not retried")
    func status401Unchanged() async throws {
        let recovered = brandYouTube { $0.brandedAnswers[Self.editPath] = .init(status: 401) }
        try await edit(makeClient(recovered))
        #expect(channels(recovered, Self.editPath) == ["brand123", nil])

        // A 401 is retried on any call, a like too.
        let liked = brandYouTube { $0.brandedAnswers["/youtubei/v1/like/like"] = .init(status: 401) }
        try await makeClient(liked).rate(videoId: "vid-1", status: .like)
        #expect(channels(liked, "/youtubei/v1/like/like") == ["brand123", nil])

        let gone = brandYouTube { $0.editPlaylistStatus = 401 }
        await #expect(throws: MusicError.signedOut) { try await edit(makeClient(gone)) }
        #expect(channels(gone, Self.editPath) == ["brand123", nil])

        let own = ownYouTube { $0.editPlaylistStatus = 401 }
        await #expect(throws: MusicError.signedOut) { try await edit(makeClient(own)) }
        #expect(channels(own, Self.editPath) == [nil])
    }

    @Test("Every status but 401 and 403 keeps its error and is not retried")
    func otherStatusesUnchanged() async {
        for status in [400, 404, 408, 429, 500, 503] {
            let youtube = brandYouTube {
                $0.editPlaylistStatus = status
                $0.rateStatus = status
            }
            let client = makeClient(youtube)
            await #expect(throws: MusicError.http(status)) { try await edit(client) }
            await #expect(throws: MusicError.http(status)) { try await client.rate(videoId: "vid-1", status: .like) }
            #expect(channels(youtube, Self.editPath) == ["brand123"], "status \(status)")
            #expect(channels(youtube, "/youtubei/v1/like/like") == ["brand123"], "status \(status)")
        }
    }

    @Test("A history ping that is refused keeps the plain HTTP error, and is not retried")
    func historyPingStaysHTTP() async throws {
        let youtube = brandYouTube { $0.statsStatus = 403 }
        let client = makeClient(youtube)
        let ping = HistoryPing(
            kind: .playback,
            url: URL(string: "https://s.youtube.com/api/stats/playback?cl=1&docid=abc&ei=E&len=370")!,
            cpn: "AbCd_-0123456789",
            mediaTime: 30
        )
        await #expect(throws: MusicError.http(403)) { _ = try await client.reportHistory(ping) }
    }

    // MARK: - The line logged for a failed answer

    @Test("The failure line names the endpoint, the status, the two tokens, the channel flag and the identity")
    func failureLine() {
        let line = InnerTubeClient.failureDescription(
            endpoint: "browse/edit_playlist", status: 403, body: Self.forbiddenBody, sentOnBehalfOf: true, identity: "brand channel"
        )
        #expect(line == "browse/edit_playlist answered http 403, status PERMISSION_DENIED, reason forbidden, onBehalfOf true, identity brand channel")
    }

    @Test("A body with no tokens logs none, and a body that is not JSON logs none")
    func failureLineWithoutTokens() {
        for body in [Data("{}".utf8), Data("<html>blocked</html>".utf8), Data()] {
            let line = InnerTubeClient.failureDescription(
                endpoint: "like/like", status: 500, body: body, sentOnBehalfOf: false, identity: "own channel"
            )
            #expect(line == "like/like answered http 500, status none, reason none, onBehalfOf false, identity own channel")
        }
    }

    @Test("The failure line never carries the message, an id or any text of the body")
    func failureLineLeaksNothing() {
        let body = Data(
            #"{"error":{"message":"secret-text for user@example.com","errors":[{"message":"secret-detail","reason":"has spaces and secrets"}],"status":"secret status"}}"#.utf8
        )
        let line = InnerTubeClient.failureDescription(
            endpoint: "browse/edit_playlist", status: 403, body: body, sentOnBehalfOf: true, identity: "unknown"
        )
        #expect(!line.contains("secret"))
        #expect(!line.contains("example.com"))
        #expect(line == "browse/edit_playlist answered http 403, status none, reason none, onBehalfOf true, identity unknown")
    }

    @Test("The line logged after a retry without the channel carries only the status that answered")
    func retryLine() {
        #expect(InnerTubeClient.retryDescription(status: 200) == "retried without channel: http 200")
        #expect(InnerTubeClient.retryDescription(status: 403) == "retried without channel: http 403")
        #expect(InnerTubeClient.retryDescription(status: 503) == "retried without channel: http 503")
    }

    @Test("The identity label says brand channel, own channel, or unknown when the page did not say")
    func identityLabels() {
        let base = InnerTubeSession(clientVersion: "1.2", visitorData: nil, playerJSURL: nil)
        #expect(InnerTubeClient.identityLabel(of: base) == "unknown")
        var brand = base
        brand.isBrandChannel = true
        #expect(InnerTubeClient.identityLabel(of: brand) == "brand channel")
        var own = base
        own.isBrandChannel = false
        #expect(InnerTubeClient.identityLabel(of: own) == "own channel")
    }
}
