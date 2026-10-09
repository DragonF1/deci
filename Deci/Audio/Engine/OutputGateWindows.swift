// Deci/Audio/Engine/OutputGateWindows.swift

/// Sample-count windows for the output gate, derived from the device sample rate.
///
/// The gate fades in over `rampSeconds` after silence and re-arms after
/// `silenceHoldSeconds` of input silence. Both are counted in samples, so they must be
/// recomputed whenever the aggregate's rate changes (activation, destructive switch,
/// crossfade promotion, Bluetooth A2DP/SCO flips); a window sized at 48 kHz is three
/// times too long at 16 kHz.
struct OutputGateWindows: Equatable {
    static let rampSeconds = 0.040
    static let silenceHoldSeconds = 0.200
    /// Used when the rate is unusable (zero, negative, NaN, infinite).
    static let fallbackSampleRate = 48_000.0

    /// Sample count for the half-cosine fade-in.
    let rampSamples: Float
    /// Sample count of sustained input silence before the gate re-arms.
    let silenceHoldSamples: Int32

    init(sampleRate: Double) {
        let rate = (sampleRate.isFinite && sampleRate > 0) ? sampleRate : Self.fallbackSampleRate
        rampSamples = Float(rate * Self.rampSeconds)
        let hold = rate * Self.silenceHoldSeconds
        silenceHoldSamples = hold >= Double(Int32.max) ? Int32.max : Int32(hold)
    }
}
