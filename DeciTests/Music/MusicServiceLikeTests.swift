// DeciTests/Music/MusicServiceLikeTests.swift
// Like and Dislike through the service, with a fake backend and a fake AVPlayer seam: the state of the playing song is
// read once when it starts, Like and Dislike act on the song playing now, Dislike skips it, and a session that ends
// takes the remembered states with it.

import Foundation
import Testing
@testable import Deci

@MainActor
private struct LikeServiceHarness {
    let backend: FakeMusicBackend
    let engine = FakePlaybackEngine()
    let surface = FakeNowPlayingSurface()
    let clock = MutableClock()
    let pick = ChannelPick()
    let signInPick = ChannelPick()
    let service: MusicService

    init(signedIn: Bool = true, preferences: MusicPlaybackPreferences = MusicPlaybackPreferences()) {
        backend = FakeMusicBackend(signedIn: signedIn)
        let clock = self.clock
        let pick = self.pick
        let signInPick = self.signInPick
        service = MusicService(
            backend: backend,
            player: MusicPlayer(engine: engine),
            presentSignIn: { signInPick.completion = $0 },
            presentChannelPicker: { _, completion in pick.completion = completion },
            closeSignInWindow: {},
            raiseSignInWindow: {},
            nowPlaying: NowPlayingController(surface: surface, fetchArtwork: { _ in nil }),
            now: { clock.now },
            preferences: preferences,
            savePreferences: { _ in },
            shuffleSeed: 1,
            queueRetryDelay: .seconds(60),
            refreshOnCreate: false
        )
    }

    /// A signed-in service, the way the app has it once the session check has answered.
    static func signedIn(preferences: MusicPlaybackPreferences = MusicPlaybackPreferences()) async -> LikeServiceHarness {
        let h = LikeServiceHarness(preferences: preferences)
        await h.service.refreshAuth()
        return h
    }

    func settle() async {
        while true {
            let play = service.playTask
            let radio = service.radioTask
            await play?.value
            await radio?.value
            if service.playTask == play, service.radioTask == radio { break }
        }
    }

    func until(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<400 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }

    func letLateWorkLand() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(40))
    }

    func song(_ id: String) -> Deci.MusicTrack { MusicSamples.track(id, title: "Song \(id)") }

    /// Plays the first of `ids` with a radio of the rest behind it, and waits for the radio.
    func startRadio(_ ids: [String]) async {
        await backend.setRadio(seed: ids[0], tracks: ids.map { song($0) })
        service.play(song(ids[0]))
        await settle()
        engine.emit(.playingChanged(true))
    }

    /// Plays one song with nothing behind it.
    func startAlone(_ id: String) async {
        service.play(song(id))
        await settle()
        engine.emit(.playingChanged(true))
    }

    var playingID: String? { service.player.nowPlaying?.videoId }
    var loadedIDs: [String] { engine.loads.map(\.stream.videoId) }
    func likeStatusCalls() async -> [String] { await backend.likeStatusCalls }
    func rateCalls() async -> [FakeMusicBackend.RateCall] { await backend.rateCalls }
}

@MainActor
@Suite("MusicService likes")
struct MusicServiceLikeTests {

    // MARK: - Reading the state

    @Test("A song that starts has its state read once, and the service shows it")
    func readsWhenTheSongStarts() async {
        let h = await LikeServiceHarness.signedIn()
        await h.backend.setLikeStatus(videoId: "a", .like)

        await h.startAlone("a")
        let known = await h.until { h.service.likeStatus == .like }

        #expect(known)
        #expect(await h.likeStatusCalls() == ["a"])

        h.engine.emit(.playingChanged(false))
        h.engine.emit(.playingChanged(true))
        await h.letLateWorkLand()
        #expect(await h.likeStatusCalls() == ["a"])
    }

    @Test("Signed out, nothing is read")
    func noReadWhenSignedOut() async {
        let h = LikeServiceHarness(signedIn: false)
        await h.service.refreshAuth()

        await h.startAlone("a")
        await h.letLateWorkLand()

        #expect(await h.likeStatusCalls().isEmpty)
        #expect(h.service.likeStatus == nil)
    }

