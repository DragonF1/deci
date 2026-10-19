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
        case .loaded(let loaded):
            // A sorted playlist shows, and queues, its sorted songs once all of them are loaded.
            let page = browse.displayedPage(collection.browseId) ?? loaded
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    MusicPageHeader(
                        page: page,
                        kind: collection.kind,
                        pin: collection.kind == .artist ? pinControl(for: page) : nil,
                        sort: MusicBrowseStore.canSort(page.browseId) ? browse.sort(for: page.browseId) : nil,
                        isLoadingAll: browse.loadingAllTracks.contains(page.browseId),
                        sortLimit: browse.sortedSongLimit(page.browseId),
                        onPlay: { if let first = page.tracks.first { service.play(first, in: page) } },
                        onShuffle: { service.playShuffled(page) },
                        onPickSort: { browse.pickSort($0, for: page.browseId) }
                    )
                    .padding(.bottom, DesignTokens.Spacing.sm)

                    // The page the songs sit on decides whether they can leave the playlist or go to this album.
                    tracks(of: page)
                        .environment(\.musicTrackContext, MusicTrackContext(
                            pageBrowseId: page.browseId,
                            pageTitle: page.title,
                            pageIsEditable: page.isEditable
                        ))

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

    /// The tile keeps the photo of the collection that opened this page: the square or round avatar.
    private func pinControl(for page: MusicBrowsePage) -> MusicPageHeader.PinControl {
        let pins = service.pinnedArtists
        return MusicPageHeader.PinControl(
            isPinned: pins.isPinned(page.browseId),
            isEnabled: pins.canToggle(page.browseId),
            toggle: { pins.toggle(MusicPinnedArtist(page: page, opener: collection)) }
        )
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

            let loadingMore = browse.loadingMoreTracks.contains(page.browseId) || browse.loadingAllTracks.contains(page.browseId)
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

/// Cover, title, subtitle, a Play button that starts the page from its first song, Shuffle, and on a playlist
/// a Sort menu. An artist's page has Pin to Home beside Play instead.
struct MusicPageHeader: View {
    /// The Pin to Home button of an artist page.
    struct PinControl {
        let isPinned: Bool
        /// Off while Home is full and this artist is not pinned yet.
        let isEnabled: Bool
        let toggle: () -> Void
    }

    let page: MusicBrowsePage
    let kind: MusicCollection.Kind
    /// The pin button; nil on a page that is not an artist's.
    var pin: PinControl?
    /// The sort picked for a playlist; nil on a page that cannot be sorted.
    var sort: MusicPlaylistSort?
    /// The sort is loading the rest of the songs before it can order them.
    var isLoadingAll = false
    /// The sort covers only this many songs, the start of a longer playlist. Nil when it covers all of them.
    var sortLimit: Int?
    let onPlay: () -> Void
    let onShuffle: () -> Void
    var onPickSort: (MusicSortField) -> Void = { _ in }

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

                if !page.tracks.isEmpty || pin != nil {
                    HStack(spacing: DesignTokens.Spacing.xs) {
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

                            // An artist's page lists top songs, not a collection to shuffle through.
                            if kind != .artist {
                                Button(action: onShuffle) {
                                    Label("Shuffle", systemImage: "shuffle")
                                        .labelStyle(.titleAndIcon)
                                }
                                .buttonStyle(.plain)
                                .font(DesignTokens.Typography.pickerText)
                                .foregroundStyle(DesignTokens.Colors.textPrimary)
                                .glassButtonStyle()
                                .contentShape(Capsule())
                                .accessibilityLabel("Shuffle \(page.title)")
                            }

                            if let sort {
                                sortMenu(sort)
                            }

                            if isLoadingAll {
                                loadingAllState
                            } else if let sortLimit {
                                sortLimitNote(sortLimit)
                            }
                        }

                        // Beside Play, and on an artist with no songs to play, on its own.
                        if let pin {
                            pinButton(pin)
                        }
                    }
                    .padding(.top, DesignTokens.Spacing.xs)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
    }

    static func pinLabel(isPinned: Bool) -> String {
        isPinned ? "Unpin from Home" : "Pin to Home"
    }

    static func pinSymbol(isPinned: Bool) -> String {
        isPinned ? "pin.fill" : "pin"
    }

    /// What the button's tooltip says; when Home is full and the artist is not pinned, it says why the button is off.
    static func pinHelp(isPinned: Bool, isEnabled: Bool) -> String {
        if isPinned { return "Take this artist off Home." }
        return isEnabled
            ? "Show this artist at the top of Home."
            : "Home can hold \(MusicPinnedArtists.limit) pinned artists. Unpin one to pin another."
    }

    private func pinButton(_ pin: PinControl) -> some View {
        Button(action: pin.toggle) {
            Label(Self.pinLabel(isPinned: pin.isPinned), systemImage: Self.pinSymbol(isPinned: pin.isPinned))
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.plain)
        .font(DesignTokens.Typography.pickerText)
        .foregroundStyle(DesignTokens.Colors.textPrimary)
        .glassButtonStyle()
        .contentShape(Capsule())
        .opacity(pin.isEnabled ? 1 : 0.5)
        .disabled(!pin.isEnabled)
        .help(Self.pinHelp(isPinned: pin.isPinned, isEnabled: pin.isEnabled))
        .accessibilityLabel(pin.isPinned ? "Unpin \(page.title) from Home" : "Pin \(page.title) to Home")
    }

    /// The options, with a mark on the picked one that shows its direction. Picking it again flips the direction.
    private func sortMenu(_ sort: MusicPlaylistSort) -> some View {
        Menu {
            ForEach(MusicSortField.allCases) { field in
                Button {
                    onPickSort(field)
                } label: {
                    if field == sort.field {
                        Label(field.label, systemImage: sort.isDefault ? "checkmark" : Self.directionSymbol(sort))
                    } else {
                        Text(field.label)
                    }
                }
            }
        } label: {
            HStack(spacing: DesignTokens.Spacing.xs) {
                Image(systemName: "arrow.up.arrow.down")
                Text(sort.isDefault ? "Sort" : sort.field.label)
                if !sort.isDefault {
                    Image(systemName: Self.directionSymbol(sort))
                        .font(.system(size: 8, weight: .semibold))
                }
            }
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .font(DesignTokens.Typography.pickerText)
        .foregroundStyle(DesignTokens.Colors.textPrimary)
        .fixedSize()
        .glassButtonStyle()
        .contentShape(Capsule())
        .accessibilityLabel(sort.isDefault ? "Sort" : "Sort: \(sort.field.label), \(sort.ascending ? "ascending" : "descending")")
    }

    /// Up for ascending and down for descending.
    private static func directionSymbol(_ sort: MusicPlaylistSort) -> String {
        sort.ascending ? "arrow.up" : "arrow.down"
    }

    /// What the note beside the sort says: the sort did not reach every song of a long playlist.
    static func sortLimitText(_ count: Int) -> String {
        count == 1 ? "First song" : "First \(count) songs"
    }

    private func sortLimitNote(_ count: Int) -> some View {
        Text(Self.sortLimitText(count))
            .font(DesignTokens.Typography.caption)
            .foregroundStyle(DesignTokens.Colors.textTertiary)
            .lineLimit(1)
            .layoutPriority(-1)
            .help("The sort covers only the start of this playlist.")
    }

    private var loadingAllState: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            ProgressView()
                .controlSize(.small)
            Text("Loading all songs")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Colors.textTertiary)
                .lineLimit(1)
        }
        .layoutPriority(-1)
        .accessibilityElement(children: .combine)
    }
}
