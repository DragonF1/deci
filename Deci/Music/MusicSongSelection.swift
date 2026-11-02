// Deci/Music/MusicSongSelection.swift
import AppKit
import Foundation
import Observation

/// One list of song rows a selection can live in: a page, the results, Liked, Up next. The id names the list and the
/// tracks are its rows in the order they are shown, so a range knows what lies between two rows.
///
/// Each row has a key that tells it from every other row of the list: its playlist item id when it has one (a playlist
/// can list a song twice), else its song and which copy of the song it is, counting from the top (History replays one
/// song again and again). The key is never the song alone, or every copy would be picked with one.
struct MusicSelectionScope: Equatable, Sendable {
    let id: String
    let tracks: [MusicTrack]
    /// The rows are Up next's, so the selection also offers Remove from queue.
    let isUpNext: Bool
    /// The key of each row, in the order of `tracks`.
    let keys: [String]

    init(id: String, tracks: [MusicTrack], isUpNext: Bool) {
        self.id = id
        self.tracks = tracks
        self.isUpNext = isUpNext
        var copies: [String: Int] = [:]
        keys = tracks.map { track in
            if let setVideoId = track.playlistSetVideoId { return setVideoId }
            let copy = copies[track.videoId, default: 0]
            copies[track.videoId] = copy + 1
            return "\(track.videoId)#\(copy)"
        }
    }
}

/// The keys of a click that matter to a selection. Command with Shift reads as Shift.
struct MusicSelectionModifiers: OptionSet, Sendable {
    let rawValue: Int

    static let shift = MusicSelectionModifiers(rawValue: 1 << 0)
    static let command = MusicSelectionModifiers(rawValue: 1 << 1)

    init(rawValue: Int) {
        self.rawValue = rawValue
    }

    init(flags: NSEvent.ModifierFlags) {
        var modifiers: MusicSelectionModifiers = []
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.command) { modifiers.insert(.command) }
        self = modifiers
    }
}

/// The songs picked in one list of rows, Finder's way. A plain click plays and clears; Command toggles a row and anchors
/// on it; Shift picks everything from the anchor to the row and adds it to what is picked, and the anchor stays where it
/// is. The rules live here, not in the rows, so they are tested without a view.
///
/// A row is told apart by its key (see `MusicSelectionScope`), and the row says which one it is by its place in the
/// list. What the actions get is `tracks`: the picked songs in list order, each song once, so two picked copies of a song
/// are one song to queue.
@MainActor
@Observable
final class MusicSongSelection {
    enum Outcome: Equatable {
        /// The click was a plain one: the row plays as it always did.
        case play
        /// The selection took the click.
        case handled
    }

    /// The list the picks are in; nil while nothing has been picked and no row is the anchor.
    private(set) var scopeId: String?
    /// The picks are in Up next.
    private(set) var isUpNext = false
    /// The picked songs in list order, each once.
    private(set) var tracks: [MusicTrack] = []
    private var keys: Set<String> = []

    /// Moves whenever `tracks` or `isUpNext` does, so what is worked out from them can be kept until it does. Not
    /// observed: a view that reads `tracks` already redraws with it.
    @ObservationIgnored private(set) var revision = 0

    @ObservationIgnored private var rows: [MusicTrack] = []
    @ObservationIgnored private var rowKeys: [String] = []
    @ObservationIgnored private var anchor: String?

    /// How many songs are picked.
    var count: Int { tracks.count }

    /// Every picked row in list order. `tracks` holds each song once, but a playlist can list a song twice and take out
    /// each row on its own, so the removal from the open playlist works from the rows.
    var pickedRows: [MusicTrack] {
        rowKeys.indices.filter { keys.contains(rowKeys[$0]) }.map { rows[$0] }
    }

    /// Whether row `index` of `scope` is picked. Only when the picks are in that list, so the same song in another list on
    /// screen is not tinted. A row of another list reads nothing but `scopeId`, so it redraws only when the list changes.
    func isSelected(at index: Int, in scope: MusicSelectionScope) -> Bool {
        guard scope.id == scopeId, scope.keys.indices.contains(index) else { return false }
        return keys.contains(scope.keys[index])
    }

