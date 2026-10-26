// DeciTests/Music/MusicLikeStoreTests.swift
// The like state of songs: one read per song and cached for the session, Like and Dislike as optimistic writes that
// roll back on a failure, a second tap ignored while the first is out, a late answer that only touches its own song,
// a session that ends, and the outcome each action reports.

import Foundation
import Testing
@testable import Deci

@MainActor
private final class LikeProbe {
    /// One rating the store showed: the song, what it now shows and what it showed before.
    struct Shown: Equatable {
        let videoId: String
        let status: MusicLikeStatus
        let previous: MusicLikeStatus?
    }

    var expired = 0
    var skips = 0
    var shown: [Shown] = []
}

@MainActor
private struct LikeHarness {
    let backend = FakeMusicBackend()
    let store: MusicLikeStore
    let probe = LikeProbe()

    init() {
        store = MusicLikeStore(backend: backend)
        let probe = self.probe
        store.onSessionExpired = { probe.expired += 1 }
        store.onRatingShown = { videoId, status, previous in
            probe.shown.append(.init(videoId: videoId, status: status, previous: previous))
        }
    }

    func until(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<400 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }

    /// Gives an answer that should be dropped time to arrive, so a missing drop would show.
    func letLateWorkLand() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(40))
    }

    /// Scripts the state of `videoId` on YouTube, reads it, and waits until the store has it.
    func know(_ videoId: String, as status: MusicLikeStatus) async {
        await backend.setLikeStatus(videoId: videoId, status)
        store.load(videoId: videoId)
        _ = await until { store.status(of: videoId) == status }
    }

    func rateCalls() async -> [FakeMusicBackend.RateCall] { await backend.rateCalls }
    func likeStatusCalls() async -> [String] { await backend.likeStatusCalls }

    /// Starts a like toggle in a task and returns at once, so a press that waits on something shows as a failed
    /// expectation on what it should have sent, not as a test that never ends.
    func startToggle(_ videoId: String) -> Task<MusicActionOutcome, Never> {
        let store = self.store
        return Task { await store.toggleLike(videoId: videoId) }
    }

    /// Starts a like toggle that is held at the backend until `gate` opens, and waits until the call is out.
    func heldToggle(_ videoId: String, gate: MusicTestGate) async -> Task<MusicActionOutcome, Never> {
        await backend.setRateGate(videoId: videoId, gate)
        let store = self.store
        let task = Task { await store.toggleLike(videoId: videoId) }
        _ = await until { await backend.rateCalls.count > 0 }
        return task
    }
}

@MainActor
@Suite("MusicLikeStore")
struct MusicLikeStoreTests {

    // MARK: - Reading the state

    @Test("A song's state is read once and kept, so loading it again asks nothing more")
    func readOnce() async {
        let h = LikeHarness()
        await h.know("a", as: .like)

        h.store.load(videoId: "a")
        await h.letLateWorkLand()

        #expect(h.store.status(of: "a") == .like)
        #expect(await h.likeStatusCalls() == ["a"])
    }

    @Test("Loading a song again while its first read is out sends one request")
    func readNotDoubled() async {
        let h = LikeHarness()
        let gate = MusicTestGate()
        await h.backend.setLikeStatus(videoId: "a", .dislike)
        await h.backend.setLikeStatusGate(videoId: "a", gate)

        h.store.load(videoId: "a")
        h.store.load(videoId: "a")
        await gate.open()
        _ = await h.until { h.store.status(of: "a") == .dislike }

        #expect(await h.likeStatusCalls() == ["a"])
    }

    @Test("Going back to a song keeps its state and asks nothing; each song has its own")
    func perSongCache() async {
        let h = LikeHarness()
        await h.know("a", as: .like)
        await h.know("b", as: .dislike)

        h.store.load(videoId: "a")
        await h.letLateWorkLand()

        #expect(h.store.status(of: "a") == .like)
        #expect(h.store.status(of: "b") == .dislike)
        #expect(await h.likeStatusCalls() == ["a", "b"])
    }

    @Test("A song with no state on its page stays unknown, and is not asked for again")
    func unknownIsNotRetried() async {
        let h = LikeHarness()
        h.store.load(videoId: "a")
        _ = await h.until { await h.likeStatusCalls().count == 1 }
        await h.letLateWorkLand()

        h.store.load(videoId: "a")
        await h.letLateWorkLand()

        #expect(h.store.status(of: "a") == nil)
        #expect(await h.likeStatusCalls() == ["a"])
    }

    @Test("A read that fails leaves the song unknown and says nothing")
    func readFailure() async {
        let h = LikeHarness()
        await h.backend.setLikeStatusError(videoId: "a", MusicError.http(500))

        h.store.load(videoId: "a")
        _ = await h.until { await h.likeStatusCalls().count == 1 }
        await h.letLateWorkLand()

        #expect(h.store.status(of: "a") == nil)
        #expect(h.probe.expired == 0)
    }

