// Deci/Views/Music/MusicPlayerColumn.swift
import SwiftUI

/// The left column of the Music popup: what is playing and everything to control it, always on screen. A stack 142 pt
/// wide (kicker, cover, title and artist, the spectrum that is also the progress bar, the times, a strip with Like and
/// Dislike, the transport, the three words that open Lyrics, Related and Up next in the right column). Volume and
/// output live in the Mixer popover. It takes the song's colour (`musicAccent`) for its wash and for everything that is
/// on or played.
///
/// It stays whatever the right column shows. `service` and `navigation` are nil before the service exists; the column
/// then shows its empty layout.
struct MusicPlayerColumn: View {
    let service: MusicService?
    let navigation: MusicSearchNavigation?
    let spectrum: MusicSpectrumDriver
    /// The like animation the strip's Like or Dislike icon is playing; nil when there is none.
    let burst: MusicRateBurstCenter.Event?

    @Environment(\.musicAccent) private var accent
    @Environment(\.musicTrackMenu) private var trackMenu
    /// The popup stays mounted while hidden: its times are read only while it is on screen, so a closed popup is not
    /// redrawn at every tick of the player.
    @Environment(\.musicPopupIsVisible) private var isPopupVisible

    private var player: MusicPlayer? { service?.player }
    private var track: MusicTrack? { player?.nowPlaying }

    private var state: MusicPlayerColumnState {
        MusicPlayerColumnState.resolve(
            isSignedIn: service?.authState == .signedIn,
            hasTrack: track != nil,
            isLoading: player?.isLoading ?? false,
            isPlaying: player?.isPlaying ?? false
        )
    }

    var body: some View {
        let state = state
        VStack(alignment: .leading, spacing: MusicPopupMetrics.playerColumnSpacing) {
            kicker(state)
            cover(state)
            meta(state)
            // The spectrum takes whatever height is left, so the column is full top to bottom.
            spectrumBlock(state)
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.bottom, MusicPopupMetrics.timesToTransport - MusicPopupMetrics.playerColumnSpacing)
            transport(state)
                // Behind the transport, so its buttons keep their clicks where the icons' reach runs into them.
                .background(alignment: .top) {
                    rateStrip(state)
                        .alignmentGuide(.top) { $0[.bottom] + MusicPopupMetrics.rateStripLift }
                }
            viewButtons(state)
        }
        .padding(MusicPopupMetrics.playerColumnPadding)
        .frame(width: MusicPopupMetrics.playerColumnWidth, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background { panel(state) }
        // The accent glides to a new song's colour: the wash, the played bars, the lit buttons.
        .animation(.easeInOut(duration: 0.4), value: accent)
    }

    // MARK: - Background

    /// The column's near black, with the accent washing down from the top: 0.16 at the top to nothing at three quarters
    /// of the height (0.05 when nothing plays).
    private func panel(_ state: MusicPlayerColumnState) -> some View {
        ZStack {
            Rectangle().fill(MusicStyle.Palette.playerPanel)
            Rectangle()
                .fill(accent.solid.opacity(state.washOpacity))
                .mask(
                    LinearGradient(
                        colors: [.black, .clear],
                        startPoint: .top,
                        endPoint: UnitPoint(x: 0.5, y: 0.75)
                    )
                )
        }
    }

    // MARK: - Song

    private func kicker(_ state: MusicPlayerColumnState) -> some View {
        Text(state.kicker)
            .musicText(MusicStyle.Typeface.kicker)
            .foregroundStyle(Color.white.opacity(state.kickerOpacity))
            .lineLimit(1)
            .frame(height: 12, alignment: .leading)
    }

