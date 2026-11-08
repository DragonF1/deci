// Deci/Music/Playback/MusicMixScore.swift
// How well one song mixes into the next, 0...1. Pure value types, no I/O, no app types.

import Foundation

/// A song's position on the Camelot wheel: 1...12 around the circle, A is minor and B is major.
nonisolated struct MusicCamelot: Sendable, Equatable, Hashable {
    let number: Int
    let isMinor: Bool

    /// Any number wraps into 1...12 so 13 is 1 and 0 is 12.
    init(number: Int, isMinor: Bool) {
        self.number = ((number - 1) % 12 + 12) % 12 + 1
        self.isMinor = isMinor
    }

    /// "8A", "12B", case-insensitive; nil for anything else.
    init?(code: String) {
        let text = code.trimmingCharacters(in: .whitespaces).uppercased()
        guard let letter = text.last, letter == "A" || letter == "B",
              let number = Int(text.dropLast()), (1...12).contains(number) else { return nil }
        self.init(number: number, isMinor: letter == "A")
    }

    var code: String { "\(number)\(isMinor ? "A" : "B")" }

    /// Steps around the wheel, 0...6, with wraparound (12 to 1 is one step). The relative major or minor (same number,
    /// other letter) is 0 because the two share their notes. nil for any other cross-mode pair.
    func distance(to other: MusicCamelot) -> Int? {
        if isMinor != other.isMinor { return number == other.number ? 0 : nil }
        let gap = abs(number - other.number)
        return min(gap, 12 - gap)
    }

    /// Signed steps from self to `other` in the same mode, -5...6 (+1 is clockwise); nil across modes.
    func step(to other: MusicCamelot) -> Int? {
        guard isMinor == other.isMinor else { return nil }
        let raw = ((other.number - number) % 12 + 12) % 12
        return raw > 6 ? raw - 12 : raw
    }
}

/// Everything the mix engine knows about a song. Optional fields mean unknown, which scores neutral and never blocks.
nonisolated struct MusicMixProfile: Sendable, Equatable {
    var videoId: String
    var artist: String
    var bpm: Double?
    /// The beat grid passed the planner's trust checks; an untrusted tempo counts for half.
    var gridTrusted: Bool
    /// nil when the key is unknown or the detector was not sure.
    var camelot: MusicCamelot?
    /// 0...1.
    var energy: Float?
    /// 0...1 loudness of the first and last seconds, how much room a long blend has.
    var introEnergy: Float?
    var outroEnergy: Float?

    init(
        videoId: String, artist: String = "", bpm: Double? = nil, gridTrusted: Bool = false,
        camelot: MusicCamelot? = nil, energy: Float? = nil, introEnergy: Float? = nil, outroEnergy: Float? = nil
    ) {
        self.videoId = videoId
        self.artist = artist
        self.bpm = bpm
        self.gridTrusted = gridTrusted
        self.camelot = camelot
        self.energy = energy
        self.introEnergy = introEnergy
        self.outroEnergy = outroEnergy
    }
}

/// A profile boiled down to plain numbers so the orderer's hot loop never touches a String or an Optional.
nonisolated struct MusicMixCompact: Sendable {
    /// 0 means unknown.
    var bpm: Double
    var trusted: Bool
    /// 0 means unknown.
    var number: Int
    var minor: Bool
    /// Negative means unknown.
    var energy: Float
    var intro: Float
    var outro: Float

    init(_ profile: MusicMixProfile) {
        let bpm = profile.bpm ?? 0
        self.bpm = bpm.isFinite && bpm > 0 ? bpm : 0
        trusted = profile.gridTrusted
        number = profile.camelot?.number ?? 0
        minor = profile.camelot?.isMinor ?? false
        func unit(_ value: Float?) -> Float {
            guard let value, value.isFinite else { return -1 }
            return max(0, min(1, value))
        }
        energy = unit(profile.energy)
        intro = unit(profile.introEnergy)
        outro = unit(profile.outroEnergy)
    }
}

