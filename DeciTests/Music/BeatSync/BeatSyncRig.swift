// DeciTests/Music/BeatSync/BeatSyncRig.swift
// One measured run of the beat sync spike (tier 3a): the real `AVPlaybackEngine` (two AVPlayer decks, each with its
// `MusicDSPChain` tap) plays click track A, deck B is prerolled, then started at a host time on A's beat grid with
// `startStandby(atHostTime:rate:)`. The mixed output of this process is recorded by a muted process tap
// (`OwnProcessCapture`): nothing is heard. A and B are told apart by band (1 kHz and 3.2 kHz, on both channels).

import Foundation
import AVFoundation
import CoreMedia
@testable import Deci

nonisolated struct BeatSyncRunRecord: Codable, Sendable {
    var label: String
    var rate: Double
    var algorithm: String
    var clock: String
    var device: String
    var deviceUID: String
    var sampleRate: Double
    var startBeat: Int
    var overlapSeconds: Double
    var aCount: Int
    var bCount: Int
    var startErrorMs: Double
    var firstErrorMs: Double
    var meanErrorMs: Double
    var driftMs: Double
    var slopeDriftMs: Double
    var jitterMs: Double
    var matched: Int
    /// B's first click against the host time it was scheduled for (the capture's own host stamps), informational.
    var hostStartErrorMs: Double
    /// A's click on the start beat against where A's item timebase says it plays, informational.
    var aGridHostErrorMs: Double
    var failure: String?
    var errorsMs: [Double]
    var bOnsets: [Double]
}

nonisolated enum BeatSyncPaths {
    static let root = URL(fileURLWithPath: "/Volumes/Storage/_test/deci-3a/sync", isDirectory: true)
    static var runs: URL { root.appendingPathComponent("runs.jsonl") }
    static var files: URL { root.appendingPathComponent("files", isDirectory: true) }
}

nonisolated struct BeatSyncRunConfig: Sendable {
    var label: String
    var rate: Double = 1
    /// nil leaves the item's own default algorithm.
    var algorithm: AVAudioTimePitchAlgorithm?
    var clock: Clock = .none
    var overlapSeconds: Double = 16
    /// The chain's linear gain. The probe plays at 0.001 (-60 dB).
    var gain: Float = 1

    enum Clock: String, Sendable { case none, host, audioDevice }

    var algorithmName: String { algorithm?.rawValue ?? "default" }
}

@MainActor
final class BeatSyncRig {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static let fileSeconds = 100.0
    static let aFrequency = 1000.0
    static let bFrequency = 3200.0

    let capture: OwnProcessCapture
    private let urlA: URL
    private let urlB: URL

    private init(capture: OwnProcessCapture, urlA: URL, urlB: URL) {
        self.capture = capture
        self.urlA = urlA
        self.urlB = urlB
    }

    /// Writes the two click files (AAC in fragmented mp4, like the streams YouTube serves), starts the muted capture and
    /// proves it with a very quiet probe before anything plays at full level. Throws when the capture cannot be made:
    /// nothing has played then.
    static func open(deviceUID: String? = nil) async throws -> BeatSyncRig {
        try FileManager.default.createDirectory(at: BeatSyncPaths.files, withIntermediateDirectories: true)
        let urlA = BeatSyncPaths.files.appendingPathComponent("click-a-1000.m4a")
        let urlB = BeatSyncPaths.files.appendingPathComponent("click-b-3200.m4a")
        // The file rate is the usual 44.1 kHz of YouTube's AAC; the device rate is whatever the device runs at.
        for (url, frequency) in [(urlA, aFrequency), (urlB, bFrequency)] where !FileManager.default.fileExists(atPath: url.path) {
            let mono = BeatSyncSignal.clickTrack(frequency: frequency, sampleRate: 44_100, seconds: fileSeconds)
            var stereo = [Float](repeating: 0, count: mono.count * 2)
            for (index, value) in mono.enumerated() {
                stereo[index * 2] = value
                stereo[index * 2 + 1] = value
            }
            try await ToneFile.write(interleavedStereo: stereo, sampleRate: 44_100, to: url)
        }
        let capture = try OwnProcessCapture(deviceUID: deviceUID)
        try capture.start()
        let rig = BeatSyncRig(capture: capture, urlA: urlA, urlB: urlB)

        // Probe: -60 dB clicks must come out of the capture, or the capture is not seeing the players.
        var probe = BeatSyncRunConfig(label: "probe", overlapSeconds: 2)
        probe.gain = 0.001
        let heard = try await rig.play(probe)
        let peak = MusicTestSignal.peak(heard.recording.samples)
        let seen = ClickDetector.detect(heard.recording.samples, sampleRate: heard.recording.sampleRate, frequency: aFrequency).count
        guard peak > 1e-5, peak < 0.05, seen >= 3 else {
            capture.stop()
            throw Failure(description: "the capture does not see the players (peak \(peak), \(seen) clicks): not playing at full level")
        }
        return rig
    }

