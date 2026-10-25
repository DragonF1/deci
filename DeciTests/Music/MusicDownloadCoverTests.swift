// DeciTests/Music/MusicDownloadCoverTests.swift
// The pieces of cover saving that need no folder: the file name a cover URL gets, the small size asked for, and what the
// live fetcher accepts as an image. Saving the files and cleaning them up is tested with the store and the service.

import Foundation
import Testing
@testable import Deci

@Suite("MusicDownloadCovers")
struct MusicDownloadCoverTests {
    private func url(_ text: String) -> URL { URL(string: text)! }

    @Test("a cover is named by a hash of its URL: the same URL always, a different one never")
    func nameIsAHash() {
        let first = MusicDownloadCovers.name(for: url("https://lh3.googleusercontent.com/a=w544-h544"))
        let again = MusicDownloadCovers.name(for: url("https://lh3.googleusercontent.com/a=w544-h544"))
        let other = MusicDownloadCovers.name(for: url("https://lh3.googleusercontent.com/b=w544-h544"))

        #expect(first == again)
        #expect(first != other)
        #expect(first.hasSuffix(".img"))
        #expect(first.dropLast(4).count == 64)
        #expect(first.dropLast(4).allSatisfy { "0123456789abcdef".contains($0) })
    }

    @Test("the name is safe as a file name, whatever the URL holds")
    func nameIsSafe() {
        for text in [
            "https://example.test/../../etc/passwd", "https://example.test/a%20b/c?d=e&f=g#h", "https://example.test/%F0%9F%8E%B5",
        ] {
            let name = MusicDownloadCovers.name(for: url(text))
            #expect(MusicDownloadStore.isValidCoverName(name), "\(text)")
            #expect(!name.contains("/"))
        }
    }

    @Test("the store accepts the names the covers get and no others")
    func validNames() {
        #expect(MusicDownloadStore.isValidCoverName(MusicDownloadCovers.name(for: url("https://example.test/x"))))
        for name in ["", ".img", "abc", "abc.png", "ABC.img", "../a.img", "a/b.img", "zz.img", "abc.img "] {
            #expect(!MusicDownloadStore.isValidCoverName(name), "\(name)")
        }
        #expect(MusicDownloadStore.isValidCoverName("0a1b.img"))
    }

    // MARK: - Size

    @Test("a cover is fetched small: width and height, or square, on a Google image host")
    func smallSizes() {
        func small(_ text: String) -> String { MusicArtworkURL.small(url(text)).absoluteString }

        #expect(small("https://lh3.googleusercontent.com/abc=w544-h544-l90-rj") == "https://lh3.googleusercontent.com/abc=w226-h226-l90-rj")
        #expect(small("https://lh3.googleusercontent.com/abc=w60-h60") == "https://lh3.googleusercontent.com/abc=w226-h226")
        #expect(small("https://yt3.ggpht.com/abc=s512-c-k-c0x00ffffff-no-rj") == "https://yt3.ggpht.com/abc=s226-c-k-c0x00ffffff-no-rj")
        #expect(MusicArtworkURL.smallEdge == 226)
    }

    @Test("a URL that cannot be sized is fetched as given")
    func smallLeavesTheRest() {
        for text in [
            "https://i.ytimg.com/vi/abc/sddefault.jpg?sqp=xyz=w120",
            "https://img.example.test/a=w60-h60",
            "https://lh3.googleusercontent.com/abc",
            "https://lh3.googleusercontent.com/abc=rj",
        ] {
            #expect(MusicArtworkURL.small(url(text)).absoluteString == text)
        }
    }

    @Test("the large size the lock screen asks for is still 544")
    func largeUnchanged() {
        let sized = MusicArtworkURL.large(url("https://lh3.googleusercontent.com/abc=w120-h120-l90-rj"))

        #expect(sized.absoluteString == "https://lh3.googleusercontent.com/abc=w544-h544-l90-rj")
    }

    // MARK: - The live fetcher

    private func response(_ status: Int, for text: String = "https://lh3.googleusercontent.com/a") -> HTTPURLResponse {
        HTTPURLResponse(url: url(text), statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    @Test("an image is a 200 with some bytes, and nothing else is")
    func acceptsOnlyAnImage() throws {
        let bytes = Data([1, 2, 3])

        #expect(try URLSessionCoverFetcher.accept(bytes, from: response(200)) == bytes)
        #expect(throws: (any Error).self) { try URLSessionCoverFetcher.accept(bytes, from: response(404)) }
        #expect(throws: (any Error).self) { try URLSessionCoverFetcher.accept(bytes, from: response(429)) }
        #expect(throws: (any Error).self) { try URLSessionCoverFetcher.accept(Data(), from: response(200)) }
        #expect(throws: (any Error).self) {
            try URLSessionCoverFetcher.accept(Data(count: URLSessionCoverFetcher.maxBytes + 1), from: response(200))
        }
        #expect(throws: (any Error).self) {
            try URLSessionCoverFetcher.accept(bytes, from: URLResponse(url: url("https://x.test/"), mimeType: nil, expectedContentLength: 3, textEncodingName: nil))
        }
    }

    @Test("the live fetcher refuses a URL that is not https before it asks for anything")
    func refusesPlainHTTP() async {
        await #expect(throws: (any Error).self) {
            try await URLSessionCoverFetcher().fetch(url("http://lh3.googleusercontent.com/a"))
        }
        await #expect(throws: (any Error).self) {
            try await URLSessionCoverFetcher().fetch(url("file:///etc/passwd"))
        }
    }
}
