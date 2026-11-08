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

    private var generator: MusicMixGenerator

    init(seed: UInt64) { generator = MusicMixGenerator(seed: seed) }

    // MARK: Whole set

    /// Every entry of `songs` once. `first`, when given, leads: if it is one of `songs` (matched by videoId) it is moved to the
    /// front, otherwise it is only the anchor the first pick mixes out of and is not returned.
    mutating func order(_ songs: [MusicMixProfile], first: MusicMixProfile?) -> [String] {
        let firstIndex = first.flatMap { f in songs.firstIndex { $0.videoId == f.videoId } }
        let picked = run(songs: songs, anchor: first, firstIndex: firstIndex, arc: true, avoid: [])
        return picked.map { songs[$0].videoId }
    }

    // MARK: Skip re-plan (phase 8)

    /// After a manual skip: the next `count` upcoming songs are re-ordered out of the new current song (`anchor`),
    /// pushing the recently played `avoid` songs and their artists to the back. The rest stays as is.
    mutating func reorderTail(
        anchor: MusicMixProfile?, upcoming: [MusicMixProfile], avoid: [MusicMixProfile], count: Int = tailCount
    ) -> [String] {
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
            guard let a, let b else { return 0.5 }
            return MusicMixScore.score(from: a, to: b, allowLift: false)
        }
        var best = low, bestGain = -Double.infinity
        for slot in low...window.count {
            let previous = slot == 0 ? anchorCompact : compact[slot - 1]
            let next = slot < window.count ? compact[slot] : nil
            var gain = score(previous, cand) + score(cand, next)
            if let previous, let next { gain -= score(previous, next) }
            if gain > bestGain + 1e-12 { best = slot; bestGain = gain }
        }
        return best
    }

    /// The candidate that mixes best out of `anchor`. When none has anything known (or there is no anchor) the choice is
    /// a seeded random one, because a score of pure unknowns would always pick the first.
    mutating func pickBest(from candidates: [MusicMixProfile], after anchor: MusicMixProfile?) -> MusicMixProfile? {
        guard !candidates.isEmpty else { return nil }
        let known = candidates.contains { $0.bpm != nil || $0.camelot != nil || $0.energy != nil }
        guard known, let anchor else { return candidates.randomElement(using: &generator) }
        let from = MusicMixCompact(anchor)
        var best = 0, bestScore = -Double.infinity
        for (index, candidate) in candidates.enumerated() {
            let value = MusicMixScore.score(from: from, to: MusicMixCompact(candidate), allowLift: false)
            if value > bestScore + 1e-12 { best = index; bestScore = value }
        }
        return candidates[best]
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
        func evaluate(_ index: Int, allowLift: Bool, target: Float, strict: Bool) -> Double? {
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
            while distance <= count {
                let past = recent[count - distance]
                if distance <= MusicMixOrderer.artistWindow, meta.artist >= 0, past.artist == meta.artist {
                    value -= distance == 1 ? MusicMixOrderer.backToBackPenalty : MusicMixOrderer.artistPenalty
                }
                if meta.keyId >= 0, meta.bucket >= 0, past.keyId == meta.keyId, past.bucket == meta.bucket {
                    value -= MusicMixOrderer.similarPenalty
                }
                distance += 1
            }
            if meta.avoided { value -= MusicMixOrderer.avoidPenalty }
            return value
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

        if let firstIndex {
            place(firstIndex, slot: 0, lifted: false)
            remaining.remove(at: firstIndex)
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
            var scored: [(position: Int, value: Double)] = []
            var strictUsed = true
            for strict in [true, false] {
                strictUsed = strict
                scored.removeAll(keepingCapacity: true)
                for position in 0..<looked {
                    let index = remaining[position]
                    if strict, let crowded, metas[index].artist != crowded { continue }
                    guard let value = scorer.evaluate(index, allowLift: allowLift, target: t, strict: strict) else { continue }
                    Self.insertTop(&scored, (position, value), limit: max(Self.candidateCount, Self.beamWidth))
                }
                // Relax the hard rule only when it leaves nothing (one artist left).
                if !scored.isEmpty { break }
            }
            let best = scored[0].value
            var chosen: Int
            if scorer.hasCurrent, best < Self.randomFallbackScore {
                // Any song, but still one the hard artist rules allow.
                let allowed = (0..<looked).filter { position in
                    let artist = metas[remaining[position]].artist
                    guard strictUsed else { return true }
                    if artist >= 0, artist == lastArtist { return false }
                    return crowded == nil || artist == crowded
                }
                chosen = allowed.randomElement(using: &generator) ?? scored[0].position
            } else if scorer.hasCurrent, best < Self.deadEndScore {
                chosen = beam(scored, from: scorer.current!, remaining: remaining, looked: looked, compact: compact)
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
            place(index, slot: slot, lifted: lifted)
            slot += 1
        }
        return out
    }

    /// Keeps `list` sorted best first and at most `limit` long.
    @_optimize(speed)
    private static func insertTop(_ list: inout [(position: Int, value: Double)], _ item: (position: Int, value: Double), limit: Int) {
        var at = list.count
        while at > 0, list[at - 1].value < item.value { at -= 1 }
        guard at < limit else { return }
        list.insert(item, at: at)
        if list.count > limit { list.removeLast() }
    }

    /// Top candidates weighted by score squared, so a good fit is likelier but never certain.
    @_optimize(speed)
    private mutating func weightedPick(_ scored: [(position: Int, value: Double)]) -> Int {
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
        _ scored: [(position: Int, value: Double)], from: MusicMixCompact, remaining: [Int], looked: Int,
        compact: [MusicMixCompact]
    ) -> Int {
        var bestPosition = scored[0].position, bestTotal = -Double.infinity
        for candidate in scored.prefix(Self.beamWidth) {
            let via = compact[remaining[candidate.position]]
            var follow = 0.0
            for position in 0..<looked where position != candidate.position {
                follow = max(follow, MusicMixScore.score(from: via, to: compact[remaining[position]], allowLift: false))
            }
            let total = candidate.value + Self.pairShare * follow
            if total > bestTotal + 1e-12 { bestPosition = candidate.position; bestTotal = total }
        }
        return bestPosition
    }
}
