// DeciTests/Music/MixShuffle/MusicServiceMixShuffleTests.swift
// Tier 4 P3: the service's Mix mode. The three-state cycle, the queue ordered from the stored rows, plain Shuffle and Off
// behaving as before, the pairs Up next reads, and the choice remembered across launches.

import Foundation
import Testing
@testable import Deci

@MainActor
final class SavedPreferences {
    var last: MusicPlaybackPreferences?
    var count = 0
}

@MainActor
struct MixShuffleHarness {
    let backend = FakeMusicBackend()
    let engine = FakePlaybackEngine()
    let surface = FakeNowPlayingSurface()
    let clock = MutableClock()
    let connectivity = MusicConnectivity(isOnline: true)
    let provider = FakeAnalysisProvider()
    let reader = FakeAnalysisReader()
    let saved = SavedPreferences()
    let player: MusicPlayer
    let service: MusicService

    init(preferences: MusicPlaybackPreferences = MusicPlaybackPreferences(), withReader: Bool = true, seed: UInt64 = 11) {
        let engine = self.engine
        let clock = self.clock
        let saved = self.saved
        let player = MusicPlayer(engine: engine)
        self.player = player
        service = MusicService(
            backend: backend,
            player: player,
            presentSignIn: { _ in },
            presentChannelPicker: { _, _ in },
            closeSignInWindow: {},
            raiseSignInWindow: {},
            nowPlaying: NowPlayingController(surface: surface, fetchArtwork: { _ in nil }),
            now: { clock.now },
            preferences: preferences,
            savePreferences: { saved.last = $0; saved.count += 1 },
            shuffleSeed: seed,
            queueRetryDelay: .seconds(60),
            connectivity: connectivity,
            refreshOnCreate: false,
            analysis: provider,
            analysisReader: withReader ? reader : nil
        )
    }

    static let ids = ["a", "b", "c", "d", "e", "f"]
    static let tempos: [String: Double] = ["a": 120, "b": 90, "c": 120, "d": 90, "e": 120, "f": 90]

    func storeRows() async {
        for (index, id) in Self.ids.enumerated() {
            await reader.set(MixRows.row(id, bpm: Self.tempos[id], tonic: index, minor: index % 2 == 0))
        }
    }

    func settle() async {
        while true {
            let play = service.playTask
            let radio = service.radioTask
            let mix = service.mixTask
            let staged = service.stagedRadioTask
            await staged?.value
            await play?.value
            await radio?.value
            await mix?.value
            await service.currentAnalysisTask?.value
            await service.analysisCleanupTask?.value
            await service.transitionReadTask?.value
            if service.playTask == play, service.radioTask == radio, service.mixTask == mix { break }
        }
    }

    func startQueue(_ ids: [String] = MixShuffleHarness.ids) async {
        for id in ids { await backend.setStream(MusicSamples.stream(videoId: id, duration: 240)) }
        let tracks = ids.map { MusicSamples.track($0, title: "Song \($0)", artist: "Artist \($0)") }
        await backend.setRadio(seed: ids[0], tracks: tracks, continuation: nil)
        service.play(tracks[0])
        await settle()
        engine.emit(.playingChanged(true))
    }

    var order: [String] { service.queue.tracks.map(\.videoId) }

    /// How many neighbours in `order` differ in tempo (the ids in `tempos`).
    static func tempoJumps(_ order: [String]) -> Int {
        zip(order, order.dropFirst()).filter { tempos[$0.0] != tempos[$0.1] }.count
    }
}

@MainActor
@Suite("MusicService Mix shuffle")
struct MusicServiceMixShuffleTests {
    @Test("the button cycles Off, Shuffle, Mix, Off and each step is saved")
    func cycle() async {
        let h = MixShuffleHarness()
        #expect(h.service.shuffleMode == .off)
        h.service.cycleShuffleMode()
        #expect(h.service.shuffleMode == .shuffle)
        #expect(h.saved.last?.shuffleMode == .shuffle)
        h.service.cycleShuffleMode()
        #expect(h.service.shuffleMode == .mix)
        #expect(h.service.isShuffleOn)
        #expect(h.service.isMixOn)
        #expect(h.saved.last?.shuffleMode == .mix)
        #expect(h.saved.last?.shuffle == true)
        h.service.cycleShuffleMode()
        #expect(h.service.shuffleMode == .off)
        #expect(!h.service.isShuffleOn)
        #expect(!h.service.isMixOn)
        #expect(h.saved.last?.shuffleMode == .off)
    }

