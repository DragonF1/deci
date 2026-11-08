// DeciTests/Music/LiveChecks/LiveChecksEngine.swift
// The engine side of the checks: real transitions through the two-deck engine (3, 5, 10) and the planning measurements
// over real analysis rows and real lyrics (7, 8).

import Foundation
@testable import Deci

extension LiveChecks {
    // MARK: Real runs

    struct RunOutcome {
        var transitions: [LiveTransition]
        var played: [String]
    }

    func realRun(
        _ audio: LiveAudio, beatMix: Bool, count: Int, tracks: [MusicTrack], page: MusicBrowsePage? = nil,
        scriptAutomix: [(after: String, tracks: [MusicTrack])] = []
    ) async -> RunOutcome {
        let (engine, chain) = audio.makeEngine()
        let backend = await world.makeBackend()
        let prefs = MusicPlaybackPreferences(crossfade: false, crossfadeSeconds: 7, beatMix: beatMix, vocalGuard: true)
        let rig = world.makeRig(engine: engine, preferences: prefs, backend: backend)
        let service = rig.service
        for entry in scriptAutomix { await backend.setAutomix(afterVideoId: entry.after, tracks: entry.tracks) }
        if let page {
            service.play(tracks[0], in: page)
        } else {
            await backend.setRadio(seed: tracks[0].videoId, tracks: tracks, continuation: nil)
            service.play(tracks[0])
        }
        await world.settle(service)
        service.setShuffleMode(.mix)
        await world.settle(service)
        let runner = LiveRunner(world: world, rig: rig, engine: engine, chain: chain, audio: audio)
        let out = await runner.run(count: count)
        engine.unload()
        return RunOutcome(transitions: out, played: runner.played)
    }

    func describe(_ t: LiveTransition) -> String {
        let a = world.byId[t.from]?.index ?? -1, b = world.byId[t.to]?.index ?? -1
        var text = "\(a) > \(b): mode \(t.mode), plan fade \(t.planFade.map { liveF($0) } ?? "-") s, measured overlap \(liveF(t.overlapSec)) s, crossfaded \(t.crossfaded)"
        if let failure = t.failure { text += ", FAILURE: \(failure)" }
        if let line = t.line("transition_beat_plan") { text += ", beat bars=\(line.kv["bars"] ?? "?") rate=\(line.kv["rate"] ?? "?")" }
        if let line = t.line("transition_beat_fallback") { text += ", beat refused: \(line.kv["reason"] ?? "?")" }
        if let line = t.line("transition_vocal_guard") { text += ", vocal guard \(line.kv["action"] ?? "?")" }
        text += ", stalls \(t.stalls), capture peak \(liveF(Double(t.capturePeak), 3)), dropouts \(t.dropouts), non-finite \(t.nonFinite)"
        return text
    }

    var beatRuns: [LiveTransition] { realBeat }

