// DeciTests/Music/MusicBackgroundAnalyzerTests.swift
// Tier 2a P4: the idle queue. Every block rule, one song at a time, the gap and the hourly cap, the rate-limit holds,
// the order (liked, playlists, old versions last), fresh songs skipped, and a block or the toggle cancelling the song in
// flight. A fake environment, a fake provider, an injected clock and a sleep that moves that clock: nothing waits for real.

import Foundation
import Testing
@testable import Deci

actor FakeBackgroundEnv: MusicBackgroundEnvironment {
    struct State: Sendable {
        var enabled = true
        var playing = false
        var online = true
        var signedIn = true
        var downloadsBusy = false
        var lowPower = false
        var thermal = false
        var battery = MusicBatteryState(onBattery: false, fraction: nil)
    }

    private var state = State()
    func set(_ change: @Sendable (inout State) -> Void) { change(&state) }

    func isEnabled() -> Bool { state.enabled }
    func isPlaying() -> Bool { state.playing }
    func isOnline() -> Bool { state.online }
    func isSignedIn() -> Bool { state.signedIn }
    func isDownloadsBusy() -> Bool { state.downloadsBusy }
    func isLowPowerMode() -> Bool { state.lowPower }
    func isThermallyConstrained() -> Bool { state.thermal }
    func battery() -> MusicBatteryState { state.battery }
}

actor FakeBackgroundProvider: MusicAnalysisProviding, MusicAnalysisLookup {
    enum Behavior: Sendable {
        case analysed, fresh, rateLimited
        /// Runs until it is cancelled.
        case hang
    }

    private let clock: MutableClock
    private(set) var ensures: [(id: String, at: Date, wantsFile: Bool)] = []
    private(set) var cancels: [String] = []
    private(set) var peak = 0
    private var running = 0
    private var behaviors: [String: Behavior] = [:]
    private var entries: Set<String> = []
    private var stale: [String] = []

    init(clock: MutableClock) { self.clock = clock }

    func set(_ id: String, _ behavior: Behavior) { behaviors[id] = behavior }
    func setEntries(_ ids: [String]) { entries = Set(ids) }
    func setStale(_ ids: [String]) { stale = ids; entries.formUnion(ids) }
    var ids: [String] { ensures.map(\.id) }

    func ensure(stream: ResolvedStream, wantsFile: Bool) async -> MusicAnalysisCoordinator.Outcome {
        let id = stream.videoId
        ensures.append((id, clock.now, wantsFile))
        running += 1
        peak = max(peak, running)
        defer { running -= 1 }
        await Task.yield()
        switch behaviors[id] ?? .analysed {
        case .analysed:
            entries.insert(id)
            stale.removeAll { $0 == id }
            return .analysed(file: nil)
        case .fresh:
            return .alreadyFresh
        case .rateLimited:
            return .rateLimited
        case .hang:
            while !Task.isCancelled, !cancels.contains(id) { await Task.yield() }
            return .failed
        }
    }

    func release(videoId: String) {}
    func discard(videoId: String) {}
    func cancel(videoId: String) { cancels.append(videoId) }

    func hasEntry(_ videoId: String) -> Bool { entries.contains(videoId) }
    func staleVideoIds(limit: Int) -> [String] { Array(stale.prefix(limit)) }
}

@MainActor
private struct BackgroundRig {
    let clock = MutableClock()
    let env = FakeBackgroundEnv()
    let provider: FakeBackgroundProvider

    init() { provider = FakeBackgroundProvider(clock: clock) }

    static func id(_ n: Int) -> String { String(format: "vid%08d", n) }

    func make(
        liked: [String] = [], playlists: [String: [String]] = [:], order: [String]? = nil, policy: MusicBackgroundAnalyzer.Policy = .init()
    ) -> MusicBackgroundAnalyzer {
        let clock = clock
        let source = MusicBackgroundSource(
            liked: { liked },
            playlistIDs: { order ?? playlists.keys.sorted() },
            playlistSongs: { playlists[$0] ?? [] }
        )
        return MusicBackgroundAnalyzer(
            provider: provider, lookup: provider, source: source,
            resolve: { MusicSamples.stream(videoId: $0, duration: 200) },
            env: env, policy: policy, now: { clock.now },
            sleep: { seconds in
                try Task.checkCancellation()
                clock.advance(by: seconds)
                await Task.yield()
            }
        )
    }

