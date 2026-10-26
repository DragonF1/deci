// DeciTests/PlaybackKeyRouterTests.swift
// Where a play/pause, next or previous key goes. The router is a plain value: the frontmost app, the Chrome tab list and
// Deci's playback state go in, a route comes out, and the one thing it remembers between presses is the tab a key paused.

import Foundation
import Testing
@testable import Deci

private let chrome = "com.google.Chrome"
private let safari = "com.apple.Safari"

private nonisolated let allPlaybackKeys: [PlaybackKey] = [.playPause, .next, .previous]

@Suite("PlaybackKeyRouter")
struct PlaybackKeyRouterTests {
    private func tab(_ id: Int, audible: Bool = false, paused: Bool = false, active: Bool = false) -> ChromeTab {
        var tab = ChromeTab(id: id, title: "Tab \(id)", volume: 1, isAudible: audible)
        tab.paused = paused
        tab.isActive = active
        return tab
    }

    /// What Deci's rules alone would do with `key`, for the tests that expect a press to fall through to them.
    private func deciRoute(_ key: PlaybackKey, _ state: DeciPlaybackState) -> PlaybackKeyRoute {
        var router = PlaybackKeyRouter()
        return router.route(key, frontmostBundleID: safari, tabs: [], deci: state)
    }

    // MARK: - Chrome frontmost with a tab playing

    @Test("With Chrome in front and a tab audible, each key acts on that tab", arguments: allPlaybackKeys)
    func chromeAudibleTab(key: PlaybackKey) {
        var router = PlaybackKeyRouter()
        let route = router.route(key, frontmostBundleID: chrome, tabs: [tab(5, audible: true)], deci: .playing)
        #expect(route == .chromeTab(id: 5, key: key))
    }

