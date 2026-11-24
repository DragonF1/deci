// Deci/Views/Music/MusicFavoriteControls.swift
import Foundation

// The four favorite slots of the player column: two beside Previous and Next in the transport (Shuffle and Loop until
// the listener swaps them) and two on the kicker line (Transitions and Autoplay). Pure, so it is unit tested; the views
// that draw them are `MusicTransportRow` and `MusicKickerToggles`.

/// What a favorite slot can hold. The slot list, the "Show here" submenu and the settings' raw values all come from
/// this enum, so a new case is the only step a new control needs (plus its look and action in the `switch`es below).
nonisolated enum MusicFavoriteControl: String, CaseIterable, Sendable {
    case shuffle
    case loop
    case autoplay
    /// Transitions: Off, Crossfade, Mixing. The raw value stays "crossfade" so a slot saved by an older build still loads.
    case transitions = "crossfade"

    /// The playback toggle the control stands for. Exhaustive, so a new case does not compile until it says which.
    var toggle: MusicPlaybackToggle {
        switch self {
        case .shuffle: .shuffle
        case .loop: .loop
        case .autoplay: .autoplay
        case .transitions: .transitions
        }
    }

    /// The control a playback toggle is. Exhaustive: a new toggle does not compile until it has a control.
    init(_ toggle: MusicPlaybackToggle) {
        switch toggle {
        case .shuffle: self = .shuffle
        case .loop: self = .loop
        case .autoplay: self = .autoplay
        case .transitions: self = .transitions
        }
    }

    /// The one name of the control: the "Show here" submenu and the Playback menu use it.
    var menuTitle: String {
        switch self {
        case .shuffle: "Shuffle"
        case .loop: "Loop"
        case .autoplay: "Autoplay"
        case .transitions: "Transitions"
        }
    }

    /// The name in a slot, for VoiceOver: the control's name, except Loop, which says its mode.
    func title(
        loop: MusicLoopMode = .off, shuffleMode: MusicShuffleMode = .shuffle, transitionMode: MusicTransitionMode = .off
    ) -> String {
        switch self {
        case .loop: loop.label
        case .shuffle: shuffleMode.title
        case .transitions: transitionMode.title
        case .autoplay: menuTitle
        }
    }

    /// The glyph: the Up next header's for the toggle.
    func symbol(
        loop: MusicLoopMode, shuffleMode: MusicShuffleMode = .shuffle, transitionMode: MusicTransitionMode = .off
    ) -> String {
        toggle.symbol(loop: loop, shuffleMode: shuffleMode, transitionMode: transitionMode)
    }

    /// Only the two buttons the row has always had keep their tooltip; nothing added later gets one.
    var hasTooltip: Bool {
        switch self {
        case .shuffle, .loop: true
        case .autoplay, .transitions: false
        }
    }
}

/// Where a favorite slot stands: the two beside Previous and Next in the transport, and the two on the kicker line.
nonisolated enum MusicFavoriteSide: CaseIterable, Sendable {
    /// The transport's slot left of Previous.
    case left
    /// The transport's slot right of Next.
    case right
    /// The kicker line's first toggle (the left one of the two, right-aligned on the "NOW PLAYING" line).
    case topLeft
    /// The kicker line's second toggle (the right-most one).
    case topRight
}

