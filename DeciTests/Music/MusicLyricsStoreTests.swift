// DeciTests/Music/MusicLyricsStoreTests.swift
// The lyrics store: it fetches only while the panel is open and the popup is showing, only for the
// current track, drops late answers, honours the busy window and asks again when it ends, waits out a quick skip and
// resets on sign-out.

import Foundation
import Testing
@testable import Deci

@MainActor
private struct Rig {
    let provider = FakeLyricsProvider()
    let clock = MutableClock()
    let store: MusicLyricsStore

    /// `sleeper` stands in for the debounce timer; without one the wait is skipped, so a test sees the fetch at once.
    init(sleeper: FakeSleeper? = nil) {
        let provider = self.provider
        let clock = self.clock
        let sleep: @Sendable (Duration) async throws -> Void
        if let sleeper {
            sleep = { try await sleeper.sleep($0) }
        } else {
            sleep = { _ in }
        }
        store = MusicLyricsStore(provider: provider, now: { clock.now }, sleep: sleep)
    }

    static func track(_ id: String = "a", album: String? = "Test Album", seconds: Int? = 200) -> MusicTrack {
        MusicTrack(videoId: id, title: "Song \(id)", artist: "Artist \(id)", album: album, durationSeconds: seconds, thumbnailURL: nil)
    }

    /// Waits for the load in flight, and any it starts.
    func settle() async {
        while let task = store.loadTask {
            await task.value
            if store.loadTask == task { break }
        }
    }

    /// Lets queued work run so a "nothing happened" check means something.
    func idle() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(20))
    }

    static let lines = [LyricLine(time: 1, text: "First test line"), LyricLine(time: 4, text: "Second test line")]
}

@MainActor
@Suite("Music lyrics store")
struct MusicLyricsStoreTests {

    // MARK: - Gating

    @Test("Nothing is fetched while the panel is closed")
    func closedPanelNeverFetches() async {
        let rig = Rig()
        rig.store.trackChanged(Rig.track("a"), duration: 200)
        rig.store.trackChanged(Rig.track("b"), duration: 200)
        await rig.idle()
        #expect(rig.provider.queries.isEmpty)
        #expect(rig.store.state == .idle)
        #expect(!rig.store.isWatching)
    }

    @Test("Opening the panel fetches for the current track with what the player knows")
    func openingFetches() async {
        let rig = Rig()
        rig.provider.setResult(.synced(Rig.lines), for: "a")
        rig.store.trackChanged(Rig.track("a", album: "Some Album"), duration: 213.4)
        rig.store.setPanelOpen(true)
        #expect(rig.store.state == .loading)
        await rig.settle()
        #expect(rig.store.state == .loaded(.synced(Rig.lines)))
        let query = rig.provider.queries.first
        #expect(rig.provider.queries.count == 1)
        #expect(query?.videoId == "a")
        #expect(query?.title == "Song a")
        #expect(query?.artist == "Artist a")
        #expect(query?.album == "Some Album")
        #expect(query?.duration == 213.4)
    }

    @Test("A track that arrives after the panel opened is fetched")
    func trackAfterOpen() async {
        let rig = Rig()
        rig.provider.setResult(.plain("First test line"), for: "a")
        rig.store.setPanelOpen(true)
        #expect(rig.store.state == .idle)
        rig.store.trackChanged(Rig.track("a"), duration: 200)
        await rig.settle()
        #expect(rig.store.state == .loaded(.plain("First test line")))
    }

    @Test("An unknown duration is passed on as unknown")
    func zeroDurationIsUnknown() async {
        let rig = Rig()
        rig.store.setPanelOpen(true)
        rig.store.trackChanged(Rig.track("a", album: nil, seconds: nil), duration: 0)
        await rig.settle()
        #expect(rig.provider.queries.first?.duration == nil)
        #expect(rig.provider.queries.first?.album == nil)
    }

    @Test("A track change while open fetches the new track")
    func trackChangeWhileOpen() async {
        let rig = Rig()
        rig.provider.setResult(.plain("From a"), for: "a")
        rig.provider.setResult(.plain("From b"), for: "b")
        rig.store.setPanelOpen(true)
        rig.store.trackChanged(Rig.track("a"), duration: 200)
        await rig.settle()
        rig.store.trackChanged(Rig.track("b"), duration: 200)
        #expect(rig.store.state == .loading)
        await rig.settle()
        #expect(rig.store.state == .loaded(.plain("From b")))
        #expect(rig.provider.videoIds == ["a", "b"])
    }

    @Test("The same track reported again does not fetch again")
    func sameTrackNoRefetch() async {
        let rig = Rig()
        rig.provider.setResult(.instrumental, for: "a")
        rig.store.setPanelOpen(true)
        rig.store.trackChanged(Rig.track("a"), duration: 199)
        await rig.settle()
        rig.store.trackChanged(Rig.track("a"), duration: 200.4)
        await rig.idle()
        #expect(rig.provider.queries.count == 1)
        #expect(rig.store.state == .loaded(.instrumental))
    }

    @Test("A late answer for the previous track is dropped")
    func staleAnswerDropped() async {
        let rig = Rig()
        let gate = MusicTestGate()
        rig.provider.setGate(gate, for: "a")
        rig.provider.setResult(.plain("From a"), for: "a")
        rig.provider.setResult(.plain("From b"), for: "b")
        rig.store.setPanelOpen(true)
        rig.store.trackChanged(Rig.track("a"), duration: 200)
        #expect(await eventually { rig.provider.videoIds == ["a"] })
        rig.store.trackChanged(Rig.track("b"), duration: 200)
        await rig.settle()
        #expect(rig.store.state == .loaded(.plain("From b")))
        await gate.open()
        await rig.idle()
        #expect(rig.store.state == .loaded(.plain("From b")))
    }

    @Test("A late failure for the previous track is dropped too")
    func staleFailureDropped() async {
        let rig = Rig()
        let gate = MusicTestGate()
        rig.provider.setGate(gate, for: "a")
        rig.provider.setError(URLError(.timedOut), for: "a")
        rig.provider.setResult(.plain("From b"), for: "b")
        rig.store.setPanelOpen(true)
        rig.store.trackChanged(Rig.track("a"), duration: 200)
        #expect(await eventually { rig.provider.videoIds == ["a"] })
        rig.store.trackChanged(Rig.track("b"), duration: 200)
        await rig.settle()
        await gate.open()
        await rig.idle()
        #expect(rig.store.state == .loaded(.plain("From b")))
    }

