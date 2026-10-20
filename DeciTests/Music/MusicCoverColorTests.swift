// DeciTests/Music/MusicCoverColorTests.swift
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import Deci

/// A solid picture, encoded as PNG, for the cover colour tests. Invented pixels; nothing is fetched.
private func solidPNG(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8 = 255, side: Int = 40) -> Data {
    var pixels = [UInt8](repeating: 0, count: side * side * 4)
    let premultiplied: (UInt8) -> UInt8 = { UInt8((Int($0) * Int(alpha) + 127) / 255) }
    for index in stride(from: 0, to: pixels.count, by: 4) {
        pixels[index] = premultiplied(red)
        pixels[index + 1] = premultiplied(green)
        pixels[index + 2] = premultiplied(blue)
        pixels[index + 3] = alpha
    }
    let image = pixels.withUnsafeMutableBytes { buffer -> CGImage? in
        CGContext(
            data: buffer.baseAddress,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )?.makeImage()
    }
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image!, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}

@MainActor
@Suite("MusicCoverColor")
struct MusicCoverColorTests {
    // MARK: - average

    @Test("the average of two pixels is their mean")
    func averageOfTwoPixels() throws {
        let rgb = try #require(MusicCoverColor.average(rgba: [255, 0, 0, 255, 0, 0, 255, 255]))
        #expect(abs(rgb.red - 0.5) < 0.0001)
        #expect(rgb.green == 0)
        #expect(abs(rgb.blue - 0.5) < 0.0001)
    }

    @Test("no pixels, a ragged length and fully transparent pixels have no average")
    func averageOfNothing() {
        #expect(MusicCoverColor.average(rgba: []) == nil)
        #expect(MusicCoverColor.average(rgba: [1, 2, 3, 255, 4]) == nil)
        #expect(MusicCoverColor.average(rgba: [255, 0, 0, 0, 0, 255, 0, 4]) == nil)
    }

    @Test("a half transparent pixel counts for half")
    func averageWeightsByAlpha() throws {
        // Opaque white and a half transparent black: (1 * 1 + 0 * 0.5) / 1.5.
        let rgb = try #require(MusicCoverColor.average(rgba: [255, 255, 255, 255, 0, 0, 0, 128]))
        #expect(abs(rgb.red - 255.0 / 383.0) < 0.01)
        #expect(rgb.red == rgb.green && rgb.green == rgb.blue)
    }

    @Test("a nearly transparent pixel is not a colour")
    func averageSkipsTransparentCorners() throws {
        let rgb = try #require(MusicCoverColor.average(rgba: [0, 0, 255, 255, 255, 0, 0, 3]))
        #expect(rgb == MusicCoverColor.RGB(red: 0, green: 0, blue: 1))
    }

    // MARK: - hsb

    @Test("hue, saturation and brightness of the primaries")
    func hsbOfPrimaries() {
        let red = MusicCoverColor.hsb(.init(red: 1, green: 0, blue: 0))
        #expect(red.hue == 0 && red.saturation == 1 && red.brightness == 1)
        let green = MusicCoverColor.hsb(.init(red: 0, green: 1, blue: 0))
        #expect(abs(green.hue - 1.0 / 3) < 0.0001)
        let blue = MusicCoverColor.hsb(.init(red: 0, green: 0, blue: 1))
        #expect(abs(blue.hue - 2.0 / 3) < 0.0001)
        let magenta = MusicCoverColor.hsb(.init(red: 1, green: 0, blue: 1))
        #expect(abs(magenta.hue - 5.0 / 6) < 0.0001)
    }

    @Test("a grey has no saturation and black has no brightness")
    func hsbOfGreys() {
        let grey = MusicCoverColor.hsb(.init(red: 0.5, green: 0.5, blue: 0.5))
        #expect(grey.saturation == 0 && grey.brightness == 0.5)
        let black = MusicCoverColor.hsb(.init(red: 0, green: 0, blue: 0))
        #expect(black.saturation == 0 && black.brightness == 0)
    }

