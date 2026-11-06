// DeciTests/Music/MusicAnalysisPayloadTests.swift
// The energy curve BLOB: version byte, UInt32 little endian count, one code per 100 ms block.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("MusicAnalysisPayload")
struct MusicAnalysisPayloadTests {

    @Test("Encode then decode returns the same codes, including the 0 and 180 ends")
    func roundTrip() {
        let codes: [UInt8] = [0, 1, 90, 179, 180, 7]
        #expect(MusicAnalysisPayload.decode(MusicAnalysisPayload.encode(codes)) == codes)
    }

    @Test("The header is the payload version and a little endian block count")
    func headerLayout() {
        let data = MusicAnalysisPayload.encode([UInt8](repeating: 5, count: 258))
        #expect(Array(data.prefix(5)) == [1, 0x02, 0x01, 0, 0])
        #expect(data.count == 5 + 258)
    }

    @Test("An empty curve round trips")
    func empty() {
        #expect(MusicAnalysisPayload.decode(MusicAnalysisPayload.encode([])) == [])
    }

    @Test("A four minute song is 2400 blocks and 2405 bytes")
    func fourMinuteSize() {
        let data = MusicAnalysisPayload.encode([UInt8](repeating: 100, count: 2400))
        #expect(data.count == 2405)
    }

    @Test("Truncated data, a short header and trailing junk all decode to nil")
    func malformed() {
        let good = MusicAnalysisPayload.encode([1, 2, 3, 4])
        #expect(MusicAnalysisPayload.decode(good.dropLast()) == nil)
        #expect(MusicAnalysisPayload.decode(good + Data([9])) == nil)
        #expect(MusicAnalysisPayload.decode(Data([1, 0, 0])) == nil)
        #expect(MusicAnalysisPayload.decode(Data()) == nil)
    }

    @Test("An unknown payload version decodes to nil")
    func unknownVersion() {
        var data = MusicAnalysisPayload.encode([1, 2, 3])
        data[0] = 2
        #expect(MusicAnalysisPayload.decode(data) == nil)
    }

    @Test("A count that claims more blocks than the data holds is rejected, not trusted")
    func hugeCount() {
        #expect(MusicAnalysisPayload.decode(Data([1, 0xFF, 0xFF, 0xFF, 0xFF, 1, 2])) == nil)
    }

    @Test("Energy codes are half-dB steps from -90 dB and clamp at both ends")
    func codes() {
        #expect(MusicAnalysis.energyCode(forDb: -90) == 0)
        #expect(MusicAnalysis.energyCode(forDb: -200) == 0)
        #expect(MusicAnalysis.energyCode(forDb: -20) == 140)
        #expect(MusicAnalysis.energyCode(forDb: 0) == 180)
        #expect(MusicAnalysis.energyCode(forDb: 6) == 180)
        #expect(MusicAnalysis.energyCode(forDb: -.infinity) == 0)
        #expect(MusicAnalysis.energyCode(forDb: .nan) == 0)
    }
}
