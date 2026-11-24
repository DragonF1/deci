// Deci/Views/Music/MusicTransportRow.swift
import SwiftUI

/// What the favorite slots show of the player: the state of each control a slot can hold.
struct MusicFavoriteSnapshot: Equatable {
    /// What the shuffle button is set to.
    var shuffle = MusicShuffleMode.off
    var loop = MusicLoopMode.off
    var autoplay = true
    var transitions = MusicTransitionMode.off
    /// The crossfade length in seconds, as Settings has it.
    var fadeSeconds = MusicPlaybackPreferences.defaultCrossfadeSeconds

    var shuffleMode: MusicShuffleMode { shuffle }

    func isOn(_ control: MusicFavoriteControl) -> Bool {
        control.toggle.isOn(shuffle: shuffle, loop: loop, autoplay: autoplay, transitions: transitions)
    }
}

/// What the transport row does. A click on a slot is `perform`; the right click menu uses the rest.
struct MusicTransportActions {
    var previous: () -> Void = {}
    var next: () -> Void = {}
    var togglePlayback: () -> Void = {}
    /// The slot's own click: toggles Autoplay, cycles Shuffle, Loop and Transitions.
    var perform: (MusicFavoriteControl) -> Void = { _ in }
    var setLoop: (MusicLoopMode) -> Void = { _ in }
    var setShuffleMode: (MusicShuffleMode) -> Void = { _ in }
    var setTransitionMode: (MusicTransitionMode) -> Void = { _ in }
    var setFadeSeconds: (Int) -> Void = { _ in }
    var show: (MusicFavoriteControl, MusicFavoriteSide) -> Void = { _, _ in }
    /// Fade length and Show here need Settings; a row without it (a preview) leaves them out of the menu.
    var hasSettings = true

    /// No-op actions for a row with no Settings behind it (a render): its menu leaves out Fade length and Show here.
    static var none: MusicTransportActions {
        var actions = MusicTransportActions()
        actions.hasSettings = false
        return actions
    }
}

/// The player column's transport: a favorite slot, Previous, play and pause, Next and a favorite slot. Five
/// boxes in a row with the spare width shared by the four Spacers (`MusicTransportMetrics`); a slot holds the same
/// 13 pt box whatever it shows, so swapping it moves nothing. A left click does what the control does; a right click
/// opens the Playback menu (`MusicFavoriteMenuModel`).
///
/// It is Equatable on what it draws and what its menu shows, and the closures are left out of `==`: used with
/// `.equatable()`, its body runs only when one of those changes. That matters because an open context menu is rebuilt,
/// with its submenus closed, whenever the body that holds it runs; a tick of the playhead must not do that.
struct MusicTransportRow: View, Equatable {
    let slots: MusicFavoriteSlots
    let snapshot: MusicFavoriteSnapshot
    let canGoNext: Bool
    let state: MusicPlayerColumnState
    let actions: MusicTransportActions

    static func == (lhs: MusicTransportRow, rhs: MusicTransportRow) -> Bool {
        lhs.slots == rhs.slots && lhs.snapshot == rhs.snapshot && lhs.canGoNext == rhs.canGoNext && lhs.state == rhs.state
    }

    #if DEBUG
    /// Test seams, told when this row's body runs and when its menu is built (not part of `==`).
    var debugOnBody: () -> Void = {}
    var debugOnMenuBuild: () -> Void = {}
    #endif

    @Environment(\.musicAccent) private var accent

    var body: some View {
        #if DEBUG
        let _ = debugOnBody()
        #endif
        HStack(spacing: 0) {
            slot(.left)
            Spacer(minLength: 0)
            MusicColumnGlyphButton(
                title: "Previous", systemImage: "backward.end.fill", fontSize: 14,
                box: MusicTransportMetrics.box(.previous), color: Color.white.opacity(0.90)
            ) { actions.previous() }
            Spacer(minLength: 0)
            playPause
            Spacer(minLength: 0)
            MusicColumnGlyphButton(
                title: "Next", systemImage: "forward.end.fill", fontSize: 14, box: MusicTransportMetrics.box(.next),
                color: Color.white.opacity(canGoNext ? 0.90 : 0.30), isDisabled: !canGoNext
            ) { actions.next() }
            Spacer(minLength: 0)
            slot(.right)
        }
        .frame(width: MusicPopupMetrics.playerColumnContentWidth, height: MusicTransportMetrics.height)
    }

