// DeciTests/Music/NowPlayingControllerTests.swift
// The Now Playing widget and media keys: the pure state-to-dictionary mapping, lazy command
// registration, release on deactivate and the cover art download with its tiny cache.

import AppKit
import Foundation
import MediaPlayer
import Testing
@testable import Deci

@MainActor
private final class FetchLog {
    var urls: [URL] = []
    var data: Data?
    var gate: MusicTestGate?
    /// URLs whose download fails.
    var failing: Set<URL> = []
}

private func pngData() -> Data {
    let image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
        NSColor.red.setFill()
        rect.fill()
        return true
    }
    let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
    return rep.representation(using: .png, properties: [:])!
}

private func state(
    _ track: Deci.MusicTrack = MusicSamples.track("a", title: "Aerodynamic", artist: "Daft Punk"),
    elapsed: TimeInterval = 42.5,
    duration: TimeInterval = 187,
    isPlaying: Bool = true
) -> NowPlayingState {
    NowPlayingState(track: track, elapsed: elapsed, duration: duration, isPlaying: isPlaying)
}

private func track(_ id: String, art: String?) -> Deci.MusicTrack {
    Deci.MusicTrack(
        videoId: id, title: "Song \(id)", artist: "Artist", album: nil, durationSeconds: 200,
        thumbnailURL: art.flatMap { URL(string: $0) }
    )
}

// MARK: - Mapping

@MainActor
@Suite("NowPlayingInfo mapping")
struct NowPlayingInfoTests {
    @Test("title, artist, duration, elapsed and rate map to the MediaPlayer keys")
    func fullMapping() {
        let info = NowPlayingInfo.dictionary(for: state(
            Deci.MusicTrack(videoId: "a", title: "Aerodynamic", artist: "Daft Punk", album: "Discovery", durationSeconds: 212, thumbnailURL: nil)
        ))
        #expect(info[MPMediaItemPropertyTitle] as? String == "Aerodynamic")
        #expect(info[MPMediaItemPropertyArtist] as? String == "Daft Punk")
        #expect(info[MPMediaItemPropertyAlbumTitle] as? String == "Discovery")
        #expect(info[MPMediaItemPropertyPlaybackDuration] as? Double == 187)
        #expect(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == 42.5)
        #expect(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 1)
        #expect(info[MPNowPlayingInfoPropertyDefaultPlaybackRate] as? Double == 1)
        #expect(info[MPNowPlayingInfoPropertyMediaType] as? UInt == MPNowPlayingInfoMediaType.audio.rawValue)
        #expect(info[MPMediaItemPropertyArtwork] == nil)
    }

    @Test("paused means rate 0")
    func pausedRate() {
        let info = NowPlayingInfo.dictionary(for: state(isPlaying: false))
        #expect(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 0)
    }

    @Test("a missing or empty album is left out")
    func albumOmitted() {
        #expect(NowPlayingInfo.dictionary(for: state())[MPMediaItemPropertyAlbumTitle] == nil)
        let empty = Deci.MusicTrack(videoId: "a", title: "T", artist: "A", album: "", durationSeconds: nil, thumbnailURL: nil)
        #expect(NowPlayingInfo.dictionary(for: state(empty))[MPMediaItemPropertyAlbumTitle] == nil)
    }

    @Test("an unknown duration is left out and elapsed is not capped")
    func unknownDuration() {
        let info = NowPlayingInfo.dictionary(for: state(duration: 0))
        #expect(info[MPMediaItemPropertyPlaybackDuration] == nil)
        #expect(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == 42.5)
    }

    @Test("elapsed is clamped to zero and the duration, and non-finite values read as zero")
    func elapsedClamped() {
        #expect(NowPlayingInfo.dictionary(for: state(elapsed: -5))[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == 0)
        #expect(NowPlayingInfo.dictionary(for: state(elapsed: 999))[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == 187)
        #expect(NowPlayingInfo.dictionary(for: state(elapsed: .nan))[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == 0)
        #expect(NowPlayingInfo.dictionary(for: state(duration: .infinity))[MPMediaItemPropertyPlaybackDuration] == nil)
    }

