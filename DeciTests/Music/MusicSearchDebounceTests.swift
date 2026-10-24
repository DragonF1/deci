// DeciTests/Music/MusicSearchDebounceTests.swift
// Search as you type in the YouTube Music field: a search goes out a moment after the last keystroke, Return sends it
// at once, and the fields that filter on screen never reach the backend. The delay is injected, long where a test
// needs "not yet" and short where it needs "now".

import Foundation
import Testing
@testable import Deci

@MainActor
private struct DebounceRig {
    let backend = FakeMusicBackend()
    let service: MusicService
    let nav: MusicSearchNavigation

    init(delay: Duration) {
        service = MusicService(
            backend: backend,
            player: MusicPlayer(engine: FakePlaybackEngine()),
            presentSignIn: { _ in },
            presentChannelPicker: { _, _ in },
            closeSignInWindow: {},
            raiseSignInWindow: {},
            nowPlaying: NowPlayingController(surface: FakeNowPlayingSurface(), fetchArtwork: { _ in nil }),
            refreshOnCreate: false
        )
        nav = MusicSearchNavigation(service: service, searchDelay: delay)
    }

    /// Types `text` the way the view does: the field writes the binding, then the change handler runs.
    func type(_ text: String) {
        nav.fieldQuery = text
        nav.queryChanged()
    }

    var searched: [String] {
        get async { await backend.searchedQueries }
    }

    /// Polls until `condition` holds; for a search that fires on a timer.
    func eventually(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<400 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    /// Lets any timer that was going to fire do so: several times the short delay the rigs use.
    func letTimersRun() async {
        try? await Task.sleep(for: .milliseconds(250))
    }

    /// Types `text`, presses Return and waits for the search to land.
    func search(_ text: String) async {
        type(text)
        nav.submit()
        await service.searchTask?.value
    }
}

@MainActor
@Suite("Music search as you type")
struct MusicSearchDebounceTests {
    private static let short = Duration.milliseconds(40)
    private static let never = Duration.seconds(600)

    // MARK: - Typing

    @Test("typing waits out the delay before it searches, and shows the search as coming")
    func waitsForTheDelay() async {
        let r = DebounceRig(delay: Self.never)
        r.type("daft")
        for _ in 0..<20 { await Task.yield() }

        #expect(await r.searched.isEmpty)
        #expect(r.nav.isSearchPending)
        #expect(r.service.isSearching == false)
    }

    @Test("a pause after typing searches once, with the typed words")
    func searchesAfterThePause() async {
        let r = DebounceRig(delay: Self.short)
        await r.backend.setSearch("daft", results: [MusicSamples.track("s1")])

        r.type("daft")
        #expect(await r.eventually { await r.searched == ["daft"] })
        await r.service.searchTask?.value

        #expect(r.nav.isSearchPending == false)
        #expect(r.service.results.map(\.videoId) == ["s1"])
        #expect(r.nav.submittedQuery == "daft")
        await r.letTimersRun()
        #expect(await r.searched == ["daft"])
    }

    @Test("quick successive edits search once, with the last words")
    func lastEditWins() async {
        let r = DebounceRig(delay: Self.short)
        r.type("d")
        r.type("da")
        r.type("daf")
        r.type("daft")

        #expect(await r.eventually { await r.searched == ["daft"] })
        await r.letTimersRun()
        #expect(await r.searched == ["daft"])
    }

    @Test("an edit during the wait pushes the search back, and the older words are never sent")
    func editRestartsTheWait() async {
        let r = DebounceRig(delay: .milliseconds(120))
        r.type("da")
        try? await Task.sleep(for: .milliseconds(60))
        r.type("daf")

        #expect(await r.eventually { await r.searched == ["daf"] })
        await r.letTimersRun()
        #expect(await r.searched == ["daf"])
    }

    @Test("a slow answer for older words is dropped when newer words have been searched")
    func staleAnswerIsDropped() async {
        let r = DebounceRig(delay: Self.short)
        let gate = MusicTestGate()
        await r.backend.setSearch("da", results: [MusicSamples.track("old")])
        await r.backend.setSearchGate("da", gate)
        await r.backend.setSearch("daft", results: [MusicSamples.track("new")])

        r.type("da")
        #expect(await r.eventually { await r.searched == ["da"] })
        let first = r.service.searchTask
        r.type("daft")
        #expect(await r.eventually { await r.searched == ["da", "daft"] })
        await r.service.searchTask?.value
        #expect(r.service.results.map(\.videoId) == ["new"])

        await gate.open()
        await first?.value
        #expect(r.service.results.map(\.videoId) == ["new"])
    }

