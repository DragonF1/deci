// DeciTests/MixerAppListTests.swift
// The Mixer's apps list with Deci's own music player in it: the player shows as an app called "Deci" with Deci's icon,
// and lands where an unpinned app of that name would, under the list's name sort (pinned apps first, then the rest A to Z).

import AppKit
import AudioToolbox
import Testing
@testable import Deci

@MainActor
@Suite("MixerAppList")
struct MixerAppListTests {
    // MARK: - Fixtures

    private func active(_ name: String, id: pid_t = 1, bundleID: String? = nil) -> DisplayableApp {
        .active(AudioApp(
            id: id,
            processObjectIDs: [],
            name: name,
            icon: NSImage(),
            bundleID: bundleID ?? "com.test.\(name)-\(id)"
        ))
    }

    private func pinnedInactive(_ name: String) -> DisplayableApp {
        .pinnedInactive(PinnedAppInfo(persistenceIdentifier: "com.test.\(name)-inactive", displayName: name, bundleID: nil))
    }

    /// The list as the engine hands it over (pinned active, pinned inactive, then unpinned active, each A to Z), with
    /// the names in `pinned` counting as pinned.
    private func entries(
        _ apps: [DisplayableApp],
        pinned: Set<String> = [],
        musicPlayer: Bool = true
    ) -> [MixerListEntry] {
        MixerAppList.entries(
            apps: apps,
            isPinned: { pinned.contains($0.displayName) },
            includesMusicPlayer: musicPlayer
        )
    }

    private func names(_ entries: [MixerListEntry]) -> [String] {
        entries.map(\.displayName)
    }

    // MARK: - Name and icon

    @Test("the music player is called Deci, not YouTube Music")
    func playerName() {
        #expect(MusicPlayerIdentity.name == "Deci")
        #expect(MixerListEntry.musicPlayer.displayName == "Deci")
    }

    @Test("the music player wears the icon it is handed: Deci's own application icon")
    func playerIconIsTheApplicationIcon() {
        let appIcon = NSImage(size: NSSize(width: 64, height: 64))
        #expect(MusicPlayerIdentity.resolveIcon(applicationIcon: appIcon) === appIcon)
    }

    @Test("without an application icon the player still gets a real image")
    func playerIconFallback() {
        let fallback = MusicPlayerIdentity.resolveIcon(applicationIcon: nil)
        #expect(fallback.size.width > 0)
        #expect(fallback.size.height > 0)
    }

    @Test("the icon comes from the running app, and is resolved once rather than on every body pass")
    func playerIconIsCached() {
        let icon = MusicPlayerIdentity.icon
        #expect(icon.size.width > 0)
        #expect(icon.size.height > 0)
        #expect(MusicPlayerIdentity.icon === icon, "the same image every time, not a fresh one per row")
    }

    // MARK: - Where the row lands

    @Test("no apps playing: the apps list is just the Deci row")
    func aloneInTheList() {
        let result = entries([])
        #expect(names(result) == ["Deci"])
        #expect(result.first?.isMusicPlayer == true)
    }

    @Test("no track loaded: the list is untouched, and empty stays empty")
    func absentWhenNoTrack() {
        let apps = [active("Arc", id: 1), active("Zoom", id: 2)]
        #expect(names(entries(apps, musicPlayer: false)) == ["Arc", "Zoom"])
        #expect(entries([], musicPlayer: false).isEmpty)
    }

    @Test("it slots in alphabetically among the unpinned apps")
    func alphabeticalAmongUnpinned() {
        let apps = [active("Arc", id: 1), active("Slack", id: 2), active("Zoom", id: 3)]
        #expect(names(entries(apps)) == ["Arc", "Deci", "Slack", "Zoom"])
    }

    @Test("it goes first when every app sorts after Deci, and last when every app sorts before")
    func edges() {
        #expect(names(entries([active("Slack", id: 1), active("Zoom", id: 2)])) == ["Deci", "Slack", "Zoom"])
        #expect(names(entries([active("Arc", id: 1), active("Brave", id: 2)])) == ["Arc", "Brave", "Deci"])
    }

    @Test("the name compare ignores case, the way the engine's sort does")
    func caseInsensitive() {
        let apps = [active("Chrome", id: 1), active("discord", id: 2), active("Spotify", id: 3)]
        #expect(names(entries(apps)) == ["Chrome", "Deci", "discord", "Spotify"])
        // Lower-case names before Deci's D must not be pushed behind it by ASCII order.
        let lower = [active("arc", id: 1), active("zoom", id: 2)]
        #expect(names(entries(lower)) == ["arc", "Deci", "zoom"])
    }

    @Test("pinned apps stay on top, even one named after Deci")
    func pinnedStayOnTop() {
        // The engine's order: pinned active, pinned inactive, then the unpinned apps.
        let apps = [active("Zed", id: 1), pinnedInactive("Alpha"), active("Brave", id: 2), active("Slack", id: 3)]
        let result = entries(apps, pinned: ["Zed", "Alpha"])
        #expect(names(result) == ["Zed", "Alpha", "Brave", "Deci", "Slack"])
    }

    @Test("a pinned app named after Deci does not drag the row above the unpinned apps")
    func pinnedAfterDeciByNameStillOnTop() {
        let apps = [active("Zed", id: 1), active("Zoom", id: 2)]
        #expect(names(entries(apps, pinned: ["Zed"])) == ["Zed", "Deci", "Zoom"])
    }

