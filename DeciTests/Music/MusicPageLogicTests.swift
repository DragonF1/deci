// DeciTests/Music/MusicPageLogicTests.swift
import AppKit
import SwiftUI
import Testing

@testable import Deci

@MainActor
@Suite("MusicPageKind")
struct MusicPageKindTests {
    @Test("a collection's kind picks the page's face, and only the liked id makes a Liked page")
    func resolve() {
        #expect(MusicPageKind.resolve(kind: .album, browseId: "MPREb_x") == .album)
        #expect(MusicPageKind.resolve(kind: .artist, browseId: "UCx") == .artist)
        #expect(MusicPageKind.resolve(kind: .playlist, browseId: "VLPLx") == .playlist)
        #expect(MusicPageKind.resolve(kind: .playlist, browseId: "VLLM") == .liked)
        // An album or an artist with that id is still what its kind says.
        #expect(MusicPageKind.resolve(kind: .album, browseId: "VLLM") == .album)
    }
}

@MainActor
@Suite("MusicPagePalette")
struct MusicPagePaletteTests {
    private let cover = MusicTint(hue: 0.6, saturation: 0.5, brightness: 0.5)
    private let fallback = MusicTint.forKey("some page")

    /// The sRGB components of a colour, red, green, blue and alpha.
    private func components(_ color: Color) -> [Double] {
        let resolved = NSColor(color).usingColorSpace(.sRGB) ?? .clear
        return [resolved.redComponent, resolved.greenComponent, resolved.blueComponent, resolved.alphaComponent].map(Double.init)
    }

    private func expectSameColour(_ a: Color, _ b: Color, alpha: Double, sourceLocation: SourceLocation = #_sourceLocation) {
        let lhs = components(a)
        let rhs = components(b)
        for index in 0..<3 {
            #expect(abs(lhs[index] - rhs[index]) < 0.002, sourceLocation: sourceLocation)
        }
        #expect(abs(lhs[3] - alpha) < 0.002, sourceLocation: sourceLocation)
    }

    @Test("the header wash is the page colour at 85 percent on dark and the light colour at 55 percent on light")
    func washFollowsScheme() {
        for palette in [MusicPagePalette(tint: cover), .liked] {
            expectSameColour(palette.wash(for: .dark), palette.page, alpha: 0.85)
            expectSameColour(palette.wash(for: .light), palette.light, alpha: 0.55)
        }
    }

    @Test("a page wears its cover's colours")
    func coverColours() {
        let palette = MusicPagePalette.resolve(kind: .album, coverTint: cover, fallback: fallback)
        #expect(palette == MusicPagePalette(tint: cover))
        #expect(palette.page == cover.page)
        #expect(palette.light == cover.light)
    }

    @Test("until the cover's colour is known the page keeps the tint of its id")
    func fallsBack() {
        for kind in [MusicPageKind.album, .artist, .playlist] {
            #expect(MusicPagePalette.resolve(kind: kind, coverTint: nil, fallback: fallback) == MusicPagePalette(tint: fallback))
        }
    }

    @Test("Liked music keeps its red whatever the cover says")
    func likedIsFixed() {
        #expect(MusicPagePalette.resolve(kind: .liked, coverTint: cover, fallback: fallback) == .liked)
        #expect(MusicPagePalette.resolve(kind: .liked, coverTint: nil, fallback: fallback) == .liked)
        #expect(MusicPagePalette.liked.page != cover.page)
    }
}

@Suite("MusicInk")
struct MusicInkTests {
    @Test("yellow is too light for white, so it gets black ink")
    func yellowGetsBlack() {
        // The system's yellow accent.
        #expect(MusicInk.onFill(red: 1, green: 0.8, blue: 0) == .black)
    }

    @Test("graphite and the default blue keep white ink, like the Mac's own buttons")
    func graphiteAndBlueGetWhite() {
        // The system's graphite and blue accents.
        #expect(MusicInk.onFill(red: 0.596, green: 0.596, blue: 0.616) == .white)
        #expect(MusicInk.onFill(red: 0, green: 0.478, blue: 1) == .white)
        // Orange and green keep white as well: it is what the Mac puts on them.
        #expect(MusicInk.onFill(red: 1, green: 0.584, blue: 0) == .white)
        #expect(MusicInk.onFill(red: 0.157, green: 0.804, blue: 0.255) == .white)
    }

