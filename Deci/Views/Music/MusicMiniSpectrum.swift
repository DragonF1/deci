// Deci/Views/Music/MusicMiniSpectrum.swift
import SwiftUI

/// The numbers of the small spectrum that marks the playing row: four bars, 2 wide on a 4 pt pitch, in a 14 by 12 box,
/// bottom aligned. At rest they stand at 7, 12, 5 and 10; while audio plays each one moves between 3 and 12 at its own
/// speed. Kept apart from the view so the heights are tested.
nonisolated enum MusicMiniSpectrum {
    static let width: CGFloat = 14
    static let height: CGFloat = 12
    static let barCount = 4
    static let barWidth: CGFloat = 2
    /// The distance from one bar's left edge to the next one's.
    static let pitch: CGFloat = 4
    static let radius: CGFloat = 1
    static let minHeight: CGFloat = 3
    static let maxHeight: CGFloat = 12
    static let restHeights: [CGFloat] = [7, 12, 5, 10]
    /// How long one bar takes for a full swing, so no two move together.
    static let periods: [Double] = [0.9, 0.7, 1.1, 0.8]

    /// The height of every bar at `time` (seconds). Still at the rest heights unless `isAnimating`, and for a time that
    /// is not a number.
    static func heights(at time: TimeInterval, isAnimating: Bool) -> [CGFloat] {
        guard isAnimating, time.isFinite else { return restHeights }
        return (0..<barCount).map { index in
            let wave = (sin(time * 2 * .pi / periods[index] + Double(index)) + 1) / 2
            let height = minHeight + (maxHeight - minHeight) * CGFloat(wave)
            return min(max(height, minHeight), maxHeight)
        }
    }

    /// The left edge of bar `index` inside the box.
    static func barX(_ index: Int) -> CGFloat { CGFloat(index) * pitch }
}

/// The small spectrum on a row that is current. It moves only while the song plays and the popup is on screen, and
/// rests at fixed heights otherwise, so a paused or hidden popup costs no redraws.
struct MusicMiniSpectrumView: View {
    let isPlaying: Bool

    @Environment(\.musicAccent) private var accent
    @Environment(\.musicPopupIsVisible) private var isPopupVisible

    private var isAnimating: Bool { isPlaying && isPopupVisible }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !isAnimating)) { context in
            let heights = MusicMiniSpectrum.heights(at: context.date.timeIntervalSinceReferenceDate, isAnimating: isAnimating)
            ZStack(alignment: .bottomLeading) {
                ForEach(0..<MusicMiniSpectrum.barCount, id: \.self) { index in
                    RoundedRectangle(cornerRadius: MusicMiniSpectrum.radius, style: .continuous)
                        .fill(accent.solid)
                        .frame(width: MusicMiniSpectrum.barWidth, height: heights[index])
                        .offset(x: MusicMiniSpectrum.barX(index))
                }
            }
            .frame(width: MusicMiniSpectrum.width, height: MusicMiniSpectrum.height, alignment: .bottomLeading)
        }
        .accessibilityHidden(true)
    }
}

private struct MusicPopupIsVisibleKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True while the Music popup is on screen: the playing row's spectrum moves only then. False by default, so a view
    /// outside the popup rests.
    var musicPopupIsVisible: Bool {
        get { self[MusicPopupIsVisibleKey.self] }
        set { self[MusicPopupIsVisibleKey.self] = newValue }
    }
}