    /// A click on row `index` of `scope`. A plain click clears the selection and leaves the playing to the caller.
    func click(at index: Int, in scope: MusicSelectionScope, modifiers: MusicSelectionModifiers) -> Outcome {
        guard modifiers.contains(.shift) || modifiers.contains(.command) else {
            clear()
            return .play
        }
        guard scope.keys.indices.contains(index) else { return .handled }
        enter(scope)
        let key = scope.keys[index]

        if modifiers.contains(.shift) {
            extend(to: index)
        } else {
            if keys.contains(key) { keys.remove(key) } else { keys.insert(key) }
            anchor = key
        }
        refresh()
        return .handled
    }

    /// The list changed under the selection: rows that left it leave the selection, and an anchor that left is forgotten.
    /// An anchor that is still there stays, even with nothing picked (the last row was Command clicked off). A list the
    /// selection is not in is none of its business.
    func sync(_ scope: MusicSelectionScope) {
        guard scope.id == scopeId else { return }
        rows = scope.tracks
        rowKeys = scope.keys
        if isUpNext != scope.isUpNext {
            isUpNext = scope.isUpNext
            revision += 1
        }
        let present = Set(scope.keys)
        let kept = keys.intersection(present)
        if kept.count != keys.count { keys = kept }
        if let anchor, !present.contains(anchor) { self.anchor = nil }
        if keys.isEmpty, anchor == nil { reset() } else { refresh() }
    }

    /// The list is gone from the screen: a selection that was in it goes with it. A list scrolled out of a lazy stack is
    /// not gone, and does not call this.
    func scopeEnded(_ id: String) {
        guard scopeId == id else { return }
        clear()
    }

    func clear() {
        guard scopeId != nil || !keys.isEmpty || !tracks.isEmpty || anchor != nil else { return }
        reset()
    }

    // MARK: - Private

    /// Takes `scope` as the list the selection is in. Each stored value is written only when it differs: rows of the
    /// other lists on screen read `scopeId` and must not redraw for a click that leaves it as it was.
    private func enter(_ scope: MusicSelectionScope) {
        if scopeId != scope.id {
            if !keys.isEmpty { keys = [] }
            anchor = nil
            scopeId = scope.id
        }
        if isUpNext != scope.isUpNext {
            isUpNext = scope.isUpNext
            revision += 1
        }
        rows = scope.tracks
        rowKeys = scope.keys
    }

    private func extend(to index: Int) {
        if let anchor, let anchorIndex = rowKeys.firstIndex(of: anchor) {
            let range = Set(rowKeys[min(anchorIndex, index)...max(anchorIndex, index)])
            if !keys.isSuperset(of: range) { keys.formUnion(range) }
        } else {
            keys.insert(rowKeys[index])
            anchor = rowKeys[index]
        }
    }

    private func refresh() {
        var seen: Set<String> = []
        var picked: [MusicTrack] = []
        for (index, key) in rowKeys.enumerated() where keys.contains(key) && seen.insert(rows[index].videoId).inserted {
            picked.append(rows[index])
        }
        if picked != tracks {
            tracks = picked
            revision += 1
        }
    }

    private func reset() {
        if scopeId != nil { scopeId = nil }
        if isUpNext {
            isUpNext = false
            revision += 1
        }
        if !keys.isEmpty { keys = [] }
        if !tracks.isEmpty {
            tracks = []
            revision += 1
        }
        rows = []
        rowKeys = []
        anchor = nil
    }
}

/// What a selection of songs can do, each in its `group` so the bar and the menu keep a single song's blocks.
enum MusicSelectionAction: Hashable, Sendable {
    case playNext
    case addToQueue
    case saveToPlaylist
    /// Takes the picked rows out of the playlist that is open, which is the user's own.
    case removeFromPlaylist
    case removeFromQueue

    /// The bar's button.
    var title: String {
        switch self {
        case .playNext: MusicTrackAction.playNext.title
        case .addToQueue: MusicTrackAction.addToQueue.title
        case .saveToPlaylist: MusicTrackAction.saveToPlaylist.title
        case .removeFromPlaylist: "Remove from this playlist"
        case .removeFromQueue: MusicTrackAction.removeFromQueue.title
        }
    }