    @Test("setting the mode already set saves nothing")
    func sameModeIsQuiet() {
        let h = MixShuffleHarness()
        h.service.setShuffleMode(.off)
        #expect(h.saved.count == 0)
        h.service.setShuffleMode(.mix)
        h.service.setShuffleMode(.mix)
        #expect(h.saved.count == 1)
    }

    @Test("a launch with Mix saved comes up in Mix")
    func restoredMix() {
        let h = MixShuffleHarness(preferences: MusicPlaybackPreferences(mixShuffle: true))
        #expect(h.service.shuffleMode == .mix)
        #expect(h.service.isShuffleOn)
    }

    @Test("Mix keeps the playing song, every song and the natural order for Off")
    func mixPermutesUpcoming() async {
        let h = MixShuffleHarness()
        await h.storeRows()
        await h.startQueue()
        let natural = h.order
        h.service.setShuffleMode(.mix)
        await h.settle()
        #expect(h.service.queue.isShuffled)
        #expect(h.order.first == "a")
        #expect(Set(h.order) == Set(natural))
        #expect(h.order.count == natural.count)
        // Rows are known, so Mix lays the songs out by tempo: fewer jumps than the alternating natural order.
        #expect(MixShuffleHarness.tempoJumps(h.order) < MixShuffleHarness.tempoJumps(natural))
        h.service.setShuffleMode(.off)
        #expect(h.order == natural)
        #expect(!h.service.queue.isShuffled)
    }

    @Test("Shuffle to Mix orders the queue from where it stands and Mix to Shuffle leaves it alone")
    func shuffleToMixToShuffle() async {
        let h = MixShuffleHarness()
        await h.storeRows()
        await h.startQueue()
        h.service.setShuffleMode(.shuffle)
        let shuffled = h.order
        #expect(Set(shuffled) == Set(MixShuffleHarness.ids))
        h.service.setShuffleMode(.mix)
        await h.settle()
        #expect(Set(h.order) == Set(shuffled))
        #expect(h.order.first == shuffled.first)
        let mixed = h.order
        h.service.setShuffleMode(.shuffle)
        #expect(h.order == mixed)
        #expect(h.service.mixPairs.isEmpty)
    }

    @Test("plain Shuffle orders the queue exactly as it did before Mix existed")
    func plainShuffleUnchanged() async {
        let h = MixShuffleHarness(seed: 21)
        await h.storeRows()
        await h.startQueue()
        var expected = h.service.queue
        var generator = MusicShuffleGenerator(seed: 21)
        expected.shuffle(mixingEarlier: expected.isPage, using: &generator)
        h.service.setShuffleMode(.shuffle)
        #expect(h.order == expected.tracks.map(\.videoId))
        #expect(h.service.mixPairs.isEmpty)
        #expect(h.service.mixInfo(from: "a", to: "b") == nil)
    }

    @Test("the same seed and the same rows give the same Mix order")
    func deterministic() async {
        var orders: [[String]] = []
        for _ in 0..<2 {
            let h = MixShuffleHarness(seed: 5)
            await h.storeRows()
            await h.startQueue()
            h.service.setShuffleMode(.mix)
            await h.settle()
            orders.append(h.order)
        }
        #expect(orders[0] == orders[1])
    }

    @Test("a song the listener queued stays right after the playing one")
    func queuedSongStays() async {
        let h = MixShuffleHarness()
        await h.storeRows()
        await h.startQueue()
        h.service.playNext(MusicSamples.track("e", title: "Song e", artist: "Artist e"))
        let before = h.service.queue.upcoming.first?.videoId
        h.service.setShuffleMode(.mix)
        await h.settle()
        #expect(before == "e")
        #expect(h.service.queue.upcoming.first?.videoId == "e")
        #expect(Set(h.order) == Set(MixShuffleHarness.ids))
    }

    @Test("Mix fills the pairs Up next reads: tempo, key and how each song is reached")
    func pairsFilled() async throws {
        let h = MixShuffleHarness()
        await h.storeRows()
        await h.startQueue()
        #expect(h.service.mixInfo(from: "a", to: "b") == nil)
        h.service.setShuffleMode(.mix)
        await h.settle()
        let chain = h.order
        for (before, after) in zip(chain, chain.dropFirst()) {
            let info = try #require(h.service.mixInfo(from: before, to: after))
            #expect(info.bpm == Int(try #require(MixShuffleHarness.tempos[after])))
            #expect(info.camelot != nil)
            #expect(info.rowText != nil)
        }
        let first = try #require(h.service.mixInfo(from: chain[0], to: chain[1]))
        let sameTempo = MixShuffleHarness.tempos[chain[0]] == MixShuffleHarness.tempos[chain[1]]
        // A beat mix needs the same tempo; the tempo gate now puts equal tempos together, but the key can still rule beat out.
        #expect(first.mode != .beat || sameTempo)
    }

