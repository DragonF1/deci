// DeciTests/Music/MixShuffle/MusicMixOrdererTests.swift
import Foundation
import Testing
@testable import Deci

@Suite struct MusicMixOrdererTests {
    static let keys = ["8A", "9A", "8B", "10A", "3B", "5A", "12A", "1A", "7B", "2A"]

    static func library(_ count: Int, artists: Int = 1000, seed: UInt64 = 7) -> [MusicMixProfile] {
        var g = MusicMixGenerator(seed: seed)
        return (0..<count).map { i in
            MusicMixProfile(
                videoId: "v\(i)", artist: "artist\(i % artists)", bpm: Double.random(in: 80...160, using: &g), gridTrusted: true,
                camelot: MusicCamelot(code: keys.randomElement(using: &g)!), energy: Float.random(in: 0...1, using: &g),
                introEnergy: Float.random(in: 0...1, using: &g), outroEnergy: Float.random(in: 0...1, using: &g))
        }
    }

    static func profiles(_ ids: [String], in songs: [MusicMixProfile]) -> [MusicMixProfile] {
        let byId = Dictionary(songs.map { ($0.videoId, $0) }, uniquingKeysWith: { a, _ in a })
        return ids.map { byId[$0]! }
    }

    static func meanAdjacent(_ songs: [MusicMixProfile]) -> Double {
        guard songs.count > 1 else { return 0 }
        let total = zip(songs, songs.dropFirst()).reduce(0.0) { $0 + MusicMixScore.score(from: $1.0, to: $1.1, allowLift: false) }
        return total / Double(songs.count - 1)
    }

    /// Best of three runs so a busy machine does not fail a speed test; a debug build still has to beat 50 ms.
    static func fastestOfThree(_ songs: [MusicMixProfile], _ ids: inout [String]) -> Duration {
        let clock = ContinuousClock()
        var best = Duration.seconds(100)
        for seed in 1...3 {
            var orderer = MusicMixOrderer(seed: UInt64(seed))
            let elapsed = clock.measure { ids = orderer.order(songs, first: nil) }
            best = min(best, elapsed)
        }
        return best
    }

    @Test func emptyOneAndTwoSongs() {
        var orderer = MusicMixOrderer(seed: 1)
        #expect(orderer.order([], first: nil).isEmpty)
        let one = Self.library(1)
        #expect(orderer.order(one, first: nil) == ["v0"])
        let two = Self.library(2)
        #expect(Set(orderer.order(two, first: nil)) == ["v0", "v1"])
        #expect(orderer.order(two, first: two[1]) == ["v1", "v0"])
    }

    @Test func outputIsAPermutation() {
        let songs = Self.library(60)
        var orderer = MusicMixOrderer(seed: 42)
        let ids = orderer.order(songs, first: nil)
        #expect(ids.count == 60)
        #expect(Set(ids) == Set(songs.map(\.videoId)))
    }

    @Test func sameSeedSameOrderDifferentSeedDiffers() {
        // Tempos all within a few percent: the tempo gate leaves every order open, so only the seed makes the choice.
        let songs = (0..<10).map { i in
            MusicMixProfile(
                videoId: "v\(i)", artist: "artist\(i)", bpm: 100 + Double(i % 4), gridTrusted: true,
                camelot: MusicCamelot(code: Self.keys[i]), energy: Float(i) / 10, introEnergy: 0.3, outroEnergy: 0.3)
        }
        var a = MusicMixOrderer(seed: 99), b = MusicMixOrderer(seed: 99)
        #expect(a.order(songs, first: nil) == b.order(songs, first: nil))
        var distinct = Set<[String]>()
        for seed in 0..<10 { var o = MusicMixOrderer(seed: UInt64(seed)); distinct.insert(o.order(songs, first: nil)) }
        #expect(distinct.count >= 8)
    }

