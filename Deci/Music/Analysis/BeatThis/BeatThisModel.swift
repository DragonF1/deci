// Deci/Music/Analysis/BeatThis/BeatThisModel.swift
// The beat_this small0 network as a Core ML model: input `spect` float32 (1, 1500, 128), output `logits` float32
// (1, 2, 1500) with the beat logit in row 0 and the downbeat logit in row 1.

import Foundation
import CoreML

nonisolated final class BeatThisModel: @unchecked Sendable {
    enum Failure: Error, Equatable { case badOutput }

    private let model: MLModel

    /// `url` is a compiled model (.mlmodelc).
    init(compiledURL url: URL, computeUnits: MLComputeUnits = .all) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        model = try MLModel(contentsOf: url, configuration: configuration)
    }

    /// Compiles an .mlpackage (tests only; the app bundles the compiled model).
    static func compile(package url: URL) throws -> URL { try MLModel.compileModel(at: url) }

    func predict(chunk: [Float]) throws -> BeatThisChunker.Logits {
        let frames = BeatThisChunker.chunkFrames, bands = BeatThisChunker.bands
        precondition(chunk.count == frames * bands)
        return try autoreleasepool {
            let input = try MLMultiArray(shape: [1, NSNumber(value: frames), NSNumber(value: bands)], dataType: .float32)
            chunk.withUnsafeBufferPointer { source in
                input.dataPointer.copyMemory(from: source.baseAddress!, byteCount: chunk.count * MemoryLayout<Float>.size)
            }
            let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["spect": MLFeatureValue(multiArray: input)]))
            guard let logits = output.featureValue(for: "logits")?.multiArrayValue,
                  logits.shape.map(\.intValue) == [1, 2, frames] else { throw Failure.badOutput }
            func row(_ r: Int) throws -> [Float] {
                let strides = logits.strides.map(\.intValue)
                return try (0..<frames).map { t in
                    let offset = r * strides[1] + t * strides[2]
                    switch logits.dataType {
                    case .float16:
                        // Float16 does not exist on Intel Macs; the model's declared output is float32 so this is a
                        // fallback that only arm64 needs.
                        #if arch(arm64)
                        return Float(logits.dataPointer.assumingMemoryBound(to: Float16.self)[offset])
                        #else
                        throw Failure.badOutput
                        #endif
                    case .double: return Float(logits.dataPointer.assumingMemoryBound(to: Double.self)[offset])
                    default: return logits.dataPointer.assumingMemoryBound(to: Float.self)[offset]
                    }
                }
            }
            return BeatThisChunker.Logits(beat: try row(0), downbeat: try row(1))
        }
    }
}

/// The whole pipeline: samples (mono, 22050 Hz) to beat and downbeat times.
nonisolated struct BeatThisTracker: @unchecked Sendable {
    let mel: BeatThisMel
    let model: BeatThisModel

    struct Output {
        var beats: [Double]
        var downbeats: [Double]
        var frames: Int
    }

    /// nil when the task is cancelled. An empty output for audio too short to analyse.
    func track(samples: [Float]) throws -> Output? {
        let spect = mel.logMel(samples)
        if Task.isCancelled { return nil }
        let length = spect.count / BeatThisMel.bands
        let starts = BeatThisChunker.starts(length: length)
        var logits: [BeatThisChunker.Logits] = []
        for start in starts {
            if Task.isCancelled { return nil }
            logits.append(try model.predict(chunk: BeatThisChunker.chunk(spect: spect, length: length, start: start)))
        }
        let piece = BeatThisChunker.aggregate(starts: starts, logits: logits, length: length)
        let picked = BeatThisPeaks.pick(beat: piece.beat, downbeat: piece.downbeat)
        return Output(beats: picked.beats, downbeats: picked.downbeats, frames: length)
    }
}
