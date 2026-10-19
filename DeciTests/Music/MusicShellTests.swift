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

    @Test("the mini player spans the popover inside its side margin, and never goes negative")
    func miniPlayerWidth() {
        let margin = MusicShellLayout.miniPlayerMargin
        #expect(MusicShellLayout.miniPlayerWidth(forWidth: 470) == 470 - 2 * margin)
        #expect(MusicShellLayout.miniPlayerWidth(forWidth: 30) == 10)
        #expect(MusicShellLayout.miniPlayerWidth(forWidth: 2 * margin - 1) == 0)
        #expect(MusicShellLayout.miniPlayerWidth(forWidth: 0) == 0)
    }

    @Test("a list scrolls clear of the mini player while one shows, and keeps the page margin without one")
    func bottomInset() {
        let without = MusicShellLayout.bottomInset(hasMiniPlayer: false)
        let with = MusicShellLayout.bottomInset(hasMiniPlayer: true)
        #expect(without == MusicShellLayout.pageMargin)
        #expect(with >= MusicStyle.Size.miniPlayerHeight + MusicShellLayout.miniPlayerBottom)
        #expect(with > without)
    }

    @Test("a list's last row scrolls clear of the mini player, and the fade and the click shield cover its footprint")
    func insetClearsThePlayer() {
        let footprint = MusicStyle.Size.miniPlayerHeight + MusicShellLayout.miniPlayerBottom
        #expect(MusicShellLayout.miniPlayerFootprint == footprint)
        // The inset is the whole footprint plus a real gap, so the last row stops above the player and not under it.
        #expect(MusicShellLayout.miniPlayerClearance > 0)
        #expect(MusicShellLayout.bottomInset(hasMiniPlayer: true) == footprint + MusicShellLayout.miniPlayerClearance)
        // The fade dissolves the rows over the whole player, side margins and bottom gap included.
        #expect(MusicShellLayout.scrimHeight >= footprint)
    }

    @Test("the account card hangs clear under the avatar and fits inside the popover, at every size", arguments: MenuBarPopupSize.allCases)
    @MainActor
    func accountCardPlacement(size: MenuBarPopupSize) {
        let dimensions = size.dimensions
        let padding = dimensions.contentPadding
        let avatarBottom = padding + (MusicPopupMetrics.headerHeight + MusicStyle.Size.headerButton) / 2
        let cardTop = MusicPopupMetrics.accountCardTop(contentPadding: padding)
        #expect(cardTop > avatarBottom)
        // The card is as wide as it is and ends where the avatar does, so it must fit between that edge and the left one.
        let cardLeft = dimensions.width - MusicPopupMetrics.avatarTrailingInset(contentPadding: padding) - MusicAccountCard.width
        #expect(cardLeft >= 0)
        // The avatar sits left of the gear, one gap apart.
        let gearLeft = dimensions.width - padding - MusicStyle.Size.headerButton
        let avatarRight = dimensions.width - MusicPopupMetrics.avatarTrailingInset(contentPadding: padding)
        #expect(gearLeft - avatarRight == MusicPopupMetrics.headerButtonGap)
        // The body starts under the header row.
        #expect(MusicPopupMetrics.contentTop(contentPadding: padding) > padding + MusicPopupMetrics.headerHeight)
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