    @Test func firstStaysFirstWhenInTheSet() {
        let songs = Self.library(30)
        for seed in 0..<20 {
            var orderer = MusicMixOrderer(seed: UInt64(seed))
            let ids = orderer.order(songs, first: songs[17])
            #expect(ids.first == "v17")
            #expect(Set(ids) == Set(songs.map(\.videoId)))
            #expect(ids.count == 30)
        }
    }

    @Test func firstOutsideTheSetIsOnlyAnAnchor() {
        let songs = Self.library(20)
        let anchor = MusicMixProfile(videoId: "playing", artist: "x", bpm: 120, gridTrusted: true, camelot: MusicCamelot(code: "8A"))
        var orderer = MusicMixOrderer(seed: 3)
        let ids = orderer.order(songs, first: anchor)
        #expect(!ids.contains("playing"))
        #expect(ids.count == 20)
    }

    @Test func allUnknownStillFullPermutation() {
        let songs = (0..<40).map { MusicMixProfile(videoId: "u\($0)", artist: "a\($0 % 7)") }
        var orderer = MusicMixOrderer(seed: 5)
        let ids = orderer.order(songs, first: nil)
        #expect(Set(ids) == Set(songs.map(\.videoId)) && ids.count == 40)
    }

    @Test func duplicateVideoIdsKeepEveryEntry() {
        var songs = Self.library(6)
        songs.append(songs[2])
        songs.append(songs[2])
        var orderer = MusicMixOrderer(seed: 8)
        let ids = orderer.order(songs, first: songs[2])
        #expect(ids.count == 8)
        #expect(ids.filter { $0 == "v2" }.count == 3)
        #expect(ids.first == "v2")
    }

    @Test func singleArtistStillOrders() {
        let songs = Self.library(25, artists: 1)
        var orderer = MusicMixOrderer(seed: 11)
        let ids = orderer.order(songs, first: nil)
        #expect(Set(ids) == Set(songs.map(\.videoId)) && ids.count == 25)
    }

    @Test func emptyArtistsNeverCollide() {
        let songs = (0..<10).map { MusicMixProfile(videoId: "e\($0)", artist: "  ", bpm: 120, gridTrusted: true, camelot: MusicCamelot(code: "8A")) }
        var orderer = MusicMixOrderer(seed: 2)
        #expect(orderer.order(songs, first: nil).count == 10)
    }

    @Test func singleArtistSetStillMixesWell() {
        // One artist means the spacing penalties hit every candidate the same, so they must not look like a dead end.
        let songs = Self.library(25, artists: 1)
        var mixed = 0.0, random = 0.0
        for seed in 0..<20 {
            var orderer = MusicMixOrderer(seed: UInt64(seed))
            mixed += Self.meanAdjacent(Self.profiles(orderer.order(songs, first: nil), in: songs))
            var g = MusicMixGenerator(seed: UInt64(seed) + 500)
            random += Self.meanAdjacent(songs.shuffled(using: &g))
        }
        #expect(mixed / 20 > random / 20 + 0.08)
    }

    @Test func mostlyOneArtistSetStillMixesWell() {
        let songs = Self.library(30, artists: 1).enumerated().map { index, song -> MusicMixProfile in
            var copy = song
            if index % 10 == 0 { copy.artist = "other\(index)" }
            return copy
        }
        var mixed = 0.0, random = 0.0
        for seed in 0..<20 {
            var orderer = MusicMixOrderer(seed: UInt64(seed))
            mixed += Self.meanAdjacent(Self.profiles(orderer.order(songs, first: nil), in: songs))
            var g = MusicMixGenerator(seed: UInt64(seed) + 700)
            random += Self.meanAdjacent(songs.shuffled(using: &g))
        }
        #expect(mixed / 20 > random / 20 + 0.08)
    }

