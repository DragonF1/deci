// DeciTests/Music/MusicServiceAutomixTests.swift
// The radio that follows a playlist or an album is YouTube's automix of it when the page has one, asked after the
// page's last song in the page's order; every other page and every tapped song still gets the plain radio.

import Foundation
import Testing
@testable import Deci

@MainActor
private struct AutomixServiceHarness {
    let backend = FakeMusicBackend()
    let engine = FakePlaybackEngine()
    let surface = FakeNowPlayingSurface()
    let clock = MutableClock()
    let player: MusicPlayer
    let service: MusicService

    /// `queueRetryDelay` is long by default, so a retry never fires inside an ordinary test.
    init(
        preferences: MusicPlaybackPreferences = MusicPlaybackPreferences(),
        queueRetryDelay: Duration = .seconds(60)
    ) {
        let engine = self.engine
        let clock = self.clock
        let player = MusicPlayer(engine: engine)
        self.player = player
        self.service = MusicService(
            backend: backend,
            player: player,
            presentSignIn: { _ in },
            presentChannelPicker: { _, _ in },
            closeSignInWindow: {},
            raiseSignInWindow: {},
            nowPlaying: NowPlayingController(surface: surface, fetchArtwork: { _ in nil }),
            now: { clock.now },
            preferences: preferences,
            savePreferences: { _ in },
            shuffleSeed: 1,
            queueRetryDelay: queueRetryDelay,
            refreshOnCreate: false
        )
    }

    /// Waits until the play and radio work started so far, including follow-ups they start, has finished.
    func settle() async {
        while true {
            let play = service.playTask
            let radio = service.radioTask
            await play?.value
            await radio?.value
            if service.playTask == play, service.radioTask == radio { break }
        }
    }

    /// Polls until `condition` holds; for work that is waiting out a retry and cannot be awaited.
    func eventually(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<400 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    func page(_ ids: [String], browseId: String = "VLPL1", audioPlaylistId: String? = nil) -> MusicBrowsePage {
        MusicSamples.page(
            browseId,
            tracks: ids.map { MusicSamples.track($0, title: "Song \($0)") },
            audioPlaylistId: audioPlaylistId
        )
    }

    /// Plays `tap` (the first row by default) from `page` and waits for the queue work.
    func start(_ page: MusicBrowsePage, tap: String? = nil) async {
        let id = tap ?? page.tracks[0].videoId
        service.play(MusicSamples.track(id, title: "Song \(id)"), in: page)
        await settle()
        engine.emit(.playingChanged(true))
    }

    /// Scripts the automix after `seed`: the seed itself first, as YouTube sends it, then `radio`.
    func setAutomix(after seed: String, _ radio: [String] = AutomixServiceHarness.radio) async {
        await backend.setAutomix(afterVideoId: seed, tracks: MusicSamples.tracks(seed) + radio.map { MusicSamples.track($0) })
    }

    static let radio = ["r1", "r2", "r3", "r4", "r5"]

    func call(_ afterVideoId: String, _ playlistId: String) -> FakeMusicBackend.AutoplayCall {
        FakeMusicBackend.AutoplayCall(afterVideoId: afterVideoId, playlistId: playlistId)
    }

    var queuedIDs: [String] { service.queue.tracks.map(\.videoId) }
    var stagedIDs: [String] { service.queue.autoplay.map(\.videoId) }
    var loadedIDs: [String] { engine.loads.map(\.stream.videoId) }

    var listing: MusicQueueListing {
        MusicQueueListing(
            queue: service.queue,
            listsNextLap: service.listsNextLap,
            listsAutoplay: service.playsAutoplay,
            autoplayIsOn: service.isAutoplayOn
        )
    }
}

@MainActor
@Suite("MusicService playlist automix")
struct MusicServiceAutomixTests {
    // MARK: - Which pages ask the automix

    @Test("a playlist asks the automix of its playlist after its last song, and stages what it answers")
    func playlist() async {
        let h = AutomixServiceHarness()
        await h.setAutomix(after: "c")
        await h.start(h.page(["a", "b", "c"]), tap: "c")

        #expect(await h.backend.autoplayCalls == [h.call("c", "PL1")])
        #expect(await h.backend.radioSeeds.isEmpty)
        #expect(h.queuedIDs == ["a", "b", "c"])
        #expect(h.service.queue.isPage)
        #expect(h.stagedIDs == AutomixServiceHarness.radio)
    }

    @Test("the automix is staged while the last songs play, listed in Up next, and joins the queue when the page runs out")
    func handsOver() async {
        let h = AutomixServiceHarness()
        await h.setAutomix(after: "c")
        await h.start(h.page(["a", "b", "c"]))

        #expect(await h.backend.autoplayCalls == [h.call("c", "PL1")])
        #expect(h.stagedIDs == AutomixServiceHarness.radio)
        #expect(h.listing.upcoming.map(\.videoId) == ["b", "c"] + AutomixServiceHarness.radio)
        #expect(h.listing.autoplayStart == 2)

        for _ in 0..<3 {
            h.service.next()
            await h.settle()
        }

        #expect(h.queuedIDs == ["a", "b", "c"] + AutomixServiceHarness.radio)
        #expect(h.service.queue.source == .radio(seedVideoId: "c"))
        #expect(h.service.queue.current?.videoId == "r1")
        #expect(h.service.queue.autoplay.isEmpty)
        #expect(h.loadedIDs == ["a", "b", "c", "r1"])
        #expect(h.listing.sourceLine == "From radio")
        #expect(await h.backend.autoplayCalls == [h.call("c", "PL1")])
    }

