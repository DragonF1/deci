// DeciTests/OutputBackendCacheTests.swift
// The Mixer popup's device rows read each output device's volume backend from a cache instead of asking CoreAudio from a
// view body. The cache must follow the device when its answer changes (a Bluetooth output after its handshake, HDMI after
// wake), and must stay silent when nothing changed: a dictionary write always notifies, and a hidden popup is redrawn by it.

import AudioToolbox
import Foundation
import Observation
import os
import Testing
@testable import Deci

/// Records that an observation fired, from the nonisolated closure `withObservationTracking` takes.
private nonisolated final class Fired: Sendable {
    private let flag = OSAllocatedUnfairLock(initialState: false)
    var value: Bool { flag.withLock { $0 } }
    func set() { flag.withLock { $0 = true } }
}

@MainActor
@Suite("OutputBackendCache")
struct OutputBackendCacheTests {
    private let tv: AudioDeviceID = 41
    private let headphones: AudioDeviceID = 42
    private let speakers: AudioDeviceID = 43

    /// Reads `read` once, and says whether `change` afterwards would redraw whoever read it.
    private func redraws(read: @MainActor () -> Void, after change: @MainActor () -> Void) -> Bool {
        let fired = Fired()
        withObservationTracking { read() } onChange: { fired.set() }
        change()
        return fired.value
    }

    // MARK: - Storing

    @Test("A device nobody stored has no tier")
    func emptyAtStart() {
        let cache = OutputBackendCache()
        #expect(cache.tier(for: headphones) == nil)
    }

    @Test("A stored tier is read back, per device")
    func storeAndRead() {
        let cache = OutputBackendCache()
        cache.store(.hardware, for: headphones)
        cache.store(.software, for: tv)
        #expect(cache.tier(for: headphones) == .hardware)
        #expect(cache.tier(for: tv) == .software)
        #expect(cache.tier(for: speakers) == nil)
    }

    @Test("Storing says whether it changed anything")
    func storeReportsChange() {
        let cache = OutputBackendCache()
        #expect(cache.store(.software, for: headphones))
        #expect(!cache.store(.software, for: headphones))
        #expect(cache.store(.hardware, for: headphones))
    }

    // MARK: - Who is redrawn

    @Test("A new tier redraws a view that reads the device")
    func changeRedraws() {
        let cache = OutputBackendCache()
        cache.store(.software, for: headphones)
        let drawn = redraws(read: { _ = cache.tier(for: headphones) }, after: { cache.store(.hardware, for: headphones) })
        #expect(drawn)
    }

    @Test("The same tier again redraws nobody")
    func sameTierIsSilent() {
        let cache = OutputBackendCache()
        cache.store(.hardware, for: headphones)
        let drawn = redraws(read: { _ = cache.tier(for: headphones) }, after: { cache.store(.hardware, for: headphones) })
        #expect(!drawn)
    }

    @Test("A first tier redraws a view that read the device before it had one")
    func firstTierRedraws() {
        let cache = OutputBackendCache()
        let drawn = redraws(read: { _ = cache.tier(for: headphones) }, after: { cache.store(.ddc, for: headphones) })
        #expect(drawn)
    }

    // MARK: - Removing

    @Test("Removing a device forgets its tier, and removing an unknown one is silent")
    func removeOne() {
        let cache = OutputBackendCache()
        cache.store(.hardware, for: headphones)
        cache.store(.software, for: tv)
        cache.remove(headphones)
        #expect(cache.tier(for: headphones) == nil)
        #expect(cache.tier(for: tv) == .software)

        let drawn = redraws(read: { _ = cache.tier(for: tv) }, after: { cache.remove(speakers) })
        #expect(!drawn)
    }

    @Test("Clearing forgets every device, and clearing an empty cache is silent")
    func removeAll() {
        let cache = OutputBackendCache()
        cache.store(.hardware, for: headphones)
        cache.store(.software, for: tv)
        cache.removeAll()
        #expect(cache.tier(for: headphones) == nil)
        #expect(cache.tier(for: tv) == nil)

        let drawn = redraws(read: { _ = cache.tier(for: tv) }, after: { cache.removeAll() })
        #expect(!drawn)
    }

    // MARK: - Refreshing

    @Test("A refresh takes the new answer of a device whose answer changed, and leaves the others")
    func refreshFollowsTheDevice() {
        let cache = OutputBackendCache()
        // The headphones were read before their handshake finished: software. Now CoreAudio says hardware.
        cache.store(.software, for: headphones)
        cache.store(.ddc, for: tv)
        let live: [AudioDeviceID: VolumeControlTier] = [headphones: .hardware, tv: .ddc]
        cache.refresh([headphones, tv]) { live[$0] ?? .software }
        #expect(cache.tier(for: headphones) == .hardware)
        #expect(cache.tier(for: tv) == .ddc)
    }

    @Test("A refresh stores a device nobody had read yet")
    func refreshAddsNewDevices() {
        let cache = OutputBackendCache()
        cache.refresh([headphones, speakers]) { $0 == headphones ? .hardware : .software }
        #expect(cache.tier(for: headphones) == .hardware)
        #expect(cache.tier(for: speakers) == .software)
    }

    @Test("A refresh redraws only the views of the devices that changed")
    func refreshRedrawsOnlyWhatChanged() {
        let cache = OutputBackendCache()
        cache.store(.software, for: headphones)
        cache.store(.hardware, for: tv)
        let live: [AudioDeviceID: VolumeControlTier] = [headphones: .hardware, tv: .hardware]

        let changed = redraws(read: { _ = cache.tier(for: headphones) }, after: { cache.refresh([headphones, tv]) { live[$0] ?? .software } })
        #expect(changed)

        // Everything now matches: a second refresh writes nothing.
        let drawn = redraws(
            read: { _ = cache.tier(for: headphones); _ = cache.tier(for: tv) },
            after: { cache.refresh([headphones, tv]) { live[$0] ?? .software } }
        )
        #expect(!drawn)
    }

    @Test("A refresh asks for each listed device once, and for no other")
    func refreshAsksOnce() {
        let cache = OutputBackendCache()
        var asked: [AudioDeviceID] = []
        cache.refresh([headphones, tv]) { id in
            asked.append(id)
            return .software
        }
        #expect(asked == [headphones, tv])
    }

    @Test("A refresh drops devices that are no longer listed")
    func refreshDropsGoneDevices() {
        let cache = OutputBackendCache()
        cache.store(.hardware, for: headphones)
        cache.store(.software, for: tv)
        cache.refresh([tv]) { _ in .software }
        #expect(cache.tier(for: headphones) == nil)
        #expect(cache.tier(for: tv) == .software)
    }
}
