// Deci/Views/Music/MusicPageView.swift
import SwiftUI

/// The page on top of `browse.path`: a playlist, album or artist, with a back button.
struct MusicPageView: View {
    let service: MusicService
    let collection: MusicCollection

    private var browse: MusicBrowseStore { service.browse }

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.xs) {
            MusicPageTopBar(title: collection.title) { browse.back() }
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        switch browse.pageState(collection.browseId) {
        case .idle, .loading:
            MusicLoadingView()
        case .failed(let message):
            MusicFailedView(message: message) { browse.reloadPage(collection.browseId) }
        case .loaded(let page):
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    MusicPageHeader(page: page, kind: collection.kind) {
                        if let first = page.tracks.first { service.play(first, in: page) }
                    }
                    .padding(.bottom, DesignTokens.Spacing.sm)

                    tracks(of: page)

                    ForEach(Array(page.shelves.enumerated()), id: \.offset) { _, shelf in
                        MusicShelfView(
                            shelf: shelf,
                            nowPlayingId: service.player.nowPlaying?.videoId,
                            isPlaying: service.player.isPlaying,
                            onPlay: { service.play($0) },
                            onOpen: { browse.open($0) }
                        )
                        .padding(.top, DesignTokens.Spacing.md)
                    }
                }
            }
            .scrollIndicators(.never)
        }
    }

    @ViewBuilder
    private func tracks(of page: MusicBrowsePage) -> some View {
        if page.tracks.isEmpty, page.shelves.isEmpty {
            MusicEmptyView(text: "No songs here yet.")
                .frame(height: 80)
        } else if !page.tracks.isEmpty {
            // An artist's songs sit above titled shelves, so they get a title too.
            if collection.kind == .artist {
                MusicSectionTitle(text: "Top songs")
                    .padding(.bottom, DesignTokens.Spacing.xs)
            }

            ForEach(Array(page.tracks.enumerated()), id: \.offset) { _, track in
                MusicResultRow(
                    track: track,
                    isCurrent: service.player.nowPlaying?.videoId == track.videoId,
                    isPlaying: service.player.nowPlaying?.videoId == track.videoId && service.player.isPlaying
                ) {
                    service.play(track, in: page)
                }
            }

            let loadingMore = browse.loadingMoreTracks.contains(page.browseId)
            if page.continuation != nil || loadingMore {
                MusicLoadMoreFooter(isLoading: loadingMore) {
                    guard !browse.loadingMoreTracks.contains(page.browseId) else { return }
                    browse.loadMoreTracks(page.browseId)
                }
            }
        }
    }
}

/// Back chevron and the page title.
struct MusicPageTopBar: View {
    let title: String
    let onBack: () -> Void

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back")
            .help("Back")

            Text(title)
                .font(DesignTokens.Typography.rowNameBold)
                .foregroundStyle(DesignTokens.Colors.textPrimary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
        }
    }
}

/// Cover, title, subtitle and a Play button that starts the page from its first song.
struct MusicPageHeader: View {
    let page: MusicBrowsePage
    let kind: MusicCollection.Kind
    let onPlay: () -> Void

    static let coverSize: CGFloat = 72

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            MusicThumbnail(
                url: page.thumbnailURL,
                size: Self.coverSize,
                circular: kind == .artist,
                placeholder: kind.placeholderSymbol
            )
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                Text(page.title)
                    .font(DesignTokens.Typography.cardHeader)
                    .foregroundStyle(DesignTokens.Colors.textPrimary)
                    .lineLimit(2)
                if let subtitle = page.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(DesignTokens.Typography.rowDescription)
                        .foregroundStyle(DesignTokens.Colors.textSecondary)
                        .lineLimit(2)
                }

                if !page.tracks.isEmpty {
                    Button(action: onPlay) {
                        Label("Play", systemImage: "play.fill")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.plain)
                    .font(DesignTokens.Typography.pickerText)
                    .foregroundStyle(DesignTokens.Colors.textPrimary)
                    .glassButtonStyle()
                    .contentShape(Capsule())
                    .accessibilityLabel("Play \(page.title)")
                    .padding(.top, DesignTokens.Spacing.xs)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
    }
}
