// Deci/Music/Playback/MusicMixHistory.swift
// The last few transitions of a set, newest first. It is what keeps one move from coming up over and over: a move that was just
// made is marked down, a long run of blends gets tiring, and an effect (a sweep or an echo out) comes about every fourth or fifth
// song. Pure: the same history always gives the same numbers.

import Foundation

nonisolated struct MusicMixHistory: Equatable, Sendable {
    /// How many transitions are kept.
    static let depth = 8
    /// Transitions that must pass after an effect before the next one: at most every fourth song has one.
    static let effectSpacing = 3
    /// What an effect gains as soon as it is allowed again and again with each transition after that, and the most it adds up to: one
    /// that a pair asks for comes early, any other a little later.
    static let dueBonus = 0.15
    static let mostDueBonus = 0.45
    /// What a move loses for being the last one, and for being the one before that.
    static let repeatPenalty = 0.25
    /// Blends in a row that cost nothing, what each one after that costs, and the most it adds up to.
    static let freeBlends = 2
    static let blendPenalty = 0.1
    static let mostBlendPenalty = 0.3

    /// Newest first.
    private(set) var styles: [MusicTransitionStyle]

    /// `styles` newest first.
    init(_ styles: [MusicTransitionStyle] = []) {
        self.styles = Array(styles.prefix(Self.depth))
    }

    /// The style of the last transition.
    var previous: MusicTransitionStyle? { styles.first }

    mutating func add(_ style: MusicTransitionStyle) {
        styles = Array(([style] + styles).prefix(Self.depth))
    }

    func adding(_ style: MusicTransitionStyle) -> MusicMixHistory {
        var out = self
        out.add(style)
        return out
    }

    /// Transitions since the last effect: 0 right after one, all of them when there was none.
    var sinceEffect: Int { styles.firstIndex(where: \.isEffect) ?? styles.count }

    /// Blends in a row, up to now.
    var blendRun: Int { styles.prefix(while: \.isPlainBlend).count }

    /// False right after an effect, when another one would be too much.
    func allows(_ style: MusicTransitionStyle) -> Bool {
        !style.isEffect || !styles.contains(where: \.isEffect) || sinceEffect >= Self.effectSpacing
    }

    /// What `style` gains or loses for what came before it.
    func bonus(for style: MusicTransitionStyle) -> Double {
        if style.isPlainBlend {
            return -min(Self.mostBlendPenalty, Self.blendPenalty * Double(max(0, blendRun - Self.freeBlends)))
        }
        var bonus = 0.0
        if style.isEffect {
            bonus += min(Self.mostDueBonus, Self.dueBonus * Double(max(0, sinceEffect - Self.effectSpacing + 1)))
            // The two effects take turns.
            if styles.first(where: \.isEffect) == style { bonus -= Self.repeatPenalty }
        }
        // A cut and an echo are the same kind of move, and the one that tires soonest.
        let same: (MusicTransitionStyle) -> Bool = { style.isCutLike ? $0.isCutLike : $0 == style }
        let weight = style.isCutLike ? 2 : 1.0
        if let last = styles.first, same(last) {
            bonus -= weight * Self.repeatPenalty
        } else if styles.count > 1, same(styles[1]) {
            bonus -= weight * Self.repeatPenalty / 2
        }
        return bonus
    }
}
