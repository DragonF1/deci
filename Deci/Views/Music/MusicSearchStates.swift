// Deci/Views/Music/MusicSearchStates.swift
import SwiftUI

// The pieces a filtered screen adds: the line that counts what matched, the "other matches" row of Library and the
// block shown when nothing matched. Library, a playlist or an album and Up next share them.

/// A filtered list's scope line: "3 OF 42 SONGS" as a small label and, when there is a way out, "Clear filter" at the
/// end of the line.
struct MusicScopeLine: View {
    let text: String
    /// Shows "Clear filter" at the end; nil leaves the line as the label alone.
    var clear: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Text(text)
                .musicText(MusicStyle.Typeface.kicker)
                .foregroundStyle(MusicStyle.Palette.textMeta)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            if let clear {
                Button(action: clear) {
                    Text(MusicSearchCopy.clearFilter)
                        .musicText(MusicStyle.Typeface.secondaryMedium)
                        .foregroundStyle(Color.white.opacity(0.55))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, MusicStyle.Spacing.page)
    }
}

/// Library's "Also 2 albums and 1 artist match" row: the line, and at its end the segment holding most of them. A click
/// switches to that segment and keeps the words.
struct MusicOtherMatchesRow: View {
    let match: MusicOtherMatches
    let action: () -> Void

    @State private var isHovered = false

    private var targetName: String {
        MusicLibrarySection(noun: match.target).title
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(match.text)
                    .musicText(MusicStyle.Typeface.secondary)
                    .foregroundStyle(MusicStyle.Palette.textSub)
                    .lineLimit(1)
                Spacer(minLength: 8)
                HStack(spacing: 4) {
                    Text(targetName)
                        .musicText(MusicStyle.Typeface.secondaryMedium)
                        .foregroundStyle(Color.white.opacity(isHovered ? 0.90 : 0.70))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.45))
                }
            }
            .padding(.horizontal, MusicStyle.Spacing.page)
            .frame(height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel("\(match.text). Show \(targetName)")
    }
}

/// What a filter that found nothing shows: a magnifier in a circle, what was searched, where it looked and the link that
/// takes the same words to YouTube Music.
struct MusicNoResultsBlock: View {
    let title: String
    let detail: String
    let searchYouTube: () -> Void

    @Environment(\.musicAccent) private var accent

    var body: some View {
        VStack(spacing: 6) {
            MusicStateIconCircle(symbol: "magnifyingglass", size: 40, symbolSize: 16)
            Text(title)
                .musicText(MusicStyle.Typeface.heading)
                .foregroundStyle(Color.white.opacity(0.92))
                .multilineTextAlignment(.center)
            Text(detail)
                .musicText(MusicStyle.Typeface.stateMessage)
                .foregroundStyle(MusicStyle.Palette.textSub)
                .multilineTextAlignment(.center)
            Button(action: searchYouTube) {
                HStack(spacing: 4) {
                    Text(MusicSearchCopy.searchYouTubeInstead)
                        .musicText(MusicStyle.Typeface.stateButton)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(accent.solid)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, MusicStyle.Spacing.page)
        .padding(.top, 36)
        .padding(.bottom, 12)
    }
}