nonisolated enum MusicMixScore {
    // One block for every weight, so tuning never hunts through the code.
    static let tempoWeight = 0.30
    static let keyWeight = 0.30
    static let energyWeight = 0.25
    static let blendWeight = 0.15

    static let unknownTempo = 0.4
    static let unknownKey = 0.4
    static let unknownEnergy = 0.5
    static let unknownBlend = 0.5

    /// Drift up to this fraction is the sweet spot (a 2 to 3 percent walk), up to `tempoTolerance` still mixes,
    /// beyond it the tempo clashes and the score falls off a cliff.
    static let tempoSweetSpot = 0.03
    static let tempoTolerance = 0.08
    static let tempoClashCeiling = 0.5
    static let tempoClashSpan = 0.22
    /// Half or double time lines the beats up but not the bars.
    static let tempoMultipleFactor = 0.95

    static let keyStep = 0.85
    static let keyLift = 0.6
    static let keyClash = 0.15

    /// A rise of up to this much between songs is free, a fall or a bigger rise costs.
    static let energyFreeRise: Float = 0.15

    /// 0...1, never NaN. Direction matters for energy and blend room, not for tempo or key (except the lift).
    static func score(from: MusicMixProfile, to: MusicMixProfile, allowLift: Bool) -> Double {
        score(from: MusicMixCompact(from), to: MusicMixCompact(to), allowLift: allowLift)
    }

    @_optimize(speed)
    static func score(from a: MusicMixCompact, to b: MusicMixCompact, allowLift: Bool) -> Double {
        let value = tempoWeight * tempoTerm(a, b) + keyWeight * keyTerm(a, b, allowLift: allowLift).value
            + energyWeight * energyTerm(a, b) + blendWeight * blendTerm(a, b)
        return max(0, min(1, value))
    }

    @_optimize(speed)
    static func tempoTerm(_ a: MusicMixCompact, _ b: MusicMixCompact) -> Double {
        guard a.bpm > 0, b.bpm > 0 else { return unknownTempo }
        let ratio = a.bpm / b.bpm
        var error = abs(ratio - 1)
        var factor = 1.0
        // Half and double time, spelled out because this runs in the orderer's hot loop.
        let doubled = abs(ratio * 2 - 1), halved = abs(ratio * 0.5 - 1)
        if doubled < error - 1e-12 { error = doubled; factor = tempoMultipleFactor }
        if halved < error - 1e-12 { error = halved; factor = tempoMultipleFactor }
        var value: Double
        if error <= tempoSweetSpot {
            value = 1
        } else if error <= tempoTolerance {
            value = 1 - (error - tempoSweetSpot) / (tempoTolerance - tempoSweetSpot) * 0.15
        } else {
            value = tempoClashCeiling * max(0, 1 - (error - tempoTolerance) / tempoClashSpan)
        }
        value *= factor
        // A guessed tempo is worth half a measured one.
        if !(a.trusted && b.trusted) { value = unknownTempo + (value - unknownTempo) * 0.5 }
        return value
    }

    /// `lift` is true when the +2 energy boost step was what earned the score.
    @_optimize(speed)
    static func keyTerm(_ a: MusicMixCompact, _ b: MusicMixCompact, allowLift: Bool) -> (value: Double, lift: Bool) {
        guard a.number > 0, b.number > 0 else { return (unknownKey, false) }
        guard a.minor == b.minor else { return (a.number == b.number ? 1 : keyClash, false) }
        let raw = ((b.number - a.number) % 12 + 12) % 12
        let step = raw > 6 ? raw - 12 : raw
        switch abs(step) {
        case 0: return (1, false)
        case 1: return (keyStep, false)
        default:
            if allowLift, step == 2 { return (keyLift, true) }
            return (keyClash, false)
        }
    }

    @_optimize(speed)
    static func energyTerm(_ a: MusicMixCompact, _ b: MusicMixCompact) -> Double {
        guard a.energy >= 0, b.energy >= 0 else { return unknownEnergy }
        let jump = b.energy - a.energy
        let cost: Float = jump >= 0 ? max(0, jump - energyFreeRise) * 1.5 : -jump * 1.2
        return Double(max(0, min(1, 1 - cost)))
    }

    /// Room for a long blend: the outgoing song's tail and the incoming intro are both quiet.
    @_optimize(speed)
    static func blendTerm(_ a: MusicMixCompact, _ b: MusicMixCompact) -> Double {
        guard a.outro >= 0, b.intro >= 0 else { return unknownBlend }
        return Double(1 - (a.outro + b.intro) / 2)
    }
}