    @Test("A read that failed is made again the next time the song is loaded, and then the state is known")
    func failedReadIsRetried() async {
        let h = LikeHarness()
        await h.backend.setLikeStatusError(videoId: "a", URLError(.notConnectedToInternet))
        h.store.load(videoId: "a")
        _ = await h.until { await h.likeStatusCalls().count == 1 }
        await h.letLateWorkLand()

        await h.backend.setLikeStatusError(videoId: "a", nil)
        await h.backend.setLikeStatus(videoId: "a", .like)
        h.store.load(videoId: "a")
        let known = await h.until { h.store.status(of: "a") == .like }

        #expect(known)
        #expect(await h.likeStatusCalls() == ["a", "a"])
    }

    @Test("A read still failing is not made twice at once")
    func failedReadNotDoubled() async {
        let h = LikeHarness()
        let gate = MusicTestGate()
        await h.backend.setLikeStatusError(videoId: "a", MusicError.http(500))
        await h.backend.setLikeStatusGate(videoId: "a", gate)

        h.store.load(videoId: "a")
        h.store.load(videoId: "a")
        await gate.open()
        _ = await h.until { await h.likeStatusCalls().count == 1 }
        await h.letLateWorkLand()

        #expect(await h.likeStatusCalls() == ["a"])
    }

    @Test("A read that finds the session gone tells the service, and is not made again")
    func readSignedOut() async {
        let h = LikeHarness()
        await h.backend.setLikeStatusError(videoId: "a", MusicError.signedOut)

        h.store.load(videoId: "a")
        let told = await h.until { h.probe.expired == 1 }
        await h.letLateWorkLand()
        h.store.load(videoId: "a")
        await h.letLateWorkLand()

        #expect(told)
        #expect(h.store.status(of: "a") == nil)
        #expect(await h.likeStatusCalls() == ["a"])
    }

    @Test("A blank video id is never asked for")
    func blankId() async {
        let h = LikeHarness()
        h.store.load(videoId: "")
        h.store.load(videoId: "  ")
        await h.letLateWorkLand()

        #expect(await h.likeStatusCalls().isEmpty)
    }

    @Test("A read that lands after the song was rated does not undo the rating")
    func lateReadDoesNotOverwrite() async {
        let h = LikeHarness()
        let readGate = MusicTestGate()
        await h.backend.setLikeStatus(videoId: "a", .indifferent)
        await h.backend.setLikeStatusGate(videoId: "a", readGate)
        h.store.load(videoId: "a")
        _ = await h.until { await h.likeStatusCalls().count == 1 }

        // Dislike does not wait for the read, so it can be rated before the read lands.
        let outcome = await h.store.dislike(videoId: "a")
        await readGate.open()
        await h.letLateWorkLand()

        #expect(outcome == .disliked)
        #expect(h.store.status(of: "a") == .dislike)
    }

    // MARK: - Like

    @Test("Like on a song whose read is still out does not wait for it: the like shows and is sent at once")
    func likeDoesNotWaitForTheRead() async {
        let h = LikeHarness()
        let readGate = MusicTestGate()
        await h.backend.setLikeStatus(videoId: "a", .like)
        await h.backend.setLikeStatusGate(videoId: "a", readGate)
        h.store.load(videoId: "a")
        _ = await h.until { await h.likeStatusCalls().count == 1 }

        // The read is held for the whole press, so a press that waited for it would send nothing.
        let task = h.startToggle("a")
        let sent = await h.until { await h.rateCalls().count == 1 }

        #expect(sent)
        #expect(h.store.status(of: "a") == .like)
        #expect(await h.rateCalls() == [.init(videoId: "a", status: .like)])

        await readGate.open()
        #expect(await task.value == .liked)
        #expect(await h.likeStatusCalls() == ["a"])
    }

    @Test("A read that lands while the like is out does not overwrite it, whatever the read says")
    func lateReadDoesNotOverwriteALikeInFlight() async {
        let h = LikeHarness()
        let readGate = MusicTestGate()
        let rateGate = MusicTestGate()
        await h.backend.setLikeStatus(videoId: "a", .dislike)
        await h.backend.setLikeStatusGate(videoId: "a", readGate)
        await h.backend.setRateGate(videoId: "a", rateGate)
        h.store.load(videoId: "a")
        _ = await h.until { await h.likeStatusCalls().count == 1 }

        let task = h.startToggle("a")
        let sent = await h.until { await h.rateCalls().count == 1 }
        await readGate.open()
        await h.letLateWorkLand()

        #expect(sent)
        #expect(h.store.status(of: "a") == .like)

        await rateGate.open()
        #expect(await task.value == .liked)
        #expect(h.store.status(of: "a") == .like)
    }

    @Test("A read that lands after the like has been sent does not overwrite it either")
    func lateReadDoesNotOverwriteASentLike() async throws {
        let h = LikeHarness()
        let readGate = MusicTestGate()
        await h.backend.setLikeStatus(videoId: "a", .indifferent)
        await h.backend.setLikeStatusGate(videoId: "a", readGate)
        h.store.load(videoId: "a")
        _ = await h.until { await h.likeStatusCalls().count == 1 }

        let task = h.startToggle("a")
        let sent = await h.until { await h.rateCalls().count == 1 }
        try #require(sent)
        let outcome = await task.value
        await readGate.open()
        await h.letLateWorkLand()

        #expect(outcome == .liked)
        #expect(h.store.status(of: "a") == .like)
        #expect(await h.rateCalls() == [.init(videoId: "a", status: .like)])
    }

