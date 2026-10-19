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
        case .failed(let message, let retryAfter):
            if let retryAfter {
                MusicLyricsWaitView(message: message, until: retryAfter) { store.retry() }
            } else {
                MusicFailedView(message: message) { store.retry() }
            }
        case .busy(let until):
            MusicLyricsWaitView(message: MusicLyricsStore.busyMessage, until: until) { store.retry() }
        case .loaded(.synced(let lines)):
            // Keyed on the track, so a direct change from one synced song to the next starts a fresh list (follow
            // state, scroll position and current line) instead of carrying the last song's over.
            MusicSyncedLyricsList(store: store, lines: lines, credit: store.credit, seek: seek)
                .id(store.track?.videoId)
        case .loaded(.plain(let text)):
            MusicPlainLyricsView(text: text, credit: store.credit)
        case .loaded(.instrumental):
            MusicEmptyView(text: "Instrumental")
        case .loaded(.notFound):
            MusicEmptyView(text: "No lyrics for this song.")
        }
    }
}

/// A lyrics source asked us to wait (busy, or a server error that opened a short window): the message shows, and Retry
/// appears once the window has passed. Until then nothing is sent. There is no ticking clock: one timeline entry
/// just after the end of the window redraws the view once, and a window that is already over shows Retry at once.
private struct MusicLyricsWaitView: View {
    let message: String
    let until: Date
    let retry: () -> Void

    var body: some View {
        if until <= Date() {
            content(canRetry: true)
        } else {
            TimelineView(.explicit([until.addingTimeInterval(0.25)])) { _ in
                content(canRetry: Date() >= until)
            }
        }
    }

    private func content(canRetry: Bool) -> some View {
        VStack(spacing: DesignTokens.Spacing.sm) {
            Text(message)
                .font(DesignTokens.Typography.rowDescription)
                .foregroundStyle(DesignTokens.Colors.textSecondary)
                .multilineTextAlignment(.center)
            if canRetry {
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

/// The line under the lyrics that says where they came from, as the lyrics source worded it ("Lyrics from LRCLIB").
/// Nothing at all when the source named no one.
private struct MusicLyricsCredit: View {
    let text: String?

    var body: some View {
        if let text {
            Text(text)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Colors.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DesignTokens.Spacing.sm)
                .padding(.vertical, DesignTokens.Spacing.md)
        }
    }
}

/// Lyrics with no timing: text to read, marked as not synced. The font of the synced lines, in the colour of sung ones.
private struct MusicPlainLyricsView: View {
    let text: String
    let credit: String?

    private let style = MusicLyricRowStyle(position: .past)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                Text("Not synced")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
                Text(text)
                    .font(style.font)
                    .lineSpacing(MusicLyricRowStyle.lineSpacing)
                    .foregroundStyle(style.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
                MusicLyricsCredit(text: credit)
                    .padding(.horizontal, -DesignTokens.Spacing.sm)
            }
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .padding(.top, DesignTokens.Spacing.md)
        }
        .scrollIndicators(.never)
        .lyricsEdgeFade()
    }
}

/// One timed line. Equatable on what it shows, so when the list redraws as the song moves only the rows whose position
/// changed redraw: the closure is left out of the comparison, and `time` is in it so a row that now seeks somewhere
/// else is never left holding the old closure. A row's own hover is its own state and redraws only that row.
private struct MusicLyricRow: View, Equatable {
    let text: String
    let time: TimeInterval
    let position: MusicLyricPosition
    let reduceMotion: Bool
    let select: () -> Void

    @State private var isHovered = false

    static func == (lhs: MusicLyricRow, rhs: MusicLyricRow) -> Bool {
        lhs.text == rhs.text && lhs.time == rhs.time && lhs.position == rhs.position && lhs.reduceMotion == rhs.reduceMotion
    }

