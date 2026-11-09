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
    /// Tier 4b: how the handover sounds. A cut and an echo are beat-mode plans, so the style tells them from a blend.
    var style: MusicTransitionStyle = .longBlend

    /// The tiny glyph between two Up next rows: scissors for a quick cut, a wave for an echo out, a metronome for a beat
    /// mix, the merge arrows for a fade.
    var symbol: String {
        switch style {
        case .quickCut: return "scissors"
        case .echoOut: return "waveform.path"
        default: return mode == .beat ? "metronome" : "arrow.triangle.merge"
        }
    }

    /// The glyph's name for VoiceOver.
    var modeLabel: String {
        switch style {
        case .quickCut, .echoOut: return style.label
        default: return mode == .beat ? "Beat mix" : "Fade"
        }
    }

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
        outgoing: MusicTransitionSide, incoming: MusicTransitionSide, settingSeconds: Double = 6, beatMixEnabled: Bool = true,
        previousStyle: MusicTransitionStyle? = nil
    ) -> MusicMixPairInfo {
        let inputs = MusicTransitionInputs(
            outgoing: outgoing, incoming: incoming, crossfadeOn: true, settingSeconds: settingSeconds,
            beatMixEnabled: beatMixEnabled, bassSwapAvailable: true, previousStyle: previousStyle
        )
        let plan = MusicTransitionPlanner.plan(inputs)
        let row = incoming.analysis
        let bpm = (incoming.grid ?? row?.usableGrid).map { Int($0.bpm.rounded()) }
        return MusicMixPairInfo(
            bpm: bpm, camelot: row?.trustedCamelot, mode: plan.mode == .beat ? .beat : .fade,
            style: plan.mode == .beat ? plan.style : .longBlend
        )
    }

    /// The Up next chain: row i is planned with row i-1's style as its previous one, and row 0 with `lastApplied`, the
    /// style of the transition that is playing now. `sides[0]` is the playing song, so `sides.count - 1` entries come back.
    /// A nil side (no analysis row yet) gives a nil entry: that pair plays a plain fade, a long blend, so the next row is
    /// planned against `.longBlend`.
    @MainActor
    static func makeChain(
        sides: [MusicTransitionSide?], lastApplied: MusicTransitionStyle?, settingSeconds: Double = 6, beatMixEnabled: Bool = true
    ) -> [MusicMixPairInfo?] {
        guard sides.count >= 2 else { return [] }
        var previous = lastApplied
        var out: [MusicMixPairInfo?] = []
        for index in 1..<sides.count {
            guard let outgoing = sides[index - 1], let incoming = sides[index] else {
                out.append(nil)
                previous = .longBlend
                continue
            }
            let info = make(
                outgoing: outgoing, incoming: incoming, settingSeconds: settingSeconds,
                beatMixEnabled: beatMixEnabled, previousStyle: previous
            )
            out.append(info)
            previous = info.style
        }
        return out
    }
}
