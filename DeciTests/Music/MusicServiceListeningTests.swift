// DeciTests/Music/MusicServiceListeningTests.swift
// The service's side of the local listening history: seconds heard are counted per session (not paused time, not seek
// jumps), a play needs 30 s or half the song, each session is noted once, and the crossfade flip does not count twice.

import Foundation
import os
import Testing
@testable import Deci

nonisolated final class FakeListeningLog: MusicListeningRecording {
    struct Note: Equatable {
        let videoId: String
        let seconds: TimeInterval
        let countsAsPlay: Bool
    }

    private let state = OSAllocatedUnfairLock(initialState: (notes: [Note](), flushes: 0))
    var notes: [Note] { state.withLock { $0.notes } }
    var flushes: Int { state.withLock { $0.flushes } }

    func note(videoId: String, seconds: TimeInterval, countsAsPlay: Bool, at date: Date) {
        state.withLock { $0.notes.append(Note(videoId: videoId, seconds: seconds, countsAsPlay: countsAsPlay)) }
    }

    func entry(for videoId: String) async -> MusicListeningEntry? { nil }
    func flushNow() { state.withLock { $0.flushes += 1 } }
}

@MainActor
private struct ListeningHarness {
    let backend = FakeMusicBackend()
    let engine = FakePlaybackEngine()
    let surface = FakeNowPlayingSurface()
    let clock = MutableClock()
    let log = FakeListeningLog()
    let player: MusicPlayer
    let service: MusicService

    init(crossfade: Bool = true) {
        let engine = self.engine
        let clock = self.clock
        let player = MusicPlayer(engine: engine)
        self.player = player
        self.service = MusicService(
            backend: backend,
            player: player,
            presentSignIn: { _ in },
            presentChannelPicker: { _, _ in },
            closeSignInWindow: {},
            raiseSignInWindow: {},
            nowPlaying: NowPlayingController(surface: surface, fetchArtwork: { _ in nil }),
            now: { clock.now },
            preferences: MusicPlaybackPreferences(crossfade: crossfade, crossfadeSeconds: 6),
            queueRetryDelay: .seconds(60),
            refreshOnCreate: false,
            listening: log
        )
    }

    func settle() async {
        while true {
            let play = service.playTask
            let radio = service.radioTask
            await play?.value
            await radio?.value
            if service.playTask == play, service.radioTask == radio { break }
        }
    }

    func startQueue(_ ids: [String]) async {
        let tracks = ids.map { MusicSamples.track($0, title: "Song \($0)") }
        await backend.setRadio(seed: ids[0], tracks: tracks, continuation: nil)
        service.play(tracks[0])
        await settle()
        engine.emit(.playingChanged(true))
    }

    /// Ticks for `seconds` of playing (or paused) time at the player's 0.5 s rhythm.
    func listen(seconds: TimeInterval, from start: TimeInterval = 0, playing: Bool = true) {
        engine.tick(start, playing: playing)
        var position = start
        for _ in 0..<Int(seconds / 0.5) {
            position += 0.5
            clock.advance(by: 0.5)
            engine.tick(position, playing: playing)
        }
    }

    func enterWindow(at position: TimeInterval = 186) async {
        engine.tick(position, playing: true)
        await service.prefetchTask?.value
        engine.tick(position + 0.5, playing: true)
    }
}

@MainActor
@Suite("MusicService listening")
struct MusicServiceListeningTests {
    @Test("nothing is noted while the first song is still playing")
    func nothingYet() async {
        let h = ListeningHarness()
        await h.startQueue(["a", "b"])
        h.listen(seconds: 40)
        #expect(h.log.notes.isEmpty)
    }

    @Test("a skip after 40 s notes the song once as a play")
    func skipAfterAPlay() async {
        let h = ListeningHarness()
        await h.startQueue(["a", "b"])
        h.listen(seconds: 40)
        h.service.next()
        await h.settle()
        #expect(h.log.notes == [.init(videoId: "a", seconds: 40, countsAsPlay: true)])
    }

    @Test("a skip after 10 s keeps the seconds and is no play")
    func earlySkip() async {
        let h = ListeningHarness()
        await h.startQueue(["a", "b"])
        h.listen(seconds: 10)
        h.service.next()
        await h.settle()
        #expect(h.log.notes == [.init(videoId: "a", seconds: 10, countsAsPlay: false)])
    }

