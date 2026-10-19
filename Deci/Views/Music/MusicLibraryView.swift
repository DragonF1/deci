// Deci/Views/Music/MusicLibraryView.swift
import SwiftUI

/// The Library root: a large title, the Playlists / Albums / Artists switch, then the saved list, with Liked music
/// first on Playlists. One scroll view, so the title scrolls away with the content.
struct MusicLibraryView: View {
    let service: MusicService
    @Environment(\.musicCollectionPin) private var collectionPin

    private var browse: MusicBrowseStore { service.browse }
    private var section: MusicLibrarySection { browse.librarySection }

    private static let topID = "library-top"

    var body: some View {
        ScrollViewReader { proxy in
            scroll
                // Another section starts at the top, as its own list did before the title joined the scroll.
                .onChange(of: section) {
                    proxy.scrollTo(Self.topID, anchor: .top)
                }
        }
    }

    private var scroll: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                MusicScreenHeader(title: "Library", account: service.account)
                    .id(Self.topID)

                MusicSegmentSwitch(segments: MusicLibrarySection.segments, selection: section) {
                    browse.librarySection = $0
                }
                .padding(.horizontal, MusicStyle.Spacing.page)
                .padding(.top, 12)
                .padding(.bottom, MusicStyle.Spacing.sectionContent)

                // Always first on Playlists, whatever state the list under it is in.
                likedMusic
                list

                MusicBottomInsetSpacer()
            }
        }
        .scrollIndicators(.never)
        .onAppear { browse.loadLibraryIfNeeded(section) }
        .onChange(of: section) { _, newSection in
            browse.loadLibraryIfNeeded(newSection)
        }
        // A channel switch drops what was loaded while this view stays up.
        .onChange(of: browse.libraryState(section) == .idle) { _, isIdle in
            if isIdle { browse.loadLibraryIfNeeded(section) }
        }
    }

    @ViewBuilder
    private var list: some View {
        switch browse.libraryState(section) {
        case .idle, .loading:
            MusicLoadingCard()
        case .failed(let message):
            MusicFailedCard(message: message) { browse.reloadLibrary(section) }
        case .loaded(let items) where items.isEmpty:
            MusicStateCard(message: section.emptyText)
        case .loaded(let items):
            let loadingMore = browse.loadingMoreLibrary.contains(section)
            ForEach(Array(items.enumerated()), id: \.offset) { _, collection in
                let row = MusicCollectionRow(
                    collection: collection,
                    isPinned: collectionPin?.isPinned(collection) == true
                ) {
                    browse.open(collection)
                }
                if let collectionPin, let listenAgain = collectionPin.pin(collection) {
                    row.contextMenu {
                        MusicListenAgainPinItem(toggle: listenAgain) { collectionPin.toggle(collection) }
                    }
                } else {
                    row
                }
            }

            if browse.libraryHasMore.contains(section) || loadingMore {
                MusicLoadMoreFooter(isLoading: loadingMore) {
                    guard !browse.loadingMoreLibrary.contains(section) else { return }
                    browse.loadMoreLibrary(section)
                }
            }
        }
    }

    /// Liked music is the first row of Playlists, whatever the list below it holds.
    @ViewBuilder
    private var likedMusic: some View {
        if section == .playlists {
            MusicCollectionRow(collection: MusicBrowseStore.likedMusic, symbol: "heart.fill") {
                browse.open(MusicBrowseStore.likedMusic)
            }
        }
    }
}

/// A playlist, album or artist row that opens its page. `symbol` swaps the cover for an icon
/// tile (Liked music).
struct MusicCollectionRow: View {
    let collection: MusicCollection
    var symbol: String?
    /// Pinned to Listen again (a playlist or album) or to Home (an artist): the cover wears the pin badge.
    var isPinned = false
    let action: () -> Void

    static let coverSize: CGFloat = 56

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                cover

                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(collection.title)
                            .musicText(MusicStyle.Typeface.row15M)
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        if !collection.subtitle.isEmpty {
                            Text(MusicHomeText.subtitle(collection.subtitle))
                                .musicText(MusicStyle.Typeface.caption12)
                                .foregroundStyle(MusicStyle.Palette.textSecondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(MusicStyle.Palette.textQuaternary)
                        .accessibilityHidden(true)
                }
                .frame(maxHeight: .infinity)
                .padding(.trailing, 4)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(MusicStyle.Palette.lineHairline).frame(height: 1)
                }
            }
            .padding(.horizontal, MusicStyle.Spacing.page)
            .frame(height: 64)
            .background(isHovered ? MusicStyle.Palette.fillHover : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isButton)
    }

    private var accessibilityText: String {
        let base = collection.subtitle.isEmpty ? collection.title : "\(collection.title), \(collection.subtitle)"
        return isPinned ? base + ", pinned" : base
    }

    @ViewBuilder
    private var cover: some View {
        if let symbol {
            RoundedRectangle(cornerRadius: MusicStyle.Radius.art, style: .continuous)
                .fill(MusicStyle.Palette.likedGradient)
                .frame(width: Self.coverSize, height: Self.coverSize)
                .overlay {
                    Image(systemName: symbol)
                        .font(.system(size: 26))
                        .foregroundStyle(.white)
                }
                .accessibilityHidden(true)
        } else {
            let circular = collection.kind == .artist
            MusicThumbnail(
                url: collection.thumbnailURL,
                size: Self.coverSize,
                circular: circular,
                placeholder: collection.kind.placeholderSymbol,
                cornerRadius: MusicStyle.Radius.art
            )
            .overlay {
                if circular {
                    Circle().strokeBorder(MusicStyle.Palette.lineHairline, lineWidth: 1)
                } else {
                    RoundedRectangle(cornerRadius: MusicStyle.Radius.art, style: .continuous)
                        .strokeBorder(MusicStyle.Palette.lineHairline, lineWidth: 1)
                }
            }
            .musicPinBadge(isPinned, coverSize: Self.coverSize, circular: circular, diameter: 14, inset: 4)
        }
    }
}
