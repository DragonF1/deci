// DeciTests/Music/LiveChecks/LiveDownbeats.swift
// Check 7 triage: beat_this downbeats against the Harmonix truth downbeats, without the two truth artifacts. Songs whose
// truth alignment is ambiguous by a beat (alias flag with margin under 0.5) and 6/8 songs are left out, and only truth
// downbeats inside the annotated range count, so nothing is extrapolated. The truth bar positions of a song whose offset
// is a whole beat or more depend on an alias choice made by heuristics (see LiveAlignment.aliasFree), so the triage also
// reports the alias free songs alone.

import Foundation
@testable import Deci

nonisolated struct LiveAlignment: Sendable {
    var flag: String?
    var margin: Double
    var timeSignature: String
    var offsetSec: Double
    var bpm: Double

    var unambiguous: Bool { flag == nil || margin >= 0.5 }

    /// The truth was moved onto the YouTube audio by an offset found by correlation, and any whole number of beats
    /// aliases to the same beat score. Only an offset under half a beat needs no alias choice, so the truth bar
    /// positions of those songs are the only ones that do not depend on the alignment heuristics.
    var aliasFree: Bool { bpm > 0 && abs(offsetSec) < 0.5 * 60 / bpm }

    static func load() -> [String: LiveAlignment] {
        guard let data = try? Data(contentsOf: LiveDirs.manifest),
              let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [:] }
        var out: [String: LiveAlignment] = [:]
        for item in json {
            guard let key = item["id"] as? String else { continue }
            out[key] = LiveAlignment(
                flag: item["alias_flag"] as? String, margin: (item["alias_margin"] as? NSNumber)?.doubleValue ?? 0,
                timeSignature: (item["ts"] as? String) ?? "4|4",
                offsetSec: (item["offset_sec"] as? NSNumber)?.doubleValue ?? 0,
                bpm: (item["bpm"] as? NSNumber)?.doubleValue ?? 0
            )
        }
        return out
    }
}

nonisolated struct LiveDownbeatResult: Sendable {
    var songIndex: Int
    var downbeatConfidence: Float = 0
    var compared = 0
    var matched = 0
    /// How many beats the grid's downbeat sits after the truth downbeat, mod 4, counted per truth downbeat.
    var shiftCounts = [0, 0, 0, 0]
    var timeErrorsMs: [Double] = []
}

nonisolated enum LiveDownbeats {
    /// One song: every truth downbeat inside the annotated range, against the grid's nearest beat.
    static func compare(song: LiveSong, grid: MusicBeatGrid) -> LiveDownbeatResult? {
        guard let phase = grid.downbeatPhase, let first = song.beats.first, let last = song.beats.last else { return nil }
        var result = LiveDownbeatResult(songIndex: song.index, downbeatConfidence: grid.downbeatConfidence)
        for beat in song.beats where beat.inBar == 1 && beat.time >= first.time && beat.time <= last.time {
            let k = Int(((beat.time - grid.anchorSec) / grid.periodSec).rounded())
            let err = beat.time - grid.beatTime(k)
            // The grid beat must be the truth beat (within a quarter period); a wider miss is a beat finder error, not a bar one.
            guard abs(err) < 0.25 * grid.periodSec else { continue }
            result.compared += 1
            let shift = (((phase - k) % 4) + 4) % 4
            // The grid says beat k is a downbeat when k mod 4 == phase: shift 0 is a match.
            result.shiftCounts[shift] += 1
            if shift == 0 { result.matched += 1 }
            result.timeErrorsMs.append(err * 1000)
        }
        return result.compared > 0 ? result : nil
    }
}
