// Deci/Views/Music/MusicLyricsView.swift
import SwiftUI

/// The lyrics panel of the Music tab: it replaces the content area while the lyrics button is on, like Up next.
/// Synced lyrics scroll with the song and a tap on a line jumps there; plain lyrics are just text.
struct MusicLyricsView: View {
    let store: MusicLyricsStore
    /// Jumps the song to a time in seconds.
    let seek: (TimeInterval) -> Void

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.xs) {
            Text("Lyrics")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Colors.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)

            content
                .frame(maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch store.state {
        case .idle:
            if store.track == nil {
                MusicEmptyView(text: "Play a song to see its lyrics.")
            } else {
                MusicLoadingView()
            }
        case .loading:
            MusicLoadingView()
        case .failed(let message):
            MusicFailedView(message: message) { store.retry() }
        case .busy(let until):
            MusicLyricsBusyView(until: until) { store.retry() }
        case .loaded(.synced(let lines)):
            MusicSyncedLyricsList(store: store, lines: lines, seek: seek)
        case .loaded(.plain(let text)):
            MusicPlainLyricsView(text: text)
        case .loaded(.instrumental):
            MusicEmptyView(text: "Instrumental")
        case .loaded(.notFound):
            MusicEmptyView(text: "No lyrics for this song.")
        }
    }
}

/// LRCLIB asked us to wait. Retry appears once the window has passed; until then nothing is sent.
private struct MusicLyricsBusyView: View {
    let until: Date
    let retry: () -> Void

    var body: some View {
        // Ticks once a second, only while the busy message is on screen.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: DesignTokens.Spacing.sm) {
                Text("Lyrics service is busy. Try again in a minute.")
                    .font(DesignTokens.Typography.rowDescription)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                if context.date >= until {
                    Button("Retry", action: retry)
                        .buttonStyle(.plain)
                        .font(DesignTokens.Typography.pickerText)
                        .foregroundStyle(DesignTokens.Colors.textPrimary)
                        .glassButtonStyle()
                        .contentShape(Rectangle())
                }
            }
            .padding(.horizontal, DesignTokens.Spacing.xl)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private extension View {
    /// Fades the first and last few points of a scrolling list, so a line cut by the edge does not look clipped.
    func lyricsEdgeFade() -> some View {
        mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.035),
                    .init(color: .black, location: 0.965),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
}

private struct MusicLyricsCredit: View {
    var body: some View {
        Text("Lyrics from LRCLIB")
            .font(DesignTokens.Typography.caption)
            .foregroundStyle(DesignTokens.Colors.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .padding(.vertical, DesignTokens.Spacing.md)
    }
}

/// Lyrics with no timing: text to read, marked as not synced.
private struct MusicPlainLyricsView: View {
    let text: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                Text("Not synced")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
                Text(text)
                    .font(DesignTokens.Typography.rowName)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                MusicLyricsCredit()
                    .padding(.horizontal, -DesignTokens.Spacing.sm)
            }
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .padding(.top, DesignTokens.Spacing.md)
        }
        .scrollIndicators(.never)
        .lyricsEdgeFade()
    }
}

/// Where a line is relative to the song: sung, being sung, or still to come.
private enum MusicLyricPosition {
    case past, current, upcoming
}

private struct MusicLyricRow: View {
    let text: String
    let position: MusicLyricPosition
    let action: () -> Void

    private var isCurrent: Bool { position == .current }

    var body: some View {
        Button(action: action) {
            // An empty timed line is an instrumental gap.
            Text(text.isEmpty ? "\u{266A}" : text)
                .font(.system(size: isCurrent ? 15 : 13, weight: isCurrent ? .semibold : .regular))
                .foregroundStyle(color)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DesignTokens.Spacing.sm)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(text.isEmpty ? "Instrumental break" : text)
        .accessibilityHint("Jumps to this line")
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    private var color: Color {
        switch position {
        case .current: DesignTokens.Colors.textPrimary
        case .past: DesignTokens.Colors.textTertiary
        case .upcoming: DesignTokens.Colors.textSecondary
        }
    }
}

/// Timed lines with the current one highlighted and kept near the middle of the panel.
private struct MusicSyncedLyricsList: View {
    let store: MusicLyricsStore
    let lines: [LyricLine]
    let seek: (TimeInterval) -> Void
    /// Written by the tracker, so only the rows whose position changed redraw as the song moves.
    @State private var currentIndex: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(lines.indices, id: \.self) { index in
                        MusicLyricRow(text: lines[index].text, position: position(of: index)) {
                            seek(lines[index].time)
                        }
                        .id(index)
                    }
                    MusicLyricsCredit()
                }
                .padding(.top, DesignTokens.Spacing.md)
            }
            .scrollIndicators(.never)
            .lyricsEdgeFade()
            .background {
                MusicLyricsPlayheadTracker(store: store, lines: lines, index: $currentIndex)
            }
            .animation(reduceMotion ? nil : DesignTokens.Animation.quick, value: currentIndex)
            .onChange(of: currentIndex) { old, new in
                // The first reading (the panel opens mid-song) jumps; later ones glide.
                let glide = old != nil && !reduceMotion
                withAnimation(glide ? .easeInOut(duration: 0.35) : nil) {
                    if let new {
                        proxy.scrollTo(new, anchor: .center)
                    } else {
                        proxy.scrollTo(0, anchor: .top)
                    }
                }
            }
        }
    }

    private func position(of index: Int) -> MusicLyricPosition {
        guard let currentIndex else { return .upcoming }
        if index == currentIndex { return .current }
        return index < currentIndex ? .past : .upcoming
    }
}

/// Finds the current line from the playhead. Between the player's half-second ticks it adds the wall-clock
/// time since the last one, ten times a second, but only while the panel is on screen and the song plays:
/// a paused or hidden panel schedules nothing and only re-reads when the playhead itself moves (a seek).
private struct MusicLyricsPlayheadTracker: View {
    let store: MusicLyricsStore
    let lines: [LyricLine]
    @Binding var index: Int?

    var body: some View {
        let playhead = store.playhead
        TimelineView(.animation(minimumInterval: 0.1, paused: !(store.isWatching && playhead.isPlaying))) { context in
            let found = LRCParser.currentIndex(in: lines, at: playhead.position(at: context.date))
            Color.clear
                .onChange(of: found, initial: true) { _, new in
                    if index != new { index = new }
                }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
