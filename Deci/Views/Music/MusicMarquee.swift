// Deci/Views/Music/MusicMarquee.swift
import SwiftUI

/// A line that scrolls when it is wider than its room, as the menu bar chip's title does: it holds at its start, then
/// scrolls left until a second copy stands where the first began, runs a few loops and rests (MusicChipMotion has the
/// timing). It runs only while the song plays and Reduce Motion is off; otherwise a line that does not fit is cut off
/// as before. Anything inside, buttons included, keeps working while it moves.
struct MusicMarquee<Content: View>: View {
    let isPlaying: Bool
    @ViewBuilder let content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var textWidth: CGFloat = 0
    @State private var roomWidth: CGFloat = 0
    /// When the run in progress started; nil while the marquee rests between runs.
    @State private var runStart: Date?

    private var scrolls: Bool { textWidth > roomWidth + 0.5 }

    var body: some View {
        let runs = MusicChipMotion.runsMarquee(scrolls: scrolls, isPlaying: isPlaying, reduceMotion: reduceMotion)
        Group {
            if runs {
                TimelineView(.animation(paused: runStart == nil)) { context in
                    let offset = runStart.map {
                        MusicChipMotion.marqueeOffset(elapsed: context.date.timeIntervalSince($0), textWidth: textWidth)
                    } ?? 0
                    HStack(spacing: MusicChipMotion.marqueeGap) {
                        content.fixedSize()
                        content.fixedSize().accessibilityHidden(true)
                    }
                    .offset(x: offset)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .clipped()
                    .mask { edgeFade(leading: offset < 0) }
                }
            } else {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background {
            // The line at its full width, never shown, to tell whether it fits.
            content.fixedSize().hidden()
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { roomWidth = $0 }
        .task(id: runs ? textWidth : -1) {
            runStart = nil
            guard runs else { return }
            let run = MusicChipMotion.marqueeRunDuration(textWidth: textWidth)
            while !Task.isCancelled {
                runStart = .now
                try? await Task.sleep(for: .seconds(run))
                runStart = nil
                try? await Task.sleep(for: .seconds(MusicChipMotion.marqueeRest))
            }
        }
    }

    /// Fades the end of the line, and its start too while the text is off its start, so letters slide out instead of
    /// being cut.
    private func edgeFade(leading: Bool) -> some View {
        let fade = MusicChipMotion.edgeFadeWidth
        return HStack(spacing: 0) {
            LinearGradient(colors: [leading ? .clear : .black, .black], startPoint: .leading, endPoint: .trailing)
                .frame(width: fade)
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: fade)
        }
    }
}