    var body: some View {
        let style = MusicLyricRowStyle(position: position, isHovered: isHovered)
        Button(action: select) {
            Text(MusicLyricRowStyle.shownText(text))
                .font(style.font)
                .lineSpacing(MusicLyricRowStyle.lineSpacing)
                .foregroundStyle(style.color)
                // The one thing on a row that animates: its colour, on its own short fade, so it is never tangled
                // with the scroll. Nothing here changes the layout, so the list does not shift under the glide.
                .animation(reduceMotion ? nil : .easeOut(duration: MusicLyricRowStyle.colorFadeDuration), value: style.opacity)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DesignTokens.Spacing.sm)
                .padding(.vertical, MusicLyricRowStyle.verticalPadding)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .onHover { isHovered = $0 }
        .accessibilityLabel(MusicLyricRowStyle.spokenText(text))
        .accessibilityAddTraits(position == .current ? .isSelected : [])
    }
}

/// Timed lines with the current one lit and kept a third of the way down the panel. The list glides to each new line
/// on one long smooth curve. A scroll by hand pauses that (the highlight still moves); 3 seconds after the user's
/// scroll goes idle the list glides back, and a tap on a line seeks there and follows again at once.
private struct MusicSyncedLyricsList: View {
    let store: MusicLyricsStore
    let lines: [LyricLine]
    let credit: String?
    let seek: (TimeInterval) -> Void
    /// Set from the tracker's readings, so only the rows whose position changed redraw as the song moves.
    @State private var currentIndex: Int?
    @State private var scrollPosition = ScrollPosition(idType: Int.self)
    @State private var follow = LyricsFollowState()
    /// False until the list has been put on a line: the first reading jumps there, later ones glide.
    @State private var hasPositioned = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            // A plain stack: lyrics are a few dozen lines, and a lazy one re-measures rows as they scroll in. The
            // spacers at both ends are the part of the visible height above and below the anchor, so the first
            // and the last line can reach it too instead of stopping where the scroll runs out.
            VStack(spacing: 0) {
                Color.clear
                    .containerRelativeFrame(.vertical) { height, _ in height * MusicLyricScroll.anchorFraction }
                ForEach(lines.indices, id: \.self) { index in
                    MusicLyricRow(
                        text: lines[index].text,
                        time: lines[index].time,
                        position: MusicLyricRowStyle.position(of: index, current: currentIndex),
                        reduceMotion: reduceMotion
                    ) {
                        select(index)
                    }
                    .equatable()
                    .id(index)
                }
                MusicLyricsCredit(text: credit)
                Color.clear
                    .containerRelativeFrame(.vertical) { height, _ in height * (1 - MusicLyricScroll.anchorFraction) }
            }
            .scrollTargetLayout()
        }
        // The anchor goes on the modifier: an anchor passed to `ScrollPosition.scrollTo(id:)` had no effect when tried,
        // and without one a line lands on the nearest edge instead of a third of the way down.
        .scrollPosition($scrollPosition, anchor: MusicLyricScroll.anchor)
        .scrollIndicators(.never)
        .lyricsEdgeFade()
        .background {
            MusicLyricsPlayheadTracker(store: store, lines: lines, report: reading)
        }
        .accessibilityHint("Select a line to jump to it in the song")
        .onScrollPhaseChange { _, phase in
            follow.scrollPhaseChanged(LyricsScrollPhase(phase))
        }
        .onChange(of: currentIndex) { _, new in
            // Left where the user scrolled it: the highlight moves, the list stays until following resumes.
            guard follow.isFollowing else { return }
            // The first line the list is put on (the panel opens mid-song) is a jump; later ones glide.
            scroll(to: new, animated: hasPositioned)
            hasPositioned = true
        }
        .onChange(of: store.isWatching) { _, watching in
            // The popup stays mounted while hidden, so a scroll the user was in the middle of when it hid may never
            // report its idle. Nothing is scrolling when it shows again: follow, and put the list on the line the
            // song is at (the playhead has just been re-read, so a change of line also arrives on its own).
            guard watching else { return }
            follow.resume()
            scroll(to: currentIndex, animated: false)
        }
        .task(id: follow.resumeAt) {
            // One wait per `resumeAt`: a new user scroll changes it, which cancels this task and starts over.
            while let due = follow.resumeAt {
                try? await Task.sleep(for: .seconds(max(0.05, due.timeIntervalSinceNow)))
                guard !Task.isCancelled else { return }
                if follow.resumeIfDue() {
                    scroll(to: currentIndex, animated: true)
                    return
                }
            }
        }
    }

    /// What the tracker read: the current line, once at the start and again whenever it changes.
    private func reading(_ new: Int?) {
        if currentIndex != new { currentIndex = new }
        // The list starts at the top, so a first reading of no line yet needs no move: the line that starts first
        // is reached by a glide from there, like any later one.
        if new == nil { hasPositioned = true }
    }

    /// A tap seeks to the line and follows again at once, heading for the tapped line, which is about to be current.
    private func select(_ index: Int) {
        seek(lines[index].time)
        follow.resume()
        scroll(to: index, animated: true)
    }

    /// Puts a line at the anchor (the top when no line has started yet): a glide, or a jump when `animated` is
    /// false or Reduce Motion is on.
    private func scroll(to index: Int?, animated: Bool) {
        withAnimation(animated && !reduceMotion ? MusicLyricScroll.glide : nil) {
            if let index {
                scrollPosition.scrollTo(id: index)
            } else {
                scrollPosition.scrollTo(edge: .top)
            }
        }
    }
}

private extension LyricsScrollPhase {
    /// SwiftUI's scroll phase, one to one.
    init(_ phase: ScrollPhase) {
        switch phase {
        case .idle: self = .idle
        case .tracking: self = .tracking
        case .interacting: self = .interacting
        case .decelerating: self = .decelerating
        case .animating: self = .animating
        }
    }
}

/// Finds the current line from the playhead. Between the player's half-second ticks it adds the wall-clock
/// time since the last one, ten times a second, but only while the panel is on screen and the song plays:
/// a paused or hidden panel schedules nothing and only re-reads when the playhead itself moves (a seek).
private struct MusicLyricsPlayheadTracker: View {
    let store: MusicLyricsStore
    let lines: [LyricLine]
    /// Told the line at the start and each time it changes (nil before the first line begins).
    let report: (Int?) -> Void

    var body: some View {
        let playhead = store.playhead
        TimelineView(.animation(minimumInterval: 0.1, paused: !(store.isWatching && playhead.isPlaying))) { context in
            let found = LRCParser.currentIndex(in: lines, at: playhead.position(at: context.date))
            Color.clear
                .onChange(of: found, initial: true) { _, new in report(new) }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
