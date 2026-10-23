// DeciTests/Music/MusicPlayerObservedTimeTests.swift
// The Music popup stays mounted while it is hidden, and the player ticks every half second. A view that is not on screen
// reads the position without subscribing to it, so a closed popup is not redrawn twice a second for a time nobody sees,
// and it reads the live value again the moment the popup opens. Fake engine, no audio.

import Foundation
import Observation
import os
import Testing
@testable import Deci

/// Records that an observation fired, from the nonisolated closure `withObservationTracking` takes.
private nonisolated final class Fired: Sendable {
    private let flag = OSAllocatedUnfairLock(initialState: false)
    var value: Bool { flag.withLock { $0 } }
    func set() { flag.withLock { $0 = true } }
}

@MainActor
@Suite("Player position read for a view")
struct MusicPlayerObservedTimeTests {

    private func playing(duration: Double = 200) -> (player: MusicPlayer, engine: FakePlaybackEngine) {
        let engine = FakePlaybackEngine()
        let player = MusicPlayer(engine: engine)
        player.load(stream: MusicSamples.stream(duration: duration), track: MusicSamples.track())
        engine.emit(.ready(duration: duration))
        engine.emit(.playingChanged(true))
        return (player, engine)
    }

    /// Reads `read` once, and says whether `change` afterwards would redraw whoever read it.
    private func redraws(read: @MainActor () -> Void, after change: @MainActor () -> Void) -> Bool {
        let fired = Fired()
        withObservationTracking { read() } onChange: { fired.set() }
        change()
        return fired.value
    }

    // MARK: - What is read

    @Test("Both reads give the position of the last tick")
    func bothReadsAgree() {
        let (player, engine) = playing()
        engine.tick(12, playing: true)
        #expect(player.readCurrentTime(observed: true) == 12)
        #expect(player.readCurrentTime(observed: false) == 12)
        #expect(player.currentTime == 12)
    }

    @Test("A read that is not observed still follows every tick")
    func unobservedReadFollowsTheTicks() {
        let (player, engine) = playing()
        engine.tick(1, playing: true)
        engine.tick(1.5, playing: true)
        engine.tick(2, playing: true)
        #expect(player.readCurrentTime(observed: false) == 2)
    }

    @Test("A seek and an ended track show in both reads")
    func seekAndEnd() {
        let (player, engine) = playing(duration: 120)
        player.seek(to: 40)
        #expect(player.readCurrentTime(observed: false) == 40)
        #expect(player.readCurrentTime(observed: true) == 40)
        engine.emit(.ended)
        #expect(player.readCurrentTime(observed: false) == 120)
        #expect(player.readCurrentTime(observed: true) == 120)
    }

    // MARK: - Who is redrawn

    @Test("An observed read is redrawn by the next tick")
    func observedReadIsRedrawn() {
        let (player, engine) = playing()
        engine.tick(10, playing: true)
        let drawn = redraws(read: { _ = player.readCurrentTime(observed: true) }, after: { engine.tick(10.5, playing: true) })
        #expect(drawn)
    }

    @Test("A read that is not observed is not redrawn by a tick")
    func unobservedReadIsQuiet() {
        let (player, engine) = playing()
        engine.tick(10, playing: true)
        let drawn = redraws(read: { _ = player.readCurrentTime(observed: false) }, after: { engine.tick(10.5, playing: true) })
        #expect(!drawn)
    }

    @Test("Reading currentTime directly is observed, as before")
    func directReadIsObserved() {
        let (player, engine) = playing()
        engine.tick(10, playing: true)
        let drawn = redraws(read: { _ = player.currentTime }, after: { engine.tick(10.5, playing: true) })
        #expect(drawn)
    }

    @Test("A tick that carries the same position redraws nobody")
    func sameTickIsQuiet() {
        let (player, engine) = playing()
        engine.tick(10, playing: true)
        let drawn = redraws(read: { _ = player.readCurrentTime(observed: true) }, after: { engine.tick(10, playing: true) })
        #expect(!drawn)
    }

    @Test("A seek redraws an observed read, and not an unobserved one")
    func seekRedrawsOnlyTheObserved() {
        let (player, engine) = playing()
        engine.tick(10, playing: true)
        let seen = redraws(read: { _ = player.readCurrentTime(observed: true) }, after: { player.seek(to: 90) })
        #expect(seen)
        let hidden = redraws(read: { _ = player.readCurrentTime(observed: false) }, after: { player.seek(to: 30) })
        #expect(!hidden)
    }

    // MARK: - Opening the popup

    @Test("After ticks heard while hidden, the first observed read is the live position")
    func openingShowsTheLiveTime() {
        let (player, engine) = playing()
        engine.tick(10, playing: true)
        _ = player.readCurrentTime(observed: false)
        for second in stride(from: 10.5, through: 61, by: 0.5) { engine.tick(second, playing: true) }
        #expect(player.readCurrentTime(observed: true) == 61)
    }

    // MARK: - The spectrum's fill

    @Test("The spectrum's fill falls back to the player's position, and hidden it is not redrawn by ticks")
    func spectrumFillGate() {
        let (player, engine) = playing(duration: 100)
        engine.tick(25, playing: true)
        #expect(MusicSpectrumView.shownProgress(showsProgress: true, player: player, spectrumProgress: nil, observed: true) == 0.25)
        #expect(MusicSpectrumView.shownProgress(showsProgress: true, player: player, spectrumProgress: nil, observed: false) == 0.25)

        let seen = redraws(
            read: { _ = MusicSpectrumView.shownProgress(showsProgress: true, player: player, spectrumProgress: nil, observed: true) },
            after: { engine.tick(30, playing: true) }
        )
        #expect(seen)
        let hidden = redraws(
            read: { _ = MusicSpectrumView.shownProgress(showsProgress: true, player: player, spectrumProgress: nil, observed: false) },
            after: { engine.tick(35, playing: true) }
        )
        #expect(!hidden)
    }

    @Test("The spectrum's own poll wins over the player's position, and a track with no progress shows none")
    func spectrumPollAndNoProgress() {
        let (player, engine) = playing(duration: 100)
        engine.tick(25, playing: true)
        #expect(MusicSpectrumView.shownProgress(showsProgress: true, player: player, spectrumProgress: 0.6, observed: true) == 0.6)
        #expect(MusicSpectrumView.shownProgress(showsProgress: false, player: player, spectrumProgress: 0.6, observed: true) == 0)
        #expect(MusicSpectrumView.shownProgress(showsProgress: true, player: nil, spectrumProgress: 0.6, observed: true) == 0)
    }
}
