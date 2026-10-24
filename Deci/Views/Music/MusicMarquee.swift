// Deci/Views/Music/MusicMarquee.swift
import SwiftUI

/// A line that scrolls when it is wider than its room, with the menu bar chip's hold, speed and gap: it holds at its
/// start, then scrolls left until a second copy stands where the first began, and again. Unlike the chip it does not
/// rest between runs: it is only drawn while the window is open, when the user is looking at it. It runs only while
/// the song plays and Reduce Motion is off; otherwise a line that does not fit is cut off as before. Buttons inside
/// keep working while it moves when the marquee is `isInteractive`.
///
/// While it runs, the line is a hosting view of its own that Core Animation slides on the render server
/// (`MusicMarqueeView`): the app does nothing per frame and the SwiftUI tree is not touched, so the popup's window does
/// not lay out, redraw or re-resolve its tracking areas every frame for it. Only while the pointer is over an
/// `isInteractive` line does a display link move it by frame, so its buttons are where they show.
struct MusicMarquee<Content: View>: View {
    let isPlaying: Bool
    /// The line holds something to click (the artist names). A line with nothing to click lets every click through to
    /// the view behind it, which carries the tooltip and the menu.
    var isInteractive = false
    @ViewBuilder let content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The marquee scrolls only while the popup is on screen: its window keeps this view mounted when closed.
    @Environment(\.musicPopupIsVisible) private var isPopupVisible
    @State private var textWidth: CGFloat = 0
    @State private var roomWidth: CGFloat = 0

    private var scrolls: Bool { textWidth > roomWidth + 0.5 }

    var body: some View {
        let runs = MusicChipMotion.runsMarquee(scrolls: scrolls, isPlaying: isPlaying && isPopupVisible, reduceMotion: reduceMotion)
        // minWidth 0 keeps both branches at the room's width: without it the frame grows to a wider line, the line
        // spills out of its column and the room reads as wide as the line.
        Group {
            if runs {
                // The line in its room, unseen, gives the view its height; the moving line lies over it.
                content
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    .hidden()
                    .overlay {
                        MusicMarqueeTrack(content: content, textWidth: textWidth, isInteractive: isInteractive)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .contentShape(Rectangle())
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
    }
}