    // MARK: - tint

    @Test("a neon colour is calmed to the saturation and brightness ceilings")
    func tintClampsDown() {
        let tint = MusicCoverColor.tint(of: .init(red: 1, green: 0, blue: 0))
        #expect(tint.hue == 0)
        #expect(tint.saturation == MusicCoverColor.saturationRange.upperBound)
        #expect(tint.brightness == MusicCoverColor.brightnessRange.upperBound)
    }

    @Test("a black or grey cover keeps a faint tint and a body")
    func tintClampsUp() {
        let black = MusicCoverColor.tint(of: .init(red: 0, green: 0, blue: 0))
        #expect(black.saturation == MusicCoverColor.saturationRange.lowerBound)
        #expect(black.brightness == MusicCoverColor.brightnessRange.lowerBound)
        let white = MusicCoverColor.tint(of: .init(red: 1, green: 1, blue: 1))
        #expect(white.saturation == MusicCoverColor.saturationRange.lowerBound)
        #expect(white.brightness == MusicCoverColor.brightnessRange.upperBound)
    }

    @Test("a colour inside the ranges is kept as it is")
    func tintKeepsMiddle() {
        let tint = MusicCoverColor.tint(of: .init(red: 0.6, green: 0.3, blue: 0.3))
        #expect(abs(tint.saturation - 0.5) < 0.0001)
        #expect(abs(tint.brightness - 0.6) < 0.0001)
    }

    @Test("RGBA pixels give the tint of their average, and no pixels give none")
    func tintOfPixels() throws {
        let tint = try #require(MusicCoverColor.tint(rgba: [100, 100, 200, 255, 100, 100, 200, 255]))
        #expect(abs(tint.hue - 2.0 / 3) < 0.0001)
        #expect(MusicCoverColor.tint(rgba: []) == nil)
    }

    // MARK: - Picture

    @Test("a solid picture gives its own hue, with the clamps applied")
    func tintOfPicture() throws {
        let tint = try #require(MusicCoverColor.tint(imageData: solidPNG(red: 200, green: 40, blue: 40)))
        #expect(tint.hue < 0.01 || tint.hue > 0.99)
        #expect(abs(tint.saturation - MusicCoverColor.saturationRange.upperBound) < 0.02)
        #expect(abs(tint.brightness - 200.0 / 255) < 0.03)
    }

    @Test("a blue picture reads blue")
    func tintOfBluePicture() throws {
        let tint = try #require(MusicCoverColor.tint(imageData: solidPNG(red: 30, green: 60, blue: 160, side: 7)))
        #expect(abs(tint.hue - 0.63) < 0.03)
    }

    @Test("a fully transparent picture and data that is not a picture have no tint")
    func tintOfNothing() {
        #expect(MusicCoverColor.tint(imageData: solidPNG(red: 255, green: 0, blue: 0, alpha: 0)) == nil)
        #expect(MusicCoverColor.tint(imageData: Data("not a picture".utf8)) == nil)
        #expect(MusicCoverColor.tint(imageData: Data()) == nil)
    }

    @Test("a thumbnail keeps the picture's shape, shrunk so its longer side is at most the limit")
    func thumbnailShrinks() throws {
        let image = try #require(MusicCoverColor.thumbnail(imageData: solidPNG(red: 10, green: 120, blue: 200, side: 300)))
        #expect(image.width == MusicCoverColor.thumbnailSide)
        #expect(image.height == MusicCoverColor.thumbnailSide)

        let small = try #require(MusicCoverColor.thumbnail(imageData: solidPNG(red: 10, green: 120, blue: 200, side: 300), maxPixelSize: 24))
        #expect(small.width == 24 && small.height == 24)
    }

