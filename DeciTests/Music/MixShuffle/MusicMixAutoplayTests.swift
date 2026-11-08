// DeciTests/Music/MixShuffle/MusicMixAutoplayTests.swift
// Tier 4 P7: Autoplay under Mix. The staged radio still joins behind everything queued, but in an order Mix picks: the
// song that mixes best out of the playing one first, the rest in the slots that cost their neighbours least. Without Mix
// (Off, plain Shuffle) the radio is appended exactly as it came.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("MusicQueue Mix autoplay placement")
struct MusicQueueMixAutoplayTests {
    private func song(_ id: String) -> MusicTrack { MusicSamples.track(id, title: "Song \(id)") }

    private func stagedPage(_ list: [String] = ["a", "b", "c"], radio: [String] = ["r1", "r2", "r3", "r4"]) -> MusicQueue {
        var queue = MusicQueue()
        queue.start(page: list.map(song), playing: song(list[0]), browseId: "VLPL1", continuation: nil, automixPlaylistId: nil)
        queue.stageAutoplay(radio.map(song), continuation: "next", seed: list.last ?? "a")
        return queue
    }

    private func atEnd(_ queue: MusicQueue) -> MusicQueue {
        var copy = queue
        while copy.advance() != nil {}
        return copy
    }

    @Test("without a placer the radio is appended as it came")
    func plainAppend() {
        var queue = atEnd(stagedPage())
        let took = queue.takeAutoplay()
        #expect(took)
        #expect(queue.tracks.map(\.videoId) == ["a", "b", "c", "r1", "r2", "r3", "r4"])
    }

    @Test("a placer sets the order the radio joins in, behind every earlier song")
    func placed() {
        var queue = atEnd(stagedPage())
        var seenCurrent: String?
        let took = queue.takeAutoplay(placing: { fresh, current in
            seenCurrent = current?.videoId
            return fresh.reversed()
        })
        #expect(took)
        #expect(seenCurrent == "c")
        #expect(queue.tracks.map(\.videoId) == ["a", "b", "c", "r4", "r3", "r2", "r1"])
        #expect(queue.currentIndex == 2)
    }

    @Test("songs the listener queued stay ahead of the placed radio")
    func queuedStayAhead() {
        var queue = stagedPage()
        queue.playNext(song("q1"))
        queue = atEnd(queue)
        var queuedBefore: [String] = []
        queue.takeAutoplay(placing: { fresh, _ in fresh.reversed() })
        queuedBefore = Array(queue.tracks.prefix(4)).map(\.videoId)
        #expect(queuedBefore == ["a", "q1", "b", "c"])
        #expect(Array(queue.tracks.suffix(4)).map(\.videoId) == ["r4", "r3", "r2", "r1"])
    }

    @Test("an answer that is not a permutation of the radio is ignored")
    func badAnswerIgnored() {
        var queue = atEnd(stagedPage())
        queue.takeAutoplay(placing: { fresh, _ in Array(fresh.dropLast()) })
        #expect(queue.tracks.map(\.videoId) == ["a", "b", "c", "r1", "r2", "r3", "r4"])
        var other = atEnd(stagedPage())
        other.takeAutoplay(placing: { fresh, _ in fresh.map { _ in self.song("zz") } })
        #expect(other.tracks.map(\.videoId) == ["a", "b", "c", "r1", "r2", "r3", "r4"])
    }

    @Test("a placed radio keeps the natural order for unshuffle")
    func unshuffleKeepsNatural() {
        var generator = MusicShuffleGenerator(seed: 3)
        var queue = stagedPage()
        queue.shuffle(using: &generator)
        queue = atEnd(queue)
        queue.takeAutoplay(placing: { fresh, _ in fresh.reversed() })
        queue.unshuffle()
        let ids = queue.tracks.map(\.videoId)
        #expect(Array(ids.suffix(4)) == ["r1", "r2", "r3", "r4"])
    }

    @Test("nothing staged means nothing to place")
    func nothingStaged() {
        var queue = atEnd(stagedPage(radio: []))
        var called = false
        let took = queue.takeAutoplay(placing: { fresh, _ in called = true; return fresh })
        #expect(!took)
        #expect(!called)
    }
}

@MainActor
@Suite("MusicService Mix autoplay")
struct MusicServiceMixAutoplayTests {
    private static let page = ["a", "b", "c"]
    private static let radio = ["r1", "r2", "r3", "r4", "r5"]

    private func start(_ h: MixShuffleHarness, mix: Bool) async {
        let all = Self.page + Self.radio
        for id in all { await h.backend.setStream(MusicSamples.stream(videoId: id, duration: 240)) }
        // The song that ends the page is 128 BPM in 8A; r3 matches it, every other radio song is far away.
        for id in Self.page { await h.reader.set(MixRows.row(id, bpm: 128, tonic: 9, minor: true)) }
        for id in Self.radio {
            let match = id == "r3"
            await h.reader.set(MixRows.row(id, bpm: match ? 128 : 70, tonic: match ? 9 : 3, minor: !match))
        }
        await h.backend.setAutomix(afterVideoId: "c", tracks: MusicSamples.tracks("c") + Self.radio.map { MusicSamples.track($0) })
        let page = MusicSamples.page("VLPL1", tracks: Self.page.map { MusicSamples.track($0, title: "Song \($0)") }, audioPlaylistId: nil)
        h.service.play(MusicSamples.track("a", title: "Song a"), in: page)
        await h.settle()
        h.engine.emit(.playingChanged(true))
        if mix {
            h.service.setShuffleMode(.mix)
            await h.settle()
        }
    }