    @Test("leaving Mix clears the pairs and the info reads nil")
    func leavingMixClears() async {
        let h = MixShuffleHarness()
        await h.storeRows()
        await h.startQueue()
        h.service.setShuffleMode(.mix)
        await h.settle()
        #expect(!h.service.mixPairs.isEmpty)
        h.service.setShuffleMode(.off)
        #expect(h.service.mixPairs.isEmpty)
        #expect(h.service.mixInfo(from: h.order[0], to: h.order[1]) == nil)
    }

    @Test("a song with no stored row still takes part and shows no numbers")
    func missingRow() async {
        let ids = MixShuffleHarness.ids
        // Rows exist for every song but "c": its pair is left out rather than guessed.
        let h2 = MixShuffleHarness()
        for id in ids where id != "c" { await h2.reader.set(MixRows.row(id)) }
        await h2.startQueue()
        h2.service.setShuffleMode(.mix)
        await h2.settle()
        #expect(Set(h2.order) == Set(ids))
        let chain = h2.order
        for (before, after) in zip(chain, chain.dropFirst()) where before == "c" || after == "c" {
            #expect(h2.service.mixInfo(from: before, to: after) == nil)
        }
    }

    @Test("without a row reader Mix still orders and shows nothing")
    func noReader() async {
        let h = MixShuffleHarness(withReader: false)
        await h.startQueue()
        h.service.setShuffleMode(.mix)
        await h.settle()
        #expect(Set(h.order) == Set(MixShuffleHarness.ids))
        #expect(h.order.first == "a")
        #expect(h.service.mixPairs.isEmpty)
    }

    @Test("starting a song in Mix keeps the shuffle mode and orders the radio behind it")
    func playInMix() async {
        let h = MixShuffleHarness(preferences: MusicPlaybackPreferences(mixShuffle: true))
        await h.storeRows()
        await h.startQueue()
        #expect(h.service.shuffleMode == .mix)
        #expect(h.order.first == "a")
        #expect(Set(h.order) == Set(MixShuffleHarness.ids))
        #expect(h.service.queue.isShuffled)
        #expect(MixShuffleHarness.tempoJumps(h.order) < MixShuffleHarness.tempoJumps(MixShuffleHarness.ids))
    }

    @Test("with Mix on, a song picked from the middle of a list is what plays, and it stays current and first after the ordering")
    func pickedSongStaysCurrentInMix() async {
        let h = MixShuffleHarness(preferences: MusicPlaybackPreferences(mixShuffle: true))
        await h.storeRows()
        for id in MixShuffleHarness.ids { await h.backend.setStream(MusicSamples.stream(videoId: id, duration: 240)) }
        let page = MusicSamples.page(
            "VLmixpick",
            tracks: MixShuffleHarness.ids.map { MusicSamples.track($0, title: "Song \($0)") },
            continuation: nil,
            audioPlaylistId: nil
        )
        h.service.play(MusicSamples.track("c", title: "Song c"), in: page)
        await h.settle()
        h.engine.emit(.playingChanged(true))
        await h.settle()

        #expect(h.service.shuffleMode == .mix)
        #expect(h.player.nowPlaying?.videoId == "c")
        #expect(h.order.first == "c")
        #expect(h.service.queue.current?.videoId == "c")
        #expect(Set(h.order) == Set(MixShuffleHarness.ids))
        #expect(h.engine.loads.first?.stream.videoId == "c")
    }

    @Test("resetting settings puts the button back to Off, Mix included")
    func reset() {
        let h = MixShuffleHarness(preferences: MusicPlaybackPreferences(mixShuffle: true))
        h.service.settingsDidReset()
        #expect(h.service.shuffleMode == .off)
    }

    @Test("a song change in Mix refreshes the pairs for the new playing song")
    func pairsFollowTheSong() async throws {
        let h = MixShuffleHarness()
        await h.storeRows()
        await h.startQueue()
        h.service.setShuffleMode(.mix)
        await h.settle()
        let next = try #require(h.service.queue.upcoming.first)
        h.service.jump(to: next)
        await h.settle()
        let chain = h.order
        let index = try #require(chain.firstIndex(of: next.videoId))
        if index + 1 < chain.count {
            #expect(h.service.mixInfo(from: next.videoId, to: chain[index + 1]) != nil)
        }
    }
}
