// Deci/Music/Playback/MusicMixProfile+Analysis.swift
// Builds the mix engine's plain profile from a stored analysis row. Kept apart so the engine itself touches no app types.

import Foundation

extension MusicMixProfile {
    /// LUFS range that maps onto 0...1 for the intro and outro room estimate (same span the energy rating uses).
    private static let quietLufs = -30.0
    private static let loudLufs = -5.0

    /// `analysis` nil (no row yet) gives a profile of unknowns, which the engine scores neutral and never blocks.
    @MainActor
    init(videoId: String, artist: String, analysis: MusicAnalysis?) {
        guard let analysis else {
            self.init(videoId: videoId, artist: artist)
            return
        }
        let grid = analysis.usableGrid
        let key = analysis.keyInfoValue
        func unit(_ lufs: Double?) -> Float? {
            guard let lufs, lufs.isFinite else { return nil }
            return Float(max(0, min(1, (lufs - Self.quietLufs) / (Self.loudLufs - Self.quietLufs))))
        }
        let trusted = grid.map {
            $0.beatConfidence >= MusicBeatPlanner.minConfidence && $0.intervalSpread <= MusicBeatPlanner.maxIntervalSpread
                && abs($0.driftSec) <= MusicBeatPlanner.maxDriftSec
        } ?? false
        self.init(
            videoId: videoId, artist: artist, bpm: grid?.bpm, gridTrusted: trusted,
            camelot: key?.trustedCamelot.flatMap { MusicCamelot(code: $0) }, energy: key?.energy,
            introEnergy: unit(analysis.introLUFS), outroEnergy: unit(analysis.outroLUFS))
    }
}