    @Test("artwork is included when given")
    func artworkIncluded() throws {
        let image = try #require(NSImage(data: pngData()))
        let info = NowPlayingInfo.dictionary(for: state(), artwork: ArtworkFactory.make(image: image))
        #expect(info[MPMediaItemPropertyArtwork] is MPMediaItemArtwork)
    }

    @Test("the artwork is as large as the image and resizes to the size the system asks for")
    func artworkSizeHandler() throws {
        let image = try #require(NSImage(data: pngData()))
        #expect(ArtworkFactory.make(image: image).bounds.size == image.size)

        let scaled = ArtworkFactory.sized(image, to: CGSize(width: 32, height: 32))
        #expect(scaled.size == CGSize(width: 32, height: 32))
        #expect(scaled.cgImage(forProposedRect: nil, context: nil, hints: nil)?.width == 32)
        let huge = ArtworkFactory.sized(image, to: CGSize(width: 5000, height: 5000))
        #expect(huge.cgImage(forProposedRect: nil, context: nil, hints: nil)?.width == 1024)
        let wide = ArtworkFactory.sized(image, to: CGSize(width: 4000, height: 2000)).cgImage(forProposedRect: nil, context: nil, hints: nil)
        #expect(wide?.width == 1024)
        #expect(wide?.height == 512)
        #expect(ArtworkFactory.sized(image, to: CGSize(width: CGFloat.nan, height: 10)) === image)
        #expect(ArtworkFactory.sized(image, to: CGSize(width: CGFloat.infinity, height: 10)) === image)
        #expect(ArtworkFactory.sized(image, to: image.size) === image)
        #expect(ArtworkFactory.sized(image, to: .zero) === image)
        #expect(ArtworkFactory.sized(image, to: CGSize(width: -4, height: 10)) === image)
    }
}

// MARK: - Controller

@MainActor
@Suite("NowPlayingController")
struct NowPlayingControllerTests {
    private struct Rig {
        let surface = FakeNowPlayingSurface()
        let fetch = FetchLog()
        let controller: NowPlayingController

        init() {
            let surface = self.surface
            let fetch = self.fetch
            fetch.data = pngData()
            controller = NowPlayingController(surface: surface, fetchArtwork: { url in
                await MainActor.run { fetch.urls.append(url) }
                let gate = await MainActor.run { fetch.gate }
                if let gate { await gate.wait() }
                return await MainActor.run { fetch.failing.contains(url) ? nil : fetch.data }
            })
        }
    }

    @Test("nothing reaches the system until the first update")
    func lazy() {
        let rig = Rig()
        #expect(rig.surface.registerCount == 0)
        #expect(rig.surface.published.isEmpty)
        rig.controller.update(nil)
        #expect(rig.surface.registerCount == 0)
        #expect(rig.surface.clearCount == 0)
        #expect(rig.surface.removeCount == 0)
    }

    @Test("the first update registers the commands once and publishes the state")
    func firstUpdateRegisters() {
        let rig = Rig()
        rig.controller.update(state())
        rig.controller.update(state(elapsed: 50))
        rig.controller.update(state(MusicSamples.track("b", title: "Next")))

        #expect(rig.surface.registerCount == 1)
        #expect(rig.surface.published.count == 3)
        #expect(rig.surface.last?.title == "Next")
    }

    @Test("an unchanged state is not published again")
    func unchangedSkipped() {
        let rig = Rig()
        rig.controller.update(state())
        rig.controller.update(state())
        #expect(rig.surface.published.count == 1)
    }

    @Test("play state reaches the surface")
    func playbackState() {
        let rig = Rig()
        rig.controller.update(state(isPlaying: true))
        rig.controller.update(state(isPlaying: false))
        #expect(rig.surface.published.map(\.isPlaying) == [true, false])
    }

    @Test("update(nil) removes the commands and clears the info once")
    func deactivate() {
        let rig = Rig()
        rig.controller.update(state())
        rig.controller.update(nil)
        rig.controller.update(nil)

        #expect(rig.surface.removeCount == 1)
        #expect(rig.surface.clearCount == 1)
        #expect(rig.surface.hasCommands == false)
    }

    @Test("playing again after a release registers again")
    func reactivate() {
        let rig = Rig()
        rig.controller.update(state())
        rig.controller.update(nil)
        rig.controller.update(state())
        #expect(rig.surface.registerCount == 2)
        #expect(rig.surface.published.count == 2)
    }