    @Test("an album asks the automix of its OLAK audio playlist")
    func album() async {
        let h = AutomixServiceHarness()
        await h.setAutomix(after: "c")
        await h.start(h.page(["a", "b", "c"], browseId: "MPREb_album", audioPlaylistId: "OLAK5uy_album"), tap: "c")

        #expect(await h.backend.autoplayCalls == [h.call("c", "OLAK5uy_album")])
        #expect(await h.backend.radioSeeds.isEmpty)
        #expect(h.stagedIDs == AutomixServiceHarness.radio)
    }

    @Test("an album with no audio playlist id gets the plain radio of its last song")
    func albumWithoutId() async {
        let h = AutomixServiceHarness()
        await h.backend.setRadio(seed: "c", tracks: MusicSamples.tracks("c", "r1", "r2"))
        await h.start(h.page(["a", "b", "c"], browseId: "MPREb_album"), tap: "c")

        #expect(await h.backend.autoplayCalls.isEmpty)
        #expect(await h.backend.radioSeeds == ["c"])
        #expect(h.stagedIDs == ["r1", "r2"])
    }

    @Test("an artist page gets the plain radio, even with an audio playlist id on it")
    func artistPage() async {
        let h = AutomixServiceHarness()
        await h.backend.setRadio(seed: "c", tracks: MusicSamples.tracks("c", "r1"))
        await h.start(h.page(["a", "b", "c"], browseId: "UCartist", audioPlaylistId: "OLAK5uy_album"), tap: "c")

        #expect(await h.backend.autoplayCalls.isEmpty)
        #expect(await h.backend.radioSeeds == ["c"])
    }

    @Test("a mix gets the plain radio: it is not a playlist to take an automix of")
    func mixPage() async {
        let h = AutomixServiceHarness()
        await h.backend.setRadio(seed: "c", tracks: MusicSamples.tracks("c", "r1"))
        await h.start(h.page(["a", "b", "c"], browseId: "VLRDTMAK5uy_mix"), tap: "c")

        #expect(await h.backend.autoplayCalls.isEmpty)
        #expect(await h.backend.radioSeeds == ["c"])
    }

    @Test("Liked Music asks the automix of LM")
    func likedMusic() async {
        let h = AutomixServiceHarness()
        await h.setAutomix(after: "c")
        await h.start(h.page(["a", "b", "c"], browseId: "VLLM"), tap: "c")

        #expect(await h.backend.autoplayCalls == [h.call("c", "LM")])
        #expect(await h.backend.radioSeeds.isEmpty)
    }

    @Test("a playlist shown in a sorted order asks after the last song of that order")
    func sortedPage() async {
        let h = AutomixServiceHarness()
        await h.setAutomix(after: "a")
        await h.start(h.page(["c", "b", "a"]), tap: "c")

        #expect(await h.backend.autoplayCalls == [h.call("a", "PL1")])
    }

    @Test("a tapped song after a playlist gets its own radio, not the playlist's automix")
    func tappedSongAfterPage() async {
        let h = AutomixServiceHarness()
        await h.setAutomix(after: "c")
        await h.start(h.page(["a", "b", "c"]), tap: "c")
        #expect(h.service.queue.automixPlaylistId == "PL1")

        await h.backend.setRadio(seed: "x", tracks: MusicSamples.tracks("x", "r1", "r2", "r3", "r4", "r5"))
        h.service.play(MusicSamples.track("x", title: "Song x"))
        await h.settle()

        #expect(h.service.queue.automixPlaylistId == nil)
        #expect(await h.backend.radioSeeds == ["x"])
        #expect(await h.backend.autoplayCalls == [h.call("c", "PL1")])
    }

    @Test("a radio that took over from a page and runs out asks the plain radio of its last song")
    func radioAfterHandOverIsPlain() async {
        let h = AutomixServiceHarness()
        await h.backend.setAutomix(afterVideoId: "b", tracks: MusicSamples.tracks("b", "r1", "r2"))
        await h.backend.setRadio(seed: "r2", tracks: MusicSamples.tracks("r2", "r3", "r4", "r5", "r6", "r7"))
        await h.start(h.page(["a", "b"]), tap: "b")
        #expect(h.stagedIDs == ["r1", "r2"])

        h.service.next()
        await h.settle()

        #expect(h.service.queue.source == .radio(seedVideoId: "r2"))
        #expect(await h.backend.autoplayCalls == [h.call("b", "PL1")])
        #expect(await h.backend.radioSeeds == ["r2"])
        #expect(h.queuedIDs == ["a", "b", "r1", "r2", "r3", "r4", "r5", "r6", "r7"])
    }

