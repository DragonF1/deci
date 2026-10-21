// DeciTests/Music/MusicBrowseStoreHistoryTests.swift
// The History tab's state in the browse store: load states, paging through the days, a refresh that keeps the
// list up while a new play comes in, a response that arrives after a newer load or a reset, and the
// session-expired callback. Home's state is checked to stay out of the way.

import Foundation
import Testing
@testable import Deci

@MainActor
private final class HistoryExpiryProbe {
    var count = 0
}

@MainActor
private struct HistoryHarness {
    let backend = FakeMusicBackend()
    let store: MusicBrowseStore
    let probe = HistoryExpiryProbe()

    init() {
        store = MusicBrowseStore(backend: backend)
        let probe = self.probe
        store.onSessionExpired = { probe.count += 1 }
    }

    /// Polls until `condition` holds, for at most two seconds.
    func until(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<400 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }

    /// Gives a response that should be dropped time to arrive, so a missing drop would show.
    func letLateWorkLand() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(40))
    }
}

@MainActor
@Suite("MusicBrowseStore history")
struct MusicBrowseStoreHistoryTests {

    /// A day of listening: a shelf of songs.
    private func day(_ title: String, _ ids: String...) -> MusicShelf {
        MusicShelf(title: title, items: ids.map { .track(MusicSamples.track($0)) })
    }

    private func loadedShelves(_ store: MusicBrowseStore) -> [MusicShelf] {
        if case .loaded(let shelves) = store.history { shelves } else { [] }
    }

    private func titles(_ store: MusicBrowseStore) -> [String] { loadedShelves(store).map(\.title) }

    // MARK: - Tab

    @Test("History is a third browse tab after Home and Library")
    func tabs() {
        #expect(MusicBrowseStore.Tab.allCases == [.home, .library, .history])
    }

    @Test("History starts idle and is not what the store opens on")
    func startsIdle() {
        let h = HistoryHarness()
        #expect(h.store.history == .idle)
        #expect(h.store.canLoadMoreHistory == false)
        #expect(h.store.isLoadingMoreHistory == false)
        #expect(h.store.isRefreshingHistory == false)
        #expect(h.store.tab == .home)
    }

    // MARK: - Loading

    @Test("loadHistoryIfNeeded goes loading, then loaded with the days and the more-flag")
    func loads() async {
        let h = HistoryHarness()
        let days = [day("Today", "a", "b"), day("Yesterday", "c")]
        await h.backend.setHistory(shelves: days, continuation: "c1")
        let gate = MusicTestGate()
        await h.backend.setHistoryGate(gate)

        h.store.loadHistoryIfNeeded()
        #expect(h.store.history == .loading)
        await gate.open()

        #expect(await h.until { h.store.history == .loaded(days) })
        #expect(h.store.canLoadMoreHistory)
        #expect(await h.backend.historyCallCount == 1)
    }

    @Test("loadHistoryIfNeeded does nothing while loading or once loaded")
    func loadsOnce() async {
        let h = HistoryHarness()
        await h.backend.setHistory(shelves: [day("Today", "a")])
        h.store.loadHistoryIfNeeded()
        h.store.loadHistoryIfNeeded()
        #expect(await h.until { h.store.history != .loading })
        h.store.loadHistoryIfNeeded()
        await h.letLateWorkLand()
        #expect(await h.backend.historyCallCount == 1)
    }

    @Test("History is separate from Home: loading one leaves the other alone")
    func independentOfHome() async {
        let h = HistoryHarness()
        await h.backend.setHistory(shelves: [day("Today", "a")])
        h.store.loadHistoryIfNeeded()
        #expect(await h.until { h.store.history != .loading })
        #expect(h.store.home == .idle)
        #expect(await h.backend.homeCallCount == 0)

        await h.backend.setHome(shelves: [MusicSamples.shelf("Quick picks", "q")])
        h.store.loadHomeIfNeeded()
        #expect(await h.until { h.store.home != .loading })
        #expect(titles(h.store) == ["Today"])
        #expect(await h.backend.historyCallCount == 1)
    }

