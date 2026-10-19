// Deci/Views/Music/MusicPlayerBackdrop.swift
import SwiftUI

/// What is behind a player screen, over the whole popover: the cover's tint as the base, the cover itself blurred over
/// it, and a dark fade from the top down so the controls stay readable on any cover. Lyrics and Up next sit under text,
/// so their fade is darker than Now Playing's.
struct MusicPlayerBackdrop: View {
    let coverURL: URL?
    let tint: MusicTint
    let screen: MusicShellScreen

    /// The cover is drawn this big and centred, so only its blurred middle reaches the popover.
    static let coverSide: CGFloat = 900
    static let blurRadius: CGFloat = 45

    var body: some View {
        let dim = MusicPlayerDim.stops(for: screen)
        ZStack {
            tint.page
            cover
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(dim.top), location: 0),
                    .init(color: .black.opacity(dim.middle), location: 0.5),
                    .init(color: .black.opacity(dim.bottom), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .animation(.easeInOut(duration: 0.4), value: tint)
        .animation(.easeInOut(duration: 0.25), value: dim)
        .accessibilityHidden(true)
    }

    /// Drawn inside a clear box that takes the popover's size, so the big picture never makes the popover bigger.
    @ViewBuilder
    private var cover: some View {
        if let coverURL {
            Color.clear
                .overlay {
                    AsyncImage(url: coverURL) { phase in
                        if case .success(let image) = phase {
                            image.resizable().scaledToFill()
                        } else {
                            Color.clear
                        }
                    }
                    .frame(width: Self.coverSide, height: Self.coverSide)
                    .blur(radius: Self.blurRadius)
                    .transition(.opacity)
                }
                .clipped()
        }
    }
}
