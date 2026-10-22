// DeciTests/Music/MusicRelatedStoreTests.swift
// The related songs panel's state: a pinned song, album, playlist or artist and a seed that follows the player; the
// loading, loaded, empty, no-seed and failed states; the small cache of recent seeds; and an answer that is dropped
// when the seed changed, the panel closed or the session ended while it was out.

import Foundation
import Testing
@testable import Deci

@MainActor
private final class RelatedProbe {
    var expired = 0
}

@MainActor
private struct RelatedHarness {
    let backend = FakeMusicBackend()
    let browse: MusicBrowseStore
    let store: MusicRelatedStore
    let probe = RelatedProbe()

    /// `sleep` stands in for the wait before a changed now-playing song is asked for; it returns at once unless a test
    /// passes one that parks.
    init(sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in }) {
        browse = MusicBrowseStore(backend: backend)
        store = MusicRelatedStore(backend: backend, browse: browse, sleep: sleep)
        let probe = self.probe
        store.onSessionExpired = { probe.expired += 1 }
    }

    func until(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<400 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }

    /// Waits until the store has left `.loading`.
    func settled() async {
        _ = await until { store.state != .loading }
    }

    /// Gives an answer that should be dropped time to arrive, so a missing drop would show.
    func letLateWorkLand() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(40))
    }

    func relatedCalls() async -> [String] { await backend.relatedCalls }
    func pageCalls() async -> [String] { await backend.pageCalls }

    /// Scripts the songs YouTube answers for `seed`.
    func script(_ seed: String, _ ids: String...) async {
        await backend.setRelated(videoId: seed, ids.map { MusicSamples.track($0, title: "Song \($0)") })
    }
}

/// The waits the store asked its injected sleep for.
private actor SleepLog {
    private(set) var durations: [Duration] = []

    func record(_ duration: Duration) { durations.append(duration) }
}

private func song(_ id: String) -> MusicTrack { MusicSamples.track(id, title: "Song \(id)") }

private func ids(_ state: MusicRelatedStore.State) -> [String]? {
    guard case .loaded(let tracks) = state else { return nil }
    return tracks.map(\.videoId)
}

@MainActor
@Suite("MusicRelatedStore")
struct MusicRelatedStoreTests {
    static let failureText = "Couldn't load related songs."

    // MARK: - A song as the seed

    @Test("A new store shows nothing and has no seed")
    func startsIdle() {
        let h = RelatedHarness()
        #expect(h.store.state == .idle)
        #expect(h.store.seed == nil)
        #expect(h.store.subline == nil)
    }

    @Test("Showing a song loads its related songs and names the song in the subline")
    func showSong() async {
        let h = RelatedHarness()
        await h.script("a", "r1", "r2")

        h.store.show(song("a"))
        #expect(h.store.state == .loading)
        #expect(h.store.seed?.videoId == "a")
        #expect(h.store.subline == "From Song a")

        await h.settled()
        #expect(ids(h.store.state) == ["r1", "r2"])
        #expect(await h.relatedCalls() == ["a"])
    }

    @Test("A song with no related songs lands on the empty state")
    func emptyAnswer() async {
        let h = RelatedHarness()
        h.store.show(song("a"))
        await h.settled()
        #expect(h.store.state == .empty)
    }

    @Test("A blank video id has no seed and asks nothing")
    func blankSeed() async {
        let h = RelatedHarness()
        h.store.show(MusicSamples.track("  ", title: "Nameless"))
        await h.letLateWorkLand()
        #expect(h.store.state == .noSeed)
        #expect(h.store.seed == nil)
        #expect(await h.relatedCalls().isEmpty)
    }

    @Test("The panel's three messages read as written, and none has an em-dash")
    func messages() {
        #expect(MusicRelatedStore.emptyMessage == "No related songs for this one.")
        #expect(MusicRelatedStore.noSeedMessage == "No song to find related songs for.")
        #expect(MusicRelatedStore.failureMessage == "Couldn't load related songs.")
        let emDash = Character(UnicodeScalar(0x2014)!)
        for message in [MusicRelatedStore.emptyMessage, MusicRelatedStore.noSeedMessage, MusicRelatedStore.failureMessage] {
            #expect(!message.contains(emDash))
        }
    }

    // MARK: - Failures

    @Test("A failed call lands on a failed state with the panel's words, and says nothing else")
    func failure() async {
        let h = RelatedHarness()
        await h.backend.setRelatedError(videoId: "a", MusicError.http(500))
        h.store.show(song("a"))
        await h.settled()
        #expect(h.store.state == .failed(Self.failureText))
        #expect(h.probe.expired == 0)
    }

