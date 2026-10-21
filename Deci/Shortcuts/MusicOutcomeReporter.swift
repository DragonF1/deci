// Deci/Shortcuts/MusicOutcomeReporter.swift
import Foundation

/// Shows what a Like, Dislike or Save shortcut could not do. `ShortcutsRegistry` holds one, so tests can stand in for
/// it.
@MainActor
protocol MusicOutcomeReporting: AnyObject {
    func report(_ outcome: MusicActionOutcome)
}

/// Puts a shortcut's outcome where the user is looking. With the Music popup open it is the popup's notice line: the
/// HUD sits behind the popup's panel, or is skipped, and the popup has the line for exactly this. Otherwise it is the
/// HUD, also while another Deci popup (the mixer) is open: that one has no line, and the HUD sits above it.
///
/// A popup that is fading out is not open, and a popup with no notice line (signed out, or before the player exists)
/// cannot show one, so both fall back to the HUD.
@MainActor
final class MusicOutcomeReporter: MusicOutcomeReporting {
    private let musicHost: MusicServiceHost
    private let popupOpener: any MusicPopupOpening
    private let hud: any MessageHUDPresenting

    init(musicHost: MusicServiceHost, popupOpener: any MusicPopupOpening, hud: any MessageHUDPresenting) {
        self.musicHost = musicHost
        self.popupOpener = popupOpener
        self.hud = hud
    }

    /// A quiet outcome shows nowhere, and neither does a rating that was made: that one is shown by the like animation. A
    /// refusal or a failure shows where the user is looking.
    func report(_ outcome: MusicActionOutcome) {
        guard let message = outcome.hudMessage else { return }
        if popupOpener.isOpen, let service = musicHost.service, service.authState == .signedIn {
            service.trackActions.post(outcome)
        } else {
            hud.showMessage(message)
        }
    }
}
