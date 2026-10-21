// DeciTests/Music/InnerTubeParserLikeTests.swift
// How the like state of a song is read out of a `next` response: the `likeButtonRenderer` in the player overlay
// whose target is the song asked about. The JSON is hand-made with made-up ids, in the shape the live response has.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("InnerTubeParser like status")
struct InnerTubeParserLikeTests {

    private static func renderer(_ videoId: String, _ status: String) -> String {
        #"{"likeButtonRenderer":{"target":{"videoId":"\#(videoId)"},"likeStatus":"\#(status)","likesAllowed":true}}"#
    }

    private static func response(actions: [String]) -> Data {
        let body = #"{"playerOverlays":{"playerOverlayRenderer":{"actions":[\#(actions.joined(separator: ","))]}}}"#
        return Data(body.utf8)
    }

    @Test("The three statuses map to like, dislike and indifferent")
    func statuses() throws {
        let cases: [(String, MusicLikeStatus)] = [("LIKE", .like), ("DISLIKE", .dislike), ("INDIFFERENT", .indifferent)]
        for (raw, expected) in cases {
            let data = Self.response(actions: [Self.renderer("vid-1", raw)])
            #expect(try InnerTubeParser.likeStatus(from: data, videoId: "vid-1") == expected, "status \(raw)")
        }
    }

    @Test("The renderer whose target is the asked song wins over another song's")
    func picksTheRequestedSong() throws {
        let data = Self.response(actions: [Self.renderer("vid-other", "DISLIKE"), Self.renderer("vid-1", "LIKE")])
        #expect(try InnerTubeParser.likeStatus(from: data, videoId: "vid-1") == .like)
        #expect(try InnerTubeParser.likeStatus(from: data, videoId: "vid-other") == .dislike)
    }

    @Test("A renderer found deeper in the response is still read")
    func nestedRenderer() throws {
        let body = #"{"contents":{"a":[{"b":{"likeButtonRenderer":{"target":{"videoId":"vid-1"},"likeStatus":"LIKE"}}}]}}"#
        #expect(try InnerTubeParser.likeStatus(from: Data(body.utf8), videoId: "vid-1") == .like)
    }

    @Test("No renderer for the song means unknown, not an error")
    func unknownWhenMissing() throws {
        #expect(try InnerTubeParser.likeStatus(from: Data("{}".utf8), videoId: "vid-1") == nil)
        let others = Self.response(actions: [Self.renderer("vid-other", "LIKE")])
        #expect(try InnerTubeParser.likeStatus(from: others, videoId: "vid-1") == nil)
        let noActions = Self.response(actions: [])
        #expect(try InnerTubeParser.likeStatus(from: noActions, videoId: "vid-1") == nil)
    }

    @Test("A renderer with a status the parser does not know, or none, is unknown")
    func unknownStatus() throws {
        #expect(try InnerTubeParser.likeStatus(from: Self.response(actions: [Self.renderer("vid-1", "SOMETHING_NEW")]), videoId: "vid-1") == nil)
        let bare = Self.response(actions: [#"{"likeButtonRenderer":{"target":{"videoId":"vid-1"}}}"#])
        #expect(try InnerTubeParser.likeStatus(from: bare, videoId: "vid-1") == nil)
    }

    @Test("A renderer with no target is never taken for the song")
    func noTarget() throws {
        let data = Self.response(actions: [#"{"likeButtonRenderer":{"likeStatus":"LIKE"}}"#])
        #expect(try InnerTubeParser.likeStatus(from: data, videoId: "vid-1") == nil)
    }

    @Test("A response that is not a JSON object is a parse error")
    func notJSON() {
        #expect(throws: MusicError.self) { try InnerTubeParser.likeStatus(from: Data("<html>".utf8), videoId: "vid-1") }
    }

    @Test("A radio page, which carries no like button, is unknown and does not throw")
    func radioPageHasNoRenderer() throws {
        let data = try MusicFixtures.data("next-radio-first.json")
        #expect(try InnerTubeParser.likeStatus(from: data, videoId: "any-id") == nil)
    }
}
