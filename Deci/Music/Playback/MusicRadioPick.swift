// Deci/Music/Playback/MusicRadioPick.swift
import Foundation

/// Which of the first radio songs should play next when songs blend: the one that mixes best out of the song it follows.
/// Pure scoring; the service decides when it runs and where the song goes.
nonisolated enum MusicRadioPick {
    /// How many radio songs, counted from the first one still ahead, are looked at.
    static let candidateCount = 10

    struct Choice: Equatable, Sendable {
        var videoId: String
        var score: Double
    }

    /// The profile carries something to score with (a tempo, a key or an energy).
    static func isKnown(_ profile: MusicMixProfile) -> Bool {
        profile.bpm != nil || profile.camelot != nil || profile.energy != nil
    }

    /// How well `candidate` mixes out of `anchor`, from the same score Mix orders by.
    static func score(of candidate: MusicMixProfile, after anchor: MusicMixProfile) -> Double {
        MusicMixScore.score(from: MusicMixCompact(anchor), to: MusicMixCompact(candidate), allowLift: false)
    }

    /// The candidate with the best score out of `anchor`. Only songs with a stored analysis are judged: a song nothing is
    /// known about is never picked over one that is. Ties go to the earlier song, so the radio's own order decides them.
    /// Nil when there is nothing to score from: the song it follows is unknown, or no candidate is known.
    static func best(of candidates: [MusicMixProfile], after anchor: MusicMixProfile) -> Choice? {
        guard isKnown(anchor) else { return nil }
        var best: Choice?
        for candidate in candidates where isKnown(candidate) {
            let value = score(of: candidate, after: anchor)
            if best == nil || value > (best?.score ?? 0) + 1e-9 { best = Choice(videoId: candidate.videoId, score: value) }
        }
        return best
    }
}
