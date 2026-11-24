// Deci/Views/Music/MusicKickerToggles.swift
import SwiftUI

/// The two favorite toggles at the right end of the player column's kicker line: small glyphs (`MusicKickerToggleMetrics`)
/// that are slots of the same kind as the transport's (`MusicFavoriteSlotButton`), Transitions and Autoplay until the
/// listener changes them. A click toggles, a right click opens the Playback menu whose "Show here" picks what the slot
/// holds. The glyphs sit 8 pt apart with the right one's edge on the row's trailing edge.
///
/// Like `MusicTransportRow` it is Equatable on what it shows, never the closures: used with `.equatable()`, its body
/// (and the menu an open right click holds) runs only when a slot, the snapshot or the state changes. It fades and
/// switches off with the transport.
struct MusicKickerToggles: View, Equatable {
    let slots: MusicFavoriteSlots
    let snapshot: MusicFavoriteSnapshot
    let state: MusicPlayerColumnState
    let actions: MusicTransportActions

    static func == (lhs: MusicKickerToggles, rhs: MusicKickerToggles) -> Bool {
        lhs.slots == rhs.slots && lhs.snapshot == rhs.snapshot && lhs.state == rhs.state
    }

    #if DEBUG
    /// Test seams, told when this view's body runs and when a menu is built (not part of `==`).
    var debugOnBody: () -> Void = {}
    var debugOnMenuBuild: () -> Void = {}
    #endif

    var body: some View {
        #if DEBUG
        let _ = debugOnBody()
        let onMenuBuild = debugOnMenuBuild
        #else
        let onMenuBuild: () -> Void = {}
        #endif
        HStack(spacing: MusicKickerToggleMetrics.gap) {
            toggle(.topLeft, onMenuBuild)
            toggle(.topRight, onMenuBuild)
        }
        .fixedSize()
        .frame(height: MusicKickerToggleMetrics.lineHeight)
        .opacity(state.controlsOpacity)
        .disabled(!state.controlsAreEnabled)
    }

    private func toggle(_ side: MusicFavoriteSide, _ onMenuBuild: @escaping () -> Void) -> some View {
        MusicFavoriteSlotButton(
            side: side, slots: slots, snapshot: snapshot, actions: actions,
            fontSize: MusicKickerToggleMetrics.glyphSize, box: nil, height: MusicKickerToggleMetrics.lineHeight,
            reachX: MusicKickerToggleMetrics.reachX, reachY: MusicKickerToggleMetrics.reachY, onMenuBuild: onMenuBuild
        )
    }
}