    @Test("Two quick Likes on a song whose state is not known: the first sends a like, the second sees it and takes it back")
    func twoQuickLikesOnAnUnknownSong() async throws {
        let h = LikeHarness()
        let readGate = MusicTestGate()
        let rateGate = MusicTestGate()
        await h.backend.setLikeStatusGate(videoId: "a", readGate)
        h.store.load(videoId: "a")
        _ = await h.until { await h.likeStatusCalls().count == 1 }
        await h.backend.setRateGate(videoId: "a", rateGate)

        // The intended toggle: the first press shows the like at once, so the second press has a like to take back.
        let first = h.startToggle("a")
        let sent = await h.until { await h.rateCalls().count == 1 }
        try #require(sent)
        #expect(h.store.status(of: "a") == .like)
        let second = await h.store.toggleLike(videoId: "a")

        #expect(second == .quiet)
        #expect(h.store.status(of: "a") == .indifferent)

        await rateGate.open()
        #expect(await first.value == .likeRemoved)
        await readGate.open()
        await h.letLateWorkLand()

        #expect(h.store.status(of: "a") == .indifferent)
        #expect(await h.rateCalls() == [
            .init(videoId: "a", status: .like),
            .init(videoId: "a", status: .indifferent),
        ])
    }

    @Test("Like on a song never loaded sends the like at once and reads nothing")
    func likeDoesNotReadAnUnloadedSong() async {
        let h = LikeHarness()
        // YouTube has the song liked, but the store cannot know that without a read, and a like sent twice does no harm.
        await h.backend.setLikeStatus(videoId: "a", .like)

        #expect(await h.store.toggleLike(videoId: "a") == .liked)
        #expect(h.store.status(of: "a") == .like)
        #expect(await h.rateCalls() == [.init(videoId: "a", status: .like)])
        #expect(await h.likeStatusCalls().isEmpty)
    }

    @Test("Like on a song whose read failed likes it without a second read")
    func likeAfterFailedRead() async {
        let h = LikeHarness()
        await h.backend.setLikeStatusError(videoId: "a", MusicError.http(500))
        h.store.load(videoId: "a")
        _ = await h.until { await h.likeStatusCalls().count == 1 }
        await h.letLateWorkLand()

        #expect(await h.store.toggleLike(videoId: "a") == .liked)
        #expect(await h.rateCalls() == [.init(videoId: "a", status: .like)])
        #expect(await h.likeStatusCalls() == ["a"])
    }

    @Test("With a read out that answers liked, Like ends liked, and the next press takes the like back")
    func nextPressAfterAnUnknownLike() async throws {
        let h = LikeHarness()
        let readGate = MusicTestGate()
        await h.backend.setLikeStatus(videoId: "a", .like)
        await h.backend.setLikeStatusGate(videoId: "a", readGate)
        h.store.load(videoId: "a")
        _ = await h.until { await h.likeStatusCalls().count == 1 }

        let first = h.startToggle("a")
        let sent = await h.until { await h.rateCalls().count == 1 }
        try #require(sent)
        await readGate.open()
        #expect(await first.value == .liked)
        await h.letLateWorkLand()
        #expect(await h.store.toggleLike(videoId: "a") == .likeRemoved)

        #expect(h.store.status(of: "a") == .indifferent)
        #expect(await h.rateCalls() == [
            .init(videoId: "a", status: .like),
            .init(videoId: "a", status: .indifferent),
        ])
    }

    @Test("Like on a song whose state is known reads nothing")
    func likeKnownReadsNothing() async {
        let h = LikeHarness()
        await h.know("a", as: .indifferent)

        #expect(await h.store.toggleLike(videoId: "a") == .liked)
        #expect(await h.likeStatusCalls() == ["a"])
    }

    @Test("Dislike on a song whose state is not known yet does not wait for the read")
    func dislikeDoesNotWait() async {
        let h = LikeHarness()
        let gate = MusicTestGate()
        await h.backend.setLikeStatusGate(videoId: "a", gate)
        h.store.load(videoId: "a")
        _ = await h.until { await h.likeStatusCalls().count == 1 }
        let probe = h.probe

        let outcome = await h.store.dislike(videoId: "a") { probe.skips += 1 }

        #expect(outcome == .disliked)
        #expect(probe.skips == 1)
        await gate.open()
    }

    @Test("Like on a song with no state, or none of the two, likes it")
    func likeFromNothing() async {
        let h = LikeHarness()
        #expect(await h.store.toggleLike(videoId: "a") == .liked)
        #expect(h.store.status(of: "a") == .like)

        await h.know("b", as: .indifferent)
        #expect(await h.store.toggleLike(videoId: "b") == .liked)

        #expect(await h.rateCalls() == [
            .init(videoId: "a", status: .like),
            .init(videoId: "b", status: .like),
        ])
    }

    @Test("Like on a disliked song likes it instead")
    func likeOverDislike() async {
        let h = LikeHarness()
        await h.know("a", as: .dislike)

        #expect(await h.store.toggleLike(videoId: "a") == .liked)
        #expect(h.store.status(of: "a") == .like)
        #expect(await h.rateCalls() == [.init(videoId: "a", status: .like)])
    }

    @Test("Like on a liked song takes the like back")
    func likeToggleOff() async {
        let h = LikeHarness()
        await h.know("a", as: .like)

        #expect(await h.store.toggleLike(videoId: "a") == .likeRemoved)
        #expect(h.store.status(of: "a") == .indifferent)
        #expect(await h.rateCalls() == [.init(videoId: "a", status: .indifferent)])
    }

    @Test("The like shows at once, before YouTube has answered")
    func likeIsOptimistic() async {
        let h = LikeHarness()
        let gate = MusicTestGate()
        let task = await h.heldToggle("a", gate: gate)

        #expect(h.store.status(of: "a") == .like)

        await gate.open()
        #expect(await task.value == .liked)
        #expect(h.store.status(of: "a") == .like)
    }

    @Test("A like that fails goes back to what the song was, and says it could not reach YouTube")
    func likeRollsBack() async {
        let h = LikeHarness()
        await h.know("a", as: .dislike)
        await h.backend.setRateError(videoId: "a", URLError(.notConnectedToInternet))

        #expect(await h.store.toggleLike(videoId: "a") == .failed)
        #expect(h.store.status(of: "a") == .dislike)
        #expect(h.probe.expired == 0)
    }

    @Test("A like that fails on a song with no known state leaves it unknown")
    func likeRollsBackToUnknown() async {
        let h = LikeHarness()
        await h.backend.setRateError(videoId: "a", MusicError.http(500))

        #expect(await h.store.toggleLike(videoId: "a") == .failed)
        #expect(h.store.status(of: "a") == nil)
    }

    @Test("A like that fails on a song with no known state lets the song be read again")
    func failedLikeOnUnknownIsReread() async {
        let h = LikeHarness()
        h.store.load(videoId: "a")
        _ = await h.until { await h.likeStatusCalls().count == 1 }
        await h.letLateWorkLand()
        await h.backend.setRateError(videoId: "a", MusicError.http(500))
        #expect(await h.store.toggleLike(videoId: "a") == .failed)
        await h.backend.setLikeStatus(videoId: "a", .dislike)

        h.store.load(videoId: "a")
        let known = await h.until { h.store.status(of: "a") == .dislike }

        #expect(known)
        #expect(await h.likeStatusCalls() == ["a", "a"])
    }

    @Test("A like that fails on a song whose state is known does not ask for the state again")
    func failedLikeOnKnownIsNotReread() async {
        let h = LikeHarness()
        await h.know("a", as: .dislike)
        await h.backend.setRateError(videoId: "a", MusicError.http(500))
        #expect(await h.store.toggleLike(videoId: "a") == .failed)

        h.store.load(videoId: "a")
        await h.letLateWorkLand()

        #expect(h.store.status(of: "a") == .dislike)
        #expect(await h.likeStatusCalls() == ["a"])
    }

    @Test("A like that finds the session gone rolls back, reports it, and tells the service once")
    func likeSignedOut() async {
        let h = LikeHarness()
        await h.know("a", as: .like)
        await h.backend.setRateError(videoId: "a", MusicError.signedOut)

        #expect(await h.store.toggleLike(videoId: "a") == .signedOut)
        #expect(h.store.status(of: "a") == .like)
        #expect(h.probe.expired == 1)
    }

    // MARK: - Dislike

    @Test("Dislike on a song dislikes it, and runs the skip once the dislike is out")
    func dislikeSends() async {
        let h = LikeHarness()
        await h.know("a", as: .like)
        let probe = h.probe

        let outcome = await h.store.dislike(videoId: "a") { probe.skips += 1 }

        #expect(outcome == .disliked)
        #expect(h.store.status(of: "a") == .dislike)
        #expect(probe.skips == 1)
        #expect(await h.rateCalls() == [.init(videoId: "a", status: .dislike)])
    }

    @Test("The skip runs after the state shows the dislike and before YouTube answers")
    func skipTiming() async {
        let h = LikeHarness()
        let gate = MusicTestGate()
        await h.backend.setRateGate(videoId: "a", gate)
        let probe = h.probe
        let store = h.store
        var seenAtSkip: MusicLikeStatus?
        let task = Task { await store.dislike(videoId: "a") { seenAtSkip = store.status(of: "a"); probe.skips += 1 } }
        _ = await h.until { probe.skips == 1 }

        #expect(seenAtSkip == .dislike)
        await gate.open()
        #expect(await task.value == .disliked)
    }

    @Test("Dislike on a disliked song takes it back and does not skip")
    func dislikeToggleOff() async {
        let h = LikeHarness()
        await h.know("a", as: .dislike)
        let probe = h.probe

        let outcome = await h.store.dislike(videoId: "a") { probe.skips += 1 }

        #expect(outcome == .dislikeRemoved)
        #expect(h.store.status(of: "a") == .indifferent)
        #expect(probe.skips == 0)
        #expect(await h.rateCalls() == [.init(videoId: "a", status: .indifferent)])
    }

    @Test("A dislike that fails goes back to what the song was")
    func dislikeRollsBack() async {
        let h = LikeHarness()
        await h.know("a", as: .like)
        await h.backend.setRateError(videoId: "a", MusicError.http(503))

        #expect(await h.store.dislike(videoId: "a") == .failed)
        #expect(h.store.status(of: "a") == .like)
    }

    @Test("A dislike that finds the session gone reports it and tells the service")
    func dislikeSignedOut() async {
        let h = LikeHarness()
        await h.backend.setRateError(videoId: "a", MusicError.signedOut)

        #expect(await h.store.dislike(videoId: "a") == .signedOut)
        #expect(h.store.status(of: "a") == nil)
        #expect(h.probe.expired == 1)
    }

    // MARK: - Taps while a rating is out

    @Test("A second Like while the first is out shows at once and takes the like back once the first has landed")
    func likeTwiceInFlight() async {
        let h = LikeHarness()
        let gate = MusicTestGate()
        let first = await h.heldToggle("a", gate: gate)

        let again = await h.store.toggleLike(videoId: "a")

        #expect(again == .quiet)
        #expect(h.store.status(of: "a") == .indifferent)
        #expect(await h.rateCalls() == [.init(videoId: "a", status: .like)])

        await gate.open()

        #expect(await first.value == .likeRemoved)
        #expect(h.store.status(of: "a") == .indifferent)
        #expect(await h.rateCalls() == [
            .init(videoId: "a", status: .like),
            .init(videoId: "a", status: .indifferent),
        ])
    }

    @Test("Dislike while a like is out shows the dislike and skips at once, and is sent once the like has landed")
    func dislikeAfterLikeInFlight() async {
        let h = LikeHarness()
        let gate = MusicTestGate()
        let first = await h.heldToggle("a", gate: gate)
        let probe = h.probe

        let second = await h.store.dislike(videoId: "a") { probe.skips += 1 }

        #expect(second == .quiet)
        #expect(probe.skips == 1)
        #expect(h.store.status(of: "a") == .dislike)
        #expect(await h.rateCalls() == [.init(videoId: "a", status: .like)])

        await gate.open()

        #expect(await first.value == .disliked)
        #expect(h.store.status(of: "a") == .dislike)
        #expect(probe.skips == 1)
        #expect(await h.rateCalls() == [
            .init(videoId: "a", status: .like),
            .init(videoId: "a", status: .dislike),
        ])
    }

    @Test("Like while a dislike is out shows the like at once and is sent once the dislike has landed")
    func likeAfterDislikeInFlight() async {
        let h = LikeHarness()
        let gate = MusicTestGate()
        await h.backend.setRateGate(videoId: "a", gate)
        let store = h.store
        let probe = h.probe
        let first = Task { await store.dislike(videoId: "a") { probe.skips += 1 } }
        _ = await h.until { await h.rateCalls().count == 1 }

        let second = await h.store.toggleLike(videoId: "a")

        #expect(second == .quiet)
        #expect(h.store.status(of: "a") == .like)
        await gate.open()

        #expect(await first.value == .liked)
        #expect(h.store.status(of: "a") == .like)
        #expect(probe.skips == 1)
        #expect(await h.rateCalls() == [
            .init(videoId: "a", status: .dislike),
            .init(videoId: "a", status: .like),
        ])
    }

    @Test("A second Dislike while the first is out takes the dislike back and does not skip again")
    func dislikeTwiceInFlight() async {
        let h = LikeHarness()
        let gate = MusicTestGate()
        await h.backend.setRateGate(videoId: "a", gate)
        let store = h.store
        let probe = h.probe
        let first = Task { await store.dislike(videoId: "a") { probe.skips += 1 } }
        _ = await h.until { await h.rateCalls().count == 1 }

        let second = await h.store.dislike(videoId: "a") { probe.skips += 1 }
        await gate.open()

        #expect(second == .quiet)
        #expect(await first.value == .dislikeRemoved)
        #expect(probe.skips == 1)
        #expect(h.store.status(of: "a") == .indifferent)
    }

    @Test("Taps that end where the song already is send nothing more")
    func tapsBackToWhereItIs() async {
        let h = LikeHarness()
        let gate = MusicTestGate()
        let first = await h.heldToggle("a", gate: gate)

        _ = await h.store.dislike(videoId: "a")
        _ = await h.store.toggleLike(videoId: "a")
        #expect(h.store.status(of: "a") == .like)
        await gate.open()

        #expect(await first.value == .liked)
        #expect(h.store.status(of: "a") == .like)
        #expect(await h.rateCalls() == [.init(videoId: "a", status: .like)])
    }

    @Test("Only the latest of several taps while a rating is out is sent")
    func latestTapWins() async {
        let h = LikeHarness()
        let gate = MusicTestGate()
        let first = await h.heldToggle("a", gate: gate)

        _ = await h.store.dislike(videoId: "a")
        _ = await h.store.dislike(videoId: "a")
        _ = await h.store.toggleLike(videoId: "a")
        _ = await h.store.dislike(videoId: "a")
        #expect(h.store.status(of: "a") == .dislike)
        await gate.open()

        #expect(await first.value == .disliked)
        #expect(await h.rateCalls() == [
            .init(videoId: "a", status: .like),
            .init(videoId: "a", status: .dislike),
        ])
    }

    @Test("A follow-up that fails goes back to what the first rating left, and says so")
    func followUpFails() async {
        let h = LikeHarness()
        let gate = MusicTestGate()
        let first = await h.heldToggle("a", gate: gate)
        await h.backend.setRateError(videoId: "a", MusicError.http(500))

        _ = await h.store.dislike(videoId: "a")
        await gate.open()

        #expect(await first.value == .failed)
        #expect(h.store.status(of: "a") == .like)
        #expect(await h.rateCalls().count == 2)
    }

    @Test("When the first rating fails, the tap made meanwhile is still sent")
    func followUpAfterFailedFirst() async {
        let h = LikeHarness()
        await h.backend.setRateError(videoId: "a", MusicError.http(500))
        let gate = MusicTestGate()
        let first = await h.heldToggle("a", gate: gate)
        await h.backend.setRateError(videoId: "a", nil)

        _ = await h.store.dislike(videoId: "a")
        await gate.open()

        #expect(await first.value == .disliked)
        #expect(h.store.status(of: "a") == .dislike)
        #expect(await h.rateCalls() == [
            .init(videoId: "a", status: .like),
            .init(videoId: "a", status: .dislike),
        ])
    }

    @Test("When the first rating finds the session gone, the tap made meanwhile is dropped")
    func followUpDroppedWhenSignedOut() async {
        let h = LikeHarness()
        await h.backend.setRateError(videoId: "a", MusicError.signedOut)
        let gate = MusicTestGate()
        let first = await h.heldToggle("a", gate: gate)

        _ = await h.store.dislike(videoId: "a")
        await gate.open()

        #expect(await first.value == .signedOut)
        #expect(h.store.status(of: "a") == nil)
        #expect(h.probe.expired == 1)
        #expect(await h.rateCalls() == [.init(videoId: "a", status: .like)])
    }

    @Test("A tap made while a rating is out is dropped by a reset")
    func resetDropsFollowUp() async {
        let h = LikeHarness()
        let gate = MusicTestGate()
        let first = await h.heldToggle("a", gate: gate)

        _ = await h.store.dislike(videoId: "a")
        h.store.reset()
        await gate.open()

        #expect(await first.value == .quiet)
        #expect(h.store.status(of: "a") == nil)
        #expect(await h.rateCalls() == [.init(videoId: "a", status: .like)])
    }

    @Test("Taps on one song while its rating is out do not touch another song")
    func followUpIsLocal() async {
        let h = LikeHarness()
        let gate = MusicTestGate()
        let first = await h.heldToggle("a", gate: gate)

        _ = await h.store.dislike(videoId: "a")
        #expect(await h.store.toggleLike(videoId: "b") == .liked)
        await gate.open()
        _ = await first.value

        #expect(h.store.status(of: "a") == .dislike)
        #expect(h.store.status(of: "b") == .like)
    }

    @Test("Once the rating has landed, the next tap goes through")
    func freedAfterLanding() async {
        let h = LikeHarness()
        #expect(await h.store.toggleLike(videoId: "a") == .liked)
        #expect(await h.store.toggleLike(videoId: "a") == .likeRemoved)
        #expect(await h.rateCalls().count == 2)
    }

    @Test("Once a rating has failed, the next tap goes through")
    func freedAfterFailure() async {
        let h = LikeHarness()
        await h.backend.setRateError(videoId: "a", MusicError.http(500))
        #expect(await h.store.toggleLike(videoId: "a") == .failed)

        await h.backend.setRateError(videoId: "a", nil)
        #expect(await h.store.toggleLike(videoId: "a") == .liked)
    }

    @Test("A rating out for one song does not hold back another")
    func otherSongNotBlocked() async {
        let h = LikeHarness()
        let gate = MusicTestGate()
        let first = await h.heldToggle("a", gate: gate)

        #expect(await h.store.toggleLike(videoId: "b") == .liked)
        await gate.open()
        _ = await first.value

        #expect(h.store.status(of: "a") == .like)
        #expect(h.store.status(of: "b") == .like)
    }

    @Test("A late failure for one song rolls back only that song")
    func lateFailureIsLocal() async {
        let h = LikeHarness()
        await h.know("a", as: .indifferent)
        let gate = MusicTestGate()
        await h.backend.setRateGate(videoId: "a", gate)
        await h.backend.setRateError(videoId: "a", MusicError.http(500))
        let store = h.store
        let task = Task { await store.toggleLike(videoId: "a") }
        _ = await h.until { await h.rateCalls().count == 1 }

        #expect(await h.store.toggleLike(videoId: "b") == .liked)
        await gate.open()

        #expect(await task.value == .failed)
        #expect(h.store.status(of: "a") == .indifferent)
        #expect(h.store.status(of: "b") == .like)
    }

    // MARK: - A session that ends

    @Test("Reset forgets every song, so the next read asks again")
    func resetForgets() async {
        let h = LikeHarness()
        await h.know("a", as: .like)

        h.store.reset()
        #expect(h.store.status(of: "a") == nil)

        await h.know("a", as: .like)
        #expect(await h.likeStatusCalls() == ["a", "a"])
    }

    @Test("A rating that lands after a reset changes nothing and reports nothing")
    func resetDropsLateRating() async {
        let h = LikeHarness()
        let gate = MusicTestGate()
        await h.backend.setRateError(videoId: "a", MusicError.signedOut)
        let first = await h.heldToggle("a", gate: gate)

        h.store.reset()
        await gate.open()

        #expect(await first.value == .quiet)
        #expect(h.store.status(of: "a") == nil)
        #expect(h.probe.expired == 0)
    }

    @Test("A read that lands after a reset is dropped")
    func resetDropsLateRead() async {
        let h = LikeHarness()
        let gate = MusicTestGate()
        await h.backend.setLikeStatus(videoId: "a", .like)
        await h.backend.setLikeStatusGate(videoId: "a", gate)
        h.store.load(videoId: "a")
        _ = await h.until { await h.likeStatusCalls().count == 1 }

        h.store.reset()
        await gate.open()
        await h.letLateWorkLand()

        #expect(h.store.status(of: "a") == nil)
    }

    @Test("After a reset, a rating of a song whose old rating is still out goes through")
    func resetFreesTheSong() async {
        let h = LikeHarness()
        let gate = MusicTestGate()
        let first = await h.heldToggle("a", gate: gate)
        h.store.reset()
        await h.backend.setRateGate(videoId: "a", nil)

        #expect(await h.store.toggleLike(videoId: "a") == .liked)
        await gate.open()
        _ = await first.value

        #expect(h.store.status(of: "a") == .like)
    }

    // MARK: - Setting a rating

    @Test("Set sends the status asked for on a song never read, and reads nothing first")
    func setSendsWithoutReading() async {
        let h = LikeHarness()

        #expect(await h.store.set(.like, videoId: "a") == .liked)

        #expect(h.store.status(of: "a") == .like)
        #expect(await h.rateCalls() == [.init(videoId: "a", status: .like)])
        #expect(await h.likeStatusCalls().isEmpty)
    }

    @Test("Set is not a toggle: Like on a liked song and Dislike on a disliked one are sent again")
    func setIsIdempotent() async {
        let h = LikeHarness()
        await h.know("a", as: .like)
        await h.know("b", as: .dislike)

        #expect(await h.store.set(.like, videoId: "a") == .liked)
        #expect(await h.store.set(.dislike, videoId: "b") == .disliked)

        #expect(h.store.status(of: "a") == .like)
        #expect(h.store.status(of: "b") == .dislike)
        #expect(await h.rateCalls() == [.init(videoId: "a", status: .like), .init(videoId: "b", status: .dislike)])
    }

    @Test("Setting a song to neither takes back what it had: Remove like on a liked song, Remove dislike on a disliked one")
    func setIndifferent() async {
        let h = LikeHarness()
        await h.know("a", as: .like)
        await h.know("b", as: .dislike)

        #expect(await h.store.set(.indifferent, videoId: "a") == .likeRemoved)
        #expect(await h.store.set(.indifferent, videoId: "b") == .dislikeRemoved)

        #expect(h.store.status(of: "a") == .indifferent)
        #expect(h.store.status(of: "b") == .indifferent)
        #expect(await h.rateCalls() == [.init(videoId: "a", status: .indifferent), .init(videoId: "b", status: .indifferent)])
    }

    @Test("Set moves a song straight from one rating to the other")
    func setSwitches() async {
        let h = LikeHarness()
        await h.know("a", as: .like)

        #expect(await h.store.set(.dislike, videoId: "a") == .disliked)
        #expect(h.store.status(of: "a") == .dislike)
        #expect(await h.store.set(.like, videoId: "a") == .liked)
        #expect(h.store.status(of: "a") == .like)
    }

    @Test("Only a dislike runs the skip, and it runs once, after the state shows the dislike")
    func setSkipsOnlyForDislike() async {
        let h = LikeHarness()
        let probe = h.probe
        let store = h.store
        var seenAtSkip: MusicLikeStatus?

        _ = await store.set(.like, videoId: "a") { probe.skips += 1 }
        _ = await store.set(.indifferent, videoId: "a") { probe.skips += 1 }
        #expect(probe.skips == 0)

        _ = await store.set(.dislike, videoId: "a") { seenAtSkip = store.status(of: "a"); probe.skips += 1 }
        #expect(probe.skips == 1)
        #expect(seenAtSkip == .dislike)
    }

    @Test("A set that fails goes back to what the song was and says it could not reach YouTube")
    func setRollsBack() async {
        let h = LikeHarness()
        await h.know("a", as: .like)
        await h.backend.setRateError(videoId: "a", URLError(.notConnectedToInternet))

        #expect(await h.store.set(.dislike, videoId: "a") == .failed)

        #expect(h.store.status(of: "a") == .like)
        #expect(h.probe.expired == 0)
    }

    @Test("A set that finds the session gone rolls back, reports it, and tells the service once")
    func setSignedOut() async {
        let h = LikeHarness()
        await h.know("a", as: .dislike)
        await h.backend.setRateError(videoId: "a", MusicError.signedOut)

        #expect(await h.store.set(.like, videoId: "a") == .signedOut)

        #expect(h.store.status(of: "a") == .dislike)
        #expect(h.probe.expired == 1)
    }

    @Test("A set on a song whose rating is out shows at once, answers quietly and is sent when the first call is back")
    func setWhileOut() async {
        let h = LikeHarness()
        let gate = MusicTestGate()
        let first = await h.heldToggle("a", gate: gate)

        let second = await h.store.set(.dislike, videoId: "a")

        #expect(second == .quiet)
        #expect(h.store.status(of: "a") == .dislike)
        #expect(await h.rateCalls() == [.init(videoId: "a", status: .like)])

        await gate.open()

        #expect(await first.value == .disliked)
        #expect(await h.rateCalls() == [.init(videoId: "a", status: .like), .init(videoId: "a", status: .dislike)])
    }

    @Test("A set for one song does not hold back another song's, and a failure rolls back only its own")
    func setPerSong() async {
        let h = LikeHarness()
        await h.know("a", as: .like)
        await h.know("b", as: .like)
        await h.backend.setRateError(videoId: "a", URLError(.timedOut))

        #expect(await h.store.set(.dislike, videoId: "a") == .failed)
        #expect(await h.store.set(.indifferent, videoId: "b") == .likeRemoved)

        #expect(h.store.status(of: "a") == .like)
        #expect(h.store.status(of: "b") == .indifferent)
    }

    @Test("A set with a blank video id sends nothing")
    func setBlankId() async {
        let h = LikeHarness()

        #expect(await h.store.set(.like, videoId: "  ") == .quiet)
        #expect(await h.store.set(.dislike, videoId: "") == .quiet)

        #expect(await h.rateCalls().isEmpty)
        #expect(h.store.statuses.isEmpty)
    }

    @Test("A set that lands after a reset changes nothing and reports nothing")
    func setAfterReset() async {
        let h = LikeHarness()
        let gate = MusicTestGate()
        await h.backend.setRateGate(videoId: "a", gate)
        let store = h.store
        let task = Task { await store.set(.like, videoId: "a") }
        _ = await h.until { await h.rateCalls().count == 1 }

        store.reset()
        await gate.open()

        #expect(await task.value == .quiet)
        #expect(store.status(of: "a") == nil)
    }

    // MARK: - Telling that a rating shows

    @Test("A like is told as soon as the state shows it, before YouTube has answered, with what the song was")
    func shownAtTheOptimisticSwitch() async {
        let h = LikeHarness()
        await h.know("a", as: .indifferent)
        let gate = MusicTestGate()
        let task = await h.heldToggle("a", gate: gate)

        #expect(h.probe.shown == [.init(videoId: "a", status: .like, previous: .indifferent)])

        await gate.open()
        #expect(await task.value == .liked)
        // The answer coming back is not a second showing.
        #expect(h.probe.shown.count == 1)
    }

    @Test("A song that was not known yet shows its first rating with no earlier state")
    func shownWithNoEarlierState() async {
        let h = LikeHarness()
        _ = await h.store.dislike(videoId: "a")
        #expect(h.probe.shown == [.init(videoId: "a", status: .dislike, previous: nil)])
    }

    @Test("Taking a rating back is told too, as the state it went to, so the listener can tell it from a rating")
    func removalIsShown() async {
        let h = LikeHarness()
        await h.know("a", as: .like)
        #expect(await h.store.set(.indifferent, videoId: "a") == .likeRemoved)
        #expect(h.probe.shown == [.init(videoId: "a", status: .indifferent, previous: .like)])
    }

    @Test("A dislike is told before the skip runs, so the song is still the one that was rated")
    func shownBeforeTheSkip() async {
        let h = LikeHarness()
        let probe = h.probe
        var shownAtSkip = 0
        _ = await h.store.dislike(videoId: "a") { shownAtSkip = probe.shown.count }
        #expect(shownAtSkip == 1)
    }

    @Test("A tap on a song whose rating is out is told at once, and not again when the call that is out sends it")
    func tapWhileOutIsShownOnce() async {
        let h = LikeHarness()
        let gate = MusicTestGate()
        let first = await h.heldToggle("a", gate: gate)
        #expect(h.probe.shown.map(\.status) == [.like])

        _ = await h.store.dislike(videoId: "a")
        #expect(h.probe.shown == [
            .init(videoId: "a", status: .like, previous: nil),
            .init(videoId: "a", status: .dislike, previous: .like),
        ])

        await gate.open()
        _ = await first.value
        #expect(h.probe.shown.count == 2)
        #expect(h.store.status(of: "a") == .dislike)
    }

    @Test("A rating that fails is not told again when it rolls back")
    func rollbackIsNotShown() async {
        let h = LikeHarness()
        await h.know("a", as: .indifferent)
        await h.backend.setRateError(videoId: "a", MusicError.http(500))
        #expect(await h.store.toggleLike(videoId: "a") == .failed)
        #expect(h.store.status(of: "a") == .indifferent)
        #expect(h.probe.shown == [.init(videoId: "a", status: .like, previous: .indifferent)])
    }

    @Test("A state read from YouTube is not a rating and is not told")
    func readsAreNotShown() async {
        let h = LikeHarness()
        await h.know("a", as: .like)
        #expect(h.probe.shown.isEmpty)
    }

    @Test("A blank video id shows nothing")
    func blankShowsNothing() async {
        let h = LikeHarness()
        _ = await h.store.set(.like, videoId: " ")
        #expect(h.probe.shown.isEmpty)
    }
}
