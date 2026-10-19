// DeciTests/MenuBarStatusItemsTests.swift
// The visibility keys written before the Music status item is renamed. AppKit reads them when the
// autosave name is set, so a stale hidden value from an old cmd-drag must be overwritten first, or the
// item hides itself and the setting is turned off with no user action.

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

        #expect(defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("NSStatusItem") }.isEmpty)
    }

    @Test("only the Music keys are written, the Mixer's Item-0 keys are left alone")
    func mixerKeysUntouched() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        MenuBarStatusItems.writeVisibilityDefaults(false, for: .music, in: defaults)

        #expect(defaults.object(forKey: "NSStatusItem Visible Item-0") == nil)
        #expect(defaults.object(forKey: "NSStatusItem VisibleCC Item-0") == nil)
    }
}
