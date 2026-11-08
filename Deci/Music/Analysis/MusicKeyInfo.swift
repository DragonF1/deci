// Deci/Music/Analysis/MusicKeyInfo.swift
// A song's musical key and energy rating, and the BLOB it is stored as. Pure value type, no I/O.

import Foundation

nonisolated struct MusicKeyInfo: Sendable, Equatable {
    /// Below this confidence the key counts as unknown to anything that plans with it.
    static let minTrustedConfidence: Float = 0.2

    /// 0...11, C = 0.
    var tonic: Int
    var isMinor: Bool
    /// Best key correlation minus the second best.
    var confidence: Float
    /// 0...1, see `MusicEnergyRating`.
    var energy: Float

    /// Camelot wheel code, "8B" for C major and "8A" for A minor.
    var camelot: String {
        let t = ((tonic % 12) + 12) % 12
        let majorTonic = isMinor ? (t + 3) % 12 : t
        let number = (majorTonic * 7 % 12 + 7) % 12 + 1
        return "\(number)\(isMinor ? "A" : "B")"
    }

    /// The code, or nil when the detector was not sure enough.
    var trustedCamelot: String? { confidence >= Self.minTrustedConfidence ? camelot : nil }

    private static let payloadVersion: UInt8 = 1
    private static let size = 11

    /// Byte 0 payload version (1), byte 1 tonic, byte 2 minor flag, then confidence and energy as Float32 little endian.
    func encode() -> Data {
        var data = Data(capacity: Self.size)
        data.append(Self.payloadVersion)
        data.append(UInt8(clamping: tonic))
        data.append(isMinor ? 1 : 0)
        withUnsafeBytes(of: confidence.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: energy.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        return data
    }

    /// nil for a wrong length, an unknown version, an out-of-range tonic or flag, or a non-finite number.
    static func decode(_ data: Data) -> MusicKeyInfo? {
        let bytes = [UInt8](data)
        guard bytes.count == size, bytes[0] == payloadVersion, bytes[1] < 12, bytes[2] <= 1 else { return nil }
        func float(_ start: Int) -> Float {
            let bits = (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[start + $1]) << (8 * UInt32($1)) }
            return Float(bitPattern: bits)
        }
        let confidence = float(3), energy = float(7)
        guard confidence.isFinite, energy.isFinite else { return nil }
        return MusicKeyInfo(tonic: Int(bytes[1]), isMinor: bytes[2] == 1, confidence: confidence, energy: energy)
    }
}

/// One 0...1 number for how driving a song is: loudness, how often the level jumps, brightness and tempo.
nonisolated enum MusicEnergyRating {
    /// Rising edges of the 100 ms energy curve of at least this many dB count as onsets.
    static let onsetStepDb: Float = 3

    static func rate(lufs: Double, bpm: Double?, onsetRate: Double, centroidHz: Double) -> Float {
        func unit(_ value: Double, _ low: Double, _ high: Double) -> Double {
            guard value.isFinite else { return value == .infinity ? 1 : 0 }
            return max(0, min(1, (value - low) / (high - low)))
        }
        let loudness = unit(lufs, -30, -5)
        let onsets = unit(onsetRate, 0, 3)
        let brightness = unit(centroidHz, 500, 5000)
        let result: Double
        if let bpm, bpm.isFinite {
            result = 0.4 * loudness + 0.25 * onsets + 0.2 * brightness + 0.15 * unit(bpm, 60, 180)
        } else {
            // No tempo: spread its weight over the rest.
            result = (0.4 * loudness + 0.25 * onsets + 0.2 * brightness) / 0.85
        }
        return Float(max(0, min(1, result)))
    }

    /// Onsets per second from the stored energy codes (one per 100 ms, 0.5 dB each).
    static func onsetRate(energy: [UInt8], duration: Double) -> Double {
        guard energy.count > 1, duration > 0, duration.isFinite else { return 0 }
        let step = Int((onsetStepDb / MusicAnalysis.energyStepDb).rounded())
        var count = 0
        for index in 1..<energy.count where Int(energy[index]) - Int(energy[index - 1]) >= step { count += 1 }
        return Double(count) / duration
    }
}