    @Test("Closing the panel cancels the fetch and later answers are ignored")
    func closingCancels() async {
        let rig = Rig()
        let gate = MusicTestGate()
        rig.provider.setGate(gate, for: "a")
        rig.provider.setResult(.plain("From a"), for: "a")
        rig.store.trackChanged(Rig.track("a"), duration: 200)
        rig.store.setPanelOpen(true)
        #expect(await eventually { rig.provider.videoIds == ["a"] })
        rig.store.setPanelOpen(false)
        #expect(rig.store.state == .idle)
        await gate.open()
        await rig.idle()
        #expect(rig.store.state == .idle)
        #expect(rig.provider.queries.count == 1)
    }

    @Test("Reopening after a cancelled fetch asks again; after a loaded one it does not")
    func reopening() async {
        let rig = Rig()
        let gate = MusicTestGate()
        rig.provider.setGate(gate, for: "a")
        rig.provider.setResult(.plain("From a"), for: "a")
        rig.store.trackChanged(Rig.track("a"), duration: 200)
        rig.store.setPanelOpen(true)
        #expect(await eventually { rig.provider.videoIds == ["a"] })
        rig.store.setPanelOpen(false)
        await gate.open()
        rig.store.setPanelOpen(true)
        await rig.settle()
        #expect(rig.store.state == .loaded(.plain("From a")))
        #expect(rig.provider.queries.count == 2)

        rig.store.setPanelOpen(false)
        rig.store.setPanelOpen(true)
        await rig.idle()
        #expect(rig.provider.queries.count == 2)
        #expect(rig.store.state == .loaded(.plain("From a")))
    }

    @Test("A loaded result stays while the panel is closed, and a new track clears it")
    func loadedStaysUntilTrackChanges() async {
        let rig = Rig()
        rig.provider.setResult(.plain("From a"), for: "a")
        rig.store.trackChanged(Rig.track("a"), duration: 200)
        rig.store.setPanelOpen(true)
        await rig.settle()
        rig.store.setPanelOpen(false)
        #expect(rig.store.state == .loaded(.plain("From a")))
        rig.store.trackChanged(Rig.track("b"), duration: 200)
        #expect(rig.store.state == .idle)
        await rig.idle()
        #expect(rig.provider.videoIds == ["a"])
    }

    @Test("A hidden popup fetches nothing, and showing it again does")
    func hiddenPopup() async {
        let rig = Rig()
        rig.provider.setResult(.plain("From a"), for: "a")
        rig.store.setPopupVisible(false)
        rig.store.setPanelOpen(true)
        rig.store.trackChanged(Rig.track("a"), duration: 200)
        await rig.idle()
        #expect(rig.provider.queries.isEmpty)
        #expect(!rig.store.isWatching)
        rig.store.setPopupVisible(true)
        #expect(rig.store.isWatching)
        await rig.settle()
        #expect(rig.store.state == .loaded(.plain("From a")))
    }

    @Test("Hiding the popup mid-fetch cancels it")
    func hidingMidFetch() async {
        let rig = Rig()
        let gate = MusicTestGate()
        rig.provider.setGate(gate, for: "a")
        rig.provider.setResult(.plain("From a"), for: "a")
        rig.store.setPanelOpen(true)
        rig.store.trackChanged(Rig.track("a"), duration: 200)
        #expect(await eventually { rig.provider.videoIds == ["a"] })
        rig.store.setPopupVisible(false)
        #expect(rig.store.state == .idle)
        await gate.open()
        await rig.idle()
        #expect(rig.store.state == .idle)
        #expect(rig.store.isPanelOpen)
    }

    @Test("Rapid open, close, open ends with one answer for the track")
    func rapidToggling() async {
        let rig = Rig()
        rig.provider.setResult(.plain("From a"), for: "a")
        rig.store.trackChanged(Rig.track("a"), duration: 200)
        for _ in 0..<5 {
            rig.store.setPanelOpen(true)
            rig.store.setPanelOpen(false)
        }
        rig.store.setPanelOpen(true)
        await rig.settle()
        #expect(rig.store.state == .loaded(.plain("From a")))
    }

    @Test("No track means nothing to show, and ends a fetch in flight")
    func noTrack() async {
        let rig = Rig()
        let gate = MusicTestGate()
        rig.provider.setGate(gate, for: "a")
        rig.store.setPanelOpen(true)
        rig.store.trackChanged(Rig.track("a"), duration: 200)
        #expect(await eventually { rig.provider.videoIds == ["a"] })
        rig.store.trackChanged(nil, duration: 0)
        #expect(rig.store.state == .idle)
        #expect(rig.store.track == nil)
        await gate.open()
        await rig.idle()
        #expect(rig.store.state == .idle)
    }

    // MARK: - Failures

    @Test("A failed fetch shows a short message, and Retry asks again")
    func failureAndRetry() async {
        let rig = Rig()
        rig.provider.setError(URLError(.notConnectedToInternet), for: "a")
        rig.store.setPanelOpen(true)
        rig.store.trackChanged(Rig.track("a"), duration: 200)
        await rig.settle()
        #expect(rig.store.state == .failed("Network problem. Check your connection."))

        rig.provider.setError(nil, for: "a")
        rig.provider.setResult(.plain("From a"), for: "a")
        rig.store.retry()
        #expect(rig.store.state == .loading)
        await rig.settle()
        #expect(rig.store.state == .loaded(.plain("From a")))
        #expect(rig.provider.queries.count == 2)
    }

    @Test("Messages never carry URLs or response text")
    func messages() {
        #expect(MusicLyricsStore.message(for: LyricsError.http(500)) == "The lyrics service returned an error (500).")
        #expect(MusicLyricsStore.message(for: LyricsError.parse) == "Couldn't read the lyrics response.")
        #expect(MusicLyricsStore.message(for: URLError(.timedOut)) == "Network problem. Check your connection.")
        #expect(MusicLyricsStore.message(for: CocoaError(.fileReadUnknown)) == "Something went wrong. Try again.")
    }

    @Test("A failed fetch is tried again when the panel is reopened")
    func failedRetriesOnReopen() async {
        let rig = Rig()
        rig.provider.setError(LyricsError.http(500), for: "a")
        rig.store.trackChanged(Rig.track("a"), duration: 200)
        rig.store.setPanelOpen(true)
        await rig.settle()
        rig.provider.setError(nil, for: "a")
        rig.provider.setResult(.instrumental, for: "a")
        rig.store.setPanelOpen(false)
        rig.store.setPanelOpen(true)
        await rig.settle()
        #expect(rig.store.state == .loaded(.instrumental))
    }

