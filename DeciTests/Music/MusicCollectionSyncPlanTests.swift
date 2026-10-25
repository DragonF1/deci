// DeciTests/Music/MusicCollectionSyncPlanTests.swift
// What a sync does with the list a page now has against the list stored: which songs are new, which are gone, which
// are listed but never arrived, and the order of it all. A pure comparison; the rules about when a deletion may run are
// the service's, and are tested there.

import Foundation
import Testing
@testable import Deci

@Suite("MusicCollectionSyncPlan")
struct MusicCollectionSyncPlanTests {
    private func ids(_ numbers: Int...) -> [String] { numbers.map(DownloadSamples.id) }

    @Test("new songs are added and songs gone from the page are removed")
    func addAndRemove() throws {
        let plan = try #require(MusicCollectionSyncPlan.make(
            old: ids(1, 2, 3), new: ids(1, 3, 4), downloaded: Set(ids(1, 2, 3))
        ))

        #expect(plan.added == ids(4))
        #expect(plan.removed == ids(2))
        #expect(plan.order == ids(1, 3, 4))
        #expect(plan.toQueue == ids(4))
    }

    @Test("the order is the page's, and a reorder alone adds and removes nothing")
    func reorder() throws {
        let plan = try #require(MusicCollectionSyncPlan.make(
            old: ids(1, 2, 3), new: ids(3, 1, 2), downloaded: Set(ids(1, 2, 3))
        ))

        #expect(plan.order == ids(3, 1, 2))
        #expect(plan.added.isEmpty)
        #expect(plan.removed.isEmpty)
        #expect(plan.toQueue.isEmpty)
    }

    @Test("songs listed before but never downloaded are queued again, with the new ones, in page order")
    func missingSongsRequeue() throws {
        let plan = try #require(MusicCollectionSyncPlan.make(
            old: ids(1, 2, 3), new: ids(5, 1, 2, 3, 4), downloaded: Set(ids(1, 3))
        ))

        #expect(plan.added == ids(5, 4))
        #expect(plan.toQueue == ids(5, 2, 4))
    }

    @Test("a song that left the page is not queued even if it never arrived")
    func goneSongNotQueued() throws {
        let plan = try #require(MusicCollectionSyncPlan.make(old: ids(1, 2), new: ids(1), downloaded: Set(ids(1))))

        #expect(plan.removed == ids(2))
        #expect(plan.toQueue.isEmpty)
    }

    @Test("a song listed twice on the page is planned once")
    func duplicatesCollapse() throws {
        let plan = try #require(MusicCollectionSyncPlan.make(old: [], new: ids(1, 2, 1, 3, 2), downloaded: []))

        #expect(plan.order == ids(1, 2, 3))
        #expect(plan.toQueue == ids(1, 2, 3))
    }

    @Test("an empty page has no plan: a list that went empty is never read as every song gone")
    func emptyNewListHasNoPlan() {
        #expect(MusicCollectionSyncPlan.make(old: ids(1, 2, 3), new: [], downloaded: Set(ids(1, 2, 3))) == nil)
    }

    @Test("nothing changed is a plan with nothing in it")
    func unchanged() throws {
        let plan = try #require(MusicCollectionSyncPlan.make(
            old: ids(1, 2), new: ids(1, 2), downloaded: Set(ids(1, 2))
        ))

        #expect(plan.added.isEmpty)
        #expect(plan.removed.isEmpty)
        #expect(plan.toQueue.isEmpty)
        #expect(plan.order == ids(1, 2))
    }
}
