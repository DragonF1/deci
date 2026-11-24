// DeciTests/Music/MusicFavoriteControlsTests.swift
// The two favorite slots beside Previous and Next: the control list, the slots, their persistence and the right click menu.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("Music favorite controls")
struct MusicFavoriteControlsTests {
    private func decode(_ json: String) throws -> AppSettings {
        try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
    }

    // MARK: - The enum

    @Test("the list is shuffle, loop, autoplay, transitions (raw value crossfade), in that order")
    func order() {
        #expect(MusicFavoriteControl.allCases == [.shuffle, .loop, .autoplay, .transitions])
    }

    @Test("every control survives its raw value")
    func rawRoundTrip() {
        for control in MusicFavoriteControl.allCases {
            #expect(MusicFavoriteControl(rawValue: control.rawValue) == control)
        }
        #expect(MusicFavoriteControl.allCases.map(\.rawValue) == ["shuffle", "loop", "autoplay", "crossfade"])
    }

    @Test("an unknown raw value is no control")
    func unknownRaw() {
        #expect(MusicFavoriteControl(rawValue: "teleport") == nil)
        #expect(MusicFavoriteControl(rawValue: "") == nil)
        #expect(MusicFavoriteControl(rawValue: "Shuffle") == nil)
    }

    @Test("the four controls take the Up next header's glyphs")
    func glyphs() {
        #expect(MusicFavoriteControl.shuffle.symbol(loop: .off) == "shuffle")
        #expect(MusicFavoriteControl.loop.symbol(loop: .off) == "repeat")
        #expect(MusicFavoriteControl.loop.symbol(loop: .song) == "repeat.1")
        #expect(MusicFavoriteControl.autoplay.symbol(loop: .off) == "infinity")
        #expect(MusicFavoriteControl.transitions.symbol(loop: .off) == MusicTransitionMode.crossfadeSymbol)
    }

    @Test("only the two buttons the row always had keep a tooltip")
    func tooltips() {
        #expect(MusicFavoriteControl.allCases.filter(\.hasTooltip) == [.shuffle, .loop])
    }

    // MARK: - The slots

    @Test("the default slots are shuffle, loop, transitions and autoplay")
    func defaults() {
        #expect(MusicFavoriteSlots.default.left == .shuffle)
        #expect(MusicFavoriteSlots.default.right == .loop)
        #expect(MusicFavoriteSlots.default.topLeft == .transitions)
        #expect(MusicFavoriteSlots.default.topRight == .autoplay)
        #expect(MusicFavoriteSlots(left: .shuffle, right: .loop) == .default)
        #expect(AppSettings().musicFavoriteSlots == .default)
        #expect(AppSettings().musicFavoriteLeft == "shuffle")
        #expect(AppSettings().musicFavoriteRight == "loop")
        #expect(AppSettings().musicFavoriteTopLeft == "crossfade")
        #expect(AppSettings().musicFavoriteTopRight == "autoplay")
    }

