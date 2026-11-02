// DeciTests/Music/MusicSelectionViewRulesTests.swift
// The decisions the selection's views take, pulled out of the views so they are tested without one: what Escape closes
// first, which menu a row shows, the line each bulk action says, the id of a History day, which songs a page lists, and
// what VoiceOver hears of a picked or playing row.

import Foundation
import SwiftUI
import Testing
@testable import Deci

// MARK: - Escape

@MainActor
@Suite("Music popup Escape order")
struct MusicPopupEscapeTests {

    /// Runs the steps with the given answers and notes which were asked, in order.
    private func run(
        selection: Bool, card: Bool, navigation: Bool
    ) -> (step: MusicPopupEscape.Step, asked: [String]) {
        var asked: [String] = []
        let step = MusicPopupEscape.run(
            clearSelection: { asked.append("selection"); return selection },
            closeAccountCard: { asked.append("card"); return card },
            closeNavigation: { asked.append("navigation"); return navigation }
        )
        return (step, asked)
    }

    @Test("A selection is cleared first, and nothing else is asked")
    func selectionFirst() {
        let result = run(selection: true, card: true, navigation: true)
        #expect(result.step == .clearedSelection)
        #expect(result.asked == ["selection"])
    }

    @Test("With no selection the account card closes next, and the navigation is not asked")
    func cardSecond() {
        let result = run(selection: false, card: true, navigation: true)
        #expect(result.step == .closedAccountCard)
        #expect(result.asked == ["selection", "card"])
    }

    @Test("With neither, the navigation closes what it has open")
    func navigationThird() {
        let result = run(selection: false, card: false, navigation: true)
        #expect(result.step == .closedNavigation)
        #expect(result.asked == ["selection", "card", "navigation"])
    }

    @Test("With nothing open the popup itself closes, after every step was asked in order")
    func popupLast() {
        let result = run(selection: false, card: false, navigation: false)
        #expect(result.step == .leavesPopup)
        #expect(result.asked == ["selection", "card", "navigation"])
    }
}

// MARK: - The menu a row shows

@MainActor
@Suite("Music selection row menu")
struct MusicSelectionRowMenuTests {
    private let offered: [MusicSelectionAction] = [.playNext, .addToQueue]

    /// The decision, and how many times the actions were asked for.
    private func menu(
        isSelected: Bool, count: Int, actions: [MusicSelectionAction]
    ) -> (menu: [MusicSelectionAction]?, asked: Int) {
        var asked = 0
        let result = MusicSelectionAction.rowMenu(isSelected: isSelected, count: count) {
            asked += 1
            return actions
        }
        return (result, asked)
    }

    @Test("A picked row in a selection of two or more shows the selection's menu")
    func selectionMenu() {
        #expect(menu(isSelected: true, count: 2, actions: offered).menu == offered)
        #expect(menu(isSelected: true, count: 40, actions: offered).menu == offered)
        let upNext: [MusicSelectionAction] = [.playNext, .addToQueue, .removeFromQueue]
        #expect(menu(isSelected: true, count: 3, actions: upNext).menu == upNext)
    }

    @Test("A row that is not picked keeps its song's menu, whatever is picked elsewhere")
    func unpickedRowKeepsOwnMenu() {
        #expect(menu(isSelected: false, count: 5, actions: offered).menu == nil)
    }

    @Test("One song picked alone keeps the song's own menu")
    func singleSongKeepsOwnMenu() {
        #expect(menu(isSelected: true, count: 1, actions: offered).menu == nil)
        #expect(menu(isSelected: true, count: 0, actions: offered).menu == nil)
    }

    @Test("A selection with nothing to offer falls back to the song's own menu")
    func emptyActionsFallBack() {
        #expect(menu(isSelected: true, count: 3, actions: []).menu == nil)
    }

    @Test("The actions are asked for only when a picked row is in a selection of two or more, and once")
    func actionsAskedLazily() {
        #expect(menu(isSelected: false, count: 9, actions: offered).asked == 0)
        #expect(menu(isSelected: true, count: 1, actions: offered).asked == 0)
        #expect(menu(isSelected: true, count: 2, actions: offered).asked == 1)
        #expect(menu(isSelected: true, count: 2, actions: []).asked == 1)
    }
}

// MARK: - The line each action says

@MainActor
@Suite("Music selection notices")
struct MusicSelectionNoticeTests {

    @Test("Queued behind a song that plays, the lines count the songs and say next")
    func notices() {
        #expect(MusicSelectionAction.playNext.notice(count: 1) == "Playing next")
        #expect(MusicSelectionAction.playNext.notice(count: 3) == "Playing 3 songs next")
        #expect(MusicSelectionAction.addToQueue.notice(count: 1) == "Added to queue")
        #expect(MusicSelectionAction.addToQueue.notice(count: 4) == "Added 4 songs to queue")
        #expect(MusicSelectionAction.removeFromQueue.notice(count: 1) == "Removed from queue")
        #expect(MusicSelectionAction.removeFromQueue.notice(count: 2) == "Removed 2 songs from queue")
    }

    @Test("On an empty queue the first song started, and the line counts every song put, that one too")
    func startedFirst() {
        #expect(MusicSelectionAction.playNext.notice(count: 3, startedFirst: true) == "Playing 3 songs")
        #expect(MusicSelectionAction.playNext.notice(count: 2, startedFirst: true) == "Playing 2 songs")
        #expect(MusicSelectionAction.addToQueue.notice(count: 3, startedFirst: true) == "Added 3 songs to queue")
    }
}

// MARK: - A History day's id

