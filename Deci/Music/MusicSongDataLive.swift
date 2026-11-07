// Deci/Music/MusicSongDataLive.swift
import Foundation

extension MusicSongDataStore {
    /// Gives the Song data panel its facts side: the cache it reads, the online lookup, and the measuring. Done by the host
    /// after the service is built, so the service itself stays as it is.
    func attachFacts(
        repository: MusicSongFactsRepository, measurer: MusicSongMeasurer, isSignedOut: @escaping @MainActor () -> Bool
    ) {
        sources?.isSignedOut = isSignedOut
        sources?.cachedFacts = { await repository.cached(videoId: $0) }
        sources?.lookupFacts = { track in
            _ = await repository.lookup(videoId: track.videoId, query: MusicSongFactsQuery(track: track))
        }
        sources?.measure = { stream, needAnalysis, needBPM in
            await measurer.measure(stream: stream, needAnalysis: needAnalysis, needBPM: needBPM)
        }
    }
}
