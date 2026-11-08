import Foundation
import Testing
@testable import Deci

@Suite struct BeatThisEngineTests {
    private enum Boom: Error { case transient, permanent }

    @Test func loadSuccessIsKeptForLife() {
        var calls = 0
        let loader = BeatThisLoader<Int>(isPermanent: { _ in false }) { calls += 1; return 7 }
        let start = Date(timeIntervalSince1970: 1_000)
        #expect((try? loader.get(now: start).get()) == 7)
        #expect((try? loader.get(now: start.addingTimeInterval(100_000)).get()) == 7)
        #expect(calls == 1)
    }

    @Test func permanentFailureIsCachedForLife() {
        var calls = 0
        let loader = BeatThisLoader<Int>(isPermanent: { ($0 as? Boom) == .permanent }) { calls += 1; throw Boom.permanent }
        let start = Date(timeIntervalSince1970: 1_000)
        _ = loader.get(now: start)
        _ = loader.get(now: start.addingTimeInterval(100_000))
        #expect(calls == 1)
    }

    @Test func transientFailureRetriesOncePerTenMinutes() {
        var calls = 0
        var succeedFrom = 3
        let loader = BeatThisLoader<Int>(isPermanent: { ($0 as? Boom) == .permanent }) {
            calls += 1
            if calls >= succeedFrom { return 42 }
            throw Boom.transient
        }
        let start = Date(timeIntervalSince1970: 1_000)
        guard case .failure = loader.get(now: start) else { Issue.record("first call should fail"); return }
        guard case .failure = loader.get(now: start.addingTimeInterval(599)) else { Issue.record("inside the window"); return }
        #expect(calls == 1)
        guard case .failure = loader.get(now: start.addingTimeInterval(601)) else { Issue.record("second try fails"); return }
        #expect(calls == 2)
        guard case .failure = loader.get(now: start.addingTimeInterval(700)) else { Issue.record("inside the new window"); return }
        #expect(calls == 2)
        #expect((try? loader.get(now: start.addingTimeInterval(1_300)).get()) == 42)
        #expect(calls == 3)
        succeedFrom = 0
        #expect((try? loader.get(now: start.addingTimeInterval(9_000)).get()) == 42)
        #expect(calls == 3)
    }

    @Test func missingBundleResourceIsThePermanentKind() throws {
        #expect(throws: BeatThisEngine.Failure.missingResource) {
            _ = try BeatThisEngine.makeTracker(bundle: try #require(Bundle(url: URL(fileURLWithPath: "/System/Library/Frameworks/Foundation.framework"))))
        }
    }

    @Test func songsLongerThanTwentyMinutesOrWithoutDurationAreNotTracked() {
        let samples = [Float](repeating: 0, count: 22_050)
        for duration in [Double.nan, .infinity, 0, -3, 1_200.5, 99_999] {
            guard case .unavailable = BeatThisEngine.grid(samples: samples, duration: duration) else {
                Issue.record("duration \(duration) should be refused")
                continue
            }
        }
    }
}
