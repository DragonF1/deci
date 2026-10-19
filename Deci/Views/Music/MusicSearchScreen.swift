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
                    .padding(.top, 8)
                    .padding(.bottom, 12)

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
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16))
                .foregroundStyle(Color.white.opacity(0.6))
                .accessibilityHidden(true)
            TextField(
                "",
                text: $service.query,
                prompt: Text("Search songs and artists").foregroundStyle(MusicStyle.Palette.textPlaceholder)
            )
            .textFieldStyle(.plain)
            .musicText(MusicStyle.Typeface.body14)
            .foregroundStyle(.white)
            .focused($isFocused)
            .onSubmit { navigation.submit() }
            .accessibilityLabel("Search songs and artists")
            if service.isSearching {
                MusicSpinner(size: 15, lineWidth: 1.6)
            }
            if !service.query.isEmpty {
                Button("Clear search", systemImage: "xmark.circle.fill") {
                    service.query = ""
                    isFocused = true
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .font(.system(size: 16))
                .foregroundStyle(MusicStyle.Palette.textQuaternary)
                .contentShape(Rectangle())
                .help("Clear search")
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .frame(height: 36)
        .musicGlass(in: Capsule(), fill: MusicStyle.Palette.fillControl, stroke: MusicStyle.Palette.lineGlass, shadow: nil)
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

    /// The invite, searching, no results and failed cards: 72 tall, 16 under the field.
    private func stateCard(_ panel: MusicSearchPanel, message: String) -> some View {
        MusicStateCard(minHeight: Self.stateCardHeight) {
            switch panel {
            case .searching:
                HStack(spacing: 8) {
                    MusicSpinner(size: 15, lineWidth: 1.6)
                    MusicStateCardMessage(text: message)
                }
            case .failed:
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 15))
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

    private static let stateCardHeight: CGFloat = 72

    /// The artists the search found as a row of round tiles, then the songs as rows.
    private var songsAndArtists: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !service.artistResults.isEmpty {
                MusicSectionHeader(title: "Artists")
                artistsRow
                    .padding(.top, MusicStyle.Spacing.sectionContent)
                if !service.results.isEmpty {
                    MusicSectionHeader(title: "Songs")
                        .padding(.top, 18)
                        .padding(.bottom, MusicStyle.Spacing.sectionContent)
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

    /// A sideways row that starts 20 in and scrolls under the popover edge, as on Home.
    private var artistsRow: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: MusicStyle.Spacing.searchArtistGap) {
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
            .padding(.horizontal, MusicStyle.Spacing.page)
        }
        .scrollIndicators(.never)
        .scrollClipDisabled()
    }
}

/// An artist the search found: a round 72 pt photo with the name and "Artist" under it.
struct MusicSearchArtistTile: View {
    let collection: MusicCollection
    var isPinned = false
    let action: () -> Void

    static let width: CGFloat = 80
    static let photoSize: CGFloat = 72

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                MusicThumbnail(
                    url: collection.thumbnailURL,
                    size: Self.photoSize,
                    circular: true,
                    placeholder: MusicCollection.Kind.artist.placeholderSymbol
                )
                .musicPinBadge(isPinned, coverSize: Self.photoSize, circular: true)

                VStack(spacing: 1) {
                    Text(collection.title)
                        .musicText(MusicStyle.Typeface.caption12M)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text("Artist")
                        .musicText(MusicStyle.Typeface.caption11R)
                        .foregroundStyle(MusicStyle.Palette.textSecondary)
                        .lineLimit(1)
                }
                .multilineTextAlignment(.center)
            }
            .frame(width: Self.width)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .musicHoverScale()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isPinned ? "\(collection.title), artist, pinned" : "\(collection.title), artist")
        .accessibilityAddTraits(.isButton)
    }
}