    @Test("The next song is read when it starts, and going back to a song keeps its state with no new read")
    func perSongAcrossSkips() async {
        let h = await LikeServiceHarness.signedIn()
        await h.backend.setLikeStatus(videoId: "a", .like)
        await h.backend.setLikeStatus(videoId: "b", .dislike)
        await h.startRadio(["a", "b", "c"])
        _ = await h.until { h.service.likeStatus == .like }

        h.service.next()
        await h.settle()
        h.engine.emit(.playingChanged(true))
        let second = await h.until { h.service.likeStatus == .dislike }
        #expect(second)
        #expect(h.playingID == "b")

        h.service.previous()
        await h.settle()
        h.engine.emit(.playingChanged(true))
        let back = await h.until { h.playingID == "a" && h.service.likeStatus == .like }

        #expect(back)
        #expect(await h.likeStatusCalls() == ["a", "b"])
    }

    @Test("A song already playing when the session check finds a sign-in has its state read then")
    func readsWhenTheSessionCheckSignsIn() async {
        let h = LikeServiceHarness()
        await h.backend.setLikeStatus(videoId: "a", .like)
        await h.startAlone("a")
        await h.letLateWorkLand()
        #expect(await h.likeStatusCalls().isEmpty)

        await h.service.refreshAuth()
        let known = await h.until { h.service.likeStatus == .like }

        #expect(known)
        #expect(await h.likeStatusCalls() == ["a"])
    }

    @Test("A song already playing when a sign-in finishes has its state read then")
    func readsWhenSignInFinishes() async {
        let h = LikeServiceHarness(signedIn: false)
        await h.service.refreshAuth()
        await h.backend.setLikeStatus(videoId: "a", .dislike)
        await h.startAlone("a")

        h.service.signIn()
        h.signInPick.completion?([StoredCookie(MusicSamples.cookie("SAPISID", domain: ".youtube.com"))])
        await h.service.signInTask?.value
        let known = await h.until { h.service.likeStatus == .dislike }

        #expect(known)
        #expect(await h.likeStatusCalls() == ["a"])
    }

    @Test("A read that failed is made again when the player next changes")
    func failedReadRetriedOnPlayerChange() async {
        let h = await LikeServiceHarness.signedIn()
        await h.backend.setLikeStatusError(videoId: "a", URLError(.notConnectedToInternet))
        await h.startAlone("a")
        await h.letLateWorkLand()
        let failedReads = await h.likeStatusCalls().count
        #expect(failedReads >= 1)
        #expect(h.service.likeStatus == nil)

        await h.backend.setLikeStatusError(videoId: "a", nil)
        await h.backend.setLikeStatus(videoId: "a", .like)
        h.engine.emit(.playingChanged(false))
        h.engine.emit(.playingChanged(true))
        let known = await h.until { h.service.likeStatus == .like }
        await h.letLateWorkLand()

        #expect(known)
        #expect(await h.likeStatusCalls().count == failedReads + 1)
    }

    @Test("The like buttons are on offer only when signed in with a song playing")
    func canRate() async {
        let h = LikeServiceHarness(signedIn: true)
        #expect(!h.service.canRate)

        await h.service.refreshAuth()
        #expect(!h.service.canRate)

        await h.startAlone("a")
        #expect(h.service.canRate)

        h.service.signOut()
        #expect(!h.service.canRate)
    }

    // MARK: - Reading another song's state

    @Test("A song other than the playing one is read when asked for, and only once")
    func readsAnotherSongOnRequest() async {
        let h = await LikeServiceHarness.signedIn()
        await h.backend.setLikeStatus(videoId: "z", .like)

        h.service.loadLikeStatus(of: h.song("z"))
        h.service.loadLikeStatus(of: h.song("z"))
        h.service.loadLikeStatus(of: h.song("z"))
        let known = await h.until { h.service.likes.status(of: "z") == .like }
        await h.letLateWorkLand()

        #expect(known)
        #expect(await h.likeStatusCalls() == ["z"])
    }

    @Test("Asking for a song's state reads nothing signed out, nor for a song with no id")
    func noRequestedReadWhenSignedOutOrWithoutId() async {
        let out = LikeServiceHarness(signedIn: false)
        await out.service.refreshAuth()
        out.service.loadLikeStatus(of: out.song("z"))
        await out.letLateWorkLand()
        #expect(await out.likeStatusCalls().isEmpty)

        let h = await LikeServiceHarness.signedIn()
        h.service.loadLikeStatus(of: h.song(""))
        h.service.loadLikeStatus(of: h.song("  "))
        await h.letLateWorkLand()
        #expect(await h.likeStatusCalls().isEmpty)
    }

