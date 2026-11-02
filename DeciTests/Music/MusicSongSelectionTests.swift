// DeciTests/Music/MusicSongSelectionTests.swift
// The rules of selecting songs in a list, as Finder has them: a plain click plays and clears, Cmd toggles a row and
// anchors on it, Shift selects from the anchor to the row and adds it to what is picked, and the anchor stays where it
// was. Pure logic, no view.

import AppKit
import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("MusicSongSelection")
struct MusicSongSelectionTests {

    private func song(_ id: String, setVideoId: String? = nil) -> Deci.MusicTrack {
        MusicSamples.track(id, title: "Song \(id)", setVideoId: setVideoId)
    }

    /// A list of songs a..e under one scope.
    private func scope(
        _ id: String = "page:VLPL1", _ ids: [String] = ["a", "b", "c", "d", "e"], isUpNext: Bool = false
    ) -> MusicSelectionScope {
        MusicSelectionScope(id: id, tracks: ids.map { song($0) }, isUpNext: isUpNext)
    }

    private func ids(_ selection: MusicSongSelection) -> [String] { selection.tracks.map(\.videoId) }

    // MARK: - Plain click

    @Test("A plain click plays the song and leaves nothing selected")
    func plainClickPlaysAndClears() {
        let selection = MusicSongSelection()
        let list = scope()
        #expect(selection.click(song("a"), in: list, modifiers: []) == .play)
        #expect(selection.count == 0)

        _ = selection.click(song("b"), in: list, modifiers: .command)
        _ = selection.click(song("d"), in: list, modifiers: .command)
        #expect(selection.count == 2)

        #expect(selection.click(song("c"), in: list, modifiers: []) == .play)
        #expect(selection.count == 0)
        #expect(selection.isSelected(song("b"), in: list) == false)
    }

    @Test("A plain click drops the anchor, so the next Shift click starts afresh")
    func plainClickDropsAnchor() {
        let selection = MusicSongSelection()
        let list = scope()
        _ = selection.click(song("b"), in: list, modifiers: .command)
        _ = selection.click(song("d"), in: list, modifiers: [])
        _ = selection.click(song("e"), in: list, modifiers: .shift)
        #expect(ids(selection) == ["e"])
    }

    // MARK: - Command click

    @Test("Command click toggles one row and says it handled the click")
    func commandToggles() {
        let selection = MusicSongSelection()
        let list = scope()
        #expect(selection.click(song("b"), in: list, modifiers: .command) == .handled)
        #expect(ids(selection) == ["b"])
        #expect(selection.isSelected(song("b"), in: list))

        #expect(selection.click(song("d"), in: list, modifiers: .command) == .handled)
        #expect(ids(selection) == ["b", "d"])

        _ = selection.click(song("b"), in: list, modifiers: .command)
        #expect(ids(selection) == ["d"])
        #expect(selection.isSelected(song("b"), in: list) == false)
    }

    @Test("Toggling the last selected row off leaves an empty selection")
    func commandToggleToEmpty() {
        let selection = MusicSongSelection()
        let list = scope()
        _ = selection.click(song("b"), in: list, modifiers: .command)
        _ = selection.click(song("b"), in: list, modifiers: .command)
        #expect(selection.count == 0)
        #expect(selection.tracks.isEmpty)
    }

    @Test("Command click sets the anchor to that row, selected or not")
    func commandSetsAnchor() {
        let selection = MusicSongSelection()
        let list = scope()
        _ = selection.click(song("b"), in: list, modifiers: .command)
        _ = selection.click(song("d"), in: list, modifiers: .command)
        // Toggling "d" off moves the anchor to it all the same.
        _ = selection.click(song("d"), in: list, modifiers: .command)
        _ = selection.click(song("e"), in: list, modifiers: .shift)
        #expect(ids(selection) == ["b", "d", "e"])
    }

    // MARK: - Shift click

    @Test("The first Shift click with no anchor selects that row and anchors on it")
    func firstShiftClick() {
        let selection = MusicSongSelection()
        let list = scope()
        #expect(selection.click(song("c"), in: list, modifiers: .shift) == .handled)
        #expect(ids(selection) == ["c"])

        _ = selection.click(song("e"), in: list, modifiers: .shift)
        #expect(ids(selection) == ["c", "d", "e"])
    }

