// Deci/Views/Music/MusicSearchScreen.swift
import SwiftUI

/// The Search tab: a field that scrolls with the content, then the artists and songs the search found. The query
/// stays while an artist page is open over it, and Back returns to the results.
struct MusicSearchScreen: View {
    @Bindable var service: MusicService
    let navigation: MusicSearchNavigation
    /// False while a player screen or the picker covers this screen, which stays alive under them.
    var isActive = true

    @FocusState private var isFocused: Bool
    @Environment(\.musicCollectionPin) private var collectionPin

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                field
                    .padding(.horizontal, MusicStyle.Spacing.page)
                    .padding(.bottom, DesignTokens.Spacing.sm)

                results

                MusicBottomInsetSpacer()
            }
        }
        .scrollIndicators(.never)
        // Typing can start the moment the tab opens.
        .task { isFocused = true }
        // A page opened over the results keeps this screen alive but hidden: the field must not keep the keyboard.
        .onChange(of: service.browse.path.isEmpty) { _, atRoot in
            if !atRoot { isFocused = false }
        }
        // Covered by a player screen or the picker: a hidden field must not keep the keyboard either.
        .onChange(of: isActive) { _, active in
            if !active { isFocused = false }
        }
    }

    private var field: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(MusicStyle.Palette.textTertiary)
                .accessibilityHidden(true)
            TextField(
                "",
                text: $service.query,
                prompt: Text("Search songs and artists").foregroundStyle(MusicStyle.Palette.textTertiary)
            )
            .textFieldStyle(.plain)
            .musicText(MusicStyle.Typeface.row)
            .foregroundStyle(MusicStyle.Palette.textPrimary)
            .focused($isFocused)
            .onSubmit { navigation.submit() }
            .accessibilityLabel("Search songs and artists")
            if service.isSearching {
                MusicSpinner(size: 13, lineWidth: 1.5)
            }
            if !service.query.isEmpty {
                Button("Clear search", systemImage: "xmark.circle.fill") {
                    service.query = ""
                    isFocused = true
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(MusicStyle.Palette.textTertiary)
                .contentShape(Rectangle())
                .help("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius, style: .continuous)
                .fill(DesignTokens.Colors.pickerBackground)
        )
    }

    // MARK: - Under the field

    @ViewBuilder
    private var results: some View {
        let panel = navigation.panel
        if let message = panel.message {
            stateCard(panel, message: message)
        } else {
            songsAndArtists
        }
    }

    /// The invite, searching, no results and failed lines: plain centred text, a little under the field.
    private func stateCard(_ panel: MusicSearchPanel, message: String) -> some View {
        MusicStateCard(minHeight: Self.stateCardHeight) {
            switch panel {
            case .searching:
                HStack(spacing: 8) {
                    MusicSpinner(size: 14, lineWidth: 1.5)
                    MusicStateCardMessage(text: message)
                }
            case .failed:
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 13))
                        .foregroundStyle(MusicStyle.Palette.textSecondary)
                        .accessibilityHidden(true)
                    MusicStateCardMessage(text: message)
                }
            case .invite, .pressReturn, .noResults, .results:
                MusicStateCardMessage(text: message)
            }
        }
        .padding(.top, 4)
    }

    private static let stateCardHeight: CGFloat = 56

    /// The artists the search found as a row of round tiles, then the songs as rows.
    private var songsAndArtists: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !service.artistResults.isEmpty {
                MusicSectionHeader(title: "Artists")
                artistsRow
                    .padding(.top, DesignTokens.Spacing.xs)
                if !service.results.isEmpty {
                    MusicSectionHeader(title: "Songs")
                        .padding(.top, MusicStyle.Spacing.sectionGap)
                        .padding(.bottom, DesignTokens.Spacing.xs)
                }
            }
            ForEach(service.results) { track in
                MusicSongRow(
                    track: track,
                    isCurrent: service.player.nowPlaying?.videoId == track.videoId,
                    isPlaying: service.player.nowPlaying?.videoId == track.videoId && service.player.isPlaying
                ) {
                    service.play(track)
                }
            }
        }
    }

    /// A sideways row of artists, as on Home.
    private var artistsRow: some View {
        MusicHorizontalShelf {
            ForEach(Array(service.artistResults.enumerated()), id: \.offset) { _, artist in
                MusicSearchArtistTile(
                    collection: artist,
                    isPinned: collectionPin?.isPinned(artist) == true
                ) {
                    navigation.openArtist(artist)
                }
                .musicCollectionMenu(artist)
            }
        }
    }
}

/// An artist the search found: a round 56 pt photo with the name and "Artist" under it.
struct MusicSearchArtistTile: View {
    let collection: MusicCollection
    var isPinned = false
    let action: () -> Void

    static let width: CGFloat = 64
    static let photoSize: CGFloat = 56

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                MusicThumbnail(
                    url: collection.thumbnailURL,
                    size: Self.photoSize,
                    circular: true,
                    placeholder: MusicCollection.Kind.artist.placeholderSymbol
                )
                .musicPinBadge(isPinned, coverSize: Self.photoSize, circular: true)

                VStack(spacing: 1) {
                    Text(collection.title)
                        .musicText(MusicStyle.Typeface.secondaryMedium)
                        .foregroundStyle(MusicStyle.Palette.textPrimary)
                        .lineLimit(1)
                    Text("Artist")
                        .musicText(MusicStyle.Typeface.caption)
                        .foregroundStyle(MusicStyle.Palette.textSecondary)
                        .lineLimit(1)
                }
                .multilineTextAlignment(.center)
            }
            .frame(width: Self.width)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .musicTileHover()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isPinned ? "\(collection.title), artist, pinned" : "\(collection.title), artist")
        .accessibilityAddTraits(.isButton)
    }
}