    @Test("A failed history shows a message and loadHistoryIfNeeded tries again")
    func failureThenRetry() async {
        let h = HistoryHarness()
        await h.backend.setHistoryError(MusicError.http(500))
        h.store.loadHistoryIfNeeded()
        let message = MusicService.message(for: MusicError.http(500))
        #expect(await h.until { h.store.history == .failed(message) })
        #expect(h.probe.count == 0)

        await h.backend.setHistoryError(nil)
        await h.backend.setHistory(shelves: [day("Today", "a")])
        h.store.loadHistoryIfNeeded()
        #expect(h.store.history == .loading)
        #expect(await h.until { h.store.history == .loaded([day("Today", "a")]) })
    }

    @Test("A history with no days (paused or cleared) is loaded and empty, not an error")
    func empty() async {
        let h = HistoryHarness()
        h.store.loadHistoryIfNeeded()
        #expect(await h.until { h.store.history == .loaded([]) })
        #expect(h.store.canLoadMoreHistory == false)
        #expect(h.probe.count == 0)
    }

    @Test("History keeps every shelf it is given: nothing is hidden the way Home hides some titles")
    func noHiddenShelves() async {
        let h = HistoryHarness()
        await h.backend.setHistory(shelves: [day("Mixed for you", "m"), day("Long listens", "l"), day("From the community", "f")])
        h.store.loadHistoryIfNeeded()
        #expect(await h.until { h.store.history != .loading })
        #expect(titles(h.store) == ["Mixed for you", "Long listens", "From the community"])
    }

    // MARK: - Paging

    @Test("loadMoreHistory appends new days, drops repeats and follows the next token to the end")
    func paging() async {
        let h = HistoryHarness()
        await h.backend.setHistory(shelves: [day("Today", "a1")], continuation: "t1")
        await h.backend.setMoreHistory(continuation: "t1", shelves: [day("Today", "a1"), day("Yesterday", "b1")], next: "t2")
        await h.backend.setMoreHistory(continuation: "t2", shelves: [day("This week", "c1")], next: nil)
        h.store.loadHistoryIfNeeded()
        #expect(await h.until { h.store.history != .loading })

        h.store.loadMoreHistory()
        #expect(h.store.isLoadingMoreHistory)
        #expect(await h.until { loadedShelves(h.store).count == 2 })
        #expect(titles(h.store) == ["Today", "Yesterday"])
        #expect(h.store.isLoadingMoreHistory == false)
        #expect(h.store.canLoadMoreHistory)

        h.store.loadMoreHistory()
        #expect(await h.until { loadedShelves(h.store).count == 3 })
        #expect(titles(h.store) == ["Today", "Yesterday", "This week"])
        #expect(h.store.canLoadMoreHistory == false)

        h.store.loadMoreHistory()
        await h.letLateWorkLand()
        #expect(await h.backend.moreHistoryCalls == ["t1", "t2"])
        #expect(await h.backend.moreHomeCalls.isEmpty)
    }

    @Test("loadMoreHistory does nothing before History has loaded or without a token")
    func moreGuards() async {
        let h = HistoryHarness()
        h.store.loadMoreHistory()
        await h.backend.setHistory(shelves: [day("Today", "a")], continuation: nil)
        h.store.loadHistoryIfNeeded()
        #expect(await h.until { h.store.history != .loading })
        h.store.loadMoreHistory()
        await h.letLateWorkLand()
        #expect(await h.backend.moreHistoryCalls.isEmpty)
    }

    @Test("loadMoreHistory while a page is already coming asks only once")
    func moreInFlight() async {
        let h = HistoryHarness()
        await h.backend.setHistory(shelves: [day("Today", "a")], continuation: "t1")
        await h.backend.setMoreHistory(continuation: "t1", shelves: [day("Yesterday", "b")])
        h.store.loadHistoryIfNeeded()
        #expect(await h.until { h.store.history != .loading })

        let gate = MusicTestGate()
        await h.backend.setMoreHistoryGate(continuation: "t1", gate)
        h.store.loadMoreHistory()
        h.store.loadMoreHistory()
        h.store.loadMoreHistory()
        await gate.open()
        #expect(await h.until { loadedShelves(h.store).count == 2 })
        #expect(await h.backend.moreHistoryCalls == ["t1"])
    }

