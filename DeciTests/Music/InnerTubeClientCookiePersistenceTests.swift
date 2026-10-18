// DeciTests/Music/InnerTubeClientCookiePersistenceTests.swift
// How often the InnerTube client touches the Keychain item: every touch can prompt on a build that was
// never given "Always Allow", so rotating cookies must not write it on every response. Responses come
// from the recording fake transport, time from a hand-driven clock and scheduler; nothing sleeps.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("InnerTubeClient cookie persistence")
struct InnerTubeClientCookiePersistenceTests {

    /// The 12 cookies whose change must reach the Keychain promptly, spelled out here so an edit to the set
    /// in the app shows up as a failing test.
    nonisolated private static let signInNames = [
        "SID", "HSID", "SSID", "APISID", "SAPISID",
        "__Secure-1PSID", "__Secure-3PSID", "__Secure-1PAPISID", "__Secure-3PAPISID",
        "__Secure-1PSIDTS", "__Secure-3PSIDTS", "LOGIN_INFO",
    ]

    /// Cookies YouTube rotates on most responses; none of them is a sign-in cookie.
    nonisolated private static let otherNames = [
        "YSC", "VISITOR_INFO1_LIVE", "__Secure-1PSIDCC", "__Secure-3PSIDCC", "SIDCC",
        "__Secure-ROLLOUT_TOKEN", "PREF", "VISITOR_PRIVACY_METADATA", "__Secure-YEC",
    ]

    private struct Rig {
        let youtube: FakeYouTube
        let store: MemorySecretStore
        let clock: MutableClock
        let scheduler: ManualWriteScheduler
        let client: InnerTubeClient

        init(store: MemorySecretStore = MusicTestJar.signedInStore(), youtube: FakeYouTube = FakeYouTube()) {
            let clock = MutableClock()
            let scheduler = ManualWriteScheduler(clock: clock)
            self.youtube = youtube
            self.store = store
            self.clock = clock
            self.scheduler = scheduler
            client = InnerTubeClient(transport: youtube, secretStore: store, now: { clock.now }, scheduler: scheduler)
        }