    @Test("A failure does not fetch again by itself")
    func noLoopOnFailure() async {
        let rig = Rig()
        rig.provider.setError(LyricsError.http(500), for: "a")
        rig.store.setPanelOpen(true)
        rig.store.trackChanged(Rig.track("a"), duration: 200)
        await rig.settle()
        rig.store.trackChanged(Rig.track("a"), duration: 201)
        await rig.idle()
        #expect(rig.provider.queries.count == 1)
    }

    @Test("Retry does nothing when there is nothing failed to retry")
    func retryOnlyAfterFailure() async {
        let rig = Rig()
        rig.provider.setResult(.plain("From a"), for: "a")
        rig.store.retry()
        rig.store.trackChanged(Rig.track("a"), duration: 200)
        rig.store.retry()
        await rig.idle()
        #expect(rig.provider.queries.isEmpty)
        rig.store.setPanelOpen(true)
        rig.store.retry()
        await rig.settle()
        rig.store.retry()
        await rig.idle()
        #expect(rig.provider.queries.count == 1)
    }

    // MARK: - Busy

    @Test("429 shows the busy state and Retry waits for the window")
    func busyWindow() async {
        let rig = Rig()
        let until = rig.clock.now.addingTimeInterval(60)
        rig.provider.setError(LyricsError.busy(until: until), for: "a")
        rig.store.setPanelOpen(true)
        rig.store.trackChanged(Rig.track("a"), duration: 200)
        await rig.settle()
        #expect(rig.store.state == .busy(until: until))

        // Too early: no request, the state stays.
        rig.clock.advance(by: 30)
        rig.store.retry()
        await rig.idle()
        #expect(rig.provider.queries.count == 1)
        #expect(rig.store.state == .busy(until: until))
        #expect(!rig.store.canRetry)

        // Past the window: the request goes out.
        rig.clock.advance(by: 31)
        #expect(rig.store.canRetry)
        rig.provider.setError(nil, for: "a")
        rig.provider.setResult(.plain("From a"), for: "a")
        rig.store.retry()
        await rig.settle()
        #expect(rig.store.state == .loaded(.plain("From a")))
        #expect(rig.provider.queries.count == 2)
    }

    @Test("Reopening the panel inside the busy window sends nothing")
    func reopenInsideBusyWindow() async {
        let rig = Rig()
        let until = rig.clock.now.addingTimeInterval(60)
        rig.provider.setError(LyricsError.busy(until: until), for: "a")
        rig.store.trackChanged(Rig.track("a"), duration: 200)
        rig.store.setPanelOpen(true)
        await rig.settle()
        rig.store.setPanelOpen(false)
        rig.store.setPanelOpen(true)
        await rig.idle()
        #expect(rig.provider.queries.count == 1)
        #expect(rig.store.state == .busy(until: until))
    }

    @Test("A new track inside the busy window is still sent to the client, which holds the line")
    func newTrackInsideBusyWindow() async {
        let rig = Rig()
        let until = rig.clock.now.addingTimeInterval(60)
        rig.provider.setError(LyricsError.busy(until: until), for: "a")
        rig.provider.setError(LyricsError.busy(until: until), for: "b")
        rig.store.trackChanged(Rig.track("a"), duration: 200)
        rig.store.setPanelOpen(true)
        await rig.settle()
        rig.store.trackChanged(Rig.track("b"), duration: 200)
        await rig.settle()
        #expect(rig.store.state == .busy(until: until))
        #expect(rig.provider.videoIds == ["a", "b"])
    }

    // MARK: - Reset

    @Test("Reset clears the state, the track and the panel, and drops a fetch in flight")
    func resetClearsEverything() async {
        let rig = Rig()
        let gate = MusicTestGate()
        rig.provider.setGate(gate, for: "a")
        rig.provider.setResult(.plain("From a"), for: "a")
        rig.store.setPanelOpen(true)
        rig.store.trackChanged(Rig.track("a"), duration: 200)
        rig.store.observePlayback(position: 33, isPlaying: true)
        #expect(await eventually { rig.provider.videoIds == ["a"] })
        rig.store.reset()
        #expect(rig.store.state == .idle)
        #expect(rig.store.track == nil)
        #expect(!rig.store.isPanelOpen)
        #expect(rig.store.playhead == .zero)
        await gate.open()
        await rig.idle()
        #expect(rig.store.state == .idle)
        #expect(rig.provider.queries.count == 1)
    }

    @Test("After a reset a new track and a reopened panel work as new")
    func resetThenUse() async {
        let rig = Rig()
        rig.provider.setResult(.plain("From a"), for: "a")
        rig.provider.setResult(.plain("From b"), for: "b")
        rig.store.setPanelOpen(true)
        rig.store.trackChanged(Rig.track("a"), duration: 200)
        await rig.settle()
        rig.store.reset()
        rig.store.trackChanged(Rig.track("b"), duration: 200)
        await rig.idle()
        #expect(rig.provider.videoIds == ["a"])
        rig.store.setPanelOpen(true)
        await rig.settle()
        #expect(rig.store.state == .loaded(.plain("From b")))
    }

    // MARK: - Playhead

    @Test("Playback observations are stamped with the clock")
    func playheadIsStamped() {
        let rig = Rig()
        rig.store.setPanelOpen(true)
        #expect(rig.store.playhead == .zero)
        rig.store.observePlayback(position: 12.5, isPlaying: true)
        #expect(rig.store.playhead == LyricsPlayhead(time: 12.5, isPlaying: true, observedAt: rig.clock.now))
        rig.clock.advance(by: 0.5)
        #expect(abs(rig.store.playhead.position(at: rig.clock.now) - 13) < 0.0001)
        rig.store.observePlayback(position: 13, isPlaying: false)
        #expect(!rig.store.playhead.isPlaying)
    }
}

// MARK: - Duration that arrives late

/// The player's exact length often arrives after the track does. A lookup that ran without it is redone once
/// when it shows up, because the client does not cache an answer found without a length.
@MainActor
@Suite("Music lyrics store: late duration")
struct MusicLyricsStoreLateDurationTests {

    @Test("A known duration after a lookup without one refetches once")
    func refetchesOnce() async {
        let rig = Rig()
        rig.provider.setResult(.plain("From a"), for: "a")
        rig.store.setPanelOpen(true)
        rig.store.trackChanged(Rig.track("a", seconds: nil), duration: 0)
        await rig.settle()
        #expect(rig.provider.queries.map(\.duration) == [nil])

        rig.store.trackChanged(Rig.track("a", seconds: nil), duration: 213.4)
        #expect(rig.store.state == .loading)
        await rig.settle()
        #expect(rig.provider.queries.map(\.duration) == [nil, 213.4])
        #expect(rig.store.state == .loaded(.plain("From a")))

        // The length is known now: nothing more to ask.
        rig.store.trackChanged(Rig.track("a"), duration: 214)
        rig.store.trackChanged(Rig.track("a"), duration: 213.4)
        await rig.idle()
        #expect(rig.provider.queries.count == 2)
    }