    @Test("Retry asks again after a failure and lands the answer")
    func retryAfterFailure() async {
        let h = RelatedHarness()
        await h.script("a", "r1")
        await h.backend.setRelatedError(videoId: "a", MusicError.http(500))
        h.store.show(song("a"))
        await h.settled()

        await h.backend.setRelatedError(videoId: "a", nil)
        h.store.retry()
        #expect(h.store.state == .loading)
        await h.settled()

        #expect(ids(h.store.state) == ["r1"])
        #expect(await h.relatedCalls() == ["a", "a"])
    }

    @Test("Retry does nothing unless the last load failed")
    func retryOnlyAfterFailure() async {
        let h = RelatedHarness()
        await h.script("a", "r1")
        h.store.retry()
        h.store.show(song("a"))
        await h.settled()
        h.store.retry()
        await h.letLateWorkLand()
        #expect(await h.relatedCalls() == ["a"])
        #expect(ids(h.store.state) == ["r1"])
    }

    @Test("A failed answer is not kept: showing the song again asks again")
    func failureNotCached() async {
        let h = RelatedHarness()
        await h.backend.setRelatedError(videoId: "a", MusicError.http(500))
        h.store.show(song("a"))
        await h.settled()
        await h.backend.setRelatedError(videoId: "a", nil)
        await h.script("a", "r1")

        h.store.show(song("a"))
        await h.settled()
        #expect(ids(h.store.state) == ["r1"])
    }

    @Test("A gone session tells the service once and shows the failed state")
    func sessionGone() async {
        let h = RelatedHarness()
        await h.backend.setRelatedError(videoId: "a", MusicError.signedOut)
        h.store.show(song("a"))
        await h.settled()
        #expect(h.probe.expired == 1)
        #expect(h.store.state == .failed(Self.failureText))
    }

    // MARK: - The cache

    @Test("Going back to a song shows its songs at once and asks nothing more")
    func cacheHit() async {
        let h = RelatedHarness()
        await h.script("a", "r1")
        await h.script("b", "r2")
        h.store.show(song("a"))
        await h.settled()
        h.store.show(song("b"))
        await h.settled()

        h.store.show(song("a"))
        #expect(ids(h.store.state) == ["r1"])
        await h.letLateWorkLand()
        #expect(await h.relatedCalls() == ["a", "b"])
    }

    @Test("Only the last ten seeds are kept, the least recently shown goes first")
    func cacheIsBounded() async {
        let h = RelatedHarness()
        let seeds = (1...11).map { "s\($0)" }
        for seed in seeds {
            await h.script(seed, "r-\(seed)")
            h.store.show(song(seed))
            await h.settled()
        }
        #expect(await h.relatedCalls() == seeds)

        // s1 was the oldest of eleven: gone. s2 is still there.
        h.store.show(song("s2"))
        #expect(ids(h.store.state) == ["r-s2"])
        h.store.show(song("s1"))
        #expect(h.store.state == .loading)
        await h.settled()
        #expect(await h.relatedCalls() == seeds + ["s1"])
    }

    @Test("Showing a cached song makes it the newest, so it outlives older ones")
    func cacheTouch() async {
        let h = RelatedHarness()
        let seeds = (1...10).map { "s\($0)" }
        for seed in seeds {
            await h.script(seed, "r-\(seed)")
            h.store.show(song(seed))
            await h.settled()
        }
        h.store.show(song("s1"))
        await h.script("s11", "r-s11")
        h.store.show(song("s11"))
        await h.settled()

        // s2 was pushed out by the eleventh, s1 was kept by being shown again.
        h.store.show(song("s1"))
        #expect(ids(h.store.state) == ["r-s1"])
        h.store.show(song("s2"))
        #expect(h.store.state == .loading)
    }

    @Test("An empty answer is not kept: the song is asked again")
    func emptyNotCached() async {
        let h = RelatedHarness()
        h.store.show(song("a"))
        await h.settled()
        await h.script("a", "r1")

        h.store.show(song("a"))
        await h.settled()
        #expect(ids(h.store.state) == ["r1"])
        #expect(await h.relatedCalls() == ["a", "a"])
    }

    // MARK: - Answers that arrive too late