@MainActor
@Suite("Music History day ids")
struct MusicHistoryDayIdTests {
    private func shelf(_ title: String, _ ids: String...) -> MusicShelf {
        MusicShelf(title: title, items: ids.map { .track(MusicSamples.track($0, title: "Song \($0)")) })
    }

    @Test("A day takes its shelf's id: its title and its first song")
    func dayIsShelfId() {
        let shelves = [shelf("Today", "a", "b"), shelf("Yesterday", "c")]
        let days = MusicHistoryView.days(in: shelves)
        #expect(days.map(\.id) == shelves.map(\.id))
        #expect(days.map(\.title) == ["Today", "Yesterday"])
    }

    @Test("Two days YouTube Music titles alike are still two scopes")
    func sameTitleDifferentIds() {
        let days = MusicHistoryView.days(in: [shelf("Today", "a", "b"), shelf("Today", "c", "d")])
        #expect(days.count == 2)
        #expect(days[0].id != days[1].id)
        #expect(days[0].title == days[1].title)
    }

    @Test("A day without a shelf is named by its title")
    func titleWithoutShelf() {
        #expect(MusicHistoryView.Day(title: "Earlier", tracks: []).id == "Earlier")
    }

    @Test("A shelf with no songs makes no day")
    func shelfWithoutSongs() {
        let collections = MusicShelf(title: "Albums", items: [.collection(MusicSamples.collection("MPREb1"))])
        #expect(MusicHistoryView.days(in: [collections, shelf("Today", "a")]).count == 1)
    }
}

// MARK: - The songs a page lists

@MainActor
@Suite("Music page listing")
struct MusicPageListingTests {
    private let tracks: [Deci.MusicTrack] = [
        MusicSamples.track("a", title: "Alpha"),
        MusicSamples.track("b", title: "Beta"),
        MusicSamples.track("c", title: "Alphabet"),
    ]

    @Test("A page is filtered by the field's words, and the answer is the positions of the songs left")
    func filtered() {
        let matches = MusicPageListing.matches(in: tracks, terms: ["alpha"], isArtist: false, orderPending: false)
        #expect(matches == [0, 2])
        let none = MusicPageListing.matches(in: tracks, terms: ["zzz"], isArtist: false, orderPending: false)
        #expect(none == [])
    }

    @Test("No words, an artist page and a list that waits for its order are not filtered")
    func notFiltered() {
        #expect(MusicPageListing.matches(in: tracks, terms: [], isArtist: false, orderPending: false) == nil)
        #expect(MusicPageListing.matches(in: tracks, terms: ["alpha"], isArtist: true, orderPending: false) == nil)
        #expect(MusicPageListing.matches(in: tracks, terms: ["alpha"], isArtist: false, orderPending: true) == nil)
    }

    @Test("The list is every song, the songs that matched, or none while the order is pending")
    func listed() {
        #expect(
            MusicPageListing.listedTracks(tracks, matches: nil, isArtist: false, orderPending: false).map(\.videoId)
                == ["a", "b", "c"]
        )
        #expect(
            MusicPageListing.listedTracks(tracks, matches: [2, 0], isArtist: false, orderPending: false).map(\.videoId)
                == ["c", "a"]
        )
        #expect(MusicPageListing.listedTracks(tracks, matches: [], isArtist: false, orderPending: false).isEmpty)
        #expect(MusicPageListing.listedTracks(tracks, matches: nil, isArtist: false, orderPending: true).isEmpty)
    }

    @Test("An artist's songs are all listed, filter or not")
    func artistListsAll() {
        #expect(
            MusicPageListing.listedTracks(tracks, matches: [1], isArtist: true, orderPending: false).map(\.videoId)
                == ["a", "b", "c"]
        )
    }

    @Test("The rows and the selection's list come from one answer: the listed songs are the matched ones in order")
    func listedFollowsMatches() {
        let terms = MusicLocalSearch.terms(of: "alpha")
        let matches = MusicPageListing.matches(in: tracks, terms: terms, isArtist: false, orderPending: false)
        let listed = MusicPageListing.listedTracks(tracks, matches: matches, isArtist: false, orderPending: false)
        #expect(listed == MusicLocalSearch.filter(tracks, terms: terms))
    }

    @Test("A page of ten thousand songs is filtered once and listed in order")
    func largePage() {
        let many = (0..<10_000).map { MusicSamples.track("v\($0)", title: $0 % 2 == 0 ? "Even \($0)" : "Odd \($0)") }
        let matches = MusicPageListing.matches(in: many, terms: ["even"], isArtist: false, orderPending: false)
        #expect(matches?.count == 5_000)
        let listed = MusicPageListing.listedTracks(many, matches: matches, isArtist: false, orderPending: false)
        #expect(listed.first?.videoId == "v0")
        #expect(listed.last?.videoId == "v9998")
    }
}

// MARK: - What VoiceOver hears

@MainActor
@Suite("Music song row accessibility")
struct MusicSongRowAccessibilityTests {

    @Test("A picked row carries the selected trait, and a row that is not picked carries none")
    func selectedTrait() {
        #expect(MusicSongRowAccessibility.traits(isPicked: true).contains(.isSelected))
        #expect(MusicSongRowAccessibility.traits(isPicked: false) == [])
    }

    @Test("The playing row's value is Now playing, whether or not it is picked, and no other row has one")
    func nowPlayingValue() {
        #expect(MusicSongRowAccessibility.value(isCurrent: true) == "Now playing")
        #expect(MusicSongRowAccessibility.value(isCurrent: false) == "")
    }
}
