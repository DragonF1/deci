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

    @Test("only an artist's photo is round")
    func round() {
        #expect(MusicPageKind.artist.isRound)
        #expect(!MusicPageKind.album.isRound)
        #expect(!MusicPageKind.playlist.isRound)
        #expect(!MusicPageKind.liked.isRound)
    }

    @Test("an album numbers its songs from 1, Liked music adds the heart, a playlist has plain rows")
    func rowLayout() {
        #expect(MusicPageKind.album.rowLayout(at: 0) == .album(number: 1))
        #expect(MusicPageKind.album.rowLayout(at: 11) == .album(number: 12))
        #expect(MusicPageKind.liked.rowLayout(at: 0) == .liked)
        #expect(MusicPageKind.liked.rowLayout(at: 40) == .liked)
        #expect(MusicPageKind.playlist.rowLayout(at: 3) == .playlist)
        #expect(MusicPageKind.artist.rowLayout(at: 3) == .playlist)
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

    @MainActor
    @Test("the white Play pill carries dark ink, the popup's own background, never pure black")
    func playPillInk() {
        let fill = MusicPlayPill.fillOpacity
        #expect(MusicInk.onFill(red: fill, green: fill, blue: fill) == .black)
        #expect(MusicPlayPill.ink == MusicStyle.Palette.popupBackground)
    }
}

@MainActor
@Suite("MusicPagePills")
struct MusicPagePillsTests {
    @Test("an album or a playlist plays and shuffles, and gets the menu when it has an action for it")
    func albumAndPlaylist() {
        for kind in [MusicPageKind.album, .playlist, .liked] {
            #expect(MusicPagePills.pills(kind: kind, hasTracks: true, hasMenuItems: true) == [.play, .shuffle, .more])
            #expect(MusicPagePills.pills(kind: kind, hasTracks: true, hasMenuItems: false) == [.play, .shuffle])
        }
    }

    @Test("an artist plays and has no shuffle, since it has no list to shuffle through")
    func artist() {
        #expect(MusicPagePills.pills(kind: .artist, hasTracks: true, hasMenuItems: true) == [.play, .more])
        #expect(MusicPagePills.pills(kind: .artist, hasTracks: true, hasMenuItems: false) == [.play])
    }

    @Test("with no songs there is nothing to play or shuffle, and the menu stays only if it has an action")
    func noTracks() {
        for kind in [MusicPageKind.album, .playlist, .liked, .artist] {
            #expect(MusicPagePills.pills(kind: kind, hasTracks: false, hasMenuItems: true) == [.more])
            #expect(MusicPagePills.pills(kind: kind, hasTracks: false, hasMenuItems: false).isEmpty)
        }
    }