    func close() {
        capture.stop()
    }

    private func stream(_ name: String, url: URL) -> ResolvedStream {
        ResolvedStream(
            videoId: name, url: url, itag: 140, durationSeconds: Self.fileSeconds,
            expiresAt: .distantFuture, playbackTrackingURL: nil, httpHeaders: [:]
        )
    }

    struct Played {
        var recording: OwnProcessCapture.Recording
        var startBeat: Int
        var scheduledHostSeconds: Double
        var aGridHostSeconds: Double
    }

    private static func hostSeconds(_ time: CMTime) -> Double { time.seconds }

    /// Plays one run and returns the recording. The engine and chain are made fresh for it.
    private func play(_ config: BeatSyncRunConfig) async throws -> Played {
        let chain = MusicDSPChain(sampleRate: capture.sampleRate)
        chain.setTargetGain(config.gain, snap: true)
        let engine = AVPlaybackEngine(chain: chain)
        engine.setOutputDevice(uid: capture.outputDeviceUID)
        engine.avPlayer.preventsDisplaySleepDuringVideoPlayback = false
        switch config.clock {
        case .none:
            break
        case .host:
            let clock = CMClockGetHostTimeClock()
            engine.avPlayer.sourceClock = clock
            engine.standbyAvPlayer.sourceClock = clock
        case .audioDevice:
            var clock: CMClock?
            let status = CMAudioDeviceClockCreate(
                allocator: kCFAllocatorDefault, deviceUID: capture.outputDeviceUID as CFString, clockOut: &clock
            )
            guard status == noErr, let clock else { throw Failure(description: "CMAudioDeviceClockCreate \(status)") }
            engine.avPlayer.sourceClock = clock
            engine.standbyAvPlayer.sourceClock = clock
        }
        let urlB = urlB
        if let algorithm = config.algorithm {
            engine.willInstall = { item in
                if (item.asset as? AVURLAsset)?.url == urlB { item.audioTimePitchAlgorithm = algorithm }
            }
        }

        capture.beginRecording()
        engine.load(stream("a", url: urlA), startAt: 0, autoplay: true)
        engine.preload(stream("b", url: urlB))
        let ready = await waitUntil(timeout: .seconds(30)) {
            engine.preloadIsReady && engine.position > 1 && engine.avPlayer.timeControlStatus == .playing
        }
        guard ready else {
            _ = capture.endRecording()
            engine.unload()
            throw Failure(description: "deck A never played, or deck B never got ready")
        }
        let hostClock = CMClockGetHostTimeClock()
        var beat = Int(((engine.position + 1.6) / BeatSyncSignal.beatPeriod).rounded(.up))
        var host = engine.hostTime(ofActiveItemTime: Double(beat) * BeatSyncSignal.beatPeriod)
        while let candidate = host, CMTimeSubtract(candidate, CMClockGetTime(hostClock)).seconds < 1 {
            beat += 1
            host = engine.hostTime(ofActiveItemTime: Double(beat) * BeatSyncSignal.beatPeriod)
        }
        guard let host else {
            _ = capture.endRecording()
            engine.unload()
            throw Failure(description: "no host time for A's beat")
        }
        guard engine.startStandby(atHostTime: host, rate: Float(config.rate)) else {
            _ = capture.endRecording()
            engine.unload()
            throw Failure(description: "startStandby refused")
        }
        let stopAt = host.seconds + config.overlapSeconds + 0.6
        while CMClockGetTime(hostClock).seconds < stopAt { try await Task.sleep(for: .milliseconds(50)) }
        let recording = capture.endRecording()
        engine.unload()
        return Played(
            recording: recording, startBeat: beat, scheduledHostSeconds: host.seconds,
            aGridHostSeconds: host.seconds
        )
    }

