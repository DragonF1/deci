// Deci/Views/Music/MusicLibraryView.swift
import SwiftUI

/// The Library root: Liked music pinned on top, then the saved playlists, albums or artists.
struct MusicLibraryView: View {
    @Bindable var browse: MusicBrowseStore
    @Environment(\.musicCollectionPin) private var collectionPin

    private var section: MusicLibrarySection { browse.librarySection }

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.xs) {
            MusicCollectionRow(collection: MusicBrowseStore.likedMusic, symbol: "heart.fill") {
                browse.open(MusicBrowseStore.likedMusic)
            }

            HStack {
                MusicSegmentSwitch(segments: MusicLibrarySection.segments, selection: section, height: 20) {
                    browse.librarySection = $0
                }
                Spacer()
            }

            list
        }
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
            MusicLoadingView()
        case .failed(let message):
            MusicFailedView(message: message) { browse.reloadLibrary(section) }
        case .loaded(let items) where items.isEmpty:
            MusicEmptyView(text: section.emptyText)
        case .loaded(let items):
            let loadingMore = browse.loadingMoreLibrary.contains(section)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, collection in
                        let row = MusicCollectionRow(collection: collection) {
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
            .scrollIndicators(.never)
            // A fresh list per section, so switching sections starts at the top.
            .id(section)
        }
    }
}

/// A playlist, album or artist row that opens its page. `symbol` swaps the cover for an icon
/// tile (Liked music).
struct MusicCollectionRow: View {
    let collection: MusicCollection
    var symbol: String?
    let action: () -> Void

    static let coverSize: CGFloat = 40

    var body: some View {
        Button(action: action) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                cover

                VStack(alignment: .leading, spacing: 1) {
                    Text(collection.title)
                        .font(DesignTokens.Typography.rowName)
                        .foregroundStyle(DesignTokens.Colors.textPrimary)
                        .lineLimit(1)
                    if !collection.subtitle.isEmpty {
                        Text(collection.subtitle)
                            .font(DesignTokens.Typography.rowDescription)
                            .foregroundStyle(DesignTokens.Colors.textSecondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: DesignTokens.Spacing.sm)

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
                    .accessibilityHidden(true)
            }
            .hoverableRow()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(collection.subtitle.isEmpty ? collection.title : "\(collection.title), \(collection.subtitle)")
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private var cover: some View {
        if let symbol {
            ZStack {
                RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius)
                    .fill(DesignTokens.Colors.glassFillStrong)
                Image(systemName: symbol)
                    .font(.system(size: 16))
                    .foregroundStyle(DesignTokens.Colors.accentPrimary)
            }
            .frame(width: Self.coverSize, height: Self.coverSize)
            .accessibilityHidden(true)
        } else {
            MusicThumbnail(
                url: collection.thumbnailURL,
                size: Self.coverSize,
                circular: collection.kind == .artist,
                placeholder: collection.kind.placeholderSymbol
            )
        }
    }
}
