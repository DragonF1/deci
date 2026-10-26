// Deci/Shortcuts/MusicOutcomeReporter.swift
import Foundation

/// Shows what a Like, Dislike or Save shortcut could not do, and what an account action could not do. `ShortcutsRegistry`
/// holds one, so tests can stand in for it.
@MainActor
protocol MusicOutcomeReporting: AnyObject {
    func report(_ outcome: MusicActionOutcome)
    /// Shows a failure that has its own words, in the place `report` shows an outcome.
    func reportFailure(_ text: String)
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
        if let service = serviceWithNoticeLine {
            service.trackActions.post(outcome)
        } else {
            hud.showMessage(message)
        }
    }

    /// A failure that has its own words, as an account action's. It shows as an error, on the same terms as an outcome.
    /// The Add account window and the channel picker are windows of their own, so the popup may be closed by the time
    /// the failure lands; then the HUD shows it, and a line too long for one row wraps there.
    func reportFailure(_ text: String) {
        if let service = serviceWithNoticeLine {
            service.trackActions.post(text, isError: true)
        } else {
            hud.showMessage(HUDMessage(symbol: "exclamationmark.triangle", text: text))
        }
    }

    /// The service whose popup is open and draws a notice line; nil when the HUD has to show it.
    private var serviceWithNoticeLine: MusicService? {
        guard popupOpener.isOpen, let service = musicHost.service, service.authState == .signedIn else { return nil }
        return service
    }
}
