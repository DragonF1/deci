// Deci/Views/MenuBar/MusicPopupOpener.swift
import AppKit

/// Opens the Music popup the way a click on its menu bar item does. The hover card's buttons and the Save hotkey both
/// open it through one of these.
@MainActor
protocol MusicPopupOpening: AnyObject {
    /// The Music item is in the menu bar. Hidden, a click on it has nothing to open, and the popup would show no player.
    var canOpen: Bool { get }
    /// The Music popup is on screen: open, or still fading out.
    var isOnScreen: Bool { get }
    /// The Music popup is open: on screen and key, which a popup fading out no longer is.
    var isOpen: Bool { get }
    /// Opens the popup, unless it is open: the toggle behind it would close it. A popup that is fading out is opened
    /// again once it has closed.
    func open()
}

@MainActor
final class MusicPopupOpener: MusicPopupOpening {
    /// Where the popup is. It is key while it is open. A popup that lost focus fades out for a moment, still on screen
    /// but no longer key: that is `closing`, and a click on the item then would not open it.
    enum State: Equatable {
        case closed
        case open
        case closing
    }

    private let state: @MainActor () -> State
    private let isItemShown: @MainActor () -> Bool
    private let toggle: @MainActor () -> Void
    /// How long a fade is waited out, and how often it is looked at.
    private let closeWait: Duration
    private let pollInterval: Duration
    private var reopenTask: Task<Void, Never>?

    init(
        state: @escaping @MainActor () -> State,
        isItemShown: @escaping @MainActor () -> Bool,
        toggle: @escaping @MainActor () -> Void,
        closeWait: Duration = .seconds(1),
        pollInterval: Duration = .milliseconds(25)
    ) {
        self.state = state
        self.isItemShown = isItemShown
        self.toggle = toggle
        self.closeWait = closeWait
        self.pollInterval = pollInterval
    }

    /// The real popup: found by the Music item's title, and opened with the app left as it is, like a click.
    convenience init() {
        let controller = MenuBarPopupController(accessibilityTitle: MenuBarItemID.music.title)
        self.init(
            state: {
                guard MenuBarStatusItems.popupWindow(for: .music)?.isVisible == true else { return .closed }
                return MusicPopupKeyWatcher.isPopupOpen ? .open : .closing
            },
            isItemShown: { MenuBarStatusItems.statusItem(for: .music)?.isVisible == true },
            toggle: { controller.toggle(activatingApp: false) }
        )
    }

    var canOpen: Bool { isItemShown() }

    var isOnScreen: Bool { state() != .closed }

    var isOpen: Bool { state() == .open }

    func open() {
        switch state() {
        case .open: break
        case .closed: toggle()
        case .closing: reopenWhenClosed()
        }
    }

    /// A click on the item during the fade would only start another one, and the popup would vanish under whatever was
    /// just put in it. So the fade is waited out, and the popup is opened then, if nobody has opened it meanwhile.
    private func reopenWhenClosed() {
        reopenTask?.cancel()
        reopenTask = Task { [weak self] in
            guard let self else { return }
            var waited = Duration.zero
            while state() != .closed, waited < closeWait {
                do { try await Task.sleep(for: pollInterval) } catch { return }
                waited += pollInterval
            }
            guard !Task.isCancelled, state() == .closed else { return }
            toggle()
        }
    }
}