    @Test("the extremes: black takes white ink and white takes black ink")
    func extremes() {
        #expect(MusicInk.onFill(red: 0, green: 0, blue: 0) == .white)
        #expect(MusicInk.onFill(red: 1, green: 1, blue: 1) == .black)
    }

    @Test("out of range and not-a-number components are clamped and do not crash")
    func oddInput() {
        #expect(MusicInk.onFill(red: 3, green: 3, blue: 3) == .black)
        #expect(MusicInk.onFill(red: -1, green: -1, blue: -1) == .white)
        #expect(MusicInk.onFill(red: .nan, green: .infinity, blue: -.infinity) == .white)
    }

    @Test("the ink maps to the colour of its name")
    func colours() {
        #expect(MusicInk.white.color == .white)
        #expect(MusicInk.black.color == .black)
    }
}

@MainActor
@Suite("MusicDarkBlur")
struct MusicDarkBlurTests {
    @Test("the pinned blur is dark Aqua whatever the window wears, and blurs inside the window")
    func pinnedDark() {
        let view = MusicDarkBlur.makeEffectView()
        #expect(view.appearance?.name == .darkAqua)
        #expect(view.blendingMode == .withinWindow)
        #expect(view.state == .active)
    }
}

@MainActor
@Suite("MusicPagePills")
struct MusicPagePillsTests {
    @Test("an album plays, shuffles and pins to Listen again, and has no sort")
    func album() {
        #expect(MusicPagePills.pills(kind: .album, hasTracks: true, canSort: true, hasListenAgainPin: true) == [.play, .shuffle, .pinListenAgain])
        #expect(MusicPagePills.pills(kind: .album, hasTracks: true, canSort: false, hasListenAgainPin: false) == [.play, .shuffle])
    }

    @Test("a playlist adds Sort between Shuffle and the pin when it can sort")
    func playlist() {
        #expect(MusicPagePills.pills(kind: .playlist, hasTracks: true, canSort: true, hasListenAgainPin: true) == [.play, .shuffle, .sort, .pinListenAgain])
        #expect(MusicPagePills.pills(kind: .playlist, hasTracks: true, canSort: false, hasListenAgainPin: true) == [.play, .shuffle, .pinListenAgain])
    }

    @Test("Liked music plays, shuffles and sorts, and has no pin to offer")
    func liked() {
        #expect(MusicPagePills.pills(kind: .liked, hasTracks: true, canSort: true, hasListenAgainPin: false) == [.play, .shuffle, .sort])
    }

    @Test("an artist plays and pins to Home, with no shuffle or sort")
    func artist() {
        #expect(MusicPagePills.pills(kind: .artist, hasTracks: true, canSort: true, hasListenAgainPin: true) == [.play, .pinHome])
    }

    @Test("with no songs there is nothing to play, shuffle or sort, but the pins stay")
    func noTracks() {
        #expect(MusicPagePills.pills(kind: .album, hasTracks: false, canSort: true, hasListenAgainPin: true) == [.pinListenAgain])
        #expect(MusicPagePills.pills(kind: .playlist, hasTracks: false, canSort: true, hasListenAgainPin: false).isEmpty)
        #expect(MusicPagePills.pills(kind: .liked, hasTracks: false, canSort: true, hasListenAgainPin: false).isEmpty)
        #expect(MusicPagePills.pills(kind: .artist, hasTracks: false, canSort: false, hasListenAgainPin: false) == [.pinHome])
    }

    @Test("the Sort pill is plain at rest and names the key and the direction once picked")
    func sortPill() {
        let rest = MusicPagePills.sortPill(.default)
        #expect(rest == .init(label: "Sort", symbol: "arrow.up.arrow.down", isActive: false))
        let up = MusicPagePills.sortPill(MusicPlaylistSort(field: .title, ascending: true))
        #expect(up.label == "Title" && up.symbol == "arrow.up" && up.isActive)
        let down = MusicPagePills.sortPill(MusicPlaylistSort(field: .duration, ascending: false))
        #expect(down.label == "Duration" && down.symbol == "arrow.down" && down.isActive)
    }

    @Test("the Home pin's help explains the limit only when it is the reason")
    func pinHelp() {
        #expect(MusicPagePills.pinHelp(isPinned: true, isEnabled: true) == "Take this artist off Home.")
        #expect(MusicPagePills.pinHelp(isPinned: true, isEnabled: false) == "Take this artist off Home.")
        #expect(MusicPagePills.pinHelp(isPinned: false, isEnabled: true) == "Show this artist at the top of Home.")
        let full = MusicPagePills.pinHelp(isPinned: false, isEnabled: false)
        #expect(full.contains("\(MusicPinnedArtists.limit)"))
        #expect(full.contains("Unpin one"))
    }

