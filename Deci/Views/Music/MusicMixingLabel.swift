// Deci/Views/Music/MusicMixingLabel.swift
import SwiftUI

/// The word "Mixing" in the song's colour with a light glint sweeping across it, shown while the engine mixes this song
/// into the next one (from `MusicMixCue.lead` before the overlap to its end). It sits in the times row, in the row's
/// 10 pt monospaced type. The glint is a short repeating animation that only runs while the word is on screen, so for a
/// few seconds per song. It holds still while the song is paused, and with Reduce Motion on the word stays plain.
struct MusicMixingLabel: View {
    let color: Color
    /// False while the song is paused: the mix is held, so the glint stops.
    var isMoving = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isSweeping = false

    /// One pass of the glint, its gap after it included.
    private static let sweepDuration: TimeInterval = 1.8
    /// The glint band's width as a share of the word's.
    private static let bandShare: CGFloat = 0.55

    var body: some View {
        word
            .foregroundStyle(color)
            .overlay { glint }
            .accessibilityLabel("Mixing songs")
            .onAppear { isSweeping = sweeps }
            .onChange(of: sweeps) { _, now in isSweeping = now }
    }

    private var sweeps: Bool { isMoving && !reduceMotion }

    private var word: Text {
        Text("Mixing")
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
    }

    /// A white band that moves from before the word to well past it (the overshoot is the pause between passes), cut to
    /// the letters.
    private var glint: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let band = max(1, width * Self.bandShare)
            LinearGradient(
                colors: [.white.opacity(0), .white.opacity(0.85), .white.opacity(0)],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: band, height: proxy.size.height)
            .offset(x: isSweeping ? width + band : -band)
            // Scoped to the sweep, so a row that moves or resizes never animates its frame with it.
            .animation(
                isSweeping ? .linear(duration: Self.sweepDuration).repeatForever(autoreverses: false) : nil,
                value: isSweeping
            )
        }
        .mask(word)
        .opacity(isSweeping ? 1 : 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Gives `content` whether the "Mixing" label is due for `cue`: at once for a mix that is playing, and from
/// `MusicMixCue.lead` before an upcoming one. The answer is read from the clock on every pass, so a cue that changes while
/// the label shows (upcoming to mixing at the overlap's start, a schedule moved) keeps it on screen without a gap. A timer
/// of its own wakes the body when an upcoming label falls due (the times row's half second ticks stop when the song
/// pauses).
struct MusicMixCueReader<Content: View>: View {
    let cue: MusicMixCue?
    @ViewBuilder let content: (_ showsMixing: Bool) -> Content

    /// Bumped when an upcoming cue's label falls due, so the body reads the clock again.
    @State private var wakes = 0

    var body: some View {
        let _ = wakes
        content(cue?.showsLabel(at: Date()) ?? false)
            .task(id: cue) {
                guard let cue else { return }
                let wait = cue.secondsUntilLabel(from: Date())
                guard wait > 0 else { return }
                // A little after the due time, so the clock read on the wake is surely past it.
                try? await Task.sleep(for: .seconds(wait + 0.02))
                guard !Task.isCancelled else { return }
                wakes &+= 1
            }
    }
}