    @Test("Shift click selects the rows from the anchor to the row, both ends in, going down or up")
    func shiftRangeBothWays() {
        let down = MusicSongSelection()
        let list = scope()
        _ = down.click(song("b"), in: list, modifiers: .command)
        _ = down.click(song("d"), in: list, modifiers: .shift)
        #expect(ids(down) == ["b", "c", "d"])

        let up = MusicSongSelection()
        _ = up.click(song("d"), in: list, modifiers: .command)
        _ = up.click(song("b"), in: list, modifiers: .shift)
        #expect(ids(up) == ["b", "c", "d"])
    }

    @Test("A Shift click on the anchor itself selects just that row")
    func shiftOnAnchor() {
        let selection = MusicSongSelection()
        let list = scope()
        _ = selection.click(song("c"), in: list, modifiers: .command)
        _ = selection.click(song("c"), in: list, modifiers: .shift)
        #expect(ids(selection) == ["c"])
    }

    @Test("A range is added to what Command clicks picked, not swapped for it")
    func shiftKeepsCommandPicks() {
        let selection = MusicSongSelection()
        let list = scope("page:VLPL1", ["a", "b", "c", "d", "e", "f", "g"])
        _ = selection.click(song("a"), in: list, modifiers: .command)
        _ = selection.click(song("c"), in: list, modifiers: .command)
        _ = selection.click(song("e"), in: list, modifiers: .shift)
        #expect(ids(selection) == ["a", "c", "d", "e"])
    }

    @Test("The anchor stays put: later Shift clicks measure from the same row and only add")
    func anchorStays() {
        let selection = MusicSongSelection()
        let list = scope("page:VLPL1", ["a", "b", "c", "d", "e", "f"])
        _ = selection.click(song("c"), in: list, modifiers: .shift)
        _ = selection.click(song("e"), in: list, modifiers: .shift)
        #expect(ids(selection) == ["c", "d", "e"])

        // A shorter range from the same anchor takes nothing away.
        _ = selection.click(song("d"), in: list, modifiers: .shift)
        #expect(ids(selection) == ["c", "d", "e"])

        // The other side of the anchor adds to the picked rows.
        _ = selection.click(song("a"), in: list, modifiers: .shift)
        #expect(ids(selection) == ["a", "b", "c", "d", "e"])

        _ = selection.click(song("f"), in: list, modifiers: .shift)
        #expect(ids(selection) == ["a", "b", "c", "d", "e", "f"])
    }

    @Test("Command with Shift counts as Shift")
    func commandShiftIsShift() {
        let selection = MusicSongSelection()
        let list = scope()
        _ = selection.click(song("b"), in: list, modifiers: [.command, .shift])
        #expect(ids(selection) == ["b"])
        _ = selection.click(song("d"), in: list, modifiers: [.command, .shift])
        #expect(ids(selection) == ["b", "c", "d"])
        // Not a toggle: the anchored row stays selected.
        _ = selection.click(song("b"), in: list, modifiers: [.command, .shift])
        #expect(ids(selection) == ["b", "c", "d"])
    }

    @Test("Modifiers are read from the event's flags, and the keys that do not matter are ignored")
    func modifiersFromFlags() {
        #expect(MusicSelectionModifiers(flags: [.shift]) == .shift)
        #expect(MusicSelectionModifiers(flags: [.command]) == .command)
        #expect(MusicSelectionModifiers(flags: [.command, .shift]) == [.command, .shift])
        #expect(MusicSelectionModifiers(flags: [.option, .control, .capsLock]) == [])
        #expect(MusicSelectionModifiers(flags: []).isEmpty)
    }

    // MARK: - Scopes

    @Test("A click in another list replaces the selection and starts from that list's own anchor")
    func scopeSwitchReplaces() {
        let selection = MusicSongSelection()
        let page = scope("page:VLPL1", ["a", "b", "c"])
        let search = scope("search:q", ["a", "x", "y", "z"])
        _ = selection.click(song("a"), in: page, modifiers: .command)
        _ = selection.click(song("c"), in: page, modifiers: .command)
        #expect(selection.scopeId == "page:VLPL1")

        _ = selection.click(song("y"), in: search, modifiers: .command)
        #expect(selection.scopeId == "search:q")
        #expect(ids(selection) == ["y"])
        // "a" is in both lists, but the old pick is gone.
        #expect(selection.isSelected(song("a"), in: search) == false)
        #expect(selection.isSelected(song("a"), in: page) == false)

        // The old list's anchor did not carry over: Shift with the new list's anchor "y".
        _ = selection.click(song("z"), in: search, modifiers: .shift)
        #expect(ids(selection) == ["y", "z"])
    }

