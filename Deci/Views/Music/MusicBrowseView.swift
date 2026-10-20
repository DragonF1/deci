// Deci/Views/Music/MusicBrowseView.swift
import SwiftUI

/// Home, Library or Search, or the page on top of `browse.path`. The root stays alive under an open
/// page so going back lands where the list was scrolled to.
struct MusicBrowseView: View {
    let service: MusicService
    let navigation: MusicSearchNavigation
    /// False while a player screen or the picker covers the browse screens, which stay alive under them.
    var isActive = true

    private var browse: MusicBrowseStore { service.browse }

    var body: some View {
        let atRoot = browse.path.isEmpty
        ZStack {
            root
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .opacity(atRoot ? 1 : 0)
                .allowsHitTesting(atRoot)
                .accessibilityHidden(!atRoot)

            if let top = browse.path.last {
                MusicPageView(service: service, collection: top)
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
            MusicLibraryView(service: service)
        case .search:
            MusicSearchScreen(service: service, navigation: navigation, isActive: isActive)
        }
    }
}
