// Deci/Audio/Engine/SwitchVolumeRamp.swift

/// Main-actor bookkeeping for the volume around a destructive device switch.
///
/// A destructive switch silences the output, rebuilds the aggregate, then steps the
/// real-time volume variable back up. While it runs it owns that variable, so:
///   - the user/engine target lives here, separate from the RT variable;
///   - a write to the target during the ramp is stored but not published, and the ramp
///     steps and the final restore always read the live target (no stale snapshot);
///   - each switch gets a generation token, so an older switch that is overtaken by a
///     newer one (or by an invalidate) can no longer touch volume or silence.
///
/// Pure value type: no CoreAudio, no threading. The controller publishes the values
/// this returns to its `nonisolated(unsafe)` RT variables.
struct SwitchVolumeRamp: Equatable {
    /// Identifies one destructive switch. Stale once a newer switch begins or `cancelAll` runs.
    struct Token: Equatable {
        fileprivate let generation: UInt64
    }

    /// What the user/engine wants (app volume x boost x software device gain).
    private(set) var target: Float
    /// True while a switch owns the RT volume variable.
    private(set) var isRamping = false
    private var generation: UInt64 = 0

    init(target: Float = 1.0) {
        self.target = target
    }

    /// Stores a new target. Returns the value to publish to the RT variable right now,
    /// or nil while a switch ramp owns it (the ramp and its restore pick the target up).
    mutating func setTarget(_ value: Float) -> Float? {
        target = value
        return isRamping ? nil : value
    }

    /// Starts a switch. Any switch that began earlier becomes stale.
    mutating func begin() -> Token {
        generation &+= 1
        isRamping = true
        return Token(generation: generation)
    }

    /// True while `token` belongs to the newest switch and no `cancelAll` has happened since.
    func isCurrent(_ token: Token) -> Bool {
        isRamping && token.generation == generation
    }

    /// RT volume for ramp step `step` of `steps`: the live target scaled linearly.
    /// Step 0 (or below) is silence; `steps` (or above) is exactly the target.
    func stepVolume(step: Int, of steps: Int) -> Float {
        guard steps > 0 else { return target }
        if step <= 0 { return 0 }
        if step >= steps { return target }
        return target * Float(step) / Float(steps)
    }

    /// Ends the ramp for `token`. Returns the target to restore on the RT variable, or nil
    /// when the token is stale (superseded or cancelled): a stale switch restores nothing.
    mutating func finish(_ token: Token) -> Float? {
        guard isCurrent(token) else { return nil }
        isRamping = false
        return target
    }

    /// Invalidates every outstanding token (tap torn down) and returns the target for the
    /// caller to publish.
    mutating func cancelAll() -> Float {
        generation &+= 1
        isRamping = false
        return target
    }
}
