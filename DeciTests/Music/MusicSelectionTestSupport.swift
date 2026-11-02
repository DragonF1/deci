// DeciTests/Music/MusicSelectionTestSupport.swift
// Test-side shorthand for the selection tests: a row is named by its song, and the helper finds its place in the list the
// way a row knows its own index. A song the list does not hold gets an index outside it.

import Foundation
@testable import Deci

extension MusicSelectionScope {
    /// The place of the first row that is `track`: the same song and the same playlist item id. -1 when there is none.
    func index(of track: Deci.MusicTrack) -> Int {
        tracks.firstIndex { $0.videoId == track.videoId && $0.playlistSetVideoId == track.playlistSetVideoId } ?? -1
    }
}

extension MusicSongSelection {
    /// A click on the first row of `scope` that is `track`.
    @discardableResult
    func click(_ track: Deci.MusicTrack, in scope: MusicSelectionScope, modifiers: MusicSelectionModifiers) -> Outcome {
        click(at: scope.index(of: track), in: scope, modifiers: modifiers)
    }

    /// Whether the first row of `scope` that is `track` is picked.
    func isSelected(_ track: Deci.MusicTrack, in scope: MusicSelectionScope) -> Bool {
        isSelected(at: scope.index(of: track), in: scope)
    }
}

extension MusicSearchNavigation {
    /// The selection's actions that edit the play order, without the two that work on playlists: the queue rules are
    /// what the older tests check, and Save to playlist is on offer whenever YouTube Music can be reached.
    @MainActor
    var queueActions: [MusicSelectionAction] {
        selectionActions.filter { $0 != .saveToPlaylist && $0 != .removeFromPlaylist }
    }
}