    // MARK: - Return

    @Test("Return searches at once and cancels the search that was waiting")
    func returnSearchesAtOnce() async {
        let r = DebounceRig(delay: Self.short)
        await r.backend.setSearch("daft", results: [MusicSamples.track("s1")])
        r.type("daft")
        #expect(r.nav.isSearchPending)

        r.nav.submit()

        #expect(r.nav.isSearchPending == false)
        #expect(r.service.isSearching)
        await r.service.searchTask?.value
        #expect(r.service.results.map(\.videoId) == ["s1"])
        await r.letTimersRun()
        #expect(await r.searched == ["daft"])
    }

    @Test("Return searches the same words again, so a failed search can be retried")
    func returnRetries() async {
        let r = DebounceRig(delay: Self.never)
        await r.search("daft")
        await r.search("daft")
        #expect(await r.searched == ["daft", "daft"])
    }

    @Test("Return on the words already being searched does not start the search over")
    func returnDuringTheSameSearch() async {
        let r = DebounceRig(delay: Self.short)
        let gate = MusicTestGate()
        await r.backend.setSearch("daft", results: [MusicSamples.track("s1")])
        await r.backend.setSearchGate("daft", gate)
        r.type("daft")
        #expect(await r.eventually { await r.searched == ["daft"] })
        #expect(r.service.isSearching)

        r.nav.submit()
        await r.letTimersRun()
        #expect(await r.searched == ["daft"])
        #expect(r.service.isSearching)

        await gate.open()
        await r.service.searchTask?.value
        #expect(r.service.results.map(\.videoId) == ["s1"])
        #expect(await r.searched == ["daft"])
    }

    @Test("Return after a failed search sends the same words again")
    func returnRetriesAfterAFailure() async {
        let r = DebounceRig(delay: Self.never)
        await r.backend.setSearchError("daft", MusicError.http(503))
        await r.search("daft")
        #expect(r.service.lastError != nil)
        #expect(r.nav.panel == .failed)

        await r.search("daft")
        #expect(await r.searched == ["daft", "daft"])
    }

    // MARK: - Clearing and blanks

    @Test("clearing the field before the wait is over cancels the search")
    func clearingCancels() async {
        let r = DebounceRig(delay: Self.short)
        r.type("daft")
        r.type("")

        #expect(r.nav.isSearchPending == false)
        await r.letTimersRun()
        #expect(await r.searched.isEmpty)
    }

    @Test("clearing the field after a search drops its results and does not search again")
    func clearingDropsResults() async {
        let r = DebounceRig(delay: Self.short)
        await r.backend.setSearch("daft", results: [MusicSamples.track("s1")])
        await r.search("daft")
        #expect(r.service.results.count == 1)

        r.type("")

        #expect(r.service.results.isEmpty)
        #expect(r.nav.isSearchPending == false)
        await r.letTimersRun()
        #expect(await r.searched == ["daft"])
    }

    @Test("clearing the field and typing the same words again searches again")
    func sameWordsAfterClearing() async {
        let r = DebounceRig(delay: Self.short)
        await r.search("daft")
        r.type("")
        r.type("daft")

        #expect(await r.eventually { await r.searched == ["daft", "daft"] })
    }

    @Test("resetting the fields forgets the last search, so the same words search again")
    func resetForgetsTheLastSearch() async {
        let r = DebounceRig(delay: Self.short)
        await r.search("daft")

        // A sign-out empties the query itself before the view resets the fields, so no edit is seen.
        r.service.query = ""
        r.nav.resetFields()
        #expect(r.nav.submittedQuery == nil)

        r.type("daft")
        #expect(await r.eventually { await r.searched == ["daft", "daft"] })
    }

    @Test("emptying the field forgets the answer, so the same words typed again are not shown as No results")
    func emptyingForgetsTheAnswer() async {
        let r = DebounceRig(delay: Self.never)
        await r.search("zzz")
        #expect(r.nav.panel == .noResults)

        r.type("")
        #expect(r.nav.submittedQuery == nil)
        r.type("zzz")
        #expect(r.nav.isSearchPending)
        #expect(r.nav.panel == .searching)
    }