    func engineRuns() async {
        guard let audio else {
            let why = "no proven silent capture (\(LiveAudio.failure ?? "unknown")); falling back to the fake engine would test nothing real here"
            for (n, t) in [(3, "Crossfade off still blends"), (5, "Playlist end hands over to Autoplay"), (10, "No crackle proxy")] {
                results[n] = false
                LiveReport.record(n, t, verdict: "NOT RUN", [why])
            }
            return
        }
        let all = world.songs.map { $0.track() }

        // Run A: Crossfade off, beat mix on, one continuous Mix run.
        let a = await realRun(audio, beatMix: true, count: 6, tracks: all)
        // Run C: Crossfade off, beat mix off, so every blend is a plain fade of the Settings length.
        let c = await realRun(audio, beatMix: false, count: 2, tracks: Array(all.dropFirst(7)))
        // Run B: a 3 song page and the automix radio behind it.
        let short = world.songs.sorted { $0.duration < $1.duration }
        let pageSongs = Array(short.prefix(3))
        let pageTracks = pageSongs.map { $0.track() }
        let pageIds = Set(pageTracks.map(\.videoId))
        let radioTracks = world.songs.filter { !pageIds.contains($0.videoId) }.prefix(4).map { $0.track() }
        let page = MusicSamples.page("VLPLliveB", tracks: pageTracks, continuation: nil, audioPlaylistId: "RDAMPLliveB")
        var automix: [(after: String, tracks: [MusicTrack])] = []
        for t in pageTracks { automix.append((t.videoId, [t] + radioTracks)) }
        let b = await realRun(audio, beatMix: true, count: 4, tracks: pageTracks, page: page, scriptAutomix: automix)

        runA = a.transitions
        realBeat = (a.transitions + c.transitions + b.transitions).filter { $0.mode == "beat" }
        allRealRuns = a.transitions + c.transitions + b.transitions

        // Check 3
        var lines3: [String] = ["Settings fade length 7 s, Crossfade OFF, Mix on."]
        var ok3 = !(a.transitions + c.transitions).isEmpty
        for t in a.transitions { lines3.append("run A (beat mix on) " + describe(t)); if !t.crossfaded || t.overlapSec < 1 { ok3 = false } }
        var fadeLengthOK = true
        for t in c.transitions {
            lines3.append("run C (beat mix off) " + describe(t))
            if !t.crossfaded || t.overlapSec < 1 { ok3 = false }
            let guardTouched = t.line("transition_vocal_guard") != nil
            if let fade = t.planFade, !guardTouched {
                if abs(fade - 7) > 0.05 || abs(t.overlapSec - fade) > 1.5 { fadeLengthOK = false }
            }
        }
        if c.transitions.isEmpty { fadeLengthOK = false }
        finish(3, "Mix with Crossfade OFF still blends, fade length = Settings", pass: ok3 && fadeLengthOK, [
            "every transition overlapped on two decks: \(ok3); non-beat plan fade equals Settings 7 s and the measured overlap is within 1.5 s of it: \(fadeLengthOK)",
        ] + lines3)

        // Check 5
        let pageOrder = b.played.prefix(3)
        let afterPage = Array(b.played.dropFirst(3))
        let radioIds = Set(radioTracks.map(\.videoId))
        let crossedAll = !b.transitions.isEmpty && b.transitions.allSatisfy { $0.crossfaded && $0.failure == nil }
        let noCut = b.transitions.allSatisfy { $0.stalls == 0 && $0.fallbackCount == 0 }
        let unique = Set(b.played).count == b.played.count
        let handedOver = !afterPage.isEmpty && afterPage.allSatisfy { radioIds.contains($0) }
        let pass5 = Set(pageOrder) == pageIds && handedOver && crossedAll && noCut && unique && b.played.count == 5
        finish(5, "Playlist end in Mix hands over to the Autoplay radio, blended", pass: pass5, [
            "played sequence: \(b.played.map { name($0) }.joined(separator: " > "))",
            "page songs first (as a set): \(Set(pageOrder) == pageIds); the radio follows: \(handedOver); no repeats: \(unique); every hand-over overlapped: \(crossedAll); no stall or fallback cut: \(noCut)",
        ] + b.transitions.map { "run B " + describe($0) })

        // Check 10
        let runs = a.transitions + c.transitions + b.transitions
        var ok10 = !runs.isEmpty
        var lines10: [String] = []
        for t in runs where t.crossfaded {
            let sane = t.capturePeak > 0.01 && t.capturePeak <= 1.05 && t.chainPeak <= 4
            if t.nonFinite > 0 || t.dropouts > 0 || t.stalls > 0 || t.glitchLines > 0 || !sane { ok10 = false }
            lines10.append("\(world.byId[t.from]?.index ?? -1) > \(world.byId[t.to]?.index ?? -1): capture peak \(liveF(Double(t.capturePeak), 3)), chain post-gain peak \(liveF(Double(t.chainPeak), 3)), non-finite \(t.nonFinite), digital dropouts >= 30 ms \(t.dropouts)\(glideNote(t))\(t.dropoutDetail.isEmpty ? "" : " [" + t.dropoutDetail + "]"), stalls \(t.stalls), engine glitch lines \(t.glitchLines)")
        }
        let failed = runs.filter { !$0.crossfaded }
        if !failed.isEmpty { ok10 = false }
        lines10.insert("\(runs.filter(\.crossfaded).count) transitions measured of \(runs.count) attempted; captured at the DSP chain (each lease's output after the chain and its fade, before the zeroing that keeps the test silent), started only after the seek settled; dropout = silence >= 30 ms with signal 100 ms either side", at: 0)
        finish(10, "No crackle proxy during transitions", pass: ok10, lines10 + failed.map { "not measured: " + describe($0) })
    }