    @Test("a skip inside the first second leaves a note the store ignores, never a play")
    func instantSkip() async {
        let h = ListeningHarness()
        await h.startQueue(["a", "b"])
        h.engine.tick(0, playing: true)
        h.service.next()
        await h.settle()
        #expect(h.log.notes.allSatisfy { !$0.countsAsPlay && $0.seconds < MusicListeningRules.minimumRecorded })
    }

    @Test("paused time and seek jumps are not heard: 20 s, a 30 s pause, a seek, 16 s more")
    func pauseAndSeek() async {
        let h = ListeningHarness()
        await h.startQueue(["a", "b"])
        h.listen(seconds: 20)
        h.listen(seconds: 30, from: 20, playing: false)
        h.service.seek(to: 100)
        h.listen(seconds: 16, from: 100)
        h.service.next()
        await h.settle()
        let note = h.log.notes.first
        #expect(h.log.notes.count == 1)
        #expect(note?.videoId == "a")
        #expect(note?.seconds == 36)
        #expect(note?.countsAsPlay == true)
    }

    @Test("a long wall-clock pause alone adds nothing")
    func pauseOnly() async {
        let h = ListeningHarness()
        await h.startQueue(["a", "b"])
        h.listen(seconds: 5)
        h.clock.advance(by: 3600)
        h.listen(seconds: 60, from: 5, playing: false)
        h.service.next()
        await h.settle()
        #expect(h.log.notes == [.init(videoId: "a", seconds: 5, countsAsPlay: false)])
    }

    @Test("the crossfade flip closes the outgoing song once and the incoming one counts on its own")
    func crossfadeFlip() async {
        let h = ListeningHarness()
        await h.startQueue(["a", "b", "c"])
        h.listen(seconds: 40)
        await h.enterWindow()
        h.engine.advance()
        await h.settle()
        #expect(h.log.notes == [.init(videoId: "a", seconds: 40, countsAsPlay: true)])

        // The flip made "b" the current song, and nothing more was noted for "a".
        #expect(h.engine.currentVideoId == "b")
        #expect(h.log.notes.count == 1)

        h.listen(seconds: 35, from: 0)
        h.service.next()
        await h.settle()
        #expect(h.log.notes == [
            .init(videoId: "a", seconds: 40, countsAsPlay: true),
            .init(videoId: "b", seconds: 35, countsAsPlay: true)
        ])
    }

    @Test("stopping for quit notes the playing song and flushes the store")
    func quit() async {
        let h = ListeningHarness()
        await h.startQueue(["a", "b"])
        h.listen(seconds: 31)
        h.service.stop()
        #expect(h.log.notes == [.init(videoId: "a", seconds: 31, countsAsPlay: true)])
        #expect(h.log.flushes == 1)
    }

    @Test("playing the same song again is a second session and a second play")
    func replay() async {
        let h = ListeningHarness()
        await h.startQueue(["a", "b"])
        h.listen(seconds: 32)
        h.service.play(MusicSamples.track("a", title: "Song a"))
        await h.settle()
        h.engine.emit(.playingChanged(true))
        h.listen(seconds: 33)
        h.service.stop()
        #expect(h.log.notes.map(\.videoId) == ["a", "a"])
        #expect(h.log.notes.filter(\.countsAsPlay).count == 2)
    }

    @Test("without a listening store nothing breaks")
    func noStore() async {
        let backend = FakeMusicBackend()
        let engine = FakePlaybackEngine()
        let service = MusicService(
            backend: backend, player: MusicPlayer(engine: engine), presentSignIn: { _ in }, presentChannelPicker: { _, _ in },
            closeSignInWindow: {}, raiseSignInWindow: {},
            nowPlaying: NowPlayingController(surface: FakeNowPlayingSurface(), fetchArtwork: { _ in nil }),
            queueRetryDelay: .seconds(60), refreshOnCreate: false
        )
        let tracks = ["a", "b"].map { MusicSamples.track($0, title: "Song \($0)") }
        await backend.setRadio(seed: "a", tracks: tracks, continuation: nil)
        service.play(tracks[0])
        await service.playTask?.value
        service.stop()
    }
}
