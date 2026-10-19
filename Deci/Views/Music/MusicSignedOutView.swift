// Deci/Views/Music/MusicSignedOutView.swift
import SwiftUI

/// The Music popover before a session exists: a centred note and the Mixer's plain sign-in button, and the same
/// layout with a spinner while the sign-in window is open. The sign-in window itself is the unchanged YouTube Music one.
struct MusicSignedOutView: View {
    let service: MusicService
    let isSigningIn: Bool

    var body: some View {
        Group {
            if isSigningIn {
                signingIn
            } else {
                signedOut
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var signedOut: some View {
        VStack(spacing: DesignTokens.Spacing.md) {
            Image(systemName: "music.note.list")
                .font(.system(size: 26))
                .foregroundStyle(DesignTokens.Colors.textTertiary)
                .accessibilityHidden(true)
            Text("Sign in to search and play from your YouTube Music account.")
                .font(DesignTokens.Typography.rowDescription)
                .foregroundStyle(DesignTokens.Colors.textSecondary)
                .multilineTextAlignment(.center)
            Button("Sign in to YouTube Music") {
                service.signIn()
            }
            .buttonStyle(.plain)
            .font(DesignTokens.Typography.pickerText)
            .foregroundStyle(DesignTokens.Colors.textPrimary)
            .glassButtonStyle()
            if let message = service.lastError {
                Text(message)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var signingIn: some View {
        VStack(spacing: DesignTokens.Spacing.sm) {
            ProgressView()
                .controlSize(.small)
            Text("Finish signing in in the YouTube Music window.")
                .font(DesignTokens.Typography.rowDescription)
                .foregroundStyle(DesignTokens.Colors.textSecondary)
                .multilineTextAlignment(.center)
        }
    }
}