    @Test("a thumbnail of data that is not a picture, empty data or a limit under 1 is nil")
    func thumbnailOfNothing() {
        #expect(MusicCoverColor.thumbnail(imageData: Data("not a picture".utf8)) == nil)
        #expect(MusicCoverColor.thumbnail(imageData: Data()) == nil)
        #expect(MusicCoverColor.thumbnail(imageData: solidPNG(red: 1, green: 2, blue: 3), maxPixelSize: 0) == nil)
    }

    @Test("unpremultiplying restores a straight colour and leaves opaque and clear pixels alone")
    func unpremultiply() {
        let out = MusicCoverColor.unpremultiplied([64, 32, 0, 128, 10, 20, 30, 255, 0, 0, 0, 0])
        #expect(out[0] == 127 || out[0] == 128)
        #expect(out[1] == 64 || out[1] == 63)
        #expect(out[2] == 0 && out[3] == 128)
        #expect(Array(out[4..<8]) == [10, 20, 30, 255])
        #expect(Array(out[8..<12]) == [0, 0, 0, 0])
    }
}

/// How often a fake cover fetch ran.
private actor FetchCounter {
    private(set) var count = 0
    func hit() -> Int {
        count += 1
        return count
    }
}

/// Counts the fetches a fake cover fetch started and how many it saw cancelled. Two event gates keep the tests off the
/// wall clock: one opens when a fetch starts, the other holds a fetch until the test lets it go. Neither has a deadline
/// of its own; the tests carry a time limit as the guard against a hang.
private actor FetchProbe {
    private(set) var startedCount = 0
    private(set) var cancelledCount = 0

    private let startEvents: AsyncStream<Void>
    private let startSignal: AsyncStream<Void>.Continuation
    private let releaseEvents: AsyncStream<Void>
    private let releaseSignal: AsyncStream<Void>.Continuation

    init() {
        let start = AsyncStream.makeStream(of: Void.self)
        startEvents = start.stream
        startSignal = start.continuation
        let release = AsyncStream.makeStream(of: Void.self)
        releaseEvents = release.stream
        releaseSignal = release.continuation
    }

    /// Returns which fetch this is, counting from 1.
    func started() -> Int {
        startedCount += 1
        startSignal.yield()
        return startedCount
    }

    func cancelled() { cancelledCount += 1 }

    /// Suspends until a fetch has started, however long that takes. False only if the waiting task was cancelled.
    func waitUntilStarted() async -> Bool {
        var events = startEvents.makeAsyncIterator()
        return await events.next() != nil
    }

    /// Called by a fetch to hold still until `release()`. False if the fetch was cancelled while it waited.
    func waitForRelease() async -> Bool {
        for await _ in releaseEvents {}
        return !Task.isCancelled
    }

    /// Lets every fetch waiting in `waitForRelease` go on, now and later.
    func release() { releaseSignal.finish() }
}

/// A clock the test moves by hand.
@MainActor
private final class TestClock {
    private(set) var date = Date(timeIntervalSinceReferenceDate: 1_000_000)
    func advance(_ seconds: TimeInterval) { date = date.addingTimeInterval(seconds) }
}

@MainActor
@Suite("MusicCoverTintStore")
struct MusicCoverTintStoreTests {
    private let red = solidPNG(red: 200, green: 40, blue: 40)
    private func url(_ name: String) -> URL { URL(string: "https://example.invalid/\(name)")! }

    @Test("a cover is fetched once and then served from the cache")
    func cachesPerURL() async throws {
        let counter = FetchCounter()
        let data = red
        let store = MusicCoverTintStore(fetch: { _ in
            _ = await counter.hit()
            return data
        })
        let first = try #require(await store.tint(for: url("a")))
        let second = try #require(await store.tint(for: url("a")))
        #expect(first == second)
        #expect(await counter.count == 1)
        #expect(store.cachedTint(for: url("a")) == first)
        #expect(store.count == 1)
    }