        /// A whole second, 90 days out. HTTPCookie judges an Expires header against the real clock and caps it at
        /// 400 days from now, so a date further away would come back changed and break the comparisons below.
        static let defaultExpiry = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 + 90 * 86_400).rounded(.down))

        /// A Set-Cookie value for a youtube.com cookie that expires on `expires`.
        static func header(_ name: String, _ value: String, expires: Date = defaultExpiry) -> String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "GMT")
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
            return "\(name)=\(value); Domain=.youtube.com; Path=/; Secure; Expires=\(formatter.string(from: expires))"
        }

        /// The next search answers by setting `name`, then runs it.
        func rotate(_ name: String, _ value: String, expires: Date = defaultExpiry) async throws {
            youtube.update { $0.searchHeaders = ["Set-Cookie": Self.header(name, value, expires: expires)] }
            _ = try await client.search("q")
        }

        /// The next search answers by deleting `name`, then runs it.
        func expire(_ name: String) async throws {
            youtube.update { $0.searchHeaders = ["Set-Cookie": "\(name)=; Domain=.youtube.com; Path=/; Max-Age=0; Secure"] }
            _ = try await client.search("q")
        }
    }

    // MARK: - Cookies that do not matter for the sign-in

    @Test("Ten responses that rotate only YSC or __Secure-1PSIDCC write the Keychain zero times")
    func rotatingOtherCookiesWritesNothing() async throws {
        let rig = Rig()
        let original = rig.store.contents
        for round in 0..<10 {
            try await rig.rotate(round.isMultiple(of: 2) ? "YSC" : "__Secure-1PSIDCC", "value-\(round)")
        }
        #expect(rig.store.saveCount == 0)
        #expect(rig.store.deleteCount == 0)
        #expect(rig.store.contents == original)

        // The in-memory jar did take every rotation.
        _ = try await rig.client.search("again")
        let cookie = try #require(rig.youtube.requests(path: "/youtubei/v1/search").last?.headers["Cookie"])
        #expect(cookie.contains("YSC=value-8"))
        #expect(cookie.contains("__Secure-1PSIDCC=value-9"))
    }

    @Test("A change to any one of the other cookies writes nothing", arguments: Self.otherNames)
    func otherCookieChangeWritesNothing(name: String) async throws {
        let rig = Rig()
        try await rig.rotate(name, "first")
        try await rig.rotate(name, "second")
        try await rig.expire(name)
        #expect(rig.store.saveCount == 0)
    }

    @Test("The sign-in cookie names are the documented twelve")
    func signInCookieNamesAreTheDocumentedSet() {
        #expect(MusicCookieJar.signInCookieNames == Set(Self.signInNames))
    }

    // MARK: - Sign-in cookies

    @Test("A __Secure-1PSIDTS change writes once, at once")
    func signInCookieChangeWritesOnce() async throws {
        let rig = Rig()
        try await rig.rotate("__Secure-1PSIDTS", "fresh")
        #expect(rig.store.saveCount == 1)
        #expect(try #require(rig.store.storedJar).value(named: "__Secure-1PSIDTS") == "fresh")
    }

    @Test("Two sign-in changes 10 s apart: one write at once, one coalesced write at the minute")
    func signInChangesCoalesce() async throws {
        let rig = Rig()
        try await rig.rotate("__Secure-1PSIDTS", "first")
        #expect(rig.store.saveCount == 1)

        rig.scheduler.advance(by: 10)
        try await rig.rotate("__Secure-1PSIDTS", "second")
        #expect(rig.store.saveCount == 1)
        #expect(try #require(rig.store.storedJar).value(named: "__Secure-1PSIDTS") == "first")

        rig.scheduler.advance(by: 49)
        #expect(rig.store.saveCount == 1)
        rig.scheduler.advance(by: 1)
        #expect(rig.store.saveCount == 2)
        #expect(try #require(rig.store.storedJar).value(named: "__Secure-1PSIDTS") == "second")
        #expect(rig.scheduler.pendingCount == 0)
    }

    @Test("Each sign-in cookie, new or changed, is written at once", arguments: Self.signInNames)
    func everySignInCookieIsWritten(name: String) async throws {
        let base = Set(MusicTestJar.signedInCookies().filter { MusicCookieJar.isYouTubeDomain($0.domain) }.map(\.name))
        let seeded = base.contains(name) ? [] : [MusicTestJar.cookie(name, "old")]
        let rig = Rig(store: MusicTestJar.signedInStore(adding: seeded))

        try await rig.rotate(name, "changed-value")
        #expect(rig.store.saveCount == 1)
        #expect(try #require(rig.store.storedJar).value(named: name) == "changed-value")
    }

    @Test("A sign-in cookie that is deleted or only gets a new expiry counts as a change")
    func deletionAndExpiryAreChanges() async throws {
        let seeded = [MusicTestJar.cookie("LOGIN_INFO", "login"), MusicTestJar.cookie("__Secure-1PSIDTS", "same")]

        let deleted = Rig(store: MusicTestJar.signedInStore(adding: seeded))
        try await deleted.expire("LOGIN_INFO")
        #expect(deleted.store.saveCount == 1)
        #expect(try #require(deleted.store.storedJar).value(named: "LOGIN_INFO") == nil)

        let renewed = Rig(store: MusicTestJar.signedInStore(adding: seeded))
        try await renewed.rotate("__Secure-1PSIDTS", "same")
        #expect(renewed.store.saveCount == 1)
        let expiry = try #require(renewed.store.storedJar?.cookies.first { $0.name == "__Secure-1PSIDTS" }?.expires)
        #expect(expiry == Rig.defaultExpiry)
    }

    @Test("A sign-in cookie sent again unchanged writes nothing")
    func unchangedSignInCookieWritesNothing() async throws {
        let seeded = MusicTestJar.cookie("__Secure-1PSIDTS", "same", expires: Rig.defaultExpiry)
        let rig = Rig(store: MusicTestJar.signedInStore(adding: [seeded]))
        try await rig.rotate("__Secure-1PSIDTS", "same")
        #expect(rig.store.saveCount == 0)
    }

    // MARK: - What the saved jar holds

    @Test("The jar that is written still holds the cookies that only marked it dirty")
    func savedJarKeepsEveryCookie() async throws {
        let rig = Rig()
        try await rig.rotate("YSC", "ysc-1")
        try await rig.rotate("PREF", "f6=40000000")
        try await rig.rotate("__Secure-ROLLOUT_TOKEN", "rollout-1")
        #expect(rig.store.saveCount == 0)

        try await rig.rotate("SAPISID", "rotated-sapisid")
        #expect(rig.store.saveCount == 1)
        let saved = try #require(rig.store.storedJar)
        #expect(saved.value(named: "YSC") == "ysc-1")
        #expect(saved.value(named: "PREF") == "f6=40000000")
        #expect(saved.value(named: "__Secure-ROLLOUT_TOKEN") == "rollout-1")
        #expect(saved.value(named: "SAPISID") == "rotated-sapisid")
        #expect(saved.value(named: "__Secure-3PAPISID") == "three-papisid-secret")
        #expect(saved.value(named: "__Secure-1PAPISID") == "one-papisid-secret")
    }

    // MARK: - Quit flush

    @Test("flushNow with dirty non-sign-in changes saves once, with those changes in it")
    func flushWritesDirtyChanges() async throws {
        let rig = Rig()
        try await rig.rotate("YSC", "ysc-1")
        try await rig.rotate("PREF", "pref-1")
        rig.client.flushNow()
        #expect(rig.store.saveCount == 1)
        let saved = try #require(rig.store.storedJar)
        #expect(saved.value(named: "YSC") == "ysc-1")
        #expect(saved.value(named: "PREF") == "pref-1")

        rig.client.flushNow()
        #expect(rig.store.saveCount == 1)
    }

    @Test("flushNow with nothing dirty saves zero times")
    func flushWithNothingDirty() async throws {
        let rig = Rig()
        _ = try await rig.client.search("q")
        rig.client.flushNow()
        #expect(rig.store.saveCount == 0)
    }

    @Test("flushNow before the client has done anything touches nothing")
    func flushBeforeAnyUse() {
        let rig = Rig()
        rig.client.flushNow()
        #expect(rig.store.loadCount == 0)
        #expect(rig.store.saveCount == 0)
        #expect(rig.store.deleteCount == 0)
    }

    @Test("Dirty changes are written by themselves 30 minutes later when the app keeps running")
    func dirtyChangesAreWrittenPeriodically() async throws {
        let rig = Rig()
        try await rig.rotate("YSC", "ysc-1")
        rig.scheduler.advance(by: 29 * 60)
        #expect(rig.store.saveCount == 0)
        rig.scheduler.advance(by: 60)
        #expect(rig.store.saveCount == 1)
        #expect(try #require(rig.store.storedJar).value(named: "YSC") == "ysc-1")
    }

    @Test("A refused write does not fail the request, and the quit flush tries again")
    func refusedWriteIsRetriedAtQuit() async throws {
        let rig = Rig()
        rig.store.failSaves = true
        try await rig.rotate("__Secure-1PSIDTS", "fresh")
        #expect(rig.store.saveCount == 0)

        rig.store.failSaves = false
        rig.client.flushNow()
        #expect(rig.store.saveCount == 1)
        #expect(try #require(rig.store.storedJar).value(named: "__Secure-1PSIDTS") == "fresh")
    }

    // MARK: - signIn

    @Test("signIn saves at once, without reading the item first")
    func signInSavesAtOnce() async throws {
        let rig = Rig(store: MemorySecretStore())
        try await rig.client.signIn(with: MusicTestJar.signedInCookies())
        #expect(rig.store.saveCount == 1)
        #expect(rig.store.loadCount == 0)
    }

    @Test("signIn saves at once even a few seconds after a sign-in cookie write: a channel switch or account swap must stick")
    func signInIgnoresTheWindow() async throws {
        let rig = Rig()
        try await rig.rotate("__Secure-1PSIDTS", "fresh")
        rig.scheduler.advance(by: 5)
        try await rig.client.signIn(with: [MusicTestJar.cookie("SAPISID", "picked-sapisid"), MusicTestJar.cookie("PREF", "brand")])
        #expect(rig.store.saveCount == 2)
        #expect(try #require(rig.store.storedJar).value(named: "SAPISID") == "picked-sapisid")
    }

    @Test("signIn replaces dirty data: the old session's cookies are never written afterwards")
    func signInDropsDirtyData() async throws {
        let rig = Rig()
        try await rig.rotate("YSC", "old-session-ysc")
        try await rig.client.signIn(with: [MusicTestJar.cookie("SAPISID", "new-account")])
        #expect(rig.store.saveCount == 1)

        rig.client.flushNow()
        rig.scheduler.advance(by: 3 * 60 * 60)
        #expect(rig.store.saveCount == 1)
        let saved = try #require(rig.store.storedJar)
        #expect(saved.value(named: "SAPISID") == "new-account")
        #expect(saved.value(named: "YSC") == nil)
    }

    // MARK: - Sign-out

    @Test("Sign-out, then flushNow: nothing is written and the item stays deleted")
    func signOutThenFlush() async throws {
        let rig = Rig()
        try await rig.rotate("YSC", "ysc-1")
        await rig.client.signOut()
        rig.client.flushNow()

        #expect(rig.store.saveCount == 0)
        #expect(rig.store.deleteCount == 1)
        #expect(rig.store.contents == nil)
    }

    @Test("Sign-out cancels a coalesced sign-in write that was waiting for its minute")
    func signOutDropsTheWaitingWrite() async throws {
        let rig = Rig()
        try await rig.rotate("__Secure-1PSIDTS", "first")
        rig.scheduler.advance(by: 10)
        try await rig.rotate("__Secure-1PSIDTS", "second")
        await rig.client.signOut()

        rig.scheduler.advance(by: 3 * 60 * 60)
        rig.client.flushNow()
        #expect(rig.store.saveCount == 1, "only the write from before the sign-out")
        #expect(rig.store.contents == nil)
        #expect(rig.scheduler.pendingCount == 0)
    }

    @Test("A timer that had already started when the user signed out writes nothing")
    func signOutBeatsAStartedTimer() async throws {
        let rig = Rig()
        try await rig.rotate("__Secure-1PSIDTS", "first")
        try await rig.rotate("__Secure-1PSIDTS", "second")
        try await rig.rotate("YSC", "ysc-1")
        await rig.client.signOut()
        rig.scheduler.fireEverything()

        #expect(rig.store.saveCount == 1)
        #expect(rig.store.contents == nil)
    }

    @Test("Sign-out drops the periodic write too")
    func signOutDropsThePeriodicWrite() async throws {
        let rig = Rig()
        try await rig.rotate("YSC", "ysc-1")
        await rig.client.signOut()
        rig.scheduler.advance(by: 3 * 60 * 60)
        #expect(rig.store.saveCount == 0)
        #expect(rig.store.contents == nil)
    }

    @Test("A response that lands after sign-out leaves nothing to flush")
    func lateResponseLeavesNothingToFlush() async throws {
        let gate = MusicTestGate()
        let rig = Rig()
        _ = try await rig.client.session()
        rig.youtube.update {
            $0.gate = gate
            $0.searchHeaders = ["Set-Cookie": Rig.header("YSC", "late-ysc")]
        }
        let search = Task { try await rig.client.search("a") }
        #expect(await eventually { rig.youtube.requests(path: "/youtubei/v1/search").count == 1 })

        await rig.client.signOut()
        await gate.open()
        _ = try? await search.value
        rig.client.flushNow()

        #expect(rig.store.saveCount == 0)
        #expect(rig.store.contents == nil)
    }

    @Test("Signing in again after a sign-out writes the new session and only that")
    func signOutThenSignIn() async throws {
        let rig = Rig()
        try await rig.rotate("YSC", "old-ysc")
        await rig.client.signOut()
        try await rig.client.signIn(with: [MusicTestJar.cookie("SAPISID", "second-account")])
        rig.client.flushNow()

        #expect(rig.store.saveCount == 1)
        let saved = try #require(rig.store.storedJar)
        #expect(saved.value(named: "SAPISID") == "second-account")
        #expect(saved.value(named: "YSC") == nil)
    }

    // MARK: - Reads

    @Test("The client never reads the item until it needs the jar, and then only once")
    func loadedAtMostOnce() async throws {
        let rig = Rig()
        #expect(rig.store.loadCount == 0)

        #expect(await rig.client.isSignedIn())
        _ = try await rig.client.session()
        for round in 0..<6 {
            try await rig.rotate("YSC", "ysc-\(round)")
        }
        _ = try await rig.client.radio(seedVideoId: "4D7u5KF7SP8")
        _ = try await rig.client.accountInfo()
        _ = await rig.client.channelIdentity()
        _ = await rig.client.sessionCookies()
        try await rig.rotate("__Secure-1PSIDTS", "fresh")
        rig.client.flushNow()

        await rig.client.signOut()
        #expect(await rig.client.isSignedIn() == false)
        #expect(rig.store.loadCount == 1)
    }

    @Test("sessionCookies, which seeds the channel picker, hands out the in-memory jar")
    func sessionCookiesComeFromMemory() async throws {
        let rig = Rig()
        try await rig.rotate("YSC", "only-in-memory")
        let cookies = await rig.client.sessionCookies()
        #expect(cookies.contains { $0.name == "YSC" && $0.value == "only-in-memory" })
        #expect(rig.store.storedJar?.value(named: "YSC") == nil)
        #expect(rig.store.loadCount == 1)
    }
}

