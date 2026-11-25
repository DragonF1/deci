// DeciTests/Music/MixShuffle/MusicGenreOrderTests.swift
// Sorting by genre: in Mixing, Flow Shuffle keeps songs of one genre together as long as they mix, and the autoplay radio stays
// in the genre of the song it follows.

import Foundation
import Testing
@testable import Deci

@Suite struct MusicGenreScoreTests {
    private func c(_ genre: MusicGenreFamily?, _ bpm: Double? = 120, trusted: Bool = true) -> MusicMixCompact {
        MusicMixCompact(MusicMixProfile(videoId: "x", bpm: bpm, gridTrusted: trusted, genre: genre))
    }

    @Test func aBeatMatchNeedsBothGridsAndFivePercent() {
        #expect(MusicMixScore.tempoCost(c(nil, 100), c(nil, 105)) == 0)
        #expect(MusicMixScore.tempoCost(c(nil, 70), c(nil, 140)) == MusicMixScore.tempoHalfCost)
        #expect(MusicMixScore.tempoCost(c(nil, 100), c(nil, 106)) == MusicMixScore.tempoNearCost)
        #expect(MusicMixScore.tempoCost(c(nil, 100), c(nil, 100, trusted: false)) == MusicMixScore.tempoNearCost)
        #expect(MusicMixScore.tempoCost(c(nil, 100), c(nil, nil)) == MusicMixScore.tempoNearCost)
        #expect(MusicMixScore.tempoCost(c(nil, 100), c(nil, 130)) == MusicMixScore.tempoClashCost)
    }

    @Test func genreCostsRankSameThenRelatedOrUnknownThenAnother() {
        #expect(MusicMixScore.genreCost(c(.house), c(.house)) == 0)
        #expect(MusicMixScore.genreCost(c(.house), c(.techno)) == 1)
        #expect(MusicMixScore.genreCost(c(.house), c(nil)) == 1)
        #expect(MusicMixScore.genreCost(c(.open), c(.house)) == 1)
        #expect(MusicMixScore.genreCost(c(.house), c(.rock)) == 3)
        #expect(MusicMixScore.changesGenre(c(.house), c(.rock)))
        #expect(!MusicMixScore.changesGenre(c(.house), c(.garage)))
        #expect(!MusicMixScore.changesGenre(c(.house), c(nil)))
    }

    @Test func theGenreWinsWhileItStillMixes() {
        let from = c(.house, 120)
        let steps = [
            c(.house, 122), c(.techno, 122), c(.house, 129), c(.rock, 122), c(.house, 160), c(.rock, 160),
        ].map { MusicMixScore.stepCost(from, $0) }
        #expect(steps == steps.sorted() && Set(steps).count == steps.count)
    }

    @Test func withNoGenresOnlyTheTempoCounts() {
        let from = c(nil, 120)
        #expect(MusicMixScore.stepCost(from, c(nil, 122)) < MusicMixScore.stepCost(from, c(nil, 61)))
        #expect(MusicMixScore.stepCost(from, c(nil, 61)) < MusicMixScore.stepCost(from, c(nil, 129)))
        #expect(MusicMixScore.stepCost(from, c(nil, 129)) < MusicMixScore.stepCost(from, c(nil, 160)))
    }

    @Test func tagsNameTheGenreAndAGuessDoesNot() {
        let row = MixRows.row("a", bpm: 124)
        #expect(MusicMixProfile(videoId: "a", artist: "", analysis: row, tags: ["deep house"]).genre == .house)
        #expect(MusicMixProfile(videoId: "a", artist: "", analysis: row).genre == nil)
        #expect(MusicMixProfile(videoId: "a", artist: "", analysis: row, tags: ["seen live"]).genre == nil)
        #expect(MusicMixProfile(videoId: "a", artist: "", analysis: nil, tags: ["rock"]).genre == .rock)
    }
}

@Suite struct MusicGenreOrdererTests {
    private func song(_ id: String, _ bpm: Double, _ genre: MusicGenreFamily?) -> MusicMixProfile {
        MusicMixProfile(
            videoId: id, artist: "artist-\(id)", bpm: bpm, gridTrusted: true, energy: 0.5, introEnergy: 0.3, outroEnergy: 0.3, genre: genre
        )
    }

    /// How often the order goes from one genre to another.
    private func changes(_ ids: [String], in songs: [MusicMixProfile]) -> Int {
        let byId = Dictionary(songs.map { ($0.videoId, $0) }) { a, _ in a }
        return zip(ids, ids.dropFirst()).filter { byId[$0]?.genre != byId[$1]?.genre }.count
    }

