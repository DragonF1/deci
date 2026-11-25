// Deci/Music/Playback/MusicTransitionStyle.swift
// Tier 4b P1: how one Mix transition sounds. A style is data on the plan; the picker is pure and deterministic: the same
// numbers always give the same answer. A cut or an echo only ever suits the end of a phrase: of a song that does not fade out, or of a
// section in the middle of one. A cut needs matching tempos there (or genres that are cut that way), a cut with a tail matching
// tempos or two songs that cannot be beat matched. What the genres of the two songs like (`MusicMixHabits`), what the pair asks for (`MusicMixIntent`) and what the last few transitions were
// (`MusicMixHistory`) move the scores.

import Foundation

nonisolated enum MusicTransitionStyle: String, Sendable, CaseIterable {
    /// The beat-matched blend of tier 3b (and every plan that is not a Mix style).
    case longBlend
    /// The next song comes in hard on the bar line, whatever the tempo gap.
    case quickCut
    /// A delay tail on the outgoing song's last beat, then the next song comes in.
    case echoOut
    /// A beat blend with a high-pass sweep on the outgoing song: it thins out to hats and air while the new song takes over.
    case filterSweep
    /// The incoming song's drop lands where the outgoing song's phrase ends.
    case dropSwap
    /// The incoming song's intro is looped 4 or 8 bars until the overlap fits inside it.
    case loopExtend
    /// A beat blend with a low-pass sweep on the outgoing song: it goes dull and sinks under the new song.
    case lowpassSweep
    /// A beat blend whose outgoing song is taken away on a bar line near the end, its last beat echoing over the new song.
    case echoThrow
    /// The outgoing song stops on the bar line and its last moment rings out in a big room while the next song starts.
    case reverbOut
    /// The outgoing song is stopped like a record under a hand as the next song starts.
    case brake
    /// A beat blend whose outgoing song stutters (a beat, half a beat, a quarter) in the bar before the bass changes hands.
    case loopRoll
    /// Both songs' drops land on the same downbeat and run together for a phrase, one bassline at a time.
    case doubleDrop

    /// What the picker may return today.
    static let pickable: [MusicTransitionStyle] = [
        .longBlend, .quickCut, .echoOut, .filterSweep, .dropSwap, .loopExtend, .lowpassSweep, .echoThrow, .reverbOut, .brake, .loopRoll,
        .doubleDrop,
    ]

    /// A cut, or a cut with a tail: no overlap to speak of, the outgoing song is held at full level until the incoming one starts.
    /// Every other style is made of a long overlap like the plain blend.
    var isCutLike: Bool { self == .quickCut || hasTail }

    /// The outgoing song goes on being heard after the cut, as an effect and nothing else.
    var hasTail: Bool { self == .echoOut || self == .reverbOut || self == .brake }

    /// A sweep: the filter takes the outgoing song away.
    var isSweep: Bool { self == .filterSweep || self == .lowpassSweep }

    /// The plan places itself on a drop: nothing else says where either song is.
    var landsOnDrop: Bool { self == .dropSwap || self == .doubleDrop }

    /// An effect is heard as one: it is kept for about every fourth or fifth song.
    var isEffect: Bool { isSweep || hasTail || self == .echoThrow || self == .loopRoll }

    /// What a Mix is made of: one song over the other and nothing more.
    var isPlainBlend: Bool { self == .longBlend || self == .loopExtend }

    /// Owner-facing name.
    var label: String {
        switch self {
        case .longBlend: return "Beat mix"
        case .quickCut: return "Quick cut"
        case .echoOut: return "Echo out"
        case .filterSweep: return "Filter sweep"
        case .dropSwap: return "Drop swap"
        case .loopExtend: return "Loop extend"
        case .lowpassSweep: return "Low-pass sweep"
        case .echoThrow: return "Echo throw"
        case .reverbOut: return "Reverb out"
        case .brake: return "Brake"
        case .loopRoll: return "Loop roll"
        case .doubleDrop: return "Double drop"
        }
    }
}

