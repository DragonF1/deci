// Deci/Music/Playback/MusicLoopExtend.swift
// Tier 4b P2b: loop extend. When the incoming song's intro is too short to mix under, a few bars of it are looped
// before the song goes on. The incoming deck plays an AVMutableComposition of the song's own file:
//
//     [0, loopEnd] + repeats x [loopStart, loopEnd] + [loopEnd, duration]
//
// so the song is `repeats x loopLength` longer than it is. The 3b spike measured the seams on real songs (offline decode
// and live through the tap): constant timing offset under 1.2 ms, no step above the song's own, no dropout.
//
// Only a local file is ever composed (the track cache or a download): a remote stream is never read this way.
// `MusicLoopMap` is the engine's time map: everything above the engine sees song time only.

import Foundation
import AVFoundation
import CoreMedia

nonisolated enum MusicLoopExtend {
    /// The sample grid every seam is snapped to, so a loop is a whole number of frames.
    static let timescale: Int32 = 48_000
    static let maxRepeats = 8

    static func snap(_ seconds: Double) -> Double { (seconds * Double(timescale)).rounded() / Double(timescale) }

    /// A loop of the incoming song, in song seconds. The numbers are snapped to the sample grid.
    struct Spec: Equatable, Sendable {
        let loopStart: Double
        let loopLength: Double
        let repeats: Int

        init(loopStart: Double, loopLength: Double, repeats: Int) {
            self.loopStart = MusicLoopExtend.snap(loopStart)
            self.loopLength = MusicLoopExtend.snap(loopLength)
            self.repeats = repeats
        }

        var loopEnd: Double { loopStart + loopLength }
        /// How much longer the composition is than the song.
        var extensionSec: Double { Double(repeats) * loopLength }

        var isValid: Bool {
            [loopStart, loopLength].allSatisfy { $0.isFinite } && loopStart >= 0 && loopLength > 0
                && (1...MusicLoopExtend.maxRepeats).contains(repeats)
        }
    }

    enum Failure: Error, Equatable {
        case remote, badSpec, rangeOutsideAsset, noAudio
    }

    /// Only a file on this Mac can be composed.
    static func isLocal(_ origin: ResolvedStream.Origin) -> Bool { origin != .network }

    /// The loop a plan asks for; nil for every plan that is not a loop extend.
    static func spec(from plan: TransitionPlan?) -> Spec? {
        guard let plan, plan.style == .loopExtend, plan.loopRepeats > 0, plan.loopLengthSec > 0 else { return nil }
        let spec = Spec(loopStart: plan.loopStartSec, loopLength: plan.loopLengthSec, repeats: plan.loopRepeats)
        return spec.isValid ? spec : nil
    }

    /// The composition for `spec` over the audio track of `asset`. `songDuration` is the song's own length (the stream's
    /// exact one: a fragmented file reads as twice its length), which the part after the loop is held to.
    /// Throws for a remote origin, a spec that is not valid, or a loop outside the audio.
    static func composition(
        asset: AVAsset, spec: Spec, songDuration: Double, origin: ResolvedStream.Origin
    ) async throws -> AVMutableComposition {
        guard isLocal(origin) else { throw Failure.remote }
        guard spec.isValid, songDuration.isFinite, songDuration > 0 else { throw Failure.badSpec }
        // A local file: the track list and its range are loaded from the header, off the caller's actor.
        guard let source = try await asset.loadTracks(withMediaType: .audio).first else { throw Failure.noAudio }
        let range = try await source.load(.timeRange)
        let available = range.end.seconds
        let end = min(snap(songDuration), available.isFinite ? available : snap(songDuration))
        guard spec.loopEnd < end else { throw Failure.rangeOutsideAsset }
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw Failure.noAudio }
        func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: timescale) }
        var at = 0.0
        try track.insertTimeRange(CMTimeRange(start: .zero, end: time(spec.loopEnd)), of: source, at: time(at))
        at = spec.loopEnd
        for _ in 0..<spec.repeats {
            try track.insertTimeRange(CMTimeRange(start: time(spec.loopStart), end: time(spec.loopEnd)), of: source, at: time(at))
            at += spec.loopLength
        }
        try track.insertTimeRange(CMTimeRange(start: time(spec.loopEnd), end: time(end)), of: source, at: time(at))
        return composition
    }
}

/// Composition time to song time and back for one deck's item. Song time is held at the loop's end while the repeats play, and
/// shifted back by the extension once they are over.
nonisolated struct MusicLoopMap: Equatable, Sendable {
    let loopEnd: Double
    let extensionSec: Double

    init(_ spec: MusicLoopExtend.Spec) {
        loopEnd = spec.loopEnd
        extensionSec = spec.extensionSec
    }

    /// The song time heard at composition (item) time `item`.
    func songTime(_ item: Double) -> Double {
        if item <= loopEnd { return item }
        if item < loopEnd + extensionSec { return loopEnd }
        return item - extensionSec
    }

    /// The composition time of song time `song`: before the loop's end it is the same, after it the extension is added.
    func itemTime(_ song: Double) -> Double {
        song < loopEnd ? song : song + extensionSec
    }
}
