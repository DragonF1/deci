// DeciTests/Music/MixShuffle/MusicServiceMixWindowTests.swift
// Tier 4 P6: Mix on big playlists and unanalysed songs. Only the next window of unqueued songs is ordered, the tail keeps
// its order, a top-up orders the next window after a few songs without moving the ones the listener can see, and songs
// with no stored row are analysed a few at a time through the foreground path.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("MusicService Mix window")
struct MusicServiceMixWindowTests {
    static func ids(_ count: Int) -> [String] { (0..<count).map { "s\(String(format: "%03d", $0))" } }

    private func harness(_ ids: [String], rows: Bool = false) async -> MixShuffleHarness {
        let h = MixShuffleHarness()
        if rows {
            for (index, id) in ids.enumerated() {
                await h.reader.set(MixRows.row(id, bpm: 80 + Double(index % 7) * 10, tonic: index % 12, minor: index % 2 == 0))
            }
        }
        await h.startQueue(ids)
        return h
    }

    @Test("a 500 song queue orders only the next 24 songs and the tail keeps its order")
    func bigQueueOrdersOneWindow() async {
        let ids = Self.ids(500)
        let h = await harness(ids)
        let natural = h.order
        h.service.setShuffleMode(.mix)
        await h.settle()
        let size = MusicMixWindow.size
        // Slot 0 is the playing song; the window is slots 1...24.
        #expect(Array(h.order[(size + 1)...]) == Array(natural[(size + 1)...]))
        #expect(Set(h.order[1...size]) == Set(natural[1...size]))
        #expect(h.order[0] == natural[0])
        #expect(h.order.count == 500)
    }

    @Test("a big queue reads only a window of rows, not the whole playlist")
    func readsStayBounded() async {
        let ids = Self.ids(500)
        let h = await harness(ids)
        h.service.setShuffleMode(.mix)
        await h.settle()
        let reads = await h.reader.reads
        #expect(reads.count < 120)
    }

    @Test("songs the listener queued stay in front and the window starts behind them")
    func queuedPrefixSkipped() async {
        let ids = Self.ids(60)
        let h = await harness(ids)
        let first = MusicSamples.track("s010", title: "Song s010", artist: "Artist s010")
        let second = MusicSamples.track("s020", title: "Song s020", artist: "Artist s020")
        h.service.playNext(second)
        h.service.playNext(first)
        let natural = h.order
        #expect(Array(natural[1...2]) == ["s010", "s020"])
        h.service.setShuffleMode(.mix)
        await h.settle()
        #expect(Array(h.order[1...2]) == ["s010", "s020"])
        // The window is the 24 songs after the queued two; everything behind them is untouched.
        let tailStart = 3 + MusicMixWindow.size
        #expect(Array(h.order[tailStart...]) == Array(natural[tailStart...]))
        #expect(Set(h.order[3..<tailStart]) == Set(natural[3..<tailStart]))
    }

    @Test("songs with no row are analysed in play order, one at a time, at most four, outside the background path")
    func foregroundAnalysisCap() async {
        let ids = Self.ids(40)
        let h = MixShuffleHarness()
        for id in ids { await h.backend.setStream(MusicSamples.stream(videoId: id, duration: 240)) }
        await h.startQueue(ids)
        let natural = h.order
        let before = await h.provider.ensures.count
        h.service.setShuffleMode(.mix)
        await h.settle()
        let ensures = await h.provider.ensures
        let added = Array(ensures.dropFirst(before))
        let mixAsked = added.filter { $0.id != natural[0] }
        #expect(mixAsked.count == 4)
        #expect(mixAsked.map(\.id) == Array(natural[1...4]))
        #expect(mixAsked.allSatisfy { !$0.wantsFile })
    }

    @Test("a song that already has a row is never analysed again by Mix")
    func rowsAreNotAnalysedAgain() async {
        let ids = Self.ids(30)
        let h = MixShuffleHarness()
        for id in ids {
            await h.backend.setStream(MusicSamples.stream(videoId: id, duration: 240))
            await h.reader.set(MixRows.row(id))
        }
        await h.startQueue(ids)
        let before = await h.provider.ensures.count
        h.service.setShuffleMode(.mix)
        await h.settle()
        let added = await h.provider.ensures.dropFirst(before).filter { $0.id != ids[0] }
        #expect(added.isEmpty)
    }

    @Test("a top-up after six songs orders the next window and leaves the next three songs alone")
    func topUpKeepsVisibleSongs() async throws {
        let ids = Self.ids(80)
        let h = await harness(ids, rows: true)
        h.service.setShuffleMode(.mix)
        await h.settle()
        // Songs that end by themselves: a manual jump would re-plan the next five (P8), which this test is not about.
        for _ in 0..<(MusicMixWindow.topUpAfter - 1) {
            h.engine.emit(.ended)
            await h.settle()
        }
        h.engine.emit(.ended)
        let visible = Array(h.service.queue.upcoming.prefix(MusicMixWindow.topUpAfter)).map(\.videoId)
        let kept = Array(visible.prefix(3))
        let tailBefore = Array(h.service.queue.upcoming.dropFirst(3 + MusicMixWindow.size)).map(\.videoId)
        let allBefore = Set(h.service.queue.upcoming.map(\.videoId))
        let windowBefore = Array(h.service.queue.upcoming.dropFirst(3).prefix(MusicMixWindow.size)).map(\.videoId)
        await h.settle()
        let after = h.service.queue.upcoming.map(\.videoId)
        #expect(Array(after.prefix(3)) == kept)
        #expect(Array(after.dropFirst(3 + MusicMixWindow.size)) == tailBefore)
        #expect(Set(after) == allBefore)
        // The window behind the three kept songs holds the same songs, laid out again.
        #expect(Set(after.dropFirst(3).prefix(MusicMixWindow.size)) == Set(windowBefore))
    }

    @Test("a radio page that lands after Mix started is ordered too")
    func radioLandsInMix() async {
        let ids = Self.ids(12)
        let h = MixShuffleHarness(preferences: MusicPlaybackPreferences(mixShuffle: true))
        for id in ids { await h.reader.set(MixRows.row(id)) }
        await h.startQueue(ids)
        let reads = await h.reader.reads
        // The window's rows were read once the page was in the queue, so the order was laid out after it landed.
        #expect(Set(reads).isSuperset(of: Set(ids.dropFirst().prefix(5))))
        #expect(Set(h.order) == Set(ids))
    }

    @Test("Off after a big Mix puts the whole natural order back")
    func offRestores() async {
        let ids = Self.ids(100)
        let h = await harness(ids)
        let natural = h.order
        h.service.setShuffleMode(.mix)
        await h.settle()
        h.service.setShuffleMode(.off)
        #expect(h.order == natural)
    }
}
