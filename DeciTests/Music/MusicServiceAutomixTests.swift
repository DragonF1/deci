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

    @Test("a mix asks its own mix, not the automix and not the plain radio: it is not a playlist to take an automix of")
    func mixPage() async {
        let h = AutomixServiceHarness()
        await h.backend.setMix(afterVideoId: "c", tracks: MusicSamples.tracks("c", "r1", "r2", "r3", "r4", "r5"))
        await h.start(h.page(["a", "b", "c"], browseId: "VLRDTMAK5uy_mix"), tap: "c")

        #expect(await h.backend.autoplayCalls.isEmpty)
        #expect(await h.backend.radioSeeds.isEmpty)
        #expect(await h.backend.mixCalls == [FakeMusicBackend.MixCall(playlistId: "RDTMAK5uy_mix", afterVideoId: "c")])
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
        let h = AutomixServiceHarness(preferences: MusicPlaybackPreferences(autoplay: false))
        await h.setAutomix(after: "f")
        await h.start(h.page(["a", "b", "c", "d", "e", "f"]), tap: "a")
        #expect(await h.backend.autoplayCalls.isEmpty)

        h.service.addToQueue(MusicSamples.track("z", title: "Song z"))
        h.service.setAutoplay(true)
        await h.settle()

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

    // MARK: - Staged as soon as the page is loaded

    private static let letters = ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l"]

    @Test("a twelve-song playlist stages the automix as soon as it plays, so Up next lists AUTOPLAY under the playlist at once")
    func stagesAtOnce() async {
        let h = AutomixServiceHarness()
        await h.setAutomix(after: "l")
        await h.start(h.page(Self.letters))

        #expect(await h.backend.autoplayCalls == [h.call("l", "PL1")])
        #expect(await h.backend.radioSeeds.isEmpty)
        #expect(h.service.queue.current?.videoId == "a")
        #expect(h.service.queue.upcomingCount == 11)
        #expect(h.queuedIDs == Self.letters)
        #expect(h.stagedIDs == AutomixServiceHarness.radio)
        let listing = h.listing
        #expect(listing.upcoming.map(\.videoId) == Array(Self.letters.dropFirst()) + AutomixServiceHarness.radio)
        #expect(listing.autoplayStart == 11)
        #expect(listing.queuedCount == 11)

        // Playing on does not ask again.
        for _ in 0..<3 {
            h.service.next()
            await h.settle()
        }
        #expect(await h.backend.autoplayCalls == [h.call("l", "PL1")])
        #expect(h.stagedIDs == AutomixServiceHarness.radio)
    }

    @Test("a long playlist hands over to the staged automix when its last song ends, without a second ask")
    func longPlaylistHandsOver() async {
        let h = AutomixServiceHarness()
        await h.setAutomix(after: "l")
        await h.start(h.page(Self.letters), tap: "e")
        #expect(h.service.queue.upcomingCount == 7)
        #expect(h.stagedIDs == AutomixServiceHarness.radio)

        for _ in 0..<8 {
            h.service.next()
            await h.settle()
        }

        #expect(h.service.queue.current?.videoId == "r1")
        #expect(h.service.queue.source == .radio(seedVideoId: "l"))
        #expect(h.queuedIDs == Self.letters + AutomixServiceHarness.radio)
        #expect(await h.backend.autoplayCalls == [h.call("l", "PL1")])
    }

    @Test("turning Autoplay on in the middle of a long playlist stages the automix at once, and turning it off hides it again")
    func autoplayOffThenOn() async {
        let h = AutomixServiceHarness(preferences: MusicPlaybackPreferences(autoplay: false))
        await h.setAutomix(after: "l")
        await h.start(h.page(Self.letters), tap: "d")
        #expect(await h.backend.autoplayCalls.isEmpty)
        #expect(h.stagedIDs.isEmpty)
        #expect(h.listing.autoplayStart == nil)

        h.service.setAutoplay(true)
        await h.settle()

        #expect(await h.backend.autoplayCalls == [h.call("l", "PL1")])
        #expect(h.stagedIDs == AutomixServiceHarness.radio)
        #expect(h.listing.upcoming.map(\.videoId) == Array(Self.letters.dropFirst(4)) + AutomixServiceHarness.radio)
        #expect(h.listing.autoplayStart == 8)

        h.service.setAutoplay(false)
        #expect(h.listing.upcoming.map(\.videoId) == Array(Self.letters.dropFirst(4)))
        #expect(h.listing.autoplayStart == nil)
        #expect(h.service.canGoNext)

        h.service.setAutoplay(true)
        await h.settle()
        #expect(h.listing.autoplayStart == 8)
        #expect(await h.backend.autoplayCalls == [h.call("l", "PL1")], "the staged songs are still there: nothing is asked again")
    }

    @Test("Loop playlist stages nothing in a long playlist, and turning it off stages the automix at once")
    func loopPlaylistThenOff() async {
        let h = AutomixServiceHarness(preferences: MusicPlaybackPreferences(loop: .playlist))
        await h.setAutomix(after: "l")
        await h.start(h.page(Self.letters))
        #expect(await h.backend.autoplayCalls.isEmpty)
        #expect(await h.backend.radioSeeds.isEmpty)
        #expect(h.stagedIDs.isEmpty)
        #expect(h.listing.autoplayStart == nil)

        h.service.setLoopMode(.off)
        await h.settle()

        #expect(await h.backend.autoplayCalls == [h.call("l", "PL1")])
        #expect(h.stagedIDs == AutomixServiceHarness.radio)
        #expect(h.listing.autoplayStart == 11)

        // Loop playlist again: the staged songs stay where they are, hidden, and nothing more is asked.
        h.service.setLoopMode(.playlist)
        #expect(h.listing.autoplayStart == nil)
        #expect(await h.backend.autoplayCalls == [h.call("l", "PL1")])
    }

    @Test("a long playlist with pages of its own stages the automix only after its last page has loaded")
    func pagedPlaylistStagesAfterTheLastPage() async {
        let h = AutomixServiceHarness()
        let gate = MusicTestGate()
        let letters = Self.letters
        await h.backend.setMoreTracks(
            browseId: "VLPL1", continuation: "t1", tracks: MusicSamples.tracks("e", "f", "g", "h"), next: "t2"
        )
        await h.backend.setMoreTracks(
            browseId: "VLPL1", continuation: "t2", tracks: MusicSamples.tracks("i", "j", "k", "l"), next: nil
        )
        await h.backend.setMoreTracksGate(browseId: "VLPL1", continuation: "t2", gate)
        await h.setAutomix(after: "l")
        let first = MusicSamples.page("VLPL1", tracks: MusicSamples.tracks("a", "b", "c", "d"), continuation: "t1")
        h.service.play(MusicSamples.track("a", title: "Song a"), in: first)
        await h.service.playTask?.value
        let held = await h.eventually { await h.backend.moreTracksCalls.count == 2 }
        #expect(held)

        // Eight songs are loaded, the last page is on its way: the automix of the page is not asked yet.
        #expect(h.queuedIDs == Array(letters.prefix(8)))
        #expect(h.service.queue.continuation == "t2")
        #expect(await h.backend.autoplayCalls.isEmpty)
        #expect(await h.backend.radioSeeds.isEmpty)
        #expect(h.stagedIDs.isEmpty)

        await gate.open()
        await h.settle()

        #expect(h.queuedIDs == letters)
        #expect(h.service.queue.continuation == nil)
        #expect(await h.backend.autoplayCalls == [h.call("l", "PL1")])
        #expect(h.stagedIDs == AutomixServiceHarness.radio)
    }

    @Test("a mix page still waits for its last songs: nothing is asked of the automix, the radio or the mix at the start")
    func mixPageStillWaits() async {
        let h = AutomixServiceHarness()
        await h.backend.setMix(afterVideoId: "l", tracks: MusicSamples.tracks("l", "m1", "m2"))
        await h.start(h.page(Self.letters, browseId: "VLRDTMAK5uy_mix"))

        #expect(h.service.queue.mixPlaylistId == "RDTMAK5uy_mix")
        #expect(await h.backend.autoplayCalls.isEmpty)
        #expect(await h.backend.radioSeeds.isEmpty)
        #expect(await h.backend.mixCalls.isEmpty)

        h.service.jump(to: MusicSamples.track("h", title: "Song h"))
        await h.settle()
        #expect(await h.backend.mixCalls.isEmpty, "four songs left: still above the threshold")

        h.service.jump(to: MusicSamples.track("i", title: "Song i"))
        await h.settle()
        #expect(await h.backend.mixCalls == [FakeMusicBackend.MixCall(playlistId: "RDTMAK5uy_mix", afterVideoId: "l")])
        #expect(h.queuedIDs == Self.letters + ["m1", "m2"])
        #expect(h.stagedIDs.isEmpty)
        #expect(await h.backend.autoplayCalls.isEmpty)
    }

    @Test("a tapped song's radio queue still waits for the threshold: a long radio asks nothing more until it runs out")
    func radioQueueStillWaits() async {
        let h = AutomixServiceHarness()
        await h.backend.setRadio(seed: "a", tracks: MusicSamples.tracks("a") + Self.letters.dropFirst().map { MusicSamples.track($0) })
        h.service.play(MusicSamples.track("a", title: "Song a"))
        await h.settle()

        #expect(h.queuedIDs == Self.letters)
        #expect(await h.backend.radioSeeds == ["a"])
        #expect(await h.backend.autoplayCalls.isEmpty)
    }

    @Test("a shuffled playlist stages the automix at once, after the page's last song and not the last song of the mix")
    func shuffledSeedAtOnce() async {
        let h = AutomixServiceHarness(preferences: MusicPlaybackPreferences(shuffle: true))
        await h.setAutomix(after: "l")
        await h.start(h.page(Self.letters), tap: "a")

        #expect(h.queuedIDs.first == "a")
        #expect(h.queuedIDs.last != "l", "the mix must not end where the page does, or this test shows nothing")
        #expect(h.service.queue.upcomingCount == 11)
        #expect(await h.backend.autoplayCalls == [h.call("l", "PL1")])
        #expect(h.stagedIDs == AutomixServiceHarness.radio)
        #expect(h.listing.autoplayStart == 11)
    }

    // MARK: - A refused staging cannot walk through the playlist

    /// The ways the page's automix can come back without a taker, each scripted for every song of the playlist.
    private enum Refusal: CaseIterable {
        case automixRefused, radioRefused, emptyAnswer

        func script(_ h: AutomixServiceHarness, for ids: [String]) async {
            for id in ids {
                switch self {
                case .automixRefused: await h.backend.setAutomixError(afterVideoId: id, MusicError.http(404))
                case .radioRefused: await h.backend.setRadioError(seed: id, MusicError.http(404))
                case .emptyAnswer: await h.backend.setAutomix(afterVideoId: id, tracks: [])
                }
            }
        }
    }

    @Test("a refused or empty automix is asked after the last three songs at most, not after every song of the playlist")
    func refusalIsBounded() async {
        for refusal in Refusal.allCases {
            let h = AutomixServiceHarness()
            await refusal.script(h, for: Self.letters)
            await h.start(h.page(Self.letters))

            #expect(await h.backend.autoplayCalls == [h.call("l", "PL1"), h.call("k", "PL1"), h.call("j", "PL1")], "\(refusal)")
            #expect(h.stagedIDs.isEmpty, "\(refusal)")
            #expect(h.service.isFillingQueue == false, "\(refusal)")
            #expect(h.service.queueRetryTask == nil, "\(refusal)")

            // Songs with more than three left behind them ask nothing: a, b, c, d, e, f, g and h.
            for _ in 0..<7 {
                h.service.next()
                await h.settle()
            }
            #expect(h.service.queue.upcomingCount == 4, "\(refusal)")
            #expect(await h.backend.autoplayCalls.count == 3, "\(refusal)")

            // Then it carries on as it always did near the end, and still never twice for the same song.
            for _ in 0..<4 {
                h.service.next()
                await h.settle()
            }
            let calls = await h.backend.autoplayCalls
            #expect(calls.count == Set(calls).count, "\(refusal)")
            #expect(calls.count <= Self.letters.count, "\(refusal)")
            #expect(h.stagedIDs.isEmpty, "\(refusal)")
        }
    }

    @Test("a long playlist whose automix is refused asks a bounded number of times however many songs it has")
    func refusalOnALongPlaylist() async {
        let h = AutomixServiceHarness()
        let ids = (0..<60).map { "s\($0)" }
        await Refusal.automixRefused.script(h, for: ids)
        await h.start(h.page(ids))
        #expect(await h.backend.autoplayCalls.count == 3)

        for _ in 0..<50 {
            h.service.next()
            await h.settle()
        }

        // 50 songs have played; the page still has nine to go, so only the first three asks have been made.
        #expect(h.service.queue.upcomingCount == 9)
        #expect(await h.backend.autoplayCalls.count == 3)
    }

    @Test("a network failure asks the same song again at each track change, never the songs before it")
    func transientFailureDoesNotWalkBack() async {
        let h = AutomixServiceHarness()
        await h.backend.setAutomixError(afterVideoId: "l", URLError(.notConnectedToInternet))
        await h.start(h.page(Self.letters))
        #expect(await h.backend.autoplayCalls == [h.call("l", "PL1")])
        #expect(h.service.queueRetryTask != nil, "a retry of the same ask waits")

        for _ in 0..<3 {
            h.service.next()
            await h.settle()
        }

        let calls = await h.backend.autoplayCalls
        #expect(calls == Array(repeating: h.call("l", "PL1"), count: 4))
        #expect(h.stagedIDs.isEmpty)
    }

    @Test("taking every staged song out stages the automix of the song before it again, three songs' worth in all and no more")
    func removingStagedSongsRestagesAtMostThrice() async {
        let h = AutomixServiceHarness()
        await h.setAutomix(after: "l", ["r1", "r2"])
        await h.setAutomix(after: "k", ["q1", "q2"])
        await h.setAutomix(after: "j", ["p1", "p2"])
        await h.start(h.page(Self.letters))
        #expect(h.stagedIDs == ["r1", "r2"])

        for id in ["r1", "r2", "q1", "q2", "p1", "p2"] {
            h.service.removeFromQueue(MusicSamples.track(id))
            await h.settle()
        }

        let calls = await h.backend.autoplayCalls
        #expect(calls == [h.call("l", "PL1"), h.call("k", "PL1"), h.call("j", "PL1")])
        #expect(h.stagedIDs.isEmpty)
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
