// DeciTests/Music/BeatSync/OwnProcessCapture.swift
// Ground truth for the beat sync spike: a Core Audio process tap on this very process, muted, so what the two
// AVPlayers hand to the output device is recorded and nothing is heard. Built the way Deci's ProcessTapController
// builds its tap and aggregate (private aggregate clocked by the output device, tap in its tap list) and torn down
// through `TapResources.destroy()`, but with no output: the IO proc writes zeros and keeps the input.

import Foundation
import AudioToolbox
import AVFoundation
import CoreAudio
import Synchronization
@testable import Deci

nonisolated final class OwnProcessCapture: @unchecked Sendable {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    struct Recording {
        var samples: [Float]
        var sampleRate: Double
        /// Host clock time, in seconds, of the first recorded frame (the input time of the first callback).
        var firstFrameHostSeconds: Double
    }

    let outputDeviceUID: String
    let outputDeviceName: String
    private(set) var sampleRate: Double = 0

    private let capacity: Int
    private let buffer: UnsafeMutablePointer<Float>
    private let writeIndex = Atomic<Int>(0)
    private let recording = Atomic<Bool>(false)
    private let firstHostTicks = Atomic<UInt64>(0)
    private let callbackCount = Atomic<Int>(0)
    private var resources = TapResources()

    /// - Parameters:
    ///   - deviceUID: The output device the aggregate is clocked by. nil is the system default output.
    ///   - maxSeconds: The longest recording `beginRecording` to `endRecording` can hold.
    init(deviceUID: String?, maxSeconds: Double = 120) throws {
        let device: AudioDeviceID
        let uid: String
        if let deviceUID, !deviceUID.isEmpty {
            guard let found = try Self.deviceID(forUID: deviceUID) else { throw Failure(description: "no device \(deviceUID)") }
            device = found
            uid = deviceUID
        } else {
            device = try AudioDeviceID.readDefaultOutputDevice()
            uid = try device.readDeviceUID()
        }
        outputDeviceUID = uid
        outputDeviceName = (try? device.readDeviceName()) ?? uid
        capacity = Int(maxSeconds * 96_000)
        buffer = .allocate(capacity: capacity)
        buffer.initialize(repeating: 0, count: capacity)
    }

    deinit {
        stop()
        buffer.deallocate()
    }

    private static func deviceID(forUID uid: String) throws -> AudioDeviceID? {
        for device in try AudioObjectID.readDeviceList() where (try? device.readDeviceUID()) == uid { return device }
        return nil
    }

    /// This process's audio object. A process only has one once it has used audio, so a silent engine is started and
    /// stopped to make it appear (it has no source and its output volume is 0).
    private static func ownProcessObject() throws -> AudioObjectID {
        func lookup() -> AudioObjectID {
            var pid = getpid()
            var object = AudioObjectID(kAudioObjectUnknown)
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let status = AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object
            )
            return status == noErr ? object : AudioObjectID(kAudioObjectUnknown)
        }
        if lookup() != AudioObjectID(kAudioObjectUnknown) { return lookup() }
        let engine = AVAudioEngine()
        engine.mainMixerNode.outputVolume = 0
        engine.prepare()
        try engine.start()
        defer { engine.stop() }
        for _ in 0..<100 {
            let object = lookup()
            if object != AudioObjectID(kAudioObjectUnknown) { return object }
            Thread.sleep(forTimeInterval: 0.02)
        }
        throw Failure(description: "this process has no audio object")
    }

    /// Creates the muted tap and the aggregate, starts the IO proc, and waits for its first callback.
    /// Throws (and leaves nothing behind) when any step fails: the caller must not play then.
    func start() throws {
        guard !resources.isActive else { return }
        let processObject = try Self.ownProcessObject()
        let description = CATapDescription(stereoMixdownOfProcesses: [processObject])
        description.uuid = UUID()
        description.muteBehavior = .muted
        description.isPrivate = true
        guard description.muteBehavior == .muted else { throw Failure(description: "tap is not muted") }

        var tapID = AudioObjectID.unknown
        let tapStatus = AudioHardwareCreateProcessTap(description, &tapID)
        guard tapStatus == noErr else { throw Failure(description: "AudioHardwareCreateProcessTap \(tapStatus)") }
        resources.tapID = tapID
        resources.tapDescription = description

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Deci-beat-sync-spike",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputDeviceUID]],
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString],
            ],
        ]
        var aggregateID = AudioObjectID.unknown
        let aggregateStatus = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        guard aggregateStatus == noErr else {
            stop()
            throw Failure(description: "AudioHardwareCreateAggregateDevice \(aggregateStatus)")
        }
        resources.aggregateDeviceID = aggregateID
        guard aggregateID.waitUntilReady(timeout: 2) else {
            stop()
            throw Failure(description: "aggregate not ready")
        }
        sampleRate = (try? aggregateID.readNominalSampleRate()) ?? 48_000

        let queue = DispatchQueue(label: "deci.beat-sync.capture", qos: .userInteractive)
        let status = AudioDeviceCreateIOProcIDWithBlock(&resources.deviceProcID, aggregateID, queue) {
            [self] _, inInputData, inInputTime, outOutputData, _ in
            self.render(input: inInputData, inputTime: inInputTime, output: outOutputData)
        }
        guard status == noErr else {
            stop()
            throw Failure(description: "AudioDeviceCreateIOProcIDWithBlock \(status)")
        }
        let started = AudioDeviceStart(aggregateID, resources.deviceProcID)
        guard started == noErr else {
            stop()
            throw Failure(description: "AudioDeviceStart \(started)")
        }
        let deadline = Date().addingTimeInterval(8)
        while callbackCount.load(ordering: .acquiring) < 3 {
            guard Date() < deadline else {
                stop()
                throw Failure(description: "the capture's IO proc never ran (device \(outputDeviceUID), rate \(sampleRate), callbacks \(callbackCount.load(ordering: .acquiring)))")
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    func stop() {
        resources.destroy()
    }

    private func render(
        input: UnsafePointer<AudioBufferList>, inputTime: UnsafePointer<AudioTimeStamp>,
        output: UnsafeMutablePointer<AudioBufferList>
    ) {
        for buffer in UnsafeMutableAudioBufferListPointer(output) {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
        callbackCount.wrappingAdd(1, ordering: .releasing)
        guard recording.load(ordering: .acquiring) else { return }
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard list.count > 0 else { return }
        var at = writeIndex.load(ordering: .relaxed)
        if at == 0 { firstHostTicks.store(inputTime.pointee.mHostTime, ordering: .relaxed) }
        if list.count == 1 {
            let channels = max(1, Int(list[0].mNumberChannels))
            let frames = Int(list[0].mDataByteSize) / (MemoryLayout<Float>.size * channels)
            guard let data = list[0].mData?.assumingMemoryBound(to: Float.self), at + frames <= capacity else { return }
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<channels { sum += data[frame * channels + channel] }
                buffer[at + frame] = sum / Float(channels)
            }
            at += frames
        } else {
            let frames = Int(list[0].mDataByteSize) / MemoryLayout<Float>.size
            guard let left = list[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = list[1].mData?.assumingMemoryBound(to: Float.self), at + frames <= capacity else { return }
            for frame in 0..<frames { buffer[at + frame] = 0.5 * (left[frame] + right[frame]) }
            at += frames
        }
        writeIndex.store(at, ordering: .releasing)
    }

    func beginRecording() {
        recording.store(false, ordering: .releasing)
        Thread.sleep(forTimeInterval: 0.03)
        writeIndex.store(0, ordering: .relaxed)
        recording.store(true, ordering: .releasing)
    }

    func endRecording() -> Recording {
        recording.store(false, ordering: .releasing)
        Thread.sleep(forTimeInterval: 0.05)
        let count = writeIndex.load(ordering: .acquiring)
        let samples = Array(UnsafeBufferPointer(start: buffer, count: count))
        let nanos = AudioConvertHostTimeToNanos(firstHostTicks.load(ordering: .relaxed))
        return Recording(samples: samples, sampleRate: sampleRate, firstFrameHostSeconds: Double(nanos) / 1e9)
    }
}
