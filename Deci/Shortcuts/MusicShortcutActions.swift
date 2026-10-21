// Deci/Shortcuts/MusicShortcutActions.swift
import Foundation

/// What the Save, Like and Dislike hotkeys ask of the music player. `ShortcutsRegistry` holds one, so tests can stand
/// in for it.
@MainActor
protocol MusicShortcutActing: AnyObject {
    /// Opens the save menu for the playing song and the Music popup that shows it. `.quiet` when it opened;
    /// `.musicHidden` when the Music item is not in the menu bar, and then nothing is opened.
    func saveToPlaylist() -> MusicActionOutcome
    /// Likes the playing song, or takes the like back.
    func toggleLike() async -> MusicActionOutcome
    /// Dislikes the playing song and skips it, or takes the dislike back.
    func dislike() async -> MusicActionOutcome
}

/// The hotkeys act on the song playing now, through the calls the Now playing hover card's buttons make. They never build
/// the player: before the Music popup was first opened nothing is playing, and they say so.
@MainActor
final class MusicShortcutActions: MusicShortcutActing {
    private let musicHost: MusicServiceHost
    private let popupOpener: any MusicPopupOpening

    init(musicHost: MusicServiceHost, popupOpener: any MusicPopupOpening) {
        self.musicHost = musicHost
        self.popupOpener = popupOpener
    }

    /// The card's Save button: the save menu opens for the playing song, then the Music popup opens to show it. With
    /// the Music item hidden there is no popup to show it in, so the menu is not opened either: it would sit unseen
    /// and greet the next open of the popup.
    func saveToPlaylist() -> MusicActionOutcome {
        guard let service = musicHost.service, let track = service.player.nowPlaying else { return .nothingPlaying }
        guard service.authState == .signedIn else { return .signedOut }
        guard popupOpener.canOpen else { return .musicHidden }
        musicHost.navigation?.perform(.saveToPlaylist, for: track, in: .none)
        popupOpener.open()
        return .quiet
    }

    func toggleLike() async -> MusicActionOutcome {
        guard let service = musicHost.service else { return .nothingPlaying }
        return await service.toggleLike()
    }

    func dislike() async -> MusicActionOutcome {
        guard let service = musicHost.service else { return .nothingPlaying }
        return await service.dislike()
    }
}

/// How the hotkey HUD words what an action came to.
nonisolated extension MusicActionOutcome {
    /// The line for the HUD; nil when there is nothing to report.
    var hudMessage: HUDMessage? {
        switch self {
        case .liked: HUDMessage(symbol: "hand.thumbsup.fill", text: "Liked")
        case .likeRemoved: HUDMessage(symbol: "hand.thumbsup", text: "Like removed")
        case .disliked: HUDMessage(symbol: "hand.thumbsdown.fill", text: "Disliked")
        case .dislikeRemoved: HUDMessage(symbol: "hand.thumbsdown", text: "Dislike removed")
        case .nothingPlaying: HUDMessage(symbol: "music.note", text: "Nothing is playing")
        case .signedOut: HUDMessage(symbol: "person.crop.circle.badge.exclamationmark", text: "Sign in to YouTube Music")
        case .failed: HUDMessage(symbol: "exclamationmark.triangle", text: "Couldn't reach YouTube Music")
        case .musicHidden: HUDMessage(symbol: "menubar.rectangle", text: "Show Music in the menu bar")
        case .quiet: nil
        }
    }
}

extension MessageHUDPresenting {
    /// The hover card's Like and Dislike buttons: a call that did not go through is worded as the hotkey words it. A
    /// call that went through stays silent, since the button already shows it.
    func showIfFailed(_ outcome: MusicActionOutcome) {
        guard outcome == .failed || outcome == .signedOut, let message = outcome.hudMessage else { return }
        showMessage(message)
    }
}
