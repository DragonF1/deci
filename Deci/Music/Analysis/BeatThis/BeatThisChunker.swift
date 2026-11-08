// Deci/Music/Analysis/BeatThis/BeatThisChunker.swift
// beat_this inference splits a spectrogram into overlapping 1500 frame chunks (border 6), runs the network on each and
// keeps the middle of every chunk's output (keep_first: the earlier chunk wins an overlap). The Core ML model has a
// fixed 1500 frame input, so a short piece is zero-padded on the right to 1500.

import Foundation

nonisolated enum BeatThisChunker {
    static let chunkFrames = 1500
    static let border = 6
    static let step = chunkFrames - 2 * border
    static let bands = BeatThisMel.bands

    /// Chunk start frames for a piece of `length` frames: -6, 1482, ... and, when the piece is longer than one step,
    /// the last start moved left so that the last chunk ends 6 frames past the piece.
    static func starts(length: Int) -> [Int] {
        guard length > 0 else { return [] }
        var starts = Array(stride(from: -border, to: length - border, by: step))
        if length > step, !starts.isEmpty { starts[starts.count - 1] = length - (chunkFrames - border) }
        return starts
    }

    /// One chunk of the (time, 128) matrix: 1500 x 128 values, zero where the chunk lies outside the piece.
    static func chunk(spect: [Float], length: Int, start: Int) -> [Float] {
        var out = [Float](repeating: 0, count: chunkFrames * bands)
        let from = max(start, 0), to = min(start + chunkFrames, length)
        guard from < to else { return out }
        let destination = (from - start) * bands
        spect.withUnsafeBufferPointer { source in
            out.withUnsafeMutableBufferPointer { target in
                for i in 0..<((to - from) * bands) { target[destination + i] = source[from * bands + i] }
            }
        }
        return out
    }

    /// One chunk's network output: a beat logit and a downbeat logit per frame (1500 each).
    struct Logits { var beat: [Float]; var downbeat: [Float] }

    /// Stitches chunk outputs into piece-length logits. Unwritten frames stay at -1000.
    static func aggregate(starts: [Int], logits: [Logits], length: Int) -> Logits {
        var beat = [Float](repeating: -1000, count: length)
        var down = [Float](repeating: -1000, count: length)
        // Reverse order: the earlier chunk is written last and so wins (keep_first).
        for index in stride(from: starts.count - 1, through: 0, by: -1) {
            let start = starts[index]
            for j in border..<(chunkFrames - border) {
                let position = start + j
                guard position >= 0, position < length else { continue }
                beat[position] = logits[index].beat[j]
                down[position] = logits[index].downbeat[j]
            }
        }
        return Logits(beat: beat, downbeat: down)
    }
}