    @Test("A slow answer for an earlier seed does not replace the later seed's songs")
    func staleSeed() async {
        let h = RelatedHarness()
        let gate = MusicTestGate()
        await h.script("a", "late")
        await h.script("b", "r2")
        await h.backend.setRelatedGate(videoId: "a", gate)

        h.store.show(song("a"))
        _ = await h.until { await h.relatedCalls() == ["a"] }
        h.store.show(song("b"))
        await h.settled()
        await gate.open()
        await h.letLateWorkLand()

        #expect(ids(h.store.state) == ["r2"])
        #expect(h.store.seed?.videoId == "b")
        // The dropped answer is not cached either.
        h.store.show(song("a"))
        #expect(h.store.state == .loading)
    }

    @Test("Closing drops the answer that is out and leaves the store idle")
    func closeDropsAnswer() async {
        let h = RelatedHarness()
        let gate = MusicTestGate()
        await h.script("a", "r1")
        await h.backend.setRelatedGate(videoId: "a", gate)
        h.store.show(song("a"))
        _ = await h.until { await h.relatedCalls() == ["a"] }

        h.store.close()
        await gate.open()
        await h.letLateWorkLand()

        #expect(h.store.state == .idle)
        #expect(h.store.seed == nil)
        #expect(h.store.subline == nil)
    }

    @Test("A session that ends drops the answer that is out and clears the cache and the seed")
    func resetDropsEverything() async {
        let h = RelatedHarness()
        let gate = MusicTestGate()
        await h.script("a", "r1")
        await h.script("b", "r2")
        h.store.show(song("b"))
        await h.settled()
        await h.backend.setRelatedGate(videoId: "a", gate)
        h.store.show(song("a"))
        _ = await h.until { await h.relatedCalls() == ["b", "a"] }

        h.store.reset()
        await gate.open()
        await h.letLateWorkLand()

        #expect(h.store.state == .idle)
        #expect(h.store.seed == nil)
        // Nothing of the old session is kept: b is asked for again.
        h.store.show(song("b"))
        #expect(h.store.state == .loading)
        await h.settled()
        #expect(await h.relatedCalls() == ["b", "a", "b"])
    }

    @Test("A failure that arrives after the seed changed is dropped, and does not tell the service twice")
    func staleFailure() async {
        let h = RelatedHarness()
        let gate = MusicTestGate()
        await h.script("b", "r2")
        await h.backend.setRelatedError(videoId: "a", MusicError.signedOut)
        await h.backend.setRelatedGate(videoId: "a", gate)
        h.store.show(song("a"))
        _ = await h.until { await h.relatedCalls() == ["a"] }
        h.store.show(song("b"))
        await h.settled()

        await gate.open()
        await h.letLateWorkLand()

        #expect(ids(h.store.state) == ["r2"])
        #expect(h.probe.expired == 0)
    }

    // MARK: - Following the player

    @Test("Following shows the playing song's related songs and reloads when the song changes")
    func followsPlayer() async {
        let h = RelatedHarness()
        await h.script("a", "r1")
        await h.script("b", "r2")

        h.store.follow(song("a"))
        await h.settled()
        #expect(ids(h.store.state) == ["r1"])
        #expect(h.store.subline == "From Song a")

        h.store.nowPlayingChanged(song("b"))
        #expect(h.store.state == .loading)
        #expect(h.store.subline == "From Song b")
        await h.settled()
        #expect(ids(h.store.state) == ["r2"])
        #expect(h.store.seed?.videoId == "b")
        #expect(await h.relatedCalls() == ["a", "b"])
    }

    @Test("The same song reported again does not reload")
    func sameSongAgain() async {
        let h = RelatedHarness()
        await h.script("a", "r1")
        h.store.follow(song("a"))
        await h.settled()

        h.store.nowPlayingChanged(song("a"))
        await h.letLateWorkLand()
        #expect(ids(h.store.state) == ["r1"])
        #expect(await h.relatedCalls() == ["a"])
    }

    @Test("When nothing plays any more the store has no seed, and the next song loads again")
    func playerStops() async {
        let h = RelatedHarness()
        await h.script("a", "r1")
        await h.script("c", "r3")
        h.store.follow(song("a"))
        await h.settled()

        h.store.nowPlayingChanged(nil)
        #expect(h.store.state == .noSeed)
        #expect(h.store.seed == nil)
        #expect(h.store.subline == nil)

        h.store.nowPlayingChanged(song("c"))
        await h.settled()
        #expect(ids(h.store.state) == ["r3"])
    }

    @Test("Following with nothing playing has no seed")
    func followNothing() async {
        let h = RelatedHarness()
        h.store.follow(nil)
        #expect(h.store.state == .noSeed)
        #expect(await h.relatedCalls().isEmpty)
    }

