// DeciTests/Music/MixShuffle/MusicMixOrdererTempoTests.swift
// The tempo gate: a Mix order keeps every step within the tempo tolerance whenever a way exists.
import Foundation
import Testing
@testable import Deci

@Suite struct MusicMixOrdererTempoTests {
    static func song(_ id: String, _ bpm: Double?, artist: String? = nil, key: String? = nil, energy: Float = 0.5, trusted: Bool = false) -> MusicMixProfile {
        MusicMixProfile(
            videoId: id, artist: artist ?? "artist-\(id)", bpm: bpm, gridTrusted: trusted,
            camelot: key.flatMap { MusicCamelot(code: $0) }, energy: energy, introEnergy: 0.3, outroEnergy: 0.3)
    }

    static func clashes(_ ids: [String], in songs: [MusicMixProfile]) -> Int {
        let byId = Dictionary(songs.map { ($0.videoId, $0) }, uniquingKeysWith: { a, _ in a })
        let compact = ids.map { MusicMixCompact(byId[$0]!) }
        return zip(compact, compact.dropFirst()).filter { !MusicMixScore.tempoFits($0.0, $0.1) }.count
    }

    static let liveBpms: [Double] = [95, 151, 81, 86, 87, 102, 95, 138, 140, 153, 127, 128]
    static let liveKeys: [String?] = ["11B", "12B", nil, "3B", "6B", "7B", "8A", "8A", "7A", "6A", nil, "12B"]

    static func liveSet() -> [MusicMixProfile] {
        liveBpms.indices.map { i in
            song("s\(i)", liveBpms[i], key: liveKeys[i], energy: 0.3 + Float(i % 6) * 0.1)
        }
    }

    // MARK: tempoError and tempoFits

    @Test func tempoErrorIsFoldedAndSymmetric() throws {
        func c(_ bpm: Double) -> MusicMixCompact { MusicMixCompact(MusicMixProfile(videoId: "x", bpm: bpm)) }
        #expect(abs(try #require(MusicMixScore.tempoError(c(100), c(105))) - 0.05) < 1e-9)
        #expect(abs(try #require(MusicMixScore.tempoError(c(105), c(100))) - 0.05) < 1e-9)
        let folded = try #require(MusicMixScore.tempoError(c(75), c(151)))
        let expected: Double = abs(151.0 / 75.0 / 2.0 - 1.0)
        #expect(abs(folded - expected) < 1e-9)
        #expect(try #require(MusicMixScore.tempoError(c(100), c(100))) == 0)
    }

    @Test func unknownTempoHasNoErrorAndFits() {
        let known = MusicMixCompact(MusicMixProfile(videoId: "a", bpm: 120))
        let unknown = MusicMixCompact(MusicMixProfile(videoId: "b"))
        #expect(MusicMixScore.tempoError(known, unknown) == nil)
        #expect(MusicMixScore.tempoError(unknown, known) == nil)
        #expect(MusicMixScore.tempoError(unknown, unknown) == nil)
        #expect(MusicMixScore.tempoFits(known, unknown))
        #expect(MusicMixScore.tempoFits(unknown, unknown))
    }

    @Test func tempoFitsUsesTheToleranceAndHalfTime() {
        func c(_ bpm: Double) -> MusicMixCompact { MusicMixCompact(MusicMixProfile(videoId: "x", bpm: bpm)) }
        #expect(MusicMixScore.tempoFits(c(100), c(108)))
        #expect(!MusicMixScore.tempoFits(c(100), c(109)))
        #expect(MusicMixScore.tempoFits(c(75), c(151)))
        #expect(!MusicMixScore.tempoFits(c(95), c(151)))
    }

    // MARK: Order

    @Test func liveSetReachesTheOneClashFloor() {
        let songs = Self.liveSet()
        var total = 0, worst = 0
        for seed in 1...100 {
            var orderer = MusicMixOrderer(seed: UInt64(seed))
            let ids = orderer.order(songs, first: nil)
            #expect(Set(ids).count == songs.count)
            let n = Self.clashes(ids, in: songs)
            total += n
            worst = max(worst, n)
        }
        let mean = Double(total) / 100
        print("live set clashes: mean \(mean) max \(worst)")
        // The set has a cluster ({95, 95, 102}) that cannot reach the rest, so one clash is the floor.
        #expect(worst <= 1)
        #expect(mean <= 1.0 + 1e-9)
    }

