// Deci/Views/Music/MusicPlayerColumnLogic.swift
import SwiftUI

// The rules of the player column kept apart from the views, so they are tested without drawing anything: which of its
// five states it is in and what each one dims or shows, and the accent it takes from the cover.

/// What the player column shows. Signed out and empty share a layout and differ in their words.
nonisolated enum MusicPlayerColumnState: Equatable {
    case signedOut
    case empty
    case loading
    case paused
    case playing

    /// A song that is loading wins over playing or paused, so the controls do not flash between them.
    static func resolve(isSignedIn: Bool, hasTrack: Bool, isLoading: Bool, isPlaying: Bool) -> MusicPlayerColumnState {
        guard isSignedIn else { return .signedOut }
        guard hasTrack else { return .empty }
        if isLoading { return .loading }
        return isPlaying ? .playing : .paused
    }

    /// The small caps line above the cover.
    var kicker: String {
        switch self {
        case .signedOut, .empty: "NOTHING PLAYING"
        case .loading: "LOADING"
        case .paused: "PAUSED"
        case .playing: "NOW PLAYING"
        }
    }

    /// White opacity of the kicker: paused reads a little brighter than the rest.
    var kickerOpacity: Double { self == .paused ? 0.60 : 0.45 }

    /// The empty layout: a placeholder cover, flat bars and a hint in place of the song.
    var isEmptyLayout: Bool { self == .signedOut || self == .empty }

    var emptyTitle: String { self == .signedOut ? "Not signed in" : "Pick something to play" }

    var emptySubtitle: String {
        self == .signedOut ? "Your music shows up here after you sign in" : "Choose a song in Home or Library"
    }

    /// The transport and the view buttons dim and stop answering when there is nothing to control. The volume and the
    /// output stay live, because the Mixer still works.
    var controlsOpacity: Double { isEmptyLayout ? 0.30 : 1 }
    var controlsAreEnabled: Bool { !isEmptyLayout }

    /// The incoming song's cover is dimmed while it loads.
    var coverOpacity: Double { self == .loading ? 0.45 : 1 }

    /// A paused song's bars dim; the playhead does not.
    var barsOpacity: Double { self == .paused ? 0.55 : 1 }

    /// Whether the bars say anything about the song: played in the accent, the rest white. Loading and empty show them
    /// flat and unplayed.
    var showsProgress: Bool { self == .playing || self == .paused }

    var showsPlayhead: Bool { showsProgress }

    /// How strongly the accent washes the top of the column.
    var washOpacity: Double { isEmptyLayout ? 0.05 : 0.16 }

    /// A bar of the empty state: all the same, 18 wide, very faint.
    static let emptyBarWidth: Double = 18
}

/// The colour the player column takes from the cover, lifted so it reads on the column's near black.
nonisolated enum MusicAccent {
    /// The lowest brightness an accent has: a darker cover colour is raised to this.
    static let minBrightness = 0.84

    /// A tint with a real hue but little colour is raised to this, so the accent is not a dull grey of its hue.
    static let minSaturation = 0.35

    /// Below this a tint is a grey (or near it), whose hue means nothing, so it stays neutral and only brightens.
    static let neutralSaturation = 0.12

    /// The design's own orange, for when there is neither a cover colour nor a song.
    static let fallback = MusicTint(hue: 0.068, saturation: 0.67, brightness: 0.88)

    /// The cover's tint with its brightness lifted to at least `minBrightness`, and a thin colour thickened. The hue is
    /// kept, and a grey stays a grey.
    static func lifted(_ tint: MusicTint) -> MusicTint {
        let isNeutral = tint.saturation < neutralSaturation
        return MusicTint(
            hue: tint.hue,
            saturation: isNeutral ? tint.saturation : max(tint.saturation, minSaturation),
            brightness: max(tint.brightness, minBrightness)
        )
    }

    /// The accent for a song: its cover's colour when known, else the hash palette's tint of its id, lifted.
    static func accent(cover: MusicTint?, videoId: String?) -> MusicTint {
        if let cover { return lifted(cover) }
        if let videoId { return lifted(MusicTint.forKey(videoId)) }
        return fallback
    }
}

extension MusicTint {
    /// The tint as one flat colour, as it is: the player column's accent.
    var solid: Color { Color(hue: hue, saturation: saturation, brightness: brightness) }
}
