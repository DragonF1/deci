// DeciTests/MultiOutputRevertTests.swift
// The shared decision for "an output device in an item's Multi selection disconnected": does the item
// go back to its pre-Multi single setting, or to System Audio? Pure, so every case is a plain value.

import Foundation
import Testing
@testable import Deci

@Suite("MultiOutputRevert")
struct MultiOutputRevertTests {

    private let since = Date(timeIntervalSince1970: 1_000_000)

    @Test("the pre-Multi single setting is remembered for exactly one hour")
    func windowIsOneHour() {
        #expect(MultiOutputRevert.rememberWindow == 3600)
    }

    @Test("a short Multi session returns to the pre-Multi single setting")
    func shortSessionRestoresTheSingleSetting() {
        let now = since.addingTimeInterval(60)
        #expect(MultiOutputRevert.target(multiSince: since, now: now) == .previousSingle)
    }

    @Test("a Multi session that just started returns to the pre-Multi single setting")
    func zeroElapsedRestoresTheSingleSetting() {
        #expect(MultiOutputRevert.target(multiSince: since, now: since) == .previousSingle)
    }

    @Test("one second under the window still restores")
    func justUnderTheWindow() {
        let now = since.addingTimeInterval(MultiOutputRevert.rememberWindow - 1)
        #expect(MultiOutputRevert.target(multiSince: since, now: now) == .previousSingle)
    }

    @Test("exactly the window goes to System Audio")
    func exactlyTheWindow() {
        let now = since.addingTimeInterval(MultiOutputRevert.rememberWindow)
        #expect(MultiOutputRevert.target(multiSince: since, now: now) == .systemAudio)
    }

    @Test("a long Multi session goes to System Audio")
    func longSessionGoesToSystemAudio() {
        let now = since.addingTimeInterval(MultiOutputRevert.rememberWindow + 1)
        #expect(MultiOutputRevert.target(multiSince: since, now: now) == .systemAudio)
        #expect(MultiOutputRevert.target(multiSince: since, now: since.addingTimeInterval(86_400 * 30)) == .systemAudio)
    }

    @Test("no recorded start goes to System Audio")
    func noRecordedStart() {
        #expect(MultiOutputRevert.target(multiSince: nil, now: since) == .systemAudio)
    }

    @Test("a start slightly in the future (a small clock step back) counts as a short session")
    func clockSteppedBackSlightly() {
        #expect(MultiOutputRevert.futureTolerance == 300)
        #expect(MultiOutputRevert.target(multiSince: since, now: since.addingTimeInterval(-120)) == .previousSingle)
        #expect(MultiOutputRevert.target(multiSince: since, now: since.addingTimeInterval(-MultiOutputRevert.futureTolerance)) == .previousSingle)
    }

    @Test("a start more than five minutes in the future is unknown, so it goes to System Audio")
    func startFarInTheFuture() {
        let justOver = since.addingTimeInterval(-(MultiOutputRevert.futureTolerance + 1))
        #expect(MultiOutputRevert.target(multiSince: since, now: justOver) == .systemAudio)
        #expect(MultiOutputRevert.target(multiSince: since, now: since.addingTimeInterval(-86_400)) == .systemAudio)
    }

    @Test("a disconnect only matters for a Multi item that has the device selected")
    func disconnectScope() {
        let selected: Set<String> = ["uid-a", "uid-b"]
        #expect(MultiOutputRevert.disconnectAffects(mode: .multi, selected: selected, uid: "uid-a"))
        #expect(!MultiOutputRevert.disconnectAffects(mode: .multi, selected: selected, uid: "uid-c"))
        #expect(!MultiOutputRevert.disconnectAffects(mode: .multi, selected: [], uid: "uid-a"))
        #expect(!MultiOutputRevert.disconnectAffects(mode: .single, selected: selected, uid: "uid-a"))
        #expect(!MultiOutputRevert.disconnectAffects(mode: nil, selected: selected, uid: "uid-a"))
    }
}
