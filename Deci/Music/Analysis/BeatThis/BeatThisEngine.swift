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

    /// Loaded on first use, under the static initialiser's lock. Several models in one process crashed Core ML, so
    /// there is exactly one.
    private static let shared: Result<BeatThisTracker, Error> = Result {
        try makeTracker(bundle: Bundle.main)
    }

    /// The shared tracker, or nil when the model could not be loaded.
    static var sharedTracker: BeatThisTracker? {
        if case .success(let tracker) = shared { return tracker }
        return nil
    }

    static func makeTracker(bundle: Bundle, computeUnits: MLComputeUnits = .cpuAndNeuralEngine) throws -> BeatThisTracker {
        guard let modelURL = bundle.url(forResource: modelName, withExtension: "mlmodelc"),
              let filterbankURL = bundle.url(forResource: filterbankName, withExtension: "bin") else {
            throw CocoaError(.fileNoSuchFile)
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
        let tracker: BeatThisTracker
        switch shared {
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