    /// Plays and measures one run. A run that could not be measured comes back with `failure` set.
    func measure(_ config: BeatSyncRunConfig, deviceName: String? = nil) async throws -> BeatSyncRunRecord {
        let played = try await play(config)
        let samples = played.recording.samples
        let rate = played.recording.sampleRate
        let aOnsets = ClickDetector.detect(samples, sampleRate: rate, frequency: Self.aFrequency)
        let bOnsets = ClickDetector.detect(samples, sampleRate: rate, frequency: Self.bFrequency)
        var record = BeatSyncRunRecord(
            label: config.label, rate: config.rate, algorithm: config.algorithmName, clock: config.clock.rawValue,
            device: capture.outputDeviceName, deviceUID: capture.outputDeviceUID, sampleRate: rate,
            startBeat: played.startBeat, overlapSeconds: config.overlapSeconds,
            aCount: aOnsets.count, bCount: bOnsets.count,
            startErrorMs: 0, firstErrorMs: 0, meanErrorMs: 0, driftMs: 0, slopeDriftMs: 0, jitterMs: 0, matched: 0,
            hostStartErrorMs: 0, aGridHostErrorMs: 0, failure: nil, errorsMs: [], bOnsets: bOnsets
        )
        guard aOnsets.count > played.startBeat, let first = bOnsets.first else {
            record.failure = "clicks not found (A \(aOnsets.count), B \(bOnsets.count), start beat \(played.startBeat))"
            return record
        }
        // A's first click is beat 0, so its index is its beat; A's clicks must also be where the first callback says.
        let spacing = zip(aOnsets, aOnsets.dropFirst()).prefix(10).map { $1 - $0 }
        guard spacing.allSatisfy({ abs($0 - BeatSyncSignal.beatPeriod) < 0.01 }) else {
            record.failure = "A's clicks are not on a 0.5 s grid: \(spacing)"
            return record
        }
        guard let stats = BeatGrid.compare(
            aOnsets: aOnsets, bOnsets: bOnsets, startBeat: played.startBeat, rate: config.rate
        ) else {
            record.failure = "B's clicks do not match the expected grid (B first click at \(first) s)"
            return record
        }
        record.startErrorMs = stats.startErrorMs
        record.firstErrorMs = stats.firstErrorMs
        record.meanErrorMs = stats.meanErrorMs
        record.driftMs = stats.driftMs
        record.slopeDriftMs = stats.slopeDriftMs
        record.jitterMs = stats.jitterMs
        record.matched = stats.matched
        record.errorsMs = stats.errorsMs
        let base = played.recording.firstFrameHostSeconds
        record.hostStartErrorMs = (base + first - (played.scheduledHostSeconds + BeatSyncSignal.firstCenter / config.rate)) * 1000
        record.aGridHostErrorMs = (base + aOnsets[played.startBeat]
            - (played.aGridHostSeconds + BeatSyncSignal.firstCenter - 0)) * 1000
        return record
    }

