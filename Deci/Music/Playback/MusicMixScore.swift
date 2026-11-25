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
    /// What kind of music its tags say it is; nil when it has none that say.
    var genre: MusicGenreFamily?

    init(
        videoId: String, artist: String = "", bpm: Double? = nil, gridTrusted: Bool = false,
        camelot: MusicCamelot? = nil, energy: Float? = nil, introEnergy: Float? = nil, outroEnergy: Float? = nil,
        genre: MusicGenreFamily? = nil
    ) {
        self.videoId = videoId
        self.artist = artist
        self.bpm = bpm
        self.gridTrusted = gridTrusted
        self.camelot = camelot
        self.energy = energy
        self.introEnergy = introEnergy
        self.outroEnergy = outroEnergy
        self.genre = genre
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
    /// The genre family and its group as numbers. Negative means unknown.
    var genre: Int
    var group: Int

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
        let family = profile.genre.flatMap { $0 == .open ? nil : $0 }
        genre = family?.index ?? -1
        group = family?.group ?? -1
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
    /// The most a song can be stretched to be beat matched. Closer than `tempoTolerance`: what still sounds right next to
    /// each other is wider than what the planner can put on one beat.
    static let matchTolerance = 0.05
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

    /// How far apart two tempos are as a fraction, half or double time folded in. nil when either tempo is unknown.
    @_optimize(speed)
    static func tempoError(_ a: MusicMixCompact, _ b: MusicMixCompact) -> Double? {
        tempoMeasure(a, b)?.error
    }

    /// Within the tolerance, half or double time included. An unknown tempo never clashes.
    @_optimize(speed)
    static func tempoFits(_ a: MusicMixCompact, _ b: MusicMixCompact) -> Bool {
        guard let error = tempoMeasure(a, b)?.error else { return true }
        return withinTolerance(error)
    }

    // What a step costs, in whole points, before any score is looked at. A lower cost always wins; the score only decides
    // between equal ones. Same genre and beat matched is free, half or double time costs a point. A change of genre costs less than a tempo clash and more
    // than two songs that only nearly share a tempo, so the music stays in its genre while that genre still mixes.
    static let genreNearCost = 1
    static let genreChangeCost = 3
    static let tempoHalfCost = 1
    static let tempoNearCost = 2
    static let tempoClashCost = 4

    /// Nothing for the same genre, a point for a related one or when either is not known, the most for another one.
    @_optimize(speed)
    static func genreCost(_ a: MusicMixCompact, _ b: MusicMixCompact) -> Int {
        guard a.genre >= 0, b.genre >= 0 else { return genreNearCost }
        if a.genre == b.genre { return 0 }
        return a.group == b.group ? genreNearCost : genreChangeCost
    }

    /// Both genres are known and a DJ would call it a change of genre.
    @_optimize(speed)
    static func changesGenre(_ a: MusicMixCompact, _ b: MusicMixCompact) -> Bool {
        a.genre >= 0 && b.genre >= 0 && a.group != b.group
    }

    /// Nothing when the two can be beat matched: both beats are known for sure and one can be stretched onto the other.
    @_optimize(speed)
    static func tempoCost(_ a: MusicMixCompact, _ b: MusicMixCompact) -> Int {
        guard let measure = tempoMeasure(a, b) else { return tempoNearCost }
        guard withinTolerance(measure.error) else { return tempoClashCost }
        guard a.trusted, b.trusted, measure.error <= matchTolerance + boundarySlack else { return tempoNearCost }
        return measure.folded ? tempoHalfCost : 0
    }

    @_optimize(speed)
    static func stepCost(_ a: MusicMixCompact, _ b: MusicMixCompact) -> Int {
        genreCost(a, b) + tempoCost(a, b)
    }

    /// Float rounding in the ratio must not push 100 to 108 over the line, so every boundary shares this slack.
    static let boundarySlack = 1e-9
    @inline(__always) static func withinSweetSpot(_ error: Double) -> Bool { error <= tempoSweetSpot + boundarySlack }
    @inline(__always) static func withinTolerance(_ error: Double) -> Bool { error <= tempoTolerance + boundarySlack }

    /// The one copy of the tempo maths: the folded error and whether the fold (half or double time) was used.
    @_optimize(speed)
    private static func tempoMeasure(_ a: MusicMixCompact, _ b: MusicMixCompact) -> (error: Double, folded: Bool)? {
        guard a.bpm > 0, b.bpm > 0 else { return nil }
        // Always the faster over the slower, so the score is the same in both directions.
        let ratio = max(a.bpm, b.bpm) / min(a.bpm, b.bpm)
        let plain = ratio - 1
        // Half or double time: the faster song is twice the slower one.
        let folded = abs(ratio / 2 - 1)
        return folded < plain - 1e-12 ? (folded, true) : (plain, false)
    }

    @_optimize(speed)
    static func tempoTerm(_ a: MusicMixCompact, _ b: MusicMixCompact) -> Double {
        guard let measure = tempoMeasure(a, b) else { return unknownTempo }
        let error = measure.error
        let factor = measure.folded ? tempoMultipleFactor : 1.0
        var value: Double
        if withinSweetSpot(error) {
            value = 1
        } else if withinTolerance(error) {
            value = 1 - max(0, error - tempoSweetSpot) / (tempoTolerance - tempoSweetSpot) * 0.15
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
