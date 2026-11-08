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

    @Test("the list is shuffle, loop, autoplay, crossfade, like, in that order")
    func order() {
        #expect(MusicFavoriteControl.allCases == [.shuffle, .loop, .autoplay, .crossfade, .like])
    }

    @Test("every control survives its raw value")
    func rawRoundTrip() {
        for control in MusicFavoriteControl.allCases {
            #expect(MusicFavoriteControl(rawValue: control.rawValue) == control)
        }
        #expect(MusicFavoriteControl.allCases.map(\.rawValue) == ["shuffle", "loop", "autoplay", "crossfade", "like"])
    }

    @Test("an unknown raw value is no control")
    func unknownRaw() {
        #expect(MusicFavoriteControl(rawValue: "teleport") == nil)
        #expect(MusicFavoriteControl(rawValue: "") == nil)
        #expect(MusicFavoriteControl(rawValue: "Shuffle") == nil)
    }

    @Test("the four toggles take the Up next header's glyphs; Like is the thumbs up, filled once liked")
    func glyphs() {
        #expect(MusicFavoriteControl.shuffle.symbol(loop: .off, isLiked: false) == "shuffle")
        #expect(MusicFavoriteControl.loop.symbol(loop: .off, isLiked: false) == "repeat")
        #expect(MusicFavoriteControl.loop.symbol(loop: .song, isLiked: false) == "repeat.1")
        #expect(MusicFavoriteControl.autoplay.symbol(loop: .off, isLiked: false) == "infinity")
        #expect(MusicFavoriteControl.crossfade.symbol(loop: .off, isLiked: false) == "arrow.triangle.merge")
        #expect(MusicFavoriteControl.like.symbol(loop: .off, isLiked: false) == "hand.thumbsup")
        #expect(MusicFavoriteControl.like.symbol(loop: .off, isLiked: true) == "hand.thumbsup.fill")
    }

    @Test("only the two buttons the row always had keep a tooltip")
    func tooltips() {
        #expect(MusicFavoriteControl.allCases.filter(\.hasTooltip) == [.shuffle, .loop])
    }

    // MARK: - The slots

    @Test("the default slots are shuffle on the left and loop on the right")
    func defaults() {
        #expect(MusicFavoriteSlots.default.left == .shuffle)
        #expect(MusicFavoriteSlots.default.right == .loop)
        #expect(AppSettings().musicFavoriteSlots == .default)
        #expect(AppSettings().musicFavoriteLeft == "shuffle")
        #expect(AppSettings().musicFavoriteRight == "loop")
    }

    @Test("an unknown or missing raw value is that slot's default")
    func fallback() {
        #expect(MusicFavoriteSlots(leftRaw: "teleport", rightRaw: "like") == MusicFavoriteSlots(left: .shuffle, right: .like))
        #expect(MusicFavoriteSlots(leftRaw: "crossfade", rightRaw: "teleport") == MusicFavoriteSlots(left: .crossfade, right: .loop))
        #expect(MusicFavoriteSlots(leftRaw: nil, rightRaw: nil) == .default)
        #expect(MusicFavoriteSlots(leftRaw: "", rightRaw: "") == .default)
    }

    @Test("two slots that name one control never end up equal")
    func duplicatesAreRepaired() {
        let same = MusicFavoriteSlots(left: .like, right: .like)
        #expect(same.left == .like)
        #expect(same.right != .like)
        let loops = MusicFavoriteSlots(left: .loop, right: .loop)
        #expect(loops.left == .loop)
        #expect(loops.right == .shuffle)
        #expect(MusicFavoriteSlots(leftRaw: "like", rightRaw: "like").left != MusicFavoriteSlots(leftRaw: "like", rightRaw: "like").right)
    }

    @Test("choosing a control puts it in the slot")
    func choose() {
        var slots = MusicFavoriteSlots.default
        slots.choose(.crossfade, for: .left)
        #expect(slots == MusicFavoriteSlots(left: .crossfade, right: .loop))
        slots.choose(.like, for: .right)
        #expect(slots == MusicFavoriteSlots(left: .crossfade, right: .like))
    }

    @Test("choosing the control a slot already holds changes nothing")
    func chooseSame() {
        #expect(MusicFavoriteSlots.default.choosing(.shuffle, for: .left) == .default)
        #expect(MusicFavoriteSlots.default.choosing(.loop, for: .right) == .default)
    }

    @Test("choosing the other slot's control swaps the two slots")
    func chooseSwaps() {
        #expect(MusicFavoriteSlots.default.choosing(.loop, for: .left) == MusicFavoriteSlots(left: .loop, right: .shuffle))
        #expect(MusicFavoriteSlots.default.choosing(.shuffle, for: .right) == MusicFavoriteSlots(left: .loop, right: .shuffle))
    }

    @Test("every choice in every slot leaves two distinct controls")
    func neverDuplicated() {
        for start in MusicFavoriteControl.allCases {
            for other in MusicFavoriteControl.allCases where other != start {
                for side in MusicFavoriteSide.allCases {
                    for pick in MusicFavoriteControl.allCases {
                        let slots = MusicFavoriteSlots(left: start, right: other).choosing(pick, for: side)
                        #expect(slots[side] == pick)
                        #expect(slots.left != slots.right)
                    }
                }
            }
        }
    }

    // MARK: - Persistence

    @Test("the slots survive an encode and decode of AppSettings")
    func roundTrip() throws {
        var settings = AppSettings()
        settings.musicFavoriteSlots = MusicFavoriteSlots(left: .autoplay, right: .like)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings)
        #expect(decoded.musicFavoriteSlots == MusicFavoriteSlots(left: .autoplay, right: .like))
        #expect(decoded.musicFavoriteLeft == "autoplay")
        #expect(decoded.musicFavoriteRight == "like")
    }

    @Test("the slots are stored as raw strings under their two keys")
    func storedKeys() throws {
        var settings = AppSettings()
        settings.musicFavoriteSlots = MusicFavoriteSlots(left: .crossfade, right: .shuffle)
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any]
        #expect(object?["musicFavoriteLeft"] as? String == "crossfade")
        #expect(object?["musicFavoriteRight"] as? String == "shuffle")
    }

    @Test("a file from before the slots existed decodes to the defaults")
    func oldFile() throws {
        let settings = try decode(#"{"launchAtLogin": true, "musicShuffle": true}"#)
        #expect(settings.launchAtLogin)
        #expect(settings.musicFavoriteSlots == .default)
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
        settings.musicFavoriteSlots = MusicFavoriteSlots(left: .like, right: .autoplay)
        #expect(settings.musicPlayback == before)
    }

    // MARK: - The menu

    private func menu(
        shuffle: Bool = false, loop: MusicLoopMode = .off, autoplay: Bool = true, crossfade: Bool = false,
        fade: Double = 6, slot: MusicFavoriteControl = .shuffle
    ) -> MusicFavoriteMenuModel {
        MusicFavoriteMenuModel(shuffle: shuffle, loop: loop, autoplay: autoplay, crossfade: crossfade, fadeSeconds: fade, slotControl: slot)
    }

    @Test("the menu lists Shuffle, Loop, Autoplay, Crossfade, Fade length, then Show here after a divider")
    func menuStructure() {
        #expect(menu().entries.map(\.title) == ["Shuffle", "Loop", "Autoplay", "Crossfade", "Fade length", nil, "Show here"])
        #expect(menu().entries.last?.title == "Show here")
    }

    @Test("the toggles carry the state they are in")
    func menuToggles() {
        let entries = menu(shuffle: true, autoplay: false, crossfade: true).entries
        #expect(entries[0] == .shuffle(selected: .shuffle))
        #expect(entries[2] == .toggle(.autoplay, isOn: false))
        #expect(entries[3] == .toggle(.crossfade, isOn: true))
    }

    @Test("Loop offers Off, All and One, with the current mode selected")
    func menuLoop() {
        #expect(MusicFavoriteMenuModel.loopChoices.map(\.title) == ["Off", "All", "One"])
        #expect(MusicFavoriteMenuModel.loopChoices.map(\.mode) == [.off, .playlist, .song])
        #expect(menu(loop: .song).entries[1] == .loop(selected: .song))
    }

    @Test("Fade length is 1 to 12 s with the current value checked, and is not greyed out with Crossfade off")
    func menuFade() {
        #expect(MusicFavoriteMenuModel.fadeOptions == Array(1...12))
        #expect(menu(crossfade: false, fade: 9).entries[4] == .fadeLength(selected: 9, options: Array(1...12)))
        #expect(menu(fade: 99).entries[4] == .fadeLength(selected: 12, options: Array(1...12)))
        #expect(menu(fade: .nan).entries[4] == .fadeLength(selected: 6, options: Array(1...12)))
        #expect(MusicFavoriteMenuModel.fadeTitle(6) == "6 s")
    }

    @Test("Show here lists every control in enum order and checks the one in this slot")
    func menuShowHere() {
        #expect(menu(slot: .like).entries.last == .showHere(selected: .like, options: MusicFavoriteControl.allCases))
        #expect(menu(slot: .shuffle).entries.last == .showHere(selected: .shuffle, options: [.shuffle, .loop, .autoplay, .crossfade, .like]))
    }
}