    /// Tier 3b P3: A (120 bpm) mixed into B (126 bpm) the way the app does it. B is preloaded with a beat plan (mix-in 0,
    /// rate 120/126) and the engine itself schedules the start on A's beat at `rate`, with the calibration. The run stops
    /// when the overlap ends, before the rate glide. Nothing is heard: the capture mutes this process.
    func measureBeatMix(label: String, overlapSeconds: Double = 16) async throws -> BeatSyncRunRecord {
        let bBpm = 126.0
        let period = 60 / bBpm
        let rate = BeatSyncSignal.bpm / bBpm
        try FileManager.default.createDirectory(at: BeatSyncPaths.files, withIntermediateDirectories: true)
        let urlB126 = BeatSyncPaths.files.appendingPathComponent("click-b-3200-126bpm.m4a")
        if !FileManager.default.fileExists(atPath: urlB126.path) {
            let mono = BeatSyncSignal.clickTrack(
                frequency: Self.bFrequency, sampleRate: 44_100, seconds: Self.fileSeconds, period: period
            )
            var stereo = [Float](repeating: 0, count: mono.count * 2)
            for (index, value) in mono.enumerated() {
                stereo[index * 2] = value
                stereo[index * 2 + 1] = value
            }
            try await ToneFile.write(interleavedStereo: stereo, sampleRate: 44_100, to: urlB126)
        }
        let chain = MusicDSPChain(sampleRate: capture.sampleRate)
        chain.setTargetGain(1, snap: true)
        let engine = AVPlaybackEngine(chain: chain)
        engine.setOutputDevice(uid: capture.outputDeviceUID)
        engine.avPlayer.preventsDisplaySleepDuringVideoPlayback = false
        engine.crossfadeSeconds = 6
        let hostClock = CMClockGetHostTimeClock()

        capture.beginRecording()
        engine.load(stream("a", url: urlA), startAt: 0, autoplay: true)
        let playing = await waitUntil(timeout: .seconds(30)) {
            engine.position > 0.5 && engine.avPlayer.timeControlStatus == .playing
        }
        guard playing else {
            _ = capture.endRecording()
            engine.unload()
            throw Failure(description: "deck A never played")
        }
        // The mix-out is A's beat about 14 s on: the engine needs the preload and the schedule window before it.
        let beat = Int(((engine.position + 14) / BeatSyncSignal.beatPeriod).rounded(.up))
        let mixOut = Double(beat) * BeatSyncSignal.beatPeriod
        var plan = TransitionPlan(
            mode: .beat, incomingStartSec: 0, outgoingEndSec: mixOut + overlapSeconds, fadeStartSec: mixOut,
            fadeSeconds: overlapSeconds, incomingGainDb: 0, incomingGlideSeconds: 0, outgoingGainDb: 0,
            outgoingRampSeconds: 0, reason: .ok
        )
        plan.incomingRate = rate
        plan.mixOutSec = mixOut
        plan.mixInSec = 0
        plan.overlapBars = Int(overlapSeconds / (4 * BeatSyncSignal.beatPeriod))
        plan.overlapSec = overlapSeconds
        plan.barSec = 4 * BeatSyncSignal.beatPeriod
        plan.glideBackSec = 10
        engine.preload(
            ResolvedStream(
                videoId: "b", url: urlB126, itag: 140, durationSeconds: Self.fileSeconds,
                expiresAt: .distantFuture, playbackTrackingURL: nil, httpHeaders: [:]
            ),
            plan: plan
        )
        let scheduled = await waitUntil(timeout: .seconds(40)) { engine.scheduledStartHost != nil }
        guard scheduled, let host = engine.scheduledStartHost else {
            _ = capture.endRecording()
            engine.unload()
            throw Failure(description: "the engine never scheduled the beat mix")
        }
        let plannedRate = engine.debugPlannedRate
        let stopAt = host.seconds + overlapSeconds - 0.1
        while CMClockGetTime(hostClock).seconds < stopAt { try await Task.sleep(for: .milliseconds(50)) }
        let recording = capture.endRecording()
        engine.unload()

        let samples = recording.samples
        let sampleRate = recording.sampleRate
        let aOnsets = ClickDetector.detect(samples, sampleRate: sampleRate, frequency: Self.aFrequency)
        let bOnsets = ClickDetector.detect(samples, sampleRate: sampleRate, frequency: Self.bFrequency)
        var record = BeatSyncRunRecord(
            label: label, rate: rate, algorithm: "spectral", clock: "none",
            device: capture.outputDeviceName, deviceUID: capture.outputDeviceUID, sampleRate: sampleRate,
            startBeat: beat, overlapSeconds: overlapSeconds,
            aCount: aOnsets.count, bCount: bOnsets.count,
            startErrorMs: 0, firstErrorMs: 0, meanErrorMs: 0, driftMs: 0, slopeDriftMs: 0, jitterMs: 0, matched: 0,
            hostStartErrorMs: 0, aGridHostErrorMs: 0, failure: nil, errorsMs: [], bOnsets: bOnsets
        )
        guard abs(Double(plannedRate) - rate) < 1e-4 else {
            record.failure = "the engine planned rate \(plannedRate), not \(rate)"
            return record
        }
        guard aOnsets.count > beat, !bOnsets.isEmpty else {
            record.failure = "clicks not found (A \(aOnsets.count), B \(bOnsets.count), start beat \(beat))"
            return record
        }
        guard let stats = BeatGrid.compare(
            aOnsets: aOnsets, bOnsets: bOnsets, startBeat: beat, rate: rate, period: period
        ) else {
            record.failure = "B's clicks do not match the expected grid (first at \(bOnsets[0]) s)"
            return record
        }
        record.startErrorMs = stats.startErrorMs
        record.firstErrorMs = stats.firstErrorMs
        record.meanErrorMs = stats.meanErrorMs
        record.driftMs = stats.driftMs
        record.slopeDriftMs = stats.slopeDriftMs
        record.jitterMs = stats.jitterMs
        record.matched = stats.matched
        record.errorsMs = stats.errorsMs
        return record
    }

    /// Appends the record to `runs.jsonl` (one JSON object per line) as soon as it exists.
    static func append(_ record: BeatSyncRunRecord) throws {
        try FileManager.default.createDirectory(at: BeatSyncPaths.root, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(record) + Data("\n".utf8)
        if let handle = try? FileHandle(forWritingTo: BeatSyncPaths.runs) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: BeatSyncPaths.runs)
        }
    }
}
