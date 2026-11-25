// Deci/Music/Playback/MusicTempoStretch.swift
// Tempo match. A DJ nudges the incoming song to the outgoing tempo for the blend and lets it go back to its own tempo
// afterwards. Writing a rate on a playing deck opens a gap in the output, so the tempo is built into the incoming deck's
// item instead: an AVMutableComposition of the song's own file, played at rate 1 from start to end.
//
//     [0, mixIn] native + [the overlap] at the matched rate + a glide, one bar a step, back to 1 + [the rest] native
//
// The last piece is never scaled: after the glide the song plays at its own tempo to its end (wjyijr).
//
// Two things keep the beats on the grid (measured on clicks through the tap, residual under 1 ms):
//   - the spectral stretcher truncates a rate to a whole number of 1/1024ths, so every rate is snapped to k/1024, and
//   - every scaled length is rounded down to the 48 kHz sample grid.
// Every seam is 3/8 of a beat after a beat, so none lands on a hit (the one at the mix-in does, where the fade is still silent).
//
// Only a local file is ever composed. `MusicTempoMap` is the engine's time map: everything above the engine sees song time.

import Foundation
import AVFoundation
import CoreMedia

nonisolated enum MusicTempoStretch {
    /// The sample grid every piece is snapped to.
    static let timescale: Int32 = 48_000
    /// The stretcher's rate resolution: a rate that is not k/1024 plays at the next one below it and drifts.
    static let rateSteps = 1024.0
    /// How far from its own tempo a song may be taken.
    static let maxRateError = 0.05
    /// The song goes back to its own tempo across this many of its bars, one step a bar.
    static let glideBars = 8
    /// How far after a beat every boundary sits, in beats.
    static let seamBeats = 0.375
    /// The rest of the song, after the glide, is at least this long.
    static let minRestSec = 1.0

    static func snapRate(_ rate: Double) -> Double { (rate * rateSteps).rounded() / rateSteps }

    /// Whether the incoming song could be taken to the outgoing one's tempo. A song whose analysis is not in yet still may; one
    /// without a beat to trust never can.
    static func mayMatch(outgoing: MusicAnalysis?, incoming: MusicAnalysis?) -> Bool {
        let grids = [outgoing, incoming].compactMap { $0 }.map { row in row.usableGrid.flatMap { MusicBeatPlanner.trusted($0) ? $0 : nil } }
        guard grids.allSatisfy({ $0 != nil }) else { return false }
        guard let out = outgoing?.usableGrid, let into = incoming?.usableGrid else { return true }
        return MusicBeatPlanner.tempoMatch(outBpm: out.bpm, inBpm: into.bpm, tolerance: maxRateError) != nil
    }

    /// A tempo match of the incoming song, in song seconds.
    struct Spec: Equatable, Sendable {
        /// Where the overlap starts in the song.
        let mixIn: Double
        /// Song seconds a wall second in the overlap, a multiple of 1/1024.
        let rate: Double
        /// How much of the song the overlap plays.
        let overlap: Double
        /// One bar of the song.
        let bar: Double
        let glideBars: Int

        init(mixIn: Double, rate: Double, overlap: Double, bar: Double, glideBars: Int = MusicTempoStretch.glideBars) {
            self.mixIn = mixIn
            self.rate = MusicTempoStretch.snapRate(rate)
            self.overlap = overlap
            self.bar = bar
            self.glideBars = glideBars
        }

        /// The song time from which the song plays at its own tempo.
        var end: Double { mixIn + overlap + MusicTempoStretch.seamBeats * bar / 4 + Double(glideBars) * bar }

        var isValid: Bool {
            [mixIn, rate, overlap, bar].allSatisfy { $0.isFinite } && mixIn >= 0 && overlap > 0 && bar > 0
                && rate != 1 && abs(rate - 1) <= MusicTempoStretch.maxRateError + 0.5 / MusicTempoStretch.rateSteps
                && (0...64).contains(glideBars)
        }
    }

    /// One stretch of the song at one rate, in ticks of `timescale`. `itemTicks` is how long it plays for.
    struct Piece: Equatable, Sendable {
        let start: Int64
        let end: Int64
        let rate: Double
        let itemTicks: Int64

        var songTicks: Int64 { end - start }
        var isNative: Bool { rate == 1 }
    }

    enum Failure: Error, Equatable {
        case remote, badSpec, rangeOutsideAsset, noAudio
    }

    static func ticks(_ seconds: Double) -> Int64 { Int64((seconds * Double(timescale)).rounded()) }

    /// The tempo match a plan asks for; nil for every plan that plays its incoming song at its own tempo.
    static func spec(from plan: TransitionPlan?) -> Spec? {
        guard let plan, plan.mode == .beat, plan.stretchRate != 1, let mixIn = plan.mixInSec,
              plan.overlapSec > 0, plan.stretchBarSec > 0 else { return nil }
        let spec = Spec(
            mixIn: mixIn, rate: plan.stretchRate, overlap: plan.overlapSec * plan.stretchRate, bar: plan.stretchBarSec,
            glideBars: plan.stretchGlideBars
        )
        return spec.isValid ? spec : nil
    }

    /// The pieces of a song that is `songEnd` seconds long. Neighbours at the same rate are one piece; the last one is
    /// always native. Empty when the spec is not valid or the song is too short for it.
    static func pieces(_ spec: Spec, songEnd: Double) -> [Piece] {
        guard spec.isValid, songEnd.isFinite, spec.end + minRestSec <= songEnd else { return [] }
        var cuts: [(end: Int64, rate: Double)] = []
        func add(upTo seconds: Double, rate: Double) {
            let end = ticks(seconds)
            guard end > (cuts.last?.end ?? 0) else { return }
            if let last = cuts.last, last.rate == rate {
                cuts[cuts.count - 1].end = end
            } else {
                cuts.append((end, rate))
            }
        }
        add(upTo: spec.mixIn, rate: 1)
        var at = spec.mixIn + spec.overlap + seamBeats * spec.bar / 4
        add(upTo: at, rate: spec.rate)
        for step in 0..<spec.glideBars {
            let share = Double(step + 1) / Double(spec.glideBars + 1)
            at += spec.bar
            add(upTo: at, rate: snapRate(spec.rate + (1 - spec.rate) * share))
        }
        add(upTo: songEnd, rate: 1)
        var out: [Piece] = []
        var start: Int64 = 0
        for cut in cuts {
            let song = cut.end - start
            // Rounded down: a length that rounds up would put the rate just under k/1024, and the stretcher a whole step off.
            let item = cut.rate == 1 ? song : Int64((Double(song) / cut.rate).rounded(.down))
            out.append(Piece(start: start, end: cut.end, rate: cut.rate, itemTicks: item))
            start = cut.end
        }
        return out
    }

    /// The composition for `spec` over the audio track of `asset`, and its time map. `songDuration` is the song's own length
    /// (the stream's exact one: a fragmented file reads as twice its length).
    /// Throws for a remote origin, a spec that is not valid, or a song that is too short for it.
    static func composition(
        asset: AVAsset, spec: Spec, songDuration: Double, origin: ResolvedStream.Origin
    ) async throws -> (composition: AVMutableComposition, map: MusicTempoMap) {
        guard MusicLoopExtend.isLocal(origin) else { throw Failure.remote }
        guard spec.isValid, songDuration.isFinite, songDuration > 0 else { throw Failure.badSpec }
        guard let source = try await asset.loadTracks(withMediaType: .audio).first else { throw Failure.noAudio }
        let range = try await source.load(.timeRange)
        let available = range.end.seconds
        let end = min(songDuration, available.isFinite ? available : songDuration)
        let pieces = Self.pieces(spec, songEnd: end)
        guard let map = MusicTempoMap(pieces) else { throw Failure.rangeOutsideAsset }
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw Failure.noAudio }
        func time(_ ticks: Int64) -> CMTime { CMTime(value: ticks, timescale: timescale) }
        var at: Int64 = 0
        for piece in pieces {
            try track.insertTimeRange(
                CMTimeRange(start: time(piece.start), end: time(piece.end)), of: source, at: time(at))
            if !piece.isNative {
                track.scaleTimeRange(
                    CMTimeRange(start: time(at), duration: time(piece.songTicks)), toDuration: time(piece.itemTicks))
            }
            at += piece.itemTicks
        }
        return (composition, map)
    }
}