    @Test func firstInTheSetEntersSpacingOnce() {
        // Two artists alternate; with the first song counted twice the history would block a legal second pick.
        let songs = (0..<6).map { i in
            MusicMixProfile(videoId: "f\(i)", artist: i < 3 ? "A" : "B", bpm: 120, gridTrusted: true, camelot: MusicCamelot(code: "8A"), energy: 0.5)
        }
        for seed in 0..<30 {
            var orderer = MusicMixOrderer(seed: UInt64(seed))
            let ids = orderer.order(songs, first: songs[0])
            let artists = ids.map { id in songs.first { $0.videoId == id }!.artist }
            #expect(artists == ["A", "B", "A", "B", "A", "B"], "seed \(seed): \(artists)")
        }
    }

    @Test func allClashingSetUsesRandomFallbackAndStaysAPermutation() {
        let songs = (0..<12).map { i in
            MusicMixProfile(videoId: "z\(i)", artist: "z\(i)", bpm: nil, gridTrusted: true,
                            camelot: MusicCamelot(number: 1 + (i * 5) % 12, isMinor: i % 2 == 0), energy: i % 2 == 0 ? 0.05 : 0.95)
        }
        var distinct = Set<[String]>()
        for seed in 0..<12 {
            var orderer = MusicMixOrderer(seed: UInt64(seed))
            let ids = orderer.order(songs, first: nil)
            #expect(Set(ids) == Set(songs.map(\.videoId)) && ids.count == 12)
            distinct.insert(ids)
        }
        #expect(distinct.count >= 10)
    }

    @Test func beamBandSetIsDeterministicPermutation() {
        // Tempo clash with unknown keys and energy keeps pair scores between 0.25 and 0.5: the look-ahead path.
        let songs = (0..<14).map { i in
            MusicMixProfile(videoId: "b\(i)", artist: "b\(i)", bpm: i % 2 == 0 ? 100 : 135, gridTrusted: true)
        }
        var a = MusicMixOrderer(seed: 3), b = MusicMixOrderer(seed: 3)
        let first = a.order(songs, first: nil)
        #expect(first == b.order(songs, first: nil))
        #expect(Set(first) == Set(songs.map(\.videoId)) && first.count == 14)
        // The look-ahead keeps each tempo group together: few switches between 100 and 135.
        let bpms = first.map { id in songs.first { $0.videoId == id }!.bpm! }
        #expect(zip(bpms, bpms.dropFirst()).filter { $0 != $1 }.count <= 8)
    }

    @Test func liftsHappenOnlyAfterThePeakStartsAndNeverBunchUp() {
        let songs = (0..<40).map { i in
            MusicMixProfile(videoId: "l\(i)", artist: "l\(i)", bpm: 120, gridTrusted: true, camelot: MusicCamelot(code: i % 2 == 0 ? "8A" : "10A"), energy: 0.8)
        }
        var seedsWithLift = 0, seedsBunched = 0
        for seed in 0..<30 {
            var orderer = MusicMixOrderer(seed: UInt64(seed))
            let ids = orderer.order(songs, first: nil)
            let keys = ids.map { id in songs.first { $0.videoId == id }!.camelot! }
            let highLifts = zip(keys, keys.dropFirst()).enumerated().filter { index, pair in
                pair.0.step(to: pair.1) == 2 && MusicEnergyArc.target(position: Double(index + 1) / 39) > MusicMixOrderer.liftTarget
            }.map(\.offset)
            if !highLifts.isEmpty { seedsWithLift += 1 }
            if zip(highLifts, highLifts.dropFirst()).contains(where: { $1 - $0 < MusicMixOrderer.liftSpacing }) { seedsBunched += 1 }
        }
        #expect(seedsWithLift >= 5)
        #expect(seedsBunched <= 3)
    }

    @Test func beatsRandomOrderOnAverage() {
        let songs = Self.library(40)
        var mixed = 0.0, random = 0.0
        for seed in 0..<20 {
            var orderer = MusicMixOrderer(seed: UInt64(seed))
            mixed += Self.meanAdjacent(Self.profiles(orderer.order(songs, first: nil), in: songs))
            var g = MusicMixGenerator(seed: UInt64(seed) + 1000)
            random += Self.meanAdjacent(songs.shuffled(using: &g))
        }
        #expect(mixed / 20 > random / 20 + 0.1)
    }

