// Deci/Music/SongFacts/MusicSongMeasurer.swift
import Foundation
import os

private let logger = Logger(subsystem: "com.abraham.Deci", category: "MusicSongFacts")

/// How one measurement ended. The results themselves are in the stores: the analysis row in the analysis database and
/// the tempo in the song facts cache.
struct MusicSongMeasureResult: Equatable, Sendable {
    enum Problem: Equatable, Sendable {
        /// The song could not be fetched because YouTube said to slow down.
        case rateLimited
        case failed
    }

    var problem: Problem?
}

/// The Song data panel's own measuring, for what no service said: the 2a analysis of a song that has none (loudness,
/// silence, intro and outro), and the tempo from Deci's beat finder. One download serves both when both are needed.
/// Each step runs off the main actor, and a cancel (the panel switched or closed) stops it at the next step.
struct MusicSongMeasurer: Sendable {
    typealias Decode = @Sendable (URL) async throws -> MusicBeatDecoder.Decoded
    typealias Find = @Sendable ([Float], Double) -> MusicBeatResult

    let analysis: any MusicAnalysisProviding
    let facts: MusicSongFactsStore
    var decode: Decode = { try await MusicBeatDecoder.decodeMono(file: $0) }
    var find: Find = { MusicBeatFinder.analyze(samples: $0, sampleRate: $1) }

    /// `needAnalysis`: no 2a row is stored. `needBPM`: no service gave a tempo and none was measured yet.
    @concurrent
    func measure(stream: ResolvedStream, needAnalysis: Bool, needBPM: Bool) async -> MusicSongMeasureResult {
        let id = stream.videoId
        // A file on this Mac (a download, or a cached copy that is playing) is read where it is: nothing to fetch or pin.
        var file: URL? = stream.url.isFileURL ? stream.url : nil
        var pinned = false
        var problem: MusicSongMeasureResult.Problem?

        // A cached copy was analysed before it was cached, so only a network stream or a download is analysed here.
        if needAnalysis, stream.origin != .trackCache {
            switch await analysis.ensure(stream: stream, wantsFile: needBPM && file == nil) {
            case .analysed(let kept):
                if let kept { file = kept; pinned = true }
            case .alreadyFresh:
                break
            case .rateLimited:
                problem = .rateLimited
            case .failed:
                problem = .failed
            }
        }

        guard needBPM, !Task.isCancelled else {
            if pinned { await analysis.release(videoId: id) }
            return MusicSongMeasureResult(problem: problem)
        }
        // A fetch that just failed is not repeated for the tempo.
        if file == nil, problem == nil {
            switch await analysis.pinnedFile(for: stream) {
            case .file(let url): file = url; pinned = true
            case .rateLimited: problem = .rateLimited
            case .failed: problem = .failed
            }
        }
        guard let file else { return MusicSongMeasureResult(problem: problem) }

        let outcome = await tempo(of: file)
        if pinned { await analysis.release(videoId: id) }
        switch outcome {
        case .tempo(let bpm, let confidence):
            await facts.putMeasured(videoId: id, bpm: bpm, confidence: confidence)
        case .none:
            await facts.putMeasured(videoId: id, bpm: nil, confidence: nil)
        case .cancelled:
            break
        case .failed:
            problem = problem ?? .failed
        }
        return MusicSongMeasureResult(problem: problem)
    }

    private enum TempoOutcome {
        case tempo(bpm: Double, confidence: Double)
        /// The file was read and has no usable tempo.
        case none
        case cancelled
        case failed
    }

    private func tempo(of file: URL) async -> TempoOutcome {
        do {
            let decoded = try await decode(file)
            if Task.isCancelled { return .cancelled }
            let result = find(decoded.samples, decoded.sampleRate)
            if Task.isCancelled { return .cancelled }
            return result.isEmpty ? .none : .tempo(bpm: result.bpm, confidence: result.confidence)
        } catch is CancellationError {
            return .cancelled
        } catch {
            logger.notice("songfacts_decode_failed kind=\(String(describing: type(of: error)), privacy: .public)")
            return .failed
        }
    }
}