    @Test("A song read on request is not read again when it starts playing")
    func requestedReadIsRememberedByThePlayer() async {
        let h = await LikeServiceHarness.signedIn()
        await h.backend.setLikeStatus(videoId: "a", .dislike)
        h.service.loadLikeStatus(of: h.song("a"))
        _ = await h.until { h.service.likes.status(of: "a") == .dislike }

        await h.startAlone("a")
        await h.letLateWorkLand()

        #expect(h.service.likeStatus == .dislike)
        #expect(await h.likeStatusCalls() == ["a"])
    }

    @Test("A read on request leaves the state of the playing song alone")
    func requestedReadLeavesThePlayingSong() async {
        let h = await LikeServiceHarness.signedIn()
        await h.backend.setLikeStatus(videoId: "a", .like)
        await h.backend.setLikeStatus(videoId: "z", .dislike)
        await h.startAlone("a")
        _ = await h.until { h.service.likeStatus == .like }

        h.service.loadLikeStatus(of: h.song("z"))
        _ = await h.until { h.service.likes.status(of: "z") == .dislike }

        #expect(h.service.likeStatus == .like)
        #expect(await h.likeStatusCalls() == ["a", "z"])
    }

    // MARK: - Like

    @Test("Like acts on the playing song, and the state shows at once")
    func likePlaying() async {
        let h = await LikeServiceHarness.signedIn()
        await h.startAlone("a")

        let outcome = await h.service.toggleLike()

        #expect(outcome == .liked)
        #expect(h.service.likeStatus == .like)
        #expect(await h.rateCalls() == [.init(videoId: "a", status: .like)])
    }

    @Test("Like on a liked song takes the like back")
    func likeToggles() async {
        let h = await LikeServiceHarness.signedIn()
        await h.backend.setLikeStatus(videoId: "a", .like)
        await h.startAlone("a")
        _ = await h.until { h.service.likeStatus == .like }

        let outcome = await h.service.toggleLike()

        #expect(outcome == .likeRemoved)
        #expect(h.service.likeStatus == .indifferent)
        #expect(await h.rateCalls() == [.init(videoId: "a", status: .indifferent)])
    }

    @Test("Like pressed before the song's state has landed waits for it, so a liked song loses its like")
    func likeBeforeTheReadLands() async {
        let h = await LikeServiceHarness.signedIn()
        let gate = MusicTestGate()
        await h.backend.setLikeStatus(videoId: "a", .like)
        await h.backend.setLikeStatusGate(videoId: "a", gate)
        await h.startAlone("a")
        _ = await h.until { await h.likeStatusCalls().count == 1 }
        let service = h.service

        let task = Task { await service.toggleLike() }
        await h.letLateWorkLand()
        #expect(await h.rateCalls().isEmpty)
        await gate.open()

        #expect(await task.value == .likeRemoved)
        #expect(service.likeStatus == .indifferent)
        #expect(await h.rateCalls() == [.init(videoId: "a", status: .indifferent)])
    }