    // MARK: - Which song it asks after

    @Test("with shuffle on the automix is asked after the page's last song, not the last of the mix")
    func shuffledSeed() async {
        let h = AutomixServiceHarness(preferences: MusicPlaybackPreferences(shuffle: true))
        await h.setAutomix(after: "d")
        await h.start(h.page(["a", "b", "c", "d"]), tap: "a")

        #expect(h.queuedIDs.first == "a")
        #expect(h.queuedIDs.last != "d", "the mix must not end where the page does, or this test shows nothing")
        #expect(await h.backend.autoplayCalls == [h.call("d", "PL1")])
        #expect(h.stagedIDs == AutomixServiceHarness.radio)
    }

    @Test("a song added to the queue is not the song the automix is asked after")
    func queuedSongIsNotTheSeed() async {
        let h = AutomixServiceHarness()
        await h.setAutomix(after: "f")
        await h.start(h.page(["a", "b", "c", "d", "e", "f"]), tap: "a")
        #expect(await h.backend.autoplayCalls.isEmpty)

        h.service.addToQueue(MusicSamples.track("z", title: "Song z"))
        for _ in 0..<3 {
            h.service.next()
            await h.settle()
        }

        #expect(h.queuedIDs == ["a", "b", "c", "d", "e", "f", "z"])
        #expect(await h.backend.autoplayCalls == [h.call("f", "PL1")])
        #expect(h.stagedIDs == AutomixServiceHarness.radio)
    }

    // MARK: - Failures

    @Test("a rejected automix is not asked again: the queue moves on to the song before it, in the page's order")
    func rejectedAutomix() async {
        let h = AutomixServiceHarness()
        await h.backend.setAutomixError(afterVideoId: "c", MusicError.http(404))
        await h.setAutomix(after: "b")
        await h.start(h.page(["a", "b", "c"]), tap: "c")

        #expect(await h.backend.autoplayCalls == [h.call("c", "PL1"), h.call("b", "PL1")])
        #expect(await h.backend.radioSeeds.isEmpty)
        #expect(h.stagedIDs == AutomixServiceHarness.radio)
    }

    @Test("a server error on the automix waits for a retry of the same request, never the plain radio")
    func serverErrorRetries() async {
        let h = AutomixServiceHarness(queueRetryDelay: .milliseconds(5))
        await h.backend.setAutomixFailures(afterVideoId: "b", MusicError.http(503), times: 2)
        await h.setAutomix(after: "b")
        await h.start(h.page(["a", "b"]), tap: "b")

        let staged = await h.eventually { h.stagedIDs == AutomixServiceHarness.radio }
        #expect(staged)
        #expect(await h.backend.autoplayCalls == [h.call("b", "PL1"), h.call("b", "PL1"), h.call("b", "PL1")])
        #expect(await h.backend.radioSeeds.isEmpty)
    }

    @Test("a network failure on the automix retries the same request")
    func networkErrorRetries() async {
        let h = AutomixServiceHarness(queueRetryDelay: .milliseconds(5))
        await h.backend.setAutomixFailures(afterVideoId: "b", URLError(.timedOut), times: 1)
        await h.setAutomix(after: "b")
        await h.start(h.page(["a", "b"]), tap: "b")

        let staged = await h.eventually { h.stagedIDs == AutomixServiceHarness.radio }
        #expect(staged)
        #expect(await h.backend.autoplayCalls == [h.call("b", "PL1"), h.call("b", "PL1")])
    }

    // MARK: - When no radio is wanted

    @Test("Loop playlist asks for no automix: the page wraps instead of handing over")
    func loopPlaylist() async {
        let h = AutomixServiceHarness(preferences: MusicPlaybackPreferences(loop: .playlist))
        await h.setAutomix(after: "c")
        await h.start(h.page(["a", "b", "c"]), tap: "c")

        #expect(await h.backend.autoplayCalls.isEmpty)
        #expect(await h.backend.radioSeeds.isEmpty)
        #expect(h.stagedIDs.isEmpty)
    }

    @Test("with Autoplay off nothing is asked")
    func autoplayOff() async {
        let h = AutomixServiceHarness(preferences: MusicPlaybackPreferences(autoplay: false))
        await h.setAutomix(after: "c")
        await h.start(h.page(["a", "b", "c"]), tap: "c")

        #expect(await h.backend.autoplayCalls.isEmpty)
        #expect(await h.backend.radioSeeds.isEmpty)
        #expect(h.stagedIDs.isEmpty)
    }

    @Test("turning Loop playlist off while a page waits at its end asks the automix then")
    func loopOffAsks() async {
        let h = AutomixServiceHarness(preferences: MusicPlaybackPreferences(loop: .playlist))
        await h.setAutomix(after: "c")
        await h.start(h.page(["a", "b", "c"]), tap: "c")
        #expect(await h.backend.autoplayCalls.isEmpty)

        h.service.setLoopMode(.off)
        await h.settle()

        #expect(await h.backend.autoplayCalls == [h.call("c", "PL1")])
        #expect(h.stagedIDs == AutomixServiceHarness.radio)
    }
}