    @Test("A lookup that already had a duration is never redone for a new one")
    func knownDurationNeverRefetches() async {
        let rig = Rig()
        rig.store.setPanelOpen(true)
        rig.store.trackChanged(Rig.track("a"), duration: 200)
        await rig.settle()
        rig.store.trackChanged(Rig.track("a"), duration: 205)
        await rig.idle()
        #expect(rig.provider.queries.count == 1)
    }

    @Test("A zero or negative duration is not a known one")
    func zeroIsNotKnown() async {
        let rig = Rig()
        rig.store.setPanelOpen(true)
        rig.store.trackChanged(Rig.track("a", seconds: nil), duration: 0)
        await rig.settle()
        rig.store.trackChanged(Rig.track("a", seconds: nil), duration: -1)
        rig.store.trackChanged(Rig.track("a", seconds: nil), duration: .nan)
        await rig.idle()
        #expect(rig.provider.queries.count == 1)
    }

    @Test("In flight: the fetch is cancelled, redone with the length, and the stale answer is dropped")
    func refetchInFlight() async {
        let rig = Rig()
        let gate = MusicTestGate()
        rig.provider.setGate(gate, for: "a")
        rig.provider.setResult(.plain("Stale"), for: "a")
        rig.store.setPanelOpen(true)
        rig.store.trackChanged(Rig.track("a", seconds: nil), duration: 0)
        #expect(await eventually { rig.provider.queries.count == 1 })

        rig.provider.setResult(.plain("Fresh"), for: "a")
        rig.store.trackChanged(Rig.track("a", seconds: nil), duration: 180)
        #expect(await eventually { rig.provider.queries.count == 2 })
        await gate.open()
        await rig.settle()
        await rig.idle()
        #expect(rig.provider.queries.map(\.duration) == [nil, 180])
        #expect(rig.store.state == .loaded(.plain("Fresh")))
    }

    @Test("While the panel is closed the old answer is dropped, and the next open asks again")
    func arrivesWhileClosed() async {
        let rig = Rig()
        rig.provider.setResult(.notFound, for: "a")
        rig.store.setPanelOpen(true)
        rig.store.trackChanged(Rig.track("a", seconds: nil), duration: 0)
        await rig.settle()
        #expect(rig.store.state == .loaded(.notFound))
        rig.store.setPanelOpen(false)

        rig.store.trackChanged(Rig.track("a", seconds: nil), duration: 200)
        #expect(rig.store.state == .idle)
        await rig.idle()
        #expect(rig.provider.queries.count == 1)

        rig.provider.setResult(.plain("From a"), for: "a")
        rig.store.setPanelOpen(true)
        await rig.settle()
        #expect(rig.provider.queries.map(\.duration) == [nil, 200])
        #expect(rig.store.state == .loaded(.plain("From a")))
    }

    @Test("While the popup is hidden it waits for the popup too")
    func arrivesWhileHidden() async {
        let rig = Rig()
        rig.store.setPanelOpen(true)
        rig.store.trackChanged(Rig.track("a", seconds: nil), duration: 0)
        await rig.settle()
        rig.store.setPopupVisible(false)
        rig.store.trackChanged(Rig.track("a", seconds: nil), duration: 200)
        await rig.idle()
        #expect(rig.provider.queries.count == 1)
        rig.store.setPopupVisible(true)
        await rig.settle()
        #expect(rig.provider.queries.map(\.duration) == [nil, 200])
    }

    @Test("A failed lookup is not redone by itself, but Retry uses the new length")
    func failedStaysFailed() async {
        let rig = Rig()
        rig.provider.setError(URLError(.timedOut), for: "a")
        rig.store.setPanelOpen(true)
        rig.store.trackChanged(Rig.track("a", seconds: nil), duration: 0)
        await rig.settle()
        let failed = rig.store.state

        rig.store.trackChanged(Rig.track("a", seconds: nil), duration: 200)
        await rig.idle()
        #expect(rig.provider.queries.count == 1)
        #expect(rig.store.state == failed)

        rig.provider.setError(nil, for: "a")
        rig.provider.setResult(.plain("From a"), for: "a")
        rig.store.retry()
        await rig.settle()
        #expect(rig.provider.queries.map(\.duration) == [nil, 200])
        #expect(rig.store.state == .loaded(.plain("From a")))
    }

    @Test("A different track is a new lookup, not a late duration")
    func differentTrackIsNotARefetch() async {
        let rig = Rig()
        rig.store.setPanelOpen(true)
        rig.store.trackChanged(Rig.track("a", seconds: nil), duration: 0)
        await rig.settle()
        rig.store.trackChanged(Rig.track("b"), duration: 200)
        await rig.settle()
        #expect(rig.provider.videoIds == ["a", "b"])
        // And b, which had its length from the start, is not redone when the length is repeated.
        rig.store.trackChanged(Rig.track("b"), duration: 201)
        await rig.idle()
        #expect(rig.provider.queries.count == 2)
    }
}

// MARK: - Playhead while hidden

/// A stand-in for the player the store samples when the panel comes into view.
@MainActor
private final class FakePlayerPosition {
    var position: TimeInterval
    var isPlaying: Bool
    private(set) var samples = 0

    init(position: TimeInterval = 0, isPlaying: Bool = false) {
        self.position = position
        self.isPlaying = isPlaying
    }

    func sample() -> (position: TimeInterval, isPlaying: Bool) {
        samples += 1
        return (position, isPlaying)
    }
}

@MainActor
@Suite("Music lyrics store: playhead gating")
struct MusicLyricsStorePlayheadTests {

    @Test("A closed panel ignores the player's ticks")
    func closedPanelIgnoresTicks() {
        let rig = Rig()
        rig.store.observePlayback(position: 10, isPlaying: true)
        #expect(rig.store.playhead == .zero)
    }

    @Test("A hidden popup ignores the player's ticks")
    func hiddenPopupIgnoresTicks() {
        let rig = Rig()
        rig.store.setPanelOpen(true)
        rig.store.observePlayback(position: 10, isPlaying: true)
        #expect(rig.store.playhead.time == 10)

        rig.store.setPopupVisible(false)
        rig.clock.advance(by: 1)
        rig.store.observePlayback(position: 11, isPlaying: true)
        #expect(rig.store.playhead.time == 10)
    }