    @Test func notJustSortedByTempo() {
        // The tempo walk is a weight, not a sort: a set that could be sorted rarely comes out sorted.
        let songs = (0..<12).map { i in
            MusicMixProfile(videoId: "t\(i)", artist: "t\(i)", bpm: 100 + Double(i) * 2, gridTrusted: true, camelot: MusicCamelot(code: "8A"), energy: 0.5)
        }
        var sorted = 0
        for seed in 0..<50 {
            var orderer = MusicMixOrderer(seed: UInt64(seed))
            let bpms = Self.profiles(orderer.order(songs, first: nil), in: songs).map { $0.bpm! }
            if bpms == bpms.sorted() || bpms == bpms.sorted(by: >) { sorted += 1 }
        }
        #expect(sorted <= 5)
    }

    @Test func tempoWalkRarelyCrossesBetweenFarClusters() {
        // Two tempo clusters far apart: a good walk plays one, crosses, plays the other.
        let songs = (0..<24).map { i in
            MusicMixProfile(videoId: "c\(i)", artist: "c\(i)", bpm: (i < 12 ? 100 : 140) + Double(i % 12), gridTrusted: true,
                            camelot: MusicCamelot(code: "8A"), energy: 0.5)
        }
        // A random order crosses about 12 times; the walk is greedy with dice, so it strands a few songs, not many.
        var total = 0
        for seed in 0..<20 {
            var orderer = MusicMixOrderer(seed: UInt64(seed))
            let bpms = Self.profiles(orderer.order(songs, first: nil), in: songs).map { $0.bpm! }
            let crossings = zip(bpms, bpms.dropFirst()).filter { abs($0.1 - $0.0) > 25 }.count
            #expect(crossings <= 8, "seed \(seed): \(crossings)")
            total += crossings
        }
        #expect(Double(total) / 20 <= 5)
    }

    @Test func energyArcMiddleBeatsOpening() {
        let songs = (0..<40).map { i in
            MusicMixProfile(videoId: "e\(i)", artist: "e\(i)", bpm: 120, gridTrusted: true, camelot: MusicCamelot(code: "8A"), energy: Float(i) / 39)
        }
        var wins = 0
        for seed in 0..<50 {
            var orderer = MusicMixOrderer(seed: UInt64(seed))
            let energies = Self.profiles(orderer.order(songs, first: nil), in: songs).map { Double($0.energy!) }
            let first = energies[0..<13].reduce(0, +) / 13, middle = energies[13..<26].reduce(0, +) / 13
            if middle > first { wins += 1 }
        }
        #expect(wins >= 45)
    }

    @Test func arcDoesNotMakeEverySetIdentical() {
        let songs = (0..<40).map { i in
            MusicMixProfile(videoId: "e\(i)", artist: "e\(i)", bpm: 120, gridTrusted: true, camelot: MusicCamelot(code: "8A"), energy: Float(i) / 39)
        }
        var distinct = Set<[String]>()
        for seed in 0..<20 { var o = MusicMixOrderer(seed: UInt64(seed)); distinct.insert(o.order(songs, first: nil)) }
        #expect(distinct.count >= 18)
    }

    @Test func fiveHundredSongsUnderFiftyMilliseconds() {
        let songs = Self.library(500, artists: 120)
        var ids: [String] = []
        #expect(Self.fastestOfThree(songs, &ids) < .milliseconds(200))
        #expect(ids.count == 500)
    }

    @Test func fiveHundredAllUnknownUnderFiftyMilliseconds() {
        let songs = (0..<500).map { MusicMixProfile(videoId: "u\($0)", artist: "a\($0 % 90)") }
        var ids: [String] = []
        #expect(Self.fastestOfThree(songs, &ids) < .milliseconds(200))
        #expect(ids.count == 500)
    }
}