    @Test("VoiceOver hears the action, not the pill's word")
    func pinAccessibility() {
        #expect(MusicPagePills.pinAccessibilityLabel(isPinned: false, title: "Fake Artist") == "Pin Fake Artist to Home")
        #expect(MusicPagePills.pinAccessibilityLabel(isPinned: true, title: "Fake Artist") == "Unpin Fake Artist from Home")
    }
}

@MainActor
@Suite("MusicSortNote")
struct MusicSortNoteTests {
    @Test("loading wins over a limit, a limit over nothing")
    func resolve() {
        #expect(MusicSortNote.resolve(isLoadingAll: true, sortLimit: 2000) == .loadingAll)
        #expect(MusicSortNote.resolve(isLoadingAll: true, sortLimit: nil) == .loadingAll)
        #expect(MusicSortNote.resolve(isLoadingAll: false, sortLimit: 2000) == .limited(2000))
        #expect(MusicSortNote.resolve(isLoadingAll: false, sortLimit: nil) == MusicSortNote.none)
    }

    @Test("the limit reads First N songs, and First song for one")
    func limitText() {
        #expect(MusicSortNote.limitText(2000) == "First 2000 songs")
        #expect(MusicSortNote.limitText(2) == "First 2 songs")
        #expect(MusicSortNote.limitText(1) == "First song")
    }
}

@MainActor
@Suite("MusicPageHeroText")
struct MusicPageHeroTextTests {
    @Test("YouTube's bullet becomes the design's middle dot, and empty text is nothing")
    func dotted() {
        #expect(MusicPageHeroText.dotted("Album \u{2022} 2020 \u{2022} 12 songs") == "Album \u{00B7} 2020 \u{00B7} 12 songs")
        #expect(MusicPageHeroText.dotted("  Playlist  ") == "Playlist")
        #expect(MusicPageHeroText.dotted("   ") == nil)
        #expect(MusicPageHeroText.dotted("") == nil)
        #expect(MusicPageHeroText.dotted(nil) == nil)
    }

    @Test("an album shows its artist as the accent and the rest of YouTube's line as the meta")
    func album() {
        let text = MusicPageHeroText.resolve(
            kind: .album, title: "Fake Album", subtitle: "Album \u{2022} Fake Artist \u{2022} 2020 \u{2022} 12 songs", firstArtist: "Fake Artist"
        )
        #expect(text.title == "Fake Album")
        #expect(text.accent == "Fake Artist")
        #expect(text.meta == "Album \u{00B7} 2020 \u{00B7} 12 songs")
    }

    @Test("an album with no known artist keeps YouTube's line whole")
    func albumWithoutArtist() {
        let text = MusicPageHeroText.resolve(kind: .album, title: "Fake Album", subtitle: "Album \u{2022} 2020", firstArtist: nil)
        #expect(text.accent == nil)
        #expect(text.meta == "Album \u{00B7} 2020")
        let blank = MusicPageHeroText.resolve(kind: .album, title: "Fake Album", subtitle: nil, firstArtist: "  ")
        #expect(blank.accent == nil && blank.meta == nil)
    }

    @Test("an album whose line is only the artist has no meta line")
    func albumLineIsArtistOnly() {
        let text = MusicPageHeroText.resolve(kind: .album, title: "T", subtitle: "Fake Artist", firstArtist: "Fake Artist")
        #expect(text.accent == "Fake Artist" && text.meta == nil)
    }

    @Test("an artist page shows the name alone")
    func artist() {
        let text = MusicPageHeroText.resolve(kind: .artist, title: "Fake Artist", subtitle: "1.2M subscribers", firstArtist: "Other")
        #expect(text == MusicPageHeroText(title: "Fake Artist", accent: nil, meta: nil))
    }

    @Test("Liked music has its own title, and Auto playlist as the default accent")
    func liked() {
        let plain = MusicPageHeroText.resolve(kind: .liked, title: "anything", subtitle: nil, firstArtist: nil)
        #expect(plain == MusicPageHeroText(title: "Liked music", accent: "Auto playlist", meta: nil))
        let counted = MusicPageHeroText.resolve(kind: .liked, title: "x", subtitle: "Auto playlist \u{2022} 87 songs", firstArtist: nil)
        #expect(counted.accent == "Auto playlist \u{00B7} 87 songs")
    }

