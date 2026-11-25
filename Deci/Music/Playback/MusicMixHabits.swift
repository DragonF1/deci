// Deci/Music/Playback/MusicMixHabits.swift
// How DJs mix two songs of these genres: how long the songs run together, which moves they like and which they leave alone. House
// and techno are layered for 16 bars; hip-hop and pop are cut or echoed out of at the end of a section. Pure.

import Foundation

nonisolated struct MusicMixHabits: Equatable, Sendable {
    /// Overlap lengths in bars: what the beat planner tries, in this order.
    var lengths: [Int] = [16, 8]
    /// Added to a style's score.
    var bonus: [MusicTransitionStyle: Double] = [:]
    /// A cut or an echo out is right at the end of a section in the middle of the song, where nothing has died down yet.
    var cutsOnSections = false
    /// The two songs are known to be different kinds of music.
    var changesGenre = false

    /// No habit at all: everything as it was before genres.
    static let neutral = MusicMixHabits()

    /// What the picker adds to a style's score. A loop extend is a long blend with a longer intro, so it goes where that goes.
    func bonus(for style: MusicTransitionStyle) -> Double {
        (bonus[style] ?? 0) + (style == .loopExtend ? bonus[.longBlend] ?? 0 : 0)
    }

    /// The habits for a pair of planner sides.
    static func pair(for inputs: MusicTransitionInputs) -> MusicMixHabits {
        pair(MusicGenre(of: inputs.outgoing), MusicGenre(of: inputs.incoming))
    }

    /// A guessed genre pulls half as hard as one the music services named.
    static let guessShare = 0.5

    /// How a pair is mixed: the shorter overlap of the two, the mean of what both like, cuts only where both are cut, and an echo or
    /// a cut rather than a long blend when the two are different kinds of music.
    static func pair(_ out: MusicGenre, _ into: MusicGenre) -> MusicMixHabits {
        var habits = MusicMixHabits()
        let sides = [out, into]
        // The song that wants the shorter overlap has its way.
        let a = lengths(out), b = lengths(into)
        habits.lengths = (b.first ?? 0, b.count) < (a.first ?? 0, a.count) ? b : a
        for side in sides {
            let share = (side.isGuess ? guessShare : 1) / 2
            for (style, value) in likes(side.family) { habits.bonus[style, default: 0] += value * share }
        }
        habits.cutsOnSections = sides.allSatisfy { !$0.isGuess && cutFriendly.contains($0.family) }
        if sides.allSatisfy({ !$0.isGuess && $0.family != .open }), out.family.group != into.family.group {
            habits.changesGenre = true
            let changes: [MusicTransitionStyle: Double] = [
                .echoOut: 0.15, .reverbOut: 0.15, .quickCut: 0.1, .brake: 0.1, .longBlend: -0.15, .doubleDrop: -0.15,
            ]
            for (style, value) in changes { habits.bonus[style, default: 0] += value }
        }
        return habits
    }

    /// Families whose DJs cut on the "1" of a section instead of layering two songs.
    static let cutFriendly: Set<MusicGenreFamily> = [.hipHop, .pop, .latin, .rock, .bass]

    /// Overlap lengths of one song's family. A guessed family never shortens below what an unknown song gets, but for hip-hop.
    static func lengths(_ genre: MusicGenre) -> [Int] {
        switch genre.family {
        case .house, .techno, .trance, .dnb, .afro, .open: [16, 8]
        case .bass, .garage, .pop, .latin: genre.isGuess ? [16, 8] : [8, 4]
        case .hipHop, .rock, .soft: genre.isGuess ? [8] : [4, 8]
        }
    }

    /// What a family's DJs like (above 0) and leave alone (below 0).
    static func likes(_ family: MusicGenreFamily) -> [MusicTransitionStyle: Double] {
        switch family {
        case .house: [
            .longBlend: 0.1, .filterSweep: 0.1, .quickCut: -0.2, .echoOut: -0.1,
            .lowpassSweep: 0.1, .loopRoll: 0.1, .echoThrow: 0.05, .reverbOut: -0.1, .brake: -0.3, .doubleDrop: -0.1,
        ]
        case .techno: [
            .longBlend: 0.15, .filterSweep: 0.1, .loopExtend: 0.1, .quickCut: -0.3, .echoOut: -0.3,
            .lowpassSweep: 0.1, .loopRoll: 0.15, .reverbOut: -0.2, .brake: -0.4, .doubleDrop: -0.1,
        ]
        case .trance: [
            .longBlend: 0.2, .dropSwap: 0.05, .quickCut: -0.4, .echoOut: -0.2, .echoThrow: 0.05, .reverbOut: -0.1, .brake: -0.4,
        ]
        case .dnb: [.dropSwap: 0.1, .doubleDrop: 0.3, .loopRoll: 0.1, .brake: -0.1]
        case .bass: [.dropSwap: 0.25, .longBlend: -0.15, .quickCut: 0.1, .doubleDrop: 0.25, .loopRoll: 0.1, .brake: 0.1]
        case .garage: [.dropSwap: 0.05, .echoThrow: 0.1, .loopRoll: 0.05, .brake: -0.1]
        case .hipHop: [
            .quickCut: 0.45, .echoOut: 0.3, .longBlend: -0.1, .filterSweep: -0.3,
            .brake: 0.4, .reverbOut: 0.1, .echoThrow: 0.1, .lowpassSweep: -0.3, .loopRoll: -0.1, .doubleDrop: -0.3,
        ]
        case .latin: [.quickCut: 0.2, .echoOut: 0.15, .filterSweep: -0.1, .echoThrow: 0.1, .brake: 0.1, .doubleDrop: -0.1]
        case .afro: [
            .echoOut: 0.2, .filterSweep: -0.15, .echoThrow: 0.15, .reverbOut: 0.15, .lowpassSweep: -0.1, .loopRoll: -0.1, .brake: -0.2,
            .doubleDrop: -0.2,
        ]
        case .pop: [
            .quickCut: 0.15, .echoOut: 0.2, .filterSweep: -0.05, .reverbOut: 0.15, .echoThrow: 0.1, .brake: 0.1, .lowpassSweep: -0.05,
            .doubleDrop: -0.1,
        ]
        case .rock: [
            .quickCut: 0.4, .echoOut: 0.1, .filterSweep: -0.3, .longBlend: -0.15,
            .brake: 0.2, .reverbOut: 0.15, .echoThrow: -0.1, .lowpassSweep: -0.3, .loopRoll: -0.3, .doubleDrop: -0.3,
        ]
        case .soft: [
            .longBlend: 0.1, .echoOut: 0.15, .quickCut: -0.4, .filterSweep: -0.4, .dropSwap: -0.3,
            .reverbOut: 0.2, .lowpassSweep: -0.1, .echoThrow: -0.1, .brake: -0.5, .loopRoll: -0.5, .doubleDrop: -0.5,
        ]
        case .open: [:]
        }
    }
}

extension MusicGenre {
    /// The genre of one side of a transition: its tags, its trusted tempo and its energy.
    nonisolated init(of side: MusicTransitionSide) {
        let grid = side.grid ?? side.analysis?.usableGrid
        self = MusicGenre.classify(
            tags: side.genres, bpm: grid.flatMap { MusicBeatPlanner.trusted($0) ? $0.bpm : nil },
            energy: (side.analysis?.keyInfoValue?.energy).map(Double.init)
        )
    }
}
