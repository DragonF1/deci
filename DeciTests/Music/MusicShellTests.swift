// DeciTests/Music/MusicShellTests.swift
// The pure parts of the Music shell: what fills the right column, the header tabs, how Home draws its shelves, and the
// helpers behind the tints and the avatar. Nothing here draws a view.

import CoreGraphics
import SwiftUI
import Testing
@testable import Deci

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

    @Test("Lyrics and Up next wear their own headers, browse and the picker keep the browse one")
    func headers() {
        #expect(MusicRightColumn.lyrics.header == .lyrics)
        #expect(MusicRightColumn.queue.header == .queue)
        #expect(MusicRightColumn.browse.header == .browse)
        #expect(MusicRightColumn.picker.header == .browse)
    }

    @Test("only Lyrics and Up next sit on the accent wash")
    func wash() {
        #expect(MusicRightColumn.lyrics.hasWash)
        #expect(MusicRightColumn.queue.hasWash)
        #expect(!MusicRightColumn.browse.hasWash)
        #expect(!MusicRightColumn.picker.hasWash)
    }

    @Test("the wash is 0.10 at the top and gone by 90% of the column, and Lyrics pads 20 at the sides and 8 at the top")
    func panelMetrics() {
        #expect(MusicPopupMetrics.panelWashOpacity == 0.10)
        #expect(MusicPopupMetrics.panelWashEnd == 0.9)
        #expect(MusicPopupMetrics.lyricsPaddingSide == 20)
        #expect(MusicPopupMetrics.lyricsPaddingTop == 8)
    }
}

@Suite("MusicHeaderTab")
struct MusicHeaderTabTests {
    @Test("the header has two tabs, Home then Library, and no Search")
    func order() {
        #expect(MusicHeaderTab.allCases == [.home, .library])
        #expect(MusicHeaderTab.allCases.map(\.title) == ["Home", "Library"])
    }

    @Test("the tab on screen is the one highlighted")
    func plainTabs() {
        #expect(MusicHeaderTab.resolve(tab: .home) == .home)
        #expect(MusicHeaderTab.resolve(tab: .library) == .library)
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

    @Test("a shelf of songs is the Quick picks list, every other shelf is a row of cover tiles")
    func styles() {
        let shelves = [
            MusicSamples.shelf("Made for you", "a", "b"),
            songs("Quick picks", "s1", "s2"),
            MusicSamples.shelf("New releases", "c"),
            MusicSamples.shelf("Mixes", "d"),
        ]
        #expect(MusicHomeSectionStyle.styles(for: shelves) == [.tiles, .quickPicks, .tiles, .tiles])
    }

    @Test("Listen again keeps its tiles, even when YouTube sends it as songs")
    func listenAgain() {
        let shelves = [MusicSamples.shelf("Listen again", "a"), songs("Listen again", "s1", "s2")]
        #expect(MusicHomeSectionStyle.styles(for: shelves) == [.tiles, .tiles])
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
}

@Suite("MusicHomeText")
struct MusicHomeTextTests {
    @Test("YouTube's bullets become middle dots")
    func subtitle() {
        #expect(MusicHomeText.subtitle("Album \u{2022} Some Band \u{2022} 2013") == "Album \u{00B7} Some Band \u{00B7} 2013")
        #expect(MusicHomeText.subtitle("Plain") == "Plain")
        #expect(MusicHomeText.subtitle("") == "")
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

    @Test("only the mono styles ask for digits of one width")
    func mono() {
        #expect(MusicStyle.Typeface.mono.mono)
        #expect(MusicStyle.Typeface.mono.size == 11)
        #expect(MusicStyle.Typeface.row.mono == false)
        #expect(MusicStyle.TextStyle(11).mono == false)
    }

    @Test("the right column's type: 17 pt page title, 12 pt line under it, 11 pt chips and See all, 10 pt kicker")
    func rightColumnScale() {
        #expect(MusicStyle.Typeface.pageTitle == MusicStyle.TextStyle(17, .bold))
        #expect(MusicStyle.Typeface.pageSub == MusicStyle.TextStyle(12, .medium))
        #expect(MusicStyle.Typeface.chip == MusicStyle.TextStyle(11, .medium))
        #expect(MusicStyle.Typeface.seeAll == MusicStyle.TextStyle(11))
        #expect(MusicStyle.Typeface.kicker == MusicStyle.TextStyle(10, .semibold, tracking: 0.5))
    }
}

@Suite("MusicStyle.Opacity")
struct MusicStyleOpacityTests {
    @Test("the white opacities of the right column step down from the title to the track number")
    func textSteps() {
        typealias O = MusicStyle.Opacity
        #expect(O.playing == 1.0)
        #expect(O.title == 0.97)
        #expect(O.heading == 0.95)
        #expect(O.row == 0.90)
        #expect(O.sub == 0.50)
        #expect(O.meta == 0.45)
        #expect(O.number == 0.40)
        #expect(O.playing > O.title && O.title > O.heading && O.heading > O.row)
        #expect(O.row > O.sub && O.sub > O.meta && O.meta > O.number)
    }

    @Test("the strokes and the fills under the pointer and under a picked segment")
    func surfaces() {
        typealias O = MusicStyle.Opacity
        #expect(O.strokeSoft == 0.12)
        #expect(O.strokeButton == 0.14)
        #expect(O.rowHover == 0.07)
        #expect(O.segmentTrack == 0.06)
        #expect(O.segmentSelected == 0.14)
        #expect(O.idleControl == 0.55)
        #expect(O.chevron == 0.30)
    }
}