    @Test("A page that adds nothing new goes on to the next one by itself, so the end of the list is never stuck")
    func repeatOnlyPageGoesOn() async {
        let h = HistoryHarness()
        await h.backend.setHistory(shelves: [day("Today", "a")], continuation: "t1")
        await h.backend.setMoreHistory(continuation: "t1", shelves: [day("Today", "a")], next: "t2")
        await h.backend.setMoreHistory(continuation: "t2", shelves: [day("Yesterday", "b")])
        h.store.loadHistoryIfNeeded()
        #expect(await h.until { h.store.history != .loading })
        h.store.loadMoreHistory()
        #expect(await h.until { titles(h.store) == ["Today", "Yesterday"] })
        #expect(await h.backend.moreHistoryCalls == ["t1", "t2"])
        #expect(h.store.canLoadMoreHistory == false)
    }

    @Test("A first page with no days but a token goes on to the next page by itself")
    func emptyFirstPageWithToken() async {
        let h = HistoryHarness()
        await h.backend.setHistory(shelves: [], continuation: "t1")
        await h.backend.setMoreHistory(continuation: "t1", shelves: [day("Today", "a")])
        h.store.loadHistoryIfNeeded()
        #expect(await h.until { titles(h.store) == ["Today"] })
        #expect(await h.backend.moreHistoryCalls == ["t1"])
    }

    @Test("A token the server hands back unchanged ends paging instead of looping")
    func repeatedToken() async {
        let h = HistoryHarness()
        await h.backend.setHistory(shelves: [day("Today", "a")], continuation: "t1")
        await h.backend.setMoreHistory(continuation: "t1", shelves: [day("Yesterday", "b")], next: "t1")
        h.store.loadHistoryIfNeeded()
        #expect(await h.until { h.store.history != .loading })
        h.store.loadMoreHistory()
        #expect(await h.until { loadedShelves(h.store).count == 2 })
        #expect(h.store.canLoadMoreHistory == false)
    }

    @Test("A failed extra page keeps the days, clears the loading flag and can be retried")
    func moreFailure() async {
        let h = HistoryHarness()
        await h.backend.setHistory(shelves: [day("Today", "a")], continuation: "t1")
        await h.backend.setMoreHistoryError(continuation: "t1", MusicError.http(503))
        h.store.loadHistoryIfNeeded()
        #expect(await h.until { h.store.history != .loading })

        h.store.loadMoreHistory()
        #expect(await h.until { h.store.isLoadingMoreHistory == false })
        #expect(titles(h.store) == ["Today"])
        #expect(h.store.canLoadMoreHistory)

        await h.backend.setMoreHistoryError(continuation: "t1", nil)
        await h.backend.setMoreHistory(continuation: "t1", shelves: [day("Yesterday", "b")])
        h.store.loadMoreHistory()
        #expect(await h.until { loadedShelves(h.store).count == 2 })
    }

    // MARK: - Reload and refresh

    @Test("reloadHistory starts again from the top and forgets the old token")
    func reload() async {
        let h = HistoryHarness()
        await h.backend.setHistory(shelves: [day("Today", "a")], continuation: "t1")
        h.store.loadHistoryIfNeeded()
        #expect(await h.until { h.store.history != .loading })

        await h.backend.setHistory(shelves: [day("Today", "z")], continuation: nil)
        h.store.reloadHistory()
        #expect(h.store.history == .loading)
        #expect(h.store.canLoadMoreHistory == false)
        #expect(await h.until { h.store.history == .loaded([day("Today", "z")]) })
        #expect(h.store.canLoadMoreHistory == false)
    }

