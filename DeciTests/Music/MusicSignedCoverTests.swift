// DeciTests/Music/MusicSignedCoverTests.swift
// The signed cover address of a playlist with an uploaded picture, and how the browse store asks for a new one when the
// old address has expired.

import Foundation
import Testing
@testable import Deci

@Suite("MusicSignedCover")
struct MusicSignedCoverTests {
    @Test("A pl_c address on i.ytimg.com names its playlist")
    func plainHost() {
        let url = URL(string: "https://i.ytimg.com/pl_c/PLabc123/studio_square_thumbnail.jpg?sqp=AAA&rs=BBB")
        #expect(MusicSignedCover.playlistId(in: url) == "PLabc123")
    }

    @Test("The numbered mirrors i1 to i9 count too")
    func numberedHost() {
        let url = URL(string: "https://i9.ytimg.com/pl_c/PLabc123/studio_square_thumbnail.jpg?sqp=AAA&rs=BBB")
        #expect(MusicSignedCover.playlistId(in: url) == "PLabc123")
    }

    @Test("A video thumbnail is not a signed cover")
    func videoThumbnail() {
        #expect(MusicSignedCover.playlistId(in: URL(string: "https://i.ytimg.com/vi/abc/hqdefault.jpg")) == nil)
    }

    @Test("A Google-hosted picture is not a signed cover")
    func googleHosted() {
        #expect(MusicSignedCover.playlistId(in: URL(string: "https://lh3.googleusercontent.com/pl_c/PLabc/x.jpg")) == nil)
        #expect(MusicSignedCover.playlistId(in: URL(string: "https://yt3.googleusercontent.com/abc=w60")) == nil)
    }

    @Test("Other hosts of ytimg are not signed covers")
    func otherHosts() {
        #expect(MusicSignedCover.playlistId(in: URL(string: "https://i10.ytimg.com/pl_c/PLabc/x.jpg")) == nil)
        #expect(MusicSignedCover.playlistId(in: URL(string: "https://ia.ytimg.com/pl_c/PLabc/x.jpg")) == nil)
        #expect(MusicSignedCover.playlistId(in: URL(string: "https://evil.example/i.ytimg.com/pl_c/PLabc/x.jpg")) == nil)
    }

    @Test("No address has no playlist")
    func nilURL() {
        #expect(MusicSignedCover.playlistId(in: nil) == nil)
    }

    @Test("An address with no playlist id has none")
    func missingId() {
        #expect(MusicSignedCover.playlistId(in: URL(string: "https://i.ytimg.com/pl_c/")) == nil)
        #expect(MusicSignedCover.playlistId(in: URL(string: "https://i.ytimg.com/pl_c//x.jpg")) == nil)
        #expect(MusicSignedCover.playlistId(in: URL(string: "https://i.ytimg.com/pl_c/x.jpg")) == nil)
    }
}

@MainActor
private final class ClockBox {
    var date = Date(timeIntervalSince1970: 1_000_000)
}

@MainActor
@Suite("MusicBrowseStore signed covers")
struct MusicBrowseStoreSignedCoverTests {
    private let backend = FakeMusicBackend()
    private let clock = ClockBox()
    private let store: MusicBrowseStore

    private static func signed(_ id: String, _ sqp: String) -> URL {
        URL(string: "https://i.ytimg.com/pl_c/\(id)/studio_square_thumbnail.jpg?sqp=\(sqp)&rs=sig")!
    }

    init() {
        let clock = self.clock
        store = MusicBrowseStore(backend: backend, now: { clock.date })
    }

    private func page(_ browseId: String, cover: URL?) -> MusicBrowsePage {
        MusicBrowsePage(
            browseId: browseId, title: "P", subtitle: nil, thumbnailURL: cover, tracks: [], continuation: nil, shelves: []
        )
    }