    @Test("A changed song waits a moment, so skipping through a queue asks only for the song it stops on")
    func followDebounce() async {
        let gate = MusicTestGate()
        let h = RelatedHarness(sleep: { _ in await gate.wait() })
        await h.script("a", "r1")
        await h.script("c", "r3")
        h.store.follow(song("a"))
        await h.settled()

        h.store.nowPlayingChanged(song("b"))
        h.store.nowPlayingChanged(song("c"))
        await h.letLateWorkLand()
        #expect(await h.relatedCalls() == ["a"])
        #expect(h.store.state == .loading)

        await gate.open()
        await h.settled()
        #expect(ids(h.store.state) == ["r3"])
        #expect(await h.relatedCalls() == ["a", "c"])
    }

    @Test("A song from a menu stays: the player's songs do not move it")
    func pinnedIgnoresPlayer() async {
        let h = RelatedHarness()
        await h.script("x", "rx")
        h.store.show(song("x"))
        await h.settled()

        h.store.nowPlayingChanged(song("y"))
        await h.letLateWorkLand()

        #expect(ids(h.store.state) == ["rx"])
        #expect(h.store.seed?.videoId == "x")
        #expect(await h.relatedCalls() == ["x"])
    }

    @Test("Showing a song while following pins it, and a later player change is ignored")
    func showEndsFollowing() async {
        let h = RelatedHarness()
        await h.script("a", "r1")
        await h.script("x", "rx")
        h.store.follow(song("a"))
        await h.settled()
        h.store.show(song("x"))
        await h.settled()

        h.store.nowPlayingChanged(song("b"))
        await h.letLateWorkLand()

        #expect(ids(h.store.state) == ["rx"])
        #expect(await h.relatedCalls() == ["a", "x"])
    }

    @Test("Following again after a pinned song picks the playing song up")
    func followAfterPinned() async {
        let h = RelatedHarness()
        await h.script("x", "rx")
        await h.script("a", "r1")
        h.store.show(song("x"))
        await h.settled()

        h.store.follow(song("a"))
        await h.settled()
        #expect(ids(h.store.state) == ["r1"])
        h.store.nowPlayingChanged(song("b"))
        #expect(h.store.seed?.videoId == "b")
    }

    @Test("A player change while the panel is closed does nothing, before it was ever opened and after")
    func closedIgnoresPlayer() async {
        let h = RelatedHarness()
        await h.script("a", "r1")
        h.store.nowPlayingChanged(song("a"))
        #expect(h.store.state == .idle)

        h.store.follow(song("a"))
        await h.settled()
        h.store.close()
        h.store.nowPlayingChanged(song("b"))
        await h.letLateWorkLand()

        #expect(h.store.state == .idle)
        #expect(await h.relatedCalls() == ["a"])
    }

    @Test("A debounced change that is closed before the wait ends asks nothing")
    func closeDuringDebounce() async {
        let gate = MusicTestGate()
        let h = RelatedHarness(sleep: { _ in await gate.wait() })
        await h.script("a", "r1")
        await h.script("b", "r2")
        h.store.follow(song("a"))
        await h.settled()
        h.store.nowPlayingChanged(song("b"))

        h.store.close()
        await gate.open()
        await h.letLateWorkLand()

        #expect(h.store.state == .idle)
        #expect(await h.relatedCalls() == ["a"])
    }

    // MARK: - Albums, playlists and artists

    @Test("A collection is seeded with the first song of its page, read through the page call")
    func collectionSeed() async {
        for kind in [MusicCollection.Kind.album, .playlist, .artist] {
            let h = RelatedHarness()
            let collection = MusicSamples.collection("page-\(kind)", kind: kind, title: "The \(kind)")
            await h.backend.setPage(MusicSamples.page(collection.browseId, tracks: [song("t1"), song("t2")]))
            await h.script("t1", "r1")

            h.store.show(collection)
            #expect(h.store.state == .loading)
            #expect(h.store.seed == nil)
            #expect(h.store.subline == "From The \(kind)")
            await h.settled()

            #expect(ids(h.store.state) == ["r1"])
            #expect(h.store.seed?.videoId == "t1")
            #expect(h.store.subline == "From The \(kind)")
            #expect(await h.pageCalls() == [collection.browseId])
            #expect(await h.relatedCalls() == ["t1"])
            #expect(h.browse.path.isEmpty)
        }
    }

