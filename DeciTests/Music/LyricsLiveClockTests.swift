// DeciTests/Music/LyricsLiveClockTests.swift
// The clock the lyrics follow. The player's own ticks come every half second, so the lyrics read the engine's clock
// directly, and fall back to the last tick carried forward when there is no such clock. Fake engine, no audio.

import Foundation
import Observation
import os
import Testing
@testable import Deci

@MainActor
@Suite("Player live position")
struct MusicPlayerLivePositionTests {

    private func playing(duration: Double = 200) -> (player: MusicPlayer, engine: FakePlaybackEngine) {
        let engine = FakePlaybackEngine()
        let player = MusicPlayer(engine: engine)
        player.load(stream: MusicSamples.stream(duration: duration), track: MusicSamples.track())
        engine.emit(.ready(duration: duration))
        engine.emit(.playingChanged(true))
        return (player, engine)
    }

    @Test("Between ticks the live position is the engine's own clock, not the last tick")
    func readsTheEngineClock() {
        let (player, engine) = playing()
        engine.tick(10, playing: true)
        engine.position = 10.37
        #expect(player.currentTime == 10)
        #expect(player.livePosition() == 10.37)
    }

    @Test("The live read does not change what the player publishes")
    func readIsSideEffectFree() {
        let (player, engine) = playing()
        engine.tick(10, playing: true)
        engine.position = 10.37
        _ = player.livePosition()
        #expect(player.currentTime == 10)
        #expect(player.isPlaying)
    }

    @Test("With nothing loaded there is no clock to read: zero")
    func nothingLoaded() {
        let engine = FakePlaybackEngine()
        engine.position = 77
        let player = MusicPlayer(engine: engine)
        #expect(player.livePosition() == 0)
    }

    @Test("While a track loads the engine may still hold the last track's clock: the player's own time is used")
    func loadingIgnoresTheEngine() {
        let engine = FakePlaybackEngine()
        let player = MusicPlayer(engine: engine)
        player.load(stream: MusicSamples.stream(duration: 200), track: MusicSamples.track())
        engine.position = 55
        #expect(player.isLoading)
        #expect(player.livePosition() == player.currentTime)
        #expect(player.livePosition() == 0)
    }

    @Test("After the track has ended the position stays at the end")
    func endedStaysAtTheEnd() {
        let (player, engine) = playing(duration: 120)
        engine.position = 118.9
        engine.emit(.ended)
        engine.position = 0
        #expect(player.hasEnded)
        #expect(player.livePosition() == 120)
    }

    @Test("A reading that is not a number, or is below zero, falls back to the player's time")
    func badReadings() {
        let (player, engine) = playing()
        engine.tick(30, playing: true)
        engine.position = .nan
        #expect(player.livePosition() == 30)
        engine.position = -4
        #expect(player.livePosition() == 30)
        engine.position = .infinity
        #expect(player.livePosition() == 30)
    }

    @Test("Paused, the live position is where the engine stopped")
    func paused() {
        let (player, engine) = playing()
        engine.tick(42, playing: true)
        engine.emit(.playingChanged(false))
        engine.position = 42.5
        #expect(player.livePosition() == 42.5)
    }
}

@MainActor
@Suite("Lyrics store position")
struct MusicLyricsStorePositionTests {

    private func store() -> MusicLyricsStore {
        MusicLyricsStore(provider: FakeLyricsProvider(), now: { MusicTestJar.now }, sleep: { _ in })
    }

    @Test("With a live clock the position is its reading, whatever the date")
    func liveClockWins() {
        let store = store()
        store.setPanelOpen(true)
        store.observePlayback(position: 10, isPlaying: true)
        store.livePosition = { 12.34 }
        #expect(store.position(at: MusicTestJar.now) == 12.34)
        #expect(store.position(at: MusicTestJar.now.addingTimeInterval(5)) == 12.34)
    }

    @Test("Without a live clock it is the last tick carried forward, as before")
    func fallsBackToThePlayhead() {
        let store = store()
        store.setPanelOpen(true)
        store.observePlayback(position: 10, isPlaying: true)
        #expect(store.livePosition == nil)
        #expect(abs(store.position(at: MusicTestJar.now.addingTimeInterval(0.4)) - 10.4) < 0.001)
    }

    @Test("A live reading that is not a number falls back to the playhead")
    func badLiveReading() {
        let store = store()
        store.setPanelOpen(true)
        store.observePlayback(position: 10, isPlaying: false)
        store.livePosition = { .nan }
        #expect(store.position(at: MusicTestJar.now) == 10)
        store.livePosition = { .infinity }
        #expect(store.position(at: MusicTestJar.now) == 10)
    }

    @Test("A negative live reading is the start of the song")
    func negativeReading() {
        let store = store()
        store.livePosition = { -3 }
        #expect(store.position(at: MusicTestJar.now) == 0)
    }

