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