    /// The menu's item, which says how many songs it is for.
    func menuTitle(count: Int) -> String {
        "\(title) (\(count))"
    }

    /// The block of the menu the action sits in, the same blocks as a single song's menu.
    var group: MusicTrackAction.Group {
        switch self {
        case .playNext, .addToQueue: .queue
        case .saveToPlaylist: .library
        case .removeFromPlaylist, .removeFromQueue: .remove
        }
    }

    /// The short line that says what the action did, for `count` songs. `startedFirst` is a put on an empty queue: the
    /// first song began to play instead of waiting, and `count` is every song of the put, that one too.
    /// The two playlist actions answer with the playlist's name, so the store words those (`MusicSelectionPlaylistText`);
    /// their lines here are the same without a name.
    func notice(count: Int, startedFirst: Bool = false) -> String {
        switch (self, count) {
        case (.saveToPlaylist, _): "Added \(count) songs to playlist"
        case (.removeFromPlaylist, _): "Removed \(count) songs from playlist"
        case (.playNext, _) where startedFirst: "Playing \(count) songs"
        case (.addToQueue, _) where startedFirst: "Added \(count) songs to queue"
        case (.playNext, 1): "Playing next"
        case (.playNext, _): "Playing \(count) songs next"
        case (.addToQueue, 1): "Added to queue"
        case (.addToQueue, _): "Added \(count) songs to queue"
        case (.removeFromQueue, 1): "Removed from queue"
        case (.removeFromQueue, _): "Removed \(count) songs from queue"
        }
    }

    /// What a row's menu offers when the row is picked: the selection's actions, in place of its own song's menu. nil
    /// keeps the song's menu: the row is not picked, one song alone is picked (the menu is still that song's), or the
    /// selection has nothing to offer. `actions` is asked only when it matters, as working it out is not free.
    static func rowMenu(
        isSelected: Bool, count: Int, actions: () -> [MusicSelectionAction]
    ) -> [MusicSelectionAction]? {
        guard isSelected, count >= 2 else { return nil }
        let offered = actions()
        return offered.isEmpty ? nil : offered
    }

    /// The actions in blocks, a line between two blocks, as a single song's menu draws them.
    static func groups(of actions: [MusicSelectionAction]) -> [[MusicSelectionAction]] {
        var groups: [[MusicSelectionAction]] = []
        var last: MusicTrackAction.Group?
        for action in actions {
            if action.group == last {
                groups[groups.count - 1].append(action)
            } else {
                groups.append([action])
                last = action.group
            }
        }
        return groups
    }

    /// What `tracks` offer, in menu order. The queue entries need a song other than the one in the player (a single song's
    /// menu says the same). `limited` is a Music tab with only this Mac to work with: Play next and Add to queue then need
    /// a song that `playsOffline`, and Remove from queue stays. The playlist entries need YouTube Music, which the caller
    /// says it can reach with `savesToPlaylists`: Save to playlist then goes with any picked song, and Remove from this
    /// playlist with `removableFromPlaylist` rows of the open, editable playlist (0 leaves it out).
    static func available(
        for tracks: [MusicTrack], isUpNext: Bool, playing: MusicTrack?, limited: Bool = false,
        savesToPlaylists: Bool = false, removableFromPlaylist: Int = 0,
        playsOffline: (MusicTrack) -> Bool = { _ in false }
    ) -> [MusicSelectionAction] {
        guard !tracks.isEmpty else { return [] }
        let others = tracks.filter { $0.videoId != playing?.videoId }
        var actions: [MusicSelectionAction] = []
        if !others.isEmpty, !limited || others.contains(where: playsOffline) { actions += [.playNext, .addToQueue] }
        if savesToPlaylists { actions.append(.saveToPlaylist) }
        if savesToPlaylists, removableFromPlaylist > 0 { actions.append(.removeFromPlaylist) }
        if !others.isEmpty, isUpNext { actions.append(.removeFromQueue) }
        return actions
    }
}

/// The words of the selection bar.
enum MusicSelectionBarText {
    static func count(_ count: Int) -> String {
        "\(count) selected"
    }
}