    private var playPause: some View {
        let isPlaying = state == .playing
        return Button {
            actions.togglePlayback()
        } label: {
            ZStack {
                Circle().fill(Color.white.opacity(0.95))
                if state == .loading {
                    MusicSpinner(
                        size: 16, lineWidth: 1.6,
                        color: MusicStyle.Palette.popupBackground,
                        track: MusicStyle.Palette.popupBackground.opacity(0.18)
                    )
                } else {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(MusicStyle.Palette.popupBackground)
                }
            }
            .frame(width: MusicTransportMetrics.box(.playPause), height: MusicTransportMetrics.height)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(state == .loading)
        .accessibilityLabel(state == .loading ? "Loading" : (isPlaying ? "Pause" : "Play"))
        .help(isPlaying ? "Pause" : "Play")
    }

    private func slot(_ side: MusicFavoriteSide) -> some View {
        #if DEBUG
        let onMenuBuild = debugOnMenuBuild
        #else
        let onMenuBuild: () -> Void = {}
        #endif
        return MusicFavoriteSlotButton(
            side: side, slots: slots, snapshot: snapshot, actions: actions, fontSize: 12,
            box: MusicTransportMetrics.box(side == .left ? .shuffle : .loop), onMenuBuild: onMenuBuild
        )
    }
}

/// One favorite slot: the glyph button of the control the slot holds, and the Playback menu (`MusicFavoriteMenuModel`) a
/// right click on it opens. The transport's two slots and the kicker line's two toggles are this one view, so they look,
/// act and open the same menu; only the glyph size, box and reach differ. A left click does what the control does.
/// It has no equality of its own: the Equatable view that holds it (`MusicTransportRow`, `MusicKickerToggles`) decides
/// when its body runs, which is what keeps an open menu from being rebuilt.
struct MusicFavoriteSlotButton: View {
    let side: MusicFavoriteSide
    let slots: MusicFavoriteSlots
    let snapshot: MusicFavoriteSnapshot
    let actions: MusicTransportActions
    let fontSize: CGFloat
    /// The width the glyph is drawn in; nil lets it take its own.
    var box: CGFloat?
    var height: CGFloat = MusicTransportMetrics.height
    var reachX: CGFloat = 6
    var reachY: CGFloat = 0
    /// Test seam, told each time the menu is built.
    var onMenuBuild: () -> Void = {}

    @Environment(\.musicAccent) private var accent

    var body: some View {
        let control = slots[side]
        let isOn = snapshot.isOn(control)
        let rest = MusicTransportMetrics.restingGlyphOpacity
        return MusicColumnGlyphButton(
            title: control.title(loop: snapshot.loop, shuffleMode: snapshot.shuffleMode, transitionMode: snapshot.transitions),
            systemImage: control.symbol(
                loop: snapshot.loop, shuffleMode: snapshot.shuffleMode, transitionMode: snapshot.transitions
            ),
            fontSize: fontSize,
            box: box,
            color: isOn ? accent.solid : Color.white.opacity(rest),
            isSelected: isOn,
            showsHelp: control.hasTooltip,
            height: height,
            reachX: reachX,
            reachY: reachY
        ) { actions.perform(control) }
        .contextMenu { menu }
    }

    // MARK: - Menu

    /// An entry that needs Settings is hidden when there is none; so is the divider that only led to them.
    private func isShown(_ entry: MusicFavoriteMenuModel.Entry) -> Bool {
        guard !actions.hasSettings else { return true }
        switch entry {
        case .fadeLength, .showHere, .divider: return false
        case .toggle, .loop, .shuffle, .transitions: return true
        }
    }

    @ViewBuilder
    private var menu: some View {
        let _ = onMenuBuild()
        let model = MusicFavoriteMenuModel(
            shuffle: snapshot.shuffle, loop: snapshot.loop, autoplay: snapshot.autoplay, transitions: snapshot.transitions,
            fadeSeconds: snapshot.fadeSeconds, slotControl: slots[side]
        )
        ForEach(Array(model.entries.filter(isShown).enumerated()), id: \.offset) { _, entry in
            switch entry {
            case .toggle(let control, let isOn):
                Toggle(control.menuTitle, isOn: Binding(get: { isOn }, set: { _ in actions.perform(control) }))
            case .shuffle(let selected):
                Picker("Shuffle", selection: Binding(get: { selected }, set: { actions.setShuffleMode($0) })) {
                    ForEach(Array(MusicFavoriteMenuModel.shuffleChoices.enumerated()), id: \.offset) { _, choice in
                        Text(choice.title).tag(choice.mode)
                    }
                }
            case .transitions(let selected):
                Picker("Transitions", selection: Binding(get: { selected }, set: { actions.setTransitionMode($0) })) {
                    ForEach(Array(MusicFavoriteMenuModel.transitionChoices.enumerated()), id: \.offset) { _, choice in
                        Text(choice.title).tag(choice.mode)
                    }
                }
            case .loop(let selected):
                Picker("Loop", selection: Binding(get: { selected }, set: { actions.setLoop($0) })) {
                    ForEach(Array(MusicFavoriteMenuModel.loopChoices.enumerated()), id: \.offset) { _, choice in
                        Text(choice.title).tag(choice.mode)
                    }
                }
            case .fadeLength(let selected, let options):
                Menu("Fade length") {
                    Picker("Fade length", selection: Binding(get: { selected }, set: { actions.setFadeSeconds($0) })) {
                        ForEach(options, id: \.self) { Text(MusicFavoriteMenuModel.fadeTitle($0)).tag($0) }
                    }
                    .pickerStyle(.inline)
                }
            case .divider:
                Divider()
            case .showHere(let selected, let options):
                Menu("Show here") {
                    Picker("Show here", selection: Binding(get: { selected }, set: { actions.show($0, side) })) {
                        ForEach(options, id: \.self) { Text($0.menuTitle).tag($0) }
                    }
                    .pickerStyle(.inline)
                }
            }
        }
    }
}
