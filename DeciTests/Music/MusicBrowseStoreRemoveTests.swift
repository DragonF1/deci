// DeciTests/Music/MusicBrowseStoreRemoveTests.swift
// A song taken out of a playlist leaves the loaded page at once: only the row with that setVideoId goes, the page
// keeps its editable flag through paging and sorting, and a page that is not loaded is left alone.

import Foundation
import Testing
@testable import Deci

@MainActor
private struct RemoveHarness {
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

    /// Opens a playlist page holding `tracks` and waits for it to load.
    func open(_ id: String = "VLPLfixtureMine", tracks: [Deci.MusicTrack], continuation: String? = nil, isEditable: Bool = true) async {
        await backend.setPage(MusicSamples.page(id, tracks: tracks, continuation: continuation, title: "Mine", isEditable: isEditable))
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
@Suite("MusicBrowseStore row removal")
struct MusicBrowseStoreRemoveTests {
    private func row(_ id: String, set: String) -> Deci.MusicTrack {
        MusicSamples.track(id, setVideoId: set)
    }

    @Test("Removing a row takes out that row only and keeps the page's own fields")
    func removesOneRow() async {
        let h = RemoveHarness()
        // A playlist the user made loads the rest of its songs the moment it lands, so the gate holds that load and
        // the page keeps the continuation the test looks for.
        let gate = MusicTestGate()
        await h.backend.setMoreTracksGate(browseId: "VLPLfixtureMine", continuation: "more", gate)
        await h.open(tracks: [row("a", set: "s1"), row("b", set: "s2"), row("c", set: "s3")], continuation: "more")
        let before = h.page()

        #expect(h.store.removeTrack(setVideoId: "s2", from: "VLPLfixtureMine"))

        #expect(h.ids() == ["a", "c"])
        let after = h.page()
        #expect(after?.title == before?.title)
        #expect(after?.continuation == "more")
        #expect(after?.isEditable == true)
        #expect(after?.browseId == "VLPLfixtureMine")
        await gate.open()
    }

    @Test("The same song twice is two rows, and only the named row goes")
    func sameSongTwice() async {
        let h = RemoveHarness()
        await h.open(tracks: [row("a", set: "s1"), row("b", set: "s2"), row("a", set: "s3")])
        #expect(h.store.removeTrack(setVideoId: "s3", from: "VLPLfixtureMine"))
        #expect(h.page()?.tracks.map(\.playlistSetVideoId) == ["s1", "s2"])
    }

    @Test("An unknown setVideoId, a blank one, or a page that is not loaded changes nothing")
    func nothingToRemove() async {
        let h = RemoveHarness()
        #expect(!h.store.removeTrack(setVideoId: "s1", from: "VLPLfixtureMine"))
        await h.open(tracks: [row("a", set: "s1")])
        #expect(!h.store.removeTrack(setVideoId: "nope", from: "VLPLfixtureMine"))
        #expect(!h.store.removeTrack(setVideoId: "", from: "VLPLfixtureMine"))
        #expect(!h.store.removeTrack(setVideoId: "s1", from: "VLPLother"))
        #expect(h.ids() == ["a"])
    }

    @Test("A page that is loading or failed is left alone")
    func notLoaded() async {
        let h = RemoveHarness()
        let gate = MusicTestGate()
        await h.backend.setPageGate("VLPLfixtureMine", gate)
        await h.backend.setPage(MusicSamples.page("VLPLfixtureMine", tracks: [row("a", set: "s1")]))
        h.store.open(MusicSamples.collection("VLPLfixtureMine"))
        #expect(!h.store.removeTrack(setVideoId: "s1", from: "VLPLfixtureMine"))
        await gate.open()
        #expect(await h.until { h.page() != nil })
        #expect(h.ids() == ["a"])
    }

    @Test("Removing the last row leaves an empty, still loaded page")
    func removesLastRow() async {
        let h = RemoveHarness()
        await h.open(tracks: [row("a", set: "s1")])
        #expect(h.store.removeTrack(setVideoId: "s1", from: "VLPLfixtureMine"))
        #expect(h.page()?.tracks.isEmpty == true)
    }

    @Test("A sorted page shows the removal too, not a stale sorted copy")
    func sortedPageUpdates() async {
        let h = RemoveHarness()
        await h.open(tracks: [
            MusicSamples.track("a", title: "Charlie", setVideoId: "s1"),
            MusicSamples.track("b", title: "Alpha", setVideoId: "s2"),
            MusicSamples.track("c", title: "Bravo", setVideoId: "s3"),
        ])
        h.store.pickSort(.title, for: "VLPLfixtureMine")
        #expect(h.store.displayedPage("VLPLfixtureMine")?.tracks.map(\.videoId) == ["b", "c", "a"])
        #expect(h.store.displayedPage("VLPLfixtureMine")?.isEditable == true)

        #expect(h.store.removeTrack(setVideoId: "s3", from: "VLPLfixtureMine"))
        #expect(h.store.displayedPage("VLPLfixtureMine")?.tracks.map(\.videoId) == ["b", "a"])
    }

    @Test("A page that pages in more songs keeps its editable flag, and so does a sorted copy of it")
    func editableSurvivesPaging() async {
        let h = RemoveHarness()
        await h.backend.setMoreTracks(browseId: "VLPLfixtureMine", continuation: "more", tracks: [row("b", set: "s2")], next: nil)
        await h.open(tracks: [row("a", set: "s1")], continuation: "more")
        h.store.loadMoreTracks("VLPLfixtureMine")
        #expect(await h.until { h.ids() == ["a", "b"] })
        #expect(h.page()?.isEditable == true)

        h.store.pickSort(.title, for: "VLPLfixtureMine")
        #expect(h.store.displayedPage("VLPLfixtureMine")?.isEditable == true)
    }

    @Test("A read-only page stays read-only through paging")
    func readOnlyStays() async {
        let h = RemoveHarness()
        await h.backend.setMoreTracks(browseId: "VLPLtheirs", continuation: "more", tracks: [row("b", set: "s2")], next: nil)
        await h.open("VLPLtheirs", tracks: [row("a", set: "s1")], continuation: "more", isEditable: false)
        h.store.loadMoreTracks("VLPLtheirs")
        #expect(await h.until { h.ids("VLPLtheirs") == ["a", "b"] })
        #expect(h.page("VLPLtheirs")?.isEditable == false)
    }

    @Test("A page opened again after Back is fetched fresh, so a removal is not remembered locally")
    func removalDoesNotOutliveThePage() async {
        let h = RemoveHarness()
        await h.open(tracks: [row("a", set: "s1"), row("b", set: "s2")])
        #expect(h.store.removeTrack(setVideoId: "s1", from: "VLPLfixtureMine"))
        h.store.back()
        #expect(h.page() == nil)
        h.store.open(MusicSamples.collection("VLPLfixtureMine", title: "Mine"))
        #expect(await h.until { h.ids() == ["a", "b"] })
    }
}
