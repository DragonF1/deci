// Deci/Music/Playback/MusicTransitionStyle.swift
// Tier 4b P1: how one Mix transition sounds. A style is data on the plan; the picker is pure and deterministic: the same
// numbers always give the same answer, and it never returns the style the previous transition used.

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

    /// What the picker may return today.
    static let pickable: [MusicTransitionStyle] = [.longBlend, .quickCut, .echoOut, .filterSweep, .dropSwap, .loopExtend]

    /// A cut or an echo: no overlap to speak of, the outgoing song is held at full level until the incoming one starts.
    /// Every other style is made of a long overlap like the plain blend.
    var isCutLike: Bool { self == .quickCut || self == .echoOut }

    /// Owner-facing name.
    var label: String {
        switch self {
        case .longBlend: return "Beat mix"
        case .quickCut: return "Quick cut"
        case .echoOut: return "Echo out"
        case .filterSweep: return "Filter sweep"
        case .dropSwap: return "Drop swap"
        case .loopExtend: return "Loop extend"
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
    /// Genre tags of both songs, any case. Often empty; only ever a tie-break.
    var genres: [String] = []
    /// Confidence (0...1) of the incoming song's first usable drop; nil when it has none or a grid is not trusted.
    var dropConfidence: Float?
    /// Loop extend: the planner built a loop plan for this pair (the incoming intro is short, the file is local).
    var loopFits = false

    init(
        tempoError: Double? = nil, energyJump: Float? = nil, outroEnergy: Float? = nil, introEnergy: Float? = nil,
        keyDistance: Int? = nil, gridTrusted: Bool = false, genres: [String] = [], dropConfidence: Float? = nil,
        loopFits: Bool = false
    ) {
        self.loopFits = loopFits
        self.dropConfidence = dropConfidence
        self.tempoError = tempoError
        self.energyJump = energyJump
        self.outroEnergy = outroEnergy
        self.introEnergy = introEnergy
        self.keyDistance = keyDistance
        self.gridTrusted = gridTrusted
        self.genres = genres
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

    /// The style for a pair. Never `previous`, even when it is the best one.
    static func pick(_ inputs: MusicTransitionStyleInputs, previous: MusicTransitionStyle?) -> MusicTransitionStyle {
        ranked(inputs, previous: previous).first ?? .quickCut
    }

    /// Every pickable style but `previous`, best first. A tie goes to the genre hint, then to the fixed order long blend,
    /// quick cut, echo out, so the result is deterministic.
    static func ranked(_ inputs: MusicTransitionStyleInputs, previous: MusicTransitionStyle?) -> [MusicTransitionStyle] {
        // A cut lands "on the downbeat", which needs a trusted grid: without one the echo (a fixed delay) always ranks
        // above it, and the cut only comes up when the echo cannot be built.
        let echoScore = (score(.echoOut, inputs) * 1000).rounded() / 1000
        let scored = MusicTransitionStyle.pickable.enumerated().compactMap { index, style -> (MusicTransitionStyle, Double, Double, Int)? in
            guard style != previous, isCandidate(style, inputs) else { return nil }
            var main = (score(style, inputs) * 1000).rounded() / 1000
            if style == .quickCut, !inputs.gridTrusted { main = min(main, echoScore - 0.002) }
            return (style, main, genreHint(style, inputs.genres), index)
        }
        let order = scored.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            if $0.2 != $1.2 { return $0.2 > $1.2 }
            return $0.3 < $1.3
        }.map(\.0)
        #if DEBUG
        // Live checks only: a style that is a candidate is put first. Never set outside the test target.
        if let forced = debugScopedStyle ?? debugForcedStyle, let at = order.firstIndex(of: forced) {
            return [forced] + order.enumerated().filter { $0.offset != at }.map(\.element)
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

    /// Whether a style can be picked for these numbers at all. The three older styles always can; a sweep needs a beat blend
    /// (tempos that meet, trusted grids), keys that agree and an incoming song that is no quieter; a drop swap needs a
    /// beat blend and a confident drop.
    private static func isCandidate(_ style: MusicTransitionStyle, _ i: MusicTransitionStyleInputs) -> Bool {
        switch style {
        case .filterSweep:
            guard i.gridTrusted, !isClash(i), let jump = i.energyJump, jump.isFinite, jump >= -similarEnergy else { return false }
            return (i.keyDistance ?? 0) < farKey
        case .dropSwap:
            guard i.gridTrusted, !isClash(i), let confidence = i.dropConfidence, confidence.isFinite else { return false }
            // Overlapping 4 to 8 bars needs keys that agree, like the sweep.
            return confidence >= MusicDropDetector.confidenceFloor && (i.keyDistance ?? 0) < farKey
        case .loopExtend:
            return i.loopFits
        default:
            return true
        }
    }

    private static func score(_ style: MusicTransitionStyle, _ i: MusicTransitionStyleInputs) -> Double {
        let clash = isClash(i)
        let jump = i.energyJump.flatMap { $0.isFinite ? $0 : nil }
        let room: Float? = {
            guard let out = i.outroEnergy, let intro = i.introEnergy, out.isFinite, intro.isFinite else { return nil }
            return (out + intro) / 2
        }()
        let far = (i.keyDistance ?? 0) >= farKey
        switch style {
        case .longBlend:
            // A blend needs the tempos to meet: with a clash it is out of the running.
            if clash { return -1 }
            var value = 1.0
            if far { value -= 0.3 }
            if let jump, abs(jump) >= hugeJump { value -= 0.3 }
            if let room, room > 0.7 { value -= 0.2 }
            return value
        case .quickCut:
            var value = 0.5
            if clash { value += 0.6 }
            if let jump, jump >= bigJump { value += 0.25 }
            if far { value += 0.2 }
            if let room, room > 0.6 { value += 0.15 }
            return value
        case .echoOut:
            var value = 0.45
            if clash { value += 0.55 }
            if let jump, jump <= -bigJump { value += 0.25 }
            if let out = i.outroEnergy, out.isFinite, out < 0.4 { value += 0.1 }
            if i.gridTrusted { value += 0.02 }
            return value
        case .filterSweep:
            // Below the plain blend, above a cut: the sweep is the blend with a twist, so it comes up when the blend would
            // repeat. A rising song is what it is for.
            var value = 0.6
            if let jump, jump >= similarEnergy { value += 0.2 }
            if let jump, jump >= bigJump { value += 0.05 }
            return value
        case .dropSwap:
            // A confident drop outranks the sweep; only a pristine blend beats it.
            return 0.6 + 0.35 * Double(min(1, max(0, i.dropConfidence ?? 0)))
        case .loopExtend:
            // The blend it replaces would be shortened or refused for two singers: a loop beats it, and only a repeat sends it away.
            return 1.05
        }
    }

    private static let punchyGenres = ["dance", "electronic", "house", "techno", "hip hop", "hip-hop", "rap", "trap", "edm"]
    private static let softGenres = ["ambient", "chill", "folk", "acoustic", "jazz", "classical", "soul", "r&b"]

    /// A tie-break only: far smaller than any step of `score`, and applied after the score is rounded.
    private static func genreHint(_ style: MusicTransitionStyle, _ genres: [String]) -> Double {
        guard !genres.isEmpty else { return 0 }
        let tags = genres.map { $0.lowercased() }
        func hits(_ words: [String]) -> Int { tags.filter { tag in words.contains { tag.contains($0) } }.count }
        switch style {
        case .quickCut: return Double(hits(punchyGenres))
        case .echoOut: return Double(hits(softGenres))
        default: return 0
        }
    }

    // MARK: From planner inputs

    /// The picker's numbers for a pair of planner sides.
    static func inputs(for inputs: MusicTransitionInputs) -> MusicTransitionStyleInputs {
        let a = profile(inputs.outgoing)
        let b = profile(inputs.incoming)
        let ca = MusicMixCompact(a), cb = MusicMixCompact(b)
        var out = MusicTransitionStyleInputs()
        out.tempoError = MusicMixScore.tempoError(ca, cb)
        if ca.energy >= 0, cb.energy >= 0 { out.energyJump = cb.energy - ca.energy }
        if ca.outro >= 0 { out.outroEnergy = ca.outro }
        if cb.intro >= 0 { out.introEnergy = cb.intro }
        if let x = a.camelot, let y = b.camelot { out.keyDistance = x.distance(to: y) }
        out.gridTrusted = a.gridTrusted && b.gridTrusted
        out.genres = inputs.outgoing.genres + inputs.incoming.genres
        if out.gridTrusted, let row = inputs.incoming.analysis {
            out.dropConfidence = MusicDropDetector.best(in: row, grid: inputs.incoming.grid)?.confidence
        }
        return out
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
