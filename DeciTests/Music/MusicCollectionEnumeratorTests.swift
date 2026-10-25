// DeciTests/Music/MusicCollectionEnumeratorTests.swift
// Listing every song of a playlist or album: the first page and each continuation in page order, the three guards that
// end a chain which never ends (a token seen before, pages that add nothing, a ceiling on pages), the rows that carry no
// usable video id, the greyed-out rows and the count the header states, a rate limit on one page asking for that page
// again, and which browse ids can be downloaded at all. A fake backend serves the pages; nothing is live.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("MusicCollectionEnumerator")
struct MusicCollectionEnumeratorTests {
    private func ids(_ range: ClosedRange<Int>) -> [String] { range.map(DownloadSamples.id) }

    private func source(_ backend: FakeMusicBackend) -> MusicCollectionSource {
        MusicCollectionSource(backend: backend)
    }

    // MARK: - Pages

    @Test("a playlist on one page lists its songs in page order, with the header's title, subtitle and cover")
    func onePage() async throws {
        let backend = FakeMusicBackend()
        let cover = URL(string: "https://lh3.googleusercontent.com/cover=w544-h544")
        await backend.setPage(MusicBrowsePage(
            browseId: "VLPLone", title: "Road trip", subtitle: "Playlist \u{2022} 3 songs", thumbnailURL: cover,
            tracks: DownloadSamples.tracks(1...3), continuation: nil, shelves: []
        ))

        let listing = try await MusicCollectionEnumerator.enumerate("VLPLone", source: source(backend))

        #expect(listing.tracks.map(\.videoId) == ids(1...3))
        #expect(listing.title == "Road trip")
        #expect(listing.subtitle == "Playlist \u{2022} 3 songs")
        #expect(listing.coverURL == cover)
        #expect(await backend.pageCalls == ["VLPLone"])
        #expect(await backend.moreTracksCalls.isEmpty)
    }

    @Test("continuations are followed in order and their songs come after the first page's")
    func continuations() async throws {
        let backend = FakeMusicBackend()
        await backend.setPage(MusicSamples.page("VLPLlong", tracks: DownloadSamples.tracks(1...3), continuation: "t1"))
        await backend.setMoreTracks(browseId: "VLPLlong", continuation: "t1", tracks: DownloadSamples.tracks(4...6), next: "t2")
        await backend.setMoreTracks(browseId: "VLPLlong", continuation: "t2", tracks: DownloadSamples.tracks(7...8), next: nil)

        let listing = try await MusicCollectionEnumerator.enumerate("VLPLlong", source: source(backend))

        #expect(listing.tracks.map(\.videoId) == ids(1...8))
        #expect(await backend.moreTracksCalls.map(\.continuation) == ["t1", "t2"])
    }

    @Test("the same works for a playlist, Liked music and an album")
    func everyKindOfPage() async throws {
        for browseId in ["VLPLabc", "VLLM", "MPREb_album"] {
            let backend = FakeMusicBackend()
            await backend.setPage(MusicSamples.page(browseId, tracks: DownloadSamples.tracks(1...2), continuation: "t1"))
            await backend.setMoreTracks(browseId: browseId, continuation: "t1", tracks: DownloadSamples.tracks(3...4))

            let listing = try await MusicCollectionEnumerator.enumerate(browseId, source: source(backend))

            #expect(listing.tracks.map(\.videoId) == ids(1...4), "\(browseId)")
        }
    }

    @Test("a song listed twice is listed once, where it first appears")
    func duplicatesCollapse() async throws {
        let backend = FakeMusicBackend()
        await backend.setPage(MusicSamples.page("VLPLdup", tracks: DownloadSamples.tracks(1...3), continuation: "t1"))
        await backend.setMoreTracks(
            browseId: "VLPLdup", continuation: "t1", tracks: DownloadSamples.tracks(2...2) + DownloadSamples.tracks(4...4)
        )

        let listing = try await MusicCollectionEnumerator.enumerate("VLPLdup", source: source(backend))

        #expect(listing.tracks.map(\.videoId) == [1, 2, 3, 4].map(DownloadSamples.id))
    }