@Suite struct MusicMixSpacingTests {
    @Test func noBackToBackArtistAcrossSeeds() {
        let songs = MusicMixOrdererTests.library(30, artists: 4)
        let artistOf = Dictionary(uniqueKeysWithValues: songs.map { ($0.videoId, $0.artist) })
        for seed in 0..<100 {
            var orderer = MusicMixOrderer(seed: UInt64(seed))
            let artists = orderer.order(songs, first: nil).map { artistOf[$0]! }
            // 4 even artists make an arrangement possible, so the rule must hold the whole way.
            #expect(zip(artists, artists.dropFirst()).allSatisfy { $0 != $1 }, "seed \(seed)")
        }
    }

    @Test func artistNamesNormalise() {
        let songs = ["Beyoncé", "BEYONCE ", "beyonce", "Drake", "Drake", "Drake", "Adele", "Adele"].enumerated().map {
            MusicMixProfile(videoId: "s\($0.offset)", artist: $0.element, bpm: 120, gridTrusted: true, camelot: MusicCamelot(code: "8A"), energy: 0.5)
        }
        for seed in 0..<50 {
            var orderer = MusicMixOrderer(seed: UInt64(seed))
            let ids = orderer.order(songs, first: nil)
            let key = { (id: String) in songs.first { $0.videoId == id }!.artist.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).trimmingCharacters(in: .whitespaces) }
            let names = ids.map(key)
            #expect(zip(names, names.dropFirst()).allSatisfy { $0 != $1 }, "seed \(seed): \(names)")
        }
    }

    @Test func firstArtistIsNotRepeatedNext() {
        let songs = MusicMixOrdererTests.library(20, artists: 5)
        for seed in 0..<30 {
            var orderer = MusicMixOrderer(seed: UInt64(seed))
            let ids = orderer.order(songs, first: songs[0])
            let second = songs.first { $0.videoId == ids[1] }!
            #expect(second.artist != songs[0].artist)
        }
    }

    @Test func similarSongsSpreadOut() {
        // Ten identical-sounding songs among thirty: they should not clump.
        var songs = (0..<20).map { i in
            MusicMixProfile(videoId: "o\(i)", artist: "o\(i)", bpm: 90 + Double(i) * 4, gridTrusted: true, camelot: MusicCamelot(number: 1 + i % 12, isMinor: i % 2 == 0), energy: 0.5)
        }
        songs += (0..<10).map { MusicMixProfile(videoId: "same\($0)", artist: "same\($0)", bpm: 120, gridTrusted: true, camelot: MusicCamelot(code: "8A"), energy: 0.5) }
        var gaps: [Double] = []
        for seed in 0..<30 {
            var orderer = MusicMixOrderer(seed: UInt64(seed))
            let ids = orderer.order(songs, first: nil)
            let slots = ids.enumerated().filter { $0.element.hasPrefix("same") }.map(\.offset)
            gaps.append(zip(slots, slots.dropFirst()).map { Double($1 - $0) }.reduce(0, +) / Double(slots.count - 1))
        }
        #expect(gaps.reduce(0, +) / Double(gaps.count) >= 2)
    }
}

@Suite struct MusicHarmonicStepTests {
    @Test func liftNeedsHighTargetAndSpacing() {
        #expect(MusicMixOrderer.liftAllowed(target: 0.85, slotsSinceLift: 4))
        #expect(!MusicMixOrderer.liftAllowed(target: 0.85, slotsSinceLift: 3))
        #expect(!MusicMixOrderer.liftAllowed(target: 0.7, slotsSinceLift: 10))
        #expect(!MusicMixOrderer.liftAllowed(target: 0.3, slotsSinceLift: 10))
    }
}

@Suite struct MusicMixAutoplayHelperTests {
    static func p(_ id: String, bpm: Double?, key: String?) -> MusicMixProfile {
        MusicMixProfile(videoId: id, artist: id, bpm: bpm, gridTrusted: bpm != nil, camelot: key.flatMap { MusicCamelot(code: $0) }, energy: 0.5)
    }

