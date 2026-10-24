// Deci/Views/Music/MusicBrowseView.swift
import SwiftUI

/// Home, Library or History, or the page on top of `browse.path`. The root stays alive under an open page so going back
/// lands where the list was scrolled to. While the header's YouTube Music field has words in it, the results cover all
/// of that in place; the screen under them keeps its place and comes back when the field is cleared. An artist page's
/// field is covered the same way by what it finds on that artist.
struct MusicBrowseView: View {
    let service: MusicService
    let navigation: MusicSearchNavigation

    private var browse: MusicBrowseStore { service.browse }

    var body: some View {
        let atRoot = browse.path.isEmpty
        let artistSearch = navigation.artistSearch
        let showsResults = navigation.showsSearchPanel || artistSearch != nil
        ZStack {
            screens(atRoot: atRoot)
                .opacity(showsResults ? 0 : 1)
                .allowsHitTesting(!showsResults)
                .accessibilityHidden(showsResults)

            if navigation.showsSearchPanel {
                MusicSearchResultsView(service: service, navigation: navigation)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .contentShape(Rectangle())
            } else if let artistSearch {
                MusicArtistSearchView(service: service, navigation: navigation, search: artistSearch)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .contentShape(Rectangle())
            }
        }
        // The page a scoped search needs (Liked music, an artist's songs) is asked for when the words start, or when the
        // artist page lands under words typed before it.
        .onChange(of: navigation.scopedLoadTarget) {
            navigation.startScopedLoad()
        }
    }

    private func screens(atRoot: Bool) -> some View {
        ZStack {
            root
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .opacity(atRoot ? 1 : 0)
                .allowsHitTesting(atRoot)
                .accessibilityHidden(!atRoot)

            if let top = browse.path.last {
                MusicPageView(service: service, navigation: navigation, collection: top)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    // A fresh view per page, so each one starts at the top.
                    .id("\(browse.path.count)|\(top.browseId)")
            }
        }
    }

    @ViewBuilder
    private var root: some View {
        switch browse.tab {
        case .home:
            MusicHomeView(service: service)
        case .library:
            MusicLibraryView(service: service, navigation: navigation)
        case .history:
            MusicHistoryView(service: service, navigation: navigation)
        }
    }
}