/// Composition time to song time and back for a tempo-matched deck: straight lines, one a piece. Up to the mix-in the two
/// are the same, and after the glide song time runs a second a second, shifted.
nonisolated struct MusicTempoMap: Equatable, Sendable {
    private struct Segment: Equatable, Sendable {
        let song: Double
        let item: Double
        /// Song seconds an item second, exactly 1 for a native piece.
        let slope: Double
    }

    private let segments: [Segment]
    /// The song time from which the song plays at its own tempo to its end.
    let stretchEnd: Double

    /// nil without pieces, or when the last one is not native: such a song would never get back to its own tempo.
    init?(_ pieces: [MusicTempoStretch.Piece]) {
        guard let last = pieces.last, last.isNative, pieces.count > 1 else { return nil }
        let scale = Double(MusicTempoStretch.timescale)
        var item: Int64 = 0
        var segments: [Segment] = []
        for piece in pieces {
            guard piece.itemTicks > 0 else { return nil }
            segments.append(Segment(
                song: Double(piece.start) / scale, item: Double(item) / scale,
                slope: piece.isNative ? 1 : Double(piece.songTicks) / Double(piece.itemTicks)
            ))
            item += piece.itemTicks
        }
        self.segments = segments
        stretchEnd = Double(last.start) / scale
    }

    /// The song time heard at composition (item) time `item`.
    func songTime(_ item: Double) -> Double {
        guard let segment = segments.last(where: { $0.item <= item }) ?? segments.first else { return item }
        return segment.song + (item - segment.item) * segment.slope
    }

    /// The composition time of song time `song`.
    func itemTime(_ song: Double) -> Double {
        guard let segment = segments.last(where: { $0.song <= song }) ?? segments.first else { return song }
        return segment.item + (song - segment.song) / segment.slope
    }
}