    @Test("an album or a playlist offers the Listen again pin where YouTube has the toggle, then Pin to Home")
    func albumAndPlaylistItems() {
        for kind in [MusicPageKind.album, .playlist] {
            #expect(
                MusicPagePills.menuItems(kind: kind, listenAgainIsPinned: false, home: .canPin)
                    == [.pinListenAgain(isPinned: false), .pinHome(.canPin)]
            )
            #expect(
                MusicPagePills.menuItems(kind: kind, listenAgainIsPinned: true, home: .pinned)
                    == [.pinListenAgain(isPinned: true), .pinHome(.pinned)]
            )
            // No toggle from YouTube leaves only the Home pin: the page can still be pinned to Home.
            #expect(MusicPagePills.menuItems(kind: kind, listenAgainIsPinned: nil, home: .canPin) == [.pinHome(.canPin)])
            #expect(MusicPagePills.menuItems(kind: kind, listenAgainIsPinned: nil, home: .full) == [.pinHome(.full)])
            // With neither, the menu is left out altogether.
            #expect(MusicPagePills.menuItems(kind: kind, listenAgainIsPinned: nil, home: nil).isEmpty)
            #expect(MusicPagePills.menuItems(kind: kind, listenAgainIsPinned: false, home: nil) == [.pinListenAgain(isPinned: false)])
        }
    }

    @Test("Liked music offers the Listen again pin only: it belongs to the account and cannot be pinned to Home")
    func likedItems() {
        #expect(MusicPagePills.menuItems(kind: .liked, listenAgainIsPinned: false, home: nil) == [.pinListenAgain(isPinned: false)])
        #expect(MusicPagePills.menuItems(kind: .liked, listenAgainIsPinned: true, home: nil) == [.pinListenAgain(isPinned: true)])
        #expect(MusicPagePills.menuItems(kind: .liked, listenAgainIsPinned: nil, home: nil).isEmpty)
        // Even a Home state handed in by mistake never puts the entry on Liked music.
        #expect(MusicPagePills.menuItems(kind: .liked, listenAgainIsPinned: nil, home: .canPin).isEmpty)
    }

    @Test("an artist offers Pin to Home, and says whether Home has room; it has no Listen again toggle")
    func homeItem() {
        #expect(MusicPagePills.menuItems(kind: .artist, listenAgainIsPinned: true, home: .canPin) == [.pinHome(.canPin)])
        #expect(MusicPagePills.menuItems(kind: .artist, listenAgainIsPinned: nil, home: .full) == [.pinHome(.full)])
        #expect(MusicPagePills.menuItems(kind: .artist, listenAgainIsPinned: nil, home: .pinned) == [.pinHome(.pinned)])
        #expect(MusicPagePills.menuItems(kind: .artist, listenAgainIsPinned: nil, home: nil).isEmpty)
    }

    @Test("a page with a Home entry shows the round menu button")
    func homeEntryShowsMenuButton() {
        for kind in [MusicPageKind.album, .playlist, .artist] {
            let items = MusicPagePills.menuItems(kind: kind, listenAgainIsPinned: nil, home: .canPin)
            #expect(MusicPagePills.pills(kind: kind, hasTracks: false, hasMenuItems: !items.isEmpty) == [.more])
        }
    }
}

@MainActor
@Suite("MusicPageMenuItem")
struct MusicPageMenuItemTests {
    @Test("the Listen again entry reads like the song menu's")
    func listenAgain() {
        let pin = MusicPageMenuItem.pinListenAgain(isPinned: false)
        let unpin = MusicPageMenuItem.pinListenAgain(isPinned: true)
        #expect(pin.title == MusicTrackAction.pinToListenAgain.title)
        #expect(unpin.title == MusicTrackAction.unpinFromListenAgain.title)
        #expect(pin.isEnabled && unpin.isEnabled)
    }

    @Test("the Home entry pins and unpins, and says when Home is full")
    func home() {
        #expect(MusicPageMenuItem.pinHome(.canPin).title == "Pin to Home")
        #expect(MusicPageMenuItem.pinHome(.pinned).title == "Unpin from Home")
        #expect(MusicPageMenuItem.pinHome(.full).title == "Pin to Home (Home is full)")
    }

