// Deci/Music/Playback/MusicMixIntent.swift
// Why one song is mixed into the next the way it is: what the pair asks for, the way a DJ would put it. The picker favours the
// moves that make that point. Pure.

import Foundation

nonisolated enum MusicMixIntent: String, Sendable, CaseIterable {
    /// Nothing changes: keep the groove going.
    case ride
    /// The next song has a drop worth landing on.
    case drop
    /// The next song is clearly bigger.
    case lift
    /// The next song is clearly calmer.
    case breather
    /// The song is left at the end of a section in its middle.
    case section
    /// The next song is another kind of music.
    case genreChange
    /// The tempos are too far apart to run together.
    case tempoChange

    /// What a pair asks for: the hardest thing to get across first.
    static func pick(_ i: MusicTransitionStyleInputs) -> MusicMixIntent {
        if MusicTransitionStylePicker.isClash(i) { return .tempoChange }
        if i.habits.changesGenre { return .genreChange }
        let jump = i.energyJump.flatMap { $0.isFinite ? $0 : nil }
        if i.gridTrusted, let drop = i.dropConfidence, drop.isFinite, drop >= MusicDropDetector.confidenceFloor,
           (jump ?? 0) >= -MusicTransitionStylePicker.similarEnergy { return .drop }
        if let jump, jump >= MusicTransitionStylePicker.bigJump { return .lift }
        if let jump, jump <= -MusicTransitionStylePicker.bigJump { return .breather }
        return i.atDJExit ? .section : .ride
    }

    /// Added to a style's score. A change of genre has its say in `MusicMixHabits`.
    func bonus(for style: MusicTransitionStyle) -> Double {
        switch (self, style) {
        case (.drop, .dropSwap), (.lift, .dropSwap), (.lift, .filterSweep), (.lift, .quickCut): 0.1
        case (.drop, .filterSweep), (.section, .quickCut), (.section, .echoOut): 0.05
        case (.breather, .longBlend), (.breather, .loopExtend): 0.05
        case (.breather, .echoOut), (.tempoChange, .echoOut): 0.15
        default: 0
        }
    }
}
