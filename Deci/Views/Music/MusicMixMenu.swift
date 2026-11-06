import Foundation

/// The two "do not mix" entries a song menu can carry, beside the song actions. They are not `MusicTrackAction`s: that
/// list is exact and fixed, and these two read and write the mix flag store instead of the song's page.
enum MusicMixMenuItem: Hashable, Sendable {
    /// "Always start clean" for the song. `on` is whether it is flagged now.
    case startClean(on: Bool)
    /// The pair previous song into this one. `on` is whether it is flagged now.
    case cleanAfterPrevious(on: Bool)

    var title: String {
        switch self {
        case .startClean(let on): on ? "Allow mixing into this song" : "Always start clean"
        case .cleanAfterPrevious(let on): on ? "Allow mixing after the previous song" : "Start clean after the previous song"
        }
    }

    /// The entries a menu offers: the song's own, and, for the song playing now with a song before it, the pair.
    /// `pairIsClean` is nil when there is no previous song (or the menu is not the now playing one).
    static func items(startsClean: Bool, pairIsClean: Bool?) -> [MusicMixMenuItem] {
        var items: [MusicMixMenuItem] = [.startClean(on: startsClean)]
        if let pairIsClean { items.append(.cleanAfterPrevious(on: pairIsClean)) }
        return items
    }
}
