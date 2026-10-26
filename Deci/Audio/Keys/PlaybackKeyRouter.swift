// Deci/Audio/Keys/PlaybackKeyRouter.swift
import Foundation

/// What Deci's own player is doing, as far as a transport key cares.
nonisolated enum DeciPlaybackState: Equatable, Sendable {
    /// A song is playing, loading, or about to play through a stall.
    case playing
    /// A song is loaded and not playing.
    case pausedWithSong
    /// No song is loaded, or the music service was never built.
    case idle
}

nonisolated enum DeciPlaybackAction: Equatable, Sendable {
    case pause
    case resume
    case next
    case previous
}

/// Where a transport key press goes.
nonisolated enum PlaybackKeyRoute: Equatable, Sendable {
    /// Chrome tab `id` gets the key.
    case chromeTab(id: Int, key: PlaybackKey)
    case deci(DeciPlaybackAction)
    /// Nothing can take the key. It is swallowed all the same.
    case nothing
}

/// Decides where the play/pause, next and previous keys go.
///
/// With Chrome in front and a tab playing, the key acts on that tab. Otherwise it acts on Deci's player: while a song
/// plays, play/pause pauses and next and previous skip; while a song is loaded and paused, play/pause resumes it and
/// next and previous do nothing; with nothing loaded the key does nothing. Any other app in front counts as nothing
/// playing, so a key never reaches Safari or Spotify.
///
/// Chrome keeps a tab's `audible` flag on for about two seconds after its sound stops, so a tab that a key just paused
/// can still read as playing, and a tab that a key paused is quiet, so it would never be found as playing to resume.
/// The router therefore remembers the tab a play/pause paused. For play/pause with Chrome in front the target is, in
/// order:
/// 1. an audible tab that is not the remembered one (the active tab if it is among them, else the first in list order);
/// 2. the remembered tab, if it is still listed and Deci is not playing (the memory is cleared, as the press resumes
///    it). While Deci plays, the front app is not the one playing, so the key is Deci's and the memory is kept;
/// 3. otherwise Deci's rules.
/// Next and previous use only the first step.
///
/// The memory is a single slot. It is cleared when a play/pause goes to that tab again, when the tab leaves the list
/// (checked at each press, and tab ids are not reused within a Chrome session), and when Chrome is not in front.
nonisolated struct PlaybackKeyRouter {
    static let chromeBundleID = ChromeExtensionInstaller.chromeBundleID

    /// The tab the last play/pause paused, until the press that resumes it.
    private(set) var keyPausedTabID: Int?

    /// Routes a fresh press. `tabs` is the Chrome tab list in the order the extension sent it.
    mutating func route(
        _ key: PlaybackKey,
        frontmostBundleID: String?,
        tabs: [ChromeTab],
        deci: DeciPlaybackState
    ) -> PlaybackKeyRoute {
        frontmostApplicationChanged(to: frontmostBundleID)
        if let remembered = keyPausedTabID, !tabs.contains(where: { $0.id == remembered }) {
            keyPausedTabID = nil
        }

        if frontmostBundleID == Self.chromeBundleID {
            if let target = audibleTarget(in: tabs) {
                if key == .playPause { keyPausedTabID = target.id }
                return .chromeTab(id: target.id, key: key)
            }
            if key == .playPause, deci != .playing, let remembered = keyPausedTabID {
                keyPausedTabID = nil
                return .chromeTab(id: remembered, key: .playPause)
            }
        }
        return Self.deciRoute(for: key, state: deci)
    }

    /// Another app came to the front (nil when it is not known): once Chrome is not in front, the tab a key paused is
    /// no longer the one the listener is looking at.
    mutating func frontmostApplicationChanged(to bundleID: String?) {
        if bundleID != Self.chromeBundleID { keyPausedTabID = nil }
    }

    private func audibleTarget(in tabs: [ChromeTab]) -> ChromeTab? {
        let audible = tabs.filter { $0.isAudible && $0.id != keyPausedTabID }
        return audible.first(where: \.isActive) ?? audible.first
    }

    private static func deciRoute(for key: PlaybackKey, state: DeciPlaybackState) -> PlaybackKeyRoute {
        switch (state, key) {
        case (.playing, .playPause): .deci(.pause)
        case (.playing, .next): .deci(.next)
        case (.playing, .previous): .deci(.previous)
        case (.pausedWithSong, .playPause): .deci(.resume)
        case (.pausedWithSong, .next), (.pausedWithSong, .previous): .nothing
        case (.idle, _): .nothing
        }
    }
}