    @Test("Reading the position does not change what the store publishes")
    func readIsSideEffectFree() {
        let store = store()
        store.setPanelOpen(true)
        store.observePlayback(position: 10, isPlaying: true)
        let before = store.playhead
        store.livePosition = { 99 }
        _ = store.position(at: MusicTestJar.now)
        #expect(store.playhead == before)
    }
}

/// Records that an observation fired, from the nonisolated closure `withObservationTracking` takes.
private nonisolated final class Fired: Sendable {
    private let flag = OSAllocatedUnfairLock(initialState: false)
    var value: Bool { flag.withLock { $0 } }
    func set() { flag.withLock { $0 = true } }
}

@MainActor
@Suite("Lyrics store: playing and animating")
struct MusicLyricsStoreAnimatesTests {

    private func store(watching: Bool = true) -> MusicLyricsStore {
        let store = MusicLyricsStore(provider: FakeLyricsProvider(), now: { MusicTestJar.now }, sleep: { _ in })
        store.setPanelOpen(watching)
        return store
    }

    /// Runs `read` once, and says whether changing the store with `change` afterwards would redraw whoever read it.
    private func redraws(_ store: MusicLyricsStore, read: @MainActor () -> Void, after change: @MainActor () -> Void) -> Bool {
        let fired = Fired()
        withObservationTracking { read() } onChange: { fired.set() }
        change()
        return fired.value
    }

    // MARK: - isPlaying

    @Test("isPlaying follows what the player reported, and is off to begin with")
    func isPlayingFollowsTheReports() {
        let store = store()
        #expect(!store.isPlaying)
        store.observePlayback(position: 3, isPlaying: true)
        #expect(store.isPlaying)
        store.observePlayback(position: 4, isPlaying: false)
        #expect(!store.isPlaying)
    }

    @Test("Opening the panel reads whether the player is playing")
    func isPlayingFromTheSample() {
        let store = store(watching: false)
        store.playbackSampler = { (position: 7, isPlaying: true) }
        store.setPanelOpen(true)
        #expect(store.isPlaying)
    }

    @Test("A hidden panel ignores the player, and a reset stops it")
    func isPlayingWhenHiddenOrReset() {
        let store = store(watching: false)
        store.observePlayback(position: 3, isPlaying: true)
        #expect(!store.isPlaying)
        store.setPanelOpen(true)
        store.observePlayback(position: 3, isPlaying: true)
        store.reset()
        #expect(!store.isPlaying)
    }

    // MARK: - animates

    @Test("The store animates only while the panel is watching and the song plays")
    func animatesOnlyWhenWatchingAndPlaying() {
        let store = store()
        #expect(!store.animates)
        store.observePlayback(position: 3, isPlaying: true)
        #expect(store.animates)
        store.setPopupVisible(false)
        #expect(!store.animates)
        store.setPopupVisible(true)
        store.observePlayback(position: 4, isPlaying: false)
        #expect(!store.animates)
    }

    @Test("While playing, a player tick that changes only the time redraws nobody")
    func tickWhilePlayingIsQuiet() {
        let store = store()
        store.observePlayback(position: 3, isPlaying: true)
        let fired = redraws(store, read: { _ = store.animates }, after: { store.observePlayback(position: 3.5, isPlaying: true) })
        #expect(!fired)
    }

    @Test("Starting or stopping the song redraws whoever reads it")
    func startAndStopRedraw() {
        let paused = store()
        paused.observePlayback(position: 3, isPlaying: false)
        let started = redraws(paused, read: { _ = paused.animates }, after: { paused.observePlayback(position: 3, isPlaying: true) })
        #expect(started)

        let playing = store()
        playing.observePlayback(position: 3, isPlaying: true)
        let stopped = redraws(playing, read: { _ = playing.animates }, after: { playing.observePlayback(position: 3, isPlaying: false) })
        #expect(stopped)
    }

    @Test("While paused, a seek redraws whoever reads it, so the held frame moves")
    func seekWhilePausedRedraws() {
        let store = store()
        store.observePlayback(position: 3, isPlaying: false)
        let moved = redraws(store, read: { _ = store.animates }, after: { store.observePlayback(position: 90, isPlaying: false) })
        #expect(moved)
    }

    @Test("The panel hiding redraws whoever reads it")
    func hidingRedraws() {
        let store = store()
        store.observePlayback(position: 3, isPlaying: true)
        let hidden = redraws(store, read: { _ = store.animates }, after: { store.setPopupVisible(false) })
        #expect(hidden)
    }

    @Test("Writing the same playing state again does not publish it")
    func isPlayingIsWrittenOnlyOnChange() {
        let store = store()
        store.observePlayback(position: 3, isPlaying: true)
        let fired = redraws(store, read: { _ = store.isPlaying }, after: { store.observePlayback(position: 4, isPlaying: true) })
        #expect(!fired)
    }
}