    @Test("a full Home turns the entry off, and an unpin is always on")
    func enabled() {
        #expect(MusicPageMenuItem.pinHome(.full).isEnabled == false)
        #expect(MusicPageMenuItem.pinHome(.canPin).isEnabled)
        #expect(MusicPageMenuItem.pinHome(.pinned).isEnabled)
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
    private let bullet = "\u{2022}"
    private let dot = "\u{00B7}"

    private func resolve(
        _ kind: MusicPageKind,
        title: String = "Fake Title",
        subtitle: String? = nil,
        firstArtist: String? = nil,
        isEditable: Bool = false,
        songCount: Int? = nil,
        totalSeconds: Int? = nil,
        albumCount: Int? = nil
    ) -> MusicPageHeroText {
        MusicPageHeroText.resolve(
            kind: kind, title: title, subtitle: subtitle, firstArtist: firstArtist, isEditable: isEditable,
            songCount: songCount, totalSeconds: totalSeconds, albumCount: albumCount
        )
    }

    @Test("YouTube's bullet becomes the design's middle dot, and empty text is nothing")
    func dotted() {
        #expect(MusicPageHeroText.dotted("Album \(bullet) 2020 \(bullet) 12 songs") == "Album \(dot) 2020 \(dot) 12 songs")
        #expect(MusicPageHeroText.dotted("  Playlist  ") == "Playlist")
        #expect(MusicPageHeroText.dotted("   ") == nil)
        #expect(MusicPageHeroText.dotted("") == nil)
        #expect(MusicPageHeroText.dotted(nil) == nil)
    }

    @Test("the parts of YouTube's line come out trimmed, with no empty ones")
    func parts() {
        #expect(MusicPageHeroText.parts("Album \(bullet) 2020 \(bullet) 12 songs") == ["Album", "2020", "12 songs"])
        #expect(MusicPageHeroText.parts(nil).isEmpty)
        #expect(MusicPageHeroText.parts("  ").isEmpty)
    }

    @Test("an album says its kind in the kicker, its artist under the title and the year and count in the meta")
    func album() {
        let text = resolve(
            .album, title: "Fake Album", subtitle: "Album \(bullet) Fake Artist \(bullet) 2020 \(bullet) 12 songs", firstArtist: "Fake Artist"
        )
        #expect(text.kicker == "ALBUM")
        #expect(text.title == "Fake Album")
        #expect(text.sub == "Fake Artist")
        #expect(text.meta == "2020 \(dot) 12 songs")
    }

    @Test("a single or an EP takes its own word as the kicker")
    func singleAndEP() {
        #expect(resolve(.album, subtitle: "Single \(bullet) Fake Artist \(bullet) 2021", firstArtist: "Fake Artist").kicker == "SINGLE")
        #expect(resolve(.album, subtitle: "EP \(bullet) Fake Artist \(bullet) 2021", firstArtist: "Fake Artist").kicker == "EP")
        #expect(resolve(.album, subtitle: "Single \(bullet) Fake Artist \(bullet) 2021", firstArtist: "Fake Artist").meta == "2021")
    }

    @Test("an album with no line from YouTube gets its count and length, and one with them does not repeat them")
    func albumCountAndLength() {
        let bare = resolve(.album, firstArtist: "Fake Artist", songCount: 12, totalSeconds: 2700)
        #expect(bare.meta == "12 songs \(dot) 45 min")
        let given = resolve(
            .album, subtitle: "Album \(bullet) Fake Artist \(bullet) 2020 \(bullet) 12 songs", firstArtist: "Fake Artist",
            songCount: 12, totalSeconds: 3000
        )
        #expect(given.meta == "2020 \(dot) 12 songs \(dot) 50 min")
        let full = resolve(
            .album, subtitle: "Album \(bullet) Fake Artist \(bullet) 12 songs \(bullet) 50 minutes", firstArtist: "Fake Artist",
            songCount: 12, totalSeconds: 3000
        )
        #expect(full.meta == "12 songs \(dot) 50 minutes")
    }

    @Test("an album with no known artist or line has only its kicker and title")
    func albumBare() {
        let text = resolve(.album, title: "Fake Album", firstArtist: "  ")
        #expect(text == MusicPageHeroText(kicker: "ALBUM", title: "Fake Album", sub: nil, meta: nil))
    }

    @Test("a count or a length that is not known for certain is left out")
    func unknownCounts() {
        let text = resolve(.playlist, subtitle: "Playlist \(bullet) Fake Owner")
        #expect(text.meta == nil)
    }

    @Test("an artist says its audience under the name and the number of albums in the meta")
    func artist() {
        let text = resolve(.artist, title: "Fake Artist", subtitle: "Artist \(bullet) 1.2M subscribers", albumCount: 3)
        #expect(text == MusicPageHeroText(kicker: "ARTIST", title: "Fake Artist", sub: "1.2M subscribers", meta: "3 albums"))
        #expect(resolve(.artist, subtitle: "1.2M subscribers", albumCount: 1).meta == "1 album")
        #expect(resolve(.artist, subtitle: "1.2M subscribers", albumCount: 0).meta == nil)
        #expect(resolve(.artist, subtitle: nil, albumCount: nil) == MusicPageHeroText(kicker: "ARTIST", title: "Fake Title", sub: nil, meta: nil))
    }

    @Test("a playlist says who made it, and the count and the length")
    func playlist() {
        let text = resolve(
            .playlist, title: "Fake Mix", subtitle: "Playlist \(bullet) Fake Owner \(bullet) 40 songs \(bullet) 2 hours",
            firstArtist: "Fake Artist"
        )
        #expect(text == MusicPageHeroText(kicker: "PLAYLIST", title: "Fake Mix", sub: "Fake Owner", meta: "40 songs \(dot) 2 hours"))
        let views = resolve(.playlist, subtitle: "Playlist \(bullet) Fake Owner \(bullet) 1.2M views \(bullet) 40 songs")
        #expect(views.sub == "Fake Owner")
        #expect(views.meta == "1.2M views \(dot) 40 songs")
        let counted = resolve(.playlist, songCount: 3, totalSeconds: 600)
        #expect(counted.sub == nil)
        #expect(counted.meta == "3 songs \(dot) 10 min")
        #expect(resolve(.playlist, songCount: 1, totalSeconds: 200).meta == "1 song \(dot) 3 min")
    }

    @Test("a playlist the user can edit is Made by you, whoever YouTube names")
    func editablePlaylist() {
        let text = resolve(.playlist, subtitle: "Playlist \(bullet) Fake Owner \(bullet) 4 songs", isEditable: true)
        #expect(text.sub == "Made by you")
        #expect(text.meta == "4 songs")
    }

    @Test("Liked music has its own title and line, and the count and length of its songs")
    func liked() {
        let plain = resolve(.liked, title: "anything")
        #expect(plain == MusicPageHeroText(kicker: "AUTO PLAYLIST", title: "Liked music", sub: MusicPageHeroText.likedSub, meta: nil))
        let counted = resolve(.liked, subtitle: "Auto playlist \(bullet) 87 songs")
        #expect(counted.meta == "87 songs")
        #expect(counted.sub == MusicPageHeroText.likedSub)
        let known = resolve(.liked, songCount: 87, totalSeconds: 18_000)
        #expect(known.meta == "87 songs \(dot) 5 hr")
    }

    @Test("an artist's albums are the items of its Albums shelf, and a shelf of anything else is not counted")
    func albumCount() {
        let albums = MusicShelf(title: "Albums", items: [.collection(MusicSamples.collection("a1", kind: .album)), .collection(MusicSamples.collection("a2", kind: .album))])
        let singles = MusicShelf(title: "Singles", items: [.collection(MusicSamples.collection("s1", kind: .album))])
        #expect(MusicPageHeroText.albumCount(in: [singles, albums]) == 2)
        #expect(MusicPageHeroText.albumCount(in: [MusicShelf(title: " albums ", items: albums.items)]) == 2)
        #expect(MusicPageHeroText.albumCount(in: [singles]) == nil)
        #expect(MusicPageHeroText.albumCount(in: []) == nil)
        #expect(MusicPageHeroText.albumCount(in: [MusicShelf(title: "Albums", items: [.track(MusicSamples.track("t"))])]) == nil)
    }
}

@Suite("MusicPageDuration")
struct MusicPageDurationTests {
    @Test("a length reads in whole minutes, then hours, rounded and never under a minute")
    func text() {
        #expect(MusicPageDuration.text(seconds: 0) == "1 min")
        #expect(MusicPageDuration.text(seconds: 29) == "1 min")
        #expect(MusicPageDuration.text(seconds: 90) == "2 min")
        #expect(MusicPageDuration.text(seconds: 2_280) == "38 min")
        #expect(MusicPageDuration.text(seconds: 3_540) == "59 min")
        #expect(MusicPageDuration.text(seconds: 3_600) == "1 hr")
        #expect(MusicPageDuration.text(seconds: 9_060) == "2 hr 31 min")
        #expect(MusicPageDuration.text(seconds: -5) == "1 min")
    }

