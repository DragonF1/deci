// DeciTests/Music/LyricsListLifetimeTests.swift
// The synced list hosted in a window that is never shown, then torn down: nothing of it may stay alive. The scroll driver
// owns an event monitor and a table of row frames, so a driver that outlives its list leaks both.

import AppKit
import SwiftUI
import Testing
@testable import Deci

@MainActor
@Suite("Lyrics list: lifetime")
struct LyricsListLifetimeTests {

    /// A holder that does not keep what it points at alive.
    private final class WeakDriver {
        weak var driver: LyricsScrollDriver?
    }

    private func probe(in view: NSView?) -> LyricsProbeView? {
        guard let view else { return nil }
        if let found = view as? LyricsProbeView { return found }
        for child in view.subviews {
            if let found = probe(in: child) { return found }
        }
        return nil
    }

    private func loadedStore() async -> MusicLyricsStore {
        let provider = FakeLyricsProvider()
        provider.setResult(.synced(LyricsSamples.syncedLines), for: "a")
        let store = MusicLyricsStore(provider: provider, now: { Date() }, sleep: { _ in })
        store.trackChanged(MusicSamples.track("a"), duration: 200)
        store.setPanelOpen(true)
        while let task = store.loadTask {
            await task.value
            if store.loadTask == task { break }
        }
        return store
    }

    /// The list hosted in a window that is never ordered front, up and with its glide hook set.
    private func hostList(_ store: MusicLyricsStore) async -> (window: NSWindow, held: WeakDriver, hooked: Bool) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 360), styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: MusicLyricsView(store: store, seek: { _ in }).frame(width: 320, height: 360))

        // Wait for the list to be up and to have set its glide hook: a test that tears down before that proves nothing.
        let held = WeakDriver()
        let begin = Date()
        var hooked = false
        while !hooked, Date().timeIntervalSince(begin) < 20 {
            try? await Task.sleep(for: .milliseconds(20))
            window.contentView?.layoutSubtreeIfNeeded()
            if let driver = probe(in: window.contentView)?.driver {
                held.driver = driver
                hooked = driver.glideChanged != nil && driver.frame(ofRow: 3) != nil
            }
        }
        return (window, held, hooked)
    }

    /// Takes the window down, and waits for the driver to go.
    private func tearDown(_ window: NSWindow, _ held: WeakDriver) async {
        window.contentView = nil
        window.close()
        let begin = Date()
        while held.driver != nil, Date().timeIntervalSince(begin) < 5 {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test("Tearing the synced list down frees its scroll driver, with the glide hook that was set")
    func listFreesItsDriver() async {
        let store = await loadedStore()
        #expect(store.state == .loaded(.synced(LyricsSamples.syncedLines)))
        var up: (window: NSWindow, held: WeakDriver, hooked: Bool)? = await hostList(store)
        #expect(up?.held.driver != nil)
        #expect(up?.hooked == true)
        let held = up?.held ?? WeakDriver()
        if let window = up?.window { await tearDown(window, held) }
        up = nil
        #expect(held.driver == nil)
    }

    @Test("A list torn down in the middle of a glide frees its driver too: no event monitor is left behind")
    func midGlideTeardown() async {
        let store = await loadedStore()
        var up: (window: NSWindow, held: WeakDriver, hooked: Bool)? = await hostList(store)
        #expect(up?.hooked == true)
        if let driver = up?.held.driver {
            #expect(driver.scroll(toRow: 3, animated: true))
            #expect(driver.isGliding)
        }
        let held = up?.held ?? WeakDriver()
        if let window = up?.window { await tearDown(window, held) }
        up = nil
        #expect(held.driver == nil)
    }
}
