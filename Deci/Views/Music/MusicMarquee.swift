// Deci/Views/Music/MusicMarquee.swift
import SwiftUI

/// A line that scrolls when it is wider than its room, with the menu bar chip's hold, speed and gap: it holds at its
/// start, then scrolls left until a second copy stands where the first began, and again. Unlike the chip it does not
/// rest between runs: it is only drawn while the window is open, when the user is looking at it. It runs only while
/// the song plays and Reduce Motion is off; otherwise a line that does not fit is cut off as before. Anything inside,
/// buttons included, keeps working while it moves.
struct MusicMarquee<Content: View>: View {
    let isPlaying: Bool
    @ViewBuilder let content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var textWidth: CGFloat = 0
    @State private var roomWidth: CGFloat = 0
    /// When the marquee started; nil while it is off.
    @State private var runStart: Date?

    private var scrolls: Bool { textWidth > roomWidth + 0.5 }

    var body: some View {
        let runs = MusicChipMotion.runsMarquee(scrolls: scrolls, isPlaying: isPlaying, reduceMotion: reduceMotion)
        // minWidth 0 keeps both branches at the room's width: without it the frame grows to a wider line, the line
        // spills out of its column and the room reads as wide as the line.
        Group {
            if runs {
                TimelineView(.animation(paused: runStart == nil)) { context in
                    let offset = runStart.map {
                        MusicChipMotion.marqueeOffset(
                            elapsed: MusicChipMotion.marqueeLoopElapsed(
                                context.date.timeIntervalSince($0), textWidth: textWidth
                            ),
                            textWidth: textWidth
                        )
                    } ?? 0
                    HStack(spacing: MusicChipMotion.marqueeGap) {
                        content.fixedSize()
                        content.fixedSize().accessibilityHidden(true)
                    }
                    .offset(x: offset)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    .clipped()
                    .mask { edgeFade(leading: offset < 0) }
                }
            } else {
                content
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            }
        }
        .background {
            // The line at its full width, never shown, to tell whether it fits.
            content.fixedSize().hidden()
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { roomWidth = $0 }
        .task(id: runs ? textWidth : -1) {
            runStart = runs ? .now : nil
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
