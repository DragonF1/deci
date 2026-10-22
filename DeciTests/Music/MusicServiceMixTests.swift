// DeciTests/Music/MusicServiceMixTests.swift
// A mix page (RDTMAK5uy_, RDAMVM, RDEM, RDAT and the other RD ids) is an endless queue: playing a song from it asks the
// mix after the page's last song and appends what it answers straight to the queue, whatever Autoplay and Loop playlist
// say. A refused mix is forgotten and the page follows the Autoplay rules like any playlist; a dry one hands over to the
// plain radio, and only then does the queue say it comes from the radio.

import Foundation
import Testing
@testable import Deci

@MainActor
private struct MixServiceHarness {
    static let mixId = "RDTMAK5uy_mix"
    static let browseId = "VLRDTMAK5uy_mix"
    static let songs = ["m1", "m2", "m3", "m4", "m5"]

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

    /// Polls until `condition` holds; for work that is waiting out a retry or a gate and cannot be awaited.
    func eventually(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<400 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    func page(
        _ ids: [String],
        browseId: String = MixServiceHarness.browseId,
        continuation: String? = nil,
        audioPlaylistId: String? = nil
    ) -> MusicBrowsePage {
        MusicSamples.page(
            browseId,
            tracks: ids.map { MusicSamples.track($0, title: "Song \($0)") },
            continuation: continuation,
            audioPlaylistId: audioPlaylistId
        )
    }

    /// Plays `tap` (the first row by default) from `page` and waits for the queue work.
    func start(_ page: MusicBrowsePage, tap: String? = nil) async {
        begin(page, tap: tap)
        await settle()
        engine.emit(.playingChanged(true))
    }

    /// Plays `tap` from `page` without waiting: for a test that holds the queue work at a gate.
    func begin(_ page: MusicBrowsePage, tap: String? = nil) {
        let id = tap ?? page.tracks[0].videoId
        service.play(MusicSamples.track(id, title: "Song \(id)"), in: page)
    }

    /// Scripts the mix after `seed`: the seed itself first, as YouTube sends it, then `songs`.
    func setMix(
        after seed: String,
        _ songs: [String] = MixServiceHarness.songs,
        continuation: String? = nil
    ) async {
        await backend.setMix(
            afterVideoId: seed,
            tracks: MusicSamples.tracks(seed) + songs.map { MusicSamples.track($0, title: "Song \($0)") },
            continuation: continuation
        )
    }

    func call(_ afterVideoId: String, _ playlistId: String = MixServiceHarness.mixId) -> FakeMusicBackend.MixCall {
        FakeMusicBackend.MixCall(playlistId: playlistId, afterVideoId: afterVideoId)
    }

    /// Waits until the backend has been asked for `count` mixes: the ask is then held at its gate, if it has one.
    func asked(_ count: Int) async -> Bool {
        await eventually { await backend.mixCalls.count == count }
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
@Suite("MusicService mix")
struct MusicServiceMixTests {
    // MARK: - Asking the mix

    @Test("the mix is asked after the page's last song and joins the queue itself: it is not staged beside the page")
    func appendsNotStages() async {
        let h = MixServiceHarness()
        await h.setMix(after: "c")
        await h.start(h.page(["a", "b", "c"]), tap: "c")

        #expect(await h.backend.mixCalls == [h.call("c")])
        #expect(await h.backend.radioSeeds.isEmpty)
        #expect(await h.backend.autoplayCalls.isEmpty)
        #expect(h.queuedIDs == ["a", "b", "c"] + MixServiceHarness.songs)
        #expect(h.stagedIDs.isEmpty)
        #expect(h.service.queue.source == .radio(seedVideoId: "c"))
        #expect(h.service.queue.mixPlaylistId == MixServiceHarness.mixId)
        #expect(h.service.queue.current?.videoId == "c")
    }

    @Test("every kind of mix page asks its own playlist id, the VL prefix dropped")
    func mixKinds() async {
        let cases = [
            ("VLRDTMAK5uy_x", "RDTMAK5uy_x"), ("VLRDAMVM4D7u5KF7SP8", "RDAMVM4D7u5KF7SP8"),
            ("VLRDEMabc", "RDEMabc"), ("VLRDATabc", "RDATabc"),
        ]
        for (browseId, playlistId) in cases {
            let h = MixServiceHarness()
            await h.setMix(after: "c")
            await h.start(h.page(["a", "b", "c"], browseId: browseId), tap: "c")

            #expect(await h.backend.mixCalls == [h.call("c", playlistId)], "\(browseId)")
            #expect(await h.backend.autoplayCalls.isEmpty, "\(browseId)")
            #expect(await h.backend.radioSeeds.isEmpty, "\(browseId)")
            #expect(h.service.queue.mixPlaylistId == playlistId, "\(browseId)")
        }
    }

    @Test("the queue plays straight on from the page into the mix, in order, and Up next lists the mix")
    func playsOn() async {
        let h = MixServiceHarness()
        await h.setMix(after: "c")
        await h.start(h.page(["a", "b", "c"]))

        #expect(await h.backend.mixCalls == [h.call("c")])
        #expect(h.listing.upcoming.map(\.videoId) == ["b", "c"] + MixServiceHarness.songs)
        #expect(h.listing.autoplayStart == nil)

        for _ in 0..<3 {
            h.service.next()
            await h.settle()
        }

        #expect(h.service.queue.current?.videoId == "m1")
        #expect(h.loadedIDs == ["a", "b", "c", "m1"])
        #expect(await h.backend.mixCalls == [h.call("c")])
    }

    @Test("a long mix page asks nothing until the queue is down to its last songs, then asks after the page's last")
    func asksNearTheEnd() async {
        let letters = ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l"]
        let h = MixServiceHarness()
        await h.setMix(after: "l", ["m1", "m2"])
        await h.start(h.page(letters), tap: "a")
        #expect(await h.backend.mixCalls.isEmpty)
        #expect(h.service.queue.mixPlaylistId == MixServiceHarness.mixId)

        h.service.jump(to: MusicSamples.track("j", title: "Song j"))
        await h.settle()

        #expect(await h.backend.mixCalls == [h.call("l")])
        #expect(h.queuedIDs == letters + ["m1", "m2"])
    }

    @Test("a mix page with a continuation of its own loads the rest of the page first, then asks after the page's last song")
    func pageContinuationFirst() async {
        let h = MixServiceHarness()
        await h.backend.setMoreTracks(browseId: MixServiceHarness.browseId, continuation: "p1", tracks: MusicSamples.tracks("d", "e"))
        await h.setMix(after: "e", ["m1", "m2"])
        await h.start(h.page(["a", "b", "c"], continuation: "p1"), tap: "c")

        #expect(await h.backend.moreTracksCalls == [FakeMusicBackend.MoreTracksCall(browseId: MixServiceHarness.browseId, continuation: "p1")])
        #expect(await h.backend.mixCalls == [h.call("e")])
        #expect(h.queuedIDs == ["a", "b", "c", "d", "e", "m1", "m2"])
        #expect(h.stagedIDs.isEmpty)
    }

    @Test("a song added to the queue is not the song the mix is asked after")
    func queuedSongIsNotTheSeed() async {
        let h = MixServiceHarness()
        await h.setMix(after: "f", ["m1", "m2"])
        await h.start(h.page(["a", "b", "c", "d", "e", "f"]), tap: "a")
        #expect(await h.backend.mixCalls.isEmpty)

        h.service.addToQueue(MusicSamples.track("z", title: "Song z"))
        for _ in 0..<3 {
            h.service.next()
            await h.settle()
        }

        #expect(await h.backend.mixCalls == [h.call("f")])
        #expect(h.queuedIDs == ["a", "b", "c", "d", "e", "f", "z", "m1", "m2"])
    }

    @Test("with shuffle on the mix is asked after the page's last song, not the last of the mix, and joins the shuffled queue")
    func shuffled() async {
        let h = MixServiceHarness(preferences: MusicPlaybackPreferences(shuffle: true))
        let gate = MusicTestGate()
        await h.backend.setMixGate(afterVideoId: "d", gate)
        await h.setMix(after: "d")
        h.begin(h.page(["a", "b", "c", "d"]), tap: "a")
        #expect(await h.asked(1))

        #expect(h.queuedIDs.first == "a")
        #expect(h.queuedIDs.last != "d", "the mix must not end where the page does, or this test shows nothing")
        #expect(await h.backend.mixCalls == [h.call("d")])

        await gate.open()
        await h.settle()

        #expect(h.queuedIDs.first == "a")
        #expect(Set(h.queuedIDs) == Set(["a", "b", "c", "d"] + MixServiceHarness.songs))
        #expect(h.queuedIDs.count == 4 + MixServiceHarness.songs.count)
        #expect(h.stagedIDs.isEmpty)
    }

    // MARK: - What the queue says it is

    @Test("the queue says it comes from a mix: while the mix is asked, once it answered, and as the radio it became")
    func fromMix() async {
        let h = MixServiceHarness()
        let gate = MusicTestGate()
        await h.backend.setMixGate(afterVideoId: "c", gate)
        await h.setMix(after: "c")
        h.begin(h.page(["a", "b", "c"]), tap: "c")
        #expect(await h.asked(1))
        #expect(h.listing.sourceLine == "From mix")
        #expect(h.service.queue.isPage)

        await gate.open()
        await h.settle()

        #expect(h.listing.sourceLine == "From mix")
        #expect(h.service.queue.source == .radio(seedVideoId: "c"))
        #expect(MusicQueueListing.nowPlayingKicker(sourceLine: h.listing.sourceLine) == "NOW PLAYING \u{00B7} FROM MIX")
    }

    @Test("a page that is not a mix does not say it comes from one")
    func playlistIsNotAMix() async {
        let h = MixServiceHarness()
        await h.backend.setAutomix(afterVideoId: "c", tracks: MusicSamples.tracks("c", "r1"))
        await h.start(h.page(["a", "b", "c"], browseId: "VLPL1"), tap: "c")

        #expect(h.service.queue.mixPlaylistId == nil)
        #expect(h.listing.sourceLine == "From playlist")
        #expect(await h.backend.mixCalls.isEmpty)
    }

    // MARK: - Autoplay and Loop playlist

    @Test("with Autoplay off a mix still asks and goes on, continuation pages included: a mix is the playlist, not what follows it")
    func autoplayOff() async {
        let h = MixServiceHarness(preferences: MusicPlaybackPreferences(autoplay: false))
        await h.setMix(after: "c", continuation: "t1")
        await h.backend.setMoreRadio(seed: "c", continuation: "t1", tracks: MusicSamples.tracks("m6", "m7"), next: "t2")
        await h.start(h.page(["a", "b", "c"]), tap: "c")

        #expect(await h.backend.mixCalls == [h.call("c")])
        #expect(h.queuedIDs == ["a", "b", "c"] + MixServiceHarness.songs)
        #expect(h.stagedIDs.isEmpty)
        #expect(await h.backend.moreRadioCalls.isEmpty)

        for _ in 0..<2 {
            h.service.next()
            await h.settle()
        }

        #expect(await h.backend.moreRadioCalls == [FakeMusicBackend.MoreRadioCall(seed: "c", continuation: "t1")])
        #expect(h.queuedIDs == ["a", "b", "c"] + MixServiceHarness.songs + ["m6", "m7"])
        #expect(h.service.queue.continuation == "t2")
        #expect(await h.backend.radioSeeds.isEmpty)
        #expect(await h.backend.autoplayCalls.isEmpty)
    }

    @Test("turning Autoplay off, and on again, leaves a mix alone: its songs stay, and it keeps paging")
    func autoplayToggledOnAMix() async {
        let h = MixServiceHarness()
        await h.setMix(after: "c", continuation: "t1")
        await h.backend.setMoreRadio(seed: "c", continuation: "t1", tracks: MusicSamples.tracks("m6", "m7"), next: "t2")
        await h.start(h.page(["a", "b", "c"]), tap: "c")
        let songs = ["a", "b", "c"] + MixServiceHarness.songs
        #expect(h.queuedIDs == songs)

        h.service.setAutoplay(false)

        // A mix ignores Autoplay: nothing is parked, and the mix is still the queue's.
        #expect(h.queuedIDs == songs)
        #expect(h.listing.upcoming.map(\.videoId) == MixServiceHarness.songs)
        #expect(h.service.queue.mixPlaylistId == MixServiceHarness.mixId)
        #expect(h.service.queue.continuation == "t1")
        #expect(h.service.canGoNext)
        #expect(h.listing.sourceLine == "From mix")

        for _ in 0..<2 {
            h.service.next()
            await h.settle()
        }

        #expect(await h.backend.moreRadioCalls == [FakeMusicBackend.MoreRadioCall(seed: "c", continuation: "t1")])
        #expect(h.queuedIDs == songs + ["m6", "m7"])

        h.service.setAutoplay(true)
        await h.settle()

        #expect(h.queuedIDs == songs + ["m6", "m7"])
        #expect(h.service.queue.continuation == "t2")
        #expect(h.service.queue.mixPlaylistId == MixServiceHarness.mixId)
    }

    @Test("with Autoplay off a mix that has run dry stops where it is, and still says it comes from a mix")
    func autoplayOffDry() async {
        let h = MixServiceHarness(preferences: MusicPlaybackPreferences(autoplay: false))
        await h.setMix(after: "c", ["m1", "m2"])
        await h.start(h.page(["a", "b", "c"]), tap: "c")

        #expect(h.queuedIDs == ["a", "b", "c", "m1", "m2"])
        #expect(await h.backend.radioSeeds.isEmpty)
        #expect(h.service.queue.mixPlaylistId == MixServiceHarness.mixId)
        #expect(h.listing.sourceLine == "From mix")
    }

    @Test("Loop playlist asks the mix too, and lists no lap while the first answer is on its way")
    func loopPlaylistAsksMix() async {
        let h = MixServiceHarness(preferences: MusicPlaybackPreferences(loop: .playlist))
        let gate = MusicTestGate()
        await h.backend.setMixGate(afterVideoId: "c", gate)
        await h.setMix(after: "c", ["m1", "m2"])
        h.begin(h.page(["a", "b", "c"]), tap: "c")
        #expect(await h.asked(1))

        #expect(h.service.listsNextLap == false)
        #expect(h.service.canGoNext)
        #expect(h.listing.upcoming.isEmpty)

        await gate.open()
        await h.settle()

        #expect(h.queuedIDs == ["a", "b", "c", "m1", "m2"])
        #expect(await h.backend.mixCalls == [h.call("c")])
        #expect(await h.backend.radioSeeds.isEmpty)
    }

    @Test("Loop playlist lists no lap while an answered mix still has a continuation, even with Autoplay off, and lists it once dry")
    func loopPlaylistNoLapWhileGrowing() async {
        let h = MixServiceHarness(preferences: MusicPlaybackPreferences(loop: .playlist, autoplay: false))
        let gate = MusicTestGate()
        await h.setMix(after: "c", ["m1", "m2"], continuation: "t1")
        await h.backend.setMoreRadioGate(seed: "c", continuation: "t1", gate)
        await h.backend.setMoreRadio(seed: "c", continuation: "t1", tracks: MusicSamples.tracks("m3"), next: nil)
        h.begin(h.page(["a", "b", "c"]), tap: "c")
        #expect(await h.eventually { await h.backend.moreRadioCalls.count == 1 })

        #expect(h.queuedIDs == ["a", "b", "c", "m1", "m2"])
        #expect(h.service.queue.continuation == "t1")
        #expect(h.service.listsNextLap == false)
        #expect(h.service.canGoNext)

        await gate.open()
        await h.settle()

        #expect(h.queuedIDs == ["a", "b", "c", "m1", "m2", "m3"])
        #expect(h.service.queue.continuation == nil)
        #expect(h.service.listsNextLap)
        #expect(h.listing.upcoming.map(\.videoId) == ["m1", "m2", "m3", "a", "b"])
    }

    @Test("Loop playlist starts the queue over only once the mix has run dry")
    func loopPlaylistWrapsWhenDry() async {
        let h = MixServiceHarness(preferences: MusicPlaybackPreferences(loop: .playlist))
        await h.setMix(after: "c", ["m1", "m2"])
        await h.start(h.page(["a", "b", "c"]), tap: "c")
        #expect(h.queuedIDs == ["a", "b", "c", "m1", "m2"])
        #expect(h.service.listsNextLap)

        for _ in 0..<3 {
            h.service.next()
            await h.settle()
        }

        #expect(h.loadedIDs == ["c", "m1", "m2", "a"])
        #expect(await h.backend.mixCalls == [h.call("c")])
        #expect(await h.backend.radioSeeds.isEmpty)
    }

    @Test("Loop playlist does not prefetch the first song again while the mix can still grow")
    func noLapPrefetchWhileGrowing() async {
        let h = MixServiceHarness(preferences: MusicPlaybackPreferences(loop: .playlist))
        let gate = MusicTestGate()
        await h.backend.setMixGate(afterVideoId: "c", gate)
        await h.setMix(after: "c")
        h.begin(h.page(["a", "b", "c"]), tap: "c")
        #expect(await h.asked(1))
        await h.service.playTask?.value
        h.engine.emit(.playingChanged(true))

        h.engine.tick(186, playing: true)

        #expect(h.service.prefetchTask == nil)
        #expect(await h.backend.resolvedIDs == ["c"])
        await gate.open()
        await h.settle()
    }

    @Test("Next waits for the mix at the last song and plays its first song when it lands, even with Autoplay off")
    func nextWaitsForMix() async {
        let h = MixServiceHarness(preferences: MusicPlaybackPreferences(autoplay: false))
        let gate = MusicTestGate()
        await h.backend.setMixGate(afterVideoId: "c", gate)
        await h.setMix(after: "c", ["m1", "m2"])
        h.begin(h.page(["a", "b", "c"]), tap: "c")
        #expect(await h.asked(1))
        await h.service.playTask?.value
        h.engine.emit(.playingChanged(true))
        #expect(h.service.canGoNext)

        h.service.next()
        #expect(h.loadedIDs == ["c"])

        await gate.open()
        await h.settle()

        #expect(h.service.queue.current?.videoId == "m1")
        #expect(h.loadedIDs == ["c", "m1"])
    }

    @Test("Next is off at the last song once the mix has nothing more, with Autoplay off")
    func nextOffWhenDry() async {
        let h = MixServiceHarness(preferences: MusicPlaybackPreferences(autoplay: false))
        await h.setMix(after: "c", [])
        await h.start(h.page(["a", "b", "c"]), tap: "c")

        #expect(h.queuedIDs == ["a", "b", "c"])
        #expect(h.service.queue.mixPlaylistId == nil, "an answer with nothing new is as good as none: the mix is forgotten")
        #expect(h.service.canGoNext == false)
    }

    // MARK: - A refused mix

    @Test("a refused mix is forgotten, and the page follows the Autoplay rules: the radio of the same last song is staged")
    func refusedMix() async {
        for error in [MusicError.http(400), .http(403), .http(404), .parse("no queue")] {
            let h = MixServiceHarness()
            await h.backend.setMixError(afterVideoId: "c", error)
            await h.backend.setRadio(seed: "c", tracks: MusicSamples.tracks("c", "r1", "r2"))
            await h.start(h.page(["a", "b", "c"]), tap: "c")

            #expect(await h.backend.mixCalls == [h.call("c")], "\(error)")
            #expect(await h.backend.radioSeeds == ["c"], "\(error)")
            #expect(await h.backend.autoplayCalls.isEmpty, "\(error)")
            #expect(h.queuedIDs == ["a", "b", "c"], "\(error)")
            #expect(h.stagedIDs == ["r1", "r2"], "\(error)")
            #expect(h.service.queue.mixPlaylistId == nil, "\(error)")
            #expect(h.service.queue.isPage, "\(error)")
            #expect(h.listing.sourceLine == "From playlist", "\(error)")
        }
    }

    @Test("a refused mix hands over to the staged radio when the page runs out, like any playlist")
    func refusedMixHandsOver() async {
        let h = MixServiceHarness()
        await h.backend.setMixError(afterVideoId: "b", MusicError.http(404))
        await h.backend.setRadio(seed: "b", tracks: MusicSamples.tracks("b", "r1", "r2"))
        await h.start(h.page(["a", "b"]), tap: "b")
        #expect(h.stagedIDs == ["r1", "r2"])

        h.service.next()
        await h.settle()

        #expect(h.service.queue.current?.videoId == "r1")
        #expect(h.queuedIDs == ["a", "b", "r1", "r2"])
        #expect(h.listing.sourceLine == "From radio")
    }

    @Test("a refused mix with Autoplay off asks nothing more and stages nothing")
    func refusedMixAutoplayOff() async {
        let h = MixServiceHarness(preferences: MusicPlaybackPreferences(autoplay: false))
        await h.backend.setMixError(afterVideoId: "c", MusicError.http(404))
        await h.backend.setRadio(seed: "c", tracks: MusicSamples.tracks("c", "r1", "r2"))
        await h.start(h.page(["a", "b", "c"]), tap: "c")

        #expect(await h.backend.mixCalls == [h.call("c")])
        #expect(await h.backend.radioSeeds.isEmpty)
        #expect(h.stagedIDs.isEmpty)
        #expect(h.service.queue.mixPlaylistId == nil)
        #expect(h.service.canGoNext == false)
    }

    @Test("a refused mix with Loop playlist asks no radio and lists the lap again")
    func refusedMixLoopPlaylist() async {
        let h = MixServiceHarness(preferences: MusicPlaybackPreferences(loop: .playlist))
        await h.backend.setMixError(afterVideoId: "c", MusicError.http(404))
        await h.start(h.page(["a", "b", "c"]), tap: "c")

        #expect(await h.backend.mixCalls == [h.call("c")])
        #expect(await h.backend.radioSeeds.isEmpty)
        #expect(h.service.queue.mixPlaylistId == nil)
        #expect(h.service.listsNextLap)
    }

    @Test("a mix that answers with nothing at all counts as refused")
    func emptyAnswerIsRefused() async {
        let h = MixServiceHarness()
        await h.backend.setMix(afterVideoId: "c", tracks: [], continuation: nil)
        await h.backend.setRadio(seed: "c", tracks: MusicSamples.tracks("c", "r1"))
        await h.start(h.page(["a", "b", "c"]), tap: "c")

        #expect(await h.backend.mixCalls == [h.call("c")])
        #expect(await h.backend.radioSeeds == ["c"])
        #expect(h.stagedIDs == ["r1"])
        #expect(h.service.queue.mixPlaylistId == nil)
        #expect(h.service.queue.isPage)
    }

    @Test("a mix answer that only repeats songs the queue has, with no continuation, is dry: the page's last song gets the radio")
    func repeatedAnswerIsDry() async {
        let h = MixServiceHarness()
        // The mix answers c, a and b: all three are queued already. The radio of b is bait: the one the page must not ask.
        await h.setMix(after: "c", ["a", "b"])
        await h.backend.setRadio(seed: "c", tracks: MusicSamples.tracks("c", "r1", "r2"))
        await h.backend.setRadio(seed: "b", tracks: MusicSamples.tracks("b", "x1", "x2"))
        await h.start(h.page(["a", "b", "c"]), tap: "c")

        #expect(await h.backend.mixCalls == [h.call("c")])
        #expect(await h.backend.radioSeeds == ["c"])
        #expect(await h.backend.autoplayCalls.isEmpty)
        #expect(h.queuedIDs == ["a", "b", "c"])
        #expect(h.stagedIDs == ["r1", "r2"])
        #expect(h.service.queue.mixPlaylistId == nil)
        #expect(h.service.queue.isPage)
        #expect(h.listing.sourceLine == "From playlist")
    }

    @Test("a repeated mix answer with Autoplay off asks nothing more, and the queue just ends where it is")
    func repeatedAnswerAutoplayOff() async {
        let h = MixServiceHarness(preferences: MusicPlaybackPreferences(autoplay: false))
        await h.setMix(after: "c", ["a", "b"])
        await h.start(h.page(["a", "b", "c"]), tap: "c")

        #expect(await h.backend.mixCalls == [h.call("c")])
        #expect(await h.backend.radioSeeds.isEmpty)
        #expect(await h.backend.autoplayCalls.isEmpty)
        #expect(h.stagedIDs.isEmpty)
        #expect(h.service.queue.mixPlaylistId == nil)
        #expect(h.service.canGoNext == false)

        h.engine.emit(.ended)
        await h.settle()

        #expect(h.player.nowPlaying?.videoId == "c")
        #expect(h.player.hasEnded)
        #expect(h.queuedIDs == ["a", "b", "c"])
        #expect(h.loadedIDs == ["c"])
        #expect(await h.backend.radioSeeds.isEmpty)
    }

    @Test("a mix answer that repeats songs but has a continuation is not dry: the mix goes on")
    func repeatedAnswerWithContinuationGoesOn() async {
        let h = MixServiceHarness(preferences: MusicPlaybackPreferences(autoplay: false))
        await h.setMix(after: "c", ["a", "b"], continuation: "t1")
        await h.backend.setMoreRadio(seed: "c", continuation: "t1", tracks: MusicSamples.tracks("m1", "m2"), next: nil)
        await h.start(h.page(["a", "b", "c"]), tap: "c")

        #expect(await h.backend.moreRadioCalls == [FakeMusicBackend.MoreRadioCall(seed: "c", continuation: "t1")])
        #expect(h.queuedIDs == ["a", "b", "c", "m1", "m2"])
        #expect(h.service.queue.mixPlaylistId == MixServiceHarness.mixId)
        #expect(await h.backend.radioSeeds.isEmpty)
    }

    @Test("a mix that finds the session gone is forgotten and asks nothing more")
    func sessionGone() async {
        let h = MixServiceHarness()
        await h.backend.setMixError(afterVideoId: "c", MusicError.signedOut)
        await h.start(h.page(["a", "b", "c"]), tap: "c")

        #expect(await h.backend.mixCalls == [h.call("c")])
        #expect(await h.backend.radioSeeds.isEmpty)
        #expect(h.service.queue.mixPlaylistId == nil)
        #expect(h.service.authState == .signedOut)
    }

    // MARK: - A mix that fails for a while

    @Test("an error that may pass waits for a retry of the same mix request, never the radio and never the mark")
    func retries() async {
        let errors: [any Error] = [MusicError.http(503), MusicError.http(429), MusicError.http(408), URLError(.timedOut)]
        for error in errors {
            let h = MixServiceHarness(queueRetryDelay: .milliseconds(5))
            await h.backend.setMixFailures(afterVideoId: "c", error, times: 2)
            await h.setMix(after: "c")
            await h.start(h.page(["a", "b", "c"]), tap: "c")

            let landed = await h.eventually { h.queuedIDs == ["a", "b", "c"] + MixServiceHarness.songs }
            #expect(landed, "\(error)")
            #expect(await h.backend.mixCalls == [h.call("c"), h.call("c"), h.call("c")], "\(error)")
            #expect(await h.backend.radioSeeds.isEmpty, "\(error)")
            #expect(h.service.queue.mixPlaylistId == MixServiceHarness.mixId, "\(error)")
        }
    }

    // MARK: - Running dry

    @Test("a mix that has run dry hands over to the plain radio of its last song, and only then says it comes from the radio")
    func ranDry() async {
        let h = MixServiceHarness()
        let gate = MusicTestGate()
        await h.setMix(after: "c", ["m1", "m2"])
        await h.backend.setRadio(seed: "m2", tracks: MusicSamples.tracks("m2", "r1", "r2", "r3", "r4", "r5"))
        await h.backend.setRadioGate(seed: "m2", gate)
        h.begin(h.page(["a", "b", "c"]), tap: "c")
        #expect(await h.eventually { await h.backend.radioSeeds == ["m2"] })

        #expect(h.service.queue.mixPlaylistId == MixServiceHarness.mixId)
        #expect(h.listing.sourceLine == "From mix")

        await gate.open()
        await h.settle()

        #expect(h.service.queue.mixPlaylistId == nil)
        #expect(h.listing.sourceLine == "From radio")
        #expect(h.queuedIDs == ["a", "b", "c", "m1", "m2", "r1", "r2", "r3", "r4", "r5"])
        #expect(await h.backend.mixCalls == [h.call("c")])
        #expect(await h.backend.autoplayCalls.isEmpty)
    }

    @Test("Autoplay turned off while a dry mix's radio is on its way: the answer is dropped, the mix plays out its own songs, and Autoplay on asks again")
    func autoplayOffWhileTheDryMixAsksForItsRadio() async {
        let h = MixServiceHarness()
        let gate = MusicTestGate()
        await h.setMix(after: "c", ["m1", "m2"])
        await h.backend.setRadio(seed: "m2", tracks: MusicSamples.tracks("m2", "r1", "r2", "r3", "r4", "r5"))
        await h.backend.setRadioGate(seed: "m2", gate)
        h.begin(h.page(["a", "b", "c"]), tap: "c")
        #expect(await h.eventually { await h.backend.radioSeeds == ["m2"] })

        h.service.setAutoplay(false)
        await gate.open()
        await h.settle()

        // The mix is still the queue's: its songs are not parked and it does not say it comes from the radio.
        #expect(h.queuedIDs == ["a", "b", "c", "m1", "m2"])
        #expect(h.service.queue.mixPlaylistId == MixServiceHarness.mixId)
        #expect(h.service.queue.radioIsParked == false)
        #expect(h.service.queue.parked.isEmpty)
        #expect(h.listing.sourceLine == "From mix")
        #expect(h.service.canGoNext)

        for _ in 0..<2 {
            h.service.next()
            await h.settle()
        }

        #expect(h.loadedIDs == ["c", "m1", "m2"])
        #expect(h.service.queue.current?.videoId == "m2")
        #expect(h.service.canGoNext == false)

        // Autoplay back on: the dry mix asks for the radio of its last song again, and the radio takes over from it.
        h.service.setAutoplay(true)
        await h.settle()

        #expect(await h.backend.radioSeeds == ["m2", "m2"])
        #expect(h.queuedIDs == ["a", "b", "c", "m1", "m2", "r1", "r2", "r3", "r4", "r5"])
        #expect(h.service.queue.mixPlaylistId == nil)
        #expect(h.listing.sourceLine == "From radio")
    }

    @Test("a mix whose continuation is refused is dry: the queue goes on as the radio of its last song")
    func continuationRefused() async {
        let h = MixServiceHarness()
        await h.setMix(after: "c", continuation: "t1")
        await h.backend.setMoreRadioError(seed: "c", continuation: "t1", MusicError.http(404))
        await h.backend.setRadio(seed: "m5", tracks: MusicSamples.tracks("m5", "r1", "r2"))
        await h.start(h.page(["a", "b", "c"]), tap: "c")

        for _ in 0..<2 {
            h.service.next()
            await h.settle()
        }

        #expect(await h.backend.moreRadioCalls == [FakeMusicBackend.MoreRadioCall(seed: "c", continuation: "t1")])
        #expect(await h.backend.radioSeeds == ["m5"])
        #expect(h.queuedIDs == ["a", "b", "c"] + MixServiceHarness.songs + ["r1", "r2"])
        #expect(h.service.queue.mixPlaylistId == nil)
        #expect(h.listing.sourceLine == "From radio")
    }

    @Test("pages that only repeat songs the queue has stop after the empty-page cap, without handing over to Autoplay")
    func repeatedSongsStop() async {
        let h = MixServiceHarness()
        await h.setMix(after: "c", [], continuation: "t1")
        await h.backend.setMoreRadio(seed: "c", continuation: "t1", tracks: MusicSamples.tracks("a", "b"), next: "t2")
        await h.backend.setMoreRadio(seed: "c", continuation: "t2", tracks: MusicSamples.tracks("c"), next: "t3")
        await h.backend.setMoreRadio(seed: "c", continuation: "t3", tracks: MusicSamples.tracks("m1"), next: nil)
        await h.start(h.page(["a", "b", "c"]), tap: "c")

        #expect(await h.backend.moreRadioCalls == [
            FakeMusicBackend.MoreRadioCall(seed: "c", continuation: "t1"),
            FakeMusicBackend.MoreRadioCall(seed: "c", continuation: "t2"),
        ])
        #expect(h.queuedIDs == ["a", "b", "c"])
        #expect(await h.backend.radioSeeds.isEmpty)
        #expect(await h.backend.autoplayCalls.isEmpty)
        #expect(h.service.queue.mixPlaylistId == MixServiceHarness.mixId)
    }

    // MARK: - A last song that cannot be played

    @Test("a last song that cannot be resolved waits for the mix being asked instead of ending the queue")
    func unplayableLastSongWaitsForMix() async {
        let h = MixServiceHarness()
        let gate = MusicTestGate()
        await h.backend.setMixGate(afterVideoId: "c", gate)
        await h.backend.setResolveError("c", MusicError.unplayable("Gone"))
        await h.setMix(after: "c", ["m1", "m2"])
        h.begin(h.page(["a", "b", "c"]), tap: "c")
        #expect(await h.asked(1))
        await h.service.playTask?.value

        #expect(h.queuedIDs == ["a", "b", "c"])
        #expect(h.service.queue.mixPlaylistId == MixServiceHarness.mixId)
        #expect(h.player.nowPlaying?.videoId == "c")

        await gate.open()
        await h.settle()

        #expect(h.queuedIDs == ["a", "b", "c", "m1", "m2"])
        #expect(h.service.queue.current?.videoId == "m1")
        #expect(h.loadedIDs == ["m1"])
        #expect(h.service.lastError == nil)
    }

    @Test("the mix having nothing after all ends the queue the way the failed last song would have on its own")
    func unplayableLastSongThenDryMix() async {
        let h = MixServiceHarness(preferences: MusicPlaybackPreferences(autoplay: false))
        let gate = MusicTestGate()
        await h.backend.setMixGate(afterVideoId: "c", gate)
        await h.backend.setResolveError("c", MusicError.unplayable("Gone"))
        await h.setMix(after: "c", [])
        h.begin(h.page(["a", "b", "c"]), tap: "c")
        #expect(await h.asked(1))
        await h.service.playTask?.value
        #expect(h.queuedIDs == ["a", "b", "c"])

        await gate.open()
        await h.settle()

        #expect(h.service.queue.isEmpty)
        #expect(h.player.nowPlaying == nil)
        #expect(h.service.lastError == "Gone")
        #expect(h.loadedIDs.isEmpty)
    }

    @Test("a last song that cannot be resolved ends the queue at once when no mix is on its way, as before")
    func unplayableLastSongWithoutMixEnds() async {
        let h = MixServiceHarness(preferences: MusicPlaybackPreferences(autoplay: false))
        await h.backend.setResolveError("c", MusicError.unplayable("Gone"))
        await h.start(h.page(["a", "b", "c"], browseId: "VLPL1"), tap: "c")

        #expect(await h.backend.mixCalls.isEmpty)
        #expect(h.service.queue.isEmpty)
        #expect(h.player.nowPlaying == nil)
    }

    @Test("Loop playlist does not wrap a last song that cannot be resolved to the start while the mix is first asked")
    func unplayableLastSongNoLapWhileGrowing() async {
        let h = MixServiceHarness(preferences: MusicPlaybackPreferences(loop: .playlist))
        let gate = MusicTestGate()
        await h.backend.setMixGate(afterVideoId: "c", gate)
        await h.backend.setResolveError("c", MusicError.unplayable("Gone"))
        await h.setMix(after: "c", ["m1", "m2"])
        h.begin(h.page(["a", "b", "c"]), tap: "c")
        #expect(await h.asked(1))
        await h.service.playTask?.value

        #expect(h.loadedIDs.isEmpty, "the failed song must not send the queue back to a")
        #expect(h.queuedIDs == ["a", "b", "c"])

        await gate.open()
        await h.settle()

        #expect(h.loadedIDs == ["m1"])
        #expect(h.service.queue.current?.videoId == "m1")
    }

    @Test("Loop playlist does not wrap a last song whose stream died to the start while the mix is first asked")
    func diedLastSongNoLapWhileGrowing() async {
        let h = MixServiceHarness(preferences: MusicPlaybackPreferences(loop: .playlist))
        let gate = MusicTestGate()
        await h.backend.setMixGate(afterVideoId: "c", gate)
        await h.setMix(after: "c", ["m1", "m2"])
        h.begin(h.page(["a", "b", "c"]), tap: "c")
        #expect(await h.asked(1))
        await h.service.playTask?.value
        h.engine.emit(.playingChanged(true))

        h.engine.emit(.failed)
        await h.player.refreshTask?.value
        h.engine.emit(.failed)

        #expect(h.loadedIDs == ["c", "c"], "the failed song must not send the queue back to a")
        #expect(h.queuedIDs == ["a", "b", "c"])

        await gate.open()
        await h.settle()

        #expect(h.loadedIDs == ["c", "c", "m1"])
        #expect(h.service.queue.current?.videoId == "m1")
    }

    @Test("Loop playlist still wraps a failed last song once the mix has run dry")
    func unplayableLastSongWrapsWhenDry() async {
        let h = MixServiceHarness(preferences: MusicPlaybackPreferences(loop: .playlist))
        await h.setMix(after: "c", ["m1"])
        await h.start(h.page(["a", "b", "c"]), tap: "c")
        #expect(h.queuedIDs == ["a", "b", "c", "m1"])
        #expect(h.service.queue.mixHasMore == false)
        await h.backend.setResolveError("m1", MusicError.unplayable("Gone"))

        h.service.jump(to: MusicSamples.track("m1", title: "Song m1"))
        await h.settle()

        #expect(h.loadedIDs == ["c", "a"], "a dry mix lets the failed last song lap, as any playlist does")
        #expect(h.service.queue.current?.videoId == "a")
    }

    // MARK: - Leaving the mix

    @Test("a song tapped on its own after a mix starts its own radio, and the mix is gone")
    func tappedSongLeavesMix() async {
        let h = MixServiceHarness()
        await h.setMix(after: "c")
        await h.start(h.page(["a", "b", "c"]), tap: "c")
        #expect(h.service.queue.mixPlaylistId == MixServiceHarness.mixId)

        await h.backend.setRadio(seed: "x", tracks: MusicSamples.tracks("x", "r1", "r2", "r3", "r4", "r5"))
        h.service.play(MusicSamples.track("x", title: "Song x"))
        await h.settle()

        #expect(h.service.queue.mixPlaylistId == nil)
        #expect(await h.backend.radioSeeds == ["x"])
        #expect(await h.backend.mixCalls == [h.call("c")])
        #expect(h.listing.sourceLine == "From radio")
    }

    @Test("a page that is not a mix, played after a mix, does not inherit it")
    func playlistAfterMix() async {
        let h = MixServiceHarness()
        await h.setMix(after: "c")
        await h.start(h.page(["a", "b", "c"]), tap: "c")

        await h.backend.setAutomix(afterVideoId: "z", tracks: MusicSamples.tracks("z", "r1"))
        await h.start(h.page(["y", "z"], browseId: "VLPL2"), tap: "z")

        #expect(h.service.queue.mixPlaylistId == nil)
        #expect(await h.backend.autoplayCalls == [FakeMusicBackend.AutoplayCall(afterVideoId: "z", playlistId: "PL2")])
        #expect(await h.backend.mixCalls == [h.call("c")])
    }

    @Test("a mix answer that lands after the queue was replaced by a song is dropped")
    func staleAnswerAfterSong() async {
        let h = MixServiceHarness()
        let gate = MusicTestGate()
        await h.backend.setMixGate(afterVideoId: "c", gate)
        await h.setMix(after: "c")
        h.begin(h.page(["a", "b", "c"]), tap: "c")
        #expect(await h.asked(1))

        await h.backend.setRadio(seed: "x", tracks: MusicSamples.tracks("x", "r1", "r2", "r3", "r4", "r5"))
        h.service.play(MusicSamples.track("x", title: "Song x"))
        await h.settle()
        await gate.open()
        try? await Task.sleep(for: .milliseconds(50))
        await h.settle()

        #expect(h.queuedIDs == ["x", "r1", "r2", "r3", "r4", "r5"])
        #expect(h.service.queue.mixPlaylistId == nil)
    }

    @Test("a mix ask that another mix page overtakes before it runs still asks its own mix, not the new page's")
    func overtakenAskKeepsItsMix() async {
        let h = MixServiceHarness()
        await h.setMix(after: "c")
        await h.setMix(after: "z", ["n1", "n2", "n3", "n4", "n5"])
        // Both pages start in one go: the first ask has not run when the second page replaces the queue.
        h.begin(h.page(["a", "b", "c"]), tap: "c")
        h.begin(h.page(["x", "y", "z"], browseId: "VLRDEM2"), tap: "z")
        await h.settle()
        try? await Task.sleep(for: .milliseconds(50))
        await h.settle()

        let calls = await h.backend.mixCalls
        #expect(calls.contains(h.call("c", "RDEM2")) == false, "the old page's seed must not be paired with the new page's mix")
        #expect(calls.contains(h.call("z", "RDEM2")))
        #expect(h.queuedIDs == ["x", "y", "z", "n1", "n2", "n3", "n4", "n5"])
        #expect(h.service.queue.mixPlaylistId == "RDEM2")
    }

    @Test("a mix answer that lands after another mix page replaced the queue is dropped")
    func staleAnswerAfterOtherMix() async {
        let h = MixServiceHarness()
        let gate = MusicTestGate()
        await h.backend.setMixGate(afterVideoId: "c", gate)
        await h.setMix(after: "c")
        h.begin(h.page(["a", "b", "c"]), tap: "c")
        #expect(await h.asked(1))

        await h.setMix(after: "z", ["n1", "n2", "n3", "n4", "n5"])
        await h.start(h.page(["x", "y", "z"], browseId: "VLRDEM2"), tap: "z")
        await gate.open()
        try? await Task.sleep(for: .milliseconds(50))
        await h.settle()

        #expect(h.queuedIDs == ["x", "y", "z", "n1", "n2", "n3", "n4", "n5"])
        #expect(h.service.queue.mixPlaylistId == "RDEM2")
        #expect(await h.backend.mixCalls == [h.call("c"), h.call("z", "RDEM2")])
    }

    // MARK: - Pages that are not mixes

    @Test("a curated RDCLAK5uy playlist is a playlist: it asks the automix, not a mix")
    func curatedPlaylist() async {
        let h = MixServiceHarness()
        await h.backend.setAutomix(afterVideoId: "c", tracks: MusicSamples.tracks("c", "r1", "r2"))
        await h.start(h.page(["a", "b", "c"], browseId: "VLRDCLAK5uy_curated"), tap: "c")

        #expect(await h.backend.autoplayCalls == [FakeMusicBackend.AutoplayCall(afterVideoId: "c", playlistId: "RDCLAK5uy_curated")])
        #expect(await h.backend.mixCalls.isEmpty)
        #expect(await h.backend.radioSeeds.isEmpty)
        #expect(h.stagedIDs == ["r1", "r2"])
        #expect(h.service.queue.mixPlaylistId == nil)
        #expect(h.listing.sourceLine == "From playlist")
    }

    @Test("an album, an artist page and Liked Music never ask a mix")
    func otherPages() async {
        for browseId in ["MPREb_album", "UCartist", "VLLM", "VLPL1"] {
            let h = MixServiceHarness()
            await h.start(h.page(["a", "b", "c"], browseId: browseId, audioPlaylistId: "OLAK5uy_x"), tap: "c")

            #expect(await h.backend.mixCalls.isEmpty, "\(browseId)")
            #expect(h.service.queue.mixPlaylistId == nil, "\(browseId)")
        }
    }
}
