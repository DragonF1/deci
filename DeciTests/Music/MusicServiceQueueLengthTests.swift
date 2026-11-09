// DeciTests/Music/MusicServiceQueueLengthTests.swift
// Every queued song gets a length: the queue asks the backend for the ones that arrived without, once each, 50 at a time,
// and keeps every answer so a song that comes back as a fresh copy without one gets it again without a new call.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("MusicService queue lengths")
struct MusicServiceQueueLengthTests {
    private func songs(_ ids: [String], seconds: Int? = nil) -> [Deci.MusicTrack] {
        ids.map { MusicSamples.track($0, title: "Song \($0)", artist: "Artist \($0)", seconds: seconds) }
    }

    private func askedCount(_ id: String, in calls: [[String]]) -> Int {
        var count = 0
        for batch in calls { for asked in batch where asked == id { count += 1 } }
        return count
    }

    private func lengths(_ h: MixShuffleHarness) -> [Int?] {
        h.service.queue.tracks.map { (track: Deci.MusicTrack) -> Int? in track.durationSeconds }
    }

    private func lengthById(_ h: MixShuffleHarness) -> [String: Int?] {
        var map: [String: Int?] = [:]
        for track in h.service.queue.tracks { map[track.videoId] = track.durationSeconds }
        return map
    }

    private func page(_ tracks: [Deci.MusicTrack]) -> MusicBrowsePage {
        MusicBrowsePage(
            browseId: "VLPLlengths", title: "Shelf", subtitle: nil, thumbnailURL: nil,
            tracks: tracks, continuation: nil, shelves: []
        )
    }

    /// Plays the first of `tracks` with the rest as its radio, and waits until the length asking has finished. The stream
    /// of each song is as long as the backend says, so the stream and the answer never disagree about the playing song.
    private func start(_ h: MixShuffleHarness, _ tracks: [Deci.MusicTrack], answers: [String: Int] = [:]) async {
        await h.backend.setQueueDurations(answers)
        for track in tracks {
            await h.backend.setStream(MusicSamples.stream(videoId: track.videoId, duration: Double(answers[track.videoId] ?? 240)))
        }
        await h.backend.setRadio(seed: tracks[0].videoId, tracks: tracks, continuation: nil)
        h.service.play(tracks[0])
        await h.settle()
        await h.service.queueLengthTask?.value
    }

    @Test("songs that arrive with no length get the one YouTube names")
    func fillsAfterPlay() async {
        let h = MixShuffleHarness(withReader: false)
        await start(h, songs(["a", "b", "c"]), answers: ["a": 201, "b": 202, "c": 203])
        #expect(lengths(h).compactMap { $0 }.sorted() == [201, 202, 203])
    }

    @Test("a song queued later by Add to queue is asked about too")
    func fillsAppended() async {
        let h = MixShuffleHarness(withReader: false)
        await start(h, songs(["a", "b"], seconds: 100))
        await h.backend.setQueueDurations(["x": 150, "y": 160])
        h.service.addToQueue(songs(["x", "y"]))
        await h.service.queueLengthTask?.value
        let map = lengthById(h)
        #expect(map["x"] == 150)
        #expect(map["y"] == 160)
    }

    @Test("a length the song already has is not asked for and not overwritten")
    func keepsKnownLengths() async {
        let h = MixShuffleHarness(withReader: false)
        var tracks = songs(["a", "b", "c"])
        tracks[0] = MusicSamples.track("a", title: "Song a", artist: "Artist a", seconds: 100)
        tracks[1] = MusicSamples.track("b", title: "Song b", artist: "Artist b", seconds: 110)
        await start(h, tracks, answers: ["a": 999, "b": 999, "c": 777])
        let calls = await h.backend.queueDurationCalls
        #expect(askedCount("a", in: calls) == 0)
        #expect(askedCount("b", in: calls) == 0)
        #expect(askedCount("c", in: calls) == 1)
        let map = lengthById(h)
        #expect(map["a"] == 100)
        #expect(map["b"] == 110)
        #expect(map["c"] == 777)
    }