/// Everything the picker looks at, as plain numbers. nil means unknown, which never blocks and scores neutral.
nonisolated struct MusicTransitionStyleInputs: Equatable, Sendable {
    /// `MusicMixScore.tempoError`: the fractional gap with half or double time folded in.
    var tempoError: Double?
    /// Incoming energy minus outgoing energy, -1...1.
    var energyJump: Float?
    /// 0...1 loudness of the outgoing tail and the incoming intro.
    var outroEnergy: Float?
    var introEnergy: Float?
    /// Camelot steps, 0...6.
    var keyDistance: Int?
    /// Both beat grids passed the planner's trust checks.
    var gridTrusted = false
    /// How songs of these genres are mixed.
    var habits = MusicMixHabits.neutral
    /// The outgoing song is left at the end of a section in its middle, not at its own end.
    var atDJExit = false
    /// That section ends on a bar line of a beat that can be trusted.
    var exitOnBar = false
    /// Confidence (0...1) of the incoming song's first usable drop; nil when it has none or a grid is not trusted.
    var dropConfidence: Float?
    /// The same for the outgoing song's most confident drop: with both, the two can land together.
    var outgoingDropConfidence: Float?
    /// Loop extend: the planner built a loop plan for this pair (the incoming intro is short, the file is local).
    var loopFits = false
    /// How many dB the outgoing tail sits below its body (integrated loudness minus the outro's); nil = unknown. A hard ending
    /// (a cut does not clip a fade-out) is a tail within `hardEndingDb` of the body.
    var tailDropDb: Double?
    /// The outgoing song's mix-out lands on a phrase end of a trusted grid with a known downbeat.
    var mixOutOnPhrase = false

    init(
        tempoError: Double? = nil, energyJump: Float? = nil, outroEnergy: Float? = nil, introEnergy: Float? = nil,
        keyDistance: Int? = nil, gridTrusted: Bool = false, habits: MusicMixHabits = .neutral, atDJExit: Bool = false,
        exitOnBar: Bool = false, dropConfidence: Float? = nil, outgoingDropConfidence: Float? = nil, loopFits: Bool = false, tailDropDb: Double? = nil,
        mixOutOnPhrase: Bool = false
    ) {
        self.habits = habits
        self.atDJExit = atDJExit
        self.exitOnBar = exitOnBar
        self.tailDropDb = tailDropDb
        self.mixOutOnPhrase = mixOutOnPhrase
        self.loopFits = loopFits
        self.dropConfidence = dropConfidence
        self.outgoingDropConfidence = outgoingDropConfidence
        self.tempoError = tempoError
        self.energyJump = energyJump
        self.outroEnergy = outroEnergy
        self.introEnergy = introEnergy
        self.keyDistance = keyDistance
        self.gridTrusted = gridTrusted
    }
}