/// The controls in the four slots: left and right in the transport, topLeft and topRight on the kicker line. Never the
/// same control twice.
nonisolated struct MusicFavoriteSlots: Equatable, Sendable {
    static let defaultLeft = MusicFavoriteControl.shuffle
    static let defaultRight = MusicFavoriteControl.loop
    static let defaultTopLeft = MusicFavoriteControl.transitions
    static let defaultTopRight = MusicFavoriteControl.autoplay
    static let `default` = MusicFavoriteSlots(
        left: defaultLeft, right: defaultRight, topLeft: defaultTopLeft, topRight: defaultTopRight
    )

    /// The control a slot holds when nothing else says.
    static func defaultControl(for side: MusicFavoriteSide) -> MusicFavoriteControl {
        switch side {
        case .left: defaultLeft
        case .right: defaultRight
        case .topLeft: defaultTopLeft
        case .topRight: defaultTopRight
        }
    }

    private(set) var left: MusicFavoriteControl
    private(set) var right: MusicFavoriteControl
    private(set) var topLeft: MusicFavoriteControl
    private(set) var topRight: MusicFavoriteControl

    /// Four slots. They are taken in the order left, right, topLeft, topRight; a slot whose control an earlier one holds
    /// takes its own default if that is still free, else the first free control in `allCases` order. So left Loop and
    /// right Loop give right Shuffle, as the two-slot rule always did.
    init(left: MusicFavoriteControl, right: MusicFavoriteControl, topLeft: MusicFavoriteControl, topRight: MusicFavoriteControl) {
        var taken: [MusicFavoriteControl] = []
        func settle(_ control: MusicFavoriteControl, _ side: MusicFavoriteSide) -> MusicFavoriteControl {
            var result = control
            if taken.contains(result) {
                let own = MusicFavoriteSlots.defaultControl(for: side)
                result = !taken.contains(own) ? own : (MusicFavoriteControl.allCases.first { !taken.contains($0) } ?? own)
            }
            taken.append(result)
            return result
        }
        self.left = settle(left, .left)
        self.right = settle(right, .right)
        self.topLeft = settle(topLeft, .topLeft)
        self.topRight = settle(topRight, .topRight)
    }

    /// The transport's two slots; the kicker's two stay on their defaults (or the first free controls when these take them).
    init(left: MusicFavoriteControl, right: MusicFavoriteControl) {
        self.init(left: left, right: right, topLeft: Self.defaultTopLeft, topRight: Self.defaultTopRight)
    }

    /// The slots as settings.json holds them. A missing or unknown raw value (a control a later build dropped) is that
    /// slot's default.
    init(leftRaw: String?, rightRaw: String?, topLeftRaw: String? = nil, topRightRaw: String? = nil) {
        func control(_ raw: String?, _ side: MusicFavoriteSide) -> MusicFavoriteControl {
            raw.flatMap(MusicFavoriteControl.init(rawValue:)) ?? Self.defaultControl(for: side)
        }
        self.init(
            left: control(leftRaw, .left), right: control(rightRaw, .right),
            topLeft: control(topLeftRaw, .topLeft), topRight: control(topRightRaw, .topRight)
        )
    }

    var leftRaw: String { left.rawValue }
    var rightRaw: String { right.rawValue }
    var topLeftRaw: String { topLeft.rawValue }
    var topRightRaw: String { topRight.rawValue }

    subscript(side: MusicFavoriteSide) -> MusicFavoriteControl {
        switch side {
        case .left: left
        case .right: right
        case .topLeft: topLeft
        case .topRight: topRight
        }
    }

    /// Puts `control` in `side`. One that another slot holds trades places with this slot's control, so all four stay
    /// filled and distinct.
    mutating func choose(_ control: MusicFavoriteControl, for side: MusicFavoriteSide) {
        let previous = self[side]
        guard control != previous else { return }
        if let holder = MusicFavoriteSide.allCases.first(where: { self[$0] == control }) {
            set(previous, for: holder)
        }
        set(control, for: side)
    }

    func choosing(_ control: MusicFavoriteControl, for side: MusicFavoriteSide) -> MusicFavoriteSlots {
        var copy = self
        copy.choose(control, for: side)
        return copy
    }

    private mutating func set(_ control: MusicFavoriteControl, for side: MusicFavoriteSide) {
        switch side {
        case .left: left = control
        case .right: right = control
        case .topLeft: topLeft = control
        case .topRight: topRight = control
        }
    }
}

