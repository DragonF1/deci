// Deci/Views/Music/MusicLyricsView.swift
import SwiftUI

/// The lyrics panel of the right column, under its own header (`MusicLyricsHeader`): the lines (or the card that says why
/// there are none) and, at the foot, a kicker that says what they are and where they came from. Synced lyrics scroll with
/// the song and a tap on a line jumps there; plain lyrics are paragraphs of text.
struct MusicLyricsView: View {
    let store: MusicLyricsStore
    /// Jumps the song to a time in seconds.
    let seek: (TimeInterval) -> Void

    @Environment(\.musicBottomInset) private var bottomInset

    /// The margin of the lines, the foot and the state cards; the lines' own 8 pt row padding makes up the rest.
    static let margin: CGFloat = MusicPopupMetrics.lyricsPaddingSide
    private static let linesInset: CGFloat = margin - 8

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, MusicPopupMetrics.lyricsPaddingTop)

            MusicLyricsFooter(kicker: MusicLyricsCaption.footer(for: store.state), credit: creditText)
                .padding(.horizontal, Self.margin)
                .padding(.top, 8)
                .padding(.bottom, bottomInset)
        }
    }

    /// The source line shows under lyrics that are on screen, never under a state card.
    private var creditText: String? {
        switch store.state {
        case .loaded(.synced), .loaded(.plain): store.credit
        default: nil
        }
    }

    @ViewBuilder
    private var content: some View {
        switch store.state {
        case .idle:
            if store.track == nil {
                MusicStateCard(message: "Play a song to see its lyrics.", minHeight: 60, margin: Self.margin)
            } else {
                loading
            }
        case .loading:
            loading
        case .failed(let message, let retryAfter):
            if let retryAfter {
                MusicLyricsWaitView(message: message, until: retryAfter) { store.retry() }
            } else {
                MusicLyricsWaitView(message: message, until: .distantPast) { store.retry() }
            }
        case .busy(let until):
            MusicLyricsWaitView(message: MusicLyricsStore.busyMessage, until: until) { store.retry() }
        case .loaded(.synced(let lines)):
            // Keyed on the track, so a direct change from one synced song to the next starts a fresh list (follow
            // state, scroll position and current line) instead of carrying the last song's over.
            MusicSyncedLyricsList(store: store, lines: lines, seek: seek)
                .padding(.horizontal, Self.linesInset)
                .id(store.track?.videoId)
        case .loaded(.plain(let text)):
            MusicPlainLyricsView(text: text)
                .padding(.horizontal, Self.linesInset)
        case .loaded(.instrumental):
            MusicStateCard(margin: Self.margin) {
                HStack(spacing: 8) {
                    Image(systemName: "music.note")
                        .font(.system(size: 13))
                        .foregroundStyle(MusicStyle.Palette.textSub)
                        .accessibilityHidden(true)
                    MusicStateCardMessage(text: "Instrumental")
                }
            }
        case .loaded(.notFound):
            MusicStateCard(message: "No lyrics for this song.", margin: Self.margin)
        }
    }

    private var loading: some View {
        MusicStateCard(margin: Self.margin) {
            MusicSpinner()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading")
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
        MusicStateCard(minHeight: 88, margin: MusicLyricsView.margin) {
            MusicStateCardMessage(text: message)
            if canRetry {
                MusicRetryPill(action: retry)
            }
        }
    }
}

private extension View {
    /// Fades the top and the bottom of a scrolling list, so a line cut by the edge does not look clipped: clear at the
    /// edges, opaque from 16 to 82 percent of the height.
    func lyricsEdgeFade() -> some View {
        mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.16),
                    .init(color: .black, location: 0.82),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
}

/// The foot of the panel: a small kicker that says what the lyrics are ("SYNCED LYRICS") and, at the other end, where
/// they came from as the lyrics source worded it ("Lyrics from LRCLIB"). It keeps its height when there is neither, so
/// the lines above do not move.
private struct MusicLyricsFooter: View {
    let kicker: String?
    let credit: String?

