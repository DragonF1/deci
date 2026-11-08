// DeciTests/Music/MixShuffle/MusicServiceMixSkipTests.swift
// Tier 4 P8: a manual skip under Mix re-plans the next five songs out of the song that now plays, away from the songs
// just skipped. A song that ends by itself never re-orders anything, Mix off leaves Next as it was, and rapid skips
// settle into one plan over the same five songs.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("MusicService Mix skip")
struct MusicServiceMixSkipTests {
    private static let ids = (0..<30).map { "s\(String(format: "%02d", $0))" }

    private func started(mix: Bool) async -> MixShuffleHarness {
        let h = MixShuffleHarness()
        for (index, id) in Self.ids.enumerated() {
            await h.reader.set(MixRows.row(id, bpm: 70 + Double(index % 9) * 8, tonic: index % 12, minor: index % 3 == 0))
        }
        await h.startQueue(Self.ids)
        if mix {
            h.service.setShuffleMode(.mix)
            await h.settle()
        }
        return h
    }

    private func upcoming(_ h: MixShuffleHarness) -> [String] { h.service.queue.upcoming.map(\.videoId) }

    @Test("Next in Mix keeps the same five songs after the new one and everything behind them")
    func skipReplansFive() async {
        let h = await started(mix: true)
        let before = upcoming(h)
        h.service.next()
        await h.settle()
        let after = upcoming(h)
        // The song now playing was the first of `before`; five songs follow it, then the rest as it was.
        #expect(h.service.queue.current?.videoId == before[0])
        #expect(Set(after.prefix(5)) == Set(before[1...5]))
        #expect(Array(after.dropFirst(5)) == Array(before.dropFirst(6)))
    }

    @Test("Mix off leaves Next exactly as it was")
    func offUnchanged() async {
        let h = await started(mix: false)
        let before = upcoming(h)
        h.service.next()
        await h.settle()
        #expect(upcoming(h) == Array(before.dropFirst()))
    }

    @Test("plain Shuffle leaves Next exactly as it was")
    func shuffleUnchanged() async {
        let h = await started(mix: false)
        h.service.setShuffleMode(.shuffle)
        await h.settle()
        let before = upcoming(h)
        h.service.next()
        await h.settle()
        #expect(upcoming(h) == Array(before.dropFirst()))
    }

    @Test("a song that ends by itself does not re-order the next songs")
    func naturalEndQuiet() async {
        let h = await started(mix: true)
        let before = upcoming(h)
        h.engine.emit(.ended)
        await h.settle()
        #expect(h.service.queue.current?.videoId == before[0])
        #expect(upcoming(h) == Array(before.dropFirst()))
    }

    @Test("two quick skips settle into one plan over the five songs after the last one")
    func rapidSkips() async {
        let h = await started(mix: true)
        let before = upcoming(h)
        h.service.next()
        h.service.next()
        await h.settle()
        let after = upcoming(h)
        #expect(h.service.queue.current?.videoId != nil)
        let afterSecond = Array(h.order.suffix(after.count))
        #expect(afterSecond == after)
        #expect(Set(h.order) == Set(Self.ids))
        // Two windows of five after the original song: everything past them is as it was.
        #expect(Array(after.dropFirst(5)) == Array(before.dropFirst(7)))
    }

    @Test("a tap in Up next re-plans like Next, and a song the listener queued is not moved")
    func jumpReplans() async throws {
        let h = await started(mix: true)
        let queued = MusicSamples.track("qq", title: "Song qq", artist: "Artist qq")
        h.service.playNext(queued)
        let target = try #require(h.service.queue.upcoming.dropFirst(3).first)
        h.service.jump(to: target)
        await h.settle()
        #expect(h.service.queue.current?.videoId == target.videoId)
        #expect(Set(h.order) == Set(Self.ids + ["qq"]))
        #expect(upcoming(h).contains("qq") || h.order.prefix(while: { $0 != target.videoId }).contains("qq"))
    }

    @Test("leaving Mix drops the plan: a later skip changes nothing")
    func leavingMixClears() async {
        let h = await started(mix: true)
        h.service.next()
        h.service.setShuffleMode(.shuffle)
        await h.settle()
        let before = upcoming(h)
        h.service.next()
        await h.settle()
        #expect(upcoming(h) == Array(before.dropFirst()))
    }

    /// Tempo class of a song: 80, 120 or 160 by index, so a natural run is a clash at every step.
    private static func tempoClass(_ id: String) -> Int { (Self.ids.firstIndex(of: id) ?? 0) % 3 }

    private static func clashes(_ chain: [String]) -> Int {
        zip(chain, chain.dropFirst()).filter { tempoClass($0.0) != tempoClass($0.1) }.count
    }

    @Test("after a skip the five songs are laid out to mix better out of the new song than they were")
    func skipImprovesTheFive() async throws {
        // Rows only exist after Mix ordered the queue, so that order knows nothing about tempo.
        let h = MixShuffleHarness(seed: 3)
        await h.startQueue(Self.ids)
        h.service.setShuffleMode(.mix)
        await h.settle()
        for (index, id) in Self.ids.enumerated() {
            await h.reader.set(MixRows.row(id, bpm: [80, 120, 160][index % 3], tonic: 0, minor: false))
        }
        let before = upcoming(h)
        let anchor = before[0]
        let oldChain = [anchor] + Array(before[1...5])
        try #require(Self.clashes(oldChain) >= 3)
        h.service.next()
        await h.settle()
        let after = upcoming(h)
        let newChain = [anchor] + Array(after.prefix(5))
        #expect(Set(newChain) == Set(oldChain))
        #expect(Self.clashes(newChain) < Self.clashes(oldChain))
        #expect(Array(after.dropFirst(5)) == Array(before.dropFirst(6)))
    }

    @Test("a next song that is already offered for preload stays first when the five are re-planned")
    func preloadedNextStaysFixed() async throws {
        let h = MixShuffleHarness(seed: 3)
        await h.startQueue(Self.ids)
        h.service.setShuffleMode(.mix)
        await h.settle()
        for (index, id) in Self.ids.enumerated() {
            await h.reader.set(MixRows.row(id, bpm: [80, 120, 160][index % 3], tonic: 0, minor: false))
        }
        let first = try #require(upcoming(h).first)
        let others = Set(upcoming(h).dropFirst().prefix(5))
        h.service.offerPreloadForTesting(first)
        await h.service.replanAfterSkipForTesting()
        #expect(upcoming(h).first == first)
        #expect(Set(upcoming(h).dropFirst().prefix(5)) == others)
    }
}