    // MARK: Planning checks (7, 8)

    func plans() -> [(a: LiveSong, b: LiveSong, plan: TransitionPlan)] {
        var out: [(LiveSong, LiveSong, TransitionPlan)] = []
        for pair in chainPairs {
            guard let a = world.byId[pair.from], let b = world.byId[pair.to], let rowA = world.rows[a.videoId], let rowB = world.rows[b.videoId] else { continue }
            var inputs = MusicTransitionInputs(
                outgoing: MusicTransitionSide(videoId: a.videoId, durationSeconds: a.duration, analysis: rowA, youtubeLoudnessDb: rowA.youtubeLoudnessDb, vocalIntervals: world.lyricIntervals[a.videoId]),
                incoming: MusicTransitionSide(videoId: b.videoId, durationSeconds: b.duration, analysis: rowB, youtubeLoudnessDb: rowB.youtubeLoudnessDb, vocalIntervals: world.lyricIntervals[b.videoId]),
                crossfadeOn: true, settingSeconds: 7, beatMixEnabled: true, bassSwapAvailable: true, vocalGuardEnabled: true
            )
            inputs.earliestMixOutSec = 0
            out.append((a, b, MusicTransitionPlanner.plan(inputs)))
        }
        return out
    }

    /// The truth beat nearest to `t`. Past the last annotated beat (outros are not annotated) the grid is carried on at the
    /// median period of the last 16 beats for at most 15 s, and the answer is flagged as extrapolated.
    static func truthNearest(_ song: LiveSong, _ t: Double) -> (inBar: Int, delta: Double, period: Double, extrapolated: Bool)? {
        guard let near = song.nearestBeat(to: t), let last = song.beats.last else { return nil }
        let period = song.period(near: t)
        let bar = max(song.beats.map(\.inBar).max() ?? 4, 1)
        func carried(from anchor: LiveBeat, tailBeats: ArraySlice<LiveBeat>) -> (inBar: Int, delta: Double, period: Double, extrapolated: Bool)? {
            guard abs(t - anchor.time) <= 15, song.beats.count >= 8 else { return nil }
            let gaps = zip(tailBeats, tailBeats.dropFirst()).map { $1.time - $0.time }.sorted()
            let step = gaps[gaps.count / 2]
            guard step > 0.2 else { return nil }
            let k = ((t - anchor.time) / step).rounded()
            let slot = (((anchor.inBar - 1 + Int(k)) % bar) + bar) % bar + 1
            return (slot, t - (anchor.time + k * step), step, true)
        }
        if let first = song.beats.first, t < first.time - 0.25 * period {
            return carried(from: first, tailBeats: song.beats.prefix(17))
        }
        if t <= last.time + 0.25 * period {
            guard abs(near.delta) < period else { return nil }
            return (near.beat.inBar, near.delta, period, false)
        }
        return carried(from: last, tailBeats: song.beats.suffix(17))
    }