    @Test("A page the browse store already holds is used without reading it again")
    func collectionUsesLoadedPage() async {
        let h = RelatedHarness()
        let collection = MusicSamples.collection("MPREb1", kind: .album, title: "Album")
        await h.backend.setPage(MusicSamples.page(collection.browseId, tracks: [song("t1")]))
        await h.script("t1", "r1")
        h.browse.reloadPage(collection.browseId)
        _ = await h.until { h.browse.pageState(collection.browseId) != .loading }
        #expect(await h.pageCalls() == [collection.browseId])

        h.store.show(collection)
        await h.settled()

        #expect(ids(h.store.state) == ["r1"])
        #expect(await h.pageCalls() == [collection.browseId])
    }

    @Test("The first song with a usable id seeds the collection")
    func collectionSkipsBlankIds() async {
        let h = RelatedHarness()
        let collection = MusicSamples.collection("VLPL1", title: "Mix")
        await h.backend.setPage(MusicSamples.page(collection.browseId, tracks: [
            MusicSamples.track(" ", title: "Nameless"), song("t2")
        ]))
        await h.script("t2", "r2")

        h.store.show(collection)
        await h.settled()

        #expect(h.store.seed?.videoId == "t2")
        #expect(ids(h.store.state) == ["r2"])
    }

    @Test("A page with no songs has no seed, and the related call is never made")
    func collectionWithoutSongs() async {
        let h = RelatedHarness()
        let collection = MusicSamples.collection("UC1", kind: .artist, title: "Quiet Artist")
        await h.backend.setPage(MusicSamples.page(collection.browseId))

        h.store.show(collection)
        await h.settled()

        #expect(h.store.state == .noSeed)
        #expect(h.store.seed == nil)
        #expect(h.store.subline == "From Quiet Artist")
        #expect(await h.relatedCalls().isEmpty)
    }

    @Test("A page that fails to load shows the failed state, and Retry reads the page again")
    func collectionPageFails() async {
        let h = RelatedHarness()
        let collection = MusicSamples.collection("MPREb1", kind: .album, title: "Album")
        await h.backend.setPageError(collection.browseId, MusicError.http(503))
        h.store.show(collection)
        await h.settled()
        #expect(h.store.state == .failed(Self.failureText))

        await h.backend.setPageError(collection.browseId, nil)
        await h.backend.setPage(MusicSamples.page(collection.browseId, tracks: [song("t1")]))
        await h.script("t1", "r1")
        h.store.retry()
        await h.settled()

        #expect(ids(h.store.state) == ["r1"])
        #expect(await h.pageCalls() == [collection.browseId, collection.browseId])
    }

    @Test("Retry after a failed related call on a collection keeps its seed and asks only the related call again")
    func collectionRelatedFails() async {
        let h = RelatedHarness()
        let collection = MusicSamples.collection("MPREb1", kind: .album, title: "Album")
        await h.backend.setPage(MusicSamples.page(collection.browseId, tracks: [song("t1")]))
        await h.backend.setRelatedError(videoId: "t1", MusicError.http(500))
        h.store.show(collection)
        await h.settled()
        #expect(h.store.state == .failed(Self.failureText))

        await h.backend.setRelatedError(videoId: "t1", nil)
        await h.script("t1", "r1")
        h.store.retry()
        await h.settled()

        #expect(ids(h.store.state) == ["r1"])
        #expect(await h.pageCalls() == [collection.browseId])
    }

    @Test("A session that ends while a collection's page is out drops its answer")
    func collectionPageStale() async {
        let h = RelatedHarness()
        let gate = MusicTestGate()
        let collection = MusicSamples.collection("MPREb1", kind: .album, title: "Album")
        await h.backend.setPage(MusicSamples.page(collection.browseId, tracks: [song("t1")]))
        await h.backend.setPageGate(collection.browseId, gate)
        await h.script("t1", "r1")
        h.store.show(collection)
        _ = await h.until { await h.pageCalls() == [collection.browseId] }

        h.store.reset()
        await gate.open()
        await h.letLateWorkLand()

        #expect(h.store.state == .idle)
        #expect(await h.relatedCalls().isEmpty)
    }

    @Test("A second collection chosen while the first one's page is out wins")
    func collectionReplaced() async {
        let h = RelatedHarness()
        let gate = MusicTestGate()
        let first = MusicSamples.collection("MPREb1", kind: .album, title: "First")
        let second = MusicSamples.collection("MPREb2", kind: .album, title: "Second")
        await h.backend.setPage(MusicSamples.page(first.browseId, tracks: [song("t1")]))
        await h.backend.setPage(MusicSamples.page(second.browseId, tracks: [song("t2")]))
        await h.backend.setPageGate(first.browseId, gate)
        await h.script("t1", "r1")
        await h.script("t2", "r2")
        h.store.show(first)
        _ = await h.until { await h.pageCalls() == [first.browseId] }

        h.store.show(second)
        await h.settled()
        await gate.open()
        await h.letLateWorkLand()

        #expect(ids(h.store.state) == ["r2"])
        #expect(h.store.subline == "From Second")
        #expect(await h.relatedCalls() == ["t2"])
    }