    @Test("A Shift click in another list starts there with that row alone")
    func shiftInNewScope() {
        let selection = MusicSongSelection()
        _ = selection.click(song("a"), in: scope("page:VLPL1"), modifiers: .command)
        _ = selection.click(song("d"), in: scope("liked"), modifiers: .shift)
        #expect(selection.scopeId == "liked")
        #expect(ids(selection) == ["d"])
    }

    @Test("A row is selected only in the list the selection is in")
    func selectedInItsScopeOnly() {
        let selection = MusicSongSelection()
        let page = scope("page:VLPL1")
        _ = selection.click(song("a"), in: page, modifiers: .command)
        #expect(selection.isSelected(song("a"), in: page))
        #expect(selection.isSelected(song("a"), in: scope("quickPicks")) == false)
    }

    @Test("The selection knows whether it is in Up next")
    func isUpNext() {
        let selection = MusicSongSelection()
        #expect(selection.isUpNext == false)
        _ = selection.click(song("b"), in: scope("upNext", isUpNext: true), modifiers: .command)
        #expect(selection.isUpNext)
        _ = selection.click(song("b"), in: scope("page:VLPL1"), modifiers: .command)
        #expect(selection.isUpNext == false)
        selection.clear()
        #expect(selection.isUpNext == false)
    }

    @Test("A row the list does not hold changes nothing on a modified click, and still plays on a plain one")
    func unknownRow() {
        let selection = MusicSongSelection()
        let list = scope("page:VLPL1", ["a", "b"])
        _ = selection.click(song("a"), in: list, modifiers: .command)
        #expect(selection.click(song("zzz"), in: list, modifiers: .command) == .handled)
        #expect(selection.click(song("zzz"), in: list, modifiers: .shift) == .handled)
        #expect(ids(selection) == ["a"])
        #expect(selection.click(song("zzz"), in: list, modifiers: []) == .play)
    }

    // MARK: - Sync

    @Test("When rows leave the list the selection drops them")
    func syncDropsVanishedRows() {
        let selection = MusicSongSelection()
        _ = selection.click(song("a"), in: scope(), modifiers: .command)
        _ = selection.click(song("b"), in: scope(), modifiers: .command)
        _ = selection.click(song("d"), in: scope(), modifiers: .command)

        let after = scope("page:VLPL1", ["a", "c", "d", "e"])
        selection.sync(after)
        #expect(ids(selection) == ["a", "d"])
        #expect(selection.count == 2)
        #expect(selection.isSelected(song("a"), in: after))
        #expect(selection.isSelected(song("c"), in: after) == false)
    }

    @Test("When every selected row leaves the list the selection is empty")
    func syncDropsAll() {
        let selection = MusicSongSelection()
        _ = selection.click(song("a"), in: scope(), modifiers: .command)
        selection.sync(scope("page:VLPL1", ["x", "y"]))
        #expect(selection.count == 0)
        #expect(selection.scopeId == nil)
    }

    @Test("An anchor whose row stays in the list stays the anchor")
    func syncKeepsAnchor() {
        let selection = MusicSongSelection()
        _ = selection.click(song("b"), in: scope(), modifiers: .command)
        _ = selection.click(song("d"), in: scope(), modifiers: .command)
        let after = scope("page:VLPL1", ["a", "c", "d", "e"])
        selection.sync(after)
        _ = selection.click(song("e"), in: after, modifiers: .shift)
        #expect(ids(selection) == ["d", "e"])
    }

    @Test("A row Command clicked off last is still the anchor after a sync, so a Shift click ranges from it")
    func syncKeepsAnchorOfEmptySelection() {
        let selection = MusicSongSelection()
        let list = scope()
        _ = selection.click(song("b"), in: list, modifiers: .command)
        _ = selection.click(song("b"), in: list, modifiers: .command)
        #expect(selection.count == 0)

        selection.sync(list)
        #expect(selection.scopeId == "page:VLPL1")
        _ = selection.click(song("d"), in: list, modifiers: .shift)
        #expect(ids(selection) == ["b", "c", "d"])
    }

