// DeciTests/Music/MusicTrackActionsSongDataTests.swift
// Song data in a song's menu: its words, its own last block, offline and signed-out use, and its absence from a
// multi-selection's menu and from a tile's.

import Foundation
import Testing
@testable import Deci

extension Array where Element == MusicTrackAction {
    /// The list as it stood before Song data ended every song's menu, for the older suites that pin an exact list.
    var withoutSongData: [MusicTrackAction] { filter { $0 != .songData } }
}

@MainActor
@Suite("MusicTrackActions song data")
struct MusicTrackActionsSongDataTests {
    private let ownPlaylist = MusicTrackContext(pageBrowseId: "VLPLmine", pageTitle: "Mine", pageIsEditable: true)

    @Test("the entry is titled Song data and is not online only")
    func words() {
        #expect(MusicTrackAction.songData.title == "Song data")
        #expect(MusicTrackAction.songData.isOnlineOnly == false)
        #expect(MusicTrackAction.songData.isEnabled)
        #expect(MusicTrackAction.songData.ratingStatus == nil)
    }

    @Test("it sits in a block of its own that comes after the remove block")
    func ownGroup() {
        #expect(MusicTrackAction.songData.group > MusicTrackAction.removeFromPlaylist.group)
        for other in [MusicTrackAction.playNext, .saveToPlaylist, .like(removing: false), .related, .removeFromPlaylist] {
            #expect(other.group != MusicTrackAction.songData.group)
        }
    }

    @Test("it shows in every single-song context, last")
    func everyContext() {
        let track = MusicSamples.track("v1", albumBrowseId: "MPREb1", setVideoId: "set1")
        let contexts: [MusicTrackContext] = [.none, .upNext, ownPlaylist]
        for context in contexts {
            let offered = MusicTrackActions.available(for: track, in: context, offersQueue: true, canRate: true)
            #expect(offered.last == .songData, "context \(context)")
            #expect(offered.filter { $0 == .songData }.count == 1)
        }
    }

    @Test("it shows for a bare song, after related songs")
    func bareSong() {
        #expect(MusicTrackActions.available(for: MusicSamples.track(), in: .none) == [.saveToPlaylist, .related, .songData])
    }

    @Test("a song with no id has nothing to show data for")
    func noId() {
        let offered = MusicTrackActions.available(for: MusicSamples.track(" "), in: .none)
        #expect(offered.contains(.songData) == false)
    }

    @Test("it stays on a tab that has only this Mac to work with: offline and signed out")
    func limited() {
        let offered = MusicTrackActions.available(for: MusicSamples.track("v1"), in: .none, limited: true)
        #expect(offered == [.songData])
        let downloaded = MusicTrackActions.available(
            for: MusicSamples.track("v1"), in: .none, offersQueue: true, download: .downloaded, limited: true, playsOffline: true
        )
        #expect(downloaded.last == .songData)
    }

    @Test("it is its own block at the end of the menu, with a line before it")
    func blocks() {
        let track = MusicSamples.track("v1", albumBrowseId: "MPREb1", setVideoId: "set1")
        let offered = MusicTrackActions.available(for: track, in: ownPlaylist, offersQueue: true, canRate: true)
        let groups = MusicTrackActions.groups(of: offered)
        #expect(groups.last == [.songData])
        #expect(groups.dropLast().last?.last == .removeFromPlaylist)
    }

    @Test("a tile never offers it, and a multi-selection's menu has no Song data")
    func notForTilesOrSelections() {
        let album = MusicSamples.collection("MPREb1", kind: .album, title: "Album")
        #expect(MusicTrackActions.available(for: album, in: .none).contains(.songData) == false)

        let tracks = [MusicSamples.track("a"), MusicSamples.track("b")]
        let offered = MusicSelectionAction.available(
            for: tracks, isUpNext: true, playing: nil, savesToPlaylists: true, removableFromPlaylist: 2
        )
        #expect(offered.isEmpty == false)
        #expect(offered.map(\.title).contains(MusicTrackAction.songData.title) == false)
        #expect(offered.map { $0.menuTitle(count: 2) }.allSatisfy { !$0.contains("Song data") })
    }
}
