// Deci/Views/Music/MusicQueueView.swift
import SwiftUI

/// The body of the Up next panel, under its header (`MusicQueueHeader`): a line that says what Shuffle, Loop and Autoplay
/// are set to, the song in the player, and under "NEXT IN QUEUE" the songs that follow, in a list that scrolls. A tap on
/// a song plays it. The header's field filters the songs that follow, live: the song in the player stays put, the label
/// counts the matches, the words are tinted and the end of the list says how to get the whole queue back.
struct MusicQueueView: View {
    let service: MusicService
    let navigation: MusicSearchNavigation

    var body: some View {
        let listing = MusicQueueListing(queue: service.queue)
        let terms = navigation.queueFilterTerms
        let matches = terms.isEmpty
            ? Array(listing.upcoming.indices)
            : MusicLocalSearch.indices(of: listing.upcoming, terms: terms)
        VStack(alignment: .leading, spacing: 10) {
            // The three toggles it describes leave the header while the field is open, and the line goes with them.
            if !navigation.isQueueFieldOpen {
                Text(MusicPlaybackStatus.text(shuffle: service.isShuffleOn, loop: service.loopMode, autoplay: service.isAutoplayOn))
                    .musicText(MusicStyle.Typeface.secondary)
                    .foregroundStyle(MusicStyle.Palette.textMeta)
                    .lineLimit(1)
                    .padding(.horizontal, MusicStyle.Spacing.page)
            }

            if let current = listing.current {
                VStack(alignment: .leading, spacing: 6) {
                    MusicQueueKicker(text: MusicQueueListing.nowPlayingKicker(sourceLine: listing.sourceLine))
                    MusicQueueCurrentRow(track: current, isPlaying: service.player.isPlaying) {
                        service.jump(to: current)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                MusicQueueKicker(
                    text: terms.isEmpty
                        ? MusicQueueListing.nextKicker(count: listing.upcoming.count)
                        : MusicQueueListing.nextKicker(matched: matches.count, total: listing.upcoming.count)
                )
                upcoming(listing.upcoming, matches: matches, terms: terms)
            }
        }
        .padding(.top, 10)
    }

    // MARK: - The list

    @ViewBuilder
    private func upcoming(_ tracks: [MusicTrack], matches: [Int], terms: [String]) -> some View {
        if tracks.isEmpty {
            MusicStateCard(message: "No more songs queued.", minHeight: 48)
                .frame(maxHeight: .infinity, alignment: .top)
        } else {
            let shown = matches.map { tracks[$0] }
            ScrollView {
                LazyVStack(spacing: 0) {
                    if shown.isEmpty {
                        noMatches
                    }
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, track in
                        MusicSongRow(track: track, isCurrent: false, isPlaying: false, layout: .playlist) {
                            service.jump(to: track)
                        }
                        .musicRowHairline(index > 0)
                    }
                    if !terms.isEmpty {
                        clearHint(total: tracks.count)
                    }
                }
                .environment(\.musicHighlightTerms, terms)
                .padding(.bottom, Self.fadeHeight)
            }
            .scrollIndicators(.never)
            .mask(bottomFade)
        }
    }

    /// What the filter found nothing in: the block that offers YouTube Music with the same words.
    private var noMatches: some View {
        let copy = MusicSearchCopy.noResults(
            noun: .song,
            query: navigation.fieldQuery,
            place: "the queue",
            beyond: "the queue"
        )
        return MusicNoResultsBlock(title: copy.title, detail: copy.detail) {
            navigation.searchYouTubeMusicInstead()
        }
    }

    /// Under a filtered list: a hairline and how to see all of it again.
    private func clearHint(total: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Rectangle()
                .fill(MusicStyle.Palette.hairline)
                .frame(height: 1)
                .accessibilityHidden(true)
            Text(MusicSearchCopy.clearHint(total: total, noun: .song))
                .musicText(MusicStyle.Typeface.secondary)
                .foregroundStyle(Color.white.opacity(0.40))
                .lineLimit(1)
        }
        .padding(.horizontal, MusicStyle.Spacing.page)
        .padding(.top, 8)
    }

    /// The last rows dissolve into the bottom of the column.
    private static let fadeHeight: CGFloat = 24

    private var bottomFade: some View {
        VStack(spacing: 0) {
            Rectangle().fill(.black)
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: Self.fadeHeight)
        }
    }
}

/// A small uppercase label over a group of rows.
private struct MusicQueueKicker: View {
    let text: String

    var body: some View {
        Text(text)
            .musicText(MusicStyle.Typeface.kicker)
            .foregroundStyle(MusicStyle.Palette.textMeta)
            .lineLimit(1)
            .padding(.horizontal, MusicStyle.Spacing.page)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The song in the player, at the top of Up next: a 48 pt row on a soft white fill, with the small spectrum that moves
/// while it plays. A tap starts it over; the right click menu is the song's own.
private struct MusicQueueCurrentRow: View {
    let track: MusicTrack
    let isPlaying: Bool
    let action: () -> Void

    /// Set while Full Keyboard Access has put keyboard focus on the row.
    @FocusState private var isKeyboardFocused: Bool
    @Environment(\.musicTrackMenu) private var menu
    @Environment(\.musicTrackContext) private var context

    var body: some View {
        let actions = menu?.actions(track, context) ?? []
        HStack(spacing: 10) {
            MusicThumbnail(url: track.thumbnailURL, size: 34, cornerRadius: MusicStyle.Radius.small)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(track.title)
                    .musicText(MusicStyle.Typeface.rowMedium)
                    .foregroundStyle(MusicStyle.Palette.textPlaying)
                    .lineLimit(1)
                    .accessibilityHidden(true)
                subtitle
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                MusicMiniSpectrumView(isPlaying: isPlaying)
                if let duration = MusicSongRowLayout.durationText(seconds: track.durationSeconds) {
                    Text(duration)
                        .musicText(MusicStyle.Typeface.mono)
                        .foregroundStyle(MusicStyle.Palette.textMeta)
                        .lineLimit(1)
                        .fixedSize()
                        .accessibilityHidden(true)
                }
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .frame(height: 48)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
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

    /// "artist · album" at half white; the artist names stay links.
    private var subtitle: some View {
        HStack(spacing: 0) {
            MusicArtistLine(
                artist: track.artist,
                links: track.artistLinks,
                hidesPlainTextFromVoiceOver: true,
                font: MusicStyle.Typeface.secondary.font,
                color: MusicStyle.Palette.textSub
            )
            .layoutPriority(1)
            if let album = track.album, !album.isEmpty {
                Text(" \u{00B7} " + album)
                    .musicText(MusicStyle.Typeface.secondary)
                    .foregroundStyle(MusicStyle.Palette.textSub)
                    .lineLimit(1)
                    .accessibilityHidden(true)
            }
        }
    }
}