    @Test("a cover not looked at has no cached tint, and no URL has none")
    func cachedTintMisses() async {
        let store = MusicCoverTintStore(fetch: { _ in nil })
        #expect(store.cachedTint(for: url("never")) == nil)
        #expect(store.cachedTint(for: nil) == nil)
        #expect(await store.tint(for: nil) == nil)
    }

    @Test("the one fetch also keeps the cover's small picture, which is served without another fetch")
    func keepsThumbnail() async throws {
        let counter = FetchCounter()
        let data = solidPNG(red: 200, green: 40, blue: 40, side: 200)
        let store = MusicCoverTintStore(fetch: { _ in
            _ = await counter.hit()
            return data
        })
        #expect(store.cachedThumbnail(for: url("a")) == nil)
        #expect(store.cachedThumbnail(for: nil) == nil)
        _ = await store.tint(for: url("a"))
        let thumbnail = try #require(store.cachedThumbnail(for: url("a")))
        #expect(thumbnail.width == MusicCoverColor.thumbnailSide)
        #expect(await counter.count == 1)
    }

    @Test("the small picture goes with its cover when the store is full, and a failed cover has none")
    func thumbnailFollowsCover() async {
        let data = red
        let store = MusicCoverTintStore(fetch: { url in url.lastPathComponent == "dead" ? nil : data }, capacity: 1)
        _ = await store.tint(for: url("first"))
        #expect(store.cachedThumbnail(for: url("first")) != nil)
        _ = await store.tint(for: url("second"))
        #expect(store.cachedThumbnail(for: url("first")) == nil)
        #expect(store.cachedThumbnail(for: url("second")) != nil)
        _ = await store.tint(for: url("dead"))
        #expect(store.cachedThumbnail(for: url("dead")) == nil)
    }

    @Test("two asks for one cover at once share one fetch")
    func dedupesInFlight() async {
        let counter = FetchCounter()
        let data = red
        let store = MusicCoverTintStore(fetch: { _ in
            _ = await counter.hit()
            try? await Task.sleep(for: .milliseconds(40))
            return data
        })
        let target = url("shared")
        async let one = store.tint(for: target)
        async let two = store.tint(for: target)
        let (a, b) = await (one, two)
        #expect(a != nil && a == b)
        #expect(await counter.count == 1)
    }

    @Test("a failed fetch gives no tint and is not fetched again while it is fresh")
    func failureIsRemembered() async {
        let counter = FetchCounter()
        let store = MusicCoverTintStore(fetch: { _ in
            _ = await counter.hit()
            return nil
        })
        #expect(await store.tint(for: url("dead")) == nil)
        #expect(await store.tint(for: url("dead")) == nil)
        #expect(await store.tint(for: url("dead")) == nil)
        #expect(await counter.count == 1)
        #expect(store.count == 0)
        #expect(store.failureCount == 1)
    }

    @Test("a failed cover is tried again after its lifetime, and a success then clears the failure")
    func failureExpires() async {
        let counter = FetchCounter()
        let data = red
        let clock = TestClock()
        let store = MusicCoverTintStore(fetch: { _ in
            let attempt = await counter.hit()
            return attempt == 1 ? nil : data
        }, now: { clock.date })
        #expect(await store.tint(for: url("flaky")) == nil)
        clock.advance(MusicCoverTintStore.failureLifetime - 1)
        #expect(await store.tint(for: url("flaky")) == nil)
        #expect(await counter.count == 1)
        clock.advance(2)
        #expect(await store.tint(for: url("flaky")) != nil)
        #expect(await counter.count == 2)
        #expect(store.failureCount == 0)
    }

    @Test("past its capacity the failure list forgets the oldest dead cover first")
    func failureListIsBounded() async {
        let counter = FetchCounter()
        let store = MusicCoverTintStore(fetch: { _ in
            _ = await counter.hit()
            return nil
        }, failureCapacity: 2)
        for name in ["one", "two", "three"] { _ = await store.tint(for: url(name)) }
        #expect(store.failureCount == 2)
        #expect(await counter.count == 3)
        _ = await store.tint(for: url("three"))
        #expect(await counter.count == 3)
        _ = await store.tint(for: url("one"))
        #expect(await counter.count == 4)
    }