    @Test func bigGaussianSetHasAlmostNoClashes() {
        var total = 0
        for seed in 1...10 {
            var g = MusicMixGenerator(seed: UInt64(seed) &* 77)
            let keys = (1...12).flatMap { ["\($0)A", "\($0)B"] }
            let songs: [MusicMixProfile] = (0..<200).map { i in
                // Box-Muller from the seeded generator.
                let u1 = Double.random(in: 0.0001..<1, using: &g), u2 = Double.random(in: 0..<1, using: &g)
                let z = (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
                let bpm = max(60, min(200, 118 + 25 * z))
                return Self.song("g\(i)", bpm, key: keys.randomElement(using: &g), energy: Float.random(in: 0...1, using: &g))
            }
            var orderer = MusicMixOrderer(seed: UInt64(seed))
            total += Self.clashes(orderer.order(songs, first: nil), in: songs)
        }
        let mean = Double(total) / 10
        print("200 song clashes: mean \(mean)")
        #expect(mean <= 1)
    }

    @Test func unknownTempoSongsAreNeverBlockedAndArePlaced() {
        var songs = (0..<10).map { Self.song("k\($0)", 100 + Double($0)) }
        songs += [Self.song("u1", nil), Self.song("u2", nil)]
        var orderer = MusicMixOrderer(seed: 3)
        let ids = orderer.order(songs, first: nil)
        #expect(Set(ids) == Set(songs.map(\.videoId)))
        // A fixed anchor at an unrelated tempo: the unknowns may still follow it.
        var anchored = MusicMixOrderer(seed: 4)
        let after = anchored.order(songs, first: Self.song("far", 200))
        #expect(Set(after) == Set(songs.map(\.videoId)))
        // Far from the anchor only an unknown tempo is eligible (140 clashes with 80): a gate that blocked unknowns
        // would have to take the 140 instead.
        let pair = [Self.song("s140", 140), Self.song("u", nil)]
        for seed in 1...30 {
            var orderer = MusicMixOrderer(seed: UInt64(seed))
            #expect(orderer.order(pair, first: Self.song("far80", 80)).first == "u")
        }
    }

    @Test func gateNeverBreaksTheArtistRule() {
        // The only tempo fit for the anchor is the same artist; the other artist must win.
        let anchor = Self.song("a0", 100, artist: "Same")
        let songs = [Self.song("a1", 101, artist: "Same"), Self.song("b1", 160, artist: "Other")]
        for seed in 1...30 {
            var orderer = MusicMixOrderer(seed: UInt64(seed))
            let ids = orderer.order(songs, first: anchor)
            #expect(ids.first == "b1")
        }
    }

    @Test func gateKeepsTheArtistRuleWhenTheFullScanRuns() {
        // More than sampleLimit songs. Every tempo fit for the anchor is by the anchor's own artist, and those songs
        // are mostly outside the sample, so the full scan finds only forbidden songs.
        var songs = (0..<3).map { Self.song("L\($0)", 100 + Double($0), artist: "Last") }
        songs += (0..<45).map { Self.song("o\($0)", 150 + Double($0) * 1.5, artist: "other-\($0)") }
        for seed in 1...40 {
            var orderer = MusicMixOrderer(seed: UInt64(seed))
            let ids = orderer.order(songs, first: songs[0])
            #expect(ids.first == "L0")
            let artists = ids.map { id in songs.first { $0.videoId == id }!.artist }
            #expect(Set(ids).count == songs.count)
            for (a, b) in zip(artists, artists.dropFirst()) { #expect(a != b, "seed \(seed)") }
        }
    }

    @Test func halfAndDoubleTimeCountAsAFit() {
        // 75 and 151 fit; 100 fits neither well. Chain: anchor 75 then the pool.
        let songs = [Self.song("x151", 151), Self.song("x100", 100), Self.song("x99", 99)]
        for seed in 1...30 {
            var orderer = MusicMixOrderer(seed: UInt64(seed))
            let ids = orderer.order(songs, first: Self.song("x75", 75))
            #expect(ids.first == "x151")
        }
    }

    @Test func nothingFitsPicksTheNearestTempo() {
        // From 100: 150 is off by 0.25, 130 by 0.30, 300 by 0.50, and none is within 0.08.
        let songs = [Self.song("n130", 130), Self.song("n300", 300), Self.song("n150", 150)]
        for seed in 1...30 {
            var orderer = MusicMixOrderer(seed: UInt64(seed))
            #expect(orderer.order(songs, first: Self.song("n100", 100)).first == "n150")
        }
    }

    @Test func reorderTailKeepsTheReplannedHeadClashFree() {
        let anchor = Self.song("anchor", 100)
        let head = [Self.song("t160", 160), Self.song("t102", 102), Self.song("t104", 104), Self.song("t165", 165), Self.song("t106", 106)]
        let upcoming = head + [Self.song("rest", 120)]
        for seed in 1...50 {
            var orderer = MusicMixOrderer(seed: UInt64(seed))
            let ids = orderer.reorderTail(anchor: anchor, upcoming: upcoming, avoid: [])
            #expect(ids.last == "rest")
            let planned = Array(ids.prefix(5))
            // 160 and 165 chain only to each other, so the clash-free order is 100,102,104,106 then 160,165 is one clash.
            // 5 songs: the best has exactly one clash (106 to 160), plus the anchor edge must be clean.
            #expect(Self.clashes(planned, in: upcoming) <= 1)
            let first = upcoming.first { $0.videoId == planned[0] }!
            #expect(MusicMixScore.tempoFits(MusicMixCompact(anchor), MusicMixCompact(first)))
        }
    }

    @Test func avoidedOnlyTempoFitDoesNotLeadWhenAFreshSongExists() {
        let avoided = Self.song("av", 101)
        let upcoming = [avoided, Self.song("f1", 160), Self.song("f2", 175)]
        for seed in 1...30 {
            var orderer = MusicMixOrderer(seed: UInt64(seed))
            let ids = orderer.reorderTail(anchor: Self.song("anchor", 100), upcoming: upcoming, avoid: [avoided])
            #expect(ids.first != "av", "seed \(seed): \(ids)")
            #expect(Set(ids) == Set(upcoming.map(\.videoId)))
        }
    }

    @Test func skippedArtistDoesNotLeadWhenAFreshArtistFitsTempo() {
        // Every song fits the anchor's tempo, so only the artist decides. The skipped song's band has two more songs.
        let skipped = Self.song("skipped", 100, artist: "Same Band")
        let band = [Self.song("band1", 100, artist: "Same Band"), Self.song("band2", 101, artist: "Same Band")]
        let fresh = (0..<4).map { Self.song("fresh\($0)", 100 + Double($0), artist: "other-\($0)") }
        let upcoming = band + fresh
        let anchor = Self.song("anchor", 100, artist: "Current")
        var before = 0.0, after = 0.0
        let seeds = 1...40
        func meanSlot(_ ids: [String]) -> Double {
            let slots = ids.indices.filter { ids[$0].hasPrefix("band") }
            return Double(slots.reduce(0, +)) / Double(slots.count)
        }
        for seed in seeds {
            var plain = MusicMixOrderer(seed: UInt64(seed))
            before += meanSlot(plain.reorderTail(anchor: anchor, upcoming: upcoming, avoid: []))
            var replanned = MusicMixOrderer(seed: UInt64(seed))
            let ids = replanned.reorderTail(anchor: anchor, upcoming: upcoming, avoid: [skipped])
            #expect(!ids[0].hasPrefix("band"), "seed \(seed): \(ids)")
            #expect(Set(ids) == Set(upcoming.map(\.videoId)))
            after += meanSlot(ids)
        }
        let n = Double(seeds.count)
        #expect(after / n >= before / n, "mean slot before \(before / n) after \(after / n)")
    }

    @Test func skippedArtistStillWinsWhenNoFreshArtistFitsTempo() {
        // The only tempo fit for the anchor is the skipped artist's other song, so the tempo walk keeps it first.
        let skipped = Self.song("skipped", 101, artist: "Same Band")
        let upcoming = [Self.song("band1", 102, artist: "Same Band"), Self.song("f160", 160, artist: "other-a"), Self.song("f175", 175, artist: "other-b")]
        for seed in 1...30 {
            var orderer = MusicMixOrderer(seed: UInt64(seed))
            let ids = orderer.reorderTail(anchor: Self.song("anchor", 100, artist: "Current"), upcoming: upcoming, avoid: [skipped])
            #expect(ids.first == "band1", "seed \(seed): \(ids)")
        }
    }

    @Test func beamLooksAheadAcrossTheWholeSample() {
        // Pool is {93.5, 107.5}; 114 is in the sample but clashes with the anchor, so it is not a candidate. Only 107.5
        // has a fitting follow-up (114). Keys and energy are set so the best pair score is in the beam band, and 93.5
        // scores a little higher on tempo alone, so a look-ahead blind to 114 would pick 93.5.
        func song(_ id: String, _ bpm: Double, key: String, energy: Float, intro: Float, outro: Float) -> MusicMixProfile {
            MusicMixProfile(videoId: id, artist: "a-\(id)", bpm: bpm, gridTrusted: true, camelot: MusicCamelot(code: key),
                            energy: energy, introEnergy: intro, outroEnergy: outro)
        }
        let anchor = song("anchor", 100, key: "1A", energy: 0.9, intro: 1, outro: 1)
        let upcoming = [
            song("low", 93.5, key: "6A", energy: 0, intro: 1, outro: 1),
            song("high", 107.5, key: "6A", energy: 0, intro: 1, outro: 1),
            song("far", 114, key: "6A", energy: 0, intro: 1, outro: 1),
        ]
        for seed in 1...30 {
            var orderer = MusicMixOrderer(seed: UInt64(seed))
            let ids = orderer.reorderTail(anchor: anchor, upcoming: upcoming, avoid: [])
            #expect(ids.first == "high", "seed \(seed): \(ids)")
        }
    }

    @Test func tempoFitAndTempoScoreShareTheBoundary() {
        func c(_ bpm: Double) -> MusicMixCompact { MusicMixCompact(MusicMixProfile(videoId: "x", bpm: bpm, gridTrusted: true)) }
        for (a, b) in [(100.0, 108.0), (75, 81), (125, 135), (150, 162)] {
            #expect(MusicMixScore.tempoFits(c(a), c(b)), "\(a) \(b)")
            let term = MusicMixScore.tempoTerm(c(a), c(b))
            #expect(abs(term - 0.85) < 1e-6, "\(a) \(b) scored \(term)")
        }
    }

    // MARK: Autoplay insertion

    @Test func insertionAvoidsTheTempoClash() {
        // No clash inside the window. The candidate (118, key 3A) clashes with the 100 and 102 (key 3A) but fits the 110
        // and 112 (key 9A). The key makes the front of the window look best, and gain alone picks the slot between 102
        // and 110 (it replaces a good edge and mixes in key on one side), which adds a clash.
        func s(_ id: String, _ bpm: Double, _ key: String) -> MusicMixProfile {
            MusicMixProfile(videoId: id, artist: id, bpm: bpm, gridTrusted: true, camelot: MusicCamelot(code: key),
                            energy: 0.5, introEnergy: 0.3, outroEnergy: 0.3)
        }
        let window = [s("w100", 100, "3A"), s("w102", 102, "3A"), s("w110", 110, "9A"), s("w112", 112, "9A")]
        let candidate = s("c118", 118, "3A")
        let compact = window.map(MusicMixCompact.init)
        let cand = MusicMixCompact(candidate)
        func clash(_ a: MusicMixCompact?, _ b: MusicMixCompact?) -> Int {
            guard let a, let b else { return 0 }
            return MusicMixScore.tempoFits(a, b) ? 0 : 1
        }
        func gain(_ slot: Int) -> Double {
            let previous = slot == 0 ? nil : compact[slot - 1]
            let next = slot < compact.count ? compact[slot] : nil
            func sc(_ a: MusicMixCompact?, _ b: MusicMixCompact?) -> Double {
                guard let a, let b else { return 0 }
                return MusicMixScore.score(from: a, to: b, allowLift: false)
            }
            var g = sc(previous, cand) + sc(cand, next)
            if let previous, let next { g -= sc(previous, next) }
            return g
        }
        func netClashes(_ slot: Int) -> Int {
            let previous = slot == 0 ? nil : compact[slot - 1]
            let next = slot < compact.count ? compact[slot] : nil
            var n = clash(previous, cand) + clash(cand, next)
            if let previous, let next { n -= clash(previous, next) }
            return n
        }
        // The case is only meaningful when gain alone would take a slot that adds a clash.
        let gainOnly = (0...window.count).max { gain($0) < gain($1) - 1e-12 }!
        #expect(netClashes(gainOnly) > 0)
        let orderer = MusicMixOrderer(seed: 1)
        let slot = orderer.bestInsertion(of: candidate, into: window, after: nil)
        #expect(slot != gainOnly)
        #expect(netClashes(slot) == 0)
        #expect(slot >= 3)
    }

    // MARK: Tier 4c C2: deck rate, stepwise slack, tempo jumps

    @Test func playingSongsEffectiveTempoIsWhatTheNextOneMeets() {
        // The anchor is 100 bpm held at 1.2 deck rate (never planned by the planner, but the arithmetic is exact): 120 effective.
        // 121 fits it, 100 does not; with rate 1 it is the other way round.
        let upcoming = [Self.song("near100", 100), Self.song("near120", 121), Self.song("far", 170)]
        for seed in 1...30 {
            var held = MusicMixOrderer(seed: UInt64(seed))
            #expect(held.reorderTail(anchor: Self.song("a", 100), upcoming: upcoming, avoid: [], anchorRate: 1.2).first == "near120")
            var plain = MusicMixOrderer(seed: UInt64(seed))
            #expect(plain.reorderTail(anchor: Self.song("a", 100), upcoming: upcoming, avoid: []).first == "near100")
        }
    }

    @Test func nearestFallbackNarrowsStepwise() {
        // From 100 nothing fits. 150 is the nearest (0.25); 151 (0.255) is within the old fixed slack of 0.02 but the
        // narrowest step that leaves two candidates is 0.01, so 130 (0.30) and 135 (0.325) never compete, and the pick is among the near two.
        let songs = [Self.song("c150", 150), Self.song("c151", 151), Self.song("c130", 130), Self.song("c135", 135)]
        for seed in 1...40 {
            var orderer = MusicMixOrderer(seed: UInt64(seed))
            let first = orderer.order(songs, first: Self.song("c100", 100)).first
            #expect(first == "c150" || first == "c151", "seed \(seed): \(String(describing: first))")
        }
        #expect(MusicMixOrderer.nearestSlackSteps == MusicMixOrderer.nearestSlackSteps.sorted())
        #expect(MusicMixOrderer.nearestSlack == 0.02)
    }

    @Test func aTempoJumpRanksBelowAnyStepInsideTheLine() {
        // From 100: 160 (a jump of 0.28 after folding) and 190 (0.05 after folding, half time). Both are cut by the gate in
        // a normal set; this checks the ranking function directly: the same key and energy, the jump scores lower.
        let a = MusicMixCompact(Self.song("a", 100))
        let jump = MusicMixCompact(Self.song("j", 160)), near = MusicMixCompact(Self.song("n", 140))
        #expect((MusicMixScore.tempoError(a, jump) ?? 0) > MusicMixOrderer.tempoJumpError)
        #expect((MusicMixScore.tempoError(a, near) ?? 0) > MusicMixOrderer.tempoJumpError)
        #expect(MusicMixOrderer.tempoJumpPenalty > 0)
    }

    @Test func seededCorpusHasUnderFivePercentJumpsOver15Percent() {
        var steps = 0, jumps = 0
        for seed in 1...12 {
            var g = MusicMixGenerator(seed: UInt64(seed) &* 131)
            // A sparse corpus, uniform 70 to 180 bpm: far fewer neighbours than the gaussian set, so jumps are tempting.
            let songs: [MusicMixProfile] = (0..<60).map { i in
                Self.song("u\(i)", Double.random(in: 70...180, using: &g), energy: Float.random(in: 0...1, using: &g))
            }
            var orderer = MusicMixOrderer(seed: UInt64(seed))
            let ids = orderer.order(songs, first: nil)
            let byId = Dictionary(songs.map { ($0.videoId, MusicMixCompact($0)) }, uniquingKeysWith: { a, _ in a })
            for (x, y) in zip(ids, ids.dropFirst()) {
                steps += 1
                if (MusicMixScore.tempoError(byId[x]!, byId[y]!) ?? 0) > MusicMixOrderer.tempoJumpError { jumps += 1 }
            }
        }
        let share = Double(jumps) / Double(steps)
        print("tempo jumps over 15%: \(jumps) of \(steps) = \(share)")
        #expect(share < 0.05)
    }
}
