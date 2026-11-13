// DeciTests/Music/MixShuffle/MusicServiceMixReviewTests.swift
// Review fixes for Mix: it mixes with Crossfade off, later pages land behind the ordered window, Up next refreshes after
// queue edits, each row shows its own song's tempo and key, the window really orders by what it knows, and the
// foreground analysis backs off on a rate limit.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("MusicService Mix review fixes")
struct MusicServiceMixReviewTests {
    private static func ids(_ count: Int) -> [String] { (0..<count).map { "m\(String(format: "%03d", $0))" } }

    @Test("Crossfade off with Mix on still fades; Off and Shuffle stay gapless")
    func mixMixesWithoutCrossfade() async {
        let h = MixShuffleHarness(preferences: MusicPlaybackPreferences(crossfade: false))
        await h.startQueue(Self.ids(8))
        #expect(h.service.effectiveCrossfadeSeconds == 0)
        h.service.setShuffleMode(.shuffle)
        await h.settle()
        #expect(h.service.effectiveCrossfadeSeconds == 0)
        h.service.setShuffleMode(.mix)
        await h.settle()
        #expect(h.service.mixesTransitions)
        #expect(h.service.effectiveCrossfadeSeconds > 0)
        #expect(h.player.crossfadeSeconds > 0)
        h.service.setShuffleMode(.off)
        await h.settle()
        #expect(h.service.effectiveCrossfadeSeconds == 0)
        #expect(h.player.crossfadeSeconds == 0)
    }

    @Test("pages that land in Mix go behind the ordered window and keep the page order")
    func pagesLandBehind() {
        var queue = MusicQueue()
        let tracks = Self.ids(30).map { MusicSamples.track($0, title: "Song \($0)") }
        queue.start(page: tracks, playing: tracks[0], browseId: "VLPL1", continuation: "c", automixPlaylistId: nil)
        var generator = MusicShuffleGenerator(seed: 4)
        queue.mixOrder(Array(queue.unqueuedUpcoming.map(\.videoId).reversed()))
        let ordered = queue.tracks.map(\.videoId)
        var landed: [String] = []
        for page in 0..<4 {
            let more = (0..<20).map { MusicSamples.track("p\(page)-\($0)", title: "More \(page) \($0)") }
            queue.append(more, continuation: "c", using: &generator, inOrder: true)
            landed += more.map(\.videoId)
        }
        let now = queue.tracks.map(\.videoId)
        #expect(Array(now.prefix(ordered.count)) == ordered)
        #expect(Array(now.dropFirst(ordered.count)) == landed)
        #expect(Set(now).count == now.count)
        queue.unshuffle()
        #expect(queue.tracks.map(\.videoId).suffix(landed.count) == landed)
    }

    @Test("plain Shuffle still scatters later pages into the mix")
    func shuffleStillScatters() {
        var queue = MusicQueue()
        let tracks = Self.ids(30).map { MusicSamples.track($0, title: "Song \($0)") }
        queue.start(page: tracks, playing: tracks[0], browseId: "VLPL1", continuation: "c", automixPlaylistId: nil)
        var generator = MusicShuffleGenerator(seed: 4)
        queue.shuffle(using: &generator)
        let more = (0..<30).map { MusicSamples.track("p-\($0)", title: "More \($0)") }
        queue.append(more, continuation: nil, using: &generator)
        let ids = queue.tracks.map(\.videoId)
        let firstNew = ids.firstIndex { $0.hasPrefix("p-") } ?? 99
        #expect(firstNew < 30)
    }

    @Test("a window of alternating tempos is laid out with fewer tempo jumps than the natural order")
    func orderingReallyOrders() async {
        let ids = Self.ids(60)
        let h = MixShuffleHarness()
        for (index, id) in ids.enumerated() {
            await h.reader.set(MixRows.row(id, bpm: index % 2 == 0 ? 80 : 160, tonic: 0, minor: false))
        }
        await h.startQueue(ids)
        func jumps(_ order: [String]) -> Int {
            zip(order, order.dropFirst()).filter { pair in
                (Int(pair.0.dropFirst()) ?? 0) % 2 != (Int(pair.1.dropFirst()) ?? 0) % 2
            }.count
        }
        let natural = Array(h.order[1...MusicMixWindow.size])
        h.service.setShuffleMode(.mix)
        await h.settle()
        let mixed = Array(h.order[1...MusicMixWindow.size])
        #expect(Set(mixed) == Set(natural))
        #expect(jumps(mixed) < jumps(natural) / 2)
    }