    @Test("Ticks count again once the panel is open and the popup is showing")
    func watchingAcceptsTicks() {
        let rig = Rig()
        rig.store.setPopupVisible(false)
        rig.store.setPanelOpen(true)
        rig.store.observePlayback(position: 5, isPlaying: true)
        #expect(rig.store.playhead == .zero)
        rig.store.setPopupVisible(true)
        rig.store.observePlayback(position: 6, isPlaying: true)
        #expect(rig.store.playhead == LyricsPlayhead(time: 6, isPlaying: true, observedAt: rig.clock.now))
    }

    @Test("Opening the panel takes one fresh sample from the player")
    func openingSamples() {
        let rig = Rig()
        let player = FakePlayerPosition(position: 42.5, isPlaying: true)
        rig.store.playbackSampler = { player.sample() }
        #expect(player.samples == 0)
        rig.store.setPanelOpen(true)
        #expect(player.samples == 1)
        #expect(rig.store.playhead == LyricsPlayhead(time: 42.5, isPlaying: true, observedAt: rig.clock.now))
    }

    @Test("Showing the popup again takes a fresh sample, so the highlight is right on re-show")
    func showingSamples() {
        let rig = Rig()
        let player = FakePlayerPosition(position: 10, isPlaying: true)
        rig.store.playbackSampler = { player.sample() }
        rig.store.setPanelOpen(true)
        rig.store.setPopupVisible(false)
        #expect(player.samples == 1)

        player.position = 95.5
        player.isPlaying = false
        rig.clock.advance(by: 30)
        rig.store.setPopupVisible(true)
        #expect(player.samples == 2)
        #expect(rig.store.playhead == LyricsPlayhead(time: 95.5, isPlaying: false, observedAt: rig.clock.now))
    }

    @Test("Hiding or closing takes no sample, and neither does showing a popup over a closed panel")
    func noSampleWhenNotWatching() {
        let rig = Rig()
        let player = FakePlayerPosition(position: 10, isPlaying: true)
        rig.store.playbackSampler = { player.sample() }
        rig.store.setPopupVisible(false)
        rig.store.setPopupVisible(true)
        #expect(player.samples == 0)
        rig.store.setPanelOpen(true)
        rig.store.setPanelOpen(false)
        #expect(player.samples == 1)
        #expect(rig.store.playhead.time == 10)
    }

    @Test("Repeating the state it is already in samples nothing")
    func repeatedStateSamplesNothing() {
        let rig = Rig()
        let player = FakePlayerPosition()
        rig.store.playbackSampler = { player.sample() }
        rig.store.setPanelOpen(true)
        rig.store.setPanelOpen(true)
        rig.store.setPopupVisible(true)
        #expect(player.samples == 1)
    }

    @Test("Without a sampler, opening the panel leaves the playhead alone")
    func nilSamplerIsSafe() {
        let rig = Rig()
        rig.store.setPanelOpen(true)
        rig.store.setPopupVisible(false)
        rig.store.setPopupVisible(true)
        #expect(rig.store.playhead == .zero)
    }
}

// MARK: - Debounce

/// A skipped-through queue sends one request, for the song it stops on. The timer is injected; the real one is
/// `Task.sleep`, which a cancelled task leaves early. The fake ignores cancellation, so a stale timer that wakes
/// late has to be dropped by the store itself.
@MainActor
@Suite("Music lyrics store: debounce")
struct MusicLyricsStoreDebounceTests {

    @Test("The wait is 300 ms")
    func waitIsThreeHundredMilliseconds() async {
        #expect(MusicLyricsStore.debounce == .milliseconds(300))
        let sleeper = FakeSleeper(gated: false)
        let rig = Rig(sleeper: sleeper)
        rig.store.setPanelOpen(true)
        rig.store.trackChanged(Rig.track("a"), duration: 200)
        await rig.settle()
        #expect(sleeper.requested == [.milliseconds(300)])
    }

    @Test("Skipping a, b, c sends only c")
    func rapidChangesSendOne() async {
        let sleeper = FakeSleeper()
        let rig = Rig(sleeper: sleeper)
        rig.provider.setResult(.plain("From c"), for: "c")
        rig.store.setPanelOpen(true)
        rig.store.trackChanged(Rig.track("a"), duration: 200)
        rig.store.trackChanged(Rig.track("b"), duration: 200)
        rig.store.trackChanged(Rig.track("c"), duration: 200)
        #expect(rig.store.state == .loading)
        #expect(await eventually { sleeper.requested.count == 3 })
        #expect(rig.provider.queries.isEmpty)

        await sleeper.release()
        await rig.settle()
        await rig.idle()
        #expect(rig.provider.videoIds == ["c"])
        #expect(rig.store.state == .loaded(.plain("From c")))
    }

    @Test("The panel shows loading at once, before the wait is over")
    func loadingImmediately() async {
        let sleeper = FakeSleeper()
        let rig = Rig(sleeper: sleeper)
        rig.store.setPanelOpen(true)
        rig.store.trackChanged(Rig.track("a"), duration: 200)
        #expect(rig.store.state == .loading)
        #expect(await eventually { sleeper.requested.count == 1 })
        #expect(rig.store.state == .loading)
        #expect(rig.provider.queries.isEmpty)
        await sleeper.release()
        await rig.settle()
    }

    @Test("A timer that wakes after the panel closed sends nothing")
    func closingDuringTheWait() async {
        let sleeper = FakeSleeper()
        let rig = Rig(sleeper: sleeper)
        rig.store.setPanelOpen(true)
        rig.store.trackChanged(Rig.track("a"), duration: 200)
        #expect(await eventually { sleeper.requested.count == 1 })
        rig.store.setPanelOpen(false)
        await sleeper.release()
        await rig.idle()
        #expect(rig.provider.queries.isEmpty)
        #expect(rig.store.state == .idle)
    }

    @Test("A timer that wakes after the track went away sends nothing")
    func trackGoneDuringTheWait() async {
        let sleeper = FakeSleeper()
        let rig = Rig(sleeper: sleeper)
        rig.store.setPanelOpen(true)
        rig.store.trackChanged(Rig.track("a"), duration: 200)
        #expect(await eventually { sleeper.requested.count == 1 })
        rig.store.trackChanged(nil, duration: 0)
        await sleeper.release()
        await rig.idle()
        #expect(rig.provider.queries.isEmpty)
        #expect(rig.store.state == .idle)
    }