    var body: some View {
        HStack(spacing: 8) {
            Text(kicker ?? "")
                .musicText(MusicStyle.Typeface.kicker)
                .foregroundStyle(Color.white.opacity(0.35))
                .lineLimit(1)
                .fixedSize()
            Spacer(minLength: 0)
            Text(credit ?? "")
                .musicText(MusicStyle.Typeface.caption)
                .foregroundStyle(MusicStyle.Palette.textTertiary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, minHeight: 12)
    }
}

/// Lyrics with no timing: paragraphs to read, 14 pt regular and quiet, with no current line. The header's "Not synced"
/// tag and the foot's "PLAIN LYRICS" say they are not synced. The top and the bottom dissolve a short way, so a paragraph
/// cut by an edge does not look clipped, and the first lines are clear at rest.
private struct MusicPlainLyricsView: View {
    private let stanzas: [String]

    init(text: String) {
        stanzas = MusicLyricsCaption.stanzas(of: text)
    }

    private static let topFade: CGFloat = 12
    private static let bottomFade: CGFloat = 24

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(stanzas.enumerated()), id: \.offset) { _, stanza in
                    Text(stanza)
                        .font(.system(size: 14))
                        .lineSpacing(5)
                        .foregroundStyle(Color.white.opacity(0.82))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .padding(.top, 14)
            .padding(.bottom, Self.bottomFade)
        }
        .scrollIndicators(.never)
        .mask(
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: Self.topFade)
                Rectangle().fill(.black)
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: Self.bottomFade)
            }
        )
    }
}

/// One timed line. Equatable on what it shows, so when the list redraws as the song moves only the rows whose position
/// changed redraw: the closure is left out of the comparison, and `time` is in it so a row that now seeks somewhere
/// else is never left holding the old closure. A row's own hover is its own state and redraws only that row.
///
/// The current row also fills as it is sung: `fill` is its word timing, and while the song plays a timeline redraws just
/// this row's text every frame with each character at the brightness the clock gives it. Every other row has no fill,
/// so it reads nothing that changes and never redraws for the clock. All rows have the same structure, so a row that
/// becomes the current one (or stops being it) keeps its colour fade.
private struct MusicLyricRow: View, Equatable {
    let text: String
    let time: TimeInterval
    let position: MusicLyricPosition
    /// How many lines ahead of the current one this row is (0 for a sung or the current row): where it sits in the fade.
    let ahead: Int
    let reduceMotion: Bool
    /// How the line fills while it is sung. Nil for every row but the current one, and for a current line that has no
    /// time to sing in (it is simply lit).
    let fill: LyricFill.Timing?
    let store: MusicLyricsStore
    let select: () -> Void

    @State private var isHovered = false

    static func == (lhs: MusicLyricRow, rhs: MusicLyricRow) -> Bool {
        lhs.text == rhs.text && lhs.time == rhs.time && lhs.position == rhs.position && lhs.ahead == rhs.ahead
            && lhs.reduceMotion == rhs.reduceMotion && lhs.fill == rhs.fill
    }

    /// The fill runs while the song plays and the panel is on screen; paused or hidden it holds one frame, and a seek
    /// redraws it (`MusicLyricsStore.animates`). Short-circuits, so a row with no fill reads nothing from the store.
    private var isFilling: Bool {
        fill != nil && store.animates
    }