/// The quit path and the Switch channel path, end to end through the real backend and service.
@MainActor
@Suite("Music Keychain traffic")
struct MusicKeychainTrafficTests {

    private struct Rig {
        let youtube = FakeYouTube()
        let store = MusicTestJar.signedInStore()
        let clock = MutableClock()
        let scheduler: ManualWriteScheduler
        let backend: MusicBackendLive
        let directory: URL

        init() {
            scheduler = ManualWriteScheduler(clock: clock)
            directory = makeTemporaryDirectory("deci-keychain-traffic")
            let clock = self.clock
            let client = InnerTubeClient(transport: youtube, secretStore: store, now: { clock.now }, scheduler: scheduler)
            let cache = PlayerCache(directory: directory)
            let resolver = StreamResolver(client: client, solver: FakeChallengeSolver(), cache: cache, now: { clock.now })
            backend = MusicBackendLive(client: client, resolver: resolver)
        }
    }

    @MainActor
    private final class Picker {
        var sessions: [[StoredCookie]] = []
        var completion: (@MainActor ([StoredCookie]?) -> Void)?
    }

    @Test("MusicBackendLive.flushCookies writes the held-back cookies from a plain synchronous call")
    func backendFlush() async throws {
        let rig = Rig()
        defer { try? FileManager.default.removeItem(at: rig.directory) }
        rig.youtube.update { $0.searchHeaders = ["Set-Cookie": "YSC=ysc-1; Domain=.youtube.com; Path=/; Secure; Expires=Wed, 01 Jan 2031 00:00:00 GMT"] }
        _ = try await rig.backend.search("q")
        #expect(rig.store.saveCount == 0)

        rig.backend.flushCookies()
        #expect(rig.store.saveCount == 1)
        #expect(rig.store.storedJar?.value(named: "YSC") == "ysc-1")
    }

