// Deci/Views/Music/MusicAnalysingSpinner.swift
import SwiftUI

/// The small loading circle beside a song that is being analysed: one solid round-capped arc that turns, in the colour
/// it is given (the current song's accent). With Reduce Motion on the arc stays still.
struct MusicAnalysingSpinner: View {
    let color: Color
    var size: CGFloat = 10
    var lineWidth: CGFloat = 1.8

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isTurning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.72)
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(isTurning ? 360 : 0))
            // Scoped to the turn, so a row that moves or resizes never animates its frame with it.
            .animation(
                reduceMotion ? nil : .linear(duration: 0.9).repeatForever(autoreverses: false),
                value: isTurning
            )
            .onAppear { isTurning = !reduceMotion }
            .onChange(of: reduceMotion) { _, reduce in isTurning = !reduce }
    }
}