    @Test("A collection whose seed song was seen before shows the cached songs without a related call")
    func collectionUsesCache() async {
        let h = RelatedHarness()
        let collection = MusicSamples.collection("MPREb1", kind: .album, title: "Album")
        await h.backend.setPage(MusicSamples.page(collection.browseId, tracks: [song("t1")]))
        await h.script("t1", "r1")
        h.store.show(song("t1"))
        await h.settled()

        h.store.show(collection)
        await h.settled()

        #expect(ids(h.store.state) == ["r1"])
        #expect(await h.relatedCalls() == ["t1"])
    }

    @Test("A collection with a blank browse id has no seed and reads nothing")
    func collectionBlankId() async {
        let h = RelatedHarness()
        h.store.show(MusicSamples.collection(" ", kind: .album, title: "Blank"))
        await h.letLateWorkLand()
        #expect(h.store.state == .noSeed)
        #expect(await h.pageCalls().isEmpty)
    }

    // MARK: - The popup is hidden

    /// A store that follows song "a", whose related songs are in, with the popup then hidden.
    private func followingA(_ h: RelatedHarness) async {
        await h.script("a", "ra")
        h.store.follow(song("a"))
        await h.settled()
        h.store.setPopupVisible(false)
    }

    @Test("The store starts with the popup visible, and says what it was told")
    func popupVisibleState() {
        let h = RelatedHarness()
        #expect(h.store.isPopupVisible)
        h.store.setPopupVisible(false)
        #expect(h.store.isPopupVisible == false)
        h.store.setPopupVisible(true)
        #expect(h.store.isPopupVisible)
    }

    @Test("While the popup is hidden a followed panel asks for nothing, however many songs play")
    func hiddenFollowSendsNothing() async {
        let h = RelatedHarness()
        await followingA(h)

        for id in ["b", "c", "d", "e"] {
            h.store.nowPlayingChanged(song(id))
        }
        await h.letLateWorkLand()

        #expect(await h.relatedCalls() == ["a"])
        #expect(h.store.seed?.videoId == "e")
        #expect(h.store.subline == "From Song e")
        #expect(h.store.state == .loading)
    }

    @Test("A followed panel that comes back into view asks once, for the song it stopped on")
    func reappearAsksOnce() async {
        let h = RelatedHarness()
        await followingA(h)
        await h.script("e", "re")
        for id in ["b", "c", "d", "e"] {
            h.store.nowPlayingChanged(song(id))
        }
        await h.letLateWorkLand()

        h.store.setPopupVisible(true)
        await h.settled()

        #expect(await h.relatedCalls() == ["a", "e"])
        #expect(ids(h.store.state) == ["re"])
        #expect(h.store.seed?.videoId == "e")

        // Nothing is stale any more: another hide and show asks nothing.
        h.store.setPopupVisible(false)
        h.store.setPopupVisible(true)
        await h.letLateWorkLand()
        #expect(await h.relatedCalls() == ["a", "e"])
    }

    @Test("Coming back into view with the panel on the song it already shows asks nothing")
    func reappearWithNothingStale() async {
        let h = RelatedHarness()
        await followingA(h)
        h.store.setPopupVisible(true)
        await h.letLateWorkLand()

        #expect(await h.relatedCalls() == ["a"])
        #expect(ids(h.store.state) == ["ra"])
    }

    @Test("A hidden change that lands on a song with kept answers shows them at once and asks nothing, hidden or back")
    func hiddenChangeToACachedSong() async {
        let h = RelatedHarness()
        await h.script("b", "rb")
        h.store.follow(song("b"))
        await h.settled()
        await followingA(h)
        h.store.nowPlayingChanged(song("b"))
        #expect(ids(h.store.state) == ["rb"])

        h.store.setPopupVisible(true)
        await h.letLateWorkLand()

        #expect(await h.relatedCalls() == ["b", "a"])
        #expect(ids(h.store.state) == ["rb"])
    }