    @Test("a playlist shows YouTube's line as its accent")
    func playlist() {
        let text = MusicPageHeroText.resolve(kind: .playlist, title: "Fake Mix", subtitle: "Playlist \u{2022} 40 songs", firstArtist: "Fake Artist")
        #expect(text == MusicPageHeroText(title: "Fake Mix", accent: "Playlist \u{00B7} 40 songs", meta: nil))
        let bare = MusicPageHeroText.resolve(kind: .playlist, title: "Fake Mix", subtitle: nil, firstArtist: nil)
        #expect(bare.accent == nil)
    }
}

@MainActor
@Suite("MusicPageScroll")
struct MusicPageScrollTests {
    @Test("the bar is clear while the hero reaches under the nav row and solid a fade later")
    func barOpacity() {
        let hero = MusicPageKind.album.heroHeight
        let start = hero - MusicPageScroll.barHeight
        #expect(MusicPageScroll.barOpacity(offset: 0, heroHeight: hero) == 0)
        #expect(MusicPageScroll.barOpacity(offset: start, heroHeight: hero) == 0)
        #expect(MusicPageScroll.barOpacity(offset: start + MusicPageScroll.barFade / 2, heroHeight: hero) == 0.5)
        #expect(MusicPageScroll.barOpacity(offset: start + MusicPageScroll.barFade, heroHeight: hero) == 1)
        #expect(MusicPageScroll.barOpacity(offset: 5000, heroHeight: hero) == 1)
    }

    @Test("an elastic pull above the top and a non-finite offset leave the bar clear")
    func barOpacityOutOfRange() {
        #expect(MusicPageScroll.barOpacity(offset: -80, heroHeight: 288) == 0)
        #expect(MusicPageScroll.barOpacity(offset: .nan, heroHeight: 288) == 0)
        #expect(MusicPageScroll.barOpacity(offset: .infinity, heroHeight: 288) == 0)
    }

    @Test("the tint URL does not change when the page's own cover arrives after the collection's")
    func tintURLIsStable() {
        let page = URL(string: "https://example.invalid/page")
        let collection = URL(string: "https://example.invalid/collection")
        #expect(MusicPageCover.tintURL(page: nil, collection: collection) == collection)
        #expect(MusicPageCover.tintURL(page: page, collection: collection) == collection)
        // With no collection cover the page's is the only one there is.
        #expect(MusicPageCover.tintURL(page: page, collection: nil) == page)
        #expect(MusicPageCover.tintURL(page: nil, collection: nil) == nil)
    }
}

@MainActor
@Suite("MusicSongRowLayout")
struct MusicSongRowLayoutTests {
    @Test("an album track has a number and no cover, a top song has both, the rest only a cover")
    func coverAndNumber() {
        #expect(MusicSongRowLayout.album(number: 7).number == 7)
        #expect(MusicSongRowLayout.album(number: 7).coverSize == nil)
        #expect(MusicSongRowLayout.topSong(number: 3).number == 3)
        #expect(MusicSongRowLayout.topSong(number: 3).coverSize != nil)
        #expect(MusicSongRowLayout.playlist.number == nil)
        #expect(MusicSongRowLayout.playlist.coverSize != nil)
        #expect(MusicSongRowLayout.search.number == nil)
        #expect(MusicSongRowLayout.search.coverSize != nil)
    }

    @Test("every row with a cover uses the Mixer's 32 to 36 pt art and has room for it above and below")
    func coverFitsTheRow() {
        let layouts: [MusicSongRowLayout] = [.search, .playlist, .topSong(number: 1), .album(number: 1)]
        for layout in layouts {
            if let cover = layout.coverSize {
                #expect((32...36).contains(cover))
                #expect(layout.height >= cover + 2 * 2)
            }
            #expect(layout.height >= 36 && layout.height <= 44)
        }
    }

    @Test("an album's playing track is marked by the bars, so its title keeps its colour")
    func accentedTitle() {
        #expect(!MusicSongRowLayout.album(number: 1).accentsCurrentTitle)
        #expect(MusicSongRowLayout.playlist.accentsCurrentTitle)
        #expect(MusicSongRowLayout.topSong(number: 1).accentsCurrentTitle)
        #expect(MusicSongRowLayout.search.accentsCurrentTitle)
    }

}