    @Test("With nothing picked and the anchor row gone from the list, a sync forgets the list")
    func syncDropsEmptyAnchorThatLeft() {
        let selection = MusicSongSelection()
        _ = selection.click(song("b"), in: scope(), modifiers: .command)
        _ = selection.click(song("b"), in: scope(), modifiers: .command)

        selection.sync(scope("page:VLPL1", ["a", "c"]))
        #expect(selection.scopeId == nil)
        #expect(selection.count == 0)
    }

    @Test("When the anchor row leaves the list the next Shift click starts afresh")
    func syncDropsAnchor() {
        let selection = MusicSongSelection()
        _ = selection.click(song("b"), in: scope(), modifiers: .command)
        _ = selection.click(song("d"), in: scope(), modifiers: .command)
        let after = scope("page:VLPL1", ["a", "b", "c", "e"])
        selection.sync(after)
        _ = selection.click(song("e"), in: after, modifiers: .shift)
        #expect(ids(selection) == ["b", "e"])
    }

    @Test("A list that reorders keeps the selection and gives it back in the new order")
    func syncKeepsRowsWhenReordered() {
        let selection = MusicSongSelection()
        _ = selection.click(song("a"), in: scope(), modifiers: .command)
        _ = selection.click(song("c"), in: scope(), modifiers: .command)
        selection.sync(scope("page:VLPL1", ["e", "c", "b", "a"]))
        #expect(ids(selection) == ["c", "a"])
    }

    @Test("A sync for another list does nothing")
    func syncOtherScopeIgnored() {
        let selection = MusicSongSelection()
        _ = selection.click(song("a"), in: scope(), modifiers: .command)
        selection.sync(scope("quickPicks", ["x"]))
        #expect(ids(selection) == ["a"])
        #expect(selection.scopeId == "page:VLPL1")
    }

    @Test("A sync with nothing selected stays empty")
    func syncEmpty() {
        let selection = MusicSongSelection()
        selection.sync(scope())
        #expect(selection.count == 0)
        #expect(selection.scopeId == nil)
    }

    @Test("A list ending clears the selection that sits in it, and only that one")
    func scopeEnded() {
        let selection = MusicSongSelection()
        _ = selection.click(song("a"), in: scope("liked"), modifiers: .command)
        selection.scopeEnded("quickPicks")
        #expect(selection.count == 1)
        selection.scopeEnded("liked")
        #expect(selection.count == 0)
        #expect(selection.scopeId == nil)
    }

    // MARK: - Redraws

    /// Whether anything `read` looked at changed while `work` ran.
    private func changes(reading read: () -> Void, during work: () -> Void) -> Bool {
        let flag = ChangeFlag()
        withObservationTracking(read) { flag.raise() }
        work()
        return flag.raised
    }

    @Test("A sync that changes nothing writes nothing a row reads")
    func unchangedSyncIsQuiet() {
        let selection = MusicSongSelection()
        let list = scope()
        _ = selection.click(song("b"), in: list, modifiers: .command)
        _ = selection.click(song("d"), in: list, modifiers: .command)

        let changed = changes(
            reading: {
                _ = selection.scopeId
                _ = selection.isUpNext
                _ = selection.tracks
                _ = selection.count
                _ = selection.isSelected(song("b"), in: list)
            },
            during: {
                selection.sync(list)
                selection.sync(scope())
            }
        )
        #expect(changed == false)
    }

    @Test("A click in the list the selection is in leaves the rows of every other list alone")
    func otherListRowsStayQuiet() {
        let selection = MusicSongSelection()
        let page = scope()
        let other = scope("search:q", ["a", "b", "c"])
        _ = selection.click(song("a"), in: page, modifiers: .command)

        let changed = changes(
            reading: { _ = selection.isSelected(song("a"), in: other) },
            during: {
                _ = selection.click(song("c"), in: page, modifiers: .command)
                _ = selection.click(song("e"), in: page, modifiers: .shift)
                selection.sync(scope("page:VLPL1", ["a", "b", "c", "x", "e"]))
            }
        )
        #expect(changed == false)

        // The list itself changing is what they do hear about.
        let heard = changes(
            reading: { _ = selection.isSelected(song("a"), in: other) },
            during: { _ = selection.click(song("a"), in: other, modifiers: .command) }
        )
        #expect(heard)
    }