    @Test(arguments: [1, 7, 42, 99] as [UInt64])
    func songsOfAGenreStayTogether(seed: UInt64) {
        let families: [MusicGenreFamily] = [.house, .rock, .hipHop]
        let songs = (0..<30).map { song("s\($0)", 120 + Double($0 % 4), families[$0 % 3]) }
        var orderer = MusicMixOrderer(seed: seed)
        let order = orderer.order(songs, first: song("a", 120, .rock))
        #expect(Set(order) == Set(songs.map(\.videoId)))
        #expect(changes(order, in: songs) == 2)
        #expect(songs.first { $0.videoId == order.first }?.genre == .rock)
    }

    @Test(arguments: [1, 7, 42, 99] as [UInt64])
    func aSongOnTheBeatComesBeforeOneThatOnlyFits(seed: UInt64) {
        let songs = [song("near", 108, nil), song("match", 102, nil), song("far", 150, nil)]
        var orderer = MusicMixOrderer(seed: seed)
        #expect(orderer.order(songs, first: song("a", 100, nil)) == ["match", "near", "far"])
    }

    @Test(arguments: [1, 7, 42] as [UInt64])
    func aClashIsWorseThanAChangeOfGenre(seed: UInt64) {
        let songs = [song("clash", 150, .house), song("change", 100, .rock)]
        var orderer = MusicMixOrderer(seed: seed)
        #expect(orderer.order(songs, first: song("a", 100, .house)).first == "change")
    }

    @Test func theRadioPickTakesTheGenreFirst() {
        let anchor = song("a", 120, .house)
        let best = MusicRadioPick.best(of: [song("rock", 120, .rock), song("house", 150, .house)], after: anchor)
        #expect(best?.videoId == "house")
        var orderer = MusicMixOrderer(seed: 3)
        #expect(orderer.pickBest(from: [song("rock", 120, .rock), song("house", 150, .house)], after: anchor)?.videoId == "house")
    }
}

@Suite struct MusicRadioGenreTests {
    @Test func theSameGenreComesFirstAndOthersLeave() {
        let ids = (1...12).map { "r\($0)" }
        var families: [String: MusicGenreFamily] = [:]
        for (i, id) in ids.enumerated() { families[id] = i % 2 == 0 ? .rock : .house }
        // Six rock songs are more than the reserve: no house song stays.
        #expect(MusicRadioGenre.kept(ids, families: families, anchor: .rock) == ["r1", "r3", "r5", "r7", "r9", "r11"])
    }

    @Test func unknownSongsStayBehindTheKnownOnes() {
        let kept = MusicRadioGenre.kept(["a", "b", "c", "d", "e", "f"], families: ["a": .house, "c": .rock, "f": .rock], anchor: .rock)
        #expect(kept == ["c", "f", "b", "d", "e"])
    }

    @Test func theQueueNeverRunsDry() {
        let ids = (1...10).map { "r\($0)" }
        let families = Dictionary(uniqueKeysWithValues: ids.map { ($0, MusicGenreFamily.house) })
        #expect(MusicRadioGenre.kept(ids, families: families, anchor: .rock) == Array(ids.prefix(MusicRadioGenre.reserve)))
        #expect(MusicRadioGenre.reserve > MusicQueue.refillThreshold)
        #expect(MusicRadioGenre.kept(["r1"], families: families, anchor: .rock) == ["r1"])
    }

    @Test func aRelatedGenreStaysLonger() {
        let ids = (1...12).map { "r\($0)" }
        let families = Dictionary(uniqueKeysWithValues: ids.map { ($0, MusicGenreFamily.techno) })
        #expect(MusicRadioGenre.kept(ids, families: families, anchor: .house).count == MusicRadioGenre.nearReserve)
    }

    @Test func anOpenAnchorChangesNothing() {
        #expect(MusicRadioGenre.kept(["a", "b"], families: ["a": .rock], anchor: .open) == ["a", "b"])
    }
}

@MainActor
@Suite("MusicQueue radio genre")
struct MusicQueueRadioGenreTests {
    private func radioQueue() -> MusicQueue {
        var queue = MusicQueue()
        queue.start(with: MusicSamples.track("s"))
        queue.append(["r1", "r2", "r3", "r4"].map { MusicSamples.track($0) }, continuation: nil)
        return queue
    }

    @Test("songs left out leave the queue, and a later page may bring them again")
    func keepHead() {
        var queue = radioQueue()
        queue.keepRadioHead(["r3", "r1"])
        #expect(queue.tracks.map(\.videoId) == ["s", "r3", "r1"])
        queue.append(["r2", "r5"].map { MusicSamples.track($0) }, continuation: nil)
        #expect(queue.tracks.map(\.videoId) == ["s", "r3", "r1", "r2", "r5"])
    }

