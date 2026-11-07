// Deci/Music/Analysis/MusicBeatGrid.swift
// A song's beat grid (tier 3b): one straight line through the beats, stored in the analysis row's `beat_grid` BLOB.
// Beat k sits at anchor + k * period, extrapolated both ways; the span says which stretch of the song was validated.

import Foundation

nonisolated struct MusicBeatGrid: Equatable, Sendable {
    var periodSec: Double
    /// A beat time (phase refined on the bass band), in the analysis reader's timeline.
    var anchorSec: Double
    /// 0...3: which beat index (mod 4, counting from the anchor) starts a bar. nil when unknown.
    var downbeatPhase: Int?
    /// 0...1: fraction of beats whose bass onset lies within 10 ms of the grid.
    var beatConfidence: Float
    var downbeatConfidence: Float
    var intervalSpread: Float
    /// Period of the second half minus the period of the first half, in seconds per beat.
    var driftSec: Float
    var spanStartSec: Double
    var spanEndSec: Double

    var bpm: Double { 60 / periodSec }

    func beatTime(_ k: Int) -> Double { anchorSec + Double(k) * periodSec }

    /// The first beat at or after `t` (a beat within a nanosecond of `t` counts as at it).
    func nextBeat(atOrAfter t: Double) -> (index: Int, time: Double) {
        let k = Int(((t - anchorSec) / periodSec - 1e-9).rounded(.up))
        return (k, beatTime(k))
    }

    /// Bar index 0 is the first bar whose downbeat is inside the span; bars are 4 beats. nil without a downbeat.
    func barTime(_ bar: Int) -> Double? {
        guard let phase = downbeatPhase else { return nil }
        var k = nextBeat(atOrAfter: spanStartSec).index
        k += ((phase - k) % 4 + 4) % 4
        return beatTime(k + 4 * bar)
    }

    // MARK: Payload

    static let payloadVersion: UInt8 = 1
    static let unknownPhase: UInt8 = 255
    private static let payloadSize = 1 + 8 + 8 + 1 + 4 * 4 + 8 + 8

    func encode() -> Data {
        var data = Data(capacity: Self.payloadSize)
        data.append(Self.payloadVersion)
        Self.append(periodSec.bitPattern, to: &data)
        Self.append(anchorSec.bitPattern, to: &data)
        data.append(downbeatPhase.map { UInt8(clamping: $0) } ?? Self.unknownPhase)
        for value in [beatConfidence, downbeatConfidence, intervalSpread, driftSec] {
            Self.append(value.bitPattern, to: &data)
        }
        Self.append(spanStartSec.bitPattern, to: &data)
        Self.append(spanEndSec.bitPattern, to: &data)
        return data
    }

    /// nil on a wrong version, a short payload, a non-finite number, a non-positive period or a reversed span.
    static func decode(_ data: Data) -> MusicBeatGrid? {
        let bytes = [UInt8](data)
        guard bytes.count >= payloadSize, bytes[0] == payloadVersion else { return nil }
        func u64(_ at: Int) -> UInt64 {
            (0..<8).reduce(UInt64(0)) { $0 | UInt64(bytes[at + $1]) << UInt64(8 * $1) }
        }
        func u32(_ at: Int) -> UInt32 {
            (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[at + $1]) << UInt32(8 * $1) }
        }
        let phaseByte = bytes[17]
        guard phaseByte == unknownPhase || phaseByte < 4 else { return nil }
        let grid = MusicBeatGrid(
            periodSec: Double(bitPattern: u64(1)),
            anchorSec: Double(bitPattern: u64(9)),
            downbeatPhase: phaseByte == unknownPhase ? nil : Int(phaseByte),
            beatConfidence: Float(bitPattern: u32(18)),
            downbeatConfidence: Float(bitPattern: u32(22)),
            intervalSpread: Float(bitPattern: u32(26)),
            driftSec: Float(bitPattern: u32(30)),
            spanStartSec: Double(bitPattern: u64(34)),
            spanEndSec: Double(bitPattern: u64(42))
        )
        let doubles = [grid.periodSec, grid.anchorSec, grid.spanStartSec, grid.spanEndSec]
        let floats = [grid.beatConfidence, grid.downbeatConfidence, grid.intervalSpread, grid.driftSec]
        guard doubles.allSatisfy(\.isFinite), floats.allSatisfy(\.isFinite),
              grid.periodSec > 0, grid.spanEndSec >= grid.spanStartSec else { return nil }
        return grid
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
}
