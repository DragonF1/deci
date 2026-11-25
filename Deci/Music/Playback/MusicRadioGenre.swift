// Deci/Music/Playback/MusicRadioGenre.swift
// Keeps the autoplay radio in the genre it was started from. Pure: what stays and in which order; the service decides when.

import Foundation

nonisolated enum MusicRadioGenre {
    /// Songs of another genre are only left out while more than this many songs stay ahead: above the number at which the queue
    /// asks for the radio's next page, so leaving songs out never asks for one by itself, and the music never runs out.
    static let reserve = MusicQueue.refillThreshold + 2
    /// The same for songs of a genre next to it (hip hop and R&B, house and techno), which are missed less.
    static let nearReserve = 8
    /// How many of the radio's first songs have their genre looked up.
    static let lookedUp = 24

    /// 0 the genre itself, 1 not known, 2 a genre next to it, 3 another one.
    static func distance(_ family: MusicGenreFamily?, from anchor: MusicGenreFamily) -> Int {
        guard let family, family != .open else { return 1 }
        if family == anchor { return 0 }
        return family.group == anchor.group ? 2 : 3
    }

    /// The songs that stay, the nearest genre first and otherwise in the order they came in. Of the rest, the farthest go
    /// first, the last of them before the others.
    static func kept(_ ids: [String], families: [String: MusicGenreFamily], anchor: MusicGenreFamily) -> [String] {
        guard anchor != .open else { return ids }
        let tiers = (0...3).map { tier in ids.filter { distance(families[$0], from: anchor) == tier } }
        let fits = tiers[0] + tiers[1]
        let near = tiers[2].prefix(max(0, nearReserve - fits.count))
        let far = tiers[3].prefix(max(0, reserve - fits.count - near.count))
        return fits + near + far
    }
}