    @Test("an unknown or missing raw value is that slot's default")
    func fallback() {
        #expect(MusicFavoriteSlots(leftRaw: "teleport", rightRaw: "autoplay") == MusicFavoriteSlots(left: .shuffle, right: .autoplay))
        #expect(MusicFavoriteSlots(leftRaw: "crossfade", rightRaw: "teleport") == MusicFavoriteSlots(left: .transitions, right: .loop, topLeft: .shuffle, topRight: .autoplay))
        #expect(MusicFavoriteSlots(leftRaw: nil, rightRaw: nil) == .default)
        #expect(MusicFavoriteSlots(leftRaw: "", rightRaw: "", topLeftRaw: "", topRightRaw: "") == .default)
        #expect(MusicFavoriteSlots(leftRaw: nil, rightRaw: nil, topLeftRaw: "teleport", topRightRaw: "autoplay")
            == MusicFavoriteSlots(left: .shuffle, right: .loop, topLeft: .transitions, topRight: .autoplay))
        #expect(MusicFavoriteSlots(leftRaw: nil, rightRaw: nil, topLeftRaw: "autoplay", topRightRaw: nil)
            == MusicFavoriteSlots(left: .shuffle, right: .loop, topLeft: .autoplay, topRight: .transitions))
    }

    @Test("slots that name one control never end up equal")
    func duplicatesAreRepaired() {
        let same = MusicFavoriteSlots(left: .autoplay, right: .autoplay)
        #expect(same.left == .autoplay)
        #expect(same.right != .autoplay)
        let loops = MusicFavoriteSlots(left: .loop, right: .loop)
        #expect(loops.left == .loop)
        #expect(loops.right == .shuffle)
        #expect(MusicFavoriteSlots(leftRaw: "autoplay", rightRaw: "autoplay").left != MusicFavoriteSlots(leftRaw: "autoplay", rightRaw: "autoplay").right)
    }

    @Test("a slot that repeats an earlier control takes its own default if free, else the first free control")
    func normalisationRule() {
        // Top slots repeat the transport's: each falls to its own default.
        let own = MusicFavoriteSlots(left: .shuffle, right: .shuffle, topLeft: .shuffle, topRight: .shuffle)
        #expect(own == .default)
        // The own default is taken too: the first free in allCases order (shuffle, loop, autoplay, transitions).
        let taken = MusicFavoriteSlots(left: .transitions, right: .autoplay, topLeft: .transitions, topRight: .autoplay)
        #expect(taken == MusicFavoriteSlots(left: .transitions, right: .autoplay, topLeft: .shuffle, topRight: .loop))
        let all = MusicFavoriteSlots(left: .loop, right: .loop, topLeft: .loop, topRight: .loop)
        #expect(all == MusicFavoriteSlots(left: .loop, right: .shuffle, topLeft: .transitions, topRight: .autoplay))
        // Old transport choice of Transitions pushes the top left to the next free control.
        #expect(MusicFavoriteSlots(left: .transitions, right: .loop) == MusicFavoriteSlots(left: .transitions, right: .loop, topLeft: .shuffle, topRight: .autoplay))
        #expect(MusicFavoriteSlots(left: .autoplay, right: .loop).topRight == .shuffle)
    }

    @Test("every combination of four controls comes out filled and distinct")
    func normalisationExhaustive() {
        let all = MusicFavoriteControl.allCases
        for a in all { for b in all { for c in all { for d in all {
            let slots = MusicFavoriteSlots(left: a, right: b, topLeft: c, topRight: d)
            let held = MusicFavoriteSide.allCases.map { slots[$0] }
            #expect(Set(held).count == 4)
            #expect(slots.left == a)
            if a != b { #expect(slots.right == b) }
        } } } }
    }

    @Test("choosing a control puts it in the slot")
    func choose() {
        var slots = MusicFavoriteSlots.default
        slots.choose(.autoplay, for: .left)
        #expect(slots == MusicFavoriteSlots(left: .autoplay, right: .loop, topLeft: .transitions, topRight: .shuffle))
        slots.choose(.transitions, for: .topRight)
        #expect(slots == MusicFavoriteSlots(left: .autoplay, right: .loop, topLeft: .shuffle, topRight: .transitions))
    }

    @Test("choosing the control a slot already holds changes nothing")
    func chooseSame() {
        for side in MusicFavoriteSide.allCases {
            #expect(MusicFavoriteSlots.default.choosing(MusicFavoriteSlots.default[side], for: side) == .default)
        }
    }

    @Test("choosing another slot's control swaps the two slots")
    func chooseSwaps() {
        #expect(MusicFavoriteSlots.default.choosing(.loop, for: .left) == MusicFavoriteSlots(left: .loop, right: .shuffle, topLeft: .transitions, topRight: .autoplay))
        #expect(MusicFavoriteSlots.default.choosing(.autoplay, for: .topLeft) == MusicFavoriteSlots(left: .shuffle, right: .loop, topLeft: .autoplay, topRight: .transitions))
        #expect(MusicFavoriteSlots.default.choosing(.shuffle, for: .topRight) == MusicFavoriteSlots(left: .autoplay, right: .loop, topLeft: .transitions, topRight: .shuffle))
        #expect(MusicFavoriteSlots.default.choosing(.transitions, for: .right) == MusicFavoriteSlots(left: .shuffle, right: .transitions, topLeft: .loop, topRight: .autoplay))
    }

    @Test("every choice in every slot leaves four distinct controls")
    func neverDuplicated() {
        let all = MusicFavoriteControl.allCases
        // Every start the normaliser can produce: each ordered pick of four distinct controls.
        var starts: [MusicFavoriteSlots] = []
        for a in all { for b in all { for c in all { for d in all {
            let slots = MusicFavoriteSlots(left: a, right: b, topLeft: c, topRight: d)
            if !starts.contains(slots) { starts.append(slots) }
        } } } }
        #expect(starts.count == 24)
        for start in starts {
            for side in MusicFavoriteSide.allCases {
                for pick in all {
                    let slots = start.choosing(pick, for: side)
                    #expect(slots[side] == pick)
                    #expect(Set(MusicFavoriteSide.allCases.map { slots[$0] }).count == 4)
                    // Only the chosen slot and the one that held `pick` change.
                    for other in MusicFavoriteSide.allCases where other != side && start[other] != pick {
                        #expect(slots[other] == start[other])
                    }
                }
            }
        }
    }

    @Test("the slots survive an encode and decode of AppSettings")
    func roundTrip() throws {
        var settings = AppSettings()
        let slots = MusicFavoriteSlots(left: .autoplay, right: .transitions, topLeft: .loop, topRight: .shuffle)
        settings.musicFavoriteSlots = slots
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings)
        #expect(decoded.musicFavoriteSlots == slots)
        #expect(decoded.musicFavoriteLeft == "autoplay")
        #expect(decoded.musicFavoriteRight == "crossfade")
        #expect(decoded.musicFavoriteTopLeft == "loop")
        #expect(decoded.musicFavoriteTopRight == "shuffle")
    }

    @Test("the slots are stored as raw strings under their four keys")
    func storedKeys() throws {
        var settings = AppSettings()
        settings.musicFavoriteSlots = MusicFavoriteSlots(left: .transitions, right: .shuffle, topLeft: .autoplay, topRight: .loop)
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any]
        #expect(object?["musicFavoriteLeft"] as? String == "crossfade")
        #expect(object?["musicFavoriteRight"] as? String == "shuffle")
        #expect(object?["musicFavoriteTopLeft"] as? String == "autoplay")
        #expect(object?["musicFavoriteTopRight"] as? String == "loop")
    }

    @Test("a file from before the slots existed decodes to the defaults")
    func oldFile() throws {
        let settings = try decode(#"{"launchAtLogin": true, "musicShuffle": true}"#)
        #expect(settings.launchAtLogin)
        #expect(settings.musicFavoriteSlots == .default)
    }

    @Test("a file with only the two old slot keys gives the top slots their defaults, then normalises")
    func oldTwoKeyFile() throws {
        let plain = try decode(#"{"musicFavoriteLeft": "autoplay", "musicFavoriteRight": "loop", "launchAtLogin": true}"#)
        #expect(plain.launchAtLogin)
        #expect(plain.musicFavoriteTopLeft == "crossfade")
        #expect(plain.musicFavoriteTopRight == "autoplay")
        #expect(plain.musicFavoriteSlots == MusicFavoriteSlots(left: .autoplay, right: .loop, topLeft: .transitions, topRight: .shuffle))
        let clash = try decode(#"{"musicFavoriteLeft": "crossfade", "musicFavoriteRight": "loop"}"#)
        #expect(clash.musicFavoriteSlots == MusicFavoriteSlots(left: .transitions, right: .loop, topLeft: .shuffle, topRight: .autoplay))
    }

    @Test("a file that saved Like in a slot still loads: that slot takes its default and all four stay distinct")
    func savedLikeFallsBack() throws {
        let right = try decode(#"{"musicFavoriteRight": "like", "launchAtLogin": true}"#)
        #expect(right.launchAtLogin)
        #expect(right.musicFavoriteSlots == .default)
        let top = try decode(#"{"musicFavoriteTopRight": "like"}"#)
        #expect(top.musicFavoriteSlots == .default)
        let topLeft = try decode(#"{"musicFavoriteLeft": "loop", "musicFavoriteTopLeft": "like"}"#)
        #expect(topLeft.musicFavoriteTopLeft == "like")
        #expect(topLeft.musicFavoriteSlots == MusicFavoriteSlots(left: .loop, right: .shuffle, topLeft: .transitions, topRight: .autoplay))
        for slots in [right, top, topLeft].map(\.musicFavoriteSlots) {
            #expect(Set(MusicFavoriteSide.allCases.map { slots[$0] }).count == 4)
        }
        #expect(MusicFavoriteSlots(leftRaw: "like", rightRaw: "like", topLeftRaw: "like", topRightRaw: "like") == .default)
    }

    @Test("a bad top slot value falls back and costs no other setting")
    func badTopValue() throws {
        let settings = try decode(#"{"musicFavoriteTopLeft": 3, "musicFavoriteTopRight": "teleport", "musicAutoplay": false}"#)
        #expect(settings.musicFavoriteTopLeft == "crossfade")
        // An unknown string is kept as the file says (like the old two keys); the slot reads as its default.
        #expect(settings.musicFavoriteTopRight == "teleport")
        #expect(settings.musicFavoriteSlots == .default)
        #expect(settings.musicAutoplay == false)
    }

    @Test("an unknown or mistyped value falls back and costs no other setting")
    func unknownValue() throws {
        let settings = try decode(#"{"musicFavoriteLeft": "teleport", "musicFavoriteRight": 7, "launchAtLogin": true, "musicAutoplay": false}"#)
        #expect(settings.musicFavoriteSlots == .default)
        #expect(settings.launchAtLogin)
        #expect(settings.musicAutoplay == false)
    }

    @Test("the favorite slots leave the playback preferences alone")
    func preferencesUntouched() {
        var settings = AppSettings()
        let before = settings.musicPlayback
        settings.musicFavoriteSlots = MusicFavoriteSlots(left: .autoplay, right: .loop)
        #expect(settings.musicPlayback == before)
    }

    // MARK: - The menu

    private func menu(
        shuffle: MusicShuffleMode = .off, loop: MusicLoopMode = .off, autoplay: Bool = true, transitions: MusicTransitionMode = .off,
        fade: Double = 6, slot: MusicFavoriteControl = .shuffle
    ) -> MusicFavoriteMenuModel {
        MusicFavoriteMenuModel(shuffle: shuffle, loop: loop, autoplay: autoplay, transitions: transitions, fadeSeconds: fade, slotControl: slot)
    }

    @Test("the menu lists Shuffle, Loop, Autoplay, Transitions, Fade length, then Show here after a divider")
    func menuStructure() {
        #expect(menu().entries.map(\.title) == ["Shuffle", "Loop", "Autoplay", "Transitions", "Fade length", nil, "Show here"])
        #expect(menu().entries.last?.title == "Show here")
    }

    @Test("the toggles carry the state they are in")
    func menuToggles() {
        let entries = menu(shuffle: .flow, autoplay: false, transitions: .mixing).entries
        #expect(entries[0] == .shuffle(selected: .flow))
        #expect(entries[2] == .toggle(.autoplay, isOn: false))
        #expect(entries[3] == .transitions(selected: .mixing))
    }

    @Test("Loop offers Off, All and One, with the current mode selected")
    func menuLoop() {
        #expect(MusicFavoriteMenuModel.loopChoices.map(\.title) == ["Off", "All", "One"])
        #expect(MusicFavoriteMenuModel.loopChoices.map(\.mode) == [.off, .playlist, .song])
        #expect(menu(loop: .song).entries[1] == .loop(selected: .song))
    }

    @Test("Fade length is 1 to 12 s with the current value checked, and is not greyed out with Transitions off")
    func menuFade() {
        #expect(MusicFavoriteMenuModel.fadeOptions == Array(1...12))
        #expect(menu(transitions: .off, fade: 9).entries[4] == .fadeLength(selected: 9, options: Array(1...12)))
        #expect(menu(fade: 99).entries[4] == .fadeLength(selected: 12, options: Array(1...12)))
        #expect(menu(fade: .nan).entries[4] == .fadeLength(selected: 6, options: Array(1...12)))
        #expect(MusicFavoriteMenuModel.fadeTitle(6) == "6 s")
    }

    @Test("Show here lists the four controls in enum order and checks the one in this slot")
    func menuShowHere() {
        #expect(menu(slot: .transitions).entries.last == .showHere(selected: .transitions, options: MusicFavoriteControl.allCases))
        #expect(menu(slot: .shuffle).entries.last == .showHere(selected: .shuffle, options: [.shuffle, .loop, .autoplay, .transitions]))
    }
}

// MARK: - One source of truth

extension MusicFavoriteControlsTests {
    @Test("every playback toggle maps to a control, and back")
    func toggleMapping() {
        for toggle in MusicPlaybackToggle.allCases {
            let control = MusicFavoriteControl(toggle)
            #expect(control.toggle == toggle)
        }
        #expect(MusicFavoriteControl.allCases.map(\.toggle) == MusicPlaybackToggle.allCases)
    }

    @Test("the menu covers every playback toggle, in toggle order, before Fade length")
    func menuCoversEveryToggle() {
        let entries = menu().entries
        let covered: [MusicFavoriteControl] = entries.compactMap {
            switch $0 {
            case .toggle(let control, _): control
            case .shuffle: .shuffle
            case .transitions: .transitions
            case .loop: .loop
            default: nil
            }
        }
        #expect(covered == MusicPlaybackToggle.allCases.map(MusicFavoriteControl.init))
        #expect(entries.firstIndex { $0.title == "Fade length" } == covered.count)
    }

    @Test("a control's menu name is its slot title except Loop, which says its mode")
    func oneNameSource() {
        for control in MusicFavoriteControl.allCases where control != .loop && control != .shuffle {
            #expect(control.title() == control.menuTitle)
        }
        #expect(MusicFavoriteControl.shuffle.title() == "Shuffle", "the slot says the mode, the menu names the group")
        #expect(MusicFavoriteControl.loop.title(loop: .song) == "Loop song")
    }

    @Test("the snapshot says which controls are on")
    func isOn() {
        #expect(MusicFavoriteSnapshot(shuffle: .shuffle).isOn(.shuffle))
        #expect(!MusicFavoriteSnapshot(shuffle: .off).isOn(.shuffle))
        #expect(MusicFavoriteSnapshot(autoplay: true).isOn(.autoplay))
        #expect(MusicFavoriteSnapshot(loop: .song).isOn(.loop))
    }

    @Test("MusicService.perform drives each toggle")
    func servicePerform() {
        let clock = MutableClock()
        let service = MusicService(
            backend: FakeMusicBackend(),
            player: MusicPlayer(engine: FakePlaybackEngine()),
            presentSignIn: { _ in },
            presentChannelPicker: { _, _ in },
            closeSignInWindow: {},
            raiseSignInWindow: {},
            nowPlaying: NowPlayingController(surface: FakeNowPlayingSurface(), fetchArtwork: { _ in nil }),
            now: { clock.now },
            preferences: MusicPlaybackPreferences(),
            savePreferences: { _ in },
            refreshOnCreate: false
        )
        service.perform(.shuffle)
        #expect(service.shuffleMode == .shuffle)
        #expect(service.isShuffleOn)
        service.perform(.shuffle)
        #expect(service.shuffleMode == .flow)
        service.perform(.shuffle)
        #expect(service.shuffleMode == .off)
        #expect(service.isShuffleOn == false)
        service.perform(.loop)
        #expect(service.loopMode == .playlist)
        let autoplay = service.isAutoplayOn
        service.perform(.autoplay)
        #expect(service.isAutoplayOn == !autoplay)
        service.perform(.transitions)
        #expect(service.transitionMode == .crossfade)
    }
}
