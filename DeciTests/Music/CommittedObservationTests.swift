// DeciTests/Music/CommittedObservationTests.swift
// The chip follows the Music service, which is made lazily. Tracking again from inside onChange (willSet) would
// still see the service as nil and never follow its player; CommittedObservation tracks again once a change landed.

import Observation
import Testing
@testable import Deci

@MainActor
@Suite("CommittedObservation")
struct CommittedObservationTests {
    @Observable
    final class Child {
        var value = 0
    }

    @Observable
    final class Parent {
        var child: Child?
        var flag = false
    }

    final class Counter {
        var count = 0
    }

    /// Lets the main actor run the tasks a change scheduled, for up to a second.
    private func waitFor(_ condition: () -> Bool) async {
        for _ in 0..<100 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("a child made after tracking began is followed")
    func followsLateChild() async {
        let parent = Parent()
        let counter = Counter()
        CommittedObservation.track {
            _ = parent.child?.value
        } onChange: {
            counter.count += 1
        }

        parent.child = Child()
        await waitFor { counter.count == 1 }
        #expect(counter.count == 1)

        parent.child?.value = 1
        await waitFor { counter.count == 2 }
        #expect(counter.count == 2)
    }

    @Test("every change is reported, not only the first")
    func keepsTracking() async {
        let parent = Parent()
        let counter = Counter()
        CommittedObservation.track {
            _ = parent.flag
        } onChange: {
            counter.count += 1
        }

        for expected in 1...3 {
            parent.flag.toggle()
            await waitFor { counter.count == expected }
            #expect(counter.count == expected)
        }
    }
}