// MARK: - One source of truth

extension MusicFavoriteControlsTests {
    @Test("every playback toggle maps to a control, and back")
    func toggleMapping() {
        for toggle in MusicPlaybackToggle.allCases {
            let control = MusicFavoriteControl(toggle)
            #expect(control.kind == .toggle(toggle))
        }
        #expect(MusicFavoriteControl.like.kind == .like)
        #expect(MusicFavoriteControl.allCases.compactMap { $0.kind.toggle } == MusicPlaybackToggle.allCases)
    }

    @Test("the menu covers every playback toggle, in toggle order, before Fade length")
    func menuCoversEveryToggle() {
        let entries = menu().entries
        let covered: [MusicFavoriteControl] = entries.compactMap {
            switch $0 {
            case .toggle(let control, _): control
            case .shuffle: .shuffle
            case .loop: .loop
            default: nil
            }
        }
        #expect(covered == MusicPlaybackToggle.allCases.map(MusicFavoriteControl.init))
        #expect(entries.firstIndex { $0.title == "Fade length" } == covered.count)
    }

    @Test("a control's menu name is its slot title except Loop, which says its mode")
    func oneNameSource() {
        for control in MusicFavoriteControl.allCases where control != .loop {
            #expect(control.title() == control.menuTitle)
        }
        #expect(MusicFavoriteControl.loop.title(loop: .song) == "Loop song")
    }

    @Test("the snapshot says which controls can be used")
    func availability() {
        let signedOut = MusicFavoriteSnapshot(canLike: false)
        #expect(signedOut.isAvailable(.like) == false)
        for control in MusicFavoriteControl.allCases where control != .like {
            #expect(signedOut.isAvailable(control))
        }
        #expect(MusicFavoriteSnapshot(canLike: true).isAvailable(.like))
        #expect(MusicFavoriteSnapshot(isLiked: true).isOn(.like))
        #expect(MusicFavoriteSnapshot(shuffle: true).isOn(.shuffle))
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
        service.perform(.shuffle)
        #expect(service.shuffleMode == .mix)
        #expect(service.isShuffleOn)
        service.perform(.shuffle)
        #expect(service.shuffleMode == .off)
        #expect(service.isShuffleOn == false)
        service.perform(.loop)
        #expect(service.loopMode == .playlist)
        let autoplay = service.isAutoplayOn
        service.perform(.autoplay)
        #expect(service.isAutoplayOn == !autoplay)
        service.perform(.crossfade)
        #expect(service.isCrossfadeOn)
    }
}