    @Test("A plain click with nothing selected writes nothing")
    func plainClickOnEmptyIsQuiet() {
        let selection = MusicSongSelection()
        let list = scope()
        let changed = changes(
            reading: {
                _ = selection.scopeId
                _ = selection.count
            },
            during: { _ = selection.click(song("a"), in: list, modifiers: []) }
        )
        #expect(changed == false)
        #expect(selection.revision == 0)
    }

    @Test("The revision moves when the picked songs or the list kind do, and only then")
    func revisionMoves() {
        let selection = MusicSongSelection()
        let list = scope()
        #expect(selection.revision == 0)

        _ = selection.click(song("b"), in: list, modifiers: .command)
        let afterPick = selection.revision
        #expect(afterPick > 0)

        // Nothing changed: a sync, and a Shift click inside what is picked already.
        selection.sync(list)
        _ = selection.click(song("b"), in: list, modifiers: .shift)
        #expect(selection.revision == afterPick)

        _ = selection.click(song("d"), in: list, modifiers: .command)
        #expect(selection.revision > afterPick)

        let afterSecond = selection.revision
        selection.clear()
        #expect(selection.revision > afterSecond)
        let afterClear = selection.revision
        selection.clear()
        #expect(selection.revision == afterClear)
    }

    @Test("Moving between Up next and another list moves the revision, with the same songs picked")
    func revisionFollowsUpNext() {
        let selection = MusicSongSelection()
        _ = selection.click(song("b"), in: scope("page:VLPL1"), modifiers: .command)
        let before = selection.revision
        selection.sync(scope("page:VLPL1", isUpNext: true))
        #expect(selection.isUpNext)
        #expect(selection.revision > before)
    }

    // MARK: - Output

    @Test("The selected songs come out in list order, whatever order they were picked in")
    func listOrder() {
        let selection = MusicSongSelection()
        let list = scope()
        _ = selection.click(song("d"), in: list, modifiers: .command)
        _ = selection.click(song("a"), in: list, modifiers: .command)
        _ = selection.click(song("c"), in: list, modifiers: .command)
        #expect(ids(selection) == ["a", "c", "d"])
    }

    @Test("Rows are told apart by their playlist item id, so the same song twice is two rows but one song to queue")
    func duplicateSongsDifferentSetIds() {
        let selection = MusicSongSelection()
        let rows = [song("a", setVideoId: "s1"), song("b", setVideoId: "s2"), song("a", setVideoId: "s3"), song("c", setVideoId: "s4")]
        let list = MusicSelectionScope(id: "page:VLPL1", tracks: rows, isUpNext: false)

        _ = selection.click(at: 0, in: list, modifiers: .command)
        #expect(selection.isSelected(at: 0, in: list))
        #expect(selection.isSelected(at: 2, in: list) == false)

        _ = selection.click(at: 2, in: list, modifiers: .command)
        #expect(selection.isSelected(at: 2, in: list))
        // The song is queued once, at its first row.
        #expect(selection.tracks.map(\.playlistSetVideoId) == ["s1"])
        #expect(selection.count == 1)
    }

    /// A History day: the same song replayed, with nothing but its place to tell the copies apart.
    private var replays: MusicSelectionScope {
        MusicSelectionScope(id: "history:day", tracks: ["a", "b", "c", "a", "d", "e"].map { song($0) }, isUpNext: false)
    }

    @Test("Clicking the second copy of a song picks that row alone, and the first copy stays untinted")
    func secondCopyIsItsOwnRow() {
        let selection = MusicSongSelection()
        let list = replays

        _ = selection.click(at: 3, in: list, modifiers: .command)
        #expect(selection.isSelected(at: 3, in: list))
        #expect(selection.isSelected(at: 0, in: list) == false)
        #expect(ids(selection) == ["a"])
        #expect(selection.count == 1)

        // Clicking it again takes that row off, and the other copy was never in.
        _ = selection.click(at: 3, in: list, modifiers: .command)
        #expect(selection.isSelected(at: 3, in: list) == false)
        #expect(selection.count == 0)
    }