    @Test("commands from the system reach onCommand")
    func commandsForwarded() {
        let rig = Rig()
        var seen: [NowPlayingCommand] = []
        rig.controller.onCommand = { seen.append($0) }
        rig.controller.update(state())
        rig.surface.send(.next)
        rig.surface.send(.seek(12))
        #expect(seen == [.next, .seek(12)])
    }

    // MARK: Artwork

    @Test("artwork is downloaded once per URL and added to the info")
    func artworkDownloaded() async {
        let rig = Rig()
        let withArt = track("a", art: "https://img.example.test/a.jpg")
        rig.controller.update(state(withArt))
        #expect(rig.surface.last?.info[MPMediaItemPropertyArtwork] == nil)
        await rig.controller.artworkTask?.value

        #expect(rig.fetch.urls == [withArt.thumbnailURL!])
        #expect(rig.surface.last?.info[MPMediaItemPropertyArtwork] is MPMediaItemArtwork)

        rig.controller.update(state(withArt, elapsed: 90))
        #expect(rig.fetch.urls.count == 1)
        #expect(rig.surface.last?.info[MPMediaItemPropertyArtwork] is MPMediaItemArtwork)
    }

    @Test("coming back to a track reuses the cached artwork")
    func artworkCached() async {
        let rig = Rig()
        let first = track("a", art: "https://img.example.test/a.jpg")
        let second = track("b", art: "https://img.example.test/b.jpg")
        rig.controller.update(state(first))
        await rig.controller.artworkTask?.value
        rig.controller.update(state(second))
        await rig.controller.artworkTask?.value
        rig.controller.update(state(first))

        #expect(rig.fetch.urls.count == 2)
        #expect(rig.surface.last?.info[MPMediaItemPropertyArtwork] is MPMediaItemArtwork)
    }

    @Test("a download that finishes after the track changed does not publish the old cover")
    func staleArtworkDoesNotPublish() async {
        let rig = Rig()
        let gate = MusicTestGate()
        rig.fetch.gate = gate
        rig.controller.update(state(track("a", art: "https://img.example.test/a.jpg")))
        let stale = rig.controller.artworkTask

        rig.controller.update(state(track("b", art: nil)))
        await gate.open()
        await stale?.value

        #expect(rig.surface.last?.title == "Song b")
        #expect(rig.surface.last?.info[MPMediaItemPropertyArtwork] == nil)
    }

    @Test("a failed or undecodable download leaves the info without artwork and is not retried")
    func artworkFailure() async {
        let rig = Rig()
        rig.fetch.data = Data([0, 1, 2])
        let broken = track("a", art: "https://img.example.test/a.jpg")
        rig.controller.update(state(broken))
        await rig.controller.artworkTask?.value
        rig.controller.update(state(broken, elapsed: 60))

        #expect(rig.fetch.urls.count == 1)
        #expect(rig.surface.last?.info[MPMediaItemPropertyArtwork] == nil)
        #expect(rig.surface.last?.elapsed == 60)
    }

    @Test("YouTube Music cover art is fetched at 544 px")
    func artworkLargeFirst() async {
        let rig = Rig()
        let small = "https://lh3.googleusercontent.com/abc=w60-h60-l90-rj"
        rig.controller.update(state(track("a", art: small)))
        await rig.controller.artworkTask?.value

        #expect(rig.fetch.urls == [URL(string: "https://lh3.googleusercontent.com/abc=w544-h544-l90-rj")!])
        #expect(rig.surface.last?.info[MPMediaItemPropertyArtwork] is MPMediaItemArtwork)
    }

    @Test("when the 544 px cover fails the list thumbnail is used instead")
    func artworkLargeFallback() async {
        let rig = Rig()
        let small = URL(string: "https://lh3.googleusercontent.com/abc=w60-h60-l90-rj")!
        let large = URL(string: "https://lh3.googleusercontent.com/abc=w544-h544-l90-rj")!
        rig.fetch.failing = [large]
        rig.controller.update(state(track("a", art: small.absoluteString)))
        await rig.controller.artworkTask?.value

        #expect(rig.fetch.urls == [large, small])
        #expect(rig.surface.last?.info[MPMediaItemPropertyArtwork] is MPMediaItemArtwork)
    }