    /// Plays on to the last song of the page, then one more, which brings the radio in.
    private func playThrough(_ h: MixShuffleHarness) async {
        for _ in 0..<(Self.page.count) {
            h.service.next()
            await h.settle()
        }
    }

    @Test("under Mix the radio song that mixes best out of the page's last song plays first")
    func bestFirst() async {
        let h = MixShuffleHarness()
        await start(h, mix: true)
        #expect(h.service.queue.autoplay.map(\.videoId).sorted() == Self.radio.sorted())
        await playThrough(h)
        #expect(h.service.queue.current?.videoId == "r3")
        #expect(Set(h.order.suffix(5)) == Set(Self.radio))
    }

    @Test("Mix off appends the radio as it came")
    func offAppends() async {
        let h = MixShuffleHarness()
        await start(h, mix: false)
        await playThrough(h)
        #expect(h.order.suffix(5).map { $0 } == Self.radio)
        #expect(h.service.queue.current?.videoId == "r1")
    }

    @Test("plain Shuffle appends the radio as it came")
    func shuffleAppends() async {
        let h = MixShuffleHarness()
        await start(h, mix: false)
        h.service.setShuffleMode(.shuffle)
        await h.settle()
        await playThrough(h)
        #expect(h.order.suffix(5).map { $0 } == Self.radio)
    }

    @Test("the song the engine crossfades into is the song the queue hands over to (no cut, no skipped song)")
    func handOverMatchesPreload() async {
        for seed in [1, 2, 3, 4] as [UInt64] {
            let h = MixShuffleHarness(seed: seed)
            for id in Self.page + Self.radio { await h.backend.setStream(MusicSamples.stream(videoId: id, duration: 140)) }
            // Songs short enough that no analysis is waited for. Nothing is known, so the first radio song is a seeded random pick.
            for id in Self.page + ["c"] { await h.backend.setAutomix(afterVideoId: id, tracks: MusicSamples.tracks(id) + Self.radio.map { MusicSamples.track($0) }) }
            let page = MusicSamples.page("VLPL1", tracks: Self.page.map { MusicSamples.track($0, title: "Song \($0)") }, audioPlaylistId: nil)
            h.service.play(MusicSamples.track("a", title: "Song a"), in: page)
            await h.settle()
            h.engine.emit(.playingChanged(true))
            h.service.setShuffleMode(.mix)
            await h.settle()
            for _ in 0..<(Self.page.count - 1) {
                h.service.next()
                await h.settle()
            }
            h.engine.emit(.playingChanged(true))
            let staged = h.service.queue.autoplay.map(\.videoId)
            #expect(staged.count == Self.radio.count)
            h.engine.tick(125, playing: true)
            await h.service.prefetchTask?.value
            h.engine.tick(125.5, playing: true)
            let offered = h.engine.preloads.last?.videoId
            #expect(offered == staged.first)
            let loads = h.engine.loads.count
            let unloads = h.engine.unloadCount
            h.engine.advance()
            await h.settle()
            #expect(h.service.queue.current?.videoId == offered)
            #expect(h.engine.loads.count == loads)
            #expect(h.engine.unloadCount == unloads)
        }
    }

    @Test("a skip that cancels the Mix task does not cancel the placing of the staged radio")
    func placingSurvivesASkip() async {
        let h = MixShuffleHarness()
        await start(h, mix: true)
        // The radio was staged and placed with its rows: r3 mixes best out of the page's last song.
        #expect(h.service.queue.autoplay.first?.videoId == "r3")
        h.service.next()
        await h.settle()
        #expect(h.service.queue.autoplay.first?.videoId == "r3")
    }

    @Test("with no row the radio keeps its order behind a seeded first pick")
    func unknownKeepsRadioOrder() {
        let radio = (1...10).map { MusicSamples.track("r\($0)", title: "Song r\($0)") }
        let anchor = MusicSamples.track("c", title: "Song c")
        var firsts = Set<String>()
        for seed in 1...8 as ClosedRange<UInt64> {
            let placed = MusicService.placement(of: radio, after: anchor, rows: [:], seed: seed).map(\.videoId)
            #expect(Set(placed) == Set(radio.map(\.videoId)))
            firsts.insert(placed[0])
            #expect(Array(placed.dropFirst()) == radio.map(\.videoId).filter { $0 != placed[0] })
        }
        #expect(firsts.count > 1)
    }

    @Test("with no row anywhere the placement is seeded and repeatable")
    func unknownIsSeeded() async {
        var firsts: [String?] = []
        for _ in 0..<2 {
            let h = MixShuffleHarness(seed: 9)
            for id in Self.page + Self.radio { await h.backend.setStream(MusicSamples.stream(videoId: id, duration: 240)) }
            await h.backend.setAutomix(afterVideoId: "c", tracks: MusicSamples.tracks("c") + Self.radio.map { MusicSamples.track($0) })
            let page = MusicSamples.page("VLPL1", tracks: Self.page.map { MusicSamples.track($0, title: "Song \($0)") }, audioPlaylistId: nil)
            h.service.play(MusicSamples.track("a", title: "Song a"), in: page)
            await h.settle()
            h.engine.emit(.playingChanged(true))
            h.service.setShuffleMode(.mix)
            await h.settle()
            await playThrough(h)
            firsts.append(h.service.queue.current?.videoId)
        }
        #expect(firsts[0] == firsts[1])
        #expect(Self.radio.contains(firsts[0] ?? ""))
    }
}
