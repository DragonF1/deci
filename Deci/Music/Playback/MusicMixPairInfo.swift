// Deci/Music/Playback/MusicMixPairInfo.swift
import Foundation

/// What Up next shows for a song in Mix: its tempo and key, and how the song before it hands over (on the beat or with a
/// fade). Built from the stored analysis rows of the two songs; a song with no row has neither number.
nonisolated struct MusicMixPairInfo: Equatable, Sendable {
    enum Mode: Equatable, Sendable {
        case beat
        case fade
    }

    /// Whole beats per minute of the incoming song, nil without a usable grid.
    var bpm: Int?
    /// Camelot code of the incoming song, nil when the key is unknown or not trusted.
    var camelot: String?
    var mode: Mode

    /// The tiny glyph between two Up next rows: a metronome for a beat mix, the merge arrows for a fade.
    var symbol: String { mode == .beat ? "metronome" : "arrow.triangle.merge" }

    /// The glyph's name for VoiceOver.
    var modeLabel: String { mode == .beat ? "Beat mix" : "Fade" }

    /// The key the cache keeps this info under.
    static func key(from outgoingId: String, to incomingId: String) -> String {
        "\(outgoingId)>\(incomingId)"
    }

    /// The small grey line on the song's row: "128 · 8A", or whichever of the two is known; nil when neither is.
    var rowText: String? {
        let parts = [bpm.map(String.init), camelot].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }

    /// The pair as the transition planner would plan it with Crossfade on: a beat mix when both songs carry a trusted
    /// grid, a fade in every other case.
    @MainActor
    static func make(
        outgoing: MusicTransitionSide, incoming: MusicTransitionSide, settingSeconds: Double = 6, beatMixEnabled: Bool = true
    ) -> MusicMixPairInfo {
        let inputs = MusicTransitionInputs(
            outgoing: outgoing, incoming: incoming, crossfadeOn: true, settingSeconds: settingSeconds,
            beatMixEnabled: beatMixEnabled, bassSwapAvailable: true
        )
        let plan = MusicTransitionPlanner.plan(inputs)
        let row = incoming.analysis
        let bpm = (incoming.grid ?? row?.usableGrid).map { Int($0.bpm.rounded()) }
        return MusicMixPairInfo(bpm: bpm, camelot: row?.trustedCamelot, mode: plan.mode == .beat ? .beat : .fade)
    }
}