    @Test("The audible flag decides, not the paused flag")
    func audibleNotPaused() {
        var router = PlaybackKeyRouter()
        // Audible but flagged paused (the optimistic flip of a toggle Chrome has not confirmed yet): still the target.
        #expect(router.route(.playPause, frontmostBundleID: chrome, tabs: [tab(5, audible: true, paused: true)], deci: .idle)
            == .chromeTab(id: 5, key: .playPause))
        // Silent and flagged playing: not a target.
        var other = PlaybackKeyRouter()
        #expect(other.route(.playPause, frontmostBundleID: chrome, tabs: [tab(5, audible: false, paused: false)], deci: .idle)
            == .nothing)
    }

    @Test("Of several audible tabs, the active one is the target")
    func prefersActive() {
        var router = PlaybackKeyRouter()
        let tabs = [tab(1, audible: true), tab(2, audible: true, active: true), tab(3, audible: true)]
        #expect(router.route(.next, frontmostBundleID: chrome, tabs: tabs, deci: .idle) == .chromeTab(id: 2, key: .next))
    }

    @Test("With no active tab among the audible ones, the first in list order is the target")
    func firstAudibleInListOrder() {
        var router = PlaybackKeyRouter()
        let tabs = [tab(9), tab(4, audible: true), tab(2, audible: true), tab(7, audible: true)]
        #expect(router.route(.previous, frontmostBundleID: chrome, tabs: tabs, deci: .idle) == .chromeTab(id: 4, key: .previous))
    }

    @Test("A tab that is active but silent does not beat an audible one")
    func activeButSilent() {
        var router = PlaybackKeyRouter()
        let tabs = [tab(1, active: true), tab(2, audible: true)]
        #expect(router.route(.playPause, frontmostBundleID: chrome, tabs: tabs, deci: .idle) == .chromeTab(id: 2, key: .playPause))
    }

    // MARK: - The tab a key paused

    @Test("A second play/pause resumes the tab the first one paused, once it has gone silent")
    func resumesKeyPausedTab() {
        var router = PlaybackKeyRouter()
        #expect(router.route(.playPause, frontmostBundleID: chrome, tabs: [tab(5, audible: true)], deci: .playing)
            == .chromeTab(id: 5, key: .playPause))
        #expect(router.keyPausedTabID == 5)

        // The tab is quiet now and Deci is not playing: the key-paused tab is the one to resume.
        #expect(router.route(.playPause, frontmostBundleID: chrome, tabs: [tab(5, paused: true)], deci: .pausedWithSong)
            == .chromeTab(id: 5, key: .playPause))
        #expect(router.keyPausedTabID == nil)
    }

    @Test("The key-paused tab is resumed only when Deci is not playing", arguments: [DeciPlaybackState.idle, .pausedWithSong])
    func resumesKeyPausedTabWhenDeciIsNotPlaying(state: DeciPlaybackState) {
        var router = PlaybackKeyRouter()
        _ = router.route(.playPause, frontmostBundleID: chrome, tabs: [tab(5, audible: true)], deci: state)
        #expect(router.route(.playPause, frontmostBundleID: chrome, tabs: [tab(5, paused: true)], deci: state)
            == .chromeTab(id: 5, key: .playPause))
        #expect(router.keyPausedTabID == nil)
    }

    @Test("Memory set, nothing audible in Chrome, Deci playing: play/pause pauses Deci and keeps the memory")
    func deciPlayingBeatsTheKeyPausedTab() {
        var router = PlaybackKeyRouter()
        _ = router.route(.playPause, frontmostBundleID: chrome, tabs: [tab(5, audible: true)], deci: .playing)
        #expect(router.keyPausedTabID == 5)

        // The tab is quiet and Deci is playing: the front app is not playing, so Deci takes the key.
        #expect(router.route(.playPause, frontmostBundleID: chrome, tabs: [tab(5, paused: true)], deci: .playing) == .deci(.pause))
        #expect(router.keyPausedTabID == 5)

        // Deci is paused now, so the next press is the key-paused tab's.
        #expect(router.route(.playPause, frontmostBundleID: chrome, tabs: [tab(5, paused: true)], deci: .pausedWithSong)
            == .chromeTab(id: 5, key: .playPause))
        #expect(router.keyPausedTabID == nil)
    }

    @Test("Memory set, the tab still reads audible, Deci playing: Deci takes play/pause")
    func deciPlayingBeatsTheLingeringTab() {
        var router = PlaybackKeyRouter()
        _ = router.route(.playPause, frontmostBundleID: chrome, tabs: [tab(5, audible: true)], deci: .playing)
        #expect(router.route(.playPause, frontmostBundleID: chrome, tabs: [tab(5, audible: true)], deci: .playing) == .deci(.pause))
        #expect(router.keyPausedTabID == 5)
    }

    @Test("A really audible tab still beats a playing Deci, remembered tab or not")
    func audibleTabBeatsDeci() {
        var router = PlaybackKeyRouter()
        _ = router.route(.playPause, frontmostBundleID: chrome, tabs: [tab(5, audible: true)], deci: .playing)
        #expect(router.route(.playPause, frontmostBundleID: chrome, tabs: [tab(5, paused: true), tab(7, audible: true)], deci: .playing)
            == .chromeTab(id: 7, key: .playPause))
    }

    @Test("Pause, resume and pause again each go to the tab")
    func pauseResumePause() {
        var router = PlaybackKeyRouter()
        let playing = [tab(5, audible: true)]
        let silent = [tab(5, paused: true)]
        for tabs in [playing, silent, playing] {
            #expect(router.route(.playPause, frontmostBundleID: chrome, tabs: tabs, deci: .idle) == .chromeTab(id: 5, key: .playPause))
        }
        #expect(router.keyPausedTabID == 5)
    }

    @Test("A key-paused tab that still reads audible does not hide another audible tab")
    func staleAudibleTabYieldsToAnother() {
        var router = PlaybackKeyRouter()
        _ = router.route(.playPause, frontmostBundleID: chrome, tabs: [tab(5, audible: true)], deci: .idle)

        // Chrome keeps `audible` on for about two seconds after the sound stops; tab 7 is the one really playing.
        let route = router.route(.playPause, frontmostBundleID: chrome, tabs: [tab(5, audible: true), tab(7, audible: true)], deci: .idle)
        #expect(route == .chromeTab(id: 7, key: .playPause))
        #expect(router.keyPausedTabID == 7)
    }

    @Test("A key-paused tab that still reads audible, alone, is resumed when Deci is not playing")
    func staleAudibleTabAlone() {
        var router = PlaybackKeyRouter()
        _ = router.route(.playPause, frontmostBundleID: chrome, tabs: [tab(5, audible: true)], deci: .idle)
        let route = router.route(.playPause, frontmostBundleID: chrome, tabs: [tab(5, audible: true)], deci: .pausedWithSong)
        #expect(route == .chromeTab(id: 5, key: .playPause))
        #expect(router.keyPausedTabID == nil)
    }

    @Test("Next and previous never go to the key-paused tab")
    func nextAndPreviousIgnoreKeyPausedTab() {
        for key in [PlaybackKey.next, .previous] {
            var router = PlaybackKeyRouter()
            _ = router.route(.playPause, frontmostBundleID: chrome, tabs: [tab(5, audible: true)], deci: .idle)

            // Silent: nothing in Chrome is playing, so Deci's rules decide.
            #expect(router.route(key, frontmostBundleID: chrome, tabs: [tab(5, paused: true)], deci: .playing)
                == deciRoute(key, .playing))
            #expect(router.route(key, frontmostBundleID: chrome, tabs: [tab(5, paused: true)], deci: .idle) == .nothing)

            // Still reading audible: it is stale, not playing.
            #expect(router.route(key, frontmostBundleID: chrome, tabs: [tab(5, audible: true)], deci: .idle) == .nothing)

            // The memory survived all of that, so play/pause still resumes the tab.
            #expect(router.keyPausedTabID == 5)
            #expect(router.route(.playPause, frontmostBundleID: chrome, tabs: [tab(5, paused: true)], deci: .idle)
                == .chromeTab(id: 5, key: .playPause))
        }
    }

    @Test("Next and previous go to another audible tab while the key-paused one lingers")
    func nextGoesToTheOtherTab() {
        var router = PlaybackKeyRouter()
        _ = router.route(.playPause, frontmostBundleID: chrome, tabs: [tab(5, audible: true)], deci: .idle)
        let route = router.route(.next, frontmostBundleID: chrome, tabs: [tab(5, audible: true), tab(7, audible: true)], deci: .idle)
        #expect(route == .chromeTab(id: 7, key: .next))
        // Skipping a track is not a pause: the memory is untouched.
        #expect(router.keyPausedTabID == 5)
    }

    @Test("The tab to resume is gone from the list: Deci's rules apply and the memory is dropped")
    func keyPausedTabRemoved() {
        var router = PlaybackKeyRouter()
        _ = router.route(.playPause, frontmostBundleID: chrome, tabs: [tab(5, audible: true)], deci: .idle)

        #expect(router.route(.playPause, frontmostBundleID: chrome, tabs: [tab(8, paused: true)], deci: .playing) == .deci(.pause))
        #expect(router.keyPausedTabID == nil)

        // It never comes back as a target, even if the id shows up again.
        #expect(router.route(.playPause, frontmostBundleID: chrome, tabs: [tab(5, paused: true)], deci: .pausedWithSong) == .deci(.resume))
    }

    @Test("The memory is dropped when the list loses the tab, even if a key press that finds nothing comes first")
    func keyPausedTabRemovedThenNothing() {
        var router = PlaybackKeyRouter()
        _ = router.route(.playPause, frontmostBundleID: chrome, tabs: [tab(5, audible: true)], deci: .idle)
        #expect(router.route(.next, frontmostBundleID: chrome, tabs: [], deci: .idle) == .nothing)
        #expect(router.keyPausedTabID == nil)
    }

    @Test("Chrome stops being in front: the memory is dropped")
    func chromeDeactivated() {
        var router = PlaybackKeyRouter()
        _ = router.route(.playPause, frontmostBundleID: chrome, tabs: [tab(5, audible: true)], deci: .idle)
        #expect(router.keyPausedTabID == 5)

        router.frontmostApplicationChanged(to: safari)
        #expect(router.keyPausedTabID == nil)

        #expect(router.route(.playPause, frontmostBundleID: chrome, tabs: [tab(5, paused: true)], deci: .pausedWithSong) == .deci(.resume))
    }

    @Test("Chrome coming to the front keeps the memory; an unknown front app drops it")
    func activationHandling() {
        var router = PlaybackKeyRouter()
        _ = router.route(.playPause, frontmostBundleID: chrome, tabs: [tab(5, audible: true)], deci: .idle)

        router.frontmostApplicationChanged(to: chrome)
        #expect(router.keyPausedTabID == 5)

        router.frontmostApplicationChanged(to: nil)
        #expect(router.keyPausedTabID == nil)
    }

    @Test("A press made while Chrome is not in front drops the memory too")
    func pressWithChromeBehind() {
        var router = PlaybackKeyRouter()
        _ = router.route(.playPause, frontmostBundleID: chrome, tabs: [tab(5, audible: true)], deci: .idle)
        _ = router.route(.next, frontmostBundleID: safari, tabs: [tab(5, paused: true)], deci: .idle)
        #expect(router.keyPausedTabID == nil)
    }

    // MARK: - Chrome not in front, or nothing playing in it

    @Test("Chrome not in front: an audible tab is not touched, Deci's rules decide", arguments: allPlaybackKeys)
    func chromeBehind(key: PlaybackKey) {
        for front in [safari, "com.spotify.client", "com.abraham.Deci", nil] as [String?] {
            var router = PlaybackKeyRouter()
            let route = router.route(key, frontmostBundleID: front, tabs: [tab(5, audible: true)], deci: .playing)
            #expect(route == deciRoute(key, .playing))
        }
    }

    @Test("Chrome in front with nothing audible falls to Deci's rules", arguments: allPlaybackKeys)
    func chromeSilent(key: PlaybackKey) {
        for state in [DeciPlaybackState.playing, .pausedWithSong, .idle] {
            var router = PlaybackKeyRouter()
            let route = router.route(key, frontmostBundleID: chrome, tabs: [tab(5), tab(6, paused: true)], deci: state)
            #expect(route == deciRoute(key, state))
        }
    }

    @Test("Chrome in front with no tabs at all falls to Deci's rules")
    func chromeNoTabs() {
        var router = PlaybackKeyRouter()
        #expect(router.route(.playPause, frontmostBundleID: chrome, tabs: [], deci: .playing) == .deci(.pause))
    }

    // MARK: - Deci

    @Test("Deci playing: play/pause pauses, next and previous skip")
    func deciPlaying() {
        #expect(deciRoute(.playPause, .playing) == .deci(.pause))
        #expect(deciRoute(.next, .playing) == .deci(.next))
        #expect(deciRoute(.previous, .playing) == .deci(.previous))
    }

    @Test("Deci paused with a song: play/pause resumes, next and previous do nothing")
    func deciPausedWithSong() {
        #expect(deciRoute(.playPause, .pausedWithSong) == .deci(.resume))
        #expect(deciRoute(.next, .pausedWithSong) == .nothing)
        #expect(deciRoute(.previous, .pausedWithSong) == .nothing)
    }

    @Test("Nothing loaded: every key does nothing", arguments: allPlaybackKeys)
    func nothingLoaded(key: PlaybackKey) {
        #expect(deciRoute(key, .idle) == .nothing)
    }
}
