// DeciTests/Music/MixShuffle/MusicMixScoreTests.swift
import Foundation
import Testing
@testable import Deci

@Suite struct MusicCamelotTests {
    @Test func parsesCodes() {
        #expect(MusicCamelot(code: "8A") == MusicCamelot(number: 8, isMinor: true))
        #expect(MusicCamelot(code: "12b") == MusicCamelot(number: 12, isMinor: false))
        #expect(MusicCamelot(code: "13A") == nil)
        #expect(MusicCamelot(code: "0B") == nil)
        #expect(MusicCamelot(code: "") == nil)
        #expect(MusicCamelot(code: "8") == nil)
        #expect(MusicCamelot(code: "8A")?.code == "8A")
    }

    @Test func relativeKeyIsDistanceZero() {
        let a = MusicCamelot(number: 8, isMinor: true), b = MusicCamelot(number: 8, isMinor: false)
        #expect(a.distance(to: b) == 0)
        #expect(b.distance(to: a) == 0)
    }

    @Test func neighboursAndWraparound() {
        let eight = MusicCamelot(number: 8, isMinor: true)
        #expect(eight.distance(to: MusicCamelot(number: 9, isMinor: true)) == 1)
        #expect(eight.distance(to: MusicCamelot(number: 7, isMinor: true)) == 1)
        #expect(eight.distance(to: MusicCamelot(number: 10, isMinor: true)) == 2)
        #expect(MusicCamelot(number: 12, isMinor: false).distance(to: MusicCamelot(number: 1, isMinor: false)) == 1)
        #expect(MusicCamelot(number: 1, isMinor: true).distance(to: MusicCamelot(number: 11, isMinor: true)) == 2)
        #expect(MusicCamelot(number: 1, isMinor: true).distance(to: MusicCamelot(number: 7, isMinor: true)) == 6)
    }

    @Test func crossModeNonRelativeIsNil() {
        #expect(MusicCamelot(number: 8, isMinor: true).distance(to: MusicCamelot(number: 9, isMinor: false)) == nil)
    }

    @Test func numbersWrapIntoRange() {
        #expect(MusicCamelot(number: 13, isMinor: true).number == 1)
        #expect(MusicCamelot(number: 0, isMinor: true).number == 12)
        #expect(MusicCamelot(number: -11, isMinor: true).number == 1)
    }

    @Test func signedStepWraps() {
        #expect(MusicCamelot(number: 11, isMinor: true).step(to: MusicCamelot(number: 1, isMinor: true)) == 2)
        #expect(MusicCamelot(number: 1, isMinor: true).step(to: MusicCamelot(number: 11, isMinor: true)) == -2)
    }
}

@Suite struct MusicMixScoreTests {
    static func song(_ id: String, bpm: Double? = 120, key: String? = "8A", energy: Float? = 0.5, trusted: Bool = true) -> MusicMixProfile {
        MusicMixProfile(videoId: id, artist: id, bpm: bpm, gridTrusted: trusted, camelot: key.flatMap { MusicCamelot(code: $0) }, energy: energy)
    }

    @Test func keyTermSteps() {
        func key(_ a: String, _ b: String, lift: Bool = false) -> Double {
            MusicMixScore.keyTerm(MusicMixCompact(Self.song("a", key: a)), MusicMixCompact(Self.song("b", key: b)), allowLift: lift).value
        }
        #expect(key("8A", "8A") == 1)
        #expect(key("8A", "8B") == 1)
        #expect(key("8A", "9A") == MusicMixScore.keyStep)
        #expect(key("12A", "1A") == MusicMixScore.keyStep)
        #expect(key("8A", "10A") == MusicMixScore.keyClash)
        #expect(key("8A", "10A", lift: true) == MusicMixScore.keyLift)
        #expect(key("10A", "8A", lift: true) == MusicMixScore.keyClash)
        #expect(key("8A", "3B") == MusicMixScore.keyClash)
    }

    @Test func liftOnlyWhenAllowed() {
        let a = Self.song("a", key: "8A"), b = Self.song("b", key: "10A")
        #expect(MusicMixScore.score(from: a, to: b, allowLift: true) > MusicMixScore.score(from: a, to: b, allowLift: false))
    }

    @Test func sameKeySameTempoBeatsClash() {
        let a = Self.song("a")
        let good = Self.song("g", bpm: 121, key: "8A")
        let bad = Self.song("b", bpm: 90, key: "3B")
        #expect(MusicMixScore.score(from: a, to: good, allowLift: false) > MusicMixScore.score(from: a, to: bad, allowLift: false) + 0.2)
    }

    @Test func unknownsAreNeutralAndNeverNaN() {
        let unknown = MusicMixProfile(videoId: "u", artist: "")
        let known = Self.song("k")
        for (a, b) in [(unknown, unknown), (unknown, known), (known, unknown), (known, known)] {
            for lift in [false, true] {
                let value = MusicMixScore.score(from: a, to: b, allowLift: lift)
                #expect(value.isFinite)
                #expect((0.0...1.0).contains(value))
            }
        }
        #expect(MusicMixScore.score(from: unknown, to: unknown, allowLift: false) > 0.2)
    }

    @Test func garbageNumbersStayInRange() {
        let weird = MusicMixProfile(videoId: "w", bpm: .nan, camelot: nil, energy: .infinity, introEnergy: -5, outroEnergy: 9)
        let other = MusicMixProfile(videoId: "o", bpm: -3, energy: .nan)
        for (a, b) in [(weird, other), (other, weird), (weird, weird)] {
            let value = MusicMixScore.score(from: a, to: b, allowLift: true)
            #expect(value.isFinite && (0.0...1.0).contains(value))
        }
    }

