// Deci/Models/MixerAppList.swift
import AppKit

/// How Deci's own music player presents itself in the Mixer tab: an app called "Deci", wearing Deci's own icon.
/// Display only. The player's settings still live under `MusicMixerState.settingsKey`.
enum MusicPlayerIdentity {
    static let name = "Deci"

    /// Deci's application icon, the one About and the Dock show. Resolved once, on first use, so a row rebuilt on every
    /// parent body pass does not ask AppKit for it again.
    @MainActor
    static let icon: NSImage = resolveIcon(applicationIcon: NSApp?.applicationIconImage)

    /// The seam behind `icon`: the running app's icon when there is one, otherwise whatever Finder shows for this bundle.
    @MainActor
    static func resolveIcon(applicationIcon: NSImage?) -> NSImage {
        applicationIcon ?? NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
    }
}

/// One slot in the Mixer's apps list: a regular app, or Deci's own music player (which has no `DisplayableApp`
/// behind it, since the process taps never see audio that plays inside Deci).
enum MixerListEntry: Identifiable {
    case app(DisplayableApp)
    case musicPlayer

    /// No app's persistence identifier (a bundle ID or `name:<app>`) looks like this, so the row never collides.
    static let musicPlayerID = "deci.mixer.music-player"

    var id: String {
        switch self {
        case .app(let app): app.id
        case .musicPlayer: Self.musicPlayerID
        }
    }

    var displayName: String {
        switch self {
        case .app(let app): app.displayName
        case .musicPlayer: MusicPlayerIdentity.name
        }
    }

    var isMusicPlayer: Bool {
        if case .musicPlayer = self { return true }
        return false
    }
}

enum MixerAppList {
    /// The apps list with the music player slotted in. The engine's order is pinned apps first, then every other app
    /// A to Z by name. The player can't be pinned, so it takes the place an unpinned app called "Deci" would: after
    /// all pinned apps, then by name among the rest. An app that really is named "Deci" keeps its spot ahead of it.
    static func entries(
        apps: [DisplayableApp],
        isPinned: (DisplayableApp) -> Bool,
        includesMusicPlayer: Bool
    ) -> [MixerListEntry] {
        var entries = apps.map(MixerListEntry.app)
        if includesMusicPlayer {
            entries.insert(.musicPlayer, at: musicPlayerIndex(in: apps, isPinned: isPinned))
        }
        return entries
    }

    /// Where the player goes: just before the first unpinned app whose name sorts after "Deci", or at the end.
    /// Uses the same case-insensitive localized compare as the engine's own sort.
    static func musicPlayerIndex(in apps: [DisplayableApp], isPinned: (DisplayableApp) -> Bool) -> Int {
        apps.firstIndex { app in
            let pinned = app.isPinnedInactive || isPinned(app)
            return !pinned
                && app.displayName.localizedCaseInsensitiveCompare(MusicPlayerIdentity.name) == .orderedDescending
        } ?? apps.count
    }
}

/// The popup's EQ accordion: at most one row's EQ panel is open, named by row id. Apps and Deci's own music player row
/// share it, so opening one closes the other, and Escape (which clears the id) closes whichever is open.
enum EQAccordion {
    /// The open row after `id`'s EQ button is tapped: closed if it was the open one, otherwise the open one swaps to it.
    static func toggled(_ open: String?, tapping id: String) -> String? {
        open == id ? nil : id
    }

    /// The open row after the list changed. The music player row comes and goes with the loaded song; when it goes, its
    /// open panel must not wait around to reopen with the next song.
    static func afterListChange(_ open: String?, musicPlayerShown: Bool) -> String? {
        open == MixerListEntry.musicPlayerID && !musicPlayerShown ? nil : open
    }
}
