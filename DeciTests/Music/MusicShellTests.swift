// DeciTests/Music/MusicShellTests.swift
// The pure parts of the Music shell: the popover height, the chrome measures, which screen shows, the tab labels, how
// Home draws its shelves, and the helpers behind the tints and the avatar. Nothing here draws a view.

import CoreGraphics
import SwiftUI
import Testing
@testable import Deci

@Suite("MusicShellLayout")
struct MusicShellLayoutTests {
    @Test("the popover is as tall as the old gear row, gap and body inside its padding, at every size", arguments: MenuBarPopupSize.allCases)
    func totalHeightIsUnchanged(size: MenuBarPopupSize) {
        let dimensions = size.dimensions
        let height = MusicPopupMetrics.totalHeight(
            maxContentHeight: dimensions.maxContentHeight,
            contentPadding: dimensions.contentPadding
        )
        let expected: CGFloat = 2 * dimensions.contentPadding + 32 + 8 + 520
        #expect(height == expected)
    }

    @Test("a short popup limit shrinks the body and so the popover")
    func totalHeightFollowsASmallLimit() {
        let expected: CGFloat = 24 + 32 + 8 + 400
        #expect(MusicPopupMetrics.totalHeight(maxContentHeight: 400, contentPadding: 12) == expected)
    }

    @Test("the tab bar is 286 wide when there is room and shrinks with the popover when there is not")
    func tabBarWidth() {
        #expect(MusicShellLayout.tabBarWidth(forWidth: 510) == 286)
        #expect(MusicShellLayout.tabBarWidth(forWidth: 470) == 286)
        #expect(MusicShellLayout.tabBarWidth(forWidth: 300) == 260)
        #expect(MusicShellLayout.tabBarWidth(forWidth: 10) == 0)
    }

    @Test("three tabs share what is left of the bar inside its padding")
    func tabWidth() {
        let expected: CGFloat = 278.0 / 3.0
        #expect(MusicShellLayout.tabWidth(forBarWidth: 286) == expected)
        #expect(MusicShellLayout.tabWidth(forBarWidth: 4) == 0)
    }

    @Test("the mini player spans the popover inside the page margin")
    func miniPlayerWidth() {
        #expect(MusicShellLayout.miniPlayerWidth(forWidth: 470) == 430)
        #expect(MusicShellLayout.miniPlayerWidth(forWidth: 30) == 0)
    }

    @Test("a list scrolls clear of the tab bar, and of the mini player while one shows")
    func bottomInset() {
        #expect(MusicShellLayout.bottomInset(hasMiniPlayer: false) == 80)
        #expect(MusicShellLayout.bottomInset(hasMiniPlayer: true) == 140)
    }
}

@Suite("MusicShellScreen")
struct MusicShellScreenTests {
    private func screen(
        open: Bool = false, track: Bool = true, lyrics: Bool = false, queue: Bool = false, picker: Bool = false
    ) -> MusicShellScreen {
        MusicShellScreen.resolve(
            isNowPlayingOpen: open, hasTrack: track, showsLyrics: lyrics, showsQueue: queue, showsPicker: picker
        )
    }

    @Test("nothing open is a browse screen")
    func browse() {
        #expect(screen() == .browse)
        #expect(screen().isPlayer == false)
    }

    @Test("Now Playing shows only with a loaded track")
    func nowPlaying() {
        #expect(screen(open: true) == .nowPlaying)
        #expect(screen(open: true, track: false) == .browse)
    }

    @Test("Lyrics and Up next are player screens, and Lyrics wins if both were somehow on")
    func panels() {
        #expect(screen(lyrics: true) == .lyrics)
        #expect(screen(queue: true) == .queue)
        #expect(screen(lyrics: true, queue: true) == .lyrics)
        #expect(screen(lyrics: true).isPlayer)
        #expect(screen(queue: true).isPlayer)
    }

    @Test("the add to playlist picker is a browse screen, even over a player screen")
    func picker() {
        #expect(screen(open: true, lyrics: true, picker: true) == .browse)
        #expect(screen(open: true, queue: true, picker: true) == .browse)
    }
}