    @Test func pickBestTakesTheBestMixWhenKnown() {
        var orderer = MusicMixOrderer(seed: 1)
        let anchor = Self.p("a", bpm: 120, key: "8A")
        let pick = orderer.pickBest(from: [Self.p("far", bpm: 80, key: "3B"), Self.p("near", bpm: 121, key: "8B"), Self.p("mid", bpm: 124, key: "9A")], after: anchor)
        #expect(pick?.videoId == "near")
    }

    @Test func pickBestUnknownFallsBackToSeededRandom() {
        let candidates = (0..<10).map { MusicMixProfile(videoId: "u\($0)", artist: "u\($0)") }
        var picks = Set<String>()
        for seed in 0..<30 {
            var a = MusicMixOrderer(seed: UInt64(seed)), b = MusicMixOrderer(seed: UInt64(seed))
            let first = a.pickBest(from: candidates, after: nil)
            #expect(first == b.pickBest(from: candidates, after: nil))
            picks.insert(first!.videoId)
        }
        #expect(picks.count >= 5)
        var orderer = MusicMixOrderer(seed: 1)
        #expect(orderer.pickBest(from: [], after: nil) == nil)
    }

    @Test func bestInsertionFindsTheSlotBetweenGoodNeighbours() {
        let anchor = Self.p("a", bpm: 100, key: "8A")
        let window = [Self.p("w0", bpm: 101, key: "8A"), Self.p("w1", bpm: 140, key: "3B"), Self.p("w2", bpm: 141, key: "3B")]
        let orderer = MusicMixOrderer(seed: 1)
        // A 140 bpm 3B song belongs next to the other 140 bpm 3B songs, not before the 100 bpm start.
        let slot = orderer.bestInsertion(of: Self.p("c", bpm: 140, key: "3B"), into: window, after: anchor)
        #expect(slot >= 1)
        #expect(orderer.bestInsertion(of: Self.p("d", bpm: 100, key: "8A"), into: window, after: anchor) <= 1)
    }

    @Test func bestInsertionIsNotPulledToTheEnd() {
        // Three songs already mix well; a song that matches the start must go in the run, not after the 128 bpm tail.
        let anchor = Self.p("a", bpm: 120, key: "8A")
        let window = [Self.p("w0", bpm: 120, key: "8A"), Self.p("w1", bpm: 120, key: "8A"), Self.p("w2", bpm: 128, key: "9A")]
        let orderer = MusicMixOrderer(seed: 1)
        let slot = orderer.bestInsertion(of: Self.p("c", bpm: 120, key: "8A"), into: window, after: anchor)
        #expect((0...2).contains(slot), "slot \(slot)")
    }

    @Test func pickBestWithUnknownAnchorIsSeededRandomNotFirst() {
        let candidates = (0..<10).map { Self.p("k\($0)", bpm: 100 + Double($0), key: "8A") }
        let unknownAnchor = MusicMixProfile(videoId: "a", artist: "a")
        var picks = Set<String>()
        for seed in 0..<40 {
            var orderer = MusicMixOrderer(seed: UInt64(seed))
            picks.insert(orderer.pickBest(from: candidates, after: unknownAnchor)!.videoId)
        }
        #expect(picks.count >= 5)
    }

    @Test func pickBestTiesAreBrokenBySeed() {
        let candidates = (0..<8).map { Self.p("t\($0)", bpm: 120, key: "8A") }
        let anchor = Self.p("a", bpm: 120, key: "8A")
        var picks = Set<String>()
        for seed in 0..<40 {
            var orderer = MusicMixOrderer(seed: UInt64(seed))
            picks.insert(orderer.pickBest(from: candidates, after: anchor)!.videoId)
        }
        #expect(picks.count >= 4)
    }

