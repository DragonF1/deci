// Deci/Music/MusicPopupEscape.swift

/// What Escape does in the Music popup. It closes the topmost thing and stops there: the songs picked first, then the
/// account card, then what the navigation closes (the save to playlist menu, Lyrics, Up next, search at its root), and
/// only when there was none of that the popup itself. The order is the whole rule, so it is kept apart from the view
/// and tested.
@MainActor
enum MusicPopupEscape {
    enum Step: Equatable {
        case clearedSelection
        case closedAccountCard
        case closedNavigation
        /// Nothing was open: the popup closes.
        case leavesPopup
    }

    /// Asks each step in turn whether it had anything to close, and stops at the first that did. A step later than the
    /// one that closed something is not asked.
    static func run(
        clearSelection: () -> Bool, closeAccountCard: () -> Bool, closeNavigation: () -> Bool
    ) -> Step {
        if clearSelection() { return .clearedSelection }
        if closeAccountCard() { return .closedAccountCard }
        if closeNavigation() { return .closedNavigation }
        return .leavesPopup
    }
}