    @Test("A Shift click after the second copy ranges from that row, not from the first copy of the song")
    func shiftRangesFromTheSecondCopy() {
        let selection = MusicSongSelection()
        let list = replays

        _ = selection.click(at: 3, in: list, modifiers: .command)
        _ = selection.click(at: 5, in: list, modifiers: .shift)
        #expect(ids(selection) == ["a", "d", "e"])
        #expect(selection.count == 3)
        #expect(selection.isSelected(at: 4, in: list))
        // Rows 0 to 2 lie above the anchor: none of them is in the range.
        #expect(selection.isSelected(at: 0, in: list) == false)
        #expect(selection.isSelected(at: 1, in: list) == false)
        #expect(selection.isSelected(at: 2, in: list) == false)
    }

    @Test("Shift on the second copy anchors on it, and a range up from there stops at the row it was clicked on")
    func firstShiftOnSecondCopy() {
        let selection = MusicSongSelection()
        let list = replays

        _ = selection.click(at: 3, in: list, modifiers: .shift)
        #expect(selection.isSelected(at: 3, in: list))
        #expect(selection.isSelected(at: 0, in: list) == false)

        _ = selection.click(at: 1, in: list, modifiers: .shift)
        #expect(ids(selection) == ["b", "c", "a"])
        #expect(selection.count == 3)
    }

    @Test("Both copies picked are two rows tinted, one song counted and queued once")
    func bothCopiesCountOnce() {
        let selection = MusicSongSelection()
        let list = replays

        _ = selection.click(at: 0, in: list, modifiers: .command)
        _ = selection.click(at: 3, in: list, modifiers: .command)
        #expect(selection.isSelected(at: 0, in: list))
        #expect(selection.isSelected(at: 3, in: list))
        #expect(selection.count == 1)
        #expect(ids(selection) == ["a"])

        // Taking one copy off leaves the song picked through the other row.
        _ = selection.click(at: 0, in: list, modifiers: .command)
        #expect(selection.isSelected(at: 0, in: list) == false)
        #expect(selection.isSelected(at: 3, in: list))
        #expect(selection.count == 1)
    }

    @Test("A click on a row index the list does not have changes nothing")
    func indexOutOfRange() {
        let selection = MusicSongSelection()
        let list = scope("page:VLPL1", ["a", "b"])
        _ = selection.click(at: 0, in: list, modifiers: .command)
        #expect(selection.click(at: 2, in: list, modifiers: .command) == .handled)
        #expect(selection.click(at: -1, in: list, modifiers: .shift) == .handled)
        #expect(ids(selection) == ["a"])
        #expect(selection.isSelected(at: 5, in: list) == false)
        #expect(selection.click(at: 9, in: list, modifiers: []) == .play)
    }

    @Test("A row's key is its playlist item id, else its song and which copy of it that is")
    func scopeKeys() {
        let plain = MusicSelectionScope(id: "x", tracks: ["a", "b", "a", "a", "b"].map { song($0) }, isUpNext: false)
        #expect(plain.keys == ["a#0", "b#0", "a#1", "a#2", "b#1"])

        let withSetIds = MusicSelectionScope(
            id: "x", tracks: [song("a", setVideoId: "s1"), song("b"), song("a", setVideoId: "s3"), song("b")], isUpNext: false
        )
        #expect(withSetIds.keys == ["s1", "b#0", "s3", "b#1"])

        #expect(MusicSelectionScope(id: "x", tracks: [], isUpNext: false).keys.isEmpty)
    }

    // MARK: - Clear

    @Test("Clear empties the selection and forgets the anchor and the list")
    func clearForgetsEverything() {
        let selection = MusicSongSelection()
        let list = scope()
        _ = selection.click(song("b"), in: list, modifiers: .command)
        _ = selection.click(song("d"), in: list, modifiers: .command)
        selection.clear()

        #expect(selection.count == 0)
        #expect(selection.tracks.isEmpty)
        #expect(selection.scopeId == nil)
        #expect(selection.isSelected(song("b"), in: list) == false)

        _ = selection.click(song("e"), in: list, modifiers: .shift)
        #expect(ids(selection) == ["e"])
    }

    @Test("Clearing an empty selection is harmless")
    func clearEmpty() {
        let selection = MusicSongSelection()
        selection.clear()
        #expect(selection.count == 0)
    }

