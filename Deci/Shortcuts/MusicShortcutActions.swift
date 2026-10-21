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

/// How an action's outcome is worded, for the HUD and for the Music popup's notice line alike. Only an action that did
/// not happen has words: a rating that was made shows as the like animation and in the icons, not as a notice.
nonisolated extension MusicActionOutcome {
    /// The words for what the action came to; nil when there is nothing to report, which includes every rating that was
    /// made.
    var noticeText: String? {
        switch self {
        case .nothingPlaying: "Nothing is playing"
        case .signedOut: "Sign in to YouTube Music"
        case .failed: "Couldn't reach YouTube Music"
        case .musicHidden: "Show Music in the menu bar"
        case .liked, .likeRemoved, .disliked, .dislikeRemoved, .quiet: nil
        }
    }

    /// The action did not happen: a refusal, or a call that did not go through. A rating that was made, a quiet outcome,
    /// is not one.
    var isFailure: Bool {
        switch self {
        case .liked, .likeRemoved, .disliked, .dislikeRemoved, .quiet: false
        case .nothingPlaying, .signedOut, .failed, .musicHidden: true
        }
    }

    /// A rating call that did not go through: YouTube Music could not be reached, or the session is gone. The Like and
    /// Dislike buttons show only these, since a call that went through is already shown by the button.
    var isRatingFailure: Bool { self == .failed || self == .signedOut }

    /// The line for the HUD; nil when there is nothing to report, as for a rating that was made.
    var hudMessage: HUDMessage? {
        guard let text = noticeText, let symbol = hudSymbol else { return nil }
        return HUDMessage(symbol: symbol, text: text)
    }

    private var hudSymbol: String? {
        switch self {
        case .nothingPlaying: "music.note"
        case .signedOut: "person.crop.circle.badge.exclamationmark"
        case .failed: "exclamationmark.triangle"
        case .musicHidden: "menubar.rectangle"
        case .liked, .likeRemoved, .disliked, .dislikeRemoved, .quiet: nil
        }
    }
}

extension MessageHUDPresenting {
    /// The hover card's Like and Dislike buttons: a call that did not go through is worded as the hotkey words it. A
    /// call that went through stays silent, since the button already shows it.
    func showIfFailed(_ outcome: MusicActionOutcome) {
        guard outcome.isRatingFailure, let message = outcome.hudMessage else { return }
        showMessage(message)
    }
}
