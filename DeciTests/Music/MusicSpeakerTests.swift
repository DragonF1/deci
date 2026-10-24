// DeciTests/Music/MusicSpeakerTests.swift
// The speaker on the cover that is in the player lights its waves one after the other while audio plays. As a SwiftUI
// `symbolEffect` that redrew the view every display frame, and every frame ran the open popup's whole update and layout
// (60 a second for each playing cover on screen). As an AppKit symbol effect the render server plays it. Covered: the
// image view's look, that the effect is added once per play and again when the view returns to a window, and that the
// popup's window is not laid out while the waves play.

import AppKit
import SwiftUI
import Testing
@testable import Deci

@MainActor
@Suite("MusicSpeakerView")
struct MusicSpeakerViewTests {
    private func makeView(symbolSize: CGFloat = 14) -> MusicSpeakerView {
        let view = MusicSpeakerView(frame: .zero)
        view.configure(symbolSize: symbolSize)
        return view
    }

    @Test("a white speaker symbol, not an accessibility element, taking no mouse events")
    func look() {
        let view = makeView()
        #expect(view.image != nil)
        #expect(view.contentTintColor == .white)
        #expect(!view.isAccessibilityElement())
        #expect(view.hitTest(NSPoint(x: 1, y: 1)) == nil)
    }

    @Test("the symbol follows the size it is asked for")
    func size() throws {
        let small = try #require(makeView(symbolSize: 10).image)
        let large = try #require(makeView(symbolSize: 28).image)
        #expect(large.size.height > small.size.height)
        #expect(large.size.width > small.size.width)
    }

    @Test("the same size again keeps the same image")
    func sameSize() throws {
        let view = makeView(symbolSize: 14)
        let first = try #require(view.image)
        view.configure(symbolSize: 14)
        #expect(view.image === first)
    }

    @Test("it starts paused, and playing adds the effect once")
    func playsOnce() {
        let view = makeView()
        #expect(!view.isPlaying)
        #expect(view.effectsAdded == 0)
        view.setPlaying(true)
        view.setPlaying(true)
        #expect(view.isPlaying)
        #expect(view.effectsAdded == 1)
    }

    @Test("pausing and playing again adds the effect again; pausing twice changes nothing")
    func pauseAndPlay() {
        let view = makeView()
        view.setPlaying(true)
        view.setPlaying(false)
        view.setPlaying(false)
        #expect(!view.isPlaying)
        #expect(view.effectsAdded == 1)
        view.setPlaying(true)
        #expect(view.effectsAdded == 2)
    }

    @Test("a paused speaker never adds an effect, in or out of a window")
    func pausedStaysStill() {
        let view = makeView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 40, height: 40), styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.contentView = view
        defer {
            window.contentView = nil
            window.close()
        }
        view.setPlaying(false)
        #expect(view.effectsAdded == 0)
    }

    @Test("a playing speaker that comes into a window gets its effect again")
    func comesBack() {
        let view = makeView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 40, height: 40), styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        defer {
            window.contentView = nil
            window.close()
        }
        view.setPlaying(true)
        #expect(view.effectsAdded == 1)
        window.contentView = view
        #expect(view.effectsAdded == 2)
        window.contentView = nil
        window.contentView = view
        #expect(view.effectsAdded == 3)
    }
}

@MainActor
@Suite("MusicPlayingOverlay in SwiftUI")
struct MusicSpeakerIntegrationTests {
    private func findSpeaker(in view: NSView) -> MusicSpeakerView? {
        if let found = view as? MusicSpeakerView { return found }
        for subview in view.subviews {
            if let found = findSpeaker(in: subview) { return found }
        }
        return nil
    }

    private func show(_ hosting: NSView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 60, height: 60), styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.collectionBehavior = [.transient, .ignoresCycle, .stationary]
        window.contentView = hosting
        window.orderFrontRegardless()
        return window
    }

    @Test("a playing cover's waves play while the popup's window is not laid out for them")
    func playsWithoutLayouts() async throws {
        let hosting = LayoutCountingHostingView(
            rootView: MusicPlayingOverlay(isPlaying: true).frame(width: 48, height: 48)
                .environment(\.musicPopupIsVisible, true)
        )
        let window = show(hosting)
        defer {
            window.contentView = nil
            window.close()
        }
        try await Task.sleep(for: .milliseconds(500))
        let view = try #require(findSpeaker(in: hosting))
        #expect(view.isPlaying)
        #expect(view.effectsAdded >= 1)
        let layoutsBefore = hosting.layouts
        try await Task.sleep(for: .seconds(1))
        let layouts = hosting.layouts - layoutsBefore
        #expect(layouts < 5)
    }

    @Test("a playing cover in a popup that is not on screen holds the symbol still, and plays when the popup opens")
    func popupGatesTheWaves() async throws {
        func root(visible: Bool, playing: Bool = true) -> AnyView {
            AnyView(
                MusicPlayingOverlay(isPlaying: playing).frame(width: 48, height: 48)
                    .environment(\.musicPopupIsVisible, visible)
            )
        }
        let hosting = NSHostingView(rootView: root(visible: false))
        let window = show(hosting)
        defer {
            window.contentView = nil
            window.close()
        }
        try await Task.sleep(for: .milliseconds(300))
        let view = try #require(findSpeaker(in: hosting))
        #expect(!view.isPlaying)
        #expect(view.effectsAdded == 0)

        hosting.rootView = root(visible: true)
        try await Task.sleep(for: .milliseconds(300))
        #expect(view.isPlaying)
        #expect(view.effectsAdded == 1)

        hosting.rootView = root(visible: false)
        try await Task.sleep(for: .milliseconds(300))
        #expect(!view.isPlaying)

        // The popup open and the song paused: still.
        hosting.rootView = root(visible: true, playing: false)
        try await Task.sleep(for: .milliseconds(300))
        #expect(!view.isPlaying)
    }

    @Test("a paused cover holds the symbol still")
    func pausedHolds() async throws {
        let hosting = NSHostingView(rootView: MusicPlayingOverlay(isPlaying: false).frame(width: 48, height: 48))
        let window = show(hosting)
        defer {
            window.contentView = nil
            window.close()
        }
        try await Task.sleep(for: .milliseconds(300))
        let view = try #require(findSpeaker(in: hosting))
        #expect(!view.isPlaying)
        #expect(view.effectsAdded == 0)
    }
}