    @Test("the total is the sum, and nil whenever it would be a guess")
    func total() {
        #expect(MusicPageDuration.total(of: [200, 100, 40], isComplete: true) == 340)
        #expect(MusicPageDuration.total(of: [200, 100], isComplete: false) == nil)
        #expect(MusicPageDuration.total(of: [], isComplete: true) == nil)
        #expect(MusicPageDuration.total(of: [200, nil], isComplete: true) == nil)
        #expect(MusicPageDuration.total(of: [200, 0], isComplete: true) == nil)
    }
}

@MainActor
@Suite("MusicSongRowLayout")
struct MusicSongRowLayoutTests {
    private let withCover: [MusicSongRowLayout] = [.search, .playlist, .topSong, .liked]

    @Test("rows are 40 pt tall, an album's 32, and every row but an album's has a 30 pt cover with a 4 pt radius")
    func measures() {
        for layout in withCover {
            #expect(layout.height == 40)
            #expect(layout.coverSize == 30)
            #expect(layout.coverRadius == 4)
        }
        #expect(MusicSongRowLayout.album(number: 1).height == 32)
        #expect(MusicSongRowLayout.album(number: 1).coverSize == nil)
        #expect(MusicSongRow.height == 40)
        #expect(MusicSongRow.coverSize == 30)
    }

