// Deci/Music/Playback/MusicMixOrderer.swift
// Orders songs so each one mixes into the next. Randomized greedy, so a set is never played the same way twice,
// with a small look-ahead to repair dead ends. Pure and deterministic for a seed.

import Foundation

/// SplitMix64, kept here so the engine stays free of app types (MusicShuffleGenerator is the same algorithm).
nonisolated struct MusicMixGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    /// 0..<bound; the modulo bias is far below anything a shuffle can show, and this is the sampler's hot path.
    @_optimize(speed)
    mutating func below(_ bound: Int) -> Int { bound <= 1 ? 0 : Int(next() % UInt64(bound)) }

    @_optimize(speed)
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

nonisolated struct MusicMixOrderer: Sendable {
    // Tuning in one block.
    static let pairShare = 0.75
    static let arcShare = 0.25
    static let candidateCount = 4
    static let beamWidth = 3
    /// Below this best score the walk is stuck: look two steps ahead instead of rolling dice.
    static let deadEndScore = 0.5
    /// Below this nothing fits at all: pick any allowed song at random.
    static let randomFallbackScore = 0.25
    static let liftTarget: Float = 0.7
    static let liftSpacing = 4
    static let artistWindow = 3
    static let artistPenalty = 0.2
    static let backToBackPenalty = 0.5
    static let similarWindow = 4
    static let similarPenalty = 0.1
    static let bpmBucketWidth = 6.0
    static let avoidPenalty = 0.5
    static let tailCount = 5
    /// A step looks at this many random remaining songs at most, which bounds a 500 song set to a few tens of thousands
    /// of scores and adds variety. Smaller sets are scanned whole.
    static let sampleLimit = 32
    /// When no song fits on tempo, songs this close (as a fraction) to the nearest one stay eligible. The search is stepwise:
    /// the narrowest step that leaves `nearestMinPool` songs wins, so a near tie keeps its choice and a far song is only
    /// let in when there is nothing closer. The last step is the widest slack ever allowed.
    static let nearestSlackSteps = [0.0, 0.005, 0.01, 0.02]
    static let nearestMinPool = 2
    static let nearestSlack = nearestSlackSteps[nearestSlackSteps.count - 1]
    /// A step whose tempos differ by more than this (half and double time folded in) is a jump: a tempo jump ranks lower
    /// than any step inside the line, whatever its pair score (a Mix plays each song at most 8% off its own tempo, so a
    /// jump past 15% cannot be matched and gets the thinned sweep).
    static let tempoJumpError = 0.15
    static let tempoJumpPenalty = 0.25

    private var generator: MusicMixGenerator

    init(seed: UInt64) { generator = MusicMixGenerator(seed: seed) }

    // MARK: Whole set

    /// Every entry of `songs` once. `first`, when given, leads: if it is one of `songs` (matched by videoId) it is moved to the
    /// front, otherwise it is only the anchor the first pick mixes out of and is not returned.
    mutating func order(_ songs: [MusicMixProfile], first: MusicMixProfile?) -> [String] {
        let firstIndex = first.flatMap { f in songs.firstIndex { $0.videoId == f.videoId } }
        // A first that is in the set is placed as slot 0, so it is not also the anchor (it would enter the spacing history twice).
        let picked = run(songs: songs, anchor: firstIndex == nil ? first : nil, firstIndex: firstIndex, arc: true, avoid: [])
        return picked.map { songs[$0].videoId }
    }

    // MARK: Skip re-plan (phase 8)

    /// After a manual skip: the next `count` upcoming songs are re-ordered out of the new current song (`anchor`),
    /// pushing the recently played `avoid` songs and their artists to the back. The rest stays as is.
    mutating func reorderTail(
        anchor: MusicMixProfile?, upcoming: [MusicMixProfile], avoid: [MusicMixProfile], count: Int = tailCount,
        anchorRate: Double = 1
    ) -> [String] {
        // The playing song may be held at a nudged rate for its whole song: its effective tempo is what the next song meets.
        var anchor = anchor
        if let bpm = anchor?.bpm, bpm.isFinite, bpm > 0, anchorRate.isFinite, anchorRate > 0.5, anchorRate < 2 {
            anchor?.bpm = bpm * anchorRate
        }
        let head = Array(upcoming.prefix(max(0, count)))
        let picked = run(songs: head, anchor: anchor, firstIndex: nil, arc: false, avoid: avoid)
        return picked.map { head[$0].videoId } + upcoming.dropFirst(head.count).map(\.videoId)
    }

    // MARK: Autoplay (phase 7)

    /// Where `candidate` fits best in `window` (an insertion index, `minIndex...window.count`): the slot that costs the
    /// existing neighbours least and mixes both ways. Earliest slot wins a tie.
    func bestInsertion(
        of candidate: MusicMixProfile, into window: [MusicMixProfile], after anchor: MusicMixProfile?, minIndex: Int = 0
    ) -> Int {
        let low = max(0, min(window.count, minIndex))
        let cand = MusicMixCompact(candidate)
        let compact = window.map(MusicMixCompact.init)
        let anchorCompact = anchor.map(MusicMixCompact.init)
        func score(_ a: MusicMixCompact?, _ b: MusicMixCompact?) -> Double {
            // A missing neighbour contributes nothing, so a slot is judged by its net change to the path.
            guard let a, let b else { return 0 }
            return MusicMixScore.score(from: a, to: b, allowLift: false)
        }
        func clash(_ a: MusicMixCompact?, _ b: MusicMixCompact?) -> Int {
            guard let a, let b else { return 0 }
            return MusicMixScore.tempoFits(a, b) ? 0 : 1
        }
        // Fewest tempo clashes after the insertion first, then the best gain.
        var best = low, bestClashes = Int.max, bestGain = -Double.infinity
        for slot in low...window.count {
            let previous = slot == 0 ? anchorCompact : compact[slot - 1]
            let next = slot < window.count ? compact[slot] : nil
            var gain = score(previous, cand) + score(cand, next)
            var clashes = clash(previous, cand) + clash(cand, next)
            if let previous, let next {
                gain -= score(previous, next)
                clashes -= clash(previous, next)
            }
            if clashes < bestClashes || (clashes == bestClashes && gain > bestGain + 1e-12) {
                best = slot; bestClashes = clashes; bestGain = gain
            }
        }
        return best
    }

    /// The candidate that mixes best out of `anchor`. When none has anything known (or there is no anchor) the choice is
    /// a seeded random one, because a score of pure unknowns would always pick the first.
    mutating func pickBest(from candidates: [MusicMixProfile], after anchor: MusicMixProfile?) -> MusicMixProfile? {
        guard !candidates.isEmpty else { return nil }
        let anchorKnown = anchor.map { $0.bpm != nil || $0.camelot != nil || $0.energy != nil } ?? false
        let known = candidates.contains { $0.bpm != nil || $0.camelot != nil || $0.energy != nil }
        guard known, anchorKnown, let anchor else { return candidates.randomElement(using: &generator) }
        let from = MusicMixCompact(anchor)
        let values = candidates.map { MusicMixScore.score(from: from, to: MusicMixCompact($0), allowLift: false) }
        let top = values.max() ?? 0
        // Ties are common (identical tempo and key), so the seed decides among them.
        let tied = values.indices.filter { values[$0] >= top - 1e-9 }
        return candidates[tied.randomElement(using: &generator) ?? 0]
    }

    // MARK: Helpers the tests and the arc check use

    /// A +2 lift needs a high energy target and at least `liftSpacing` songs since the last one.
    static func liftAllowed(target: Float, slotsSinceLift: Int) -> Bool {
        target > liftTarget && slotsSinceLift >= liftSpacing
    }

    // MARK: Core

    private struct Meta {
        var artist: Int
        var keyId: Int
        var bucket: Int
        var avoided: Bool
    }

    /// Scores candidates against the last few placed songs. A plain struct with no captured variables, because this is the
    /// loop that runs a few tens of thousands of times for a big set and closures over mutable state are slow in debug.
    private struct Scorer {
        var compact: [MusicMixCompact]
        var metas: [Meta]
        var arc: Bool
        var current: MusicMixCompact?
        var hasCurrent = false
        /// The last `similarWindow` placed songs, newest last.
        var recent: [Meta] = []

        mutating func remember(_ meta: Meta) {
            recent.append(meta)
            if recent.count > MusicMixOrderer.similarWindow { recent.removeFirst() }
        }

        /// nil when the hard artist rule forbids the candidate.
        @_optimize(speed)
        func evaluate(_ index: Int, allowLift: Bool, target: Float, strict: Bool) -> (value: Double, raw: Double)? {
            let meta = metas[index]
            let lastArtist = recent.isEmpty ? -1 : recent[recent.count - 1].artist
            if strict, meta.artist >= 0, meta.artist == lastArtist { return nil }
            let pair = hasCurrent ? MusicMixScore.score(from: current!, to: compact[index], allowLift: allowLift) : 0.5
            var value = MusicMixOrderer.pairShare * pair
            if arc {
                let energy = compact[index].energy
                let fit = energy < 0 ? 0.5 : Double(max(0, 1 - abs(energy - target)))
                value += MusicMixOrderer.arcShare * fit
            } else {
                value += MusicMixOrderer.arcShare * 0.5
            }
            let count = recent.count
            var distance = 1
            // The relaxed pass has no good choice on artists, the penalty would hit every candidate alike.
            while distance <= count {
                let past = recent[count - distance]
                if strict, distance <= MusicMixOrderer.artistWindow, meta.artist >= 0, past.artist == meta.artist {
                    value -= distance == 1 ? MusicMixOrderer.backToBackPenalty : MusicMixOrderer.artistPenalty
                }
                if meta.keyId >= 0, meta.bucket >= 0, past.keyId == meta.keyId, past.bucket == meta.bucket {
                    value -= MusicMixOrderer.similarPenalty
                }
                distance += 1
            }
            if meta.avoided { value -= MusicMixOrderer.avoidPenalty }
            if hasCurrent, let error = MusicMixScore.tempoError(current!, compact[index]), error > MusicMixOrderer.tempoJumpError {
                value -= MusicMixOrderer.tempoJumpPenalty
            }
            return (value, pair)
        }
    }

    private static func artistKey(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Indices of `songs` in play order.
    @_optimize(speed)
    private mutating func run(
        songs: [MusicMixProfile], anchor: MusicMixProfile?, firstIndex: Int?, arc: Bool, avoid: [MusicMixProfile]
    ) -> [Int] {
        guard !songs.isEmpty else { return [] }
        var artistIds: [String: Int] = [:]
        var uniqueArtist = -1
        @_optimize(speed)
        func artistId(_ name: String) -> Int {
            let key = Self.artistKey(name)
            // An empty artist is nobody in particular and never collides.
            if key.isEmpty { uniqueArtist -= 1; return uniqueArtist }
            if let id = artistIds[key] { return id }
            artistIds[key] = artistIds.count
            return artistIds.count - 1
        }
        @_optimize(speed)
        func meta(_ profile: MusicMixProfile, avoided: Bool) -> Meta {
            let c = MusicMixCompact(profile)
            return Meta(
                artist: artistId(profile.artist), keyId: c.number == 0 ? -1 : c.number * 2 + (c.minor ? 1 : 0),
                bucket: c.bpm > 0 ? Int(c.bpm / Self.bpmBucketWidth) : -1, avoided: avoided)
        }
        let avoidIds = Set(avoid.map(\.videoId))
        let compact = songs.map(MusicMixCompact.init)
        let metas = songs.map { meta($0, avoided: avoidIds.contains($0.videoId)) }
        // Artists of the skipped songs, so the tempo gate can keep their other songs out of the front when it has a choice.
        let avoidedArtists = Set(avoid.map { meta($0, avoided: true).artist }.filter { $0 >= 0 })

        // History of what just played, oldest first, for spacing: avoided songs, then the anchor.
        var scorer = Scorer(compact: compact, metas: metas, arc: arc)
        for profile in avoid { scorer.remember(meta(profile, avoided: false)) }
        if let anchor {
            scorer.remember(meta(anchor, avoided: false))
            scorer.current = MusicMixCompact(anchor)
            scorer.hasCurrent = true
        }
        // Slots, and the arc, count only the songs this call places.
        let slotCount = songs.count
        var lastLiftSlot = -1000
        var out: [Int] = []
        out.reserveCapacity(slotCount)
        var remaining = Array(songs.indices)
        // Songs left per artist: a hard no-back-to-back rule needs the biggest artist placed early enough to interleave.
        var artistLeft: [Int: Int] = [:]
        for meta in metas where meta.artist >= 0 { artistLeft[meta.artist, default: 0] += 1 }
        let biggestArtist = artistLeft.values.max() ?? 0

        @_optimize(speed)
        func target(slot: Int) -> Float {
            guard arc else { return -1 }
            return MusicEnergyArc.target(position: slotCount > 1 ? Double(slot) / Double(slotCount - 1) : 0)
        }

        @_optimize(speed)
        func place(_ index: Int, slot: Int, lifted: Bool) {
            out.append(index)
            scorer.remember(metas[index])
            scorer.current = compact[index]
            scorer.hasCurrent = true
            if lifted { lastLiftSlot = slot }
        }

        // Per song, how many other songs it still fits with on tempo (known tempos only). Placing a song takes one off
        // each song it fitted with, so the count is always about what is left.
        var degree = [Int](repeating: 0, count: songs.count)
        for i in 0..<songs.count where compact[i].bpm > 0 {
            for j in (i + 1)..<max(i + 1, songs.count) where compact[j].bpm > 0 && MusicMixScore.tempoFits(compact[i], compact[j]) {
                degree[i] += 1
                degree[j] += 1
            }
        }
        var pool: [Int] = []
        pool.reserveCapacity(Self.sampleLimit)

        @_optimize(speed)
        func retire(_ index: Int) {
            guard compact[index].bpm > 0 else { return }
            for other in remaining where compact[other].bpm > 0 && MusicMixScore.tempoFits(compact[index], compact[other]) {
                degree[other] -= 1
            }
        }

        if let firstIndex {
            place(firstIndex, slot: 0, lifted: false)
            remaining.remove(at: firstIndex)
            retire(firstIndex)
            if metas[firstIndex].artist >= 0 { artistLeft[metas[firstIndex].artist, default: 0] -= 1 }
        }

        var slot = firstIndex == nil ? 0 : 1
        while !remaining.isEmpty {
            let t = target(slot: slot)
            let allowLift = arc && Self.liftAllowed(target: t, slotsSinceLift: slot - lastLiftSlot)
            // The artist that would be stranded back to back unless it is placed now (it fills every other slot).
            let lastArtist = scorer.recent.last?.artist ?? -1
            // Only worth scanning once the set is small enough for the biggest artist to matter.
            let crowded = remaining.count <= 2 * biggestArtist
                ? artistLeft.first { $0.key != lastArtist && $0.value * 2 > remaining.count }?.key : nil
            // Look at a random sample when there is a lot to scan.
            let looked = min(remaining.count, Self.sampleLimit)
            if looked < remaining.count {
                for position in 0..<looked {
                    remaining.swapAt(position, position + generator.below(remaining.count - position))
                }
            }
            // The tempo gate only works when the song we mix out of has a known tempo.
            let gateOn = scorer.hasCurrent && scorer.current!.bpm > 0
            var scored: [(position: Int, value: Double, raw: Double)] = []
            pool.removeAll(keepingCapacity: true)
            for strict in [true, false] {
                scored.removeAll(keepingCapacity: true)
                pool.removeAll(keepingCapacity: true)
                // Hard artist rules decide who is allowed; the tempo gate only narrows inside that.
                for position in 0..<looked {
                    let artist = metas[remaining[position]].artist
                    if strict {
                        if artist >= 0, artist == lastArtist { continue }
                        if let crowded, artist != crowded { continue }
                    }
                    pool.append(position)
                }
                // Relax the hard rule only when it leaves nothing (one artist left).
                if pool.isEmpty { continue }
                // With nothing playing yet there is no tempo to fit, but the start still goes to a hard-to-place song.
                if gateOn || !scorer.hasCurrent {
                    gate(
                        &pool, current: gateOn ? scorer.current! : nil, looked: looked, remaining: remaining, compact: compact, metas: metas,
                        degree: degree, strict: strict, lastArtist: lastArtist, crowded: crowded, avoidedArtists: avoidedArtists)
                }
                for position in pool {
                    guard let result = scorer.evaluate(remaining[position], allowLift: allowLift, target: t, strict: strict) else { continue }
                    Self.insertTop(&scored, (position, result.value, result.raw), limit: max(Self.candidateCount, Self.beamWidth))
                }
                if !scored.isEmpty { break }
            }
            // Thresholds read the raw pair score of the top pick; penalties only rank (they would make a one-artist set look stuck).
            let best = scored[0].raw
            var chosen: Int
            if scorer.hasCurrent, best < Self.randomFallbackScore {
                // Any song the hard artist rules and the tempo gate allow (the pool is exactly that).
                // An avoided song only when nothing else is left.
                let fresh = pool.filter { !metas[remaining[$0]].avoided }
                chosen = (fresh.isEmpty ? pool : fresh).randomElement(using: &generator) ?? scored[0].position
            } else if scorer.hasCurrent, best < Self.deadEndScore {
                chosen = beam(scored, from: scorer.current!, remaining: remaining, pool: pool, looked: looked, compact: compact)
            } else {
                chosen = weightedPick(scored)
            }
            let index = remaining[chosen]
            if metas[index].artist >= 0 { artistLeft[metas[index].artist, default: 0] -= 1 }
            var lifted = false
            if allowLift, scorer.hasCurrent {
                lifted = MusicMixScore.keyTerm(scorer.current!, compact[index], allowLift: true).lift
            }
            remaining.swapAt(chosen, remaining.count - 1)
            remaining.removeLast()
            retire(index)
            place(index, slot: slot, lifted: lifted)
            slot += 1
        }
        return out
    }

    /// Narrows `pool` (positions in `remaining`, already allowed by the artist rules) to songs that keep the tempo step
    /// inside the tolerance: the sample's fitting songs, else a scan of everything left, else the nearest tempo. Then
    /// keeps the songs with the fewest tempo neighbours left (plus one), so outliers are placed before they are stranded.
    @_optimize(speed)
    private mutating func gate(
        _ pool: inout [Int], current: MusicMixCompact?, looked: Int, remaining: [Int], compact: [MusicMixCompact],
        metas: [Meta], degree: [Int], strict: Bool, lastArtist: Int, crowded: Int?, avoidedArtists: Set<Int>
    ) {
        // A recently played song only competes when nothing else is allowed.
        var preferFresh = false
        if pool.contains(where: { metas[remaining[$0]].avoided }), pool.contains(where: { !metas[remaining[$0]].avoided }) {
            pool = pool.filter { !metas[remaining[$0]].avoided }
            preferFresh = true
        }
        var fitting = pool
        if let current { fitting = pool.filter { MusicMixScore.tempoFits(current, compact[remaining[$0]]) } }
        if let current, fitting.isEmpty, looked < remaining.count {
            // Nothing in the sample fits: look at everything left that the artist rules allow.
            for position in looked..<remaining.count {
                let index = remaining[position]
                let artist = metas[index].artist
                if preferFresh, metas[index].avoided { continue }
                if strict {
                    if artist >= 0, artist == lastArtist { continue }
                    if let crowded, artist != crowded { continue }
                }
                if MusicMixScore.tempoFits(current, compact[index]) { fitting.append(position) }
            }
            if fitting.count > Self.sampleLimit {
                for i in 0..<Self.sampleLimit { fitting.swapAt(i, i + generator.below(fitting.count - i)) }
                fitting.removeLast(fitting.count - Self.sampleLimit)
            }
        }
        if let current, fitting.isEmpty {
            // No song fits anywhere: the nearest tempo, with a little slack so a near tie keeps its choice.
            var all = pool
            if looked < remaining.count {
                for position in looked..<remaining.count {
                    let artist = metas[remaining[position]].artist
                    if preferFresh, metas[remaining[position]].avoided { continue }
                    if strict {
                        if artist >= 0, artist == lastArtist { continue }
                        if let crowded, artist != crowded { continue }
                    }
                    all.append(position)
                }
            }
            var minError = Double.infinity
            for position in all {
                minError = min(minError, MusicMixScore.tempoError(current, compact[remaining[position]]) ?? 0)
            }
            let errors = all.map { MusicMixScore.tempoError(current, compact[remaining[$0]]) ?? 0 }
            for slack in Self.nearestSlackSteps {
                let step = all.indices.filter { errors[$0] <= minError + slack }.map { all[$0] }
                fitting = step
                if step.count >= min(Self.nearestMinPool, all.count) { break }
            }
            if fitting.count > Self.sampleLimit {
                for i in 0..<Self.sampleLimit { fitting.swapAt(i, i + generator.below(fitting.count - i)) }
                fitting.removeLast(fitting.count - Self.sampleLimit)
            }
        }
        // A skipped artist's other songs wait while a song by someone else also fits the tempo. The soft artist penalty
        // cannot do this alone, because the tempo gate has already left it a single candidate.
        if !avoidedArtists.isEmpty {
            let others = fitting.filter { !avoidedArtists.contains(metas[remaining[$0]].artist) }
            if !others.isEmpty { fitting = others }
        }
        // Fewest neighbours first. Unknown tempo songs stay out of the minimum and are always kept.
        var minDegree = Int.max
        for position in fitting {
            let index = remaining[position]
            if compact[index].bpm > 0 { minDegree = min(minDegree, degree[index]) }
        }
        if minDegree != Int.max {
            // The very start has no tempo to fit, so it takes only the hardest songs to place.
            let slack = current == nil ? 0 : 1
            fitting = fitting.filter { compact[remaining[$0]].bpm <= 0 || degree[remaining[$0]] <= minDegree + slack }
        }
        pool = fitting
    }

    /// Keeps `list` sorted best first and at most `limit` long.
    @_optimize(speed)
    private static func insertTop(_ list: inout [(position: Int, value: Double, raw: Double)], _ item: (position: Int, value: Double, raw: Double), limit: Int) {
        var at = list.count
        while at > 0, list[at - 1].value < item.value { at -= 1 }
        guard at < limit else { return }
        list.insert(item, at: at)
        if list.count > limit { list.removeLast() }
    }

    /// Top candidates weighted by score squared, so a good fit is likelier but never certain.
    @_optimize(speed)
    private mutating func weightedPick(_ scored: [(position: Int, value: Double, raw: Double)]) -> Int {
        let pool = scored.prefix(Self.candidateCount)
        let weights = pool.map { max($0.value, 0.001) * max($0.value, 0.001) }
        var roll = Double.random(in: 0..<weights.reduce(0, +), using: &generator)
        for (offset, weight) in weights.enumerated() {
            roll -= weight
            if roll < 0 { return pool[pool.startIndex + offset].position }
        }
        return pool[pool.startIndex].position
    }

    /// Of the top few, the one whose best follow-up is best, so a dead end is not walked into.
    @_optimize(speed)
    private func beam(
        _ scored: [(position: Int, value: Double, raw: Double)], from: MusicMixCompact, remaining: [Int], pool: [Int], looked: Int,
        compact: [MusicMixCompact]
    ) -> Int {
        var bestPosition = scored[0].position, bestTotal = -Double.infinity
        for candidate in scored.prefix(Self.beamWidth) {
            let via = compact[remaining[candidate.position]]
            var follow = 0.0
            // Follow-ups come from the whole sample, only the candidates are gated.
            for position in 0..<looked where position != candidate.position {
                follow = max(follow, MusicMixScore.score(from: via, to: compact[remaining[position]], allowLift: false))
            }
            let total = candidate.value + Self.pairShare * follow
            if total > bestTotal + 1e-12 { bestPosition = candidate.position; bestTotal = total }
        }
        return bestPosition
    }
}
