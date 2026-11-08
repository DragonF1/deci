// Deci/Music/Playback/MusicEnergyArc.swift
// The shape a mix window follows: warm up, build, peak, breather, build again. Pure.

import Foundation

nonisolated struct MusicEnergyArc: Sendable {
    /// (position, target) knots, linear between them.
    private static let knots: [(Double, Float)] = [
        (0, 0.3), (0.25, 0.55), (0.6, 0.85), (0.78, 0.5), (1, 0.8),
    ]

    /// Wanted energy 0...1 at a position 0...1 across the window; out of range or NaN clamps.
    static func target(position: Double) -> Float {
        guard position.isFinite else { return knots[0].1 }
        let p = max(0, min(1, position))
        for index in 1..<knots.count where p <= knots[index].0 {
            let (x0, y0) = knots[index - 1], (x1, y1) = knots[index]
            return y0 + (y1 - y0) * Float((p - x0) / (x1 - x0))
        }
        return knots[knots.count - 1].1
    }
}