nonisolated enum MusicTransitionStylePicker {
    /// Rises and falls in energy (0...1) that count as a real change.
    static let bigJump: Float = 0.2
    static let hugeJump: Float = 0.35
    static let farKey = 3
    /// An incoming song this much quieter or less still counts as similar in energy for a sweep.
    static let similarEnergy: Float = 0.1
    /// The log reason for a transition that repeats the previous style because no other style could be built.
    static let noAlternative = "noAlternative"
    /// A cut, with or without a tail, needs the song's end this close to its body (dB): a song that fades out gets a blend.
    static let hardEndingDb = 6.0
    /// A cut needs tempos this close (a fraction, half and double time folded in), and so does a tail between two songs that
    /// could be beat matched.
    static let cutTempoError = 0.03
    /// The long blend of two songs that cannot be beat matched: the short handover of the floor blend. An effect or a cut with a
    /// reason beats it.
    static let clashBlendScore = 0.65
    /// What a tail gains there: nothing overlaps, so it is how a DJ changes the tempo.
    static let clashTailBonus = 0.2
    /// A sweep there has no beats running under it, so it is the effect for a pair that has no other: it waits a song longer.
    static let floorSweepScore = 0.2
    /// A tail or an intro quieter than this (0...1) has no drums to speak of.
    static let quietEdge: Float = 0.4

    /// The style for a pair: the best ranked one, the long blend when none is a candidate.
    static func pick(_ inputs: MusicTransitionStyleInputs, history: MusicMixHistory) -> MusicTransitionStyle {
        ranked(inputs, history: history).first ?? .longBlend
    }

    /// `pick` with only the last transition known.
    static func pick(_ inputs: MusicTransitionStyleInputs, previous: MusicTransitionStyle?) -> MusicTransitionStyle {
        pick(inputs, history: MusicMixHistory(previous.map { [$0] } ?? []))
    }

    /// `ranked` with only the last transition known.
    static func ranked(_ inputs: MusicTransitionStyleInputs, previous: MusicTransitionStyle?) -> [MusicTransitionStyle] {
        ranked(inputs, history: MusicMixHistory(previous.map { [$0] } ?? []))
    }

    /// Every style that suits the pair, best first. What the history makes of a style counts after the score is rounded, and an
    /// effect too soon after the last one is left out. A tie goes to the fixed order long blend, quick cut, echo out, so the result is
    /// deterministic.
    static func ranked(_ inputs: MusicTransitionStyleInputs, history: MusicMixHistory) -> [MusicTransitionStyle] {
        let intent = MusicMixIntent.pick(inputs)
        // A cut lands "on the downbeat", which needs a trusted grid: without one the echo (a fixed delay) always ranks
        // above it, and the cut only comes up when the echo cannot be built.
        func total(_ style: MusicTransitionStyle) -> Double {
            ((score(style, inputs) + inputs.habits.bonus(for: style) + intent.bonus(for: style)) * 1000).rounded() / 1000
        }
        let echoScore = total(.echoOut)
        let scored = MusicTransitionStyle.pickable.enumerated().compactMap { index, style -> (MusicTransitionStyle, Double, Int)? in
            guard suits(style, inputs), history.allows(style) else { return nil }
            var main = total(style)
            if style == .quickCut, !inputs.gridTrusted { main = min(main, echoScore - 0.002) }
            return (style, main + history.bonus(for: style), index)
        }
        let order = scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2 < $1.2 }.map(\.0)
        #if DEBUG
        // Live checks only: a style that is a candidate is put first. Never set outside the test target.
        if let forced = debugScopedStyle ?? debugForcedStyle, isCandidate(forced, inputs) {
            return [forced] + order.filter { $0 != forced }
        }
        #endif
        return order
    }

    #if DEBUG
    nonisolated(unsafe) static var debugForcedStyle: MusicTransitionStyle?
    /// The same hook scoped to one task (and the tasks it starts): set with `$debugScopedStyle.withValue(_:operation:)`, so a
    /// test that forces a style can never be seen by a test running beside it. Wins over `debugForcedStyle`.
    @TaskLocal static var debugScopedStyle: MusicTransitionStyle?
    #endif

    /// True when the tempos are further apart than a beat mix can bridge (half and double time folded in).
    static func isClash(_ inputs: MusicTransitionStyleInputs) -> Bool {
        guard let error = inputs.tempoError, error.isFinite else { return false }
        return !MusicMixScore.withinTolerance(error)
    }

    /// No beat mix can be made of these two: the tempos clash, one of them is not known, or a grid is not trusted.
    static func cannotBeatMix(_ i: MusicTransitionStyleInputs) -> Bool {
        guard i.gridTrusted, let error = i.tempoError, error.isFinite else { return true }
        return !MusicMixScore.withinTolerance(error)
    }

    /// Whether a style suits these numbers. A cut needs something to cut: a hard ending (the tail within `hardEndingDb` of the body)
    /// on a phrase end of a trusted outgoing grid, or the end of a section in the middle of the song. Anything else gets a blend, so
    /// a song that fades out is never stopped. There a cut with a tail is right for two songs that cannot be beat matched: the old
    /// groove is gone before the new one starts, and a section's own end is phrase enough when it is on a bar line. A bare cut also
    /// needs tempos that match, or that are close enough to beat match at a section end between two genres that are cut there
    /// (`cutsOnSections`), and so does a tail between two songs that could be beat matched. Every other style is a candidate by
    /// `isCandidate`.
    static func suits(_ style: MusicTransitionStyle, _ i: MusicTransitionStyleInputs) -> Bool {
        guard style.isCutLike else { return isCandidate(style, i) }
        let hardEnding = i.tailDropDb.map { $0.isFinite && $0 <= hardEndingDb } ?? false
        if style.hasTail, cannotBeatMix(i) { return i.atDJExit ? i.exitOnBar : i.mixOutOnPhrase && hardEnding }
        guard i.mixOutOnPhrase, let error = i.tempoError, error.isFinite else { return false }
        if i.atDJExit, i.habits.cutsOnSections { return MusicMixScore.withinTolerance(error) }
        return hardEnding && error <= cutTempoError + MusicMixScore.boundarySlack
    }

    /// Whether a style can be built for these numbers at all (a cut or an echo is always buildable, but only `suits` picks it).
    /// A sweep needs keys that agree and an incoming song that is no quieter (no louder for a low-pass), with or without a trusted
    /// grid; a throw and a roll need a beat blend; a drop swap also a confident drop, a double drop one in each song.
    private static func isCandidate(_ style: MusicTransitionStyle, _ i: MusicTransitionStyleInputs) -> Bool {
        switch style {
        case .filterSweep:
            guard let jump = i.energyJump, jump.isFinite, jump >= -similarEnergy else { return false }
            return (i.keyDistance ?? 0) < farKey
        case .lowpassSweep:
            guard let jump = i.energyJump, jump.isFinite, jump <= similarEnergy else { return false }
            return (i.keyDistance ?? 0) < farKey
        case .echoThrow, .loopRoll:
            return i.gridTrusted && i.tempoError != nil && !isClash(i) && (i.keyDistance ?? 0) < farKey
        case .dropSwap:
            return dropFits(i, i.dropConfidence)
        case .doubleDrop:
            return dropFits(i, i.dropConfidence) && dropFits(i, i.outgoingDropConfidence)
        case .loopExtend:
            return i.loopFits
        default:
            return true
        }
    }

    /// A drop worth landing on, in a pair that can overlap for a few bars: that needs keys that agree, like the sweep.
    private static func dropFits(_ i: MusicTransitionStyleInputs, _ confidence: Float?) -> Bool {
        guard i.gridTrusted, !isClash(i), let confidence, confidence.isFinite else { return false }
        return confidence >= MusicDropDetector.confidenceFloor && (i.keyDistance ?? 0) < farKey
    }

    private static func score(_ style: MusicTransitionStyle, _ i: MusicTransitionStyleInputs) -> Double {
        let clash = cannotBeatMix(i)
        let jump = i.energyJump.flatMap { $0.isFinite ? $0 : nil }
        let room: Float? = {
            guard let out = i.outroEnergy, let intro = i.introEnergy, out.isFinite, intro.isFinite else { return nil }
            return (out + intro) / 2
        }()
        let far = (i.keyDistance ?? 0) >= farKey
        switch style {
        case .longBlend:
            // There it is a short handover, not two songs running together: keys and energy hardly matter.
            if clash { return clashBlendScore }
            var value = 1.0
            if far { value -= 0.3 }
            if let jump, abs(jump) >= hugeJump { value -= 0.3 }
            if let room, room > 0.7 { value -= 0.2 }
            return value
        case .quickCut:
            var value = 0.5
            if let jump, jump >= bigJump { value += 0.25 }
            if far { value += 0.2 }
            if let room, room > 0.6 { value += 0.15 }
            return value
        case .echoOut:
            var value = 0.45
            if let jump, jump <= -bigJump { value += 0.25 }
            if let out = i.outroEnergy, out.isFinite, out < 0.4 { value += 0.1 }
            if i.gridTrusted { value += 0.02 }
            if clash { value += clashTailBonus }
            return value
        case .filterSweep:
            // Below the plain blend, above a cut: the sweep is the blend with a twist, so it comes up when the blend would
            // repeat. A rising song is what it is for.
            var value = clash ? floorSweepScore : 0.6
            if let jump, jump >= similarEnergy { value += 0.2 }
            if let jump, jump >= bigJump { value += 0.05 }
            return value
        case .dropSwap:
            // A confident drop outranks the sweep; only a pristine blend beats it.
            return 0.6 + 0.35 * Double(min(1, max(0, i.dropConfidence ?? 0)))
        case .loopExtend:
            // The blend it replaces would be shortened or refused for two singers: a loop beats it, and only a repeat sends it away.
            return 1.05
        case .lowpassSweep:
            // The other way round from the high-pass: a song that sinks away is for a calmer one.
            var value = clash ? floorSweepScore : 0.6
            if let jump, jump <= -similarEnergy { value += 0.2 }
            if let jump, jump <= -bigJump { value += 0.05 }
            return value
        case .echoThrow:
            // For two songs of a kind, where a sweep up or down would say nothing.
            var value = 0.6
            if let jump, abs(jump) < similarEnergy { value += 0.2 }
            return value
        case .loopRoll:
            // It builds up to what comes next, so something has to come.
            var value = 0.55
            if let jump, jump >= similarEnergy { value += 0.2 }
            if let drop = i.dropConfidence, drop.isFinite, drop >= MusicDropDetector.confidenceFloor { value += 0.1 }
            return value
        case .reverbOut:
            // For the next song to start in: the quieter its first seconds, the more of the tail is heard.
            var value = 0.45
            if clash { value += clashTailBonus }
            if let jump, jump <= -bigJump { value += 0.2 }
            if let intro = i.introEnergy, intro.isFinite, intro < quietEdge { value += 0.15 }
            if far { value += 0.05 }
            return value
        case .brake:
            // A joke when there is nothing to stop.
            var value = 0.4
            if clash { value += clashTailBonus }
            if let jump, jump >= bigJump { value += 0.15 }
            if far { value += 0.1 }
            if !i.atDJExit, let out = i.outroEnergy, out.isFinite, out < quietEdge { value -= 0.3 }
            return value
        case .doubleDrop:
            // The weaker of the two drops says how well it lands.
            let weaker = min(i.dropConfidence ?? 0, i.outgoingDropConfidence ?? 0)
            return 0.6 + 0.4 * Double(min(1, max(0, weaker)))
        }
    }

    // MARK: From planner inputs

    /// The outgoing song is left in its quiet tail, or the incoming one starts on a quiet intro: two drum parts never meet there. A
    /// DJ exit or entry is not at the song's own edge, so it never counts.
    static func hasQuietEdge(_ inputs: MusicTransitionInputs) -> Bool {
        let outro = MusicMixCompact(profile(inputs.outgoing)).outro, intro = MusicMixCompact(profile(inputs.incoming)).intro
        func quiet(_ value: Float) -> Bool { value >= 0 && value < quietEdge }
        return (inputs.djMixOutSec == nil && quiet(outro)) || (inputs.djEntry == nil && quiet(intro))
    }

    /// The picker's numbers for a pair of planner sides.
    static func inputs(for inputs: MusicTransitionInputs) -> MusicTransitionStyleInputs {
        let a = profile(inputs.outgoing)
        let b = profile(inputs.incoming)
        var ca = MusicMixCompact(a)
        let cb = MusicMixCompact(b)
        // The outgoing deck may be running off its file tempo: the picker judges the tempo that is heard.
        if inputs.outgoing.deckRate.isFinite, inputs.outgoing.deckRate > 0 { ca.bpm *= inputs.outgoing.deckRate }
        var out = MusicTransitionStyleInputs()
        out.tempoError = MusicMixScore.tempoError(ca, cb)
        if ca.energy >= 0, cb.energy >= 0 { out.energyJump = cb.energy - ca.energy }
        if ca.outro >= 0 { out.outroEnergy = ca.outro }
        if cb.intro >= 0 { out.introEnergy = cb.intro }
        if let x = a.camelot, let y = b.camelot { out.keyDistance = x.distance(to: y) }
        out.gridTrusted = a.gridTrusted && b.gridTrusted
        if let row = inputs.outgoing.analysis, row.integratedLUFS.isFinite, let outro = row.outroLUFS, outro.isFinite {
            out.tailDropDb = row.integratedLUFS - outro
        }
        out.mixOutOnPhrase = mixOutIsPhraseEnd(inputs)
        out.habits = MusicMixHabits.pair(for: inputs)
        out.atDJExit = inputs.djMixOutSec != nil
        out.exitOnBar = exitIsOnBar(inputs)
        if out.gridTrusted, let row = inputs.incoming.analysis {
            out.dropConfidence = MusicDropDetector.best(in: row, grid: inputs.incoming.grid)?.confidence
            if out.dropConfidence != nil, let leaving = inputs.outgoing.analysis {
                out.outgoingDropConfidence = MusicDropDetector.drops(in: leaving, grid: inputs.outgoing.grid)?.map(\.confidence).max()
            }
        }
        return out
    }

    /// The cut's mix-out (one bar of room before the outgoing end) is a phrase boundary of a trusted grid with a known downbeat.
    private static func mixOutIsPhraseEnd(_ inputs: MusicTransitionInputs) -> Bool {
        let side = inputs.outgoing
        guard let analysis = side.analysis, let grid = side.grid ?? analysis.usableGrid, MusicBeatPlanner.trusted(grid),
              let first = grid.barTime(0), let duration = MusicBeatPlanner.valid(side.durationSeconds) else { return false }
        let end = MusicTransitionPlanner.trimmedEnd(of: analysis, duration: duration) ?? duration
        let barSec = 4 * grid.periodSec
        guard let out = MusicBeatPlanner.mixOutTime(
            grid: grid, analysis: analysis, bars: 1, barSec: barSec, end: end, preferred: inputs.djMixOutSec
        ) else { return false }
        let phraseSec = Double(MusicBeatPlanner.phraseBars) * barSec
        let phrases = (out - first) / phraseSec
        return abs(phrases - phrases.rounded()) * phraseSec < 0.005
    }

    /// The DJ exit is a bar line of a trusted grid with a known downbeat.
    private static func exitIsOnBar(_ inputs: MusicTransitionInputs) -> Bool {
        guard let exit = inputs.djMixOutSec, let grid = inputs.outgoing.grid ?? inputs.outgoing.analysis?.usableGrid,
              MusicBeatPlanner.trusted(grid), let first = grid.barTime(0) else { return false }
        let bars = (exit - first) / (4 * grid.periodSec)
        return abs(bars - bars.rounded()) * 4 * grid.periodSec < 0.005
    }

    private static func profile(_ side: MusicTransitionSide) -> MusicMixProfile {
        var profile = MusicMixProfile(videoId: side.videoId, artist: "", analysis: side.analysis)
        if let grid = side.grid {
            profile.bpm = grid.bpm
            profile.gridTrusted = MusicBeatPlanner.trusted(grid)
        }
        return profile
    }
}
