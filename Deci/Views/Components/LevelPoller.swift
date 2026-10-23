// Deci/Views/Components/LevelPoller.swift
import Foundation

/// Samples one audio level on a timer for a VU meter, and only while it is started.
///
/// A meter row used to keep its level in its own `@State`, so every tick re-evaluated the whole row, its
/// controls and its closures included. The level lives here instead and only `PolledVUMeter` reads it, so a
/// tick redraws the meter and nothing else. Stopped, there is no timer at all: a row whose popup is closed
/// polls nothing, and a tick that reads the level it already has publishes nothing.
@Observable
@MainActor
final class LevelPoller {
    /// The last level sampled: 0 while stopped.
    private(set) var level: Float

    @ObservationIgnored private let interval: TimeInterval
    @ObservationIgnored private var sample: (() -> Float)?
    @ObservationIgnored private var timer: Timer?

    /// True between `start` and `stop`. Observed, so a meter can drop its peak marker the moment its poller stops.
    private(set) var isRunning = false

    // A poller dropped without a stop must not leave its timer behind.
    isolated deinit {
        timer?.invalidate()
    }

    /// `level` is the resting level, for a preview that wants a fixed meter.
    init(level: Float = 0, interval: TimeInterval = DesignTokens.Timing.vuMeterUpdateInterval) {
        self.level = level
        self.interval = interval
    }

    /// Reads `sample` every `interval` until `stop()`. Starting a running poller only swaps the source.
    func start(_ sample: @escaping () -> Float) {
        self.sample = sample
        guard timer == nil else { return }
        if !isRunning { isRunning = true }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// Takes the timer down and returns the meter to rest.
    func stop() {
        timer?.invalidate()
        timer = nil
        sample = nil
        if isRunning { isRunning = false }
        publish(0)
    }

    /// One sample. The timer calls it; a test can call it without waiting for the timer.
    func tick() {
        guard let sample else { return }
        publish(sample())
    }

    private func publish(_ new: Float) {
        if level != new { level = new }
    }
}
