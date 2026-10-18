// DeciTests/Music/MusicAvatarModelTests.swift
// The account photo behind the avatar views: loaded in memory only, through the cookie-less
// cache-less session cover art uses, gone the moment the URL changes or goes away, and never
// landing after its load was cancelled or replaced.

import AppKit
import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("MusicAvatarModel")
struct MusicAvatarModelTests {
    private static let photo = URL(string: "https://photos.example.test/alice")!
    private static let otherPhoto = URL(string: "https://photos.example.test/bob")!

    /// A real PNG, so the model decodes it the way it would a downloaded photo.
    private static func png(side: Int = 4) -> Data {
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: side,
            pixelsHigh: side,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        return bitmap.representation(using: .png, properties: [:])!
    }

    /// Records every URL asked for, answers from `answers` (nothing for an unknown URL) and holds a URL at its gate until it opens.
    private final class Fetches: @unchecked Sendable {
        private let lock = NSLock()
        private var asked: [URL] = []
        private let answers: [URL: Data]
        private let held: [URL: MusicTestGate]

        init(_ answers: [URL: Data] = [:], held: [URL: MusicTestGate] = [:]) {
            self.answers = answers
            self.held = held
        }

        var urls: [URL] { lock.withLock { asked } }

        func fetch(_ url: URL) async -> Data? {
            lock.withLock { asked.append(url) }
            if let gate = held[url] { await gate.wait() }
            return answers[url]
        }
    }

    private func model(_ fetches: Fetches) -> MusicAvatarModel {
        MusicAvatarModel(fetch: { await fetches.fetch($0) })
    }

    /// Polls until `condition` holds; for a load parked at a gate.
    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<400 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    // MARK: Loading

    @Test("the photo at the URL is fetched once, as given, and decoded")
    func loadsPhoto() async {
        let fetches = Fetches([Self.photo: Self.png(side: 6)])
        let model = model(fetches)
        await model.load(Self.photo)
        #expect(fetches.urls == [Self.photo])
        #expect(model.image?.size.width == 6)
    }

    @Test("no URL shows no photo and fetches nothing")
    func nilURL() async {
        let fetches = Fetches()
        let model = model(fetches)
        await model.load(nil)
        #expect(model.image == nil)
        #expect(fetches.urls.isEmpty)
    }

    @Test("a failed fetch leaves no photo")
    func fetchFails() async {
        let model = model(Fetches())
        await model.load(Self.photo)
        #expect(model.image == nil)
    }

    @Test("bytes that are not an image leave no photo")
    func notAnImage() async {
        let model = model(Fetches([Self.photo: Data("<html>not a photo</html>".utf8)]))
        await model.load(Self.photo)
        #expect(model.image == nil)
    }

    @Test("an empty answer leaves no photo")
    func emptyData() async {
        let model = model(Fetches([Self.photo: Data()]))
        await model.load(Self.photo)
        #expect(model.image == nil)
    }

    // MARK: Dropping

    @Test("the URL going away (sign-out) drops the photo")
    func urlBecomesNil() async {
        let model = model(Fetches([Self.photo: Self.png()]))
        await model.load(Self.photo)
        #expect(model.image != nil)
        await model.load(nil)
        #expect(model.image == nil)
    }

    @Test("a new URL (a swap) drops the old photo, so a photo that fails to load never leaves the old one on screen")
    func urlChanges() async {
        let fetches = Fetches([Self.photo: Self.png()])
        let model = model(fetches)
        await model.load(Self.photo)
        #expect(model.image != nil)

        // The new photo cannot be fetched: the old one must not stay on screen.
        await model.load(Self.otherPhoto)
        #expect(model.image == nil)
        #expect(fetches.urls == [Self.photo, Self.otherPhoto])
    }

    @Test("the old photo is gone as soon as a load for a new URL starts, before it answers")
    func droppedWhileLoading() async {
        let gate = MusicTestGate()
        let fetches = Fetches(
            [Self.photo: Self.png(), Self.otherPhoto: Self.png()],
            held: [Self.otherPhoto: gate]
        )
        let model = model(fetches)
        await model.load(Self.photo)
        #expect(model.image != nil)

        let load = Task { await model.load(Self.otherPhoto) }
        let asked = await eventually { fetches.urls.count == 2 }
        #expect(asked)
        #expect(model.image == nil)
        await gate.open()
        await load.value
        #expect(model.image != nil)
    }

    // MARK: Cancelling

    @Test("a load cancelled while the fetch is out never lands, even if the bytes arrive")
    func cancelledLoadDoesNotLand() async {
        let gate = MusicTestGate()
        let fetches = Fetches([Self.photo: Self.png()], held: [Self.photo: gate])
        let model = model(fetches)
        let load = Task { await model.load(Self.photo) }
        let asked = await eventually { fetches.urls.count == 1 }
        #expect(asked)

        load.cancel()
        await gate.open()
        await load.value
        #expect(model.image == nil)
    }

    @Test("a cancelled load for an old URL cannot overwrite the photo of the URL that replaced it")
    func cancelledLoadLosesToNewer() async {
        let gate = MusicTestGate()
        let fetches = Fetches(
            [Self.photo: Self.png(side: 9), Self.otherPhoto: Self.png(side: 5)],
            held: [Self.photo: gate]
        )
        let model = model(fetches)
        let stale = Task { await model.load(Self.photo) }
        let asked = await eventually { fetches.urls.count == 1 }
        #expect(asked)

        stale.cancel()
        await model.load(Self.otherPhoto)
        #expect(model.image?.size.width == 5)

        await gate.open()
        await stale.value
        #expect(model.image?.size.width == 5)
    }

    @Test("an older load that was never cancelled still loses to the newer one")
    func olderLoadLosesToNewer() async {
        let gate = MusicTestGate()
        let fetches = Fetches(
            [Self.photo: Self.png(side: 9), Self.otherPhoto: Self.png(side: 5)],
            held: [Self.photo: gate]
        )
        let model = model(fetches)
        let older = Task { await model.load(Self.photo) }
        let asked = await eventually { fetches.urls.count == 1 }
        #expect(asked)

        await model.load(Self.otherPhoto)
        await gate.open()
        await older.value
        #expect(model.image?.size.width == 5)
    }

    // MARK: The session

    @Test("the real fetcher's session has no URL cache and no cookies, so the photo URL never reaches Cache.db")
    func sessionHasNoCache() {
        let configuration = NowPlayingController.artworkSession.configuration
        #expect(configuration.urlCache == nil)
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.httpShouldSetCookies == false)
    }

    @Test("the default fetcher only takes https")
    func defaultFetcherIsHTTPSOnly() async {
        let model = MusicAvatarModel()
        await model.load(URL(string: "http://photos.example.test/alice")!)
        #expect(model.image == nil)
    }
}