extension AppSettings {
    /// The four favorite slots as the transport row and the kicker toggles take them.
    var musicFavoriteSlots: MusicFavoriteSlots {
        get {
            MusicFavoriteSlots(
                leftRaw: musicFavoriteLeft, rightRaw: musicFavoriteRight,
                topLeftRaw: musicFavoriteTopLeft, topRightRaw: musicFavoriteTopRight
            )
        }
        set {
            musicFavoriteLeft = newValue.leftRaw
            musicFavoriteRight = newValue.rightRaw
            musicFavoriteTopLeft = newValue.topLeftRaw
            musicFavoriteTopRight = newValue.topRightRaw
        }
    }
}

/// The full Playback menu a right click on any slot opens, as data: what is in it, in order, and what is on or
/// checked. The row turns each entry into a native menu item.
nonisolated struct MusicFavoriteMenuModel: Equatable, Sendable {
    enum Entry: Equatable, Sendable {
        /// Autoplay.
        case toggle(MusicFavoriteControl, isOn: Bool)
        /// Shuffle: Off, Shuffle, Flow Shuffle.
        case shuffle(selected: MusicShuffleMode)
        /// Transitions: Off, Crossfade, Mixing.
        case transitions(selected: MusicTransitionMode)
        /// Loop: Off, All, One.
        case loop(selected: MusicLoopMode)
        /// 1 to 12 s, the Settings range.
        case fadeLength(selected: Int, options: [Int])
        case divider
        /// Every control, in enum order, with the one in this slot checked.
        case showHere(selected: MusicFavoriteControl, options: [MusicFavoriteControl])

        var title: String? {
            switch self {
            case .toggle(let control, _): control.menuTitle
            case .shuffle: "Shuffle"
            case .transitions: "Transitions"
            case .loop: "Loop"
            case .fadeLength: "Fade length"
            case .divider: nil
            case .showHere: "Show here"
            }
        }
    }

    /// The choices of the Loop picker, in the order the picker lists them.
    static let loopChoices: [(mode: MusicLoopMode, title: String)] = [(.off, "Off"), (.playlist, "All"), (.song, "One")]

    /// The whole seconds the Fade length submenu offers.
    static let fadeOptions: [Int] = Array(Int(MusicPlaybackPreferences.crossfadeRange.lowerBound)...Int(MusicPlaybackPreferences.crossfadeRange.upperBound))

    /// The Fade length entry's label for a number of seconds.
    static func fadeTitle(_ seconds: Int) -> String { "\(seconds) s" }

    let entries: [Entry]

    /// The choices of the Shuffle picker, in the order the button cycles through them.
    static let shuffleChoices: [(mode: MusicShuffleMode, title: String)] = [(.off, "Off"), (.shuffle, "Shuffle"), (.flow, "Flow Shuffle")]

    /// The choices of the Transitions picker, in the order the button cycles through them.
    static let transitionChoices: [(mode: MusicTransitionMode, title: String)] = [(.off, "Off"), (.crossfade, "Crossfade"), (.mixing, "Mixing")]

    init(
        shuffle: MusicShuffleMode, loop: MusicLoopMode, autoplay: Bool, transitions: MusicTransitionMode, fadeSeconds: Double,
        slotControl: MusicFavoriteControl
    ) {
        // Settings' stepper stays live with Transitions off, so Fade length is never greyed out here either.
        let seconds = Int(MusicPlaybackPreferences.clampedCrossfade(fadeSeconds).rounded())
        // One entry per playback toggle, in toggle order, so a new toggle cannot be left out of the menu.
        let toggles: [Entry] = MusicPlaybackToggle.allCases.map { toggle in
            switch toggle {
            case .shuffle: .shuffle(selected: shuffle)
            case .loop: .loop(selected: loop)
            case .autoplay: .toggle(.autoplay, isOn: autoplay)
            case .transitions: .transitions(selected: transitions)
            }
        }
        entries = toggles + [
            .fadeLength(selected: seconds, options: Self.fadeOptions),
            .divider,
            .showHere(selected: slotControl, options: MusicFavoriteControl.allCases),
        ]
    }
}