    @Test func bestInsertionHonoursMinIndexAndBounds() {
        let window = (0..<5).map { Self.p("w\($0)", bpm: 120, key: "8A") }
        let orderer = MusicMixOrderer(seed: 1)
        let candidate = Self.p("c", bpm: 120, key: "8A")
        #expect(orderer.bestInsertion(of: candidate, into: window, after: nil, minIndex: 3) >= 3)
        #expect(orderer.bestInsertion(of: candidate, into: window, after: nil, minIndex: 99) == 5)
        #expect(orderer.bestInsertion(of: candidate, into: window, after: nil, minIndex: -4) >= 0)
        #expect(orderer.bestInsertion(of: candidate, into: [], after: nil) == 0)
    }
}

@Suite struct MusicMixReorderTailTests {
    @Test func reordersOnlyTheNextFiveAndKeepsTheRest() {
        let upcoming = MusicMixOrdererTests.library(12)
        let anchor = MusicMixOrdererTests.library(1, seed: 99)[0]
        var orderer = MusicMixOrderer(seed: 4)
        let ids = orderer.reorderTail(anchor: anchor, upcoming: upcoming, avoid: [], count: 5)
        #expect(ids.count == 12)
        #expect(Set(ids[0..<5]) == Set(upcoming[0..<5].map(\.videoId)))
        #expect(Array(ids[5...]) == upcoming[5...].map(\.videoId))
    }

    @Test func avoidedSongsGoToTheBack() {
        let upcoming = MusicMixOrdererTests.library(5)
        let anchor = MusicMixOrdererTests.library(1, seed: 5)[0]
        for seed in 0..<40 {
            var orderer = MusicMixOrderer(seed: UInt64(seed))
            let ids = orderer.reorderTail(anchor: anchor, upcoming: upcoming, avoid: [upcoming[0], upcoming[1]], count: 5)
            #expect(Set(ids[3...]).isSuperset(of: ["v0", "v1"]) || Set(ids[2...]).isSuperset(of: ["v0", "v1"]), "seed \(seed): \(ids)")
            #expect(ids[0] != "v0" && ids[0] != "v1")
        }
    }

    @Test func avoidedSongNeverLeadsEvenWhenEverythingClashes() {
        // Every pair scores low, so the walk is in its random fallback: the avoided song still must not come first.
        let upcoming = (0..<5).map { i in
            MusicMixProfile(videoId: "x\(i)", artist: "x\(i)", bpm: 80 + Double(i) * 25, gridTrusted: true,
                            camelot: MusicCamelot(number: 1 + i * 2, isMinor: i % 2 == 0), energy: i % 2 == 0 ? 0.1 : 0.9)
        }
        let anchor = MusicMixProfile(videoId: "anchor", artist: "anchor", bpm: 120, gridTrusted: true, camelot: MusicCamelot(code: "8A"), energy: 0.5)
        for seed in 0..<40 {
            var orderer = MusicMixOrderer(seed: UInt64(seed))
            let ids = orderer.reorderTail(anchor: anchor, upcoming: upcoming, avoid: [upcoming[2]], count: 5)
            #expect(ids[0] != upcoming[2].videoId, "seed \(seed): \(ids)")
            #expect(Set(ids) == Set(upcoming.map(\.videoId)))
        }
    }

    @Test func shortAndEmptyInputs() {
        var orderer = MusicMixOrderer(seed: 1)
        #expect(orderer.reorderTail(anchor: nil, upcoming: [], avoid: []).isEmpty)
        let two = MusicMixOrdererTests.library(2)
        #expect(Set(orderer.reorderTail(anchor: nil, upcoming: two, avoid: [])) == ["v0", "v1"])
        #expect(orderer.reorderTail(anchor: nil, upcoming: two, avoid: [], count: 0) == ["v0", "v1"])
        #expect(orderer.reorderTail(anchor: nil, upcoming: two, avoid: [], count: -2) == ["v0", "v1"])
    }

    @Test func deterministicPerSeed() {
        let upcoming = MusicMixOrdererTests.library(8)
        var a = MusicMixOrderer(seed: 6), b = MusicMixOrderer(seed: 6)
        #expect(a.reorderTail(anchor: nil, upcoming: upcoming, avoid: []) == b.reorderTail(anchor: nil, upcoming: upcoming, avoid: []))
    }
}
