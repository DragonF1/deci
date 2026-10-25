// DeciTests/Music/MusicCollectionSyncRulesTests.swift
// When a sync may delete a song. The page has stopped listing it is not proof the song left the playlist: YouTube greys
// rows out, drops podcast episodes, and sometimes returns fewer songs than the header says. These rules turn what a
// page read found into the list to store and the songs to delete now, holding a big drop back until a later read agrees.

import Foundation
import Testing
@testable import Deci

@Suite("MusicCollectionSyncRules")
struct MusicCollectionSyncRulesTests {
    private typealias Held = MusicDownloadStore.Collection.HeldDrop

    private let start = Date(timeIntervalSince1970: 1_000_000)
    private let hour: TimeInterval = 3_600

    private func ids(_ range: ClosedRange<Int>) -> [String] { range.map(DownloadSamples.id) }
    private func ids(_ numbers: Int...) -> [String] { numbers.map(DownloadSamples.id) }

    private func decide(
        stored: [String], playable: [String], unavailable: [String] = [], stated: Int? = nil, held: Held? = nil,
        at time: Date? = nil
    ) -> MusicCollectionSyncRules.Decision? {
        MusicCollectionSyncRules.decide(
            stored: stored, playable: playable, unavailable: unavailable, statedCount: stated, held: held,
            now: time ?? start
        )
    }

    // MARK: - Small removals

    @Test("a small removal deletes at once and the order is the page's")
    func smallRemovalDeletesAtOnce() throws {
        let stored = ids(1...20)
        let playable = stored.filter { $0 != DownloadSamples.id(3) }

        let decision = try #require(decide(stored: stored, playable: playable))

        #expect(decision.deleteNow == ids(3))
        #expect(decision.held == nil)
        #expect(decision.order == playable)
        #expect(decision.isComplete)
    }

    @Test("a page with no songs decides nothing: an empty list is never every song gone")
    func emptyPageDecidesNothing() {
        #expect(decide(stored: ids(1...3), playable: []) == nil)
        #expect(decide(stored: ids(1...3), playable: [], unavailable: ids(1...3)) == nil)
    }

    @Test("five songs gone is small whatever the size of the list, and six of twenty is not")
    func fiveIsTheFloor() throws {
        let stored = ids(1...20)

        let five = try #require(decide(stored: stored, playable: ids(6...20)))
        #expect(five.deleteNow == ids(1...5))
        #expect(five.held == nil)

        let six = try #require(decide(stored: stored, playable: ids(7...20)))
        #expect(six.deleteNow.isEmpty)
        #expect(six.held?.videoIds == ids(1...6))
    }

    @Test("ten percent of the stored list is small once the list is long")
    func tenPercent() throws {
        let stored = ids(1...100)

        let ten = try #require(decide(stored: stored, playable: ids(11...100)))
        #expect(ten.deleteNow == ids(1...10))

        let eleven = try #require(decide(stored: stored, playable: ids(12...100)))
        #expect(eleven.deleteNow.isEmpty)
        #expect(eleven.held?.videoIds == ids(1...11))
    }

    @Test("new songs go in at the page's place, and the songs of a small drop leave the order")
    func additionsFollowThePage() throws {
        let decision = try #require(decide(stored: ids(1, 2, 3), playable: ids(9, 1, 3, 8)))

        #expect(decision.order == ids(9, 1, 3, 8))
        #expect(decision.deleteNow == ids(2))
    }

    // MARK: - Big drops

    @Test("a big drop is held: nothing is deleted, every song stays in the list, and the time is recorded")
    func bigDropIsHeld() throws {
        let stored = ids(1...20)
        let playable = ids(9...20)

        let decision = try #require(decide(stored: stored, playable: playable))

        #expect(decision.deleteNow.isEmpty)
        #expect(decision.held == Held(videoIds: ids(1...8), since: start))
        #expect(Set(decision.order) == Set(stored))
        #expect(decision.isComplete)
    }