    @Test("A timer that wakes after a reset sends nothing")
    func resetDuringTheWait() async {
        let sleeper = FakeSleeper()
        let rig = Rig(sleeper: sleeper)
        rig.store.setPanelOpen(true)
        rig.store.trackChanged(Rig.track("a"), duration: 200)
        #expect(await eventually { sleeper.requested.count == 1 })
        rig.store.reset()
        await sleeper.release()
        await rig.idle()
        #expect(rig.provider.queries.isEmpty)
    }

    @Test("Opening the panel is not debounced")
    func openingIsImmediate() async {
        let sleeper = FakeSleeper()
        let rig = Rig(sleeper: sleeper)
        rig.provider.setResult(.plain("From a"), for: "a")
        rig.store.trackChanged(Rig.track("a"), duration: 200)
        rig.store.setPanelOpen(true)
        await rig.settle()
        #expect(sleeper.requested.isEmpty)
        #expect(rig.provider.videoIds == ["a"])
        #expect(rig.store.state == .loaded(.plain("From a")))
    }

    @Test("Showing the popup is not debounced")
    func showingIsImmediate() async {
        let sleeper = FakeSleeper()
        let rig = Rig(sleeper: sleeper)
        rig.store.setPopupVisible(false)
        rig.store.setPanelOpen(true)
        rig.store.trackChanged(Rig.track("a"), duration: 200)
        rig.store.setPopupVisible(true)
        await rig.settle()
        #expect(sleeper.requested.isEmpty)
        #expect(rig.provider.videoIds == ["a"])
    }

    @Test("Retry is not debounced")
    func retryIsImmediate() async {
        let sleeper = FakeSleeper(gated: false)
        let rig = Rig(sleeper: sleeper)
        rig.provider.setError(URLError(.timedOut), for: "a")
        rig.store.setPanelOpen(true)
        rig.store.trackChanged(Rig.track("a"), duration: 200)
        await rig.settle()
        #expect(sleeper.requested.count == 1)

        rig.provider.setError(nil, for: "a")
        rig.provider.setResult(.plain("From a"), for: "a")
        rig.store.retry()
        await rig.settle()
        #expect(sleeper.requested.count == 1)
        #expect(rig.provider.queries.count == 2)
    }

    @Test("A late duration refetch is not debounced")
    func refetchIsImmediate() async {
        let sleeper = FakeSleeper(gated: false)
        let rig = Rig(sleeper: sleeper)
        rig.store.setPanelOpen(true)
        rig.store.trackChanged(Rig.track("a", seconds: nil), duration: 0)
        await rig.settle()
        rig.store.trackChanged(Rig.track("a", seconds: nil), duration: 200)
        await rig.settle()
        #expect(sleeper.requested.count == 1)
        #expect(rig.provider.queries.map(\.duration) == [nil, 200])
    }

    @Test("A duration that arrives during the wait goes out with the one request")
    func durationDuringTheWait() async {
        let sleeper = FakeSleeper()
        let rig = Rig(sleeper: sleeper)
        rig.store.setPanelOpen(true)
        rig.store.trackChanged(Rig.track("a", seconds: nil), duration: 0)
        #expect(await eventually { sleeper.requested.count == 1 })
        rig.store.trackChanged(Rig.track("a", seconds: nil), duration: 187)
        #expect(rig.provider.queries.isEmpty)

        await sleeper.release()
        await rig.settle()
        await rig.idle()
        #expect(rig.provider.queries.map(\.duration) == [187])
    }

    @Test("A track change during a request in flight waits too, and only the last one is sent")
    func changeDuringARequest() async {
        let sleeper = FakeSleeper(gated: false)
        let rig = Rig(sleeper: sleeper)
        let gate = MusicTestGate()
        rig.provider.setGate(gate, for: "a")
        rig.provider.setResult(.plain("From b"), for: "b")
        rig.store.setPanelOpen(true)
        rig.store.trackChanged(Rig.track("a"), duration: 200)
        #expect(await eventually { rig.provider.videoIds == ["a"] })
        rig.store.trackChanged(Rig.track("b"), duration: 200)
        await rig.settle()
        await gate.open()
        await rig.idle()
        #expect(rig.provider.videoIds == ["a", "b"])
        #expect(rig.store.state == .loaded(.plain("From b")))
    }
}

// MARK: - Server-error window, copy and factories

@MainActor
@Suite("Music lyrics store: server errors and copy")
struct MusicLyricsStoreBackoffTests {

    @Test("A 5xx window shows the failure, and Retry waits for it to pass")
    func windowThenRetry() async {
        let rig = Rig()
        let until = rig.clock.now.addingTimeInterval(30)
        rig.provider.setError(LyricsError.backoff(status: 500, until: until), for: "a")
        rig.store.setPanelOpen(true)
        rig.store.trackChanged(Rig.track("a"), duration: 200)
        await rig.settle()
        #expect(rig.store.state == .failed("The lyrics service returned an error (500). Trying again shortly.", retryAfter: until))
        #expect(!rig.store.canRetry)

        rig.clock.advance(by: 10)
        rig.store.retry()
        await rig.idle()
        #expect(rig.provider.queries.count == 1)
        #expect(!rig.store.canRetry)

        rig.clock.advance(by: 21)
        #expect(rig.store.canRetry)
        rig.provider.setError(nil, for: "a")
        rig.provider.setResult(.plain("From a"), for: "a")
        rig.store.retry()
        #expect(rig.store.state == .loading)
        await rig.settle()
        #expect(rig.store.state == .loaded(.plain("From a")))
        #expect(rig.provider.queries.count == 2)
    }

    @Test("Reopening the panel inside the window sends nothing, and after it asks again")
    func reopenAroundTheWindow() async {
        let rig = Rig()
        let until = rig.clock.now.addingTimeInterval(30)
        rig.provider.setError(LyricsError.backoff(status: 502, until: until), for: "a")
        rig.store.trackChanged(Rig.track("a"), duration: 200)
        rig.store.setPanelOpen(true)
        await rig.settle()

        rig.store.setPanelOpen(false)
        rig.store.setPanelOpen(true)
        await rig.idle()
        #expect(rig.provider.queries.count == 1)
        #expect(rig.store.state == .failed("The lyrics service returned an error (502). Trying again shortly.", retryAfter: until))

        rig.clock.advance(by: 31)
        rig.provider.setError(nil, for: "a")
        rig.provider.setResult(.instrumental, for: "a")
        rig.store.setPanelOpen(false)
        rig.store.setPanelOpen(true)
        await rig.settle()
        #expect(rig.store.state == .loaded(.instrumental))
    }