    @Test("a track without a thumbnail never downloads anything")
    func noThumbnail() {
        let rig = Rig()
        rig.controller.update(state(track("a", art: nil)))
        #expect(rig.controller.artworkTask == nil)
        #expect(rig.fetch.urls.isEmpty)
    }

    @Test("only https artwork is fetched over the network")
    func httpsOnly() async {
        let plain = await NowPlayingController.fetchOverNetwork(URL(string: "http://img.example.test/a.jpg")!)
        let file = await NowPlayingController.fetchOverNetwork(URL(fileURLWithPath: "/etc/hosts"))
        #expect(plain == nil)
        #expect(file == nil)
    }

    // MARK: Release

    @Test("dropping a controller that is registered releases the commands and the widget")
    func deinitReleases() async {
        let surface = FakeNowPlayingSurface()
        do {
            let controller = NowPlayingController(surface: surface, fetchArtwork: { _ in nil })
            controller.update(state())
            #expect(surface.hasCommands)
        }
        await Task.yield()

        #expect(surface.removeCount == 1)
        #expect(surface.clearCount == 1)
        #expect(surface.hasCommands == false)
    }

    @Test("dropping a controller that never registered, or already released, touches nothing")
    func deinitWhenIdle() async {
        let surface = FakeNowPlayingSurface()
        do {
            _ = NowPlayingController(surface: surface, fetchArtwork: { _ in nil })
        }
        let released = FakeNowPlayingSurface()
        do {
            let controller = NowPlayingController(surface: released, fetchArtwork: { _ in nil })
            controller.update(state())
            controller.update(nil)
        }
        await Task.yield()

        #expect(surface.removeCount == 0)
        #expect(surface.clearCount == 0)
        #expect(released.removeCount == 1)
        #expect(released.clearCount == 1)
    }
}

// MARK: - System surface

@MainActor
@Suite("SystemNowPlayingSurface delivery")
struct SystemNowPlayingSurfaceTests {
    @Test("a command that arrives on the main thread is still handled on a later turn, never inside the system call")
    func deliverAlwaysHops() async {
        var seen: [NowPlayingCommand] = []
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            SystemNowPlayingSurface.deliver(.next) { command in
                seen.append(command)
                done.resume()
            }
            #expect(seen.isEmpty)
        }
        #expect(seen == [.next])
    }

    @Test("a command that arrives on another thread reaches the handler on the main actor")
    func deliverFromBackground() async {
        let seen = await withCheckedContinuation { (done: CheckedContinuation<[NowPlayingCommand], Never>) in
            DispatchQueue.global().async {
                SystemNowPlayingSurface.deliver(.seek(9)) { command in
                    done.resume(returning: [command])
                }
            }
        }
        #expect(seen == [.seek(9)])
    }
}

// MARK: - Artwork URL

@Suite("MusicArtworkURL")
struct MusicArtworkURLTests {
    private func large(_ text: String) -> String { MusicArtworkURL.large(URL(string: text)!).absoluteString }

    @Test("width and height sizes on Google image hosts become 544, other options stay")
    func widthHeight() {
        #expect(large("https://lh3.googleusercontent.com/abc=w120-h120-l90-rj") == "https://lh3.googleusercontent.com/abc=w544-h544-l90-rj")
        #expect(large("https://yt3.googleusercontent.com/abc=w60-h60") == "https://yt3.googleusercontent.com/abc=w544-h544")
    }

    @Test("square sizes become 544")
    func square() {
        #expect(large("https://yt3.ggpht.com/abc=s88-c-k-c0x00ffffff-no-rj") == "https://yt3.ggpht.com/abc=s544-c-k-c0x00ffffff-no-rj")
    }

    @Test("other hosts and URLs without a size are left alone")
    func untouched() {
        let ytimg = "https://i.ytimg.com/vi/abc/sddefault.jpg?sqp=xyz=w120"
        #expect(large(ytimg) == ytimg)
        #expect(large("https://img.example.test/a=w60-h60") == "https://img.example.test/a=w60-h60")
        #expect(large("https://lh3.googleusercontent.com/abc") == "https://lh3.googleusercontent.com/abc")
        #expect(large("https://lh3.googleusercontent.com/abc=rj") == "https://lh3.googleusercontent.com/abc=rj")
    }
}