    @Test("a held drop is applied by a later complete read at least an hour after the first, which still misses the songs")
    func heldDropIsAppliedLater() throws {
        let stored = ids(1...20)
        let held = Held(videoIds: ids(1...8), since: start)

        let decision = try #require(decide(
            stored: stored, playable: ids(9...20), held: held, at: start.addingTimeInterval(hour)
        ))

        #expect(decision.deleteNow == ids(1...8))
        #expect(decision.held == nil)
        #expect(decision.order == ids(9...20))
    }

    @Test("a held drop waits while the first read is less than an hour old, and keeps its first time")
    func heldDropWaits() throws {
        let stored = ids(1...20)
        let held = Held(videoIds: ids(1...8), since: start)

        let decision = try #require(decide(
            stored: stored, playable: ids(9...20), held: held, at: start.addingTimeInterval(hour - 1)
        ))

        #expect(decision.deleteNow.isEmpty)
        #expect(decision.held == held)
    }

    @Test("songs that come back cancel their part of the held drop, and the rest keeps waiting")
    func comingBackShrinksTheHold() throws {
        let stored = ids(1...20)
        let held = Held(videoIds: ids(1...8), since: start)

        // Songs 1 and 2 are listed again: six are still missing, which is still a big drop.
        let decision = try #require(decide(
            stored: stored, playable: ids(1, 2) + ids(9...20), held: held, at: start.addingTimeInterval(hour * 2)
        ))

        #expect(decision.deleteNow == ids(3...8))
        #expect(decision.held == nil)
        #expect(Set(decision.order) == Set(ids(1, 2) + ids(9...20)))
    }

    @Test("a hold younger than an hour loses the songs that came back and keeps the first time for the rest")
    func youngHoldShrinks() throws {
        let stored = ids(1...20)
        let held = Held(videoIds: ids(1...8), since: start)

        let decision = try #require(decide(
            stored: stored, playable: ids(1) + ids(9...20) + ids(2), held: held, at: start.addingTimeInterval(600)
        ))

        #expect(decision.deleteNow.isEmpty)
        #expect(decision.held == Held(videoIds: ids(3...8), since: start))
        #expect(Set(decision.order) == Set(stored))
    }

    @Test("a hold is cancelled when every held song is listed again")
    func holdCancelled() throws {
        let stored = ids(1...20)
        let held = Held(videoIds: ids(1...8), since: start)

        let decision = try #require(decide(
            stored: stored, playable: stored, held: held, at: start.addingTimeInterval(hour * 3)
        ))

        #expect(decision.deleteNow.isEmpty)
        #expect(decision.held == nil)
        #expect(decision.order == stored)
    }

    @Test("a small removal after a hold deletes at once and clears the hold")
    func smallRemovalClearsHold() throws {
        let stored = ids(1...20)
        let held = Held(videoIds: ids(1...8), since: start)

        // Everything but song 4 is back.
        let decision = try #require(decide(
            stored: stored, playable: stored.filter { $0 != DownloadSamples.id(4) }, held: held,
            at: start.addingTimeInterval(60)
        ))

        #expect(decision.deleteNow == ids(4))
        #expect(decision.held == nil)
    }

    @Test("songs that went missing after the hold began start a hold of their own, and are not deleted with the first")
    func newMissesAreHeldSeparately() throws {
        let stored = ids(1...30)
        let held = Held(videoIds: ids(1...10), since: start)
        let later = start.addingTimeInterval(hour)

        // 1...10 are still missing, and so are 11...20.
        let decision = try #require(decide(stored: stored, playable: ids(21...30), held: held, at: later))

        #expect(decision.deleteNow == ids(1...10))
        #expect(decision.held == Held(videoIds: ids(11...20), since: later))
    }

    @Test("a different big drop while an older hold has fully healed starts a new hold")
    func healedHoldThenNewDrop() throws {
        let stored = ids(1...20)
        let held = Held(videoIds: ids(1...8), since: start)
        let time = start.addingTimeInterval(600)

        // Songs 1...8 are back, and 13...20 are missing instead.
        let decision = try #require(decide(stored: stored, playable: ids(1...12), held: held, at: time))

        #expect(decision.deleteNow.isEmpty)
        #expect(decision.held == Held(videoIds: ids(13...20), since: time))
    }

    // MARK: - Rows that are listed but cannot be played

    @Test("a greyed-out row counts as still listed: it stays in the list and is never deleted")
    func unavailableRowsStay() throws {
        let stored = ids(1, 2, 3, 4)

        let decision = try #require(decide(stored: stored, playable: ids(1, 3, 4), unavailable: ids(2)))

        #expect(decision.deleteNow.isEmpty)
        #expect(decision.order == ids(1, 2, 3, 4))
        #expect(decision.held == nil)
    }

    @Test("a stored song that went grey keeps its place after the song it followed, whatever the page's order")
    func unavailableKeepsItsAnchor() throws {
        let stored = ids(1, 2, 3, 4)

        let decision = try #require(decide(stored: stored, playable: ids(4, 1, 3), unavailable: ids(2)))

        #expect(decision.order == ids(4, 1, 2, 3))
    }

    @Test("a stored song with nothing before it that went grey stays at the front")
    func unavailableAtFront() throws {
        let decision = try #require(decide(stored: ids(1, 2, 3), playable: ids(3, 2), unavailable: ids(1)))

        #expect(decision.order == ids(1, 3, 2))
    }

    @Test("a greyed-out row that was never stored is not added to the list")
    func unavailableNotStoredIsIgnored() throws {
        let decision = try #require(decide(stored: ids(1, 2), playable: ids(1, 2), unavailable: ids(7)))

        #expect(decision.order == ids(1, 2))
    }

    @Test("greyed-out rows do not count toward a big drop")
    func unavailableNotCountedAsRemoved() throws {
        let stored = ids(1...20)

        let decision = try #require(decide(stored: stored, playable: ids(9...20), unavailable: ids(1...8)))

        #expect(decision.deleteNow.isEmpty)
        #expect(decision.held == nil)
        #expect(decision.order == stored)
    }

    // MARK: - The count in the header

    @Test("a listing shorter than the stated count by more than the margin is incomplete: it deletes nothing")
    func shortCountBlocksDeletes() throws {
        let stored = ids(1...100)
        // One song really left, but the page returned 85 of the 100 it states.
        let playable = ids(2...86)

        let decision = try #require(decide(stored: stored, playable: playable, stated: 100))

        #expect(!decision.isComplete)
        #expect(decision.deleteNow.isEmpty)
        #expect(decision.held == nil)
        #expect(Set(decision.order) == Set(stored))
    }

    @Test("an incomplete listing still adds new songs and leaves a hold as it was")
    func shortCountStillAdds() throws {
        let stored = ids(1...20)
        let held = Held(videoIds: ids(1...8), since: start)

        let decision = try #require(decide(
            stored: stored, playable: ids(9...20) + ids(30, 31), stated: 40, held: held, at: start.addingTimeInterval(hour * 2)
        ))

        #expect(!decision.isComplete)
        #expect(decision.deleteNow.isEmpty)
        #expect(decision.held == held)
        #expect(Set(decision.order) == Set(stored + ids(30, 31)))
    }

    @Test("the margin is five songs or ten percent of the stated count, whichever is bigger")
    func countMargin() throws {
        // Short by 5 of 100: inside the margin.
        let exactlyFive = try #require(decide(stored: ids(1...100), playable: ids(1...95), stated: 100))
        #expect(exactlyFive.isComplete)

        // Short by 10 of 100: ten percent, inside the margin.
        let ten = try #require(decide(stored: ids(1...100), playable: ids(1...90), stated: 100))
        #expect(ten.isComplete)

        // Short by 11 of 100: outside.
        let eleven = try #require(decide(stored: ids(1...100), playable: ids(1...89), stated: 100))
        #expect(!eleven.isComplete)

        // Short by 6 of 20: more than five and more than ten percent.
        let six = try #require(decide(stored: ids(1...20), playable: ids(1...14), stated: 20))
        #expect(!six.isComplete)

        // Short by 5 of 20: the floor.
        let five = try #require(decide(stored: ids(1...20), playable: ids(1...15), stated: 20))
        #expect(five.isComplete)
    }

    @Test("greyed-out rows count toward the stated total")
    func unavailableCountsTowardTotal() throws {
        let decision = try #require(decide(
            stored: ids(1...100), playable: ids(1...80), unavailable: ids(81...100), stated: 100
        ))

        #expect(decision.isComplete)
    }

    @Test("no stated count means the check is skipped")
    func noStatedCount() throws {
        let decision = try #require(decide(stored: ids(1...100), playable: ids(1...50), stated: nil))

        #expect(decision.isComplete)
    }

    @Test("a listing longer than the stated count is complete")
    func longerThanStated() throws {
        let decision = try #require(decide(stored: ids(1...10), playable: ids(1...12), stated: 10))

        #expect(decision.isComplete)
    }

    // MARK: - Reading the count

    @Test("the count is read from the page's subtitle", arguments: [
        ("Playlist \u{2022} 2026 \u{2022} 182 tracks", 182),
        ("Chart \u{2022} 2026 \u{2022} 100 songs", 100),
        ("Auto playlist \u{2022} 1,000 songs", 1_000),
        ("Album \u{2022} 2023 \u{2022} 12 songs \u{2022} 45 minutes", 12),
        ("1 song", 1),
        ("182 songs, 11 hours", 182),
        ("1\u{202F}000 songs", 1_000),
        ("1\u{00A0}234 tracks", 1_234),
        ("  57 Songs  ", 57),
    ] as [(String, Int)])
    func statedCount(subtitle: String, count: Int) {
        #expect(MusicCollectionSyncRules.statedCount(inSubtitle: subtitle) == count)
    }

    @Test("a subtitle with no count gives none", arguments: [
        "", "Playlist", "Playlist \u{2022} 2026", "Playlist \u{2022} YouTube Music", "2026 \u{2022} 12 minutes",
        "1.5K songs", "songs", "Mix of 30 songs by Adele",
    ])
    func noCount(subtitle: String) {
        #expect(MusicCollectionSyncRules.statedCount(inSubtitle: subtitle) == nil)
    }
}