    /// Waits (really, a few ms at a time) until `condition` holds.
    func until(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<5000 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return false
    }

    /// A while in which a wrongly running queue would have started something.
    func settleAwhile() async { try? await Task.sleep(for: .milliseconds(60)) }
}

@MainActor
@Suite("Music background analyzer")
struct MusicBackgroundAnalyzerTests {
    // MARK: Block rules

    @Test("every block rule names itself, and an idle machine is not blocked")
    func blockRules() async {
        let cases: [(String, MusicBackgroundAnalyzer.Block?, @Sendable (inout FakeBackgroundEnv.State) -> Void)] = [
            ("idle", nil, { _ in }),
            ("toggle off", .disabled, { $0.enabled = false }),
            ("playing", .playing, { $0.playing = true }),
            ("offline", .offline, { $0.online = false }),
            ("signed out", .signedOut, { $0.signedIn = false }),
            ("downloads busy", .downloadsBusy, { $0.downloadsBusy = true }),
            ("low power mode", .lowPowerMode, { $0.lowPower = true }),
            ("thermal serious", .thermal, { $0.thermal = true }),
            ("battery 49%", .battery, { $0.battery = MusicBatteryState(onBattery: true, fraction: 0.49) }),
            ("battery 50%", nil, { $0.battery = MusicBatteryState(onBattery: true, fraction: 0.5) }),
            ("battery 90%", nil, { $0.battery = MusicBatteryState(onBattery: true, fraction: 0.9) }),
            ("plugged in at 10%", nil, { $0.battery = MusicBatteryState(onBattery: false, fraction: 0.1) }),
            ("no battery at all", nil, { $0.battery = MusicBatteryState(onBattery: false, fraction: nil) }),
        ]
        for (name, expected, change) in cases {
            let rig = BackgroundRig()
            await rig.env.set(change)
            let block = await rig.make().currentBlock()
            #expect(block == expected, "\(name)")
        }
    }

    @Test("playback blocks until 60 s after it stopped")
    func quietAfterPlayback() async {
        let rig = BackgroundRig()
        let analyzer = rig.make()
        await rig.env.set { $0.playing = true }
        #expect(await analyzer.currentBlock() == .playing)

        await rig.env.set { $0.playing = false }
        #expect(await analyzer.currentBlock() == .recentlyPlayed)
        rig.clock.advance(by: 59)
        #expect(await analyzer.currentBlock() == .recentlyPlayed)
        rig.clock.advance(by: 2)
        #expect(await analyzer.currentBlock() == nil)
    }

    @Test("nothing runs while blocked, and the queue starts once the block lifts")
    func blockedThenLifted() async {
        let rig = BackgroundRig()
        await rig.env.set { $0.downloadsBusy = true }
        let analyzer = rig.make(liked: [BackgroundRig.id(1)])
        await analyzer.start()
        await rig.settleAwhile()
        #expect(await rig.provider.ids.isEmpty)

        await rig.env.set { $0.downloadsBusy = false }
        #expect(await rig.until { await rig.provider.ids.count == 1 })
        await analyzer.stop()
    }

    // MARK: Pacing

    @Test("one song at a time, at least 20 s apart, never keeping a file")
    func pacing() async {
        let rig = BackgroundRig()
        let ids = (1...5).map(BackgroundRig.id)
        let analyzer = rig.make(liked: ids)
        await analyzer.start()
        #expect(await rig.until { await rig.provider.ids.count == 5 })
        await analyzer.stop()

        let ensures = await rig.provider.ensures
        #expect(ensures.map(\.id) == ids)
        for pair in zip(ensures, ensures.dropFirst()) {
            #expect(pair.1.at.timeIntervalSince(pair.0.at) >= 20)
        }
        #expect(ensures.allSatisfy { !$0.wantsFile })
        #expect(await rig.provider.peak == 1)
    }

    @Test("at most 30 songs an hour: the 31st waits for the first to age out")
    func hourlyCap() async {
        let rig = BackgroundRig()
        let analyzer = rig.make(liked: (1...35).map(BackgroundRig.id))
        await analyzer.start()
        #expect(await rig.until { await rig.provider.ids.count >= 31 })
        await analyzer.stop()

        let ensures = await rig.provider.ensures
        #expect(ensures[30].at.timeIntervalSince(ensures[0].at) >= 3600)
        #expect(ensures[29].at.timeIntervalSince(ensures[0].at) < 3600)
    }