    @Test("A new track inside the window is still handed to the client, which holds the line")
    func newTrackInsideTheWindow() async {
        let rig = Rig()
        let until = rig.clock.now.addingTimeInterval(30)
        rig.provider.setError(LyricsError.backoff(status: 504, until: until), for: "a")
        rig.provider.setError(LyricsError.busy(until: until), for: "b")
        rig.store.setPanelOpen(true)
        rig.store.trackChanged(Rig.track("a"), duration: 200)
        await rig.settle()
        rig.store.trackChanged(Rig.track("b"), duration: 200)
        await rig.settle()
        #expect(rig.store.state == .busy(until: until))
        #expect(rig.provider.videoIds == ["a", "b"])
    }

    @Test("A plain failure has no window and can be retried at once")
    func plainFailureRetriesAtOnce() async {
        let rig = Rig()
        rig.provider.setError(LyricsError.http(403), for: "a")
        rig.store.setPanelOpen(true)
        rig.store.trackChanged(Rig.track("a"), duration: 200)
        await rig.settle()
        #expect(rig.store.state == .failed("The lyrics service returned an error (403)."))
        #expect(rig.store.canRetry)
    }

    @Test("The busy copy says it is trying again shortly")
    func busyCopy() {
        #expect(MusicLyricsStore.busyMessage == "Lyrics service is busy. Trying again shortly.")
        #expect(MusicLyricsStore.message(for: LyricsError.busy(until: Date())) == MusicLyricsStore.busyMessage)
    }

    @Test("A 5xx message carries only the status, and says it is trying again shortly")
    func backoffMessage() {
        #expect(
            MusicLyricsStore.message(for: LyricsError.backoff(status: 502, until: Date()))
                == "The lyrics service returned an error (502). Trying again shortly."
        )
    }

    @Test("A failure with no window carries only the status and promises no retry")
    func httpMessage() {
        #expect(MusicLyricsStore.message(for: LyricsError.http(403)) == "The lyrics service returned an error (403).")
    }

    @Test("The live store talks to the LRCLIB client")
    func liveUsesTheClient() {
        #expect(MusicLyricsStore.live().provider is LRCLibClient)
    }

    @Test("The no-op provider finds no lyrics and never fails")
    func noLyricsProvider() async throws {
        let provider = NoLyricsProvider()
        #expect(try await provider.lyrics(for: LyricsSamples.query()) == .notFound)
        #expect(try await provider.lyrics(for: LyricsSamples.query(videoId: "other", duration: nil)) == .notFound)
    }
}

// MARK: - Automatic retry

/// While the panel is watching, a busy or backoff window that ends is followed by another try, with no tap. The timer
/// is the store's injected sleep. The fake ignores cancellation, so a timer that wakes after the panel closed, the
/// track changed or a reset has to be dropped by the store itself.
@MainActor
@Suite("Music lyrics store: automatic retry")
struct MusicLyricsStoreAutoRetryTests {

    /// Where a watching store stops watching, or loses its track, while its retry timer is waiting.
    enum Away: CaseIterable, CustomTestStringConvertible {
        case panelClosed, popupHidden, trackGone, reset

        var testDescription: String {
            switch self {
            case .panelClosed: "the panel closed"
            case .popupHidden: "the popup hid"
            case .trackGone: "the track went away"
            case .reset: "a reset"
            }
        }
    }

    /// Opens the panel on track "a" while LRCLIB answers with `error`, and waits until the retry timer is asking to
    /// sleep. The track is set before the panel opens, so the first fetch is not debounced and the sleeper's first
    /// request is the retry's.
    private func land(_ error: any Error, _ rig: Rig, _ sleeper: FakeSleeper) async {
        rig.provider.setError(error, for: "a")
        rig.store.trackChanged(Rig.track("a"), duration: 200)
        rig.store.setPanelOpen(true)
        await rig.settle()
        #expect(await eventually { sleeper.requested.count == 1 })
    }

    private func answer(_ rig: Rig, with result: LyricsResult, for id: String = "a") {
        rig.provider.setError(nil, for: id)
        rig.provider.setResult(result, for: id)
    }

    // MARK: - Busy and backoff windows

    @Test("A busy window ends in another try by itself, after the window")
    func busyRetriesByItself() async {
        let sleeper = FakeSleeper()
        let rig = Rig(sleeper: sleeper)
        let until = rig.clock.now.addingTimeInterval(30)
        await land(LyricsError.busy(until: until), rig, sleeper)
        #expect(rig.store.state == .busy(until: until))
        #expect(sleeper.requested == [.seconds(30)])
        #expect(rig.provider.queries.count == 1)

        rig.clock.advance(by: 30)
        answer(rig, with: .plain("From a"))
        await sleeper.release()
        #expect(await eventually { rig.store.state == .loaded(.plain("From a")) })
        #expect(rig.provider.queries.count == 2)
    }

    @Test("A server-error window ends in another try by itself, and its message says so")
    func backoffRetriesByItself() async {
        let sleeper = FakeSleeper()
        let rig = Rig(sleeper: sleeper)
        let until = rig.clock.now.addingTimeInterval(15)
        await land(LyricsError.backoff(status: 503, until: until), rig, sleeper)
        #expect(rig.store.state == .failed("The lyrics service returned an error (503). Trying again shortly.", retryAfter: until))
        #expect(sleeper.requested == [.seconds(15)])

        rig.clock.advance(by: 15)
        answer(rig, with: .instrumental)
        await sleeper.release()
        #expect(await eventually { rig.store.state == .loaded(.instrumental) })
        #expect(rig.provider.queries.count == 2)
    }

    @Test("The wait is what is left of the window, never negative")
    func waitIsWhatIsLeft() async {
        let sleeper = FakeSleeper()
        let rig = Rig(sleeper: sleeper)
        let gate = MusicTestGate()
        let until = rig.clock.now.addingTimeInterval(30)
        rig.provider.setError(LyricsError.busy(until: until), for: "a")
        rig.provider.setGate(gate, for: "a")
        rig.store.trackChanged(Rig.track("a"), duration: 200)
        rig.store.setPanelOpen(true)
        // The answer takes a while: 12 s of the window are gone when it lands.
        #expect(await eventually { rig.provider.queries.count == 1 })
        rig.clock.advance(by: 12)
        await gate.open()
        await rig.settle()
        #expect(await eventually { sleeper.requested.count == 1 })
        #expect(sleeper.requested == [.seconds(18)])
        await sleeper.release()
    }

    @Test("A window that is already over asks again at once")
    func overWindowRetriesAtOnce() async {
        let sleeper = FakeSleeper()
        let rig = Rig(sleeper: sleeper)
        await land(LyricsError.busy(until: rig.clock.now.addingTimeInterval(-5)), rig, sleeper)
        #expect(sleeper.requested == [.zero])

        answer(rig, with: .plain("From a"))
        await sleeper.release()
        #expect(await eventually { rig.store.state == .loaded(.plain("From a")) })
    }

