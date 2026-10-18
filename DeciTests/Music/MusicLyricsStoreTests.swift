// DeciTests/Music/MusicLyricsStoreTests.swift
// The lyrics store: it fetches only while the panel is open and the popup is showing, only for the
// current track, drops late answers, honours the busy window and resets on sign-out.

import Foundation
import Testing
@testable import Deci

@MainActor
private struct Rig {
    let provider = FakeLyricsProvider()
    let clock = MutableClock()
    let store: MusicLyricsStore

    init() {
        let provider = self.provider
        let clock = self.clock
        store = MusicLyricsStore(provider: provider, now: { clock.now })
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
        rig.store.trackChanged(Rig.track("a"), duration: 0)
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
        #expect(rig.store.playhead == .zero)
        rig.store.observePlayback(position: 12.5, isPlaying: true)
        #expect(rig.store.playhead == LyricsPlayhead(time: 12.5, isPlaying: true, observedAt: rig.clock.now))
        rig.clock.advance(by: 0.5)
        #expect(abs(rig.store.playhead.position(at: rig.clock.now) - 13) < 0.0001)
        rig.store.observePlayback(position: 13, isPlaying: false)
        #expect(!rig.store.playhead.isPlaying)
    }
}
