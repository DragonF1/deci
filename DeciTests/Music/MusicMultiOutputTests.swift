// DeciTests/Music/MusicMultiOutputTests.swift
// The music player on several output devices at once: the stacked aggregate it is pointed at, which device is the clock,
// how the choice is seeded and saved, and that the aggregate is rebuilt and destroyed at the right moments. The
// aggregates and the player are fakes, so no audio plays and Core Audio is never touched.

import AudioToolbox
import Foundation
import Observation
import Testing
@testable import Deci

/// What happened to the player and the aggregates, in one list, so tests can say which came first.
@MainActor
final class MultiOutputEventLog {
    enum Event: Equatable {
        case made(String)
        case destroyed(String)
        case player(String?)
    }

    private(set) var events: [Event] = []

    func record(_ event: Event) { events.append(event) }
}

@MainActor
final class FakeOutputAggregates: MusicOutputAggregating {
    var bluetoothUIDs: Set<String> = []
    var failsToMake = false
    /// Every stack the mixer asked for, whether or not it was made.
    private(set) var stacks: [MusicOutputStack] = []
    private(set) var live: [MusicOutputAggregate] = []
    private(set) var destroyed: [MusicOutputAggregate] = []
    private var made = 0
    private let log: MultiOutputEventLog

    init(log: MultiOutputEventLog) { self.log = log }

    func isBluetooth(deviceUID: String) -> Bool { bluetoothUIDs.contains(deviceUID) }

    func makeAggregate(for stack: MusicOutputStack) -> MusicOutputAggregate? {
        stacks.append(stack)
        guard !failsToMake else { return nil }
        made += 1
        let aggregate = MusicOutputAggregate(uid: "agg-\(made)", objectID: AudioObjectID(100 + made))
        live.append(aggregate)
        log.record(.made(aggregate.uid))
        return aggregate
    }

    func destroy(_ aggregate: MusicOutputAggregate) {
        live.removeAll { $0 == aggregate }
        destroyed.append(aggregate)
        log.record(.destroyed(aggregate.uid))
    }
}

/// A player that only writes the output devices it is given into the shared log.
@MainActor
final class LoggingPlaybackEngine: PlaybackEngine {
    var onTick: (@MainActor (TimeInterval, Bool) -> Void)?
    var onEvent: (@MainActor (PlaybackEngineEvent) -> Void)?
    var position: TimeInterval = 0
    private(set) var outputDevices: [String?] = []
    private let log: MultiOutputEventLog

    init(log: MultiOutputEventLog) { self.log = log }

    func load(_ stream: ResolvedStream, startAt: TimeInterval, autoplay: Bool) {}
    func play() {}
    func pause() {}
    func seek(to seconds: TimeInterval) {}
    func unload() {}
    func setFallbackLevel(volume: Float, muted: Bool) {}

    func setOutputDevice(uid: String?) {
        outputDevices.append(uid)
        log.record(.player(uid))
    }
}

/// Counts a change callback that Observation may call from anywhere.
private nonisolated final class ChangeCounter: @unchecked Sendable {
    var count = 0
}

/// The mixer's clock in the tests: it starts at the real time, so a start recorded without a clock (a settings file
/// prepared by hand) is on the same scale, and moves only when a test moves it.
@MainActor
private final class RigClock {
    private(set) var now = Date()

