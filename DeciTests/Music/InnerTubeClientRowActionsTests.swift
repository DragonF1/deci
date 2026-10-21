// DeciTests/Music/InnerTubeClientRowActionsTests.swift
// The song-action calls of the InnerTube client against the recording fake transport: the add-to-playlist picker
// (for a song, or for a whole album or playlist), and the playlist add, add-whole-playlist and remove edits.
// Request bodies, auth headers, and how each failure maps.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("InnerTubeClient song actions")
struct InnerTubeClientRowActionsTests {
    private static let optionsPath = "/youtubei/v1/playlist/get_add_to_playlist"
    private static let editPath = "/youtubei/v1/browse/edit_playlist"

    private func makeClient(
        _ youtube: FakeYouTube,
        store: MemorySecretStore = MusicTestJar.signedInStore()
    ) -> InnerTubeClient {
        InnerTubeClient(transport: youtube, secretStore: store, now: { MusicTestJar.now })
    }

    private func onlyRequest(_ youtube: FakeYouTube, _ path: String) throws -> HTTPRequest {
        let requests = youtube.requests(path: path)
        #expect(requests.count == 1)
        return try #require(requests.first)
    }

    private func actions(_ request: HTTPRequest) -> [[String: Any]] {
        FakeYouTube.jsonBody(request)["actions"] as? [[String: Any]] ?? []
    }

    // MARK: - Picker list

    @Test("The picker list posts the video id, with the WEB_REMIX context and the auth headers")
    func optionsRequestShape() async throws {
        let fake = FakeYouTube()
        let options = try await makeClient(fake).addToPlaylistOptions(videoId: "vid-1")
        #expect(options.map(\.title) == ["Fixture Road Trip", "Fixture Workout", "Fixture No Cover"])
        #expect(options.map(\.containsVideo) == [false, true, false])

        let request = try onlyRequest(fake, Self.optionsPath)
        #expect(request.method == "POST")
        #expect(request.url.absoluteString == "https://music.youtube.com/youtubei/v1/playlist/get_add_to_playlist?prettyPrint=false")
        #expect(request.headers["Authorization"]?.hasPrefix("SAPISIDHASH 1800000000_") == true)
        #expect(request.headers["Cookie"]?.contains("SAPISID=sapisid-secret") == true)
        #expect(request.headers["Cookie"]?.contains("sid-google-only") == false)
        #expect(request.headers["Origin"] == "https://music.youtube.com")
        let body = FakeYouTube.jsonBody(request)
        #expect(body["videoIds"] as? [String] == ["vid-1"])
        let client = (body["context"] as? [String: Any])?["client"] as? [String: Any]
        #expect(client?["clientName"] as? String == "WEB_REMIX")
    }

    @Test("A blank video id asks for nothing and lists nothing")
    func optionsBlankId() async throws {
        let fake = FakeYouTube()
        let client = makeClient(fake)
        #expect(try await client.addToPlaylistOptions(videoId: "") == [])
        #expect(try await client.addToPlaylistOptions(videoId: "  \n") == [])
        #expect(fake.requests(path: Self.optionsPath).isEmpty)
    }

    @Test("A user with no playlists gets an empty list, not an error")
    func optionsEmpty() async throws {
        let fake = FakeYouTube { $0.addToPlaylistBody = Data("{}".utf8) }
        #expect(try await makeClient(fake).addToPlaylistOptions(videoId: "vid-1") == [])
    }

    @Test("A picker answer that is not JSON is a parse error")
    func optionsNotJSON() async {
        let fake = FakeYouTube { $0.addToPlaylistBody = Data("<html>".utf8) }
        await #expect(throws: MusicError.self) { try await makeClient(fake).addToPlaylistOptions(videoId: "vid-1") }
    }

    // MARK: - Picker list for a whole album or playlist