extension TransitionPlan {
    /// The plan as one that plays its incoming song as it is: no loop, no tempo match.
    nonisolated mutating func clearItemEdit() {
        style = .longBlend
        loopStartSec = 0
        loopBars = 0
        loopLengthSec = 0
        loopRepeats = 0
        stretchRate = 1
        stretchGlideBars = 0
        stretchBarSec = 0
    }
}

/// What a standby's item is built as when it is not the plain song: a loop extend or a tempo match, never both.
nonisolated enum MusicItemEdit: Equatable, Sendable {
    case loop(MusicLoopExtend.Spec)
    case stretch(MusicTempoStretch.Spec)

    /// The edit a plan asks for; nil for a plan whose incoming song plays as it is. A loop wins: the planner never asks for both.
    static func edit(from plan: TransitionPlan?) -> MusicItemEdit? {
        if let loop = MusicLoopExtend.spec(from: plan) { return .loop(loop) }
        return MusicTempoStretch.spec(from: plan).map(MusicItemEdit.stretch)
    }

    var isValid: Bool {
        switch self {
        case .loop(let spec): spec.isValid
        case .stretch(let spec): spec.isValid
        }
    }

    /// The composition of the edit over `asset` with its time map.
    func composition(
        asset: AVAsset, songDuration: Double, origin: ResolvedStream.Origin
    ) async throws -> (composition: AVMutableComposition, map: MusicItemMap) {
        switch self {
        case .loop(let spec):
            let built = try await MusicLoopExtend.composition(
                asset: asset, spec: spec, songDuration: songDuration, origin: origin)
            return (built, .loop(MusicLoopMap(spec)))
        case .stretch(let spec):
            let built = try await MusicTempoStretch.composition(
                asset: asset, spec: spec, songDuration: songDuration, origin: origin)
            return (built.composition, .stretch(built.map))
        }
    }
}

/// The time map of a deck whose item is an edit of its song.
nonisolated enum MusicItemMap: Equatable, Sendable {
    case loop(MusicLoopMap)
    case stretch(MusicTempoMap)

    func songTime(_ item: Double) -> Double {
        switch self {
        case .loop(let map): map.songTime(item)
        case .stretch(let map): map.songTime(item)
        }
    }

    func itemTime(_ song: Double) -> Double {
        switch self {
        case .loop(let map): map.itemTime(song)
        case .stretch(let map): map.itemTime(song)
        }
    }

    var loop: MusicLoopMap? { if case .loop(let map) = self { map } else { nil } }
    var stretch: MusicTempoMap? { if case .stretch(let map) = self { map } else { nil } }
}