    @Test("naming none of them changes nothing")
    func keepNone() {
        var queue = radioQueue()
        queue.keepRadioHead(["x"])
        #expect(queue.tracks.map(\.videoId) == ["s", "r1", "r2", "r3", "r4"])
    }

    @Test("a song the listener queued stays and so does everything behind it")
    func keepsListenerSongs() {
        var queue = radioQueue()
        queue.playNext(MusicSamples.track("mine"))
        queue.keepRadioHead(["r1"])
        #expect(queue.tracks.map(\.videoId) == ["s", "mine", "r1", "r2", "r3", "r4"])
    }

    @Test("the radio follows the last song it did not bring itself")
    func anchor() {
        var queue = radioQueue()
        #expect(queue.radioAnchorIndex == 0)
        queue.advance()
        #expect(queue.radioAnchorIndex == 0)
    }
}

@MainActor
@Suite("MusicService genre order")
struct MusicServiceGenreOrderTests {
    private actor Asked {
        var ids: [String] = []
        func add(_ id: String) { ids.append(id) }
    }

    private let asked = Asked()

    private nonisolated static func facts(_ tag: String) -> MusicSongFacts {
        var facts = MusicSongFacts(fetchedAt: Date(timeIntervalSince1970: 0))
        facts.tags = [tag]
        return facts
    }

    /// Songs whose stored tags are known at once, and songs a lookup finds them for.
    private func lookahead(stored: [String: String], found: [String: String] = [:]) -> MusicGenreLookahead {
        MusicGenreLookahead(
            readCache: { id in
                stored[id].map { MusicSongFactsCached(facts: Self.facts($0), lookupIsFresh: true, measureAttempted: false) }
            },
            lookup: { [asked] id, _ in
                await asked.add(id)
                return found[id].map { .found(Self.facts($0)) } ?? .notFound
            }
        )
    }

    private func settle(_ h: MixShuffleHarness) async {
        await h.settle()
        while let task = h.service.genreTask {
            await task.value
            await h.settle()
        }
        await h.settle()
    }

    private func mixing(_ lookahead: MusicGenreLookahead, _ mode: MusicTransitionMode = .mixing) -> MixShuffleHarness {
        MixShuffleHarness(preferences: MusicPlaybackPreferences(transitionMode: mode), genreLookahead: lookahead)
    }

    private static let songs = (1...12).map { "p\($0)" }
    /// p1, p3... are house, p2, p4... are rock.
    private static let tags = Dictionary(uniqueKeysWithValues: songs.enumerated().map { ($1, $0 % 2 == 0 ? "house" : "rock") })

    private func changes(_ order: [String]) -> Int {
        zip(order, order.dropFirst()).filter { Self.tags[$0] != Self.tags[$1] }.count
    }

    private func startPage(_ h: MixShuffleHarness, songs: [String] = songs) async {
        for id in songs {
            await h.backend.setStream(MusicSamples.stream(videoId: id, duration: 240))
            await h.reader.set(MixRows.row(id, bpm: 120))
        }
        let tracks = songs.map { MusicSamples.track($0, title: "Song \($0)", artist: "Artist \($0)") }
        h.service.play(tracks[0], in: MusicSamples.page("VLPL1", tracks: tracks, audioPlaylistId: nil))
        await h.settle()
        h.engine.emit(.playingChanged(true))
        await settle(h)
    }

    @Test("Flow Shuffle in Mixing keeps a genre together")
    func flowSortsByGenre() async {
        let h = mixing(lookahead(stored: Self.tags))
        await startPage(h)
        h.service.setShuffleMode(.flow)
        await settle(h)
        #expect(Set(h.order) == Set(Self.songs))
        #expect(changes(h.order) == 1)
        #expect(await asked.ids.isEmpty)
    }

    @Test("genres that are looked up put the songs behind the visible ones in order again")
    func lookedUpGenresReorder() async {
        let h = mixing(lookahead(stored: [:], found: Self.tags))
        await startPage(h)
        h.service.setShuffleMode(.flow)
        await settle(h)
        #expect(Set(await asked.ids) == Set(Self.songs))
        #expect(await asked.ids.count == Self.songs.count)
        #expect(changes(Array(h.order.dropFirst(3))) <= 2)
    }

    @Test("plain shuffle and the other transition modes never ask for a genre")
    func onlyFlowAndMixing() async {
        for (mode, shuffle) in [(MusicTransitionMode.crossfade, MusicShuffleMode.flow), (.off, .flow), (.mixing, .shuffle)] {
            let h = mixing(lookahead(stored: [:], found: Self.tags), mode)
            await startPage(h)
            h.service.setShuffleMode(shuffle)
            await settle(h)
            #expect(await asked.ids.isEmpty)
        }
    }

