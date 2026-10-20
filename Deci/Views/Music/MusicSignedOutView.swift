// Deci/Views/Music/MusicSignedOutView.swift
import SwiftUI

/// The right column before a session exists (under the header with the tabs at a third of their strength and the
/// placeholder avatar): a centred stack with a headphones badge, what signing in gives, the white Sign in button and a
/// note that it opens a window. While that window is open the same stack shows a spinner and no button. The sign-in
/// window itself is the unchanged YouTube Music one.
struct MusicSignedOutView: View {
    let service: MusicService
    let isSigningIn: Bool

    /// The room under the stack, which lifts it above the middle of the column.
    private static let bottomPadding: CGFloat = 36
    private static let descriptionWidth: CGFloat = 250

    var body: some View {
        VStack(spacing: 0) {
            if isSigningIn {
                signingIn
            } else {
                signedOut
            }
        }
        .padding(.bottom, Self.bottomPadding)
        .padding(.horizontal, DesignTokens.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var signedOut: some View {
        VStack(spacing: 0) {
            MusicStateIconCircle(symbol: "headphones")
            Text("Sign in to YouTube Music")
                .musicText(MusicStyle.Typeface.stateTitle)
                .foregroundStyle(MusicStyle.Palette.textPlaying)
                .multilineTextAlignment(.center)
                .padding(.top, 14)
                .accessibilityAddTraits(.isHeader)
            Text("Play your library, playlists and liked songs from the menu bar. The mixer keeps working without an account.")
                .musicText(MusicStyle.Typeface.stateMessage)
                .foregroundStyle(Color.white.opacity(0.55))
                .lineSpacing(2.5)
                .multilineTextAlignment(.center)
                .frame(maxWidth: Self.descriptionWidth)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            Button {
                service.signIn()
            } label: {
                Text("Sign in")
                    .musicText(MusicStyle.Typeface.stateButton)
                    .foregroundStyle(MusicStyle.Palette.popupBackground)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 6)
                    .background(Capsule(style: .continuous).fill(Color.white.opacity(0.95)))
                    .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(MusicSignInPress())
            .accessibilityLabel("Sign in to YouTube Music")
            .padding(.top, 16)
            Text("Opens a sign-in window")
                .musicText(MusicStyle.Typeface.secondary)
                .foregroundStyle(Color.white.opacity(0.40))
                .padding(.top, 8)
            if let message = service.lastError {
                Text(message)
                    .musicText(MusicStyle.Typeface.caption)
                    .foregroundStyle(MusicStyle.Palette.textMeta)
                    .multilineTextAlignment(.center)
                    .padding(.top, 10)
            }
        }
    }

    private var signingIn: some View {
        VStack(spacing: 0) {
            MusicStateIconCircle(symbol: nil)
                .overlay { MusicSpinner(size: 22) }
            Text("Finish signing in in the YouTube Music window.")
                .musicText(MusicStyle.Typeface.stateMessage)
                .foregroundStyle(MusicStyle.Palette.textSub)
                .multilineTextAlignment(.center)
                .frame(maxWidth: Self.descriptionWidth)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A press dims the white Sign in button a little, like the action pills.
private struct MusicSignInPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(DesignTokens.Animation.hover, value: configuration.isPressed)
    }
}
