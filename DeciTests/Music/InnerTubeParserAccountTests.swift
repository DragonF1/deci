// DeciTests/Music/InnerTubeParserAccountTests.swift
// The account menu parser (`account/account_menu`): the signed-in channel's name, @handle and avatar.
// account-menu.json copies the structure of a real response with made-up values.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("InnerTubeParser account")
struct InnerTubeParserAccountTests {

    // MARK: - Helpers

    /// A menu response whose header is `header` (raw JSON for the activeAccountHeaderRenderer body).
    private func menu(header: String) -> Data {
        let json = """
        {"actions":[{"openPopupAction":{"popup":{"multiPageMenuRenderer":{"header":{"activeAccountHeaderRenderer":\(header)}}}}}]}
        """
        return Data(json.utf8)
    }

    private func photo(_ entries: String) -> String {
        #""accountPhoto":{"thumbnails":[\#(entries)]}"#
    }

    // MARK: - Full response

    @Test("the full fixture gives name, handle and the largest photo")
    func fullFixture() throws {
        let account = try #require(try InnerTubeParser.accountInfo(from: MusicFixtures.data("account-menu.json")))
        #expect(account.name == "Test Listener")
        #expect(account.handle == "@testlistener")
        #expect(account.photoURL?.absoluteString == "https://photos.example.test/avatar=s512-c-k-c0x00ffffff-no-rj")
    }

    @Test("a name split over several runs is joined")
    func multiRunName() throws {
        let data = menu(header: #"{"accountName":{"runs":[{"text":"Test "},{"text":"Listener"}]}}"#)
        #expect(try InnerTubeParser.accountInfo(from: data)?.name == "Test Listener")
    }

    // MARK: - Optional parts

    @Test("no handle gives a nil handle and keeps the name and photo")
    func noHandle() throws {
        let data = menu(header: """
        {"accountName":{"runs":[{"text":"Plain Account"}]},\(photo(#"{"url":"https://photos.example.test/a","width":88,"height":88}"#))}
        """)
        let account = try #require(try InnerTubeParser.accountInfo(from: data))
        #expect(account.name == "Plain Account")
        #expect(account.handle == nil)
        #expect(account.photoURL?.absoluteString == "https://photos.example.test/a")
    }

    @Test("a blank handle counts as no handle")
    func blankHandle() throws {
        let data = menu(header: #"{"accountName":{"runs":[{"text":"Plain Account"}]},"channelHandle":{"runs":[{"text":"  "}]}}"#)
        #expect(try InnerTubeParser.accountInfo(from: data)?.handle == nil)
    }

    @Test("no photo gives a nil photo URL")
    func noPhoto() throws {
        let data = menu(header: #"{"accountName":{"runs":[{"text":"No Photo"}]},"channelHandle":{"runs":[{"text":"@nophoto"}]}}"#)
        let account = try #require(try InnerTubeParser.accountInfo(from: data))
        #expect(account.photoURL == nil)
        #expect(account.handle == "@nophoto")
    }

    @Test("a thumbnail without a width still counts when it is the only one")
    func photoWithoutWidth() throws {
        let data = menu(header: """
        {"accountName":{"runs":[{"text":"A"}]},\(photo(#"{"url":"https://photos.example.test/only"}"#))}
        """)
        #expect(try InnerTubeParser.accountInfo(from: data)?.photoURL?.absoluteString == "https://photos.example.test/only")
    }

    // MARK: - Photo URLs

    @Test("a protocol-relative photo URL becomes https")
    func protocolRelativePhoto() throws {
        let data = menu(header: """
        {"accountName":{"runs":[{"text":"A"}]},\(photo(#"{"url":"//photos.example.test/avatar=s88","width":88,"height":88}"#))}
        """)
        #expect(try InnerTubeParser.accountInfo(from: data)?.photoURL?.absoluteString == "https://photos.example.test/avatar=s88")
    }

    @Test("the largest photo wins even when it is protocol-relative")
    func largestRelativePhoto() throws {
        let small = #"{"url":"https://photos.example.test/small","width":48,"height":48}"#
        let large = #"{"url":"//photos.example.test/large","width":256,"height":256}"#
        let data = menu(header: """
        {"accountName":{"runs":[{"text":"A"}]},\(photo(small + "," + large))}
        """)
        #expect(try InnerTubeParser.accountInfo(from: data)?.photoURL?.absoluteString == "https://photos.example.test/large")
    }

    @Test("a photo URL that is not https (http, file, script) is dropped, the account still parses")
    func unsafePhotoSchemes() throws {
        for url in ["http://photos.example.test/a", "file:///etc/passwd", "javascript:alert(1)", "data:text/plain,hi", ""] {
            let data = menu(header: """
            {"accountName":{"runs":[{"text":"A"}]},\(photo(#"{"url":"\#(url)","width":88,"height":88}"#))}
            """)
            let account = try #require(try InnerTubeParser.accountInfo(from: data))
            #expect(account.name == "A")
            #expect(account.photoURL == nil)
        }
    }

    // MARK: - Missing or moved renderer

    @Test("a response without the account header gives nil, not an error")
    func rendererMissing() throws {
        let data = Data(#"{"actions":[{"openPopupAction":{"popup":{"multiPageMenuRenderer":{"sections":[]}}}}]}"#.utf8)
        #expect(try InnerTubeParser.accountInfo(from: data) == nil)
    }

    @Test("an empty JSON object gives nil")
    func emptyObject() throws {
        #expect(try InnerTubeParser.accountInfo(from: Data("{}".utf8)) == nil)
    }

    @Test("a header with no readable name gives nil")
    func noName() throws {
        for header in [#"{}"#, #"{"accountName":{"runs":[]}}"#, #"{"accountName":{"runs":[{"text":"   "}]}}"#, #"{"accountName":"flat"}"#] {
            #expect(try InnerTubeParser.accountInfo(from: menu(header: header)) == nil)
        }
    }

    @Test("the renderer is found when YouTube nests the popup differently")
    func movedRenderer() throws {
        let json = """
        {"wrapper":[{"deeper":{"popup":{"multiPageMenuRenderer":{"header":{"activeAccountHeaderRenderer":\
        {"accountName":{"runs":[{"text":"Moved"}]},"channelHandle":{"runs":[{"text":"@moved"}]}}}}}}}]}
        """
        let account = try #require(try InnerTubeParser.accountInfo(from: Data(json.utf8)))
        #expect(account.name == "Moved")
        #expect(account.handle == "@moved")
    }

    @Test("unicode names and emoji pass through untouched")
    func unicodeName() throws {
        let data = menu(header: #"{"accountName":{"runs":[{"text":"Ünïcödé 音楽 🎵"}]},"channelHandle":{"runs":[{"text":"@ünï"}]}}"#)
        let account = try #require(try InnerTubeParser.accountInfo(from: data))
        #expect(account.name == "Ünïcödé 音楽 \u{1F3B5}")
        #expect(account.handle == "@ünï")
    }

    // MARK: - Bad input

    @Test("data that is not a JSON object throws a parse error")
    func notJSON() {
        for bad in ["", "not json", "[]", "42"] {
            #expect(throws: MusicError.self) { try InnerTubeParser.accountInfo(from: Data(bad.utf8)) }
        }
    }
}