    @Test("The wait before a changed song is asked for ends while the popup is hidden: nothing is sent, and it waits")
    func debounceEndsHidden() async {
        let gate = MusicTestGate()
        let h = RelatedHarness(sleep: { _ in await gate.wait() })
        await h.script("a", "ra")
        await h.script("b", "rb")
        h.store.follow(song("a"))
        await h.settled()
        h.store.nowPlayingChanged(song("b"))
        h.store.setPopupVisible(false)

        await gate.open()
        await h.letLateWorkLand()
        #expect(await h.relatedCalls() == ["a"])

        h.store.setPopupVisible(true)
        await h.settled()
        #expect(await h.relatedCalls() == ["a", "b"])
        #expect(ids(h.store.state) == ["rb"])
    }

    @Test("A song that changes while hidden sends no call, so a dead session is not reported from there")
    func hiddenNeverReportsExpiry() async {
        let h = RelatedHarness()
        await followingA(h)
        await h.backend.setRelatedError(videoId: "b", MusicError.signedOut)

        h.store.nowPlayingChanged(song("b"))
        await h.letLateWorkLand()

        #expect(h.probe.expired == 0)
        #expect(await h.relatedCalls() == ["a"])
    }

    @Test("A seed a menu pinned loads as it always did, even when the store was last told the popup is hidden")
    func pinnedLoadsRegardless() async {
        let h = RelatedHarness()
        await h.script("x", "rx")
        h.store.setPopupVisible(false)

        h.store.show(song("x"))
        await h.settled()

        #expect(ids(h.store.state) == ["rx"])
        #expect(await h.relatedCalls() == ["x"])
    }

    @Test("A collection a menu pinned reads its page and loads regardless of the popup flag")
    func pinnedCollectionLoadsRegardless() async {
        let h = RelatedHarness()
        let collection = MusicSamples.collection("MPREb1", kind: .album, title: "Album")
        await h.backend.setPage(MusicSamples.page(collection.browseId, tracks: [song("t1")]))
        await h.script("t1", "r1")
        h.store.setPopupVisible(false)

        h.store.show(collection)
        await h.settled()

        #expect(ids(h.store.state) == ["r1"])
    }

    @Test("When nothing plays any more while hidden the store has no seed, and coming back asks nothing")
    func hiddenNothingPlaying() async {
        let h = RelatedHarness()
        await followingA(h)
        h.store.nowPlayingChanged(song("b"))

        h.store.nowPlayingChanged(nil)
        #expect(h.store.state == .noSeed)
        h.store.setPopupVisible(true)
        await h.letLateWorkLand()

        #expect(h.store.state == .noSeed)
        #expect(await h.relatedCalls() == ["a"])
    }

    @Test("Closing or resetting while a hidden change waits forgets it: coming back asks nothing")
    func closeForgetsThePendingSeed() async {
        let ends: [(MusicRelatedStore) -> Void] = [{ $0.close() }, { $0.reset() }]
        for end in ends {
            let h = RelatedHarness()
            await followingA(h)
            h.store.nowPlayingChanged(song("b"))

            end(h.store)
            h.store.setPopupVisible(true)
            await h.letLateWorkLand()

            #expect(h.store.state == .idle)
            #expect(await h.relatedCalls() == ["a"])
        }
    }

    @Test("A pinned seed chosen while a hidden change waits replaces it")
    func pinnedReplacesThePendingSeed() async {
        let h = RelatedHarness()
        await followingA(h)
        await h.script("x", "rx")
        h.store.nowPlayingChanged(song("b"))

        h.store.show(song("x"))
        await h.settled()
        h.store.setPopupVisible(true)
        await h.letLateWorkLand()

        #expect(await h.relatedCalls() == ["a", "x"])
        #expect(h.store.seed?.videoId == "x")
    }

    // MARK: - Following

    @Test("The store says whether it follows the player: the button's panel does, a menu's does not")
    func isFollowing() async {
        let h = RelatedHarness()
        #expect(h.store.isFollowing == false)

        h.store.follow(song("a"))
        #expect(h.store.isFollowing)

        h.store.show(song("x"))
        #expect(h.store.isFollowing == false)

        h.store.follow(song("a"))
        h.store.close()
        #expect(h.store.isFollowing == false)

        h.store.follow(song("a"))
        h.store.reset()
        #expect(h.store.isFollowing == false)
    }

    @Test("A changed song is waited for 300 ms, the wait the store asks its sleep for")
    func debounceIsThreeHundredMilliseconds() async {
        let log = SleepLog()
        let h = RelatedHarness(sleep: { await log.record($0) })
        await h.script("a", "ra")
        await h.script("b", "rb")
        h.store.follow(song("a"))
        await h.settled()
        #expect(await log.durations.isEmpty)

        h.store.nowPlayingChanged(song("b"))
        await h.settled()

        #expect(await log.durations == [.milliseconds(300)])
    }

