// DeciTests/Music/MusicLyricsOfflineTests.swift
// Lyrics with no network: no source is asked, the panel lands on the same "no lyrics" state a song without lyrics
// gets (never a spinner that does not end), and the song's lyrics are fetched once the network returns.

import Foundation
import Testing
@testable import Deci

@MainActor
private struct OfflineLyricsRig {
    let provider = FakeLyricsProvider()
    let connectivity: MusicConnectivity
    let store: MusicLyricsStore

    init(online: Bool = false) {
        let provider = self.provider
        connectivity = MusicConnectivity(isOnline: online)
        store = MusicLyricsStore(provider: provider, sleep: { _ in }, connectivity: connectivity)
    }

    static func track(_ id: String = "a") -> MusicTrack {
        MusicTrack(videoId: id, title: "Song \(id)", artist: "Artist \(id)", album: "Album", durationSeconds: 200, thumbnailURL: nil)
    }

    func settle() async {
        while let task = store.loadTask {
            await task.value
            if store.loadTask == task { break }
        }
    }

    func idle() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(20))
    }

    static let lines = [LyricLine(time: 1, text: "First test line"), LyricLine(time: 4, text: "Second test line")]
}

@MainActor
@Suite("Music lyrics offline")
struct MusicLyricsOfflineTests {
    @Test("opening the panel offline lands on no lyrics at once, asks no source and never shows loading")
    func openingOffline() async {
        let rig = OfflineLyricsRig()
        rig.store.trackChanged(OfflineLyricsRig.track("a"), duration: 200)

        rig.store.setPanelOpen(true)

        #expect(rig.store.state == .loaded(.notFound))
        await rig.idle()
        #expect(rig.provider.queries.isEmpty)
        #expect(rig.store.state == .loaded(.notFound))
        #expect(rig.store.loadTask == nil)
    }

    @Test("a track change offline lands on no lyrics for the new song, with no request")
    func trackChangeOffline() async {
        let rig = OfflineLyricsRig()
        rig.store.setPanelOpen(true)

        rig.store.trackChanged(OfflineLyricsRig.track("a"), duration: 200)
        rig.store.trackChanged(OfflineLyricsRig.track("b"), duration: 180)
        await rig.idle()

        #expect(rig.store.state == .loaded(.notFound))
        #expect(rig.provider.queries.isEmpty)
        #expect(rig.store.track?.videoId == "b")
    }

    @Test("Retry offline asks nothing")
    func retryOffline() async {
        let rig = OfflineLyricsRig()
        rig.store.trackChanged(OfflineLyricsRig.track("a"), duration: 200)
        rig.store.setPanelOpen(true)

        rig.store.retry()
        await rig.idle()

        #expect(rig.provider.queries.isEmpty)
        #expect(rig.store.state == .loaded(.notFound))
    }

    @Test("when the network returns, the song's lyrics are fetched and shown")
    func fetchedOnReconnect() async {
        let rig = OfflineLyricsRig()
        rig.provider.setResult(.synced(OfflineLyricsRig.lines), for: "a")
        rig.store.trackChanged(OfflineLyricsRig.track("a"), duration: 200)
        rig.store.setPanelOpen(true)
        #expect(rig.provider.queries.isEmpty)

        rig.connectivity.update(isOnline: true)
        await rig.settle()

        #expect(rig.store.state == .loaded(.synced(OfflineLyricsRig.lines)))
        #expect(rig.provider.videoIds == ["a"])
    }

    @Test("the network returning with the panel closed fetches nothing, and opening it then does")
    func reconnectWithPanelClosed() async {
        let rig = OfflineLyricsRig()
        rig.provider.setResult(.synced(OfflineLyricsRig.lines), for: "a")
        rig.store.trackChanged(OfflineLyricsRig.track("a"), duration: 200)

        rig.connectivity.update(isOnline: true)
        await rig.idle()
        #expect(rig.provider.queries.isEmpty)

        rig.store.setPanelOpen(true)
        await rig.settle()

        #expect(rig.store.state == .loaded(.synced(OfflineLyricsRig.lines)))
    }

    @Test("lyrics that were loaded online stay on screen when the network goes")
    func loadedLyricsStay() async {
        let rig = OfflineLyricsRig(online: true)
        rig.provider.setResult(.synced(OfflineLyricsRig.lines), for: "a")
        rig.store.trackChanged(OfflineLyricsRig.track("a"), duration: 200)
        rig.store.setPanelOpen(true)
        await rig.settle()

        rig.connectivity.update(isOnline: false)
        await rig.idle()

        #expect(rig.store.state == .loaded(.synced(OfflineLyricsRig.lines)))
        #expect(rig.provider.queries.count == 1)
    }

    @Test("lyrics already loaded are not fetched again when the network goes and comes back")
    func loadedLyricsNotRefetched() async {
        let rig = OfflineLyricsRig(online: true)
        rig.provider.setResult(.synced(OfflineLyricsRig.lines), for: "a")
        rig.store.trackChanged(OfflineLyricsRig.track("a"), duration: 200)
        rig.store.setPanelOpen(true)
        await rig.settle()

        rig.connectivity.update(isOnline: false)
        rig.connectivity.update(isOnline: true)
        await rig.idle()

        #expect(rig.provider.queries.count == 1)
    }

    @Test("a store with no connectivity behaves as before")
    func withoutConnectivity() async {
        let provider = FakeLyricsProvider()
        provider.setResult(.synced(OfflineLyricsRig.lines), for: "a")
        let store = MusicLyricsStore(provider: provider, sleep: { _ in })
        store.trackChanged(OfflineLyricsRig.track("a"), duration: 200)

        store.setPanelOpen(true)
        while let task = store.loadTask {
            await task.value
            if store.loadTask == task { break }
        }

        #expect(store.state == .loaded(.synced(OfflineLyricsRig.lines)))
    }
}