    private func until(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<400 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(40))
    }

    @Test("A failed signed cover fetches the playlist's page once and keeps the new address")
    func refreshes() async {
        let old = Self.signed("PLa", "old"), fresh = Self.signed("PLa", "new")
        await backend.setPage(page("VLPLa", cover: fresh))
        #expect(store.coverURL(for: old) == nil)
        store.coverFailed(old)
        #expect(await until { store.coverURL(for: old) != nil })
        #expect(store.coverURL(for: old) == fresh)
        #expect(await backend.pageCalls == ["VLPLa"])
    }

    @Test("A cover that is not signed never reaches the backend")
    func unsignedIgnored() async {
        store.coverFailed(URL(string: "https://i.ytimg.com/vi/abc/hqdefault.jpg"))
        store.coverFailed(URL(string: "https://lh3.googleusercontent.com/abc=w60"))
        store.coverFailed(nil)
        await settle()
        #expect(await backend.pageCalls.isEmpty)
        #expect(store.freshCovers.isEmpty)
    }

    @Test("A second failure within ten minutes does not ask again")
    func rateLimited() async {
        let old = Self.signed("PLa", "old")
        await backend.setPage(page("VLPLa", cover: Self.signed("PLa", "new")))
        store.coverFailed(old)
        #expect(await until { store.coverURL(for: old) != nil })
        clock.date.addTimeInterval(9 * 60)
        store.coverFailed(old)
        await settle()
        #expect(await backend.pageCalls.count == 1)
    }

    @Test("A failure after ten minutes asks again")
    func retriesLater() async {
        let old = Self.signed("PLa", "old")
        await backend.setPage(page("VLPLa", cover: Self.signed("PLa", "new")))
        store.coverFailed(old)
        #expect(await until { store.coverURL(for: old) != nil })
        clock.date.addTimeInterval(10 * 60 + 1)
        await backend.setPage(page("VLPLa", cover: Self.signed("PLa", "newer")))
        store.coverFailed(old)
        #expect(await until { store.coverURL(for: old) == Self.signed("PLa", "newer") })
        #expect(await backend.pageCalls.count == 2)
    }

    @Test("A failed fetch is not repeated in a loop")
    func errorNotLooped() async {
        let old = Self.signed("PLa", "old")
        await backend.setPageError("VLPLa", MusicError.rejected)
        store.coverFailed(old)
        #expect(await until { await backend.pageCalls.count == 1 })
        await settle()
        store.coverFailed(old)
        await settle()
        #expect(await backend.pageCalls.count == 1)
        #expect(store.coverURL(for: old) == nil)
    }

    @Test("A page whose cover is another playlist's stores nothing")
    func differentId() async {
        await backend.setPage(page("VLPLa", cover: Self.signed("PLother", "new")))
        store.coverFailed(Self.signed("PLa", "old"))
        #expect(await until { await backend.pageCalls.count == 1 })
        await settle()
        #expect(store.freshCovers.isEmpty)
    }

    @Test("A page whose cover is not signed stores nothing")
    func unsignedAnswer() async {
        await backend.setPage(page("VLPLa", cover: URL(string: "https://lh3.googleusercontent.com/abc=w60")))
        store.coverFailed(Self.signed("PLa", "old"))
        #expect(await until { await backend.pageCalls.count == 1 })
        await settle()
        #expect(store.freshCovers.isEmpty)
    }

    @Test("A page with no cover stores nothing")
    func noCover() async {
        await backend.setPage(page("VLPLa", cover: nil))
        store.coverFailed(Self.signed("PLa", "old"))
        #expect(await until { await backend.pageCalls.count == 1 })
        await settle()
        #expect(store.freshCovers.isEmpty)
    }

    @Test("Offline nothing is asked")
    func offline() async {
        store.accountGone = { true }
        store.coverFailed(Self.signed("PLa", "old"))
        await settle()
        #expect(await backend.pageCalls.isEmpty)
    }

    @Test("A cover that failed offline is asked for when the account returns")
    func offlineAskedOnReturn() async {
        let old = Self.signed("PLa", "old"), fresh = Self.signed("PLa", "new")
        await backend.setPage(page("VLPLa", cover: fresh))
        var gone = true
        store.accountGone = { gone }
        store.coverFailed(old)
        await settle()
        #expect(await backend.pageCalls.isEmpty)
        gone = false
        store.accountReturned()
        #expect(await until { store.coverURL(for: old) == fresh })
        #expect(await backend.pageCalls == ["VLPLa"])
    }

    @Test("A second failure while the first ask is out does not ask again")
    func inFlightNotRepeated() async {
        let gate = MusicTestGate()
        await backend.setPageGate("VLPLa", gate)
        await backend.setPage(page("VLPLa", cover: Self.signed("PLa", "new")))
        let old = Self.signed("PLa", "old")
        store.coverFailed(old)
        #expect(await until { await backend.pageCalls.count == 1 })
        clock.date.addTimeInterval(11 * 60)
        store.coverFailed(old)
        await settle()
        #expect(await backend.pageCalls.count == 1)
        await gate.open()
        #expect(await until { store.coverURL(for: old) != nil })
    }

    @Test("An answer that lands after a reset is dropped")
    func resetMidFlight() async {
        let gate = MusicTestGate()
        await backend.setPageGate("VLPLa", gate)
        await backend.setPage(page("VLPLa", cover: Self.signed("PLa", "new")))
        let old = Self.signed("PLa", "old")
        store.coverFailed(old)
        #expect(await until { await backend.pageCalls.count == 1 })
        store.reset()
        await gate.open()
        await settle()
        #expect(store.freshCovers.isEmpty)
    }

    @Test("Resetting the store forgets the new addresses")
    func resetForgets() async {
        let old = Self.signed("PLa", "old")
        await backend.setPage(page("VLPLa", cover: Self.signed("PLa", "new")))
        store.coverFailed(old)
        #expect(await until { store.coverURL(for: old) != nil })
        store.reset()
        #expect(store.coverURL(for: old) == nil)
    }
}