    @Test("a song YouTube gives no length for is not asked again when the queue changes")
    func notAskedTwice() async {
        let h = MixShuffleHarness(withReader: false)
        await start(h, songs(["a", "b"]))
        h.service.addToQueue(songs(["z"]))
        await h.service.queueLengthTask?.value
        let calls = await h.backend.queueDurationCalls
        #expect(askedCount("a", in: calls) == 1)
        #expect(askedCount("b", in: calls) == 1)
        #expect(askedCount("z", in: calls) == 1)
    }

    @Test("a long queue is asked about in batches of at most 50, one call after another")
    func batchesOfFifty() async {
        let h = MixShuffleHarness(withReader: false)
        let ids = (0..<120).map { "s\($0)" }
        await start(h, songs(ids), answers: Dictionary(uniqueKeysWithValues: ids.map { ($0, 180) }))
        let calls = await h.backend.queueDurationCalls
        // The first call can hold the tapped song alone, asked before its radio arrived.
        #expect(calls.allSatisfy { $0.count <= 50 })
        #expect(calls.count >= 3)
        #expect(Set(calls.flatMap { $0 }) == Set(ids))
        #expect(lengths(h).allSatisfy { $0 == 180 })
    }

    @Test("playing the same page again fills the fresh copies from what was answered, with no new call")
    func samePageAgain() async {
        let h = MixShuffleHarness(withReader: false)
        let tracks = songs(["a", "b", "c"])
        for track in tracks { await h.backend.setStream(MusicSamples.stream(videoId: track.videoId, duration: 240)) }
        await h.backend.setQueueDurations(["a": 240, "b": 202, "c": 203])
        h.service.play(tracks[0], in: page(tracks))
        await h.settle()
        await h.service.queueLengthTask?.value
        let before = await h.backend.queueDurationCalls.count
        #expect(before > 0)
        h.service.play(tracks[1], in: page(tracks))
        await h.settle()
        await h.service.queueLengthTask?.value
        #expect(await h.backend.queueDurationCalls.count == before)
        let map = lengthById(h)
        #expect(map["b"] == 202)
        #expect(map["c"] == 203)
    }

    @Test("Play next with a no-length copy of a queued song gets the answered length with no new call")
    func playNextCopy() async {
        let h = MixShuffleHarness(withReader: false)
        await start(h, songs(["a", "b", "c"]), answers: ["a": 201, "b": 202, "c": 203])
        let before = await h.backend.queueDurationCalls.count
        h.service.playNext(songs(["c"])[0])
        await h.service.queueLengthTask?.value
        #expect(await h.backend.queueDurationCalls.count == before)
        #expect(lengthById(h)["c"] == 203)
    }

    @Test("a network failure is forgotten: the same songs are asked again on the next queue change")
    func transportFailureRetriesLater() async {
        let h = MixShuffleHarness(withReader: false)
        await h.backend.setQueueDurationError(URLError(.notConnectedToInternet))
        await start(h, songs(["a", "b", "c"]), answers: ["b": 202, "c": 203])
        #expect(lengthById(h)["b"] == .some(nil))
        // Each queue change during the start started a pass that failed the same way, so count from here.
        let failedAsks = askedCount("b", in: await h.backend.queueDurationCalls)
        await h.backend.setQueueDurationError(nil)
        h.service.addToQueue(songs(["z"]))
        await h.service.queueLengthTask?.value
        let calls = await h.backend.queueDurationCalls
        #expect(askedCount("b", in: calls) == failedAsks + 1)
        let map = lengthById(h)
        #expect(map["b"] == 202)
        #expect(map["c"] == 203)
    }

    @Test("an HTTP failure is not retried: the songs stay unasked-for and without a length")
    func httpFailureNotRetried() async {
        let h = MixShuffleHarness(withReader: false)
        await h.backend.setQueueDurationError(MusicError.http(500))
        await start(h, songs(["a", "b", "c"]), answers: ["b": 202, "c": 203])
        await h.backend.setQueueDurationError(nil)
        h.service.addToQueue(songs(["z"]))
        await h.service.queueLengthTask?.value
        let calls = await h.backend.queueDurationCalls
        #expect(askedCount("b", in: calls) == 1)
        #expect(lengthById(h)["b"] == .some(nil))
    }
}