    @Test("emptying the field forgets a failure too, so retyped words do not flash the failed card")
    func emptyingForgetsTheFailure() async {
        let r = DebounceRig(delay: Self.never)
        await r.backend.setSearchError("zzz", MusicError.http(503))
        await r.search("zzz")
        #expect(r.nav.panel == .failed)

        r.type("")
        r.type("zzz")
        #expect(r.nav.isSearchPending)
        #expect(r.nav.panel == .searching)
    }

    @Test("words that are only whitespace do not search")
    func whitespaceDoesNotSearch() async {
        let r = DebounceRig(delay: Self.short)
        r.type("   \n ")

        #expect(r.nav.isSearchPending == false)
        await r.letTimersRun()
        #expect(await r.searched.isEmpty)
    }

    @Test("trimming the words to the empty string cancels the search that was waiting")
    func whitespaceCancels() async {
        let r = DebounceRig(delay: Self.short)
        r.type("daft")
        r.type("   ")

        #expect(r.nav.isSearchPending == false)
        await r.letTimersRun()
        #expect(await r.searched.isEmpty)
    }

    // MARK: - The same words

    @Test("words that trim to the last search do not search again")
    func sameTrimmedWords() async {
        let r = DebounceRig(delay: Self.short)
        await r.search("daft")

        r.type("daft ")
        #expect(r.nav.isSearchPending == false)
        r.type("  daft")
        #expect(r.nav.isSearchPending == false)

        await r.letTimersRun()
        #expect(await r.searched == ["daft"])
    }

    @Test("typing more and then deleting back to the last search cancels the search for the longer words")
    func backToTheLastSearch() async {
        let r = DebounceRig(delay: Self.short)
        await r.search("daft")

        r.type("daftx")
        #expect(r.nav.isSearchPending)
        r.type("daft")

        #expect(r.nav.isSearchPending == false)
        await r.letTimersRun()
        #expect(await r.searched == ["daft"])
    }

    @Test("a search typed in is the last search, so Return on the same words is the only way to repeat it")
    func typedSearchIsRemembered() async {
        let r = DebounceRig(delay: Self.short)
        r.type("daft")
        #expect(await r.eventually { await r.searched == ["daft"] })
        await r.service.searchTask?.value

        r.type("daft ")
        await r.letTimersRun()
        #expect(await r.searched == ["daft"])
    }

    // MARK: - Panel

    @Test("while a typed search waits, the panel shows the search as running rather than asking for Return")
    func panelWhilePending() async {
        let r = DebounceRig(delay: Self.never)
        r.type("daft")
        #expect(r.nav.panel == .searching)

        r.type("")
        #expect(r.nav.panel == .invite)
    }

    // MARK: - Fields that filter

    @Test("a Library filter never searches YouTube Music")
    func libraryFilterDoesNotSearch() async {
        let r = DebounceRig(delay: Self.short)
        r.nav.select(.library)
        r.nav.openField()
        #expect(r.nav.scope == .library)

        r.type("daft")

        #expect(r.nav.filterQuery == "daft")
        #expect(r.nav.isSearchPending == false)
        await r.letTimersRun()
        #expect(await r.searched.isEmpty)
    }

    @Test("a playlist filter never searches YouTube Music")
    func playlistFilterDoesNotSearch() async {
        let r = DebounceRig(delay: Self.short)
        r.service.browse.open(MusicSamples.collection("PL1", kind: .playlist))
        r.nav.reconcile()
        r.nav.openField()
        #expect(r.nav.scope == .playlist)

        r.type("daft")

        #expect(r.nav.isSearchPending == false)
        await r.letTimersRun()
        #expect(await r.searched.isEmpty)
    }

    @Test("the Up next filter never searches YouTube Music")
    func queueFilterDoesNotSearch() async {
        let r = DebounceRig(delay: Self.short)
        r.service.play(MusicSamples.track("playing"))
        r.nav.toggleQueue()
        r.nav.openField()
        #expect(r.nav.scope == .queue)

        r.type("daft")

        #expect(r.nav.queueQuery == "daft")
        #expect(r.nav.isSearchPending == false)
        await r.letTimersRun()
        #expect(await r.searched.isEmpty)
    }

    @Test("a search waiting when the field moves on is dropped with the field")
    func movingOnCancels() async {
        let r = DebounceRig(delay: Self.short)
        r.nav.openField()
        r.type("daft")
        #expect(r.nav.isSearchPending)

        r.nav.select(.library)

        #expect(r.nav.isSearchPending == false)
        await r.letTimersRun()
        #expect(await r.searched.isEmpty)
    }
}