@Suite("MusicBrowseStore.Tab labels")
struct MusicTabLabelTests {
    @Test("the tabs run Home, Library, Search")
    func order() {
        #expect(MusicBrowseStore.Tab.allCases == [.home, .library, .search])
        #expect(MusicBrowseStore.Tab.allCases.map(\.title) == ["Home", "Library", "Search"])
    }

    @Test("only Home has a filled icon, and only while selected")
    func symbols() {
        #expect(MusicBrowseStore.Tab.home.symbol(selected: false) == "house")
        #expect(MusicBrowseStore.Tab.home.symbol(selected: true) == "house.fill")
        #expect(MusicBrowseStore.Tab.library.symbol(selected: true) == MusicBrowseStore.Tab.library.symbol(selected: false))
        #expect(MusicBrowseStore.Tab.search.symbol(selected: true) == MusicBrowseStore.Tab.search.symbol(selected: false))
    }
}

@Suite("MusicHomeSectionStyle")
struct MusicHomeSectionStyleTests {
    private func songs(_ title: String, _ ids: String...) -> MusicShelf {
        MusicShelf(title: title, items: ids.map { .track(MusicSamples.track($0)) })
    }

    @Test("a shelf of songs is Quick picks, the first other shelf is Top Picks, the rest are cover tiles")
    func styles() {
        let shelves = [
            MusicSamples.shelf("Made for you", "a", "b"),
            songs("Quick picks", "s1", "s2"),
            MusicSamples.shelf("New releases", "c"),
            MusicSamples.shelf("Mixes", "d"),
        ]
        #expect(MusicHomeSectionStyle.styles(for: shelves) == [.topPicks, .quickPicks, .coverTiles, .coverTiles])
    }

    @Test("Listen again keeps its tiles and does not take the Top Picks slot")
    func listenAgain() {
        let shelves = [MusicSamples.shelf("Listen again", "a"), MusicSamples.shelf("Made for you", "b")]
        #expect(MusicHomeSectionStyle.styles(for: shelves) == [.coverTiles, .topPicks])
        #expect(MusicHomeSectionStyle.isListenAgain(MusicSamples.shelf("LISTEN AGAIN", "a")))
    }

    @Test("an empty shelf is not a songs shelf, and a mixed one is not either")
    func songsOnly() {
        #expect(MusicHomeSectionStyle.isSongsOnly(MusicShelf(title: "x", items: [])) == false)
        let mixed = MusicShelf(
            title: "x", items: [.track(MusicSamples.track("t")), .collection(MusicSamples.collection("c"))]
        )
        #expect(MusicHomeSectionStyle.isSongsOnly(mixed) == false)
        #expect(MusicHomeSectionStyle.styles(for: []).isEmpty)
    }

    @Test("a Top Picks card names what it opens")
    func kickers() {
        #expect(MusicHomeSectionStyle.kicker(for: .track(MusicSamples.track("t"))) == "SONG")
        #expect(MusicHomeSectionStyle.kicker(for: .collection(MusicSamples.collection("p", kind: .playlist))) == "PLAYLIST")
        #expect(MusicHomeSectionStyle.kicker(for: .collection(MusicSamples.collection("a", kind: .album))) == "ALBUM")
        #expect(MusicHomeSectionStyle.kicker(for: .collection(MusicSamples.collection("r", kind: .artist))) == "ARTIST")
    }
}

@Suite("MusicHomeText")
struct MusicHomeTextTests {
    @Test("YouTube's bullets become middle dots")
    func subtitle() {
        #expect(MusicHomeText.subtitle("Album \u{2022} Some Band \u{2022} 2013") == "Album \u{00B7} Some Band \u{00B7} 2013")
        #expect(MusicHomeText.subtitle("Plain") == "Plain")
        #expect(MusicHomeText.subtitle("") == "")
    }

    @Test("a song line joins the artist and the album and skips a missing half")
    func songSubtitle() {
        #expect(MusicHomeText.songSubtitle(artist: "Some Band", album: "First Record") == "Some Band \u{00B7} First Record")
        #expect(MusicHomeText.songSubtitle(artist: "Some Band", album: nil) == "Some Band")
        #expect(MusicHomeText.songSubtitle(artist: "", album: "First Record") == "First Record")
        #expect(MusicHomeText.songSubtitle(artist: "", album: nil) == "")
    }
}