    var body: some View {
        let style = MusicLyricRowStyle(position: position, isHovered: isHovered, ahead: ahead)
        Button(action: select) {
            TimelineView(.animation(paused: !isFilling)) { context in
                Text(shown(at: context.date))
                    .font(style.font)
                    .lineSpacing(MusicLyricRowStyle.lineSpacing)
                    .foregroundStyle(style.color)
                    // The one thing on a row that animates apart from the fill: its colour, on its own short fade, so
                    // it is never tangled with the scroll. Nothing here changes the layout, so the list does not
                    // shift under the glide.
                    .animation(reduceMotion ? nil : .easeOut(duration: MusicLyricRowStyle.colorFadeDuration), value: style.opacity)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
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

    /// The row's text at `date`: the plain line, or the line filled as far as the clock says. The fill reads the clock a
    /// line's lead ahead, to match the moment the line itself lit up. Colour only: the characters never change.
    private func shown(at date: Date) -> AttributedString {
        let line = MusicLyricRowStyle.shownText(text)
        guard let fill else { return AttributedString(line) }
        let clock = store.position(at: date) + MusicLyricScroll.lineLead
        return MusicLyricRowStyle.filledText(line, sweep: fill.sweep(at: clock))
    }
}

/// Timed lines with the current one lit and kept a third of the way down the panel. The list glides to each new line
/// on one long smooth curve (the real scroll view is animated: see `LyricsScrollDriver`). A scroll by hand stops a glide
/// where it is and pauses following (the highlight still moves); 3 seconds after the user's scroll goes idle the list
/// glides back, and a tap on a line seeks there and follows again at once.
private struct MusicSyncedLyricsList: View {
    let store: MusicLyricsStore
    let lines: [LyricLine]
    let seek: (TimeInterval) -> Void
    /// Set from the tracker's readings, so only the rows whose position changed redraw as the song moves.
    @State private var currentIndex: Int?
    @State private var scrollPosition = ScrollPosition(idType: Int.self)
    @State private var follow = LyricsFollowState()
    /// Finds the real scroll view, and moves it. Not observed: it never redraws the list.
    @State private var driver = LyricsScrollDriver()
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
                        ahead: MusicLyricRowStyle.ahead(of: index, current: currentIndex),
                        reduceMotion: reduceMotion,
                        fill: index == currentIndex ? fillTiming(of: index) : nil,
                        store: store
                    ) {
                        select(index)
                    }
                    .equatable()
                    .id(index)
                    .lyricsRowFrame(index, to: driver)
                }
                Color.clear
                    .containerRelativeFrame(.vertical) { height, _ in height * (1 - MusicLyricScroll.anchorFraction) }
            }
            .scrollTargetLayout()
            .lyricsScrollDriven(by: driver)
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
        .onAppear {
            // The glide is the list's own: while it runs, the scroll view's reports are not the user's. The driver
            // keeps this closure, so it holds the follow state's binding and never `self`: `self` owns the driver (the
            // `@State`), and a closure back to it would keep the list, the driver and its event monitor alive for good.
            let follow = $follow
            driver.glideChanged = { gliding in
                if gliding {
                    follow.wrappedValue.glideStarted()
                } else {
                    follow.wrappedValue.glideEnded()
                }
            }
        }
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

    /// The fill timing of line `index`: its own word times if the source gave them, else an estimate from where it
    /// starts and where the next line does.
    private func fillTiming(of index: Int) -> LyricFill.Timing? {
        let next = index + 1 < lines.count ? lines[index + 1].time : nil
        return LyricFill.timing(for: lines[index], nextStart: next)
    }

    /// Puts a line at the anchor (the top when no line has started yet): a glide, or a jump when `animated` is
    /// false or Reduce Motion is on. The real scroll view does it; SwiftUI's own scroll to a row is the fallback for
    /// when that cannot (no scroll view found yet, or the row's frame not reported yet), and it jumps on macOS.
    private func scroll(to index: Int?, animated: Bool) {
        let glide = animated && !reduceMotion
        if driver.scroll(toRow: index, animated: glide) { return }
        withAnimation(glide ? MusicLyricScroll.glide : nil) {
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

/// Finds the current line from the player's clock, a tenth of a second ahead. Every frame while the panel is on screen
/// and the song plays, from the engine's own clock (the player's ticks come only twice a second); a paused or hidden panel
/// schedules nothing and only re-reads when the playhead itself moves (a seek). Nothing is written for a frame: the
/// list is told only when the line changes.
private struct MusicLyricsPlayheadTracker: View {
    let store: MusicLyricsStore
    let lines: [LyricLine]
    /// Told the line at the start and each time it changes (nil before the first line begins).
    let report: (Int?) -> Void

    var body: some View {
        TimelineView(.animation(paused: !store.animates)) { context in
            let found = LRCParser.currentIndex(
                in: lines, at: store.position(at: context.date), lead: MusicLyricScroll.lineLead
            )
            Color.clear
                .onChange(of: found, initial: true) { _, new in report(new) }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