    @Test("the cover fits its row with room above and below")
    func coverFitsTheRow() {
        for layout in withCover {
            #expect(layout.height >= (layout.coverSize ?? 0) + 2 * 4)
        }
    }

    @Test("an album track has a number and no cover, the other rows have a cover and no number")
    func number() {
        #expect(MusicSongRowLayout.album(number: 7).number == 7)
        for layout in withCover {
            #expect(layout.number == nil)
        }
    }

    @Test("the number sits in an 18 by 16 box, the cover is 12 from the text and the number 10, the title 1 over its line")
    func gaps() {
        for layout in withCover + [.album(number: 1)] {
            #expect(layout.numberBoxWidth == 18)
            #expect(layout.numberBoxHeight == 16)
            #expect(layout.textGap == 1)
            #expect(layout.trailingGap == 8)
            #expect(layout.horizontalPadding == MusicStyle.Spacing.page)
        }
        for layout in withCover {
            #expect(layout.contentGap == 12)
        }
        #expect(MusicSongRowLayout.album(number: 1).contentGap == 10)
    }

    @Test("the current row's title is a weight heavier and full white, the others 90 percent")
    func titleStyle() {
        let layout = MusicSongRowLayout.playlist
        #expect(layout.titleStyle(isCurrent: true) == MusicStyle.Typeface.rowMedium)
        #expect(layout.titleStyle(isCurrent: false) == MusicStyle.Typeface.row)
        #expect(layout.titleColorOpacity(isCurrent: true) == 1.0)
        #expect(layout.titleColorOpacity(isCurrent: false) == 0.90)
    }

    @Test("numbers are set in mono, and so are the durations of album and Liked rows")
    func monoStyles() {
        for layout in withCover + [.album(number: 1)] {
            #expect(layout.numberStyle == MusicStyle.Typeface.mono)
        }
        #expect(MusicSongRowLayout.album(number: 1).durationStyle == MusicStyle.Typeface.mono)
        #expect(MusicSongRowLayout.liked.durationStyle == MusicStyle.Typeface.mono)
        #expect(MusicSongRowLayout.playlist.durationStyle == MusicStyle.Typeface.seeAll)
        #expect(MusicSongRowLayout.search.durationStyle == MusicStyle.Typeface.seeAll)
        #expect(MusicSongRowLayout.topSong.durationStyle == MusicStyle.Typeface.seeAll)
    }

    @Test("only a Liked row shows the heart, 12 pt at 90 percent")
    func heart() {
        #expect(MusicSongRowLayout.liked.showsHeart)
        #expect(MusicSongRowLayout.liked.heartSize == 12)
        #expect(MusicSongRowLayout.liked.heartOpacity == 0.9)
        for layout in [MusicSongRowLayout.search, .playlist, .topSong, .album(number: 1)] {
            #expect(!layout.showsHeart)
        }
    }

    @Test("a song row says artist and album under the title, a top song only the album, an album track nothing")
    func subtitle() {
        #expect(MusicSongRowLayout.search.subtitle == .artistAndAlbum)
        #expect(MusicSongRowLayout.playlist.subtitle == .artistAndAlbum)
        #expect(MusicSongRowLayout.liked.subtitle == .artistAndAlbum)
        #expect(MusicSongRowLayout.topSong.subtitle == .album)
        let albumTrack: MusicSongRowLayout.Subtitle = MusicSongRowLayout.album(number: 1).subtitle
        #expect(albumTrack == MusicSongRowLayout.Subtitle.none)
    }

    @Test("a duration shows as m:ss, and a song of no known length shows none")
    func durationText() {
        #expect(MusicSongRowLayout.durationText(seconds: 225) == "3:45")
        #expect(MusicSongRowLayout.durationText(seconds: 61) == "1:01")
        #expect(MusicSongRowLayout.durationText(seconds: 3_725) == "1:02:05")
        #expect(MusicSongRowLayout.durationText(seconds: nil) == nil)
        #expect(MusicSongRowLayout.durationText(seconds: 0) == nil)
        #expect(MusicSongRowLayout.durationText(seconds: -4) == nil)
    }
}