    @Test("Play next in Mix gives the queued song a pair entry")
    func playNextRefreshesPairs() async throws {
        let ids = Self.ids(10)
        let h = MixShuffleHarness()
        for id in ids + ["qq"] { await h.reader.set(MixRows.row(id)) }
        await h.startQueue(ids)
        h.service.setShuffleMode(.mix)
        await h.settle()
        h.service.playNext(MusicSamples.track("qq", title: "Song qq", artist: "Artist qq"))
        await h.settle()
        let current = try #require(h.service.queue.current)
        #expect(h.service.mixInfo(from: current.videoId, to: "qq") != nil)
        h.service.removeFromQueue(MusicSamples.track("qq", title: "Song qq", artist: "Artist qq"))
        await h.settle()
        #expect(h.service.mixInfo(from: current.videoId, to: "qq") == nil)
    }

    @Test("a row's tempo text comes from its own song, not from the pair before it")
    func rowTextIsOwn() async throws {
        let ids = Self.ids(6)
        let h = MixShuffleHarness()
        // The playing song has no row; every other song has one.
        for id in ids.dropFirst() { await h.reader.set(MixRows.row(id, bpm: 120, tonic: 9, minor: true)) }
        await h.startQueue(ids)
        h.service.setShuffleMode(.mix)
        await h.settle()
        let next = try #require(h.service.queue.upcoming.first)
        let text = try #require(h.service.mixRowText(for: next.videoId))
        #expect(text.contains("120"))
        #expect(h.service.mixRowText(for: ids[0]) == nil)
        h.service.setShuffleMode(.off)
        #expect(h.service.mixRowText(for: next.videoId) == nil)
    }

    @Test("a row stored by another analysis path shows in Up next once its run ends, with no pair to carry it")
    func landedRowShows() async throws {
        let ids = Self.ids(6)
        let h = MixShuffleHarness()
        await h.startQueue(ids)
        h.service.setShuffleMode(.mix)
        await h.settle()
        let next = try #require(h.service.queue.upcoming.first)
        #expect(h.service.mixRowText(for: next.videoId) == nil)
        // The idle queue (say) stores the next song's row. The playing song has none, so no pair changes.
        await h.reader.set(MixRows.row(next.videoId, bpm: 128, tonic: 9, minor: true))
        h.service.analysisLanded(next.videoId)
        await h.service.mixLandedTask?.value
        let text = try #require(h.service.mixRowText(for: next.videoId))
        #expect(text.contains("128"))
        #expect(h.service.mixPairs.isEmpty)
        // Measured again (say a newer analysis version): the new row replaces the one shown.
        await h.reader.set(MixRows.row(next.videoId, bpm: 96, tonic: 9, minor: true))
        h.service.analysisLanded(next.videoId)
        await h.service.mixLandedTask?.value
        #expect(h.service.mixRowText(for: next.videoId)?.contains("96") == true)
    }

    @Test("a landed run outside Up next, or with Mix off, reads nothing")
    func landedOutsideIgnored() async throws {
        let ids = Self.ids(6)
        let h = MixShuffleHarness()
        await h.startQueue(ids)
        h.service.analysisLanded(ids[1])
        #expect(h.service.mixLandedTask == nil, "Mix is off")
        h.service.setShuffleMode(.mix)
        await h.settle()
        h.service.analysisLanded("not-queued")
        #expect(h.service.mixLandedTask == nil, "not a song Up next shows")
    }

    @Test("a rate limit stops the foreground analysis pass")
    func rateLimitStops() async {
        let ids = Self.ids(20)
        let h = MixShuffleHarness()
        for id in ids { await h.backend.setStream(MusicSamples.stream(videoId: id, duration: 240)) }
        await h.startQueue(ids)
        for id in ids { await h.provider.setOutcome(id, .rateLimited) }
        let before = await h.provider.ensures.count
        h.service.setShuffleMode(.mix)
        await h.settle()
        let asked = await h.provider.ensures.dropFirst(before).filter { $0.id != ids[0] }
        #expect(asked.count == 1)
    }
}