    @Test("Opening History again after a play refreshes it in place: the old days stay up, then the new play shows")
    func refreshAfterAPlay() async {
        let h = HistoryHarness()
        await h.backend.setHistory(shelves: [day("Today", "a")], continuation: "t1")
        h.store.loadHistoryIfNeeded()
        #expect(await h.until { h.store.history != .loading })

        // A song is played elsewhere, so YouTube's list now starts with it.
        let gate = MusicTestGate()
        await h.backend.setHistoryGate(gate)
        await h.backend.setHistory(shelves: [day("Today", "played", "a")], continuation: "t9")
        h.store.refreshHistory()
        #expect(h.store.isRefreshingHistory)
        #expect(h.store.history == .loaded([day("Today", "a")]))
        #expect(h.store.canLoadMoreHistory == false)

        // Another open while it is coming asks nothing more.
        h.store.refreshHistory()
        await gate.open()
        #expect(await h.until { h.store.isRefreshingHistory == false })
        #expect(h.store.history == .loaded([day("Today", "played", "a")]))
        #expect(h.store.canLoadMoreHistory)
        #expect(await h.backend.historyCallCount == 2)
    }

    @Test("A failed refresh keeps the old days and their next token, and says nothing on screen")
    func refreshFailure() async {
        let h = HistoryHarness()
        await h.backend.setHistory(shelves: [day("Today", "a")], continuation: "t1")
        await h.backend.setMoreHistory(continuation: "t1", shelves: [day("Yesterday", "b")])
        h.store.loadHistoryIfNeeded()
        #expect(await h.until { h.store.history != .loading })

        await h.backend.setHistoryError(MusicError.http(503))
        h.store.refreshHistory()
        #expect(await h.until { h.store.isRefreshingHistory == false })
        #expect(titles(h.store) == ["Today"])
        #expect(h.store.canLoadMoreHistory)
        h.store.loadMoreHistory()
        #expect(await h.until { loadedShelves(h.store).count == 2 })
        #expect(h.probe.count == 0)
    }

    @Test("refreshHistory before History has loaded, or after a failure, loads it from the top")
    func refreshBeforeLoad() async {
        let h = HistoryHarness()
        await h.backend.setHistoryError(MusicError.http(500))
        h.store.refreshHistory()
        #expect(h.store.history == .loading)
        #expect(h.store.isRefreshingHistory == false)
        #expect(await h.until { h.store.history != .loading })
        #expect(h.store.history == .failed(MusicService.message(for: MusicError.http(500))))

        await h.backend.setHistoryError(nil)
        await h.backend.setHistory(shelves: [day("Today", "a")])
        h.store.refreshHistory()
        #expect(h.store.history == .loading)
        #expect(await h.until { h.store.history == .loaded([day("Today", "a")]) })
    }

    @Test("refreshHistory while the first load is still coming does not start a second request")
    func refreshWhileLoading() async {
        let h = HistoryHarness()
        let gate = MusicTestGate()
        await h.backend.setHistory(shelves: [day("Today", "a")])
        await h.backend.setHistoryGate(gate)
        h.store.loadHistoryIfNeeded()
        h.store.refreshHistory()
        h.store.refreshHistory()
        await gate.open()
        #expect(await h.until { h.store.history == .loaded([day("Today", "a")]) })
        await h.letLateWorkLand()
        #expect(await h.backend.historyCallCount == 1)
    }

    @Test("A refresh that lands while an extra page is coming drops that page")
    func refreshDuringMore() async {
        let h = HistoryHarness()
        await h.backend.setHistory(shelves: [day("Today", "a")], continuation: "t1")
        await h.backend.setMoreHistory(continuation: "t1", shelves: [day("Old", "old")])
        h.store.loadHistoryIfNeeded()
        #expect(await h.until { h.store.history != .loading })

        let slow = MusicTestGate()
        await h.backend.setMoreHistoryGate(continuation: "t1", slow)
        h.store.loadMoreHistory()
        #expect(await h.until { await h.backend.moreHistoryCalls.count == 1 })

        await h.backend.setHistory(shelves: [day("Today", "new")])
        h.store.refreshHistory()
        #expect(await h.until { h.store.history == .loaded([day("Today", "new")]) })

        await slow.open()
        await h.letLateWorkLand()
        #expect(titles(h.store) == ["Today"])
        #expect(h.store.isLoadingMoreHistory == false)
    }

    // MARK: - Stale answers