    @Test("A try that lands busy again schedules the next one")
    func busyAgainSchedulesAgain() async {
        let sleeper = FakeSleeper()
        let rig = Rig(sleeper: sleeper)
        await land(LyricsError.busy(until: rig.clock.now.addingTimeInterval(30)), rig, sleeper)

        rig.clock.advance(by: 30)
        let next = rig.clock.now.addingTimeInterval(30)
        rig.provider.setError(LyricsError.busy(until: next), for: "a")
        await sleeper.release()
        #expect(await eventually { sleeper.requested.count == 2 })
        #expect(sleeper.requested == [.seconds(30), .seconds(30)])
        #expect(rig.provider.queries.count == 2)
        #expect(rig.store.state == .busy(until: next))
    }

    @Test("Other failures and good answers start no timer")
    func nothingElseIsRetried() async {
        let sleeper = FakeSleeper()
        let rig = Rig(sleeper: sleeper)
        let errors: [any Error] = [LyricsError.http(403), LyricsError.parse, URLError(.timedOut)]
        for (index, error) in errors.enumerated() {
            let id = "e\(index)"
            rig.provider.setError(error, for: id)
            rig.store.trackChanged(Rig.track(id), duration: 200)
            rig.store.setPanelOpen(true)
            await rig.settle()
            rig.store.setPanelOpen(false)
        }
        rig.provider.setResult(.plain("From ok"), for: "ok")
        rig.store.trackChanged(Rig.track("ok"), duration: 200)
        rig.store.setPanelOpen(true)
        await rig.settle()
        await rig.idle()
        #expect(rig.store.state == .loaded(.plain("From ok")))
        #expect(sleeper.requested.isEmpty)
    }

    // MARK: - Out of view

    @Test("A timer that wakes after the panel closed, the popup hid, the track went away or a reset sends nothing", arguments: Away.allCases)
    func awayDropsTheTimer(away: Away) async {
        let sleeper = FakeSleeper()
        let rig = Rig(sleeper: sleeper)
        let until = rig.clock.now.addingTimeInterval(30)
        await land(LyricsError.busy(until: until), rig, sleeper)

        switch away {
        case .panelClosed: rig.store.setPanelOpen(false)
        case .popupHidden: rig.store.setPopupVisible(false)
        case .trackGone: rig.store.trackChanged(nil, duration: 0)
        case .reset: rig.store.reset()
        }
        rig.clock.advance(by: 31)
        answer(rig, with: .plain("From a"))
        await sleeper.release()
        await rig.idle()
        #expect(rig.provider.queries.count == 1)
        #expect(rig.store.state != .loading)
        #expect(rig.store.state != .loaded(.plain("From a")))
    }

    @Test("A track change drops the timer and fetches only the new track")
    func trackChangeDropsTheTimer() async {
        let sleeper = FakeSleeper()
        let rig = Rig(sleeper: sleeper)
        await land(LyricsError.busy(until: rig.clock.now.addingTimeInterval(30)), rig, sleeper)

        rig.clock.advance(by: 31)
        answer(rig, with: .plain("From a"))
        answer(rig, with: .plain("From b"), for: "b")
        rig.store.trackChanged(Rig.track("b"), duration: 200)
        #expect(await eventually { sleeper.requested.count == 2 })
        await sleeper.release()
        #expect(await eventually { rig.store.state == .loaded(.plain("From b")) })
        await rig.idle()
        #expect(rig.provider.videoIds == ["a", "b"])
    }

    @Test("Coming back after the window asks again at once")
    func comingBackAfterTheWindow() async {
        let sleeper = FakeSleeper()
        let rig = Rig(sleeper: sleeper)
        await land(LyricsError.busy(until: rig.clock.now.addingTimeInterval(30)), rig, sleeper)

        rig.store.setPanelOpen(false)
        rig.clock.advance(by: 31)
        answer(rig, with: .plain("From a"))
        rig.store.setPanelOpen(true)
        #expect(rig.store.state == .loading)
        await rig.settle()
        #expect(rig.store.state == .loaded(.plain("From a")))

        // The old timer wakes late and finds nothing to do.
        await sleeper.release()
        await rig.idle()
        #expect(rig.provider.queries.count == 2)
    }

    @Test("Coming back inside the window sends nothing and waits out what is left")
    func comingBackInsideTheWindow() async {
        let sleeper = FakeSleeper()
        let rig = Rig(sleeper: sleeper)
        let until = rig.clock.now.addingTimeInterval(30)
        await land(LyricsError.busy(until: until), rig, sleeper)

        rig.store.setPopupVisible(false)
        rig.clock.advance(by: 10)
        rig.store.setPopupVisible(true)
        #expect(rig.store.state == .busy(until: until))
        #expect(await eventually { sleeper.requested.count == 2 })
        #expect(sleeper.requested == [.seconds(30), .seconds(20)])
        #expect(rig.provider.queries.count == 1)

        rig.clock.advance(by: 20)
        answer(rig, with: .plain("From a"))
        await sleeper.release()
        #expect(await eventually { rig.store.state == .loaded(.plain("From a")) })
        #expect(rig.provider.queries.count == 2)
    }

    @Test("Coming back inside a server-error window waits out what is left too")
    func comingBackInsideABackoffWindow() async {
        let sleeper = FakeSleeper()
        let rig = Rig(sleeper: sleeper)
        let until = rig.clock.now.addingTimeInterval(15)
        await land(LyricsError.backoff(status: 500, until: until), rig, sleeper)

        rig.store.setPanelOpen(false)
        rig.clock.advance(by: 5)
        rig.store.setPanelOpen(true)
        #expect(await eventually { sleeper.requested.count == 2 })
        #expect(sleeper.requested == [.seconds(15), .seconds(10)])
        #expect(rig.provider.queries.count == 1)
    }

    @Test("Tapping Retry after the window drops the timer, so nothing is asked twice")
    func manualRetryDropsTheTimer() async {
        let sleeper = FakeSleeper()
        let rig = Rig(sleeper: sleeper)
        await land(LyricsError.busy(until: rig.clock.now.addingTimeInterval(30)), rig, sleeper)

        rig.clock.advance(by: 31)
        answer(rig, with: .plain("From a"))
        rig.store.retry()
        await rig.settle()
        #expect(rig.store.state == .loaded(.plain("From a")))

        await sleeper.release()
        await rig.idle()
        #expect(rig.provider.queries.count == 2)
    }
}
