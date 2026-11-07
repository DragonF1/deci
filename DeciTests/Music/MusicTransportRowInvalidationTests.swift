// DeciTests/Music/MusicTransportRowInvalidationTests.swift
// A right click opens the row's menu, and SwiftUI rebuilds an open menu (closing its submenus) whenever the row's body
// runs. So the row must run its body only when something the menu shows changes, never on a playback tick.

import AppKit
import Observation
import SwiftUI
import Testing
@testable import Deci

@MainActor
@Observable
private final class TickModel {
    /// Ticks several times a second in the real column: the playhead.
    var position = 0.0
    var shuffle = false
    @ObservationIgnored var bodies = 0
    @ObservationIgnored var menus = 0
}

/// Stands in for the column's body: it reads the playhead, as the times row used to, and builds the row with fresh
/// closures every time it runs.
private struct TickHost: View {
    let model: TickModel

    var body: some View {
        let _ = model.position
        let row = MusicTransportRow(
            slots: .default, snapshot: MusicFavoriteSnapshot(shuffle: model.shuffle), canGoNext: true, state: .playing,
            actions: MusicTransportActions(previous: {}, next: {}, perform: { _ in }, setLoop: { _ in }, setFadeSeconds: { _ in }, show: { _, _ in }),
            debugOnBody: { model.bodies += 1 }, debugOnMenuBuild: { model.menus += 1 }
        )
        row.equatable()
    }
}

@MainActor
@Suite("Music transport row invalidation")
struct MusicTransportRowInvalidationTests {
    private func settle(_ host: NSHostingView<some View>) async {
        for _ in 0..<3 {
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            try? await Task.sleep(for: .milliseconds(30))
        }
    }

    @Test("playback ticks never re-run the row or rebuild its menu; a real toggle does, once")
    func ticksDoNotRebuildTheMenu() async {
        let model = TickModel()
        let host = NSHostingView(rootView: TickHost(model: model))
        host.frame = NSRect(x: 0, y: 0, width: 200, height: 60)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = host  // never ordered front
        await settle(host)
        // The first update after the host is attached may still be settling (appearance, environment): let it finish.
        model.position = 0.1
        await settle(host)
        await settle(host)

        let bodies = model.bodies
        let menus = model.menus
        #expect(bodies > 0)

        for step in 1...20 {
            model.position = Double(step) * 0.5
            await settle(host)
        }
        #expect(model.bodies == bodies)
        #expect(model.menus == menus)

        model.shuffle = true
        await settle(host)
        #expect(model.bodies == bodies + 1)
    }

    @Test("rows with the same inputs are equal whatever their closures do, and differ when the menu would")
    func equality() {
        func row(_ snapshot: MusicFavoriteSnapshot, slots: MusicFavoriteSlots = .default, next: Bool = true, state: MusicPlayerColumnState = .playing, onPrevious: @escaping () -> Void = {}) -> MusicTransportRow {
            MusicTransportRow(slots: slots, snapshot: snapshot, canGoNext: next, state: state, actions: MusicTransportActions(previous: onPrevious))
        }
        let base = row(MusicFavoriteSnapshot())
        #expect(base == row(MusicFavoriteSnapshot(), onPrevious: { print("other") }))
        #expect(base != row(MusicFavoriteSnapshot(shuffle: true)))
        #expect(base != row(MusicFavoriteSnapshot(fadeSeconds: 3)))
        #expect(base != row(MusicFavoriteSnapshot(), slots: MusicFavoriteSlots(left: .like, right: .loop)))
        #expect(base != row(MusicFavoriteSnapshot(), next: false))
        #expect(base != row(MusicFavoriteSnapshot(), state: .paused))
    }
}
