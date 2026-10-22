// DeciTests/MenuBarStatusItemsTests.swift
// The visibility keys written before the Music status item is renamed. AppKit reads them when the
// autosave name is set, so a stale hidden value from an old cmd-drag must be overwritten first, or the
// item hides itself and the setting is turned off with no user action.

import AppKit
import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("MenuBarStatusItems visibility defaults")
struct MenuBarStatusItemsTests {
    private let visibleKey = "NSStatusItem Visible DeciMusic"
    private let visibleCCKey = "NSStatusItem VisibleCC DeciMusic"

    private func makeDefaults() throws -> (defaults: UserDefaults, suite: String) {
        let suite = "deci-menubar-status-items-\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: suite)), suite)
    }

    /// The keys written to the test's own suite. A suite's lookups also fall through to the app's domain, where the
    /// installed Deci keeps its real status item keys, so reads that look for an absent key go to the suite alone.
    private func written(in defaults: UserDefaults, suite: String) -> [String: Any] {
        defaults.persistentDomain(forName: suite) ?? [:]
    }

    @Test("shown writes 1 to both keys and hidden writes 0", arguments: [true, false])
    func writesBothKeys(shown: Bool) throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        MenuBarStatusItems.writeVisibilityDefaults(shown, for: .music, in: defaults)

        #expect(defaults.object(forKey: visibleKey) as? Int == (shown ? 1 : 0))
        #expect(defaults.object(forKey: visibleCCKey) as? Int == (shown ? 1 : 0))
    }

    @Test("a stale hidden value from an old cmd-drag is overwritten when the setting is on")
    func staleHiddenValueOverwritten() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(0, forKey: visibleKey)
        defaults.set(0, forKey: visibleCCKey)

        MenuBarStatusItems.writeVisibilityDefaults(true, for: .music, in: defaults)

        #expect(defaults.integer(forKey: visibleKey) == 1)
        #expect(defaults.integer(forKey: visibleCCKey) == 1)
    }

    @Test("a stale shown value is overwritten when the setting is off")
    func staleShownValueOverwritten() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(1, forKey: visibleKey)
        defaults.set(1, forKey: visibleCCKey)

        MenuBarStatusItems.writeVisibilityDefaults(false, for: .music, in: defaults)

        #expect(defaults.integer(forKey: visibleKey) == 0)
        #expect(defaults.integer(forKey: visibleCCKey) == 0)
    }

    @Test("the Mixer has no autosave name of its own, so nothing is written for it")
    func mixerWritesNothing() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        MenuBarStatusItems.writeVisibilityDefaults(true, for: .mixer, in: defaults)

        #expect(written(in: defaults, suite: suite).keys.filter { $0.hasPrefix("NSStatusItem") }.isEmpty)
    }

    @Test("only the Music keys are written, the Mixer's Item-0 keys are left alone")
    func mixerKeysUntouched() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        MenuBarStatusItems.writeVisibilityDefaults(false, for: .music, in: defaults)

        let keys = written(in: defaults, suite: suite).keys
        #expect(!keys.contains("NSStatusItem Visible Item-0"))
        #expect(!keys.contains("NSStatusItem VisibleCC Item-0"))
    }
}

// The status item lookup and the rename's position carry-over. FluidMenuBarExtra's wrapper is the popup
// window's delegate and keeps the status item under an @objc `statusItem`; the window's own property is
// invisible to KVC, which is why the lookup goes through the delegate.

@MainActor
@Suite("MenuBarStatusItems lookup")
struct MenuBarStatusItemsLookupTests {
    /// Stands in for FluidMenuBarExtra's wrapper: the window's delegate with an @objc `statusItem`.
    private final class FakeWrapper: NSObject, NSWindowDelegate {
        @objc let statusItem: NSObject
        init(statusItem: NSObject) { self.statusItem = statusItem }
    }

    private final class PlainDelegate: NSObject, NSWindowDelegate {}

    /// Never ordered in, so nothing is drawn.
    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    @Test("reads the status item through the window's delegate")
    func readsThroughDelegate() {
        let sentinel = NSObject()
        let wrapper = FakeWrapper(statusItem: sentinel)
        let window = makeWindow()
        window.delegate = wrapper

        #expect((MenuBarStatusItems.statusItemValue(of: window) as? NSObject) === sentinel)
    }

    @Test("a delegate without the key gives nil instead of raising")
    func otherDelegateGivesNil() {
        let delegate = PlainDelegate()
        let window = makeWindow()
        window.delegate = delegate

        #expect(MenuBarStatusItems.statusItemValue(of: window) == nil)
    }

    @Test("no delegate gives nil")
    func noDelegateGivesNil() {
        #expect(MenuBarStatusItems.statusItemValue(of: makeWindow()) == nil)
    }
}

@MainActor
@Suite("MenuBarStatusItems position carry-over")
struct MenuBarStatusItemsPositionTests {
    private let oldKey = "NSStatusItem Preferred Position Item-1"
    private let newKey = "NSStatusItem Preferred Position DeciMusic"

    private func makeDefaults() throws -> (defaults: UserDefaults, suite: String) {
        let suite = "deci-menubar-position-\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: suite)), suite)
    }

    @Test("the old name's position is copied to the new name")
    func copiesPosition() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(771, forKey: oldKey)

        MenuBarStatusItems.carryPosition(from: "Item-1", to: "DeciMusic", in: defaults)

        #expect(defaults.object(forKey: newKey) as? Int == 771)
    }

    @Test("a position already saved under the new name wins")
    func keepsExistingPosition() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(771, forKey: oldKey)
        defaults.set(500, forKey: newKey)

        MenuBarStatusItems.carryPosition(from: "Item-1", to: "DeciMusic", in: defaults)

        #expect(defaults.object(forKey: newKey) as? Int == 500)
    }

    @Test("nothing saved under the old name writes nothing")
    func nothingToCarry() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        MenuBarStatusItems.carryPosition(from: "Item-1", to: "DeciMusic", in: defaults)

        #expect(defaults.object(forKey: newKey) == nil)
    }
}