    @ViewBuilder
    private func cover(_ state: MusicPlayerColumnState) -> some View {
        let size = MusicPopupMetrics.playerColumnContentWidth
        if let track, !state.isEmptyLayout {
            MusicThumbnail(url: track.thumbnailURL, size: size, cornerRadius: 6)
                .opacity(state.coverOpacity)
                .contextMenu { trackActions(track) }
                .accessibilityHidden(true)
        } else {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                )
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: 30))
                        .foregroundStyle(Color.white.opacity(0.22))
                )
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func meta(_ state: MusicPlayerColumnState) -> some View {
        let width = MusicPopupMetrics.playerColumnContentWidth
        if state.isEmptyLayout {
            VStack(alignment: .leading, spacing: 3) {
                Text(state.emptyTitle)
                    .musicText(MusicStyle.Typeface.emptyTitle)
                    .foregroundStyle(Color.white.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                Text(state.emptySubtitle)
                    .musicText(MusicStyle.Typeface.secondary)
                    .foregroundStyle(Color.white.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: width, height: 67, alignment: .topLeading)
            .accessibilityElement(children: .combine)
        } else if let track {
            VStack(alignment: .leading, spacing: 2) {
                MusicMarquee(isPlaying: player?.isPlaying ?? false) {
                    Text(track.title)
                        .musicText(MusicStyle.Typeface.playerTitle)
                        .foregroundStyle(Color.white.opacity(0.97))
                        .lineLimit(1)
                }
                .help(track.title)
                .contextMenu { trackActions(track) }
                if let error = player?.error {
                    Text(error)
                        .musicText(MusicStyle.Typeface.secondary)
                        .foregroundStyle(Color.white.opacity(0.60))
                        .lineLimit(1)
                } else {
                    MusicMarquee(isPlaying: player?.isPlaying ?? false) {
                        MusicArtistLine(
                            artist: track.artist,
                            links: track.artistLinks,
                            font: MusicStyle.Typeface.secondary.font,
                            color: Color.white.opacity(0.60)
                        )
                    }
                }
            }
            .frame(width: width, height: 32, alignment: .topLeading)
        }
    }

    /// The song's actions, as the "..." menu of a row has them, on a right click: there is no button for them here.
    @ViewBuilder
    private func trackActions(_ track: MusicTrack) -> some View {
        if let trackMenu {
            MusicTrackMenuItems(
                actions: trackMenu.actions(track, .none),
                perform: { trackMenu.perform($0, track, .none) }
            )
        }
    }

    // MARK: - Spectrum

    private func spectrumBlock(_ state: MusicPlayerColumnState) -> some View {
        VStack(alignment: .leading, spacing: MusicPopupMetrics.spectrumBlockSpacing) {
            MusicSpectrumView(state: state, track: track, service: service, spectrum: spectrum)
            timesRow(state)
        }
    }

    /// Like and Dislike for the song playing now, as the Now playing card has them, in the strip over the transport. The
    /// strip's space is kept even when there is nothing to rate. A call that goes through shows in the icons, with the
    /// like animation on the one that turned on; one that does not shows in the popup's notice line. They fade and
    /// switch off with the transport.
    private func rateStrip(_ state: MusicPlayerColumnState) -> some View {
        let service = service
        return MusicRateStrip(
            isAvailable: service?.canRate == true,
            status: service?.likeStatus,
            burst: burst,
            onDislike: {
                guard let service else { return }
                Task { service.trackActions.postIfFailed(await service.dislike()) }
            },
            onLike: {
                guard let service else { return }
                Task { service.trackActions.postIfFailed(await service.toggleLike()) }
            }
        )
        .opacity(state.controlsOpacity)
        .disabled(!state.controlsAreEnabled)
    }

    /// The row under the spectrum. A song that plays reads "0:08 / 4:15" on the left and its view count on the right
    /// ("1.2M views"); loading shows the spinner and nothing on the right; with no song it is a dimmed "0:00 / 0:00".
    private func timesRow(_ state: MusicPlayerColumnState) -> some View {
        let duration = player?.duration ?? 0
        let total = duration > 0 ? duration : TimeInterval(track?.durationSeconds ?? 0)
        return HStack(spacing: 0) {
            switch state {
            case .loading:
                HStack(spacing: 5) {
                    MusicSpinner(size: 10, lineWidth: 1.2, color: Color.white.opacity(0.75), track: Color.white.opacity(0.15))
                    Text("Loading")
                        .musicText(MusicStyle.Typeface.columnLabel)
                        .foregroundStyle(Color.white.opacity(0.60))
                }
                Spacer(minLength: 0)
            case .playing, .paused:
                playbackTimes(
                    current: player?.readCurrentTime(observed: isPopupVisible) ?? 0, total: total, viewCount: player?.viewCount
                )
            case .signedOut, .empty:
                timePair(current: 0, total: 0, currentOpacity: 0.30, totalOpacity: 0.30)
                Spacer(minLength: 0)
            }
        }
        .frame(height: 13)
    }

    /// The times of a song that plays and its view count. The count gives way before the times do: the first of
    /// "1.2M views", "1.2M" and nothing that fits the column's width is the one shown.
    private func playbackTimes(current: TimeInterval, total: TimeInterval, viewCount: Int?) -> some View {
        let long = MusicViewCountFormat.label(viewCount)
        let short = viewCount.flatMap(MusicViewCountFormat.abbreviated)
        let full = MusicViewCountFormat.fullLabel(viewCount)
        return ViewThatFits(in: .horizontal) {
            playbackLine(current: current, total: total, views: long, tooltip: full)
            playbackLine(current: current, total: total, views: short, tooltip: full)
            playbackLine(current: current, total: total, views: nil, tooltip: nil)
        }
    }

    /// One candidate of the playing row. The times take the width first, so they never truncate.
    private func playbackLine(current: TimeInterval, total: TimeInterval, views: String?, tooltip: String?) -> some View {
        HStack(spacing: 0) {
            timePair(current: current, total: total, currentOpacity: 0.70, totalOpacity: 0.40)
                .layoutPriority(1)
            // A count comes with its gap, so the fit check counts the gap too.
            Spacer(minLength: views == nil ? 0 : MusicPopupMetrics.timesRowGap)
            if let views {
                mono(views, opacity: 0.40)
                    .lineLimit(1)
                    .help(tooltip ?? views)
            }
        }
    }

    /// "0:08 / 4:15": the position, then the length behind a slash, side by side.
    private func timePair(current: TimeInterval, total: TimeInterval, currentOpacity: Double, totalOpacity: Double) -> some View {
        HStack(spacing: 0) {
            time(current, opacity: currentOpacity)
            mono(" / " + MusicTimeFormat.string(total), opacity: totalOpacity)
        }
    }

    private func time(_ seconds: TimeInterval, opacity: Double) -> some View {
        mono(MusicTimeFormat.string(seconds), opacity: opacity)
    }

    /// The row's one font: 10 pt monospaced, so a column of times and counts keeps its width as the digits change.
    private func mono(_ text: String, opacity: Double) -> some View {
        Text(text)
            .font(.system(size: 10, design: .monospaced))
            .monospacedDigit()
            .foregroundStyle(Color.white.opacity(opacity))
    }

    // MARK: - Transport

    private func transport(_ state: MusicPlayerColumnState) -> some View {
        let service = service
        let canGoNext = service?.canGoNext ?? false
        let isShuffleOn = service?.isShuffleOn ?? false
        let loopMode = service?.loopMode ?? .off
        let rest = MusicTransportMetrics.restingGlyphOpacity
        return HStack(spacing: 0) {
            MusicColumnGlyphButton(
                title: "Shuffle", systemImage: "shuffle", fontSize: 12, box: MusicTransportMetrics.box(.shuffle),
                color: isShuffleOn ? accent.solid : Color.white.opacity(rest), isSelected: isShuffleOn
            ) { service?.setShuffle(!isShuffleOn) }
            Spacer(minLength: 0)
            MusicColumnGlyphButton(
                title: "Previous", systemImage: "backward.end.fill", fontSize: 14,
                box: MusicTransportMetrics.box(.previous), color: Color.white.opacity(0.90)
            ) { service?.previous() }
            Spacer(minLength: 0)
            playPause(state)
            Spacer(minLength: 0)
            MusicColumnGlyphButton(
                title: "Next", systemImage: "forward.end.fill", fontSize: 14, box: MusicTransportMetrics.box(.next),
                color: Color.white.opacity(canGoNext ? 0.90 : 0.30), isDisabled: !canGoNext
            ) { service?.next() }
            Spacer(minLength: 0)
            MusicColumnGlyphButton(
                title: loopMode.label, systemImage: loopMode.systemImage, fontSize: 12,
                box: MusicTransportMetrics.box(.loop),
                color: loopMode != .off ? accent.solid : Color.white.opacity(rest), isSelected: loopMode != .off
            ) { service?.cycleLoopMode() }
        }
        .frame(width: MusicPopupMetrics.playerColumnContentWidth, height: MusicTransportMetrics.height)
        .opacity(state.controlsOpacity)
        .disabled(!state.controlsAreEnabled)
    }

    private func playPause(_ state: MusicPlayerColumnState) -> some View {
        let isPlaying = state == .playing
        return Button {
            service?.togglePlayback()
        } label: {
            ZStack {
                Circle().fill(Color.white.opacity(0.95))
                if state == .loading {
                    MusicSpinner(
                        size: 16, lineWidth: 1.6,
                        color: MusicStyle.Palette.popupBackground,
                        track: MusicStyle.Palette.popupBackground.opacity(0.18)
                    )
                } else {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(MusicStyle.Palette.popupBackground)
                }
            }
            .frame(width: MusicTransportMetrics.box(.playPause), height: MusicTransportMetrics.height)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(state == .loading)
        .accessibilityLabel(state == .loading ? "Loading" : (isPlaying ? "Pause" : "Play"))
        .help(isPlaying ? "Pause" : "Play")
    }

    // MARK: - Views

    /// Lyrics, Related and Up next as words in one row: Lyrics on the left edge of the column, Up next on the right
    /// edge, Related between them, with the two spaces taking the same width (`MusicViewButtons`). Each button dims
    /// and turns off on its own (`MusicViewButtons.isAvailable`), not the row: an open Related panel's button stays
    /// live when nothing plays.
    private func viewButtons(_ state: MusicPlayerColumnState) -> some View {
        let hasLyrics = service?.lyrics.track != nil
        let hasSong = track != nil
        let hasQueue = !(service?.queue.isEmpty ?? true)
        let relatedIsOpen = navigation?.showsRelated ?? false
        func available(_ kind: MusicViewButtons.Kind) -> Bool {
            MusicViewButtons.isAvailable(
                kind, controlsAreEnabled: state.controlsAreEnabled, hasLyrics: hasLyrics, hasSong: hasSong,
                hasQueue: hasQueue, relatedIsOpen: relatedIsOpen
            )
        }
        return HStack(spacing: 0) {
            MusicColumnViewButton(
                title: MusicViewButtons.Kind.lyrics.title,
                isActive: navigation?.showsLyrics ?? false, isAvailable: available(.lyrics)
            ) { navigation?.toggleLyrics() }
            Spacer(minLength: 0)
            MusicColumnViewButton(
                title: MusicViewButtons.Kind.related.title,
                isActive: relatedIsOpen, isAvailable: available(.related)
            ) { navigation?.toggleRelated() }
            Spacer(minLength: 0)
            MusicColumnViewButton(
                title: MusicViewButtons.Kind.queue.title,
                isActive: navigation?.showsQueue ?? false, isAvailable: available(.queue)
            ) { navigation?.toggleQueue() }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 12)
    }
}

/// One glyph of the transport, bare. Its hit area reaches past the glyph (the glyphs are small and spaced apart) and
/// stays out of the layout.
private struct MusicColumnGlyphButton: View {
    let title: String
    let systemImage: String
    let fontSize: CGFloat
    /// The width the design draws the glyph in.
    let box: CGFloat
    let color: Color
    var isSelected = false
    var isDisabled = false
    let action: () -> Void

    private static let reach: CGFloat = 6

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: fontSize, weight: .medium))
                .foregroundStyle(color)
                .frame(width: box, height: MusicTransportMetrics.height)
                .padding(.horizontal, Self.reach)
                .contentShape(Rectangle())
                .padding(.horizontal, -Self.reach)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help(title)
    }
}

/// Lyrics, Related or Up next: a word in the accent while that view is open on the right. Pressing it then goes back to
/// browse. With nothing to show (no lyrics for the song, no song, an empty queue) it stays and dims.
private struct MusicColumnViewButton: View {
    let title: String
    let isActive: Bool
    let isAvailable: Bool
    let action: () -> Void

    @Environment(\.musicAccent) private var accent

    var body: some View {
        Button(action: action) {
            Text(title)
                .musicText(MusicStyle.Typeface.columnLabel)
                .foregroundStyle(isActive ? accent.solid : Color.white.opacity(0.75))
                .lineLimit(1)
                .fixedSize()
                .padding(.vertical, 6)
                .contentShape(Rectangle())
                .padding(.vertical, -6)
        }
        .buttonStyle(.plain)
        .opacity(isAvailable ? 1 : 0.30)
        .disabled(!isAvailable)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .help(title)
    }
}