    @Test("a rate limit holds the queue 600 s, a second one 3600 s")
    func rateLimitBackoff() async {
        let rig = BackgroundRig()
        let ids = (1...3).map(BackgroundRig.id)
        await rig.provider.set(ids[0], .rateLimited)
        await rig.provider.set(ids[1], .rateLimited)
        let analyzer = rig.make(liked: ids)
        await analyzer.start()
        #expect(await rig.until { await rig.provider.ids.count == 3 })
        await analyzer.stop()

        let ensures = await rig.provider.ensures
        let first = ensures[1].at.timeIntervalSince(ensures[0].at)
        let second = ensures[2].at.timeIntervalSince(ensures[1].at)
        #expect(first >= 600 && first < 1000)
        #expect(second >= 3600 && second < 4000)
    }

    @Test("a success resets the strikes: the next rate limit holds 600 s again")
    func strikesReset() async {
        let rig = BackgroundRig()
        let ids = (1...3).map(BackgroundRig.id)
        await rig.provider.set(ids[0], .rateLimited)
        await rig.provider.set(ids[2], .rateLimited)
        let analyzer = rig.make(liked: ids + [BackgroundRig.id(4)])
        await analyzer.start()
        #expect(await rig.until { await rig.provider.ids.count == 4 })
        await analyzer.stop()

        let ensures = await rig.provider.ensures
        let afterSecondLimit = ensures[3].at.timeIntervalSince(ensures[2].at)
        #expect(afterSecondLimit >= 600 && afterSecondLimit < 1000)
    }

    @Test("429 and 403 are rate limits, a 404 and a bad length are not")
    func rateLimitClassification() {
        #expect(MusicBackgroundAnalyzer.isRateLimit(MusicDownloadError.badStatus(429)))
        #expect(MusicBackgroundAnalyzer.isRateLimit(MusicDownloadError.badStatus(403)))
        #expect(MusicBackgroundAnalyzer.isRateLimit(MusicDownloadError.reResolveLimit))
        #expect(!MusicBackgroundAnalyzer.isRateLimit(MusicDownloadError.badStatus(404)))
        #expect(!MusicBackgroundAnalyzer.isRateLimit(MusicDownloadError.lengthMismatch))
        #expect(!MusicBackgroundAnalyzer.isRateLimit(URLError(.timedOut)))
    }

    // MARK: Order and skipping

    @Test("liked songs first, then the playlists in order, old versions last; songs with an entry are skipped")
    func order() async {
        let rig = BackgroundRig()
        let (l1, l2, a, b, s1) = (BackgroundRig.id(1), BackgroundRig.id(2), BackgroundRig.id(3), BackgroundRig.id(4), BackgroundRig.id(5))
        await rig.provider.setEntries([l2])
        await rig.provider.setStale([s1])
        // The playlist order is the library's: p2 before p1 here, so the order is not alphabetical by accident.
        let analyzer = rig.make(
            liked: [l1, l2], playlists: ["VLp1": [a, l1], "VLp2": [b]], order: ["VLp2", "VLp1"]
        )
        await analyzer.start()
        #expect(await rig.until { await rig.provider.ids.count == 4 })
        await rig.settleAwhile()
        await analyzer.stop()

        #expect(await rig.provider.ids == [l1, b, a, s1])
    }

    @Test("songs that turn out fresh cost no hourly slot")
    func freshOutcomeIsFree() async {
        let rig = BackgroundRig()
        let ids = (1...35).map(BackgroundRig.id)
        for id in ids { await rig.provider.set(id, .fresh) }
        let analyzer = rig.make(liked: ids)
        await analyzer.start()
        #expect(await rig.until { await rig.provider.ids.count == 35 })
        await analyzer.stop()

        let ensures = await rig.provider.ensures
        #expect(ensures[34].at.timeIntervalSince(ensures[0].at) < 3600, "35 fresh songs never hit the cap of 30")
    }

    // MARK: Cancelling