    @Test("Opening the sign-in state, the account card and Switch channel twice reads the Keychain once")
    func everyOtherLoadSiteUsesMemory() async throws {
        let rig = Rig()
        defer { try? FileManager.default.removeItem(at: rig.directory) }
        let picker = Picker()
        let service = MusicService(
            backend: rig.backend,
            player: MusicPlayer(engine: FakePlaybackEngine()),
            presentSignIn: { _ in },
            presentChannelPicker: { session, completion in
                picker.sessions.append(session)
                picker.completion = completion
            },
            closeSignInWindow: {},
            raiseSignInWindow: {},
            nowPlaying: NowPlayingController(surface: FakeNowPlayingSurface(), fetchArtwork: { _ in nil }),
            refreshOnCreate: false
        )

        await service.refreshAuth()
        await service.identityTask?.value
        await service.accountTask?.value
        #expect(service.authState == .signedIn)
        #expect(rig.store.loadCount == 1)

        // Switch channel: the picker is seeded from the backend, then the pick signs in again.
        service.switchChannel()
        await service.channelSwitchTask?.value
        picker.completion?([MusicTestJar.cookie("SAPISID", "picked-sapisid"), MusicTestJar.cookie("PREF", "brand-channel")])
        await service.channelSwitchTask?.value
        await service.accountTask?.value

        // And again: the second picker starts from the session the first pick installed.
        service.switchChannel()
        await service.channelSwitchTask?.value
        picker.completion?(nil)

        #expect(picker.sessions.count == 2)
        #expect(picker.sessions[1].contains { $0.name == "SAPISID" && $0.value == "picked-sapisid" })
        #expect(rig.store.loadCount == 1)
        #expect(rig.store.saveCount == 1, "the pick is the only write")
    }
}