    @Test("Showing a seed or following asks for no wait at all")
    func noWaitForMenusAndTheButton() async {
        let log = SleepLog()
        let h = RelatedHarness(sleep: { await log.record($0) })
        h.store.show(song("x"))
        await h.settled()
        h.store.follow(song("a"))
        await h.settled()
        #expect(await log.durations.isEmpty)
    }

    // MARK: - The subline

    @Test("A seed with no title has no subline, a song's and a collection's alike")
    func blankTitleHidesTheSubline() async {
        let h = RelatedHarness()
        h.store.show(MusicSamples.track("a", title: ""))
        #expect(h.store.subline == nil)
        h.store.show(MusicSamples.track("b", title: "  \n "))
        #expect(h.store.subline == nil)
        h.store.show(MusicSamples.collection("MPREb1", kind: .album, title: ""))
        #expect(h.store.subline == nil)

        h.store.show(song("c"))
        #expect(h.store.subline == "From Song c")
    }

    // MARK: - Collection seeds are kept

    @Test("The same album chosen again reads its page once: the seed it found is kept")
    func repeatCollectionReadsItsPageOnce() async {
        let h = RelatedHarness()
        let collection = MusicSamples.collection("MPREb1", kind: .album, title: "Album")
        await h.backend.setPage(MusicSamples.page(collection.browseId, tracks: [song("t1")]))
        await h.script("t1", "r1")
        h.store.show(collection)
        await h.settled()
        h.store.close()

        h.store.show(collection)
        await h.settled()

        #expect(ids(h.store.state) == ["r1"])
        #expect(h.store.seed?.videoId == "t1")
        #expect(await h.pageCalls() == [collection.browseId])
        #expect(await h.relatedCalls() == ["t1"])
    }

    @Test("A kept seed is found at once, with no state in between that shows nothing")
    func keptSeedIsImmediate() async {
        let h = RelatedHarness()
        let collection = MusicSamples.collection("MPREb1", kind: .album, title: "Album")
        await h.backend.setPage(MusicSamples.page(collection.browseId, tracks: [song("t1")]))
        await h.script("t1", "r1")
        h.store.show(collection)
        await h.settled()

        h.store.show(collection)

        #expect(ids(h.store.state) == ["r1"])
        #expect(h.store.seed?.videoId == "t1")
    }

    @Test("A page with no song, or one that failed, is not kept: the next try reads it again")
    func noSeedAndFailureAreNotKept() async {
        let h = RelatedHarness()
        let empty = MusicSamples.collection("MPREbEmpty", kind: .album, title: "Empty")
        await h.backend.setPage(MusicSamples.page(empty.browseId))
        let broken = MusicSamples.collection("MPREbBroken", kind: .album, title: "Broken")
        await h.backend.setPageError(broken.browseId, MusicError.http(500))

        for _ in 0..<2 {
            h.store.show(empty)
            await h.settled()
            h.store.show(broken)
            await h.settled()
        }

        #expect(await h.pageCalls() == [empty.browseId, broken.browseId, empty.browseId, broken.browseId])
    }

    @Test("Sign-out forgets the kept seeds with the rest of the cache")
    func resetForgetsKeptSeeds() async {
        let h = RelatedHarness()
        let collection = MusicSamples.collection("MPREb1", kind: .album, title: "Album")
        await h.backend.setPage(MusicSamples.page(collection.browseId, tracks: [song("t1")]))
        await h.script("t1", "r1")
        h.store.show(collection)
        await h.settled()

        h.store.reset()
        h.store.show(collection)
        await h.settled()

        #expect(await h.pageCalls() == [collection.browseId, collection.browseId])
    }

    @Test("Only the last ten collections' seeds are kept, the least recently shown goes first")
    func keptSeedsAreBounded() async {
        let h = RelatedHarness()
        let collections = (0..<11).map { MusicSamples.collection("MPREb\($0)", kind: .album, title: "Album \($0)") }
        for (index, collection) in collections.enumerated() {
            await h.backend.setPage(MusicSamples.page(collection.browseId, tracks: [song("t\(index)")]))
        }
        for collection in collections {
            h.store.show(collection)
            await h.settled()
        }
        let reads = await h.pageCalls().count
        #expect(reads == 11)

        // The newest ten are kept; the oldest was dropped and is read again.
        h.store.show(collections[10])
        await h.settled()
        h.store.show(collections[1])
        await h.settled()
        #expect(await h.pageCalls().count == 11)
        h.store.show(collections[0])
        await h.settled()
        #expect(await h.pageCalls().count == 12)
    }
}
