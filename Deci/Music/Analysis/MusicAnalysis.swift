// Deci/Music/Analysis/MusicAnalysis.swift
// One analysed song: measured edges and loudness, YouTube's own numbers, the energy curve, and
// slots reserved for later tiers. Pure value types, no I/O.

import Foundation

struct MusicAnalysis: Sendable, Equatable {
    /// Bump to have older entries redone quietly in the background. 3: the beat finder measures bass onsets without
    /// depending on its own prediction and locks the phase over the whole period (3b accuracy P1). 4: the downbeat comes
    /// from kick, back-beat, harmony and section cues with a held-out check (3b accuracy P2). 5: the row carries a musical
    /// key and an energy rating (tier 4); an older row has neither until the sweep redoes it. Version 5 is also the
    /// first with beat_this grids (3d); it is unreleased and the installed build writes 4, so every installed row is
    /// re-analysed into one anyway and no further bump is needed.
    static let currentVersion = 5
    /// First version whose rows may carry a beat grid; older rows keep their fade fields but have no grid. A version 2
    /// or 3 grid stays usable (an unreadable file drops its old bass-only downbeat guess, a re-analysis replaces it) until the background sweep replaces it with a version 4 one.
    static let gridVersion = 2
    /// One UInt8 step of the energy curve, in dB.
    static let energyStepDb: Float = 0.5
    /// Energy code 0.
    static let energyFloorDb: Float = -90
    static let energyBlockSeconds = 0.1
    /// Highest code the analyzer produces (0 dBFS).
    static let energyMaxCode: UInt8 = 180

    /// The fingerprint of the audio that was analysed.
    struct Format: Sendable, Equatable {
        /// "mp4a.40.2"; empty when unknown (a local file).
        var codec: String
        /// 0 means unknown (a downloaded file does not know its itag).
        var itag: Int
        /// Exact duration from approxDurationMs.
        var durationMs: Int

        /// Codec equal (case-insensitive, empty matches anything), duration within 1 ms, itag equal unless either is 0.
        func matches(_ other: Format) -> Bool {
            let codecMatches = codec.isEmpty || other.codec.isEmpty
                || codec.caseInsensitiveCompare(other.codec) == .orderedSame
            let itagMatches = itag == 0 || other.itag == 0 || itag == other.itag
            return codecMatches && itagMatches && abs(durationMs - other.durationMs) <= 1
        }
    }

    enum Source: String, Sendable, Equatable {
        case playbackCache, download, backgroundCache
    }

    var videoId: String
    var version: Int
    var format: Format
    var analyzedAt: Date
    var source: Source

    // Measured.
    /// Seconds; first 10 ms window above -60 dBFS (0 if never silent).
    var silenceStart: Double
    /// Seconds; end of the last window above -60 dBFS (the duration if none).
    var silenceEnd: Double
    var introEnd: Double
    var outroStart: Double
    /// BS.1770-4; -infinity when everything was gated out (stored as NULL).
    var integratedLUFS: Double
    /// Sample peak in dBFS, not true peak. Non-finite values are stored as -200.
    var samplePeakDb: Double
    /// Gated mean loudness of the first 8 s after `silenceStart`.
    var introLUFS: Double?
    /// Same for the last 8 s before `silenceEnd`.
    var outroLUFS: Double?
    /// One code per 100 ms block, RMS dBFS, (dB + 90) * 2 clamped to 0...180.
    var energy: [UInt8]

    // YouTube's own numbers (playerConfig.audioConfig).
    var youtubeLoudnessDb: Double?
    var youtubePerceptualLoudnessDb: Double?

    // Reserved for later tiers; nil in 2a.
    var beatGrid: Data? = nil
    var keyInfo: Data? = nil
    /// The nudge, remembered forever. No UI in 2a.
    var userMixPointMs: Int? = nil

    /// The stored beat grid, only from a row that is at least `gridVersion` and decodes cleanly.
    var usableGrid: MusicBeatGrid? {
        guard version >= Self.gridVersion, let beatGrid else { return nil }
        return MusicBeatGrid.decode(beatGrid)
    }

    /// The stored key and energy, only from a row that is at least version 5 and decodes cleanly.
    nonisolated var keyInfoValue: MusicKeyInfo? {
        guard version >= 5, let keyInfo else { return nil }
        return MusicKeyInfo.decode(keyInfo)
    }

    /// Camelot code when the detector was sure enough (confidence 0.10 or more), else nil (unknown key).
    nonisolated var trustedCamelot: String? { keyInfoValue?.trustedCamelot }

    /// RMS level of block `block` in dBFS; -infinity when out of range.
    func energyDb(at block: Int) -> Float {
        guard energy.indices.contains(block) else { return -.infinity }
        return Float(energy[block]) * Self.energyStepDb + Self.energyFloorDb
    }

    /// The code for a level in dBFS, clamped to 0...180. Non-finite levels give 0.
    static func energyCode(forDb db: Float) -> UInt8 {
        guard db.isFinite else { return db == .infinity ? energyMaxCode : 0 }
        let code = ((db - energyFloorDb) / energyStepDb).rounded()
        return UInt8(max(0, min(Float(energyMaxCode), code)))
    }
}

/// The energy curve BLOB: byte 0 payload version (1), bytes 1...4 block count as UInt32 little
/// endian, then one UInt8 code per block.
enum MusicAnalysisPayload {
    static let version: UInt8 = 1
    private static let headerSize = 5

    static func encode(_ codes: [UInt8]) -> Data {
        var data = Data(capacity: headerSize + codes.count)
        data.append(version)
        withUnsafeBytes(of: UInt32(clamping: codes.count).littleEndian) { data.append(contentsOf: $0) }
        data.append(contentsOf: codes)
        return data
    }

    /// nil for a short header, an unknown version, or a count that disagrees with the data length.
    static func decode(_ data: Data) -> [UInt8]? {
        let bytes = [UInt8](data)
        guard bytes.count >= headerSize, bytes[0] == version else { return nil }
        let count = bytes[1..<5].enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        guard bytes.count == headerSize + count else { return nil }
        return Array(bytes[headerSize...])
    }
}