    @Test("a block in the middle of a song cancels it, and the song waits for the block to lift")
    func cancelOnBlock() async {
        let rig = BackgroundRig()
        let id = BackgroundRig.id(1)
        await rig.provider.set(id, .hang)
        let analyzer = rig.make(liked: [id])
        await analyzer.start()
        #expect(await rig.until { await rig.provider.ids.count == 1 })

        await rig.env.set { $0.playing = true }
        #expect(await rig.until { await rig.provider.cancels.contains(id) })
        await rig.settleAwhile()
        #expect(await rig.provider.ids.count == 1, "nothing starts while something plays")
        #expect(await analyzer.analysedCount == 0)

        // The song was not counted as tried: it is the next one once the block lifts.
        await rig.provider.set(id, .analysed)
        await rig.env.set { $0.playing = false }
        #expect(await rig.until { await rig.provider.ids.count == 2 })
        #expect(await rig.provider.ids == [id, id])
        await analyzer.stop()
    }

    @Test("turning the toggle off mid-song cancels it and the queue stops")
    func toggleOffMidSong() async {
        let rig = BackgroundRig()
        let ids = (1...2).map(BackgroundRig.id)
        await rig.provider.set(ids[0], .hang)
        let analyzer = rig.make(liked: ids)
        await analyzer.start()
        #expect(await rig.until { await rig.provider.ids.count == 1 })

        await rig.env.set { $0.enabled = false }
        #expect(await rig.until { await rig.provider.cancels.contains(ids[0]) })
        await rig.settleAwhile()
        #expect(await rig.provider.ids.count == 1)
        await analyzer.stop()
    }

    @Test("with the toggle off nothing runs, and turning it on starts the queue")
    func toggleOffThenOn() async {
        let rig = BackgroundRig()
        await rig.env.set { $0.enabled = false }
        let analyzer = rig.make(liked: [BackgroundRig.id(1)])
        await analyzer.start()
        await rig.settleAwhile()
        #expect(await rig.provider.ids.isEmpty)

        await rig.env.set { $0.enabled = true }
        #expect(await rig.until { await rig.provider.ids.count == 1 })
        await analyzer.stop()
    }

    @Test("stop cancels the song in flight and ends the loop")
    func stopCancels() async {
        let rig = BackgroundRig()
        let id = BackgroundRig.id(1)
        await rig.provider.set(id, .hang)
        let analyzer = rig.make(liked: [id])
        await analyzer.start()
        #expect(await analyzer.isRunning)
        #expect(await rig.until { await rig.provider.ids.count == 1 })

        await analyzer.stop()
        #expect(await analyzer.isRunning == false)
        #expect(await rig.until { await rig.provider.cancels.contains(id) })
    }

    @Test("stop then start while the first loop is mid-scan leaves one loop that scans afresh")
    func restartLeavesOneLoop() async {
        let rig = BackgroundRig()
        let ids = (1...3).map(BackgroundRig.id)
        let staleID = BackgroundRig.id(99)
        let gate = MusicTestGate()
        let calls = LikedCalls()
        let clock = rig.clock
        let source = MusicBackgroundSource(
            liked: {
                if calls.next() == 1 {
                    await gate.wait()
                    return [staleID]
                }
                return ids
            },
            playlistIDs: { [] },
            playlistSongs: { _ in [] }
        )
        let analyzer = MusicBackgroundAnalyzer(
            provider: rig.provider, lookup: rig.provider, source: source,
            resolve: { MusicSamples.stream(videoId: $0, duration: 200) },
            env: rig.env, now: { clock.now },
            sleep: { seconds in
                try Task.checkCancellation()
                clock.advance(by: seconds)
                await Task.yield()
            }
        )
        await analyzer.start()
        #expect(await rig.until { calls.count == 1 })

        await analyzer.stop()
        await analyzer.start()
        await gate.open()

        #expect(await rig.until { await rig.provider.ids.count >= 3 })
        await rig.settleAwhile()
        #expect(await rig.provider.ids == ids, "each song once, in order, from the new loop; the stopped loop's list is dropped")
        #expect(await rig.provider.peak == 1)
        await analyzer.stop()
    }
}

private nonisolated final class LikedCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var total = 0
    var count: Int { lock.withLock { total } }
    func next() -> Int { lock.withLock { total += 1; return total } }
}
