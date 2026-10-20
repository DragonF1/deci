// DeciTests/Music/MusicShellTests.swift
// The pure parts of the Music shell: the browse measures, what fills the right column, the header tabs, how
// Home draws its shelves, and the helpers behind the tints and the avatar. Nothing here draws a view.

import CoreGraphics
import SwiftUI
import Testing
@testable import Deci

@Suite("MusicShellLayout")
struct MusicShellLayoutTests {
    @Test("a browse page keeps the Mixer's 16 pt side margin, and Quick picks columns sit 12 pt apart")
    func browseMeasures() {
        #expect(MusicShellLayout.pageMargin == 16)
        #expect(MusicShellLayout.quickPickColumnGap == 12)
    }
}

@Suite("MusicRightColumn")
struct MusicRightColumnTests {
    private func column(lyrics: Bool = false, queue: Bool = false, picker: Bool = false) -> MusicRightColumn {
        MusicRightColumn.resolve(showsPicker: picker, showsLyrics: lyrics, showsQueue: queue)
    }

    @Test("nothing open is browse")
    func browse() {
        #expect(column() == .browse)
    }

    @Test("Lyrics and Up next each take the column, and Lyrics wins if both were somehow on")
    func panels() {
        #expect(column(lyrics: true) == .lyrics)
        #expect(column(queue: true) == .queue)
        #expect(column(lyrics: true, queue: true) == .lyrics)
    }

    @Test("the add to playlist picker covers both panels")
    func picker() {
        #expect(column(picker: true) == .picker)
        #expect(column(lyrics: true, picker: true) == .picker)
        #expect(column(queue: true, picker: true) == .picker)
    }
}

@Suite("MusicHeaderTab")
struct MusicHeaderTabTests {
    @Test("the header has two tabs, Home then Library, and no Search")
    func order() {
        #expect(MusicHeaderTab.allCases == [.home, .library])
        #expect(MusicHeaderTab.allCases.map(\.title) == ["Home", "Library"])
    }

    @Test("a tab that is on screen is the one highlighted")
    func plainTabs() {
        #expect(MusicHeaderTab.resolve(tab: .home, tabBeforeSearch: nil) == .home)
        #expect(MusicHeaderTab.resolve(tab: .library, tabBeforeSearch: nil) == .library)
        // The stale record of an earlier search does not matter once a real tab is showing.
        #expect(MusicHeaderTab.resolve(tab: .home, tabBeforeSearch: .library) == .home)
    }

    @Test("search keeps the tab it was opened from highlighted, Home when it has none")
    func searchBorrowsTheEarlierTab() {
        #expect(MusicHeaderTab.resolve(tab: .search, tabBeforeSearch: .library) == .library)
        #expect(MusicHeaderTab.resolve(tab: .search, tabBeforeSearch: .home) == .home)
        #expect(MusicHeaderTab.resolve(tab: .search, tabBeforeSearch: nil) == .home)
        #expect(MusicHeaderTab.resolve(tab: .search, tabBeforeSearch: .search) == .home)
    }

    @Test("a header tab maps to the browse tab it opens")
    func browseTab() {
        #expect(MusicHeaderTab.home.browseTab == .home)
        #expect(MusicHeaderTab.library.browseTab == .library)
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

    @Test("a Library row leads with its kind, keeps YouTube's line, and does not say the kind twice")
    func librarySubtitle() {
        #expect(MusicHomeText.librarySubtitle(kind: .playlist, youtubeSubtitle: "42 songs") == "Playlist \u{00B7} 42 songs")
        #expect(MusicHomeText.librarySubtitle(kind: .album, youtubeSubtitle: "Some Band") == "Album \u{00B7} Some Band")
        #expect(MusicHomeText.librarySubtitle(kind: .artist, youtubeSubtitle: "") == "Artist")
        #expect(MusicHomeText.librarySubtitle(kind: .artist, youtubeSubtitle: "   ") == "Artist")
        // YouTube's bullet becomes a middle dot, and a line that already starts with the kind is left alone.
        #expect(
            MusicHomeText.librarySubtitle(kind: .album, youtubeSubtitle: "Album \u{2022} Some Band \u{2022} 2013")
                == "Album \u{00B7} Some Band \u{00B7} 2013"
        )
        #expect(MusicHomeText.librarySubtitle(kind: .playlist, youtubeSubtitle: "playlist by someone") == "playlist by someone")
        // The kind has to be a whole word: "Albums by X" is not an album line, and a word after a dot or dash is.
        #expect(MusicHomeText.librarySubtitle(kind: .album, youtubeSubtitle: "Albums by Some Band") == "Album \u{00B7} Albums by Some Band")
        #expect(MusicHomeText.librarySubtitle(kind: .artist, youtubeSubtitle: "Artists to watch") == "Artist \u{00B7} Artists to watch")
        #expect(MusicHomeText.librarySubtitle(kind: .album, youtubeSubtitle: "Album") == "Album")
        #expect(MusicHomeText.librarySubtitle(kind: .album, youtubeSubtitle: "Album, 2013") == "Album, 2013")
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

    @Test("the header avatar shows one letter: the first of the name, in capitals")
    func letter() {
        #expect(MusicAccountInitials.letter("Ada Lovelace") == "A")
        #expect(MusicAccountInitials.letter("ada") == "A")
        #expect(MusicAccountInitials.letter("\u{00E9}mile z") == "\u{00C9}")
        #expect(MusicAccountInitials.letter("") == "")
        #expect(MusicAccountInitials.letter("--- ...") == "")
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