    @Test("pinned inactive apps always count as pinned")
    func pinnedInactiveAlwaysPinned() {
        // The pin lookup knows nothing of them: the enum case already says so.
        let apps = [pinnedInactive("Zed"), active("Zoom", id: 1)]
        #expect(names(entries(apps)) == ["Zed", "Deci", "Zoom"])
    }

    @Test("with only pinned apps, the row comes last")
    func allPinned() {
        let apps = [active("Arc", id: 1), pinnedInactive("Zed")]
        #expect(names(entries(apps, pinned: ["Arc"])) == ["Arc", "Zed", "Deci"])
    }

    @Test("an app literally named Deci keeps its place and the player goes right after it")
    func tieGoesAfter() {
        let apps = [active("Deci", id: 1), active("Slack", id: 2)]
        #expect(names(entries(apps)) == ["Deci", "Deci", "Slack"])
        #expect(entries(apps).map(\.isMusicPlayer) == [false, true, false])
    }

    @Test("the apps keep their order and identity, and the player appears exactly once")
    func appsUntouched() {
        let apps = [active("Arc", id: 1), active("Slack", id: 2), active("Zoom", id: 3)]
        let result = entries(apps)
        let appIDs = result.compactMap { entry -> String? in
            if case .app(let app) = entry { return app.id }
            return nil
        }
        #expect(appIDs == apps.map(\.id))
        #expect(result.filter(\.isMusicPlayer).count == 1)
    }

    @Test("the row has an id of its own that no app can share, so SwiftUI keeps its state as apps come and go")
    func stableDistinctID() {
        let apps = [active("Arc", id: 1), active("Zoom", id: 2)]
        let ids = entries(apps).map(\.id)
        #expect(Set(ids).count == ids.count)
        // The same id wherever in the list the row lands.
        let first = entries([active("Zoom", id: 9)])
        let last = entries([active("Arc", id: 8)])
        #expect(first.first(where: \.isMusicPlayer)?.id == last.first(where: \.isMusicPlayer)?.id)
        #expect(first.first(where: \.isMusicPlayer)?.id == MixerListEntry.musicPlayer.id)
    }

    @Test("Unicode and emoji names place without trouble")
    func unicodeNames() {
        let apps = [active("Éclair", id: 1), active("日本語", id: 2), active("🎵 Player", id: 3), active("", id: 4)]
        let result = entries(apps.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending })
        #expect(result.count == 5)
        #expect(result.filter(\.isMusicPlayer).count == 1)
    }

    @Test("ten thousand apps place the row in order, fast")
    func largeList() {
        let apps = (0..<10_000).map { active(String(format: "App %05d", $0), id: pid_t($0 + 1)) }
        let start = ContinuousClock.now
        let result = entries(apps)
        let elapsed = ContinuousClock.now - start
        #expect(result.count == 10_001)
        // "App 00000" through "App 09999" all sort before "Deci".
        #expect(result.last?.isMusicPlayer == true)
        #expect(elapsed < .seconds(2))
    }

    // MARK: - The EQ accordion

    @Test("opening the Deci row's EQ opens it, and tapping it again closes it")
    func accordionOpensAndClosesDeci() {
        let id = MixerListEntry.musicPlayerID
        #expect(EQAccordion.toggled(nil, tapping: id) == id)
        #expect(EQAccordion.toggled(id, tapping: id) == nil)
    }

    @Test("opening an app's EQ closes Deci's, and the other way round: one panel at a time")
    func accordionSwaps() {
        let id = MixerListEntry.musicPlayerID
        #expect(EQAccordion.toggled(id, tapping: "com.test.Arc") == "com.test.Arc")
        #expect(EQAccordion.toggled("com.test.Arc", tapping: id) == id)
        #expect(EQAccordion.toggled("com.test.Arc", tapping: "com.test.Arc") == nil)
    }

    @Test("Deci's open EQ is forgotten when its row goes away, so it does not reopen with the next song")
    func accordionForgetsAGoneDeciRow() {
        let id = MixerListEntry.musicPlayerID
        #expect(EQAccordion.afterListChange(id, musicPlayerShown: false) == nil)
        #expect(EQAccordion.afterListChange(id, musicPlayerShown: true) == id)
    }

    @Test("a list change never touches an app's open EQ or an empty accordion")
    func accordionLeavesAppsAlone() {
        #expect(EQAccordion.afterListChange("com.test.Arc", musicPlayerShown: false) == "com.test.Arc")
        #expect(EQAccordion.afterListChange("com.test.Arc", musicPlayerShown: true) == "com.test.Arc")
        #expect(EQAccordion.afterListChange(nil, musicPlayerShown: false) == nil)
        #expect(EQAccordion.afterListChange(nil, musicPlayerShown: true) == nil)
    }

    @Test("the accordion handles odd ids: empty, Unicode, emoji")
    func accordionOddIDs() {
        for id in ["", "name:日本語", "name:🎵 Player"] {
            #expect(EQAccordion.toggled(nil, tapping: id) == id)
            #expect(EQAccordion.toggled(id, tapping: id) == nil)
            #expect(EQAccordion.toggled(id, tapping: MixerListEntry.musicPlayerID) == MixerListEntry.musicPlayerID)
        }
    }
}
