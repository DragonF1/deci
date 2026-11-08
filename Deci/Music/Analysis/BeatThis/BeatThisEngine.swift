// Deci/Music/Analysis/BeatThis/BeatThisEngine.swift
//
// NOTICE: this folder ports beat_this (Foscarin, Schlueter, Widmer, "Beat This! Accurate beat tracking without DBN
// postprocessing", ISMIR 2024) to Swift and Core ML. The method, the small0 model weights and the reference
// postprocessing are from https://github.com/CPJKU/beat_this (commit b95c8ab), MIT license, Copyright (c) 2024
// Institute of Computational Perception, JKU Linz, Austria. The license text is in LICENSE-beat_this.txt.
//
// The engine loads the Core ML model once per process and turns a mono 22050 Hz sample array into a MusicBeatGrid.
// Anything that goes wrong (missing resource, model error, too few beats) answers nil and the caller falls back to
// the own beat finder.

import Foundation
import CoreML
import os

private let logger = Logger(subsystem: "com.abraham.Deci", category: "MusicAnalysis")

nonisolated enum BeatThisEngine {
    static let modelName = "BeatThis_small0_f16"
    static let filterbankName = "mel_filterbank_128x513_f32le"

    enum Failure: Error, Equatable {
        /// The model or the filterbank is not in the bundle: nothing a retry can fix.
        case missingResource
    }

    /// Loaded on first use. Several models in one process crashed Core ML, so a loaded model is kept for the life of
    /// the process and there is exactly one. A missing resource is cached for life; any other load error (Core ML can
    /// fail transiently) is retried at most once per `retryAfter`.
    private static let loader = BeatThisLoader<BeatThisTracker>(isPermanent: { ($0 as? Failure) == .missingResource }) {
        try makeTracker(bundle: Bundle.main)
    }

    /// The shared tracker, or nil when the model could not be loaded.
    static var sharedTracker: BeatThisTracker? {
        if case .success(let tracker) = loader.get() { return tracker }
        return nil
    }

    static func makeTracker(bundle: Bundle, computeUnits: MLComputeUnits = .cpuAndNeuralEngine) throws -> BeatThisTracker {
        guard let modelURL = bundle.url(forResource: modelName, withExtension: "mlmodelc"),
              let filterbankURL = bundle.url(forResource: filterbankName, withExtension: "bin") else {
            throw Failure.missingResource
        }
        let model = try BeatThisModel(compiledURL: modelURL, computeUnits: computeUnits)
        let mel = try BeatThisMel(filterbank: BeatThisMel.loadFilterbank(url: filterbankURL))
        return BeatThisTracker(mel: mel, model: model)
    }

    enum Outcome {
        case grid(MusicBeatGrid)
        /// The model ran but the beats did not fit a grid (too few, or silence): the finder gets a turn.
        case noGrid
        case cancelled
        case unavailable(String)
    }

    /// `samples` are mono at 22050 Hz, the first sample at time 0 of the song.
    static func grid(samples: [Float], duration: Double) -> Outcome {
        // Bounded input: a song longer than 20 minutes (or one with no real duration) is the finder's.
        guard duration.isFinite, duration > 0, duration <= BeatThisResampler.maxSongSeconds,
              samples.count <= Int(BeatThisResampler.maxSongSeconds * BeatThisResampler.outputRate) + 22_050 else {
            return .unavailable("input: length")
        }
        let tracker: BeatThisTracker
        switch loader.get() {
        case .success(let value): tracker = value
        case .failure(let error): return .unavailable("load: \(error.localizedDescription)")
        }
        do {
            guard let output = try tracker.track(samples: samples) else { return .cancelled }
            guard let grid = BeatThisGridFit.grid(beats: output.beats, downbeats: output.downbeats, duration: duration) else {
                return .noGrid
            }
            return .grid(grid)
        } catch {
            return .unavailable("predict: \(error.localizedDescription)")
        }
    }
}

/// Holds the result of a load: a success for life, a permanent failure for life, any other failure until `retryAfter`
/// seconds have passed. The load runs under the lock, so two callers never load two models.
nonisolated final class BeatThisLoader<Value: Sendable>: @unchecked Sendable {
    static var retryAfterDefault: TimeInterval { 600 }

    private let lock = NSLock()
    private let isPermanent: (Error) -> Bool
    private let load: () throws -> Value
    private let retryAfter: TimeInterval
    private var value: Value?
    private var failure: Error?
    private var failedAt: Date?
    private(set) var attempts = 0

    init(retryAfter: TimeInterval = BeatThisLoader.retryAfterDefault, isPermanent: @escaping (Error) -> Bool,
         load: @escaping () throws -> Value) {
        self.retryAfter = retryAfter
        self.isPermanent = isPermanent
        self.load = load
    }

    func get(now: Date = Date()) -> Result<Value, Error> {
        lock.lock()
        defer { lock.unlock() }
        if let value { return .success(value) }
        if let failure, let failedAt, isPermanent(failure) || now.timeIntervalSince(failedAt) < retryAfter {
            return .failure(failure)
        }
        attempts += 1
        do {
            let loaded = try load()
            value = loaded
            failure = nil
            return .success(loaded)
        } catch {
            failure = error
            failedAt = now
            return .failure(error)
        }
    }
}