    @Test("The picker list of a whole playlist posts the source playlist id alone, with the same path and auth headers")
    func sourceOptionsRequestShape() async throws {
        let fake = FakeYouTube()
        let options = try await makeClient(fake).addToPlaylistOptions(sourcePlaylistId: "OLAK5uy_tile")
        #expect(options.map(\.title) == ["Fixture Road Trip", "Fixture Workout", "Fixture No Cover"])

        let request = try onlyRequest(fake, Self.optionsPath)
        #expect(request.method == "POST")
        #expect(request.url.absoluteString == "https://music.youtube.com/youtubei/v1/playlist/get_add_to_playlist?prettyPrint=false")
        #expect(request.headers["Authorization"]?.hasPrefix("SAPISIDHASH 1800000000_") == true)
        #expect(request.headers["Cookie"]?.contains("SAPISID=sapisid-secret") == true)
        let body = FakeYouTube.jsonBody(request)
        #expect(body["playlistId"] as? String == "OLAK5uy_tile")
        #expect(body["videoIds"] == nil)
        let client = (body["context"] as? [String: Any])?["client"] as? [String: Any]
        #expect(client?["clientName"] as? String == "WEB_REMIX")
    }

    @Test("A source playlist id goes out without a VL, as the edit call's does")
    func sourceOptionsKeepsPlainId() async throws {
        let fake = FakeYouTube()
        _ = try await makeClient(fake).addToPlaylistOptions(sourcePlaylistId: " VLPLtile ")
        let body = FakeYouTube.jsonBody(try onlyRequest(fake, Self.optionsPath))
        #expect(body["playlistId"] as? String == "PLtile")
    }

    @Test("A blank source playlist id asks for nothing and lists nothing")
    func sourceOptionsBlankId() async throws {
        let fake = FakeYouTube()
        let client = makeClient(fake)
        #expect(try await client.addToPlaylistOptions(sourcePlaylistId: "") == [])
        #expect(try await client.addToPlaylistOptions(sourcePlaylistId: "  \n") == [])
        #expect(try await client.addToPlaylistOptions(sourcePlaylistId: "VL") == [])
        #expect(fake.requests(path: Self.optionsPath).isEmpty)
    }

    @Test("A source list answer that is not JSON is a parse error")
    func sourceOptionsNotJSON() async {
        let fake = FakeYouTube { $0.addToPlaylistBody = Data("<html>".utf8) }
        await #expect(throws: MusicError.self) { try await makeClient(fake).addToPlaylistOptions(sourcePlaylistId: "PLtile") }
    }

    // MARK: - Add

    @Test("Adding posts one ACTION_ADD_VIDEO that skips a duplicate, to the playlist id without its VL")
    func addRequestShape() async throws {
        let fake = FakeYouTube()
        try await makeClient(fake).addVideo("vid-1", toPlaylist: "VLPLfixtureMine")

        let request = try onlyRequest(fake, Self.editPath)
        #expect(request.method == "POST")
        #expect(request.url.absoluteString == "https://music.youtube.com/youtubei/v1/browse/edit_playlist?prettyPrint=false")
        #expect(request.headers["Authorization"]?.hasPrefix("SAPISIDHASH 1800000000_") == true)
        #expect(request.headers["Cookie"]?.contains("SAPISID=sapisid-secret") == true)
        let body = FakeYouTube.jsonBody(request)
        #expect(body["playlistId"] as? String == "PLfixtureMine")
        let sent = actions(request)
        #expect(sent.count == 1)
        #expect(sent.first?["action"] as? String == "ACTION_ADD_VIDEO")
        #expect(sent.first?["addedVideoId"] as? String == "vid-1")
        // DEDUPE_OPTION_SKIP would skip YouTube's duplicate check and add the song twice.
        #expect(sent.first?["dedupeOption"] == nil)
        #expect(sent.first?["setVideoId"] == nil)
    }

    @Test("A playlist id with no VL goes out as it is")
    func addKeepsPlainId() async throws {
        let fake = FakeYouTube()
        try await makeClient(fake).addVideo("vid-1", toPlaylist: "PLfixtureMine")
        let body = FakeYouTube.jsonBody(try onlyRequest(fake, Self.editPath))
        #expect(body["playlistId"] as? String == "PLfixtureMine")
    }

