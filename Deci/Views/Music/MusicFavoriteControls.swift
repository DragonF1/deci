// Deci/Views/Music/MusicFavoriteControls.swift
import Foundation

// The two slots beside Previous and Next in the player column's transport. Shuffle and Loop are what they hold until
// the listener swaps them. Pure, so it is unit tested; the row that draws it is `MusicTransportRow`.

/// What a favorite slot can hold. The slot list, the "Show here" submenu and the settings' raw values all come from
/// this enum, so a new case is the only step a new control needs (plus its look and action in the `switch`es below).
nonisolated enum MusicFavoriteControl: String, CaseIterable, Sendable {
    case shuffle
    case loop
    case autoplay
    case crossfade
    case like

    /// What a control is: one of the playback toggles Up next has too, or Like. Exhaustive, so a new case does not
    /// compile until it says which.
    enum Kind: Equatable, Sendable {
        case toggle(MusicPlaybackToggle)
        case like

        var toggle: MusicPlaybackToggle? {
            switch self {
            case .toggle(let toggle): toggle
            case .like: nil
            }
        }
    }

    var kind: Kind {
        switch self {
        case .shuffle: .toggle(.shuffle)
        case .loop: .toggle(.loop)
        case .autoplay: .toggle(.autoplay)
        case .crossfade: .toggle(.crossfade)
        case .like: .like
        }
    }

    /// The control a playback toggle is. Exhaustive: a new toggle does not compile until it has a control.
    init(_ toggle: MusicPlaybackToggle) {
        switch toggle {
        case .shuffle: self = .shuffle
        case .loop: self = .loop
        case .autoplay: self = .autoplay
        case .crossfade: self = .crossfade
        }
    }

    /// The one name of the control: the "Show here" submenu and the Playback menu use it.
    var menuTitle: String {
        switch self {
        case .shuffle: "Shuffle"
        case .loop: "Loop"
        case .autoplay: "Autoplay"
        case .crossfade: "Crossfade"
        case .like: "Like"
        }
    }

    /// The name in a slot, for VoiceOver: the control's name, except Loop, which says its mode.
    func title(loop: MusicLoopMode = .off) -> String {
        switch self {
        case .loop: loop.label
        case .shuffle, .autoplay, .crossfade, .like: menuTitle
        }
    }

    /// The glyph: the Up next header's for the four toggles, the strip's thumbs up (filled once liked) for Like.
    func symbol(loop: MusicLoopMode, isLiked: Bool) -> String {
        switch kind {
        case .toggle(let toggle): toggle.symbol(loop: loop)
        case .like: MusicRateButtonLook(kind: .like, status: isLiked ? .like : nil).symbolName
        }
    }

    /// Only the two buttons the row has always had keep their tooltip; nothing added later gets one.
    var hasTooltip: Bool {
        switch self {
        case .shuffle, .loop: true
        case .autoplay, .crossfade, .like: false
        }
    }
}

/// Where a favorite slot stands.
nonisolated enum MusicFavoriteSide: CaseIterable, Sendable {
    case left
    case right

    var opposite: MusicFavoriteSide {
        self == .left ? .right : .left
    }
}

/// The controls in the left and right slot. Never the same control twice.
nonisolated struct MusicFavoriteSlots: Equatable, Sendable {
    static let defaultLeft = MusicFavoriteControl.shuffle
    static let defaultRight = MusicFavoriteControl.loop
    static let `default` = MusicFavoriteSlots(left: defaultLeft, right: defaultRight)

    private(set) var left: MusicFavoriteControl
    private(set) var right: MusicFavoriteControl

    /// Two slots; when both name one control the right slot gives it up for a control the left one does not hold.
    init(left: MusicFavoriteControl, right: MusicFavoriteControl) {
        self.left = left
        if left == right {
            self.right = left == Self.defaultRight ? Self.defaultLeft : Self.defaultRight
        } else {
            self.right = right
        }
    }

    /// The slots as settings.json holds them. A missing or unknown raw value (a control a later build dropped) is that
    /// slot's default.
    init(leftRaw: String?, rightRaw: String?) {
        self.init(
            left: leftRaw.flatMap(MusicFavoriteControl.init(rawValue:)) ?? Self.defaultLeft,
            right: rightRaw.flatMap(MusicFavoriteControl.init(rawValue:)) ?? Self.defaultRight
        )
    }

    var leftRaw: String { left.rawValue }
    var rightRaw: String { right.rawValue }

    subscript(side: MusicFavoriteSide) -> MusicFavoriteControl {
        side == .left ? left : right
    }

    /// Puts `control` in `side`. One that the other slot holds trades places with this slot's control, so both stay filled
    /// and distinct.
    mutating func choose(_ control: MusicFavoriteControl, for side: MusicFavoriteSide) {
        let previous = self[side]
        guard control != previous else { return }
        if control == self[side.opposite] {
            set(previous, for: side.opposite)
        }
        set(control, for: side)
    }

    func choosing(_ control: MusicFavoriteControl, for side: MusicFavoriteSide) -> MusicFavoriteSlots {
        var copy = self
        copy.choose(control, for: side)
        return copy
    }

    private mutating func set(_ control: MusicFavoriteControl, for side: MusicFavoriteSide) {
        if side == .left { left = control } else { right = control }
    }
}

extension AppSettings {
    /// The two favorite slots as the transport row takes them.
    var musicFavoriteSlots: MusicFavoriteSlots {
        get { MusicFavoriteSlots(leftRaw: musicFavoriteLeft, rightRaw: musicFavoriteRight) }
        set {
            musicFavoriteLeft = newValue.leftRaw
            musicFavoriteRight = newValue.rightRaw
        }
    }
}

/// The full Playback menu a right click on either slot opens, as data: what is in it, in order, and what is on or
/// checked. The row turns each entry into a native menu item.
nonisolated struct MusicFavoriteMenuModel: Equatable, Sendable {
    enum Entry: Equatable, Sendable {
        /// Shuffle, Autoplay or Crossfade.
        case toggle(MusicFavoriteControl, isOn: Bool)
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

    init(shuffle: Bool, loop: MusicLoopMode, autoplay: Bool, crossfade: Bool, fadeSeconds: Double, slotControl: MusicFavoriteControl) {
        // Settings' stepper stays live with Crossfade off, so Fade length is never greyed out here either.
        let seconds = Int(MusicPlaybackPreferences.clampedCrossfade(fadeSeconds).rounded())
        // One entry per playback toggle, in toggle order, so a new toggle cannot be left out of the menu.
        let toggles: [Entry] = MusicPlaybackToggle.allCases.map { toggle in
            switch toggle {
            case .shuffle: .toggle(.shuffle, isOn: shuffle)
            case .loop: .loop(selected: loop)
            case .autoplay: .toggle(.autoplay, isOn: autoplay)
            case .crossfade: .toggle(.crossfade, isOn: crossfade)
            }
        }
        entries = toggles + [
            .fadeLength(selected: seconds, options: Self.fadeOptions),
            .divider,
            .showHere(selected: slotControl, options: MusicFavoriteControl.allCases),
        ]
    }
}