@Suite("MusicTint")
struct MusicTintTests {
    @Test("FNV-1a gives the published value for a known input and for the empty string")
    func knownHash() {
        #expect(MusicHash.fnv1a("a") == 0xaf63_dc4c_8601_ec8c)
        #expect(MusicHash.fnv1a("") == 0xcbf2_9ce4_8422_2325)
    }

    @Test("a key always gets the same tint, one from the palette")
    func deterministic() {
        #expect(MusicTint.forKey("vid-1") == MusicTint.forKey("vid-1"))
        #expect(MusicTint.palette.contains(MusicTint.forKey("vid-2")))
        #expect(MusicTint.forKey("") == MusicTint.palette[5])
    }

    @Test("values are clamped and the hue wraps")
    func clamps() {
        let tint = MusicTint(hue: 1.25, saturation: 2, brightness: -1)
        #expect(tint.hue == 0.25)
        #expect(tint.saturation == 1)
        #expect(tint.brightness == 0)
        let broken = MusicTint(hue: .nan, saturation: .infinity, brightness: .nan)
        #expect(broken.hue == 0)
        #expect(broken.saturation == 0)
        #expect(broken.brightness == 0)
    }

    @Test("the page brightness stays between 23 and 46 percent, and the bottom is half of it")
    func pageBrightness() {
        #expect(MusicTint(hue: 0, saturation: 0.5, brightness: 0).pageBrightness == 0.23)
        #expect(MusicTint(hue: 0, saturation: 0.5, brightness: 1).pageBrightness == 0.46)
        #expect(MusicTint(hue: 0, saturation: 0.5, brightness: 0.3).pageBrightness == 0.3)
        #expect(MusicTint(hue: 0, saturation: 0.5, brightness: 1).pageBottomBrightness == 0.23)
    }

    @Test("the light colour is bright and soft, and the ink is dark and richer")
    func lightAndInk() {
        let tint = MusicTint(hue: 0.5, saturation: 0.9, brightness: 0.5)
        #expect(tint.lightSaturation == 0.3)
        #expect(abs(tint.lightBrightness - 0.92) < 0.0001)
        #expect(abs(tint.inkBrightness - 0.175) < 0.0001)
        #expect(abs(tint.inkSaturation - 0.95) < 0.0001)
        #expect(MusicTint(hue: 0, saturation: 0, brightness: 0).lightSaturation == 0.2)
    }
}

@Suite("MusicAccountInitials")
struct MusicAccountInitialsTests {
    @Test("two words give the first and last initial, one word gives one")
    func initials() {
        #expect(MusicAccountInitials.from("Ada Lovelace") == "AL")
        #expect(MusicAccountInitials.from("ada king lovelace") == "AL")
        #expect(MusicAccountInitials.from("Ada") == "A")
    }

    @Test("blank names, punctuation and emoji do not crash and give nothing or what is there")
    func edges() {
        #expect(MusicAccountInitials.from("") == "")
        #expect(MusicAccountInitials.from("   ") == "")
        #expect(MusicAccountInitials.from("--- ...") == "")
        #expect(MusicAccountInitials.from("  Ada   Lovelace  ") == "AL")
        #expect(MusicAccountInitials.from("\u{00E9}mile z") == "\u{00C9}Z")
    }
}

@Suite("MusicStyle.TextStyle")
struct MusicTextStyleTests {
    @Test("negative tracking applies only from 24 pt up")
    func negativeTracking() {
        #expect(MusicStyle.TextStyle(24, .bold, tracking: -0.5).appliedTracking == -0.5)
        #expect(MusicStyle.TextStyle(40, .bold, tracking: -1).appliedTracking == -1)
        #expect(MusicStyle.TextStyle(23.9, .bold, tracking: -0.5).appliedTracking == 0)
        #expect(MusicStyle.TextStyle(15, .medium, tracking: -0.2).appliedTracking == 0)
    }

    @Test("positive and zero tracking are kept at any size")
    func otherTracking() {
        #expect(MusicStyle.TextStyle(11, .semibold, tracking: 0.6).appliedTracking == 0.6)
        #expect(MusicStyle.TextStyle(14).appliedTracking == 0)
    }
}
