// DeciTests/Music/MusicBrowseStoreAutomixTests.swift
// A page's audio playlist id (the OLAK id an album's automix is asked of) survives every way the store rebuilds the
// page: paging in more songs, removing a row, and the sorted copy the list shows.

import Foundation
import Testing
@testable import Deci

@MainActor
private struct AutomixHarness {
    let backend = FakeMusicBackend()
    let store: MusicBrowseStore

    init() {
        store = MusicBrowseStore(backend: backend)
    }

    func until(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<400 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    /// Opens a page holding `tracks` that carries `audioPlaylistId`, and waits for it to load.
    func open(
        _ id: String = "VLPLfixtureMine",
        tracks: [Deci.MusicTrack],
        continuation: String? = nil,
        isEditable: Bool = false,
        audioPlaylistId: String? = "OLAK5uy_fixture"
    ) async {
        await backend.setPage(MusicSamples.page(
            id, tracks: tracks, continuation: continuation, title: "Mine", isEditable: isEditable, audioPlaylistId: audioPlaylistId
        ))
        store.open(MusicSamples.collection(id, title: "Mine"))
        _ = await until { if case .loaded = store.pageState(id) { true } else { false } }
    }

    func page(_ id: String = "VLPLfixtureMine") -> MusicBrowsePage? {
        if case .loaded(let page) = store.pageState(id) { page } else { nil }
    }

    func ids(_ id: String = "VLPLfixtureMine") -> [String] {
        page(id)?.tracks.map(\.videoId) ?? []
    }
}

@MainActor
@Suite("MusicBrowseStore audio playlist id")
struct MusicBrowseStoreAutomixTests {
    @Test("A loaded page keeps the audio playlist id the backend gave it")
    func landed() async {
        let h = AutomixHarness()
        await h.open(tracks: MusicSamples.tracks("a", "b"))
        #expect(h.page()?.audioPlaylistId == "OLAK5uy_fixture")
    }

    @Test("Paging in more songs keeps it")
    func pagingKeepsIt() async {
        let h = AutomixHarness()
        await h.backend.setMoreTracks(browseId: "VLPLfixtureMine", continuation: "more", tracks: MusicSamples.tracks("c"), next: nil)
        await h.open(tracks: MusicSamples.tracks("a", "b"), continuation: "more")
        h.store.loadMoreTracks("VLPLfixtureMine")
        #expect(await h.until { h.ids() == ["a", "b", "c"] })
        #expect(h.page()?.audioPlaylistId == "OLAK5uy_fixture")
    }

    @Test("Removing a row keeps it")
    func removalKeepsIt() async {
        let h = AutomixHarness()
        await h.open(
            tracks: [MusicSamples.track("a", setVideoId: "s1"), MusicSamples.track("b", setVideoId: "s2")],
            isEditable: true
        )
        #expect(h.store.removeTrack(setVideoId: "s1", from: "VLPLfixtureMine"))
        #expect(h.ids() == ["b"])
        #expect(h.page()?.audioPlaylistId == "OLAK5uy_fixture")
    }

    @Test("The sorted copy the list shows keeps it")
    func sortedCopyKeepsIt() async {
        let h = AutomixHarness()
        await h.open(tracks: [
            MusicSamples.track("a", title: "Charlie"),
            MusicSamples.track("b", title: "Alpha"),
        ])
        h.store.pickSort(.title, for: "VLPLfixtureMine")
        let shown = h.store.displayedPage("VLPLfixtureMine")
        #expect(shown?.tracks.map(\.videoId) == ["b", "a"])
        #expect(shown?.audioPlaylistId == "OLAK5uy_fixture")
        #expect(shown?.automixPlaylistId == "PLfixtureMine")
    }

    @Test("A page without one stays without one through the same rebuilds")
    func nilStaysNil() async {
        let h = AutomixHarness()
        await h.backend.setMoreTracks(browseId: "VLPLfixtureMine", continuation: "more", tracks: MusicSamples.tracks("c"), next: nil)
        await h.open(
            tracks: [MusicSamples.track("a", title: "Charlie", setVideoId: "s1"), MusicSamples.track("b", title: "Alpha", setVideoId: "s2")],
            continuation: "more",
            isEditable: true,
            audioPlaylistId: nil
        )
        h.store.loadMoreTracks("VLPLfixtureMine")
        #expect(await h.until { h.ids() == ["a", "b", "c"] })
        #expect(h.store.removeTrack(setVideoId: "s1", from: "VLPLfixtureMine"))
        h.store.pickSort(.title, for: "VLPLfixtureMine")
        #expect(h.page()?.audioPlaylistId == nil)
        #expect(h.store.displayedPage("VLPLfixtureMine")?.audioPlaylistId == nil)
    }
}