    @Test func tempoSweetSpotBeatsEdgeBeatsClash() {
        func tempo(_ b: Double) -> Double {
            MusicMixScore.tempoTerm(MusicMixCompact(Self.song("a", bpm: 100)), MusicMixCompact(Self.song("b", bpm: b)))
        }
        #expect(tempo(102) > tempo(107))
        #expect(tempo(107) > tempo(115))
        #expect(tempo(115) > tempo(140))
        // Heavy penalty past 8 percent.
        #expect(tempo(107) - tempo(110) > 0.2)
    }

    @Test func halfAndDoubleTimeCountAsAMatch() {
        func tempo(_ b: Double) -> Double {
            MusicMixScore.tempoTerm(MusicMixCompact(Self.song("a", bpm: 70)), MusicMixCompact(Self.song("b", bpm: b)))
        }
        #expect(tempo(140) > 0.8)
        #expect(tempo(35) > 0.8)
        #expect(tempo(140) <= tempo(70))
    }

    @Test func untrustedGridPullsTempoTowardNeutral() {
        let trusted = MusicMixScore.tempoTerm(MusicMixCompact(Self.song("a")), MusicMixCompact(Self.song("b")))
        let untrusted = MusicMixScore.tempoTerm(MusicMixCompact(Self.song("a", trusted: false)), MusicMixCompact(Self.song("b")))
        #expect(untrusted < trusted)
        #expect(untrusted > MusicMixScore.unknownTempo)
    }

    @Test func energyRiseIsCheaperThanFall() {
        let low = Self.song("l", energy: 0.4), high = Self.song("h", energy: 0.55), crash = Self.song("c", energy: 0.1)
        let small = MusicMixScore.energyTerm(MusicMixCompact(low), MusicMixCompact(high))
        let fall = MusicMixScore.energyTerm(MusicMixCompact(high), MusicMixCompact(low))
        #expect(small == 1)
        #expect(fall < small)
        #expect(MusicMixScore.energyTerm(MusicMixCompact(high), MusicMixCompact(crash)) < fall)
    }

    @Test func quietEdgesGiveBlendRoom() {
        let quietOut = MusicMixProfile(videoId: "a", outroEnergy: 0.1)
        let loudOut = MusicMixProfile(videoId: "b", outroEnergy: 0.9)
        let quietIn = MusicMixProfile(videoId: "c", introEnergy: 0.1)
        #expect(MusicMixScore.blendTerm(MusicMixCompact(quietOut), MusicMixCompact(quietIn))
            > MusicMixScore.blendTerm(MusicMixCompact(loudOut), MusicMixCompact(quietIn)))
    }

    @Test func weightsSumToOne() {
        let sum = MusicMixScore.tempoWeight + MusicMixScore.keyWeight + MusicMixScore.energyWeight + MusicMixScore.blendWeight
        #expect(abs(sum - 1) < 1e-9)
    }
}

@Suite struct MusicEnergyArcTests {
    @Test func peaksNearSixtyPercent() {
        let samples = stride(from: 0.0, through: 1.0, by: 0.01).map { ($0, MusicEnergyArc.target(position: $0)) }
        let peak = samples.max { $0.1 < $1.1 }!
        #expect(abs(peak.0 - 0.6) <= 0.05)
    }

    @Test func startsLowAndDipsAfterThePeak() {
        #expect(MusicEnergyArc.target(position: 0) < 0.4)
        #expect(MusicEnergyArc.target(position: 0.78) < MusicEnergyArc.target(position: 0.6) - 0.2)
        #expect(MusicEnergyArc.target(position: 1) > MusicEnergyArc.target(position: 0.78))
    }

    @Test func clampsAndSurvivesNaN() {
        #expect(MusicEnergyArc.target(position: -3) == MusicEnergyArc.target(position: 0))
        #expect(MusicEnergyArc.target(position: 9) == MusicEnergyArc.target(position: 1))
        #expect(MusicEnergyArc.target(position: .nan).isFinite)
        for p in stride(from: 0.0, through: 1.0, by: 0.05) {
            #expect((0...1).contains(MusicEnergyArc.target(position: p)))
        }
    }
}

@Suite struct MusicMixWindowTests {
    @Test func skipsQueuedPrefixAndCapsAtSize() {
        let ids = (0..<500).map(String.init)
        let window = MusicMixWindow.window(upcoming: ids, queuedCount: 3)
        #expect(window.count == 24)
        #expect(window.first == "3")
        #expect(window.last == "26")
    }

    @Test func shortQueuesAndEdges() {
        #expect(MusicMixWindow.range(upcomingCount: 0, queuedCount: 0) == 0..<0)
        #expect(MusicMixWindow.range(upcomingCount: 5, queuedCount: 9) == 5..<5)
        #expect(MusicMixWindow.range(upcomingCount: 10, queuedCount: 0) == 0..<10)
        #expect(MusicMixWindow.range(upcomingCount: 10, queuedCount: -4) == 0..<10)
        #expect(MusicMixWindow.range(upcomingCount: 10, queuedCount: 2, size: -1) == 2..<2)
    }

    @Test func topUpAfterSixPlayed() {
        #expect(!MusicMixWindow.needsTopUp(playedSinceOrdering: 5))
        #expect(MusicMixWindow.needsTopUp(playedSinceOrdering: 6))
    }
}