    @Test("A slow history answer that arrives after a reload is dropped")
    func staleResponse() async {
        let h = HistoryHarness()
        let slow = MusicTestGate()
        await h.backend.setHistory(shelves: [day("Today", "old")])
        await h.backend.setHistoryGate(slow)
        h.store.loadHistoryIfNeeded()
        #expect(await h.until { await h.backend.historyCallCount == 1 })

        await h.backend.setHistoryGate(nil)
        await h.backend.setHistory(shelves: [day("Today", "new")])
        h.store.reloadHistory()
        #expect(await h.until { h.store.history == .loaded([day("Today", "new")]) })

        await slow.open()
        await h.letLateWorkLand()
        #expect(h.store.history == .loaded([day("Today", "new")]))
    }

    @Test("A slow history failure that arrives after a reload does not replace the newer days or sign out")
    func staleFailure() async {
        let h = HistoryHarness()
        let slow = MusicTestGate()
        await h.backend.setHistoryError(MusicError.signedOut)
        await h.backend.setHistoryGate(slow)
        h.store.loadHistoryIfNeeded()
        #expect(await h.until { await h.backend.historyCallCount == 1 })

        await h.backend.setHistoryError(nil)
        await h.backend.setHistoryGate(nil)
        await h.backend.setHistory(shelves: [day("Today", "new")])
        h.store.reloadHistory()
        #expect(await h.until { loadedShelves(h.store).count == 1 })

        await slow.open()
        await h.letLateWorkLand()
        #expect(titles(h.store) == ["Today"])
        #expect(h.probe.count == 0)
    }

    // MARK: - Reset

    @Test("reset drops History and keeps the selected tab")
    func resetClears() async {
        let h = HistoryHarness()
        await h.backend.setHistory(shelves: [day("Today", "a")], continuation: "t1")
        h.store.tab = .history
        h.store.loadHistoryIfNeeded()
        #expect(await h.until { h.store.history != .loading })

        h.store.reset()
        #expect(h.store.history == .idle)
        #expect(h.store.canLoadMoreHistory == false)
        #expect(h.store.isLoadingMoreHistory == false)
        #expect(h.store.isRefreshingHistory == false)
        #expect(h.store.tab == .history)

        h.store.loadHistoryIfNeeded()
        #expect(h.store.history == .loading)
    }

    @Test("A history answer that was in flight at reset is dropped and cannot bring old days back")
    func resetDropsInFlight() async {
        let h = HistoryHarness()
        let slow = MusicTestGate()
        await h.backend.setHistory(shelves: [day("Today", "a")], continuation: "t1")
        await h.backend.setHistoryGate(slow)
        h.store.loadHistoryIfNeeded()
        #expect(await h.until { await h.backend.historyCallCount == 1 })

        h.store.reset()
        await slow.open()
        await h.letLateWorkLand()
        #expect(h.store.history == .idle)
        #expect(h.store.canLoadMoreHistory == false)
    }

    @Test("A refresh and an extra page that were in flight at reset are dropped")
    func resetDropsRefreshAndMore() async {
        let h = HistoryHarness()
        await h.backend.setHistory(shelves: [day("Today", "a")], continuation: "t1")
        await h.backend.setMoreHistory(continuation: "t1", shelves: [day("Yesterday", "b")])
        h.store.loadHistoryIfNeeded()
        #expect(await h.until { h.store.history != .loading })

        let slow = MusicTestGate()
        await h.backend.setMoreHistoryGate(continuation: "t1", slow)
        h.store.loadMoreHistory()
        #expect(await h.until { await h.backend.moreHistoryCalls.count == 1 })
        h.store.reset()
        await slow.open()
        await h.letLateWorkLand()
        #expect(h.store.history == .idle)
        #expect(h.store.isLoadingMoreHistory == false)

        // A refresh in flight at reset: load again, refresh, reset while it is held.
        await h.backend.setHistoryGate(nil)
        h.store.loadHistoryIfNeeded()
        #expect(await h.until { h.store.history != .loading })
        let gate = MusicTestGate()
        await h.backend.setHistoryGate(gate)
        h.store.refreshHistory()
        #expect(h.store.isRefreshingHistory)
        h.store.reset()
        await gate.open()
        await h.letLateWorkLand()
        #expect(h.store.history == .idle)
        #expect(h.store.isRefreshingHistory == false)
    }