    @Test("A blank playlist id or video id is refused before any request")
    func addBlankIds() async {
        let fake = FakeYouTube()
        let client = makeClient(fake)
        await #expect(throws: MusicError.self) { try await client.addVideo("vid-1", toPlaylist: "") }
        await #expect(throws: MusicError.self) { try await client.addVideo("vid-1", toPlaylist: "VL") }
        await #expect(throws: MusicError.self) { try await client.addVideo("", toPlaylist: "PLfixtureMine") }
        #expect(fake.requests(path: Self.editPath).isEmpty)
    }

    @Test("An edit that does not say STATUS_SUCCEEDED is rejected")
    func addRejected() async {
        for body in [#"{"status":"STATUS_FAILED"}"#, "{}", #"{"status":"succeeded"}"#] {
            let fake = FakeYouTube { $0.editPlaylistBody = Data(body.utf8) }
            await #expect(throws: MusicError.rejected, "body \(body)") {
                try await makeClient(fake).addVideo("vid-1", toPlaylist: "PLfixtureMine")
            }
        }
    }

    // MARK: - Add a whole playlist

    @Test("Adding a whole playlist posts one ACTION_ADD_PLAYLIST with the source id, to the target without its VL")
    func addPlaylistRequestShape() async throws {
        let fake = FakeYouTube()
        try await makeClient(fake).addPlaylist("OLAK5uy_tile", toPlaylist: "VLPLfixtureMine")

        let request = try onlyRequest(fake, Self.editPath)
        #expect(request.method == "POST")
        #expect(request.url.absoluteString == "https://music.youtube.com/youtubei/v1/browse/edit_playlist?prettyPrint=false")
        #expect(request.headers["Authorization"]?.hasPrefix("SAPISIDHASH 1800000000_") == true)
        #expect(request.headers["Cookie"]?.contains("SAPISID=sapisid-secret") == true)
        let body = FakeYouTube.jsonBody(request)
        #expect(body["playlistId"] as? String == "PLfixtureMine")
        let sent = actions(request)
        #expect(sent.count == 1)
        #expect(sent.first?["action"] as? String == "ACTION_ADD_PLAYLIST")
        #expect(sent.first?["addedFullListId"] as? String == "OLAK5uy_tile")
        // Like the song add, no dedupe option goes out.
        #expect(sent.first?["dedupeOption"] == nil)
        #expect(sent.first?["addedVideoId"] == nil)
    }

    @Test("A target or source id with no content is refused before any request")
    func addPlaylistBlankIds() async {
        let fake = FakeYouTube()
        let client = makeClient(fake)
        await #expect(throws: MusicError.self) { try await client.addPlaylist("OLAK5uy_tile", toPlaylist: "") }
        await #expect(throws: MusicError.self) { try await client.addPlaylist("OLAK5uy_tile", toPlaylist: "VL") }
        await #expect(throws: MusicError.self) { try await client.addPlaylist("", toPlaylist: "PLfixtureMine") }
        await #expect(throws: MusicError.self) { try await client.addPlaylist("  ", toPlaylist: "PLfixtureMine") }
        #expect(fake.requests(path: Self.editPath).isEmpty)
    }

    @Test("A whole-playlist add that does not say STATUS_SUCCEEDED is rejected")
    func addPlaylistRejected() async {
        for body in [#"{"status":"STATUS_FAILED"}"#, "{}"] {
            let fake = FakeYouTube { $0.editPlaylistBody = Data(body.utf8) }
            await #expect(throws: MusicError.rejected, "body \(body)") {
                try await makeClient(fake).addPlaylist("OLAK5uy_tile", toPlaylist: "PLfixtureMine")
            }
        }
    }

    // MARK: - Remove

    @Test("Removing posts one ACTION_REMOVE_VIDEO with the row's setVideoId and the video id")
    func removeRequestShape() async throws {
        let fake = FakeYouTube()
        try await makeClient(fake).removeVideo("vid-1", setVideoId: "set-1", fromPlaylist: "VLPLfixtureMine")

        let request = try onlyRequest(fake, Self.editPath)
        #expect(request.headers["Authorization"]?.hasPrefix("SAPISIDHASH 1800000000_") == true)
        let body = FakeYouTube.jsonBody(request)
        #expect(body["playlistId"] as? String == "PLfixtureMine")
        let sent = actions(request)
        #expect(sent.count == 1)
        #expect(sent.first?["action"] as? String == "ACTION_REMOVE_VIDEO")
        #expect(sent.first?["setVideoId"] as? String == "set-1")
        #expect(sent.first?["removedVideoId"] as? String == "vid-1")
        #expect(sent.first?["dedupeOption"] == nil)
    }

    @Test("A removal with no playlist id, video id or setVideoId is refused before any request")
    func removeBlankIds() async {
        let fake = FakeYouTube()
        let client = makeClient(fake)
        await #expect(throws: MusicError.self) { try await client.removeVideo("vid-1", setVideoId: "set-1", fromPlaylist: "VL") }
        await #expect(throws: MusicError.self) { try await client.removeVideo("", setVideoId: "set-1", fromPlaylist: "PLfixtureMine") }
        await #expect(throws: MusicError.self) { try await client.removeVideo("vid-1", setVideoId: "", fromPlaylist: "PLfixtureMine") }
        #expect(fake.requests(path: Self.editPath).isEmpty)
    }

    @Test("A removal that does not say STATUS_SUCCEEDED is rejected")
    func removeRejected() async {
        let fake = FakeYouTube { $0.editPlaylistBody = Data(#"{"status":"STATUS_FAILED"}"#.utf8) }
        await #expect(throws: MusicError.rejected) {
            try await makeClient(fake).removeVideo("vid-1", setVideoId: "set-1", fromPlaylist: "VLPLfixtureMine")
        }
    }

    // MARK: - Signed out and HTTP errors

    @Test("Signed out: every song action fails with signedOut and touches no network")
    func signedOut() async {
        let fake = FakeYouTube()
        let client = makeClient(fake, store: MemorySecretStore())
        await #expect(throws: MusicError.signedOut) { try await client.addToPlaylistOptions(videoId: "vid-1") }
        await #expect(throws: MusicError.signedOut) { try await client.addToPlaylistOptions(sourcePlaylistId: "PLtile") }
        await #expect(throws: MusicError.signedOut) { try await client.addVideo("vid-1", toPlaylist: "PLfixtureMine") }
        await #expect(throws: MusicError.signedOut) { try await client.addPlaylist("PLtile", toPlaylist: "PLfixtureMine") }
        await #expect(throws: MusicError.signedOut) {
            try await client.removeVideo("vid-1", setVideoId: "set-1", fromPlaylist: "PLfixtureMine")
        }
        #expect(fake.requests.isEmpty)
    }

    @Test("HTTP 401 means the session is gone, other statuses carry their code")
    func httpErrors() async {
        let expired = makeClient(FakeYouTube {
            $0.addToPlaylistStatus = 401
            $0.editPlaylistStatus = 401
        })
        await #expect(throws: MusicError.signedOut) { try await expired.addToPlaylistOptions(videoId: "vid-1") }
        await #expect(throws: MusicError.signedOut) { try await expired.addToPlaylistOptions(sourcePlaylistId: "PLtile") }
        await #expect(throws: MusicError.signedOut) { try await expired.addVideo("vid-1", toPlaylist: "PLfixtureMine") }
        await #expect(throws: MusicError.signedOut) { try await expired.addPlaylist("PLtile", toPlaylist: "PLfixtureMine") }
        await #expect(throws: MusicError.signedOut) {
            try await expired.removeVideo("vid-1", setVideoId: "set-1", fromPlaylist: "PLfixtureMine")
        }

        let broken = makeClient(FakeYouTube {
            $0.addToPlaylistStatus = 500
            $0.editPlaylistStatus = 503
        })
        await #expect(throws: MusicError.http(500)) { try await broken.addToPlaylistOptions(videoId: "vid-1") }
        await #expect(throws: MusicError.http(500)) { try await broken.addToPlaylistOptions(sourcePlaylistId: "PLtile") }
        await #expect(throws: MusicError.http(503)) { try await broken.addVideo("vid-1", toPlaylist: "PLfixtureMine") }
        await #expect(throws: MusicError.http(503)) { try await broken.addPlaylist("PLtile", toPlaylist: "PLfixtureMine") }
        await #expect(throws: MusicError.http(503)) {
            try await broken.removeVideo("vid-1", setVideoId: "set-1", fromPlaylist: "PLfixtureMine")
        }
    }
}