    @Test("rows with no video id, or one that is not a video id, are skipped")
    func badRowsSkipped() async throws {
        let backend = FakeMusicBackend()
        let rows = [
            DownloadSamples.track(DownloadSamples.id(1)),
            DownloadSamples.track(""),
            DownloadSamples.track("short"),
            DownloadSamples.track("../../etc/pw"),
            DownloadSamples.track("has a space"),
            DownloadSamples.track(DownloadSamples.id(2)),
        ]
        await backend.setPage(MusicSamples.page("VLPLbad", tracks: rows))

        let listing = try await MusicCollectionEnumerator.enumerate("VLPLbad", source: source(backend))

        #expect(listing.tracks.map(\.videoId) == ids(1...2))
    }

    @Test("an empty continuation token ends the chain like no token")
    func emptyTokenEnds() async throws {
        let backend = FakeMusicBackend()
        await backend.setPage(MusicSamples.page("VLPLempty", tracks: DownloadSamples.tracks(1...2), continuation: ""))

        let listing = try await MusicCollectionEnumerator.enumerate("VLPLempty", source: source(backend))

        #expect(listing.tracks.count == 2)
        #expect(await backend.moreTracksCalls.isEmpty)
    }

    // MARK: - The guards

    @Test("a token that comes round again ends the chain as incomplete, not as a short list")
    func repeatedTokenIsIncomplete() async throws {
        let backend = FakeMusicBackend()
        await backend.setPage(MusicSamples.page("VLPLloop", tracks: DownloadSamples.tracks(1...2), continuation: "t1"))
        await backend.setMoreTracks(browseId: "VLPLloop", continuation: "t1", tracks: DownloadSamples.tracks(3...4), next: "t2")
        await backend.setMoreTracks(browseId: "VLPLloop", continuation: "t2", tracks: DownloadSamples.tracks(5...6), next: "t1")

        await #expect(throws: MusicCollectionEnumerator.Failure.incomplete) {
            try await MusicCollectionEnumerator.enumerate("VLPLloop", source: source(backend))
        }
        #expect(await backend.moreTracksCalls.map(\.continuation) == ["t1", "t2"])
    }

    @Test("pages that add no new song, three in a row, end the chain as incomplete")
    func emptyPagesAreIncomplete() async throws {
        let backend = FakeMusicBackend()
        await backend.setPage(MusicSamples.page("VLPLempty", tracks: DownloadSamples.tracks(1...2), continuation: "t1"))
        await backend.setMoreTracks(browseId: "VLPLempty", continuation: "t1", tracks: [], next: "t2")
        await backend.setMoreTracks(browseId: "VLPLempty", continuation: "t2", tracks: [], next: "t3")
        await backend.setMoreTracks(browseId: "VLPLempty", continuation: "t3", tracks: [], next: "t4")
        await backend.setMoreTracks(browseId: "VLPLempty", continuation: "t4", tracks: DownloadSamples.tracks(3...3))

        await #expect(throws: MusicCollectionEnumerator.Failure.incomplete) {
            try await MusicCollectionEnumerator.enumerate("VLPLempty", source: source(backend))
        }
        #expect(await backend.moreTracksCalls.map(\.continuation) == ["t1", "t2", "t3"])
    }

    @Test("a page of songs already listed counts as an empty page, and a page with a new song starts the count again")
    func repeatedSongsCountAsEmpty() async throws {
        let backend = FakeMusicBackend()
        await backend.setPage(MusicSamples.page("VLPLrep", tracks: DownloadSamples.tracks(1...2), continuation: "t1"))
        await backend.setMoreTracks(browseId: "VLPLrep", continuation: "t1", tracks: DownloadSamples.tracks(1...2), next: "t2")
        await backend.setMoreTracks(browseId: "VLPLrep", continuation: "t2", tracks: DownloadSamples.tracks(1...2), next: "t3")
        // A new song here: the count of empty pages starts over.
        await backend.setMoreTracks(browseId: "VLPLrep", continuation: "t3", tracks: DownloadSamples.tracks(3...3), next: "t4")
        await backend.setMoreTracks(browseId: "VLPLrep", continuation: "t4", tracks: DownloadSamples.tracks(3...3), next: "t5")
        await backend.setMoreTracks(browseId: "VLPLrep", continuation: "t5", tracks: DownloadSamples.tracks(3...3), next: nil)

        let listing = try await MusicCollectionEnumerator.enumerate("VLPLrep", source: source(backend))

        #expect(listing.tracks.map(\.videoId) == ids(1...3))
    }

    @Test("the page ceiling ends a chain that keeps bringing new songs as incomplete")
    func pageCeilingIsIncomplete() async throws {
        let backend = FakeMusicBackend()
        await backend.setPage(MusicSamples.page("VLPLendless", tracks: DownloadSamples.tracks(1...1), continuation: "t1"))
        for page in 1...10 {
            await backend.setMoreTracks(
                browseId: "VLPLendless", continuation: "t\(page)",
                tracks: DownloadSamples.tracks((page + 1)...(page + 1)), next: "t\(page + 1)"
            )
        }

        await #expect(throws: MusicCollectionEnumerator.Failure.incomplete) {
            try await MusicCollectionEnumerator.enumerate("VLPLendless", source: source(backend), pageCeiling: 5)
        }
        #expect(await backend.moreTracksCalls.count == 5)
    }

    @Test("a chain that ends exactly at the ceiling is complete")
    func endingAtTheCeilingIsComplete() async throws {
        let backend = FakeMusicBackend()
        await backend.setPage(MusicSamples.page("VLPLedge", tracks: DownloadSamples.tracks(1...1), continuation: "t1"))
        for page in 1...5 {
            await backend.setMoreTracks(
                browseId: "VLPLedge", continuation: "t\(page)",
                tracks: DownloadSamples.tracks((page + 1)...(page + 1)), next: page == 5 ? nil : "t\(page + 1)"
            )
        }

        let listing = try await MusicCollectionEnumerator.enumerate("VLPLedge", source: source(backend), pageCeiling: 5)

        #expect(listing.tracks.count == 6)
    }

    @Test("a download reads up to five hundred pages, and gives up on empty pages where a sort would")
    func guardsAreTheDownloadsOwn() {
        #expect(MusicCollectionEnumerator.pageCeiling == 500)
        #expect(MusicCollectionEnumerator.emptyPageLimit == MusicBrowseStore.sortEmptyPageLimit)
    }

    @Test("a long playlist is not cut at the sort's song cap")
    func noSongCap() async throws {
        let backend = FakeMusicBackend()
        let total = MusicBrowseStore.sortTrackCap + 300
        await backend.setPage(MusicSamples.page("VLPLbig", tracks: DownloadSamples.tracks(1...1_000), continuation: "t1"))
        await backend.setMoreTracks(
            browseId: "VLPLbig", continuation: "t1", tracks: DownloadSamples.tracks(1_001...2_000), next: "t2"
        )
        await backend.setMoreTracks(
            browseId: "VLPLbig", continuation: "t2", tracks: DownloadSamples.tracks(2_001...total), next: nil
        )

        let listing = try await MusicCollectionEnumerator.enumerate("VLPLbig", source: source(backend))

        #expect(listing.tracks.count == total)
        #expect(listing.tracks.last?.videoId == DownloadSamples.id(total))
    }

    // MARK: - Failures

    @Test("an error on the first page is thrown as it is")
    func firstPageError() async throws {
        let backend = FakeMusicBackend()
        await backend.setPageError("VLPLgone", MusicError.http(404))

        await #expect(throws: MusicError.http(404)) {
            try await MusicCollectionEnumerator.enumerate("VLPLgone", source: source(backend))
        }
    }

    @Test("an error on a later page throws, and the songs of the pages before it are not returned")
    func laterPageError() async throws {
        let backend = FakeMusicBackend()
        await backend.setPage(MusicSamples.page("VLPLcut", tracks: DownloadSamples.tracks(1...3), continuation: "t1"))
        await backend.setMoreTracksError(browseId: "VLPLcut", continuation: "t1", MusicError.http(503))

        await #expect(throws: MusicError.http(503)) {
            try await MusicCollectionEnumerator.enumerate("VLPLcut", source: source(backend), delays: [])
        }
    }

    // MARK: - Rows that are listed but cannot be played

    @Test("greyed-out rows of every page are reported once each, in order, apart from the songs")
    func unavailableRowsReported() async throws {
        let backend = FakeMusicBackend()
        await backend.setPage(MusicBrowsePage(
            browseId: "VLPLgrey", title: "Grey", subtitle: nil, thumbnailURL: nil, tracks: DownloadSamples.tracks(1...2),
            continuation: "t1", shelves: [], unavailableVideoIds: [DownloadSamples.id(90)]
        ))
        await backend.setMoreTracks(
            browseId: "VLPLgrey", continuation: "t1", tracks: DownloadSamples.tracks(3...3),
            unavailable: [DownloadSamples.id(91), DownloadSamples.id(90), DownloadSamples.id(2)]
        )

        let listing = try await MusicCollectionEnumerator.enumerate("VLPLgrey", source: source(backend))

        #expect(listing.tracks.map(\.videoId) == ids(1...3))
        #expect(listing.unavailableVideoIds == [DownloadSamples.id(90), DownloadSamples.id(91)])
    }

    @Test("a greyed-out id that is not a video id is not reported")
    func invalidUnavailableIgnored() async throws {
        let backend = FakeMusicBackend()
        await backend.setPage(MusicBrowsePage(
            browseId: "VLPLgrey", title: "Grey", subtitle: nil, thumbnailURL: nil, tracks: DownloadSamples.tracks(1...1),
            continuation: nil, shelves: [], unavailableVideoIds: ["short", "../../etc/pw", DownloadSamples.id(90)]
        ))

        let listing = try await MusicCollectionEnumerator.enumerate("VLPLgrey", source: source(backend))

        #expect(listing.unavailableVideoIds == [DownloadSamples.id(90)])
    }

    @Test("the count the header states comes with the listing, and is nil when it states none")
    func statedCountReported() async throws {
        let backend = FakeMusicBackend()
        await backend.setPage(MusicBrowsePage(
            browseId: "VLPLcount", title: "Count", subtitle: "Playlist \u{2022} 2026 \u{2022} 1,000 songs", thumbnailURL: nil,
            tracks: DownloadSamples.tracks(1...2), continuation: nil, shelves: []
        ))
        await backend.setPage(MusicBrowsePage(
            browseId: "VLPLnone", title: "None", subtitle: "Playlist", thumbnailURL: nil,
            tracks: DownloadSamples.tracks(1...2), continuation: nil, shelves: []
        ))

        let counted = try await MusicCollectionEnumerator.enumerate("VLPLcount", source: source(backend))
        let uncounted = try await MusicCollectionEnumerator.enumerate("VLPLnone", source: source(backend))

        #expect(counted.statedCount == 1_000)
        #expect(uncounted.statedCount == nil)
    }

    // MARK: - Rate limits

    @Test("a rate limit on the first page waits 30 then 60 seconds and asks for that page again")
    func rateLimitOnTheFirstPage() async throws {
        let backend = FakeMusicBackend()
        let pause = RecordingPause()
        await backend.setPage(MusicSamples.page("VLPLslow", tracks: DownloadSamples.tracks(1...2)))
        await backend.queuePageErrors("VLPLslow", [MusicError.http(429), MusicError.http(503)])

        let listing = try await MusicCollectionEnumerator.enumerate(
            "VLPLslow", source: source(backend), pause: pause.closure
        )

        #expect(listing.tracks.map(\.videoId) == ids(1...2))
        #expect(pause.waits == [30, 60])
        #expect(await backend.pageCalls == ["VLPLslow", "VLPLslow", "VLPLslow"])
    }

    @Test("a rate limit on a later page asks for that page again and does not read the pages before it again")
    func rateLimitOnALaterPage() async throws {
        let backend = FakeMusicBackend()
        let pause = RecordingPause()
        await backend.setPage(MusicSamples.page("VLPLlong", tracks: DownloadSamples.tracks(1...3), continuation: "t1"))
        await backend.setMoreTracks(browseId: "VLPLlong", continuation: "t1", tracks: DownloadSamples.tracks(4...6), next: "t2")
        await backend.setMoreTracks(browseId: "VLPLlong", continuation: "t2", tracks: DownloadSamples.tracks(7...8))
        await backend.queueMoreTracksErrors(browseId: "VLPLlong", continuation: "t2", [MusicError.http(429)])

        let listing = try await MusicCollectionEnumerator.enumerate(
            "VLPLlong", source: source(backend), pause: pause.closure
        )

        #expect(listing.tracks.map(\.videoId) == ids(1...8))
        #expect(pause.waits == [30])
        #expect(await backend.pageCalls == ["VLPLlong"])
        #expect(await backend.moreTracksCalls.map(\.continuation) == ["t1", "t2", "t2"])
    }

    @Test("a page that keeps being refused waits 30, 60 and 120 seconds and then throws its error")
    func rateLimitRetriesAreUsedUp() async throws {
        let backend = FakeMusicBackend()
        let pause = RecordingPause()
        await backend.setPage(MusicSamples.page("VLPLbusy", tracks: DownloadSamples.tracks(1...3), continuation: "t1"))
        await backend.setMoreTracksError(browseId: "VLPLbusy", continuation: "t1", MusicError.http(503))

        await #expect(throws: MusicError.http(503)) {
            try await MusicCollectionEnumerator.enumerate("VLPLbusy", source: source(backend), pause: pause.closure)
        }
        #expect(pause.waits == [30, 60, 120])
        #expect(await backend.moreTracksCalls.count == 4)
    }

    @Test("an error that is not a rate limit is thrown at once, without a wait")
    func otherErrorsAreNotRetried() async throws {
        let backend = FakeMusicBackend()
        let pause = RecordingPause()
        await backend.setPageError("VLPLgone", MusicError.http(404))

        await #expect(throws: MusicError.http(404)) {
            try await MusicCollectionEnumerator.enumerate("VLPLgone", source: source(backend), pause: pause.closure)
        }
        #expect(pause.waits.isEmpty)
        #expect(await backend.pageCalls == ["VLPLgone"])
    }

    @Test("cancelling while a page waits out a rate limit ends the listing")
    func cancelEndsTheWait() async throws {
        let backend = FakeMusicBackend()
        let pause = RecordingPause()
        pause.blockBackoff()
        await backend.setPageError("VLPLheld", MusicError.http(429))
        let task = Task {
            try await MusicCollectionEnumerator.enumerate(
                "VLPLheld", source: MusicCollectionSource(backend: backend), pause: pause.closure
            )
        }
        await pause.waitForCount(1)

        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await backend.pageCalls == ["VLPLheld"])
    }

    @Test("cancelling stops the enumeration at the next page")
    func cancelStops() async throws {
        let backend = FakeMusicBackend()
        let gate = MusicTestGate()
        await backend.setPage(MusicSamples.page("VLPLslow", tracks: DownloadSamples.tracks(1...3), continuation: "t1"))
        await backend.setMoreTracks(browseId: "VLPLslow", continuation: "t1", tracks: DownloadSamples.tracks(4...6), next: "t2")
        await backend.setMoreTracksGate(browseId: "VLPLslow", continuation: "t1", gate)
        let task = Task { try await MusicCollectionEnumerator.enumerate("VLPLslow", source: MusicCollectionSource(backend: backend)) }
        while await backend.moreTracksCalls.isEmpty { await Task.yield() }

        task.cancel()
        await gate.open()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await backend.moreTracksCalls.map(\.continuation) == ["t1"])
    }

    // MARK: - Which pages

    @Test("playlists, Liked music, curated playlists and albums can be downloaded; nothing else can")
    func downloadableIDs() {
        for browseId in ["VLPLabc123", "VLLM", "VLOLAK5uy_x", "VLRDCLAK5uy_curated", "MPREb_album"] {
            #expect(MusicCollectionEnumerator.isDownloadable(browseId: browseId), "\(browseId)")
        }
        for browseId in [
            "UCartist", "VLRDAMVMabc", "VLRDTMAK5uy_mix", "RDCLAK5uy_x", "RDAMVMabc", "MPADartist", "FEmusic_home", "VL", "MPRE", "",
        ] {
            #expect(!MusicCollectionEnumerator.isDownloadable(browseId: browseId), "\(browseId)")
        }
    }

    @Test("an album is told by MPRE, everything else that can be downloaded is a playlist")
    func kindOfBrowseID() {
        #expect(MusicCollectionEnumerator.kind(ofBrowseId: "MPREb_album") == .album)
        #expect(MusicCollectionEnumerator.kind(ofBrowseId: "VLPLabc") == .playlist)
        #expect(MusicCollectionEnumerator.kind(ofBrowseId: "VLLM") == .playlist)
    }

    // MARK: - The source

    @Test("the source reads sign-in and channel from the backend")
    func sourceReadsTheBackend() async {
        let backend = FakeMusicBackend(signedIn: true)
        await backend.setSessionIdentity("channel-z")
        let live = source(backend)

        #expect(await live.isSignedIn())
        #expect(await live.identity() == "channel-z")

        await backend.setSignedIn(false)
        await backend.setSessionIdentity(nil)
        #expect(await live.isSignedIn() == false)
        #expect(await live.identity() == nil)
    }
}