    @Test("Dislike pressed while a like is out skips at once and is sent after it")
    func dislikeWhileLikeIsOut() async {
        let h = await LikeServiceHarness.signedIn()
        await h.startRadio(["a", "b", "c"])
        let gate = MusicTestGate()
        await h.backend.setRateGate(videoId: "a", gate)
        let service = h.service
        let like = Task { await service.toggleLike() }
        _ = await h.until { await h.rateCalls().count == 1 }

        let dislike = await service.dislike()
        let skipped = await h.until { h.playingID == "b" }

        #expect(dislike == .quiet)
        #expect(skipped)
        #expect(service.likes.status(of: "a") == .dislike)
        await gate.open()
        #expect(await like.value == .disliked)
        #expect(await h.rateCalls() == [
            .init(videoId: "a", status: .like),
            .init(videoId: "a", status: .dislike),
        ])
    }

    @Test("Like with nothing playing does nothing and says so")
    func likeNothingPlaying() async {
        let h = await LikeServiceHarness.signedIn()

        #expect(await h.service.toggleLike() == .nothingPlaying)
        #expect(await h.rateCalls().isEmpty)
    }

    @Test("Like while signed out sends nothing and asks to sign in")
    func likeSignedOut() async {
        let h = LikeServiceHarness(signedIn: false)
        await h.service.refreshAuth()
        await h.startAlone("a")

        #expect(await h.service.toggleLike() == .signedOut)
        #expect(await h.service.dislike() == .signedOut)
        #expect(await h.rateCalls().isEmpty)
    }

    @Test("A like that fails goes back and says YouTube could not be reached; the session stays")
    func likeFails() async {
        let h = await LikeServiceHarness.signedIn()
        await h.startAlone("a")
        await h.backend.setRateError(videoId: "a", URLError(.notConnectedToInternet))

        #expect(await h.service.toggleLike() == .failed)
        #expect(h.service.likeStatus == nil)
        #expect(h.service.authState == .signedIn)
    }

    // MARK: - Dislike

    @Test("Dislike rates the playing song and skips to the next at once")
    func dislikeSkips() async {
        let h = await LikeServiceHarness.signedIn()
        await h.startRadio(["a", "b", "c"])

        let outcome = await h.service.dislike()
        await h.settle()

        #expect(outcome == .disliked)
        #expect(await h.rateCalls() == [.init(videoId: "a", status: .dislike)])
        #expect(h.loadedIDs.last == "b")
        #expect(h.playingID == "b")
    }

    @Test("The skip does not wait for YouTube's answer to the dislike")
    func dislikeSkipsBeforeTheAnswer() async {
        let h = await LikeServiceHarness.signedIn()
        await h.startRadio(["a", "b", "c"])
        let gate = MusicTestGate()
        await h.backend.setRateGate(videoId: "a", gate)
        let service = h.service

        let task = Task { await service.dislike() }
        let skipped = await h.until { h.playingID == "b" }

        #expect(skipped)
        #expect(service.likes.status(of: "a") == .dislike)
        await gate.open()
        #expect(await task.value == .disliked)
    }

    @Test("Dislike on the last song with nothing to follow rates it and keeps it playing")
    func dislikeWithNowhereToGo() async {
        let h = await LikeServiceHarness.signedIn(preferences: MusicPlaybackPreferences(shuffle: false, loop: .off, autoplay: false))
        await h.startAlone("a")
        #expect(!h.service.canGoNext)

        let outcome = await h.service.dislike()
        await h.settle()

        #expect(outcome == .disliked)
        #expect(h.playingID == "a")
        #expect(await h.rateCalls() == [.init(videoId: "a", status: .dislike)])
    }

    @Test("Dislike on a disliked song takes it back and does not skip")
    func dislikeToggles() async {
        let h = await LikeServiceHarness.signedIn()
        await h.backend.setLikeStatus(videoId: "a", .dislike)
        await h.startRadio(["a", "b", "c"])
        _ = await h.until { h.service.likeStatus == .dislike }

        let outcome = await h.service.dislike()
        await h.settle()

        #expect(outcome == .dislikeRemoved)
        #expect(h.playingID == "a")
        #expect(await h.rateCalls() == [.init(videoId: "a", status: .indifferent)])
    }

    @Test("Dislike with nothing playing does nothing and says so")
    func dislikeNothingPlaying() async {
        let h = await LikeServiceHarness.signedIn()

        #expect(await h.service.dislike() == .nothingPlaying)
        #expect(await h.rateCalls().isEmpty)
    }

    @Test("A dislike that fails after the skip rolls back that song's state and leaves the new song alone")
    func lateFailureAfterSkip() async {
        let h = await LikeServiceHarness.signedIn()
        await h.backend.setLikeStatus(videoId: "a", .like)
        await h.backend.setLikeStatus(videoId: "b", .like)
        await h.startRadio(["a", "b", "c"])
        _ = await h.until { h.service.likeStatus == .like }
        let gate = MusicTestGate()
        await h.backend.setRateGate(videoId: "a", gate)
        await h.backend.setRateError(videoId: "a", MusicError.http(500))
        let service = h.service

        let task = Task { await service.dislike() }
        _ = await h.until { h.playingID == "b" }
        h.engine.emit(.playingChanged(true))
        _ = await h.until { service.likeStatus == .like }
        await gate.open()

        #expect(await task.value == .failed)
        #expect(service.likes.status(of: "a") == .like)
        #expect(service.likeStatus == .like)
        #expect(h.playingID == "b")
    }

    // MARK: - Rating any song

    @Test("Rating another song sends that song's id, reports it, and leaves the playing song's state alone")
    func setLikeOfAnotherSong() async {
        let h = await LikeServiceHarness.signedIn()
        await h.startRadio(["a", "b", "c"])
        let before = h.service.likeStatus

        let outcome = await h.service.setLike(.like, of: h.song("x"))

        #expect(outcome == .liked)
        #expect(h.service.likes.status(of: "x") == .like)
        #expect(h.service.likeStatus == before)
        #expect(await h.rateCalls() == [.init(videoId: "x", status: .like)])
    }

    @Test("Rating the playing song shows in the player's own state")
    func setLikeOfThePlayingSong() async {
        let h = await LikeServiceHarness.signedIn()
        await h.startRadio(["a", "b", "c"])

        #expect(await h.service.setLike(.like, of: h.song("a")) == .liked)

        #expect(h.service.likeStatus == .like)
        #expect(h.playingID == "a")
    }

    @Test("Disliking a song that is not playing never skips and leaves the queue as it was")
    func dislikeOfAnotherSongDoesNotSkip() async {
        let h = await LikeServiceHarness.signedIn()
        await h.startRadio(["a", "b", "c"])
        let queued = h.service.queue.tracks.map(\.videoId)
        let loaded = h.loadedIDs

        #expect(await h.service.setLike(.dislike, of: h.song("c")) == .disliked)
        #expect(await h.service.setLike(.dislike, of: h.song("x")) == .disliked)
        await h.settle()

        #expect(h.playingID == "a")
        #expect(h.loadedIDs == loaded)
        #expect(h.service.queue.tracks.map(\.videoId) == queued)
        #expect(await h.rateCalls() == [.init(videoId: "c", status: .dislike), .init(videoId: "x", status: .dislike)])
    }

    @Test("Disliking the playing song skips it, as the shortcut does")
    func dislikeOfThePlayingSongSkips() async {
        let h = await LikeServiceHarness.signedIn()
        await h.startRadio(["a", "b", "c"])

        #expect(await h.service.setLike(.dislike, of: h.song("a")) == .disliked)
        await h.settle()

        #expect(h.playingID == "b")
        #expect(await h.rateCalls() == [.init(videoId: "a", status: .dislike)])
    }

    @Test("Disliking the playing song with nothing to follow still sends it and keeps it playing")
    func dislikeOfThePlayingSongWithNowhereToGo() async {
        let h = await LikeServiceHarness.signedIn(preferences: MusicPlaybackPreferences(shuffle: false, loop: .off, autoplay: false))
        await h.startAlone("a")

        #expect(await h.service.setLike(.dislike, of: h.song("a")) == .disliked)
        await h.settle()

        #expect(h.playingID == "a")
    }

    @Test("Taking back a dislike, and liking, the playing song do not skip")
    func otherRatingsOfThePlayingSongDoNotSkip() async {
        let h = await LikeServiceHarness.signedIn()
        await h.backend.setLikeStatus(videoId: "a", .dislike)
        await h.startRadio(["a", "b", "c"])
        _ = await h.until { h.service.likeStatus == .dislike }

        #expect(await h.service.setLike(.indifferent, of: h.song("a")) == .dislikeRemoved)
        #expect(await h.service.setLike(.like, of: h.song("a")) == .liked)
        await h.settle()

        #expect(h.playingID == "a")
    }

    @Test("Any song can be rated with nothing playing")
    func setLikeWithNothingPlaying() async {
        let h = await LikeServiceHarness.signedIn()

        #expect(await h.service.setLike(.like, of: h.song("x")) == .liked)
        #expect(await h.rateCalls() == [.init(videoId: "x", status: .like)])
    }

    @Test("Rating a song while signed out sends nothing and asks to sign in")
    func setLikeSignedOut() async {
        let h = LikeServiceHarness(signedIn: false)
        await h.service.refreshAuth()

        #expect(await h.service.setLike(.like, of: h.song("x")) == .signedOut)
        #expect(await h.rateCalls().isEmpty)
    }

    @Test("A rating YouTube does not take goes back and reports a failure; the session stays")
    func setLikeFails() async {
        let h = await LikeServiceHarness.signedIn()
        await h.backend.setRateError(videoId: "x", URLError(.notConnectedToInternet))

        #expect(await h.service.setLike(.like, of: h.song("x")) == .failed)

        #expect(h.service.likes.status(of: "x") == nil)
        #expect(h.service.authState == .signedIn)
    }

    // MARK: - The like animation

    /// The bursts the service asked for, and the ones it asked to cut short, each in order.
    @MainActor
    private final class BurstLog {
        var kinds: [MusicRateBurst.Kind] = []
        var cancelled: [MusicRateBurst.Kind] = []
    }

    @Test("Liking the playing song asks for the like burst as the state flips, before YouTube answers")
    func likePlaysTheBurst() async {
        let h = await LikeServiceHarness.signedIn()
        let log = BurstLog()
        h.service.onRatingBurst = { log.kinds.append($0) }
        await h.startAlone("a")
        let gate = MusicTestGate()
        await h.backend.setRateGate(videoId: "a", gate)

        let service = h.service
        let task = Task { await service.toggleLike() }
        _ = await h.until { log.kinds.count == 1 }

        #expect(log.kinds == [.like])
        #expect(h.service.likeStatus == .like)
        #expect(await h.rateCalls().count == 1)
        await gate.open()
        #expect(await task.value == .liked)
        #expect(log.kinds == [.like])
    }

    @Test("Disliking the playing song asks for the dislike burst, once, and the skip still happens")
    func dislikePlaysTheBurst() async {
        let h = await LikeServiceHarness.signedIn()
        let log = BurstLog()
        h.service.onRatingBurst = { log.kinds.append($0) }
        await h.startRadio(["a", "b", "c"])

        #expect(await h.service.dislike() == .disliked)
        await h.settle()

        #expect(log.kinds == [.dislike])
        #expect(h.playingID == "b")
    }

    @Test("Taking a like or a dislike back asks for no burst")
    func removalPlaysNothing() async {
        let h = await LikeServiceHarness.signedIn()
        let log = BurstLog()
        h.service.onRatingBurst = { log.kinds.append($0) }
        await h.backend.setLikeStatus(videoId: "a", .like)
        await h.startAlone("a")
        _ = await h.until { h.service.likeStatus == .like }

        #expect(await h.service.toggleLike() == .likeRemoved)
        #expect(await h.service.setLike(.dislike, of: h.song("a")) == .disliked)
        log.kinds.removeAll()
        #expect(await h.service.setLike(.indifferent, of: h.song("a")) == .dislikeRemoved)

        #expect(log.kinds.isEmpty)
    }

    @Test("The menus' Like and Dislike on the playing song play the burst, on any other song nothing")
    func menuRatingsOfTheSongsOnScreen() async {
        let h = await LikeServiceHarness.signedIn()
        let log = BurstLog()
        h.service.onRatingBurst = { log.kinds.append($0) }
        await h.startRadio(["a", "b", "c"])

        #expect(await h.service.setLike(.like, of: h.song("c")) == .liked)
        #expect(await h.service.setLike(.dislike, of: h.song("x")) == .disliked)
        #expect(log.kinds.isEmpty)

        #expect(await h.service.setLike(.like, of: h.song("a")) == .liked)
        #expect(log.kinds == [.like])
    }

    @Test("Liking the song that is already liked, from a menu, plays nothing")
    func repeatedLikePlaysNothing() async {
        let h = await LikeServiceHarness.signedIn()
        let log = BurstLog()
        h.service.onRatingBurst = { log.kinds.append($0) }
        await h.backend.setLikeStatus(videoId: "a", .like)
        await h.startAlone("a")
        _ = await h.until { h.service.likeStatus == .like }

        #expect(await h.service.setLike(.like, of: h.song("a")) == .liked)

        #expect(log.kinds.isEmpty)
    }

    @Test("A like that fails has played its burst already and plays nothing more when it rolls back")
    func failedLikeDoesNotReplay() async {
        let h = await LikeServiceHarness.signedIn()
        let log = BurstLog()
        h.service.onRatingBurst = { log.kinds.append($0) }
        await h.startAlone("a")
        await h.backend.setRateError(videoId: "a", MusicError.http(500))

        #expect(await h.service.toggleLike() == .failed)

        #expect(log.kinds == [.like])
        #expect(h.service.likeStatus == nil)
    }

    @Test("A like that fails cuts its burst short as the song goes back, once")
    func failedLikeCutsTheBurstShort() async {
        let h = await LikeServiceHarness.signedIn()
        let log = BurstLog()
        h.service.onRatingBurst = { log.kinds.append($0) }
        h.service.onRatingBurstCancel = { log.cancelled.append($0) }
        await h.startAlone("a")
        await h.backend.setRateError(videoId: "a", MusicError.http(500))

        #expect(await h.service.toggleLike() == .failed)

        #expect(log.kinds == [.like])
        #expect(log.cancelled == [.like])
        #expect(h.service.likeStatus == nil)
    }

    @Test("Taking a like or a dislike of the playing song back asks to cut that burst short, once, and plays no burst")
    func removalCutsTheBurstShort() async {
        let h = await LikeServiceHarness.signedIn()
        let log = BurstLog()
        h.service.onRatingBurst = { log.kinds.append($0) }
        h.service.onRatingBurstCancel = { log.cancelled.append($0) }
        await h.backend.setLikeStatus(videoId: "a", .like)
        await h.startAlone("a")
        _ = await h.until { h.service.likeStatus == .like }

        #expect(await h.service.toggleLike() == .likeRemoved)
        #expect(log.cancelled == [.like])
        #expect(log.kinds.isEmpty)

        #expect(await h.service.setLike(.dislike, of: h.song("a")) == .disliked)
        log.kinds.removeAll()
        log.cancelled.removeAll()
        #expect(await h.service.setLike(.indifferent, of: h.song("a")) == .dislikeRemoved)
        #expect(log.cancelled == [.dislike])
        #expect(log.kinds.isEmpty)
    }

    @Test("A like taken back while its call is still out cuts the burst short as the state flips back")
    func unlikeWhileTheLikeIsOut() async {
        let h = await LikeServiceHarness.signedIn()
        let log = BurstLog()
        h.service.onRatingBurst = { log.kinds.append($0) }
        h.service.onRatingBurstCancel = { log.cancelled.append($0) }
        await h.startAlone("a")
        let gate = MusicTestGate()
        await h.backend.setRateGate(videoId: "a", gate)

        let service = h.service
        let task = Task { await service.toggleLike() }
        _ = await h.until { log.kinds.count == 1 }
        #expect(await service.toggleLike() == .quiet)

        #expect(log.kinds == [.like])
        #expect(log.cancelled == [.like])
        #expect(h.service.likeStatus == .indifferent)
        await gate.open()
        _ = await task.value
        #expect(log.kinds == [.like])
        #expect(log.cancelled == [.like])
    }

    @Test("Switching a like to a dislike asks for the dislike burst, which replaces the like one, and cuts nothing short")
    func switchingCutsNothingShort() async {
        let h = await LikeServiceHarness.signedIn()
        let log = BurstLog()
        h.service.onRatingBurst = { log.kinds.append($0) }
        h.service.onRatingBurstCancel = { log.cancelled.append($0) }
        await h.backend.setLikeStatus(videoId: "a", .like)
        await h.startAlone("a")
        _ = await h.until { h.service.likeStatus == .like }

        #expect(await h.service.setLike(.dislike, of: h.song("a")) == .disliked)

        #expect(log.kinds == [.dislike])
        #expect(log.cancelled.isEmpty)
    }

    @Test("A rating that takes nothing away cuts nothing short: a first like, a song with no rating, a rating sent again")
    func nothingTakenAwayCutsNothingShort() async {
        let h = await LikeServiceHarness.signedIn()
        let log = BurstLog()
        h.service.onRatingBurst = { log.kinds.append($0) }
        h.service.onRatingBurstCancel = { log.cancelled.append($0) }
        await h.startAlone("a")

        #expect(await h.service.setLike(.indifferent, of: h.song("a")) == .likeRemoved)
        #expect(await h.service.toggleLike() == .liked)
        #expect(await h.service.setLike(.like, of: h.song("a")) == .liked)

        #expect(log.kinds == [.like])
        #expect(log.cancelled.isEmpty)
    }

    @Test("Taking a rating back from a song that is not playing cuts nothing short and plays nothing")
    func removalOfAnotherSongsRating() async {
        let h = await LikeServiceHarness.signedIn()
        let log = BurstLog()
        h.service.onRatingBurst = { log.kinds.append($0) }
        h.service.onRatingBurstCancel = { log.cancelled.append($0) }
        await h.startRadio(["a", "b", "c"])

        #expect(await h.service.setLike(.like, of: h.song("c")) == .liked)
        #expect(await h.service.setLike(.indifferent, of: h.song("c")) == .likeRemoved)
        #expect(await h.service.setLike(.dislike, of: h.song("x")) == .disliked)
        #expect(await h.service.setLike(.indifferent, of: h.song("x")) == .dislikeRemoved)

        #expect(log.kinds.isEmpty)
        #expect(log.cancelled.isEmpty)
    }

    @Test("Signed out or with nothing playing there is nothing to rate and no burst")
    func nothingToRate() async {
        let h = LikeServiceHarness(signedIn: false)
        await h.service.refreshAuth()
        let log = BurstLog()
        h.service.onRatingBurst = { log.kinds.append($0) }
        await h.startAlone("a")

        #expect(await h.service.toggleLike() == .signedOut)
        #expect(await h.service.setLike(.like, of: h.song("a")) == .signedOut)
        let idle = await LikeServiceHarness.signedIn()
        idle.service.onRatingBurst = { log.kinds.append($0) }
        #expect(await idle.service.toggleLike() == .nothingPlaying)

        #expect(log.kinds.isEmpty)
    }

    // MARK: - A session that ends

    @Test("A rating that finds the session gone signs the service out and forgets the states")
    func ratingFindsSessionGone() async {
        let h = await LikeServiceHarness.signedIn()
        await h.backend.setLikeStatus(videoId: "a", .like)
        await h.startAlone("a")
        _ = await h.until { h.service.likeStatus == .like }
        await h.backend.setRateError(videoId: "a", MusicError.signedOut)

        let outcome = await h.service.toggleLike()

        #expect(outcome == .signedOut)
        #expect(h.service.authState == .signedOut)
        #expect(h.service.likeStatus == nil)
        #expect(!h.service.canRate)
    }

    @Test("A read that finds the session gone signs the service out")
    func readFindsSessionGone() async {
        let h = await LikeServiceHarness.signedIn()
        await h.backend.setLikeStatusError(videoId: "a", MusicError.signedOut)

        await h.startAlone("a")
        let out = await h.until { h.service.authState == .signedOut }

        #expect(out)
    }

    @Test("Signing out forgets the states")
    func signOutForgets() async {
        let h = await LikeServiceHarness.signedIn()
        await h.backend.setLikeStatus(videoId: "a", .like)
        await h.startAlone("a")
        _ = await h.until { h.service.likeStatus == .like }

        h.service.signOut()

        #expect(h.service.likes.status(of: "a") == nil)
        #expect(h.service.likeStatus == nil)
    }

    @Test("Switching channel forgets the states and reads the playing song again")
    func channelSwitchReads() async {
        let h = LikeServiceHarness()
        let service = h.service
        await h.backend.setSessionCookies([StoredCookie(MusicSamples.cookie("SAPISID", domain: ".youtube.com"))])
        await h.backend.setChannelIdentity(false)
        await service.refreshAuth()
        await h.backend.setLikeStatus(videoId: "a", .like)
        await h.startAlone("a")
        _ = await h.until { service.likeStatus == .like }

        // The other channel has not liked it.
        await h.backend.setLikeStatus(videoId: "a", .indifferent)
        service.switchChannel()
        await service.channelSwitchTask?.value
        h.pick.completion?([StoredCookie(MusicSamples.cookie("__Secure-3PAPISID", domain: ".youtube.com"))])
        await service.channelSwitchTask?.value
        let reread = await h.until { service.likeStatus == .indifferent }

        #expect(reread)
        #expect(await h.likeStatusCalls() == ["a", "a"])
    }
}

@MainActor
private final class ChannelPick {
    var completion: (@MainActor ([StoredCookie]?) -> Void)?
}
