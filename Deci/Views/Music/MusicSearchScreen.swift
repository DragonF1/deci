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

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                field
                    .padding(.horizontal, MusicStyle.Spacing.page)
                    .padding(.top, 8)
                    .padding(.bottom, MusicStyle.Spacing.sectionContent)

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
                ProgressView()
                    .controlSize(.mini)
                    .environment(\.colorScheme, .dark)
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
        .background(Capsule().fill(MusicStyle.Palette.fillControl))
        .overlay(Capsule().strokeBorder(MusicStyle.Palette.lineGlass, lineWidth: 1))
    }

    @ViewBuilder
    private var results: some View {
        if !navigation.showsResults {
            MusicStateCard(
                message: service.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "Search YouTube Music for songs and artists."
                    : "Press Return to search."
            )
        } else if !navigation.hasResults {
            MusicStateCard(message: navigation.emptyResultsText)
        } else {
            songsAndArtists
        }
    }

    /// The results keep the look of the song rows and tiles; only the margin is the new one.
    private var songsAndArtists: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The artists the search found, as a row of tiles above the songs.
            if let artists = navigation.artistsShelf {
                MusicShelfView(
                    shelf: artists,
                    nowPlayingId: service.player.nowPlaying?.videoId,
                    isPlaying: service.player.isPlaying,
                    onPlay: { service.play($0) },
                    onOpen: { navigation.openArtist($0) }
                )
                if !service.results.isEmpty {
                    MusicSectionTitle(text: "Songs")
                        .padding(.top, DesignTokens.Spacing.md)
                        .padding(.bottom, DesignTokens.Spacing.xs)
                }
            }
            ForEach(service.results) { track in
                MusicResultRow(
                    track: track,
                    isCurrent: service.player.nowPlaying?.videoId == track.videoId,
                    isPlaying: service.player.nowPlaying?.videoId == track.videoId && service.player.isPlaying
                ) {
                    service.play(track)
                }
            }
        }
        .padding(.horizontal, 12)
    }
}