    func planningChecks() {
        let planned = plans().reduce(into: [(a: LiveSong, b: LiveSong, plan: TransitionPlan)]()) { acc, p in
            if !acc.contains(where: { $0.a.videoId == p.a.videoId && $0.b.videoId == p.b.videoId }) { acc.append(p) }
        }
        let gatePass = world.songs.filter { song in world.rows[song.videoId]?.usableGrid.map(LiveWorld.gatePasses) ?? false }.count
        let withGrid = world.songs.filter { world.rows[$0.videoId]?.usableGrid != nil }.count
        var beat = 0, smart = 0, other = 0
        var reasons: [String: Int] = [:]
        var planErrors: [Double] = []
        var inDown = 0, outDown = 0, uncovered = 0, extrapolated = 0
        var lines7: [String] = []
        var inRange: [String] = []
        var inRangeIn = 0, inRangeOut = 0, inRangeCount = 0
        for p in planned {
            switch p.plan.mode {
            case .beat: beat += 1
            case .smart: smart += 1
            default: other += 1
            }
            if p.plan.mode != .beat { reasons[p.plan.fallbackReason ?? "none (\(p.plan.mode.rawValue), \(p.plan.reason.rawValue))", default: 0] += 1 }
            guard p.plan.mode == .beat, let mo = p.plan.mixOutSec, let mi = p.plan.mixInSec else { continue }
            let rate = p.plan.incomingRate
            // The truth annotation does not span the whole file: past it the grid is extrapolated (flagged) or, too far, excluded.
            guard let na = LiveChecks.truthNearest(p.a, mo), let nb = LiveChecks.truthNearest(p.b, mi) else {
                uncovered += 1
                continue
            }
            if na.extrapolated || nb.extrapolated { extrapolated += 1 }
            if !na.extrapolated, !nb.extrapolated {
                inRangeCount += 1
                if nb.inBar == 1, abs(nb.delta) < 0.06 { inRangeIn += 1 }
                if na.inBar == 1, abs(na.delta) < 0.06 { inRangeOut += 1 }
                inRange.append("\(p.a.index) > \(p.b.index): mix-out on truth beat \(na.inBar) (\(liveF(na.delta * 1000, 0)) ms), mix-in on truth beat \(nb.inBar) (\(liveF(nb.delta * 1000, 0)) ms), planner bar positions: out bar of grid A, in bar of grid B, overlap \(p.plan.overlapBars) bars")
            }
            let err = LiveScan.wrap(na.delta - nb.delta / rate, period: na.period) * 1000
            planErrors.append(err)
            let inIsDown = nb.inBar == 1 && abs(nb.delta) < 0.06
            let outIsDown = na.inBar == 1 && abs(na.delta) < 0.06
            if inIsDown { inDown += 1 }
            if outIsDown { outDown += 1 }
            lines7.append("\(p.a.index) > \(p.b.index): phase error \(liveF(err, 1)) ms, rate \(liveF(rate, 3)), bars \(p.plan.overlapBars), incoming enters truth beat \(nb.inBar) (offset \(liveF(nb.delta * 1000, 0)) ms), outgoing leaves truth beat \(na.inBar) (offset \(liveF(na.delta * 1000, 0)) ms)")
        }
        let absErr = planErrors.map(abs)
        let planMedian = LiveScan.median(absErr)
        let planMax = absErr.max() ?? .nan
        // Engine-measured alignment over the overlaps that really played as beat mixes.
        var engineMedians: [Double] = []
        var engineLines: [String] = []
        for t in realBeat {
            let a = world.byId[t.from], b = world.byId[t.to]
            guard let a, let b else { continue }
            var errs: [Double] = []
            for s in t.samples.dropFirst(5).dropLast(5) where s.tA.isFinite && s.tB.isFinite {
                guard let na = a.nearestBeat(to: s.tA), let nb = b.nearestBeat(to: s.tB) else { continue }
                errs.append(abs(LiveScan.wrap(na.delta - nb.delta / t.rate, period: a.period(near: s.tA)) * 1000))
            }
            guard !errs.isEmpty else { continue }
            let med = LiveScan.median(errs)
            engineMedians.append(med)
            engineLines.append("real overlap \(a.index) > \(b.index): beat phase error median \(liveF(med, 1)) ms, max \(liveF(errs.max() ?? .nan, 1)) ms over \(errs.count) samples (AVPlayer item times vs truth beats)")
        }
        let measured = planErrors.count
        let downShare = measured == 0 ? 0 : Double(inDown) / Double(measured)
        let enginePass = engineMedians.allSatisfy { $0 <= 60 }
        let pass7 = measured >= 1 && planMedian <= 40 && downShare >= 0.6 && enginePass
        let alignment = LiveAlignment.load()
        var db: [LiveDownbeatResult] = []
        var aliasFreeSongs = Set<Int>()
        var skippedAmbiguous = 0, skipped68 = 0, noPhase = 0, noOverlap = 0
        for song in world.songs {
            guard let a = alignment[song.key] else { continue }
            if !a.unambiguous { skippedAmbiguous += 1; continue }
            if a.timeSignature != "4|4" { skipped68 += 1; continue }
            guard let grid = world.rows[song.videoId]?.usableGrid, grid.downbeatPhase != nil else { noPhase += 1; continue }
            if let r = LiveDownbeats.compare(song: song, grid: grid) {
                db.append(r)
                if a.aliasFree { aliasFreeSongs.insert(song.index) }
            } else { noOverlap += 1 }
        }
        let dbCompared = db.reduce(0) { $0 + $1.compared }
        let dbMatched = db.reduce(0) { $0 + $1.matched }
        let shifts = (0..<4).map { k in db.reduce(0) { $0 + $1.shiftCounts[k] } }
        let songMatches = db.filter { Double($0.matched) / Double($0.compared) >= 0.5 }.count
        let dbErrors = db.flatMap(\.timeErrorsMs).map(abs)
        func share(_ group: [LiveDownbeatResult]) -> String {
            let compared = group.reduce(0) { $0 + $1.compared }, matched = group.reduce(0) { $0 + $1.matched }
            return "\(matched) of \(compared) truth downbeats (\(liveF(compared == 0 ? 0 : Double(matched) / Double(compared) * 100, 1)) %), \(group.filter { Double($0.matched) / Double($0.compared) >= 0.5 }.count) of \(group.count) songs at least half"
        }
        let aliasFreeResults = db.filter { aliasFreeSongs.contains($0.songIndex) }
        let aliasChosenResults = db.filter { !aliasFreeSongs.contains($0.songIndex) }
        let perSong = db.map { r -> String in
            let best = r.shiftCounts.enumerated().max { $0.element < $1.element }!
            return "song \(r.songIndex): \(r.matched) of \(r.compared) truth downbeats match, dominant shift \(best.offset) beat(s) (\(best.element) of \(r.compared)), downbeat vote share \(liveF(Double(r.downbeatConfidence), 2))"
        }
        let triage7 = [
            "TRIAGE (truth artifacts removed): songs with an unambiguous alignment and a beat_this downbeat phase: \(db.count) (left out: \(skippedAmbiguous) ambiguous alias, \(skipped68) 6/8, \(noPhase) without a usable grid or phase, \(noOverlap) with no truth downbeat on a grid beat)",
            "beat_this downbeat vs truth downbeat, only inside the annotated range: \(dbMatched) of \(dbCompared) truth downbeats are grid downbeats (\(liveF(dbCompared == 0 ? 0 : Double(dbMatched) / Double(dbCompared) * 100, 1)) %); \(songMatches) of \(db.count) songs match at least half; time error median \(liveF(LiveScan.median(dbErrors), 1)) ms, max \(liveF(dbErrors.max() ?? .nan, 1)) ms",
            "alias free songs (offset under half a beat, truth bar positions need no alignment choice): \(share(aliasFreeResults)); songs whose offset is a beat or more (truth bar position depends on the alias choice): \(share(aliasChosenResults))",
            "grid downbeat sits N beats off the truth downbeat (mod 4), counted per truth downbeat: N=0 \(shifts[0]), N=1 \(shifts[1]), N=2 \(shifts[2]), N=3 \(shifts[3])",
            "planner beat plans with both mix points inside the annotated range (nothing extrapolated): \(inRangeCount) of \(beat); incoming on a truth downbeat \(inRangeIn), outgoing on a truth downbeat \(inRangeOut)",
        ] + inRange + perSong
        finish(7, "Beat mixes land on the bar", pass: pass7, [
            "planned pairs: \(planned.count) (five Mix chains from check 2, seeds 11 23 37 51 77): \(beat) beat plans, \(smart) smart plans, \(other) other",
            "refusal reasons of the non-beat plans: \(reasons.sorted { $0.key < $1.key }.map { "\($0.key) x\($0.value)" }.joined(separator: ", "))",
            "beat_this grids passing the planner gate: \(gatePass) of \(withGrid) songs with a grid (\(world.songs.count) songs)",
            "plan phase error vs truth beats: median \(liveF(planMedian, 1)) ms, max \(liveF(planMax, 1)) ms over \(measured) of \(beat) beat plans (\(extrapolated) use a truth grid carried on past the last annotated beat, at most 15 s; \(uncovered) excluded: mix point farther out)",
            "incoming song enters on a truth downbeat: \(inDown) of \(measured); outgoing leaves on a downbeat: \(outDown) of \(measured) (thresholds: median <= 40 ms, downbeat share >= 60%, real overlaps median <= 60 ms)",
            "real engine overlaps measured as beat mixes: \(realBeat.count); \(engineMedians.isEmpty ? "none, so only the planned alignment is measured" : "see below")",
        ] + engineLines + lines7 + triage7)

        // Check 8
        let budget = MusicVocalGuard.budgetSec
        var evaluated = 0, paddedOver = 0, rawOver = 0, guardActions: [String: Int] = [:], violations = 0
        var maxPadded = 0.0, maxRaw = 0.0
        var lines8: [String] = []
        for p in planned {
            guard let la = world.lyricLines[p.a.videoId], let lb = world.lyricLines[p.b.videoId],
                  let ia = world.lyricIntervals[p.a.videoId], let ib = world.lyricIntervals[p.b.videoId] else { continue }
            evaluated += 1
            let plan = p.plan
            let out: Double, inn: Double, rate: Double, length: Double
            if plan.mode == .beat, let mo = plan.mixOutSec, let mi = plan.mixInSec {
                out = mo; inn = mi; rate = plan.incomingRate; length = plan.overlapSec
            } else {
                length = plan.fadeSeconds
                out = plan.fadeStartSec ?? ((plan.outgoingEndSec ?? p.a.duration) - length)
                inn = plan.incomingStartSec; rate = 1
            }
            guard length > 0 else { lines8.append("\(p.a.index) > \(p.b.index): no overlap (\(plan.mode.rawValue))"); continue }
            let padded = MusicVocalGuardIntervals.collisionSec(a: ia, b: ib, outroStartA: 0, introEndB: 0, outStart: out, inStart: inn, rate: rate, length: length)
            let raw = MusicVocalGuardIntervals.collisionSec(a: LiveChecks.rawIntervals(la, p.a.duration), b: LiveChecks.rawIntervals(lb, p.b.duration), outroStartA: 0, introEndB: 0, outStart: out, inStart: inn, rate: rate, length: length)
            maxPadded = max(maxPadded, padded); maxRaw = max(maxRaw, raw)
            if padded > budget + 0.05 { paddedOver += 1; if plan.vocalAction != "min" { violations += 1 } }
            if raw > budget + 0.05 { rawOver += 1 }
            if let action = plan.vocalAction { guardActions[action, default: 0] += 1 }
            lines8.append("\(p.a.index) > \(p.b.index): \(plan.mode.rawValue), overlap \(liveF(length)) s, both-singing padded \(liveF(padded)) s, raw lines \(liveF(raw)) s, guard \(plan.vocalAction ?? "none") (before \(plan.vocalBeforeSec.map { liveF($0) } ?? "-") s, planner says \(plan.vocalCollisionSec.map { liveF($0) } ?? "-") s)")
        }
        // The engine runs also logged the guard.
        let engineGuard = allRealRuns.filter { $0.line("transition_vocal_guard") != nil }.count
        let lyricPairs = evaluated
        let pass8 = lyricPairs > 0 && violations == 0
        finish(8, "Vocal guard: no two singers beyond the 2 s budget", pass: pass8, [
            "pairs with synced lyrics on both sides: \(lyricPairs) of \(planned.count) planned; \(world.lyricLines.count) of \(world.songs.count) songs have synced lyrics, the rest use the structural proxy",
            "collisions above the \(liveF(budget)) s budget: \(paddedOver) with the guard's padded intervals (max \(liveF(maxPadded)) s), \(rawOver) with the raw line times (max \(liveF(maxRaw)) s); violations not explained by the guard's own \"min\" fallback: \(violations)",
            "guard actions in the planned pairs: \(guardActions.isEmpty ? "none" : guardActions.sorted { $0.key < $1.key }.map { "\($0.key) x\($0.value)" }.joined(separator: ", ")); guard lines in the real engine runs: \(engineGuard)",
        ] + lines8)
    }

    /// Singing intervals without the guard's padding: a line runs to its end or the next line, at most 8 s.
    static func rawIntervals(_ lines: [LyricLine], _ duration: Double) -> [ClosedRange<Double>] {
        let sorted = lines.filter { $0.time.isFinite }.sorted { $0.time < $1.time }
        var out: [ClosedRange<Double>] = []
        for (i, line) in sorted.enumerated() where !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let next = i + 1 < sorted.count ? sorted[i + 1].time : line.time + 8
            let end = min(max(line.end ?? next, line.time), line.time + 8, duration)
            if end > line.time { out.append(line.time...end) }
        }
        return out
    }
}

private func glideNote(_ t: LiveTransition) -> String {
    guard abs(t.rate - 1) > 0.0005 else { return "" }
    return t.glideSeen ? " (captured through the whole glide back to 1)" : " (glide NOT seen to its end)"
}