    func advance(by seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

/// A mixer with fakes around it. `devices` are the connected output devices.
@MainActor
private final class Rig {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("deci-multi-\(UUID().uuidString)")
    let log = MultiOutputEventLog()
    let environment = FakeMusicMixerEnvironment()
    let settings: SettingsManager
    let aggregates: FakeOutputAggregates
    let engine: LoggingPlaybackEngine
    let state: MusicMixerState
    let clock = RigClock()

    init(
        devices: [String] = [],
        defaultUID: String? = nil,
        bluetooth: Set<String> = [],
        attach: Bool = true,
        prepare: (SettingsManager) -> Void = { _ in }
    ) {
        let settings = SettingsManager(directory: directory)
        prepare(settings)
        self.settings = settings
        environment.outputDevices = devices.map { FakeMusicMixerEnvironment.device($0) }
        environment.defaultOutputDeviceUID = defaultUID
        aggregates = FakeOutputAggregates(log: log)
        aggregates.bluetoothUIDs = bluetooth
        engine = LoggingPlaybackEngine(log: log)
        let clock = clock
        state = MusicMixerState(
            settings: settings, environment: environment, aggregates: aggregates, now: { clock.now }
        )
        if attach { state.attach(engine: engine) }
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    /// The connected devices become exactly these, and the mixer is told, as the engine does.
    func connect(_ uids: [String]) {
        environment.outputDevices = uids.map { FakeMusicMixerEnvironment.device($0) }
        state.outputDevicesChanged()
    }

    /// When the music entered Multi, as the settings hold it.
    var multiSince: Date? { settings.getMultiOutputSince(for: musicKey) }

    /// Ticks these devices in Multi mode.
    func playOn(_ uids: Set<String>) {
        state.setDeviceSelectionMode(.multi)
        state.setSelectedDeviceUIDs(uids)
    }

    /// The events since `mark`, taken from `log.events.count` earlier.
    func events(since mark: Int) -> [MultiOutputEventLog.Event] {
        Array(log.events[mark...])
    }
}

private let musicKey = MusicMixerState.settingsKey

private func profile(_ id: String) -> AutoEQProfile {
    AutoEQProfile(
        id: id, name: id, source: .bundled, preampDB: -3,
        filters: [AutoEQFilter(type: .peaking, frequency: 1_000, gainDB: 3, q: 1)]
    )
}

// MARK: - The stack

@Suite("Music output stack")
struct MusicOutputStackTests {
    @Test("a stack needs two devices")
    func needsTwoDevices() {
        #expect(MusicOutputStack.plan(for: [], isBluetooth: { _ in false }) == nil)
        #expect(MusicOutputStack.plan(for: ["a"], isBluetooth: { _ in false }) == nil)
        #expect(MusicOutputStack.plan(for: ["a", "b"], isBluetooth: { _ in false }) != nil)
    }

    @Test("with no Bluetooth device the clock is the first UID in sorted order, and the others follow in order")
    func clockIsTheFirstSorted() {
        let stack = MusicOutputStack.plan(for: ["c", "a", "b"], isBluetooth: { _ in false })
        #expect(stack?.subDeviceUIDs == ["a", "b", "c"])
        #expect(stack?.clockDeviceUID == "a")
    }

    @Test("a wired device is the clock ahead of a Bluetooth one")
    func clockSkipsBluetooth() {
        let stack = MusicOutputStack.plan(for: ["a", "b", "c"], isBluetooth: { $0 == "a" })
        #expect(stack?.clockDeviceUID == "b")
        #expect(stack?.subDeviceUIDs == ["b", "a", "c"])
    }

    @Test("with several wired devices the first sorted one is the clock")
    func clockIsTheFirstWired() {
        let stack = MusicOutputStack.plan(for: ["a", "b", "c", "d"], isBluetooth: { $0 == "a" || $0 == "d" })
        #expect(stack?.subDeviceUIDs == ["b", "a", "c", "d"])
    }

    @Test("when every device is Bluetooth the first sorted one is still the clock")
    func allBluetooth() {
        let stack = MusicOutputStack.plan(for: ["b", "a"], isBluetooth: { _ in true })
        #expect(stack?.subDeviceUIDs == ["a", "b"])
    }

    @Test("the description is a private stacked aggregate clocked by the first device, drift compensation on the rest")
    func description() throws {
        let stack = try #require(MusicOutputStack.plan(for: ["a", "b", "c"], isBluetooth: { $0 == "a" }))
        let description = stack.description(name: "Deci-Music", uid: "Deci-Music-1")

        #expect(description[kAudioAggregateDeviceNameKey] as? String == "Deci-Music")
        #expect(description[kAudioAggregateDeviceUIDKey] as? String == "Deci-Music-1")
        #expect(description[kAudioAggregateDeviceIsPrivateKey] as? Bool == true)
        #expect(description[kAudioAggregateDeviceIsStackedKey] as? Bool == true)
        #expect(description[kAudioAggregateDeviceMainSubDeviceKey] as? String == "b")
        #expect(description[kAudioAggregateDeviceClockDeviceKey] as? String == "b")

        let subDevices = try #require(description[kAudioAggregateDeviceSubDeviceListKey] as? [[String: Any]])
        #expect(subDevices.map { $0[kAudioSubDeviceUIDKey] as? String } == ["b", "a", "c"])
        #expect(subDevices.map { $0[kAudioSubDeviceDriftCompensationKey] as? Bool } == [false, true, true])
    }

    @Test("every sub-device carries the extra output latency that lines it up with the slowest, in the clock-first order")
    func descriptionCarriesExtraOutputLatency() throws {
        let stack = try #require(MusicOutputStack.plan(for: ["xm5", "buds"], isBluetooth: { _ in true }))
        let description = stack.description(
            name: "Deci-Music", uid: "Deci-Music-1",
            extraOutputLatencyFrames: ["xm5": 1412, "buds": 0]
        )

        let subDevices = try #require(description[kAudioAggregateDeviceSubDeviceListKey] as? [[String: Any]])
        #expect(subDevices.map { $0[kAudioSubDeviceUIDKey] as? String } == ["buds", "xm5"])
        #expect(subDevices.map { $0[kAudioSubDeviceExtraOutputLatencyKey] as? UInt32 } == [0, 1412])
    }

    @Test("with no latency table every sub-device still says 0, and the other keys are as before")
    func descriptionDefaultsToNoExtraLatency() throws {
        let stack = MusicOutputStack(subDeviceUIDs: ["a", "b", "c"])
        let description = stack.description(name: "Deci-Music", uid: "Deci-Music-1")

        let subDevices = try #require(description[kAudioAggregateDeviceSubDeviceListKey] as? [[String: Any]])
        #expect(subDevices.map { $0[kAudioSubDeviceExtraOutputLatencyKey] as? UInt32 } == [0, 0, 0])
        #expect(subDevices.map { $0[kAudioSubDeviceDriftCompensationKey] as? Bool } == [false, true, true])
        #expect(Set(subDevices[0].keys) == [kAudioSubDeviceUIDKey, kAudioSubDeviceDriftCompensationKey, kAudioSubDeviceExtraOutputLatencyKey])
    }

    @Test("a name starting with Deci- keeps the device monitor from listing the aggregate as an output")
    func nameIsHiddenFromTheMonitor() {
        #expect(MusicOutputStack.aggregateName.hasPrefix("Deci-"))
    }

    @Test("a user aggregate in the stack is replaced by its own devices, because an aggregate cannot hold another")
    func flatteningUserAggregates() {
        let stack = MusicOutputStack(subDeviceUIDs: ["a", "agg", "b"])
        let flat = stack.flattened { $0 == "agg" ? ["x", "y"] : nil }
        #expect(flat.subDeviceUIDs == ["a", "x", "y", "b"])
    }

    @Test("flattening drops a device that would appear twice, and leaves a stack of plain devices alone")
    func flatteningDeduplicates() {
        let stack = MusicOutputStack(subDeviceUIDs: ["x", "agg", "b"])
        #expect(stack.flattened { $0 == "agg" ? ["x", "y"] : nil }.subDeviceUIDs == ["x", "y", "b"])
        #expect(stack.flattened { _ in nil } == stack)
    }
}

// MARK: - The mixer in Multi mode

@MainActor
@Suite("Music multi-device output")
struct MusicMultiOutputTests {
    // MARK: Seeding and saving

    @Test("a fresh mixer is in Single mode with nothing ticked and no aggregate")
    func defaults() {
        let rig = Rig(devices: ["a", "b"], defaultUID: "a")
        #expect(rig.state.deviceSelectionMode == .single)
        #expect(rig.state.selectedDeviceUIDs.isEmpty)
        #expect(rig.state.multiOutputDeviceUIDs.isEmpty)
        #expect(rig.aggregates.stacks.isEmpty)
    }

    @Test("flipping to Multi saves the mode and ticks the device the music plays on")
    func firstFlipSeeds() {
        let rig = Rig(devices: ["a", "b"], defaultUID: "a")
        rig.state.setDeviceSelectionMode(.multi)

        #expect(rig.state.deviceSelectionMode == .multi)
        #expect(rig.state.selectedDeviceUIDs == ["a"], "the default output is where it plays")
        #expect(rig.settings.getDeviceSelectionMode(for: musicKey) == .multi)
        #expect(rig.settings.getSelectedDeviceUIDs(for: musicKey) == ["a"])
        #expect(rig.aggregates.stacks.isEmpty, "one device needs no aggregate")
        #expect(rig.engine.outputDevices.last == .some("a"))
    }

    @Test("the seed is the chosen device when the music is routed to one, not the default")
    func seedFollowsTheRoutedDevice() {
        let rig = Rig(devices: ["a", "b"], defaultUID: "a")
        rig.state.selectDevice(uid: "b")
        rig.state.setDeviceSelectionMode(.multi)
        #expect(rig.state.selectedDeviceUIDs == ["b"])
    }

    @Test("a selection saved earlier is not seeded over")
    func savedSelectionStays() {
        let rig = Rig(devices: ["a", "b", "c"], defaultUID: "a", prepare: {
            $0.setSelectedDeviceUIDs(for: musicKey, to: ["b", "c"])
        })
        #expect(rig.state.selectedDeviceUIDs == ["b", "c"], "loaded with the mixer")
        rig.state.setDeviceSelectionMode(.multi)
        #expect(rig.state.selectedDeviceUIDs == ["b", "c"])
        #expect(rig.settings.getSelectedDeviceUIDs(for: musicKey) == ["b", "c"])
    }

    @Test("with nothing to seed from, Multi starts empty and the mode is still saved")
    func nothingToSeed() {
        let rig = Rig()
        rig.state.setDeviceSelectionMode(.multi)
        #expect(rig.state.deviceSelectionMode == .multi)
        #expect(rig.state.selectedDeviceUIDs.isEmpty)
        #expect(rig.settings.getDeviceSelectionMode(for: musicKey) == .multi)
        #expect(rig.engine.outputDevices.last == .some(nil), "plays on the default output")
    }

    @Test("the mode and the ticked devices come back after a restart, from the file")
    func persistenceRoundTrip() {
        let rig = Rig(devices: ["a", "b", "c"], defaultUID: "a")
        rig.playOn(["a", "c"])
        rig.settings.flushSync()

        let reloaded = SettingsManager(directory: rig.directory)
        let second = MusicMixerState(
            settings: reloaded,
            environment: rig.environment,
            aggregates: FakeOutputAggregates(log: MultiOutputEventLog())
        )
        #expect(second.deviceSelectionMode == .multi)
        #expect(second.selectedDeviceUIDs == ["a", "c"])
    }

    @Test("picking devices saves them under the music key without touching the single-device choice")
    func selectionIsSaved() {
        let rig = Rig(devices: ["a", "b", "c"], defaultUID: "a")
        rig.state.selectDevice(uid: "c")
        rig.playOn(["a", "b"])
        #expect(rig.settings.getSelectedDeviceUIDs(for: musicKey) == ["a", "b"])
        #expect(rig.settings.getDeviceRouting(for: musicKey) == "c")
        #expect(rig.state.selectedDeviceUID == "c")
    }

    @Test("an unchanged selection or mode is not written again")
    func unchangedIsIgnored() {
        let rig = Rig(devices: ["a", "b"], defaultUID: "a")
        rig.playOn(["a", "b"])
        #expect(rig.aggregates.live.count == 1)
        let mark = rig.log.events.count
        rig.state.setDeviceSelectionMode(.multi)
        rig.state.setSelectedDeviceUIDs(["a", "b"])
        #expect(rig.events(since: mark).isEmpty)
    }

    // MARK: Going back to Single

    @Test("going back to Single plays on the device that was chosen before")
    func backToTheChosenDevice() {
        let rig = Rig(devices: ["a", "b", "c"], defaultUID: "a")
        rig.state.selectDevice(uid: "b")
        rig.playOn(["a", "c"])
        rig.state.setDeviceSelectionMode(.single)

        #expect(rig.state.deviceSelectionMode == .single)
        #expect(rig.state.selectedDeviceUID == "b")
        #expect(rig.state.outputDeviceUID == "b")
        #expect(rig.engine.outputDevices.last == .some("b"))
        #expect(rig.settings.getDeviceSelectionMode(for: musicKey) == .single)
        #expect(rig.settings.getSelectedDeviceUIDs(for: musicKey) == ["a", "c"], "kept for the next time")
    }

    @Test("going back to Single follows the default output again when no device was chosen")
    func backToFollowingTheDefault() {
        let rig = Rig(devices: ["a", "b"], defaultUID: "a")
        rig.playOn(["a", "b"])
        #expect(rig.engine.outputDevices.last == .some("agg-1"))
        rig.state.setDeviceSelectionMode(.single)

        #expect(rig.state.isFollowingDefault)
        #expect(rig.engine.outputDevices.last == .some(nil))
    }

    @Test("Single mode never makes an aggregate")
    func singleModeMakesNone() {
        let rig = Rig(devices: ["a", "b"], defaultUID: "a")
        rig.state.selectDevice(uid: "b")
        rig.state.followDefaultDevice()
        rig.state.outputDevicesChanged()
        #expect(rig.aggregates.stacks.isEmpty)
        #expect(rig.state.multiOutputDeviceUIDs.isEmpty)
    }

    // MARK: Output by the number of devices

    @Test("two available devices build one stacked aggregate and the player is pointed at it")
    func twoDevicesBuildAnAggregate() {
        let rig = Rig(devices: ["a", "b", "c"], defaultUID: "a")
        rig.playOn(["c", "a"])

        #expect(rig.aggregates.stacks == [MusicOutputStack(subDeviceUIDs: ["a", "c"])])
        #expect(rig.aggregates.live.map(\.uid) == ["agg-1"])
        #expect(rig.engine.outputDevices.last == .some("agg-1"))
    }

    @Test("the clock is a wired device when one of the selection is Bluetooth")
    func clockPrefersWired() {
        let rig = Rig(devices: ["a", "b", "c"], defaultUID: "a", bluetooth: ["a"])
        rig.playOn(["a", "b", "c"])
        #expect(rig.aggregates.stacks.last?.clockDeviceUID == "b")
        #expect(rig.aggregates.stacks.last?.subDeviceUIDs == ["b", "a", "c"])
    }

    @Test("exactly one available device is used directly, with no aggregate")
    func oneDeviceIsDirect() {
        let rig = Rig(devices: ["a"], defaultUID: "a")
        rig.playOn(["a", "gone"])

        #expect(rig.aggregates.stacks.isEmpty)
        #expect(rig.engine.outputDevices.last == .some("a"))
        #expect(rig.state.multiOutputDeviceUIDs.isEmpty)
        #expect(rig.state.selectedDeviceUIDs == ["a", "gone"], "the unplugged device stays ticked")
    }

    @Test("no available device plays on the system default and keeps the selection")
    func noDeviceFallsBack() {
        let rig = Rig(devices: ["x"], defaultUID: "x")
        rig.playOn(["a", "b"])

        #expect(rig.aggregates.stacks.isEmpty)
        #expect(rig.engine.outputDevices.last == .some(nil))
        #expect(rig.state.selectedDeviceUIDs == ["a", "b"])
        #expect(rig.settings.getSelectedDeviceUIDs(for: musicKey) == ["a", "b"])
        #expect(rig.state.multiOutputDeviceUIDs.isEmpty)
    }

    @Test("when the selected devices come back the aggregate is built again")
    func reconnectRestores() {
        let rig = Rig(devices: ["x"], defaultUID: "x")
        rig.playOn(["a", "b"])
        rig.connect(["x", "a"])
        #expect(rig.engine.outputDevices.last == .some("a"), "one is back: direct")
        rig.connect(["x", "a", "b"])

        #expect(rig.aggregates.stacks.last == MusicOutputStack(subDeviceUIDs: ["a", "b"]))
        #expect(rig.engine.outputDevices.last == .some("agg-1"))
        #expect(rig.state.multiOutputDeviceUIDs == ["a", "b"])
    }

    @Test("a selected device unplugged sends the music back to Single instead of rebuilding on the rest")
    func disconnectLeavesMulti() {
        let rig = Rig(devices: ["a", "b", "c"], defaultUID: "a")
        rig.playOn(["a", "b", "c"])
        #expect(rig.aggregates.stacks.count == 1)

        rig.connect(["a", "c"])
        #expect(rig.state.deviceSelectionMode == .single, "two devices are still there, and it left Multi anyway")
        #expect(rig.aggregates.stacks.count == 1, "no new aggregate for the rest")
        #expect(rig.engine.outputDevices.last == .some(nil))
        #expect(rig.aggregates.live.isEmpty)
        #expect(rig.state.multiOutputDeviceUIDs.isEmpty)

        rig.connect(["c"])
        #expect(rig.state.deviceSelectionMode == .single, "a second drop finds it in Single already")
        #expect(rig.engine.outputDevices.last == .some(nil))
        #expect(rig.aggregates.stacks.count == 1)
    }

    @Test("a failed aggregate plays on the clock device alone rather than not at all")
    func failedAggregate() {
        let rig = Rig(devices: ["a", "b"], defaultUID: "a", attach: true)
        rig.aggregates.failsToMake = true
        rig.playOn(["a", "b"])

        #expect(rig.aggregates.stacks.count == 1)
        #expect(rig.engine.outputDevices.last == .some("a"))
        #expect(rig.state.multiOutputDeviceUIDs.isEmpty, "it does not play on two devices")
    }

    @Test("a stack that failed to build is not built again while the stack stays the same")
    func failedStackIsNotRetried() {
        let rig = Rig(devices: ["a", "b"], defaultUID: "a")
        rig.aggregates.failsToMake = true
        rig.playOn(["a", "b"])
        #expect(rig.aggregates.stacks.count == 1)

        // Every try waits on the main thread for the aggregate to come up, so the same stack is not tried on each event.
        rig.state.outputDevicesChanged()
        rig.connect(["a", "b"])
        rig.state.defaultDeviceChanged(uid: "b")
        rig.state.setSelectedDeviceUIDs(["a", "b", "gone"])

        #expect(rig.aggregates.stacks.count == 1)
        #expect(rig.engine.outputDevices.last == .some("a"), "it keeps playing on the clock device")
        #expect(rig.state.multiOutputDeviceUIDs.isEmpty)
    }

    @Test("a stack that failed to build is tried again once the devices make a different stack")
    func failedStackRetriesOnAChange() {
        let rig = Rig(devices: ["a", "b", "c"], defaultUID: "a")
        rig.aggregates.failsToMake = true
        rig.playOn(["a", "b"])
        rig.aggregates.failsToMake = false

        rig.state.setSelectedDeviceUIDs(["a", "b", "c"])

        #expect(rig.aggregates.stacks.last == MusicOutputStack(subDeviceUIDs: ["a", "b", "c"]))
        #expect(rig.engine.outputDevices.last == .some("agg-1"))
        #expect(rig.state.multiOutputDeviceUIDs == ["a", "b", "c"])
    }

    @Test("a stack that failed to build is tried again when the selection went down to one device and came back")
    func failedStackRetriesAfterAnAbsence() {
        let rig = Rig(devices: ["a", "b"], defaultUID: "a")
        rig.aggregates.failsToMake = true
        rig.playOn(["a", "b"])
        rig.state.setSelectedDeviceUIDs(["a"])  // down to one device: played directly, no stack wanted
        rig.aggregates.failsToMake = false

        rig.state.setSelectedDeviceUIDs(["a", "b"])

        #expect(rig.aggregates.stacks.count == 2)
        #expect(rig.engine.outputDevices.last == .some("agg-1"))
        #expect(rig.state.multiOutputDeviceUIDs == ["a", "b"])
    }

    @Test("a stack that failed once and then built is rebuilt normally after the next change")
    func successAfterFailureClearsTheMemory() {
        let rig = Rig(devices: ["a", "b", "c"], defaultUID: "a")
        rig.aggregates.failsToMake = true
        rig.playOn(["a", "b"])
        rig.aggregates.failsToMake = false
        rig.state.setSelectedDeviceUIDs(["a", "b", "c"])  // built
        rig.state.setSelectedDeviceUIDs(["a", "b"])       // [a, b] is a different stack than the live one

        #expect(rig.aggregates.stacks.last == MusicOutputStack(subDeviceUIDs: ["a", "b"]))
        #expect(rig.engine.outputDevices.last == .some("agg-2"), "[a, b] failed before but nothing remembers that now")
    }

    @Test("with no player attached nothing is built, and the aggregate comes when the player is attached")
    func waitsForThePlayer() {
        let rig = Rig(devices: ["a", "b"], defaultUID: "a", attach: false, prepare: {
            $0.setDeviceSelectionMode(for: musicKey, to: .multi)
            $0.setSelectedDeviceUIDs(for: musicKey, to: ["a", "b"])
        })
        #expect(rig.state.deviceSelectionMode == .multi)
        #expect(rig.aggregates.stacks.isEmpty)
        #expect(rig.state.multiOutputDeviceUIDs.isEmpty)

        rig.state.attach(engine: rig.engine)
        #expect(rig.aggregates.stacks == [MusicOutputStack(subDeviceUIDs: ["a", "b"])])
        #expect(rig.engine.outputDevices == [.some("agg-1")])
        #expect(rig.state.multiOutputDeviceUIDs == ["a", "b"])
    }

    @Test("a second player attached later is told the aggregate that already exists")
    func secondPlayerGetsTheSameAggregate() {
        let rig = Rig(devices: ["a", "b"], defaultUID: "a")
        rig.playOn(["a", "b"])
        let second = LoggingPlaybackEngine(log: rig.log)
        rig.state.attach(engine: second)

        #expect(second.outputDevices == [.some("agg-1")])
        #expect(rig.aggregates.stacks.count == 1)
        #expect(rig.aggregates.destroyed.isEmpty)
    }

    @Test("emptying the selection keeps the music where it is, and the empty selection is saved")
    func emptySelectionKeepsPlaying() {
        let rig = Rig(devices: ["a", "b"], defaultUID: "a")
        rig.playOn(["a", "b"])
        let mark = rig.log.events.count
        rig.state.setSelectedDeviceUIDs([])

        #expect(rig.events(since: mark).isEmpty, "no rebuild, no jump to the default output")
        #expect(rig.state.multiOutputDeviceUIDs == ["a", "b"])
        #expect(rig.settings.getSelectedDeviceUIDs(for: musicKey) == [])
    }

    @Test("a chosen device that is not connected is reported as missing in Multi too")
    func missingDeviceInMulti() {
        let rig = Rig(devices: ["x"], defaultUID: "x")
        #expect(!rig.state.isChosenDeviceMissing)
        rig.playOn(["a", "b"])
        #expect(rig.state.isChosenDeviceMissing, "none of the ticked devices is connected")
        rig.connect(["x", "a"])
        #expect(!rig.state.isChosenDeviceMissing, "one is enough to play on")
    }

    // MARK: Lifecycle

    @Test("changing the selection points the player at the new aggregate before the old one is destroyed")
    func newBeforeOld() {
        let rig = Rig(devices: ["a", "b", "c"], defaultUID: "a")
        rig.playOn(["a", "b"])
        let mark = rig.log.events.count
        rig.state.setSelectedDeviceUIDs(["a", "b", "c"])

        #expect(rig.events(since: mark) == [.made("agg-2"), .player("agg-2"), .destroyed("agg-1")])
        #expect(rig.aggregates.live.map(\.uid) == ["agg-2"])
    }

    @Test("a selected device connecting rebuilds in the same order")
    func deviceEventOrder() {
        let rig = Rig(devices: ["a", "b"], defaultUID: "a")
        rig.playOn(["a", "b", "c"])
        let mark = rig.log.events.count
        rig.connect(["a", "b", "c"])
        #expect(rig.events(since: mark) == [.made("agg-2"), .player("agg-2"), .destroyed("agg-1")])
    }

    @Test("a selected device dropping out sets the player back on the single output and then destroys the aggregate")
    func disconnectOrder() {
        let rig = Rig(devices: ["a", "b", "c"], defaultUID: "a")
        rig.playOn(["a", "b", "c"])
        let mark = rig.log.events.count
        rig.connect(["a", "b"])
        #expect(rig.events(since: mark) == [.player(nil), .destroyed("agg-1")])
    }

    @Test("dropping to one device sets the player first and then destroys the aggregate")
    func collapseOrder() {
        let rig = Rig(devices: ["a", "b"], defaultUID: "a")
        rig.playOn(["a", "b"])
        let mark = rig.log.events.count
        rig.state.setSelectedDeviceUIDs(["b"])
        #expect(rig.events(since: mark) == [.player("b"), .destroyed("agg-1")])
    }

    @Test("leaving Multi destroys the aggregate after the player is back on the single output")
    func leavingMultiDestroys() {
        let rig = Rig(devices: ["a", "b"], defaultUID: "a")
        rig.state.selectDevice(uid: "b")
        rig.playOn(["a", "b"])
        let mark = rig.log.events.count
        rig.state.setDeviceSelectionMode(.single)

        #expect(rig.events(since: mark) == [.player("b"), .destroyed("agg-1")])
        #expect(rig.aggregates.live.isEmpty)
        #expect(rig.state.multiOutputDeviceUIDs.isEmpty)
    }

    @Test("a set of devices that did not change builds nothing new")
    func unchangedSetDoesNotRebuild() {
        let rig = Rig(devices: ["a", "b", "c"], defaultUID: "a")
        rig.playOn(["a", "b"])
        let mark = rig.log.events.count

        rig.state.outputDevicesChanged()
        rig.connect(["a", "b", "c", "d"])      // a device that is not ticked appears
        rig.connect(["a", "b"])                // and goes
        rig.state.setSelectedDeviceUIDs(["a", "b", "gone"])   // an unplugged device is ticked
        rig.state.defaultDeviceChanged(uid: "c")
        rig.state.setSelectedDeviceUIDs(["a", "b", "gone"])

        #expect(rig.events(since: mark).isEmpty)
        #expect(rig.aggregates.stacks.count == 1)
    }

    @Test("quitting destroys the aggregate after the player is released from it, and nothing is built afterwards")
    func shutdownDestroys() {
        let rig = Rig(devices: ["a", "b"], defaultUID: "a")
        rig.playOn(["a", "b"])
        let mark = rig.log.events.count
        rig.state.shutdown()

        #expect(rig.events(since: mark) == [.player(nil), .destroyed("agg-1")])
        #expect(rig.state.multiOutputDeviceUIDs.isEmpty)

        let afterShutdown = rig.log.events.count
        rig.state.outputDevicesChanged()
        rig.state.setSelectedDeviceUIDs(["a"])
        rig.state.setSelectedDeviceUIDs(["a", "b"])
        #expect(rig.events(since: afterShutdown).isEmpty)
        rig.state.shutdown()
        #expect(rig.aggregates.destroyed.count == 1, "a second call destroys nothing twice")
    }

    @Test("quitting through the music host shuts the mixer down")
    func hostShutdownReachesTheMixer() {
        let rig = Rig(devices: ["a", "b"], defaultUID: "a")
        rig.playOn(["a", "b"])
        #expect(rig.aggregates.live.count == 1)
        MusicServiceHost(mixer: rig.state).shutdown()
        #expect(rig.aggregates.live.isEmpty)
        #expect(rig.aggregates.destroyed.count == 1)
    }

    @Test("dropping the mixer destroys a live aggregate")
    func deinitDestroys() {
        let log = MultiOutputEventLog()
        let aggregates = FakeOutputAggregates(log: log)
        let environment = FakeMusicMixerEnvironment()
        environment.outputDevices = [FakeMusicMixerEnvironment.device("a"), FakeMusicMixerEnvironment.device("b")]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("deci-multi-\(UUID().uuidString)")
        var state: MusicMixerState? = MusicMixerState(
            settings: SettingsManager(directory: directory),
            environment: environment,
            aggregates: aggregates
        )
        let engine = LoggingPlaybackEngine(log: log)   // the mixer holds its engine weakly
        state?.attach(engine: engine)
        state?.setDeviceSelectionMode(.multi)
        state?.setSelectedDeviceUIDs(["a", "b"])
        #expect(aggregates.live.count == 1)

        state = nil
        #expect(aggregates.live.isEmpty)
        #expect(aggregates.destroyed.count == 1)
        withExtendedLifetime(engine) {}
        try? FileManager.default.removeItem(at: directory)
    }

    @Test("resetting all settings leaves Multi and destroys the aggregate")
    func resetLeavesMulti() {
        let rig = Rig(devices: ["a", "b"], defaultUID: "a")
        rig.playOn(["a", "b"])
        #expect(rig.aggregates.live.count == 1)
        rig.state.settingsDidReset()

        #expect(rig.state.deviceSelectionMode == .single)
        #expect(rig.state.selectedDeviceUIDs.isEmpty)
        #expect(rig.aggregates.live.isEmpty)
        #expect(rig.engine.outputDevices.last == .some(nil))
        #expect(rig.state.multiOutputDeviceUIDs.isEmpty)
    }

    // MARK: A disconnect sends the music back to Single

    @Test("entering Multi records the time, and asking for Multi again keeps the first")
    func enteringMultiRecordsTheTime() {
        let rig = Rig(devices: ["a", "b"], defaultUID: "a")
        #expect(rig.multiSince == nil)

        let start = rig.clock.now
        rig.playOn(["a", "b"])
        #expect(rig.multiSince == start)

        rig.clock.advance(by: 30)
        rig.state.setDeviceSelectionMode(.multi)
        rig.state.setSelectedDeviceUIDs(["a"])
        #expect(rig.multiSince == start, "nothing restarts the clock while it stays in Multi")
    }

    @Test("leaving Multi clears the time, and coming back starts a fresh one")
    func leavingMultiClearsTheTime() {
        let rig = Rig(devices: ["a", "b"], defaultUID: "a")
        rig.playOn(["a", "b"])
        rig.clock.advance(by: 120)
        rig.state.setDeviceSelectionMode(.single)
        #expect(rig.multiSince == nil)

        rig.clock.advance(by: 120)
        rig.state.setDeviceSelectionMode(.multi)
        #expect(rig.multiSince == rig.clock.now)
    }

    @Test("a short session with no device chosen returns to System Audio, and the selection is kept")
    func shortSessionReturnsToSystemAudio() {
        let rig = Rig(devices: ["a", "b"], defaultUID: "a")
        rig.playOn(["a", "b"])
        rig.clock.advance(by: 600)
        let mark = rig.log.events.count
        rig.connect(["a"])

        #expect(rig.state.deviceSelectionMode == .single)
        #expect(rig.state.isFollowingDefault)
        #expect(rig.events(since: mark) == [.player(nil), .destroyed("agg-1")])
        #expect(rig.settings.getDeviceSelectionMode(for: musicKey) == .single)
        #expect(rig.settings.getDeviceRouting(for: musicKey) == nil)
        #expect(rig.state.selectedDeviceUIDs == ["a", "b"])
        #expect(rig.settings.getSelectedDeviceUIDs(for: musicKey) == ["a", "b"])
        #expect(rig.multiSince == nil)
    }

    @Test("a session just under the window returns to the device chosen before Multi")
    func shortSessionReturnsToTheChosenDevice() {
        let rig = Rig(devices: ["a", "b", "c"], defaultUID: "a")
        rig.state.selectDevice(uid: "c")
        rig.playOn(["a", "b"])
        rig.clock.advance(by: MultiOutputRevert.rememberWindow - 1)
        let mark = rig.log.events.count
        rig.connect(["a", "c"])

        #expect(rig.state.deviceSelectionMode == .single)
        #expect(rig.state.selectedDeviceUID == "c")
        #expect(rig.state.outputDeviceUID == "c")
        #expect(rig.events(since: mark) == [.player("c"), .destroyed("agg-1")])
        #expect(rig.settings.getDeviceRouting(for: musicKey) == "c")
        #expect(rig.settings.getSelectedDeviceUIDs(for: musicKey) == ["a", "b"])
    }

    @Test("a session of the full window goes to System Audio and forgets the device chosen before")
    func longSessionGoesToSystemAudio() {
        let rig = Rig(devices: ["a", "b", "c"], defaultUID: "a")
        rig.state.selectDevice(uid: "c")
        rig.playOn(["a", "b"])
        rig.clock.advance(by: MultiOutputRevert.rememberWindow)
        rig.connect(["a", "c"])

        #expect(rig.state.deviceSelectionMode == .single)
        #expect(rig.state.isFollowingDefault)
        #expect(rig.state.selectedDeviceUID == nil)
        #expect(rig.settings.getDeviceRouting(for: musicKey) == nil)
        #expect(rig.engine.outputDevices.last == .some(nil))

        // The forgotten device does not pull the music back when it comes and goes.
        rig.connect(["a", "b", "c"])
        rig.connect(["a", "b"])
        #expect(rig.state.isFollowingDefault)
        #expect(rig.engine.outputDevices.last == .some(nil))
    }

    @Test("a Multi choice with no recorded start goes to System Audio")
    func noRecordedStartGoesToSystemAudio() {
        let rig = Rig(devices: ["a", "b", "c"], defaultUID: "a", prepare: {
            $0.setDeviceRouting(for: musicKey, deviceUID: "c")
            $0.setDeviceSelectionMode(for: musicKey, to: .multi)
            $0.setSelectedDeviceUIDs(for: musicKey, to: ["a", "b"])
            $0.setMultiOutputSince(nil, for: musicKey)  // a file from before the start was recorded
        })
        #expect(rig.state.deviceSelectionMode == .multi)
        #expect(rig.multiSince == nil)

        rig.connect(["a", "c"])
        #expect(rig.state.deviceSelectionMode == .single)
        #expect(rig.state.selectedDeviceUID == nil)
        #expect(rig.settings.getDeviceRouting(for: musicKey) == nil)
    }

    @Test("a chosen device that is the one that dropped stays the saved choice and returns when it does")
    func chosenDeviceThatDroppedStaysChosen() {
        let rig = Rig(devices: ["a", "b", "c"], defaultUID: "a")
        rig.state.selectDevice(uid: "c")
        rig.playOn(["a", "c"])
        rig.clock.advance(by: 60)
        rig.connect(["a", "b"])

        #expect(rig.state.deviceSelectionMode == .single)
        #expect(rig.state.selectedDeviceUID == "c", "no new fallback: the choice stays")
        #expect(rig.settings.getDeviceRouting(for: musicKey) == "c")
        #expect(rig.state.outputDeviceUID == nil)
        #expect(rig.state.isChosenDeviceMissing)
        #expect(rig.engine.outputDevices.last == .some(nil), "the music plays on the default meanwhile")

        rig.connect(["a", "b", "c"])
        #expect(rig.state.outputDeviceUID == "c")
        #expect(rig.engine.outputDevices.last == .some("c"))
        #expect(rig.state.deviceSelectionMode == .single)
    }

    @Test("the device coming back does not rejoin Multi, and flipping back by hand builds the saved selection")
    func noAutoRejoinAndManualFlipBack() {
        let rig = Rig(devices: ["a", "b"], defaultUID: "a")
        rig.playOn(["a", "b"])
        rig.connect(["a"])
        rig.connect(["a", "b"])

        #expect(rig.state.deviceSelectionMode == .single)
        #expect(rig.engine.outputDevices.last == .some(nil))
        #expect(rig.aggregates.stacks.count == 1)
        #expect(rig.aggregates.live.isEmpty)

        rig.clock.advance(by: 5)
        rig.state.setDeviceSelectionMode(.multi)
        #expect(rig.state.deviceSelectionMode == .multi)
        #expect(rig.aggregates.stacks.last == MusicOutputStack(subDeviceUIDs: ["a", "b"]))
        #expect(rig.engine.outputDevices.last == .some("agg-2"))
        #expect(rig.multiSince == rig.clock.now)
    }

    @Test("a session that left Multi and came back is timed from the second entry")
    func freshClockAfterLeavingMulti() {
        let rig = Rig(devices: ["a", "b", "c"], defaultUID: "a")
        rig.state.selectDevice(uid: "c")
        rig.playOn(["a", "b"])
        rig.clock.advance(by: 7200)
        rig.state.setDeviceSelectionMode(.single)
        rig.state.setDeviceSelectionMode(.multi)
        rig.clock.advance(by: 60)
        rig.connect(["a", "c"])

        #expect(rig.state.deviceSelectionMode == .single)
        #expect(rig.state.selectedDeviceUID == "c", "a minute into the second session, not two hours")
    }

    @Test("a device that is not ticked dropping changes nothing")
    func unselectedDeviceChangesNothing() {
        let rig = Rig(devices: ["a", "b", "c"], defaultUID: "a")
        rig.playOn(["a", "b"])
        let start = rig.multiSince
        rig.clock.advance(by: 10)
        let mark = rig.log.events.count
        rig.connect(["a", "b"])

        #expect(rig.state.deviceSelectionMode == .multi)
        #expect(rig.events(since: mark).isEmpty)
        #expect(rig.multiSince == start)
    }

    @Test("a device dropping while the music is in Single changes nothing, whatever was ticked")
    func singleModeIgnoresALeftoverSelection() {
        let rig = Rig(devices: ["a", "b", "c"], defaultUID: "a")
        rig.playOn(["a", "b"])
        rig.state.setDeviceSelectionMode(.single)
        let mark = rig.log.events.count
        rig.connect(["a", "c"])

        #expect(rig.state.deviceSelectionMode == .single)
        #expect(rig.state.isFollowingDefault)
        #expect(rig.events(since: mark).isEmpty)
        #expect(rig.state.selectedDeviceUIDs == ["a", "b"])
    }

    @Test("a device away at launch is not a disconnect, and joins when it arrives")
    func awayAtLaunchIsNotADisconnect() {
        let rig = Rig(devices: ["a"], defaultUID: "a", prepare: {
            $0.setDeviceSelectionMode(for: musicKey, to: .multi)
            $0.setSelectedDeviceUIDs(for: musicKey, to: ["a", "b"])
        })
        rig.connect(["a"])
        #expect(rig.state.deviceSelectionMode == .multi)

        rig.connect(["a", "b"])
        #expect(rig.state.deviceSelectionMode == .multi)
        #expect(rig.state.multiOutputDeviceUIDs == ["a", "b"])
    }

    @Test("devices the engine reports after the mixer was built are arrivals, and only a later drop reverts")
    func devicesAppearingAfterLaunchAreNotDisconnects() {
        let rig = Rig(devices: [], prepare: {
            $0.setDeviceSelectionMode(for: musicKey, to: .multi)
            $0.setSelectedDeviceUIDs(for: musicKey, to: ["a", "b"])
        })
        rig.connect(["a"])
        rig.connect(["a", "b"])
        #expect(rig.state.deviceSelectionMode == .multi)
        #expect(rig.state.multiOutputDeviceUIDs == ["a", "b"])

        rig.connect(["a"])
        #expect(rig.state.deviceSelectionMode == .single)
    }

    @Test("unticking every device keeps the devices it plays on counted, so their drop still reverts")
    func emptiedSelectionStillCounts() {
        let rig = Rig(devices: ["a", "b"], defaultUID: "a")
        rig.playOn(["a", "b"])
        rig.state.setSelectedDeviceUIDs([])
        #expect(rig.state.multiOutputDeviceUIDs == ["a", "b"])

        rig.connect(["a"])
        #expect(rig.state.deviceSelectionMode == .single)
        #expect(rig.engine.outputDevices.last == .some(nil))
        #expect(rig.aggregates.live.isEmpty)
    }

    @Test("a mixer built without a clock times the session by the real time")
    func defaultClockIsTheRealOne() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("deci-multi-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = SettingsManager(directory: directory)
        let state = MusicMixerState(
            settings: settings,
            environment: FakeMusicMixerEnvironment(),
            aggregates: FakeOutputAggregates(log: MultiOutputEventLog())
        )
        let before = Date()
        state.setDeviceSelectionMode(.multi)
        let since = try #require(settings.getMultiOutputSince(for: musicKey))
        #expect(since >= before)
        #expect(since <= Date())
    }

    // MARK: multiOutputDeviceUIDs

    @Test("multiOutputDeviceUIDs lists the devices in the aggregate and is empty with fewer than two")
    func multiOutputContents() {
        let rig = Rig(devices: ["a", "b", "c"], defaultUID: "a")
        #expect(rig.state.multiOutputDeviceUIDs.isEmpty, "Single mode")

        rig.state.setDeviceSelectionMode(.multi)
        #expect(rig.state.multiOutputDeviceUIDs.isEmpty, "one device")

        rig.state.setSelectedDeviceUIDs(["a", "c", "gone"])
        #expect(rig.state.multiOutputDeviceUIDs == ["a", "c"], "only the connected ones")

        rig.state.setSelectedDeviceUIDs(["a", "gone"])
        #expect(rig.state.multiOutputDeviceUIDs.isEmpty, "down to one")

        rig.state.setSelectedDeviceUIDs(["a", "c", "gone"])
        #expect(rig.state.multiOutputDeviceUIDs == ["a", "c"])

        rig.state.setDeviceSelectionMode(.single)
        #expect(rig.state.multiOutputDeviceUIDs.isEmpty)
    }

    @Test("multiOutputDeviceUIDs is assigned only when the set really changes")
    func multiOutputAssignedOnChangeOnly() {
        let rig = Rig(devices: ["a", "b", "c"], defaultUID: "a")
        rig.playOn(["a", "b"])

        let counter = ChangeCounter()
        func watch() {
            withObservationTracking {
                _ = rig.state.multiOutputDeviceUIDs
            } onChange: {
                counter.count += 1
            }
        }
        watch()
        rig.state.outputDevicesChanged()
        rig.connect(["a", "b", "c", "d"])
        rig.state.setSelectedDeviceUIDs(["a", "b", "gone"])    // recomputed, same two devices
        rig.state.setSelectedDeviceUIDs(["b", "a", "gone"])
        #expect(counter.count == 0, "the same set must not wake the views")

        rig.state.setSelectedDeviceUIDs(["a", "b", "c"])
        #expect(counter.count == 1)
        #expect(rig.state.multiOutputDeviceUIDs == ["a", "b", "c"])
    }

    // MARK: AutoEQ

    // The engine's multi-device tap applies the AutoEQ profile and device volume of its first sorted device to the one
    // tap that feeds every device, with no fallback to another device's profile and the manual EQ left alone. The music
    // follows that: the lowest UID of the stack is the device in use.

    @Test("a stack takes the AutoEQ profile of its first sorted device, whichever device is the clock")
    func autoEQFollowsThePrimary() {
        let rig = Rig(devices: ["a", "b"], defaultUID: "b", bluetooth: ["a"])
        rig.environment.autoEQProfiles = ["a": profile("for-a"), "b": profile("for-b")]
        rig.state.setDeviceSelectionMode(.multi)
        #expect(rig.state.chain.autoEQProfile?.id == "for-b", "seeded on b alone")

        rig.state.setSelectedDeviceUIDs(["a", "b"])
        #expect(rig.aggregates.stacks.last?.clockDeviceUID == "b", "a is Bluetooth, so b clocks the stack")
        #expect(rig.state.effectiveDeviceUID == "a")
        #expect(rig.state.chain.autoEQProfile?.id == "for-a")
    }

    @Test("a stack does not borrow another device's profile when its primary has none")
    func autoEQHasNoFallback() {
        let rig = Rig(devices: ["a", "b"], defaultUID: "b")
        rig.environment.autoEQProfiles = ["b": profile("for-b")]
        rig.playOn(["a", "b"])
        #expect(rig.state.effectiveDeviceUID == "a")
        #expect(rig.state.chain.autoEQProfile == nil, "b has a profile and is the default, but a is the primary")
    }

    @Test("the manual EQ stays through Multi, and going back to Single returns to that device's profile")
    func manualEQStays() {
        let rig = Rig(devices: ["a", "b"], defaultUID: "b")
        rig.environment.autoEQProfiles = ["a": profile("for-a"), "b": profile("for-b")]
        var eq = EQSettings()
        eq.bandGains[3] = 6
        rig.state.setEQ(eq)

        rig.playOn(["a", "b"])
        #expect(rig.state.eqSettings == eq)
        #expect(rig.state.chain.eqSettings == eq)

        rig.state.setDeviceSelectionMode(.single)
        #expect(rig.state.chain.autoEQProfile?.id == "for-b")
        #expect(rig.state.chain.eqSettings == eq)
    }

    @Test("an AutoEQ change on the primary refreshes the chain, and one on another device of the stack does not")
    func autoEQChangeOnThePrimary() {
        let rig = Rig(devices: ["a", "b"], defaultUID: "b")
        rig.playOn(["a", "b"])
        #expect(rig.state.effectiveDeviceUID == "a")
        #expect(rig.state.chain.autoEQProfile == nil)

        rig.environment.autoEQProfiles["b"] = profile("for-b")
        rig.state.autoEQSelectionChanged(deviceUID: "b")
        #expect(rig.state.chain.autoEQProfile == nil)

        rig.environment.autoEQProfiles["a"] = profile("for-a")
        rig.state.autoEQSelectionChanged(deviceUID: "a")
        #expect(rig.state.chain.autoEQProfile?.id == "for-a")
    }
}