    // MARK: - Session expired

    @Test("signedOut from history tells the service once and shows the signed-out message")
    func sessionExpired() async {
        let h = HistoryHarness()
        await h.backend.setHistoryError(MusicError.signedOut)
        h.store.loadHistoryIfNeeded()
        #expect(await h.until { h.store.history == .failed(MusicService.message(for: MusicError.signedOut)) })
        #expect(h.probe.count == 1)
    }

    @Test("signedOut from an extra page, or from a refresh, tells the service and keeps what was loaded")
    func sessionExpiredOnMoreAndRefresh() async {
        let h = HistoryHarness()
        await h.backend.setHistory(shelves: [day("Today", "a")], continuation: "t1")
        await h.backend.setMoreHistoryError(continuation: "t1", MusicError.signedOut)
        h.store.loadHistoryIfNeeded()
        #expect(await h.until { h.store.history != .loading })

        h.store.loadMoreHistory()
        #expect(await h.until { h.probe.count == 1 })
        #expect(titles(h.store) == ["Today"])

        await h.backend.setHistoryError(MusicError.signedOut)
        h.store.refreshHistory()
        #expect(await h.until { h.probe.count == 2 })
        #expect(await h.until { h.store.isRefreshingHistory == false })
        #expect(titles(h.store) == ["Today"])
    }

    @Test("Other errors do not sign the session out")
    func otherErrorsKeepSession() async {
        let h = HistoryHarness()
        let errors: [any Error] = [MusicError.http(500), MusicError.http(403), MusicError.parse("x"), URLError(.notConnectedToInternet)]
        for error in errors {
            await h.backend.setHistoryError(error)
            h.store.reloadHistory()
            #expect(await h.until { h.store.history != .loading })
        }
        #expect(h.store.history == .failed(MusicService.message(for: URLError(.notConnectedToInternet))))
        #expect(h.probe.count == 0)
    }

    @Test("A signedOut history answer that arrives after a reset does not fire the callback")
    func sessionExpiredAfterResetIsIgnored() async {
        let h = HistoryHarness()
        let slow = MusicTestGate()
        await h.backend.setHistoryError(MusicError.signedOut)
        await h.backend.setHistoryGate(slow)
        h.store.loadHistoryIfNeeded()
        #expect(await h.until { await h.backend.historyCallCount == 1 })

        h.store.reset()
        await slow.open()
        await h.letLateWorkLand()
        #expect(h.probe.count == 0)
        #expect(h.store.history == .idle)
    }
}

@MainActor
@Suite("MusicHistoryView days")
struct MusicHistoryDaysTests {
    @Test("Each shelf with songs is a day, in order, with its songs in order")
    func daysInOrder() {
        let shelves = [
            MusicShelf(title: "Today", items: [.track(MusicSamples.track("a")), .track(MusicSamples.track("b"))]),
            MusicShelf(title: "Yesterday", items: [.track(MusicSamples.track("c"))]),
        ]
        let days = MusicHistoryView.days(in: shelves)
        #expect(days.map(\.title) == ["Today", "Yesterday"])
        #expect(days.map { $0.tracks.map(\.videoId) } == [["a", "b"], ["c"]])
    }

    @Test("History lists songs only: a collection is left out, and a day of only collections vanishes")
    func songsOnly() {
        let shelves = [
            MusicShelf(title: "Today", items: [.collection(MusicSamples.collection("MPREb1")), .track(MusicSamples.track("a"))]),
            MusicShelf(title: "Yesterday", items: [.collection(MusicSamples.collection("MPREb2"))]),
        ]
        let days = MusicHistoryView.days(in: shelves)
        #expect(days.map(\.title) == ["Today"])
        #expect(days.first?.tracks.map(\.videoId) == ["a"])
    }

    @Test("No shelves, or shelves with no items, give no days")
    func noDays() {
        #expect(MusicHistoryView.days(in: []).isEmpty)
        #expect(MusicHistoryView.days(in: [MusicShelf(title: "Today", items: [])]).isEmpty)
    }
}