    @Test("offline nothing is looked up, and it is when the network is back")
    func offline() async {
        let h = mixing(lookahead(stored: [:], found: Self.tags))
        await startPage(h)
        h.connectivity.update(isOnline: false)
        h.service.setShuffleMode(.flow)
        await settle(h)
        #expect(await asked.ids.isEmpty)
        h.connectivity.update(isOnline: true)
        await settle(h)
        #expect(!(await asked.ids).isEmpty)
    }

    // MARK: Radio

    private static let radio = (1...12).map { "r\($0)" }
    /// r2, r4... are rock like the song they follow.
    private static let radioTags = Dictionary(uniqueKeysWithValues: radio.enumerated().map { ($1, $0 % 2 == 1 ? "rock" : "house") })
    private static let rock = ["r2", "r4", "r6", "r8", "r10", "r12"]

    private func startRadio(_ h: MixShuffleHarness, artist: String? = nil) async {
        for id in ["s"] + Self.radio {
            await h.backend.setStream(MusicSamples.stream(videoId: id, duration: 240))
            await h.reader.set(MixRows.row(id, bpm: 120))
        }
        let tracks = (["s"] + Self.radio).map {
            MusicSamples.track($0, title: "Song \($0)", artist: $0 == "s" ? "Seed" : artist ?? "Artist \($0)")
        }
        await h.backend.setRadio(seed: "s", tracks: tracks, continuation: nil)
        h.service.play(tracks[0])
        await h.settle()
        h.engine.emit(.playingChanged(true))
        await settle(h)
        await h.service.radioScanTask?.value
        await settle(h)
    }

    @Test("a radio stays in the genre of the song it was started from")
    func radioStays() async {
        let tags = Self.radioTags.merging(["s": "rock"]) { a, _ in a }
        let h = mixing(lookahead(stored: tags))
        await startRadio(h)
        #expect(Set(h.order) == Set(["s"] + Self.rock))
        #expect(h.service.transitionLines.contains { $0.hasPrefix("radio_genre family=rock kept=6") })
    }

    @Test("genres that are looked up keep the radio in its genre too")
    func radioLooksUp() async {
        let tags = Self.radioTags.merging(["s": "rock"]) { a, _ in a }
        let h = mixing(lookahead(stored: [:], found: tags))
        await startRadio(h)
        #expect(h.order.first == "s")
        #expect(h.order.dropFirst().prefix(6).filter { Self.rock.contains($0) }.count >= 5)
    }

    @Test("the tags of another song of the artist never leave a song out of the radio")
    func artistTagsKeep() async {
        // r1 is house and looked up; every other song is by the same artist and has no tags of its own.
        let h = mixing(lookahead(stored: ["s": "rock", "r1": "house"]))
        await startRadio(h, artist: "One Artist")
        #expect(Set(h.order).isSuperset(of: Self.radio.dropFirst()))
        #expect(Set(await asked.ids) == Set(Self.radio.dropFirst()))
    }

    @Test("without Mixing the radio keeps every song in its own order")
    func radioOutsideMixing() async {
        let tags = Self.radioTags.merging(["s": "rock"]) { a, _ in a }
        let h = mixing(lookahead(stored: tags), .off)
        await startRadio(h)
        #expect(h.order == ["s"] + Self.radio)
    }

    @Test("a radio staged behind a page follows the page's last song")
    func stagedRadioStays() async {
        let tags = Self.radioTags.merging(["a": "rock"]) { a, _ in a }
        let h = mixing(lookahead(stored: tags))
        for id in ["a"] + Self.radio {
            await h.backend.setStream(MusicSamples.stream(videoId: id, duration: 240))
            await h.reader.set(MixRows.row(id, bpm: 120))
        }
        let radio = Self.radio.map { MusicSamples.track($0, title: "Song \($0)", artist: "Artist \($0)") }
        await h.backend.setAutomix(afterVideoId: "a", tracks: MusicSamples.tracks("a") + radio)
        let page = MusicSamples.page("VLPL1", tracks: [MusicSamples.track("a", title: "Song a")], audioPlaylistId: nil)
        h.service.play(MusicSamples.track("a", title: "Song a"), in: page)
        await h.settle()
        h.engine.emit(.playingChanged(true))
        await settle(h)
        await h.service.radioScanTask?.value
        await settle(h)
        #expect(Set(h.service.queue.autoplay.map(\.videoId)) == Set(Self.rock))
    }
}
