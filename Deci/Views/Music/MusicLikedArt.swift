// Deci/Views/Music/MusicLikedArt.swift
import SwiftUI

/// The art of Liked music, drawn instead of a cover: a warm dark base under a wash of the accent that fades down, and an
/// accent heart in the middle.
struct MusicLikedArt: View {
    let size: CGFloat
    var cornerRadius: CGFloat = MusicStyle.Radius.art

    @Environment(\.musicAccent) private var accent

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            MusicStyle.Palette.hex(MusicLikedArtStyle.baseHex)
            LinearGradient(
                colors: [
                    accent.solid.opacity(MusicLikedArtStyle.topOpacity),
                    accent.solid.opacity(MusicLikedArtStyle.bottomOpacity),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            Image(systemName: "heart.fill")
                .font(.system(size: MusicLikedArtStyle.heartSize(art: size)))
                .foregroundStyle(accent.solid)
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(shape.strokeBorder(MusicStyle.Palette.strokeSoft, lineWidth: 1))
        .accessibilityHidden(true)
    }
}