    // MARK: - Large lists

    @Test("A range over a long list is correct and quick")
    func largeList() {
        let selection = MusicSongSelection()
        let rows = (0..<10_000).map { song("v\($0)") }
        let list = MusicSelectionScope(id: "history", tracks: rows, isUpNext: false)
        _ = selection.click(rows[10], in: list, modifiers: .command)
        _ = selection.click(rows[9_990], in: list, modifiers: .shift)
        #expect(selection.count == 9_981)
        #expect(selection.tracks.first?.videoId == "v10")
        #expect(selection.tracks.last?.videoId == "v9990")
    }

    @Test("Songs with Unicode and emoji ids select like any other")
    func unicodeIds() {
        let selection = MusicSongSelection()
        let rows = [song("日本語"), song("🎵"), song("a'b\"; DROP")]
        let list = MusicSelectionScope(id: "search:日本語 🎵", tracks: rows, isUpNext: false)
        _ = selection.click(rows[0], in: list, modifiers: .command)
        _ = selection.click(rows[2], in: list, modifiers: .shift)
        #expect(selection.count == 3)
    }
}

// MARK: - Which actions the selection offers

@MainActor
@Suite("MusicSelectionAction rules")
struct MusicSelectionActionTests {
    private func song(_ id: String) -> Deci.MusicTrack { MusicSamples.track(id, title: "Song \(id)") }

    @Test("Play next and Add to queue are offered for any selection, and Remove from queue only in Up next")
    func offered() {
        let tracks = [song("a"), song("b")]
        #expect(MusicSelectionAction.available(for: tracks, isUpNext: false, playing: nil) == [.playNext, .addToQueue])
        #expect(
            MusicSelectionAction.available(for: tracks, isUpNext: true, playing: nil)
                == [.playNext, .addToQueue, .removeFromQueue]
        )
    }

    @Test("The queue entries need a selected song other than the one that plays")
    func currentSongOnly() {
        let playing = song("a")
        #expect(MusicSelectionAction.available(for: [playing], isUpNext: false, playing: playing).isEmpty)
        #expect(MusicSelectionAction.available(for: [playing], isUpNext: true, playing: playing).isEmpty)
        #expect(
            MusicSelectionAction.available(for: [playing, song("b")], isUpNext: false, playing: playing)
                == [.playNext, .addToQueue]
        )
    }

    @Test("Nothing selected offers nothing")
    func empty() {
        #expect(MusicSelectionAction.available(for: [], isUpNext: true, playing: nil).isEmpty)
    }

    @Test("A menu item names the number of songs, and the bar's button does not")
    func titles() {
        #expect(MusicSelectionAction.playNext.menuTitle(count: 3) == "Play next (3)")
        #expect(MusicSelectionAction.addToQueue.menuTitle(count: 12) == "Add to queue (12)")
        #expect(MusicSelectionAction.removeFromQueue.menuTitle(count: 2) == "Remove from queue (2)")
        #expect(MusicSelectionAction.playNext.title == "Play next")
        #expect(MusicSelectionAction.addToQueue.title == "Add to queue")
        #expect(MusicSelectionAction.removeFromQueue.title == "Remove from queue")
    }

    @Test("The menu puts the queue entries in one block and Remove from queue in the next")
    func menuBlocks() {
        #expect(MusicSelectionAction.groups(of: [.playNext, .addToQueue]) == [[.playNext, .addToQueue]])
        #expect(
            MusicSelectionAction.groups(of: [.playNext, .addToQueue, .removeFromQueue])
                == [[.playNext, .addToQueue], [.removeFromQueue]]
        )
        #expect(MusicSelectionAction.groups(of: [.removeFromQueue]) == [[.removeFromQueue]])
        #expect(MusicSelectionAction.groups(of: []).isEmpty)
    }

    @Test("The bar's count reads as N selected")
    func barCount() {
        #expect(MusicSelectionBarText.count(1) == "1 selected")
        #expect(MusicSelectionBarText.count(24) == "24 selected")
    }
}

/// Set by an observation callback, which is `@Sendable`, so a plain variable cannot be captured.
nonisolated private final class ChangeFlag: @unchecked Sendable {
    private(set) var raised = false
    func raise() { raised = true }
}