    @Test("the only caller cancelling cancels the fetch, which is not a failure and costs no decode", .timeLimit(.minutes(1)))
    func lastWaiterCancelsFetch() async throws {
        let probe = FetchProbe()
        let data = red
        let store = MusicCoverTintStore(fetch: { _ in
            await probe.started()
            do {
                try await Task.sleep(for: .seconds(10))
            } catch {
                await probe.cancelled()
                return nil
            }
            return data
        })
        let waiter = Task { await store.tint(for: url("left")) }
        try #require(await probe.waitUntilStarted())
        waiter.cancel()
        #expect(await waiter.value == nil)
        #expect(await probe.cancelledCount == 1)
        #expect(store.count == 0)
        #expect(store.failureCount == 0)
    }

    @Test("a fetch another caller still waits for keeps going when one caller cancels", .timeLimit(.minutes(1)))
    func otherWaiterKeepsFetch() async throws {
        let probe = FetchProbe()
        let data = red
        let store = MusicCoverTintStore(fetch: { _ in
            await probe.started()
            // Holds until the test lets it go, so the fetch cannot end before both callers have come and one has left.
            guard await probe.waitForRelease() else {
                await probe.cancelled()
                return nil
            }
            return data
        })
        let target = url("both")
        let leaving = Task { await store.tint(for: target) }
        try #require(await probe.waitUntilStarted())
        let staying = Task { await store.tint(for: target) }
        // Both callers and the cancellation's bookkeeping run on the main actor in the order they were queued, so the
        // second caller has joined the fetch before the first one is counted out.
        await Task.yield()
        leaving.cancel()
        await Task.yield()
        await probe.release()
        #expect(await staying.value != nil)
        _ = await leaving.value
        #expect(await probe.startedCount == 1)
        #expect(await probe.cancelledCount == 0)
        #expect(store.cachedTint(for: target) != nil)
    }

    @Test("after the last waiter left, asking again starts a fresh fetch", .timeLimit(.minutes(1)))
    func askAgainAfterCancel() async throws {
        let probe = FetchProbe()
        let data = red
        let store = MusicCoverTintStore(fetch: { _ in
            let attempt = await probe.started()
            if attempt == 1 {
                do { try await Task.sleep(for: .seconds(10)) } catch { return nil }
            }
            return data
        })
        let first = Task { await store.tint(for: url("again")) }
        try #require(await probe.waitUntilStarted())
        first.cancel()
        _ = await first.value
        #expect(await store.tint(for: url("again")) != nil)
        #expect(await probe.startedCount == 2)
    }

    @Test("data that is not a picture gives no tint and is not cached")
    func notAPicture() async {
        let store = MusicCoverTintStore(fetch: { _ in Data("nope".utf8) })
        #expect(await store.tint(for: url("text")) == nil)
        #expect(store.count == 0)
    }

    @Test("past its capacity the store drops the oldest cover first")
    func evictsOldest() async {
        let data = red
        let store = MusicCoverTintStore(fetch: { _ in data }, capacity: 2)
        _ = await store.tint(for: url("one"))
        _ = await store.tint(for: url("two"))
        _ = await store.tint(for: url("three"))
        #expect(store.count == 2)
        #expect(store.cachedTint(for: url("one")) == nil)
        #expect(store.cachedTint(for: url("two")) != nil)
        #expect(store.cachedTint(for: url("three")) != nil)
    }

    @Test("a capacity under 1 still holds one cover")
    func capacityBounds() async {
        let data = red
        let store = MusicCoverTintStore(fetch: { _ in data }, capacity: 0)
        _ = await store.tint(for: url("a"))
        _ = await store.tint(for: url("b"))
        #expect(store.count == 1)
        #expect(store.cachedTint(for: url("b")) != nil)
    }
}
