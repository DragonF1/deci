// Deci/Views/Music/MusicSignedOutView.swift
import SwiftUI

/// The Music popover before a session exists: a blurred, tilted wall of covers with the sign-in button over it,
/// and the same wall behind the "finish signing in" message while the sign-in window is open. The sign-in window
/// itself is the unchanged YouTube Music one.
struct MusicSignedOutView: View {
    let service: MusicService
    let isSigningIn: Bool

    var body: some View {
        ZStack(alignment: .top) {
            MusicCoverWall()
            LinearGradient(
                stops: [
                    .init(color: MusicStyle.Palette.base.opacity(0.50), location: 0),
                    .init(color: MusicStyle.Palette.base.opacity(0.76), location: 0.34),
                    .init(color: MusicStyle.Palette.base.opacity(0.82), location: 0.64),
                    .init(color: MusicStyle.Palette.base.opacity(0.96), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)

            if isSigningIn {
                signingIn
            } else {
                signedOut
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private var signedOut: some View {
        VStack(spacing: 24) {
            Image(systemName: "music.note")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 72, height: 72)
                .musicGlass(
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous),
                    fill: MusicStyle.Palette.fillControl2,
                    stroke: MusicStyle.Palette.lineGlyphTile
                )
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text("Your music, inside Deci")
                    .musicText(MusicStyle.Typeface.title1)
                    .foregroundStyle(.white)
                    .accessibilityAddTraits(.isHeader)
                Text("Sign in to search and play from your YouTube Music account.")
                    .musicText(MusicStyle.Typeface.body14)
                    .foregroundStyle(MusicStyle.Palette.textSung)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 14) {
                Button(action: { service.signIn() }) {
                    HStack(spacing: 10) {
                        MusicGoogleGlyph()
                        Text("Sign in to YouTube Music")
                            .musicText(MusicStyle.Typeface.row15SB)
                            .foregroundStyle(MusicStyle.Palette.base)
                    }
                    .frame(width: 270, height: 44)
                }
                .buttonStyle(MusicGoogleButtonStyle())

                HStack(spacing: 5) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 12))
                        .accessibilityHidden(true)
                    Text("Your sign-in stays in the Keychain.")
                        .musicText(MusicStyle.Typeface.caption11R)
                }
                .foregroundStyle(Color.white.opacity(0.5))

                if let message = service.lastError {
                    Text(message)
                        .musicText(MusicStyle.Typeface.caption11R)
                        .foregroundStyle(MusicStyle.Palette.textTertiary)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .frame(maxWidth: 400)
        .padding(.horizontal, MusicStyle.Spacing.page)
        .padding(.top, 125)
    }

    private var signingIn: some View {
        VStack(spacing: 24) {
            ProgressView()
                .controlSize(.regular)
                .environment(\.colorScheme, .dark)
            Text("Finish signing in in the YouTube Music window.")
                .musicText(MusicStyle.Typeface.status15)
                .foregroundStyle(Color.white.opacity(0.85))
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, MusicStyle.Spacing.page)
        .padding(.top, 125)
    }
}

/// White pill with the dark label: lighter grey under the pointer and darker while pressed.
private struct MusicGoogleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        MusicGoogleButtonSurface(configuration: configuration)
    }
}

/// A view of its own, because the hover state needs a view to live in.
private struct MusicGoogleButtonSurface: View {
    let configuration: ButtonStyleConfiguration
    @State private var isHovered = false

    var body: some View {
        let fill = configuration.isPressed ? MusicStyle.Palette.hex(0xE5E5E5)
            : isHovered ? MusicStyle.Palette.hex(0xF2F2F2) : Color.white
        configuration.label
            .background(Capsule().fill(fill))
            .shadow(
                color: MusicStyle.Shadow.button.color,
                radius: MusicStyle.Shadow.button.radius,
                y: MusicStyle.Shadow.button.y
            )
            .contentShape(Capsule())
            .onHover { isHovered = $0 }
    }
}

/// A stand-in for Google's "G": the letter filled with the four brand colours. The app ships no Google asset.
private struct MusicGoogleGlyph: View {
    var body: some View {
        Text("G")
            .font(.system(size: 18, weight: .bold, design: .rounded))
            .foregroundStyle(
                AngularGradient(
                    stops: [
                        .init(color: MusicStyle.Palette.hex(0x4285F4), location: 0),
                        .init(color: MusicStyle.Palette.hex(0x34A853), location: 0.30),
                        .init(color: MusicStyle.Palette.hex(0xFBBC05), location: 0.55),
                        .init(color: MusicStyle.Palette.hex(0xEA4335), location: 0.80),
                        .init(color: MusicStyle.Palette.hex(0x4285F4), location: 1),
                    ],
                    center: .center,
                    angle: .degrees(-45)
                )
            )
            .frame(width: 18, height: 18)
            .accessibilityHidden(true)
    }
}

/// The tilted mosaic behind the signed-out screen: 5 rows of 6 covers, each 128 pt, centred and turned 12 degrees,
/// overflowing every edge of the popover. The covers are generated gradients, not real albums: the screen is shown
/// before any account is known, so there is nothing of the owner's to draw.
struct MusicCoverWall: View {
    static let columns = 6
    static let rows = 5
    static let tile: CGFloat = 128
    static let gap: CGFloat = 14

    var body: some View {
        VStack(spacing: Self.gap) {
            ForEach(0..<Self.rows, id: \.self) { row in
                HStack(spacing: Self.gap) {
                    ForEach(0..<Self.columns, id: \.self) { column in
                        cover(index: row * Self.columns + column)
                    }
                }
            }
        }
        .fixedSize()
        // One flat layer before the turn and the blur, instead of 30 gradient tiles blurred one by one.
        .drawingGroup()
        .rotationEffect(.degrees(-12))
        .blur(radius: 9)
        .opacity(0.8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .accessibilityHidden(true)
    }

    private func cover(index: Int) -> some View {
        let tint = MusicTint.forKey("wall-\(index)")
        let shift = Double(MusicHash.fnv1a("shift-\(index)") % 12) / 100
        return RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color(hue: tint.hue, saturation: 0.55, brightness: 0.85),
                        Color(hue: tint.hue + shift, saturation: 0.75, brightness: 0.40),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: Self.tile, height: Self.tile)
    }
}
