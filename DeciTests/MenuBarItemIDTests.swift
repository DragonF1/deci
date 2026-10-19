// DeciTests/MenuBarItemIDTests.swift
// Deci has two menu bar items. Every window lookup tells them apart by the window title, so the
// matching rule is pinned here: the title decides, and only a FluidMenuBarExtra popup counts.

import Testing
@testable import Deci

/// The class names a popup window can report: the plain name, the module-qualified name and the
/// mangled name the Objective-C runtime gives a generic Swift class.
private nonisolated let popupClassNames = [
    "FluidMenuBarExtraWindow<MenuBarPopupView>",
    "FluidMenuBarExtra.FluidMenuBarExtraWindow<Deci.MenuBarPopupView>",
    "_TtGC17FluidMenuBarExtra24FluidMenuBarExtraWindowV4Deci16MenuBarPopupView_",
]

@Suite("MenuBarItemID")
struct MenuBarItemIDTests {
    @Test("the Mixer popup is the window titled Deci")
    func mixerTitle() {
        #expect(MenuBarItemID.mixer.title == "Deci")
    }

    @Test("the Music popup is the window titled Deci Music")
    func musicTitle() {
        #expect(MenuBarItemID.music.title == "Deci Music")
    }

    @Test("every item has its own title")
    func titlesAreUnique() {
        let titles = MenuBarItemID.allCases.map(\.title)
        #expect(Set(titles).count == titles.count)
    }

    @Test("a popup window titled Deci is the Mixer", arguments: popupClassNames)
    func mixerWindowMatches(className: String) {
        #expect(MenuBarItemID.match(windowTitle: "Deci", className: className) == .mixer)
    }

    @Test("a popup window titled Deci Music is the Music item", arguments: popupClassNames)
    func musicWindowMatches(className: String) {
        #expect(MenuBarItemID.match(windowTitle: "Deci Music", className: className) == .music)
    }

    @Test("a window that is not a menu bar popup matches nothing, whatever its title",
          arguments: ["NSWindow", "SwiftUI.AppKitWindow", "NSAlertPanel", "NSStatusBarWindow", "NSPanel", ""])
    func otherWindowsDoNotMatch(className: String) {
        for id in MenuBarItemID.allCases {
            #expect(MenuBarItemID.match(windowTitle: id.title, className: className) == nil)
        }
    }

    @Test("a popup window with some other title matches nothing",
          arguments: ["", "Settings", "deci", "DECI MUSIC", "Deci ", " Deci Music", "Deci Music 2", "Music"])
    func otherTitlesDoNotMatch(title: String) {
        for className in popupClassNames {
            #expect(MenuBarItemID.match(windowTitle: title, className: className) == nil)
        }
    }

    @Test("the Mixer title never matches the Music window, and the other way round")
    func titlesDoNotOverlap() {
        let className = popupClassNames[0]
        #expect(MenuBarItemID.match(windowTitle: "Deci", className: className) != .music)
        #expect(MenuBarItemID.match(windowTitle: "Deci Music", className: className) != .mixer)
    }

    @Test("every item matches its own title when that title is read back")
    func titleRoundTrip() {
        for id in MenuBarItemID.allCases {
            #expect(MenuBarItemID.match(windowTitle: id.title, className: popupClassNames[0]) == id)
        }
    }

    @Test("isPopupWindow accepts the popup class names and nothing else", arguments: popupClassNames)
    func popupClassRecognised(className: String) {
        #expect(MenuBarItemID.isPopupWindow(className: className))
    }

    @Test("isPopupWindow rejects other windows", arguments: ["NSWindow", "NSPanel", "NSAlertPanel", ""])
    func nonPopupClassRejected(className: String) {
        #expect(!MenuBarItemID.isPopupWindow(className: className))
    }

    @Test("the Mixer keeps the name AppKit gave its status item, so the icon stays where it was put")
    func mixerKeepsDefaultAutosaveName() {
        #expect(MenuBarItemID.mixer.autosaveName == nil)
    }

    @Test("the Music item has a fixed autosave name that cannot clash with a default Item-N name")
    func musicAutosaveName() throws {
        let name = try #require(MenuBarItemID.music.autosaveName)
        #expect(name == "DeciMusic")
        #expect(!name.hasPrefix("Item-"))
    }

    @Test("the visibility keys AppKit reads for a status item come from its autosave name")
    func visibilityKeysFromName() {
        #expect(MenuBarItemID.visibilityDefaultsKeys(autosaveName: "DeciMusic") == [
            "NSStatusItem Visible DeciMusic",
            "NSStatusItem VisibleCC DeciMusic"
        ])
    }

    @Test("the Music item has visibility keys of its own, the Mixer has none to manage")
    func visibilityKeysPerItem() {
        #expect(MenuBarItemID.music.visibilityDefaultsKeys == [
            "NSStatusItem Visible DeciMusic",
            "NSStatusItem VisibleCC DeciMusic"
        ])
        #expect(MenuBarItemID.mixer.visibilityDefaultsKeys.isEmpty)
    }
}
