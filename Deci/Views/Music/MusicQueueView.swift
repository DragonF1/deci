// Deci/Views/Music/MusicQueueView.swift
import SwiftUI

/// The middle of the Up next screen: its title and the Autoplay chip, the song in the player on an accent row, and under
/// "Playing Next" the songs that follow, in a list that scrolls. A tap on a song plays it.
struct MusicQueueView: View {
    let service: MusicService

    var body: some View {
        let listing = MusicQueueListing(queue: service.queue)
        VStack(spacing: 0) {
            titleRow
                .padding(.top, 16)

            if let current = listing.current {
                MusicQueueCurrentRow(track: current, isPlaying: service.player.isPlaying) {
                    service.jump(to: current)
                }
                .padding(.top, 10)
            }

            header(sourceLine: listing.sourceLine)
                .padding(.top, 6)

            upcoming(listing.upcoming)
                .padding(.top, 11)
        }
    }

    // MARK: - Title

    private var titleRow: some View {
        HStack(spacing: 0) {
            Text("Up next")
                .musicText(MusicStyle.Typeface.headline)
                .foregroundStyle(.white)
            Spacer(minLength: 8)
            // The play order and the loop, beside Autoplay: the same buttons, states and loop cycle as Now Playing.
            HStack(spacing: 4) {
                MusicShuffleButton(service: service)
                MusicLoopButton(service: service)
            }
            .padding(.trailing, 8)
            MusicAutoplayChip(isOn: service.isAutoplayOn) {
                service.setAutoplay(!service.isAutoplayOn)
            }
        }
        .frame(height: MusicAutoplayChip.height)
        .padding(.horizontal, MusicStyle.Spacing.page)
    }

    private func header(sourceLine: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Playing Next")
                .musicText(MusicStyle.Typeface.headline)
                .foregroundStyle(.white)
            if let sourceLine {
                Text(sourceLine)
                    .musicText(MusicStyle.Typeface.caption12)
                    .foregroundStyle(MusicStyle.Palette.textSecondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, MusicStyle.Spacing.page)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: - The list

    @ViewBuilder
    private func upcoming(_ tracks: [MusicTrack]) -> some View {
        if tracks.isEmpty {
            MusicStateCard(message: "No more songs queued.", minHeight: 60)
                .frame(maxHeight: .infinity, alignment: .top)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(tracks) { track in
                        MusicSongRow(track: track, isCurrent: false, isPlaying: false, layout: .playlist) {
                            service.jump(to: track)
                        }
                    }
                }
                .padding(.bottom, Self.fadeHeight)
            }
            .scrollIndicators(.never)
            .mask(bottomFade)
        }
    }

    /// The last rows dissolve into the controls under the list.
    private static let fadeHeight: CGFloat = 24

    private var bottomFade: some View {
        VStack(spacing: 0) {
            Rectangle().fill(.black)
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: Self.fadeHeight)
        }
    }
}

/// The Autoplay chip: when a playlist or an album ends, recommended songs carry on. Lit in the accent colour while on.
struct MusicAutoplayChip: View {
    let isOn: Bool
    let action: () -> Void

    static let height: CGFloat = 36

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "infinity")
                    .font(.system(size: 18))
                Text("Autoplay")
                    .musicText(MusicStyle.Typeface.callout)
            }
            .foregroundStyle(isOn ? MusicStyle.Palette.accent : Color.white)
            .padding(.leading, 12)
            .padding(.trailing, 14)
            .frame(height: Self.height)
            .background(Capsule().fill(isOn ? MusicStyle.Palette.accentFill : MusicStyle.Palette.fillControl2))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .help("Keep playing recommended songs after a playlist or an album ends")
    }
}

/// The song in the player, at the top of Up next: the accent row, with the waveform that moves while it plays. A tap
/// starts it over; the right click menu is the song's own.
private struct MusicQueueCurrentRow: View {
    let track: MusicTrack
    let isPlaying: Bool
    let action: () -> Void

    /// Set while Full Keyboard Access has put keyboard focus on the row.
    @FocusState private var isKeyboardFocused: Bool
    @Environment(\.musicTrackMenu) private var menu
    @Environment(\.musicTrackContext) private var context

    private var accent: Color { MusicStyle.Palette.accent }

    var body: some View {
        let actions = menu?.actions(track, context) ?? []
        HStack(spacing: 12) {
            MusicThumbnail(url: track.thumbnailURL, size: 40, cornerRadius: MusicStyle.Radius.small)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(track.title)
                    .musicText(MusicStyle.Typeface.row15)
                    .foregroundStyle(accent)
                    .lineLimit(1)
                    .accessibilityHidden(true)
                subtitle
            }
            Spacer(minLength: 8)
            Image(systemName: "waveform")
                .font(.system(size: 18))
                .foregroundStyle(accent)
                .symbolEffect(.variableColor.iterative, options: .repeating, isActive: isPlaying)
                .accessibilityHidden(true)
        }
        .padding(.leading, 6)
        .padding(.trailing, 10)
        .frame(height: 52)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(MusicStyle.Palette.accentRow))
        .padding(.horizontal, MusicStyle.Spacing.page)
        .contentShape(Rectangle())
        .contextMenu {
            MusicTrackMenuItems(actions: actions) { menu?.perform($0, track, context) }
        }
        .onTapGesture(perform: action)
        // Reachable with Full Keyboard Access only, and Space or Return plays, like a song row. A key goes to the row
        // only while it has focus, so typing in the search field never reaches it.
        .focusable(interactions: .activate)
        .focused($isKeyboardFocused)
        .onKeyPress(keys: [.space, .return], phases: .down) { _ in
            action()
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(track.title), \(track.artist), \(isPlaying ? "playing" : "paused")")
        .accessibilityAddTraits(.isSelected)
        .accessibilityAction(.default, action)
        .accessibilityActions {
            ForEach(actions, id: \.self) { item in
                Button(item.title) { menu?.perform(item, track, context) }
            }
        }
    }

    /// "artist · album" in the accent colour at three quarters; the artist names stay links.
    private var subtitle: some View {
        HStack(spacing: 0) {
            MusicArtistLine(
                artist: track.artist,
                links: track.artistLinks,
                hidesPlainTextFromVoiceOver: true,
                font: MusicStyle.Typeface.caption12.font,
                color: accent.opacity(0.75)
            )
            .layoutPriority(1)
            if let album = track.album, !album.isEmpty {
                Text(" \u{00B7} " + album)
                    .musicText(MusicStyle.Typeface.caption12)
                    .foregroundStyle(accent.opacity(0.75))
                    .lineLimit(1)
                    .accessibilityHidden(true)
            }
        }
    }
}
