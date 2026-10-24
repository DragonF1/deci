// DeciTests/Music/MusicServiceTopResultTests.swift
// The search's Top result: a song or video the unfiltered search names comes first in the songs list, the songs
// filter's rows follow without it, and a failed or slow Top result never costs the songs.

import Foundation
import Testing
@testable import Deci

@MainActor
private struct Rig {
    let backend = FakeMusicBackend(signedIn: true)
    let service: MusicService

    /// `artistGrace` is long by default, so a search waits for a held call; a test of the grace passes a short one.
    init(grace: Duration = .seconds(60)) {
        service = MusicService(
            backend: backend,
            player: MusicPlayer(engine: FakePlaybackEngine()),
            nowPlaying: NowPlayingController(surface: FakeNowPlayingSurface(), fetchArtwork: { _ in nil }),
            artistGrace: grace,
            refreshOnCreate: false
        )
    }

    func search(_ query: String) async {
        service.query = query
        service.search()
        await service.searchTask?.value
    }

    /// Polls until `condition` holds; for work that is held at a gate and cannot be awaited.
    func eventually(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<400 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    var ids: [String] { service.results.map(\.videoId) }
}

@MainActor
@Suite("MusicService search top result")
struct MusicServiceTopResultTests {

    private static let top = MusicSamples.track("top", title: "Crab Rave Bass Boosted")

    @Test("the top result comes first, then the songs filter's rows")
    func topFirst() async {
        let r = Rig()
        await r.backend.setSearch("crab", results: MusicSamples.tracks("s1", "s2"))
        await r.backend.setTopResult("crab", track: Self.top)

        await r.search("crab")

        #expect(r.ids == ["top", "s1", "s2"])
        #expect(r.service.results.first == Self.top)
        #expect(r.service.isSearching == false)
        #expect(await r.backend.searchedTopResultQueries == ["crab"])
    }

    @Test("a top result the songs filter also returned appears once, first")
    func duplicateRemoved() async {
        let r = Rig()
        await r.backend.setSearch("crab", results: MusicSamples.tracks("s1", "top", "s2"))
        await r.backend.setTopResult("crab", track: Self.top)

        await r.search("crab")

        #expect(r.ids == ["top", "s1", "s2"])
    }

    @Test("with no top track the songs show as before")
    func noTopTrack() async {
        let r = Rig()
        await r.backend.setSearch("crab", results: MusicSamples.tracks("s1", "s2"))

        await r.search("crab")

        #expect(r.ids == ["s1", "s2"])
    }

    @Test("a top result alone shows when the songs filter finds nothing")
    func topWithoutSongs() async {
        let r = Rig()
        await r.backend.setTopResult("crab", track: Self.top)

        await r.search("crab")

        #expect(r.ids == ["top"])
    }

    @Test("the query is trimmed before the top result is asked for")
    func queryTrimmed() async {
        let r = Rig()
        await r.search("  crab \n")
        #expect(await r.backend.searchedTopResultQueries == ["crab"])
    }

    @Test("a blank query clears the results and asks for no top result")
    func blankQuery() async {
        let r = Rig()
        await r.backend.setTopResult("crab", track: Self.top)
        await r.search("crab")
        #expect(r.ids == ["top"])

        r.service.query = "   "
        r.service.search()

        #expect(r.service.results.isEmpty)
        #expect(await r.backend.searchedTopResultQueries == ["crab"])
    }

    @Test("a failing top result leaves the songs showing and no error")
    func topFailureIsQuiet() async {
        let r = Rig()
        await r.backend.setSearch("crab", results: MusicSamples.tracks("s1", "s2"))
        await r.backend.setTopResultError("crab", MusicError.http(503))

        await r.search("crab")

        #expect(r.ids == ["s1", "s2"])
        #expect(r.service.lastError == nil)
        #expect(r.service.isSearching == false)
    }

    @Test("a failing songs request fails the search even when the top result is found")
    func songsFailureFails() async {
        let r = Rig()
        await r.backend.setSearchError("crab", MusicError.http(503))
        await r.backend.setTopResult("crab", track: Self.top)

        await r.search("crab")

        #expect(r.service.results.isEmpty)
        #expect(r.service.lastError != nil)
        #expect(r.service.isSearching == false)
    }

    @Test("a top result slower than the grace is dropped and the songs show without it")
    func slowTopResultIsDropped() async {
        let r = Rig(grace: .milliseconds(20))
        let gate = MusicTestGate()
        await r.backend.setSearch("crab", results: MusicSamples.tracks("s1"))
        await r.backend.setTopResult("crab", track: Self.top)
        await r.backend.setTopResultGate("crab", gate)

        r.service.query = "crab"
        r.service.search()

        // The top call never returns, and the search still ends. Polled, so a search that waits for it fails here
        // instead of hanging the run.
        #expect(await r.eventually { r.service.isSearching == false })
        #expect(r.ids == ["s1"])
        #expect(r.service.lastError == nil)

        // A reply that comes after the grace changes nothing.
        await gate.open()
        for _ in 0..<20 { await Task.yield() }
        #expect(r.ids == ["s1"])
    }

    @Test("the songs wait for a top result that lands inside the grace")
    func topResultInsideTheGrace() async {
        let r = Rig()
        let gate = MusicTestGate()
        await r.backend.setSearch("crab", results: MusicSamples.tracks("s1"))
        await r.backend.setTopResult("crab", track: Self.top)
        await r.backend.setTopResultGate("crab", gate)

        r.service.query = "crab"
        r.service.search()
        let task = r.service.searchTask
        #expect(await r.eventually { await r.backend.searchedTopResultQueries == ["crab"] })
        for _ in 0..<20 { await Task.yield() }
        #expect(r.service.results.isEmpty)
        #expect(r.service.isSearching)

        await gate.open()
        await task?.value
        #expect(r.ids == ["top", "s1"])
        #expect(r.service.isSearching == false)
    }

    @Test("the artists shelf still lands with the top result")
    func artistsStillLand() async {
        let r = Rig()
        await r.backend.setSearch("crab", results: MusicSamples.tracks("s1"))
        await r.backend.setTopResult("crab", track: Self.top)
        await r.backend.setArtistSearch("crab", results: [
            MusicSamples.collection("UCa", kind: .artist, title: "Artist UCa", subtitle: "Artist"),
        ])

        await r.search("crab")

        #expect(r.ids == ["top", "s1"])
        #expect(r.service.artistResults.map(\.browseId) == ["UCa"])
    }

    @Test("a newer search drops the top result of one still in flight")
    func staleTopResultIsDropped() async {
        let r = Rig()
        let gate = MusicTestGate()
        await r.backend.setSearch("one", results: MusicSamples.tracks("slow"))
        await r.backend.setTopResult("one", track: MusicSamples.track("oldTop"))
        await r.backend.setTopResultGate("one", gate)
        await r.backend.setSearch("two", results: MusicSamples.tracks("fast"))
        await r.backend.setTopResult("two", track: MusicSamples.track("newTop"))

        r.service.query = "one"
        r.service.search()
        let first = r.service.searchTask
        r.service.query = "two"
        r.service.search()
        await r.service.searchTask?.value
        #expect(r.ids == ["newTop", "fast"])

        await gate.open()
        await first?.value
        #expect(r.ids == ["newTop", "fast"])
        #expect(r.service.isSearching == false)
    }
}
