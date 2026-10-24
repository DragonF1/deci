// FineTuneTests/MenuBarPopupControllerTests.swift
import Testing
import AppKit
@testable import Deci

@Suite("MenuBarPopupController", .serialized)
@MainActor
struct MenuBarPopupControllerTests {
    /// Makes a status item for a test and gives it its own autosave name right away.
    /// A new item is named "Item-0", the test host shares com.abraham.Deci with the installed
    /// app, and removing it deleted the Mixer's saved spot so the icon came back hidden at the far left.
    private func makeTestStatusItem(title: String) -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "DeciTest-\(UUID().uuidString)"
        item.button?.setAccessibilityTitle(title)
        return item
    }

    @Test("toggle is a no-op when no matching status item exists")
    func noMatchingItem() {
        // Use a deliberately unique accessibility title so no real status item
        // (e.g. one materialized by another concurrently-running test) can match.
        let controller = MenuBarPopupController(accessibilityTitle: "FineTuneTest-NoSuchItem-\(UUID().uuidString)")
        controller.toggle()  // must not crash; logs a debug message and returns
    }

    @Test("findStatusItem returns nil when no matching status item exists")
    func findReturnsNilWhenNoMatch() {
        let controller = MenuBarPopupController(accessibilityTitle: "FineTuneTest-NoSuchItem-\(UUID().uuidString)")
        #expect(controller.findStatusItem() == nil)
    }

    @Test("findStatusItem locates the matching status item by accessibility title")
    func findLocatesMatching() {
        let title = "FineTuneTest-Match-\(UUID().uuidString)"
        let statusItem = makeTestStatusItem(title: title)
        defer { NSStatusBar.system.removeStatusItem(statusItem) }

        // Materialize the button window so KVC has a fully-formed window to walk.
        _ = statusItem.button?.window?.windowNumber

        let controller = MenuBarPopupController(accessibilityTitle: title)
        let found = controller.findStatusItem()

        #expect(found === statusItem)
    }

    @Test("findStatusItem ignores items with non-matching accessibility titles")
    func findIgnoresNonMatching() {
        let otherTitle = "FineTuneTest-Other-\(UUID().uuidString)"
        let other = makeTestStatusItem(title: otherTitle)
        defer { NSStatusBar.system.removeStatusItem(other) }
        _ = other.button?.window?.windowNumber

        let controller = MenuBarPopupController(accessibilityTitle: "FineTuneTest-Searching-\(UUID().uuidString)")
        #expect(controller.findStatusItem() == nil)
    }

    @Test("toggle on a discovered status item runs to completion without crashing")
    func toggleEndToEndSmoke() {
        // We don't assert event delivery here — `NSApp.postEvent` -> `LocalEventMonitor`
        // round-trips inside a unit-test process are flaky because the test runner's
        // event-pump differs from a normal app's. Production validation lives in the
        // manual smoke check in /ft-verify and Phase 8 of the plan. This test
        // exercises the full discovery + event-construction path so a regression
        // (nil event, missing window, KVC failure) surfaces as a crash or early return.
        let title = "FineTuneTest-Smoke-\(UUID().uuidString)"
        let statusItem = makeTestStatusItem(title: title)
        defer { NSStatusBar.system.removeStatusItem(statusItem) }
        _ = statusItem.button?.window?.windowNumber

        let controller = MenuBarPopupController(accessibilityTitle: title)
        controller.toggle()  // must not crash
    }

    @Test("making and removing a test status item leaves the app's Item-0 defaults alone")
    func removalLeavesItemZeroDefaultsAlone() {
        // Read only: the installed app's Mixer item is autosaved as "Item-0" in this same
        // UserDefaults domain, so these keys are never written here.
        let keys = [
            "NSStatusItem Preferred Position Item-0",
            "NSStatusItem Visible Item-0",
            "NSStatusItem VisibleCC Item-0",
        ]
        func snapshot() -> [Int?] {
            keys.map { UserDefaults.standard.object(forKey: $0) as? Int }
        }
        let before = snapshot()

        let statusItem = makeTestStatusItem(title: "FineTuneTest-Defaults-\(UUID().uuidString)")
        _ = statusItem.button?.window?.windowNumber
        NSStatusBar.system.removeStatusItem(statusItem)

        #expect(snapshot() == before)
    }
}
