// Deci/Views/Music/MusicSignedOutDownloadsView.swift
import SwiftUI

/// The right column signed out, once Downloads is opened from the sign-in note: the Library with its one working tab,
/// Downloads, and the pages of downloaded playlists and albums, all read from the download index. A Back row at the top
/// of the root returns to the sign-in note. The store treats a missing account like a missing network (see
/// `MusicBrowseStore.accountGone`), so nothing here asks the account for anything.
struct MusicSignedOutDownloadsView: View {
    let service: MusicService
    let navigation: MusicSearchNavigation
    /// Back to the sign-in note.
    let back: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // A page has its own Back row; the root has this one.
            if service.browse.path.isEmpty {
                MusicBackRow(label: MusicOfflineCopy.signedOutBack, action: back)
                    .padding(.top, MusicBrowseLayout.pageTop)
                    .padding(.horizontal, MusicStyle.Spacing.page)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            MusicBrowseView(service: service, navigation: navigation)
        }
    }
}

/// The link under the sign-in note that opens the downloads, for a listener who has some.
struct MusicOpenDownloadsLink: View {
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: MusicBrowseLayout.downloadsSymbol)
                    .font(.system(size: 12))
                    .accessibilityHidden(true)
                Text(MusicOfflineCopy.signedOutDownloads)
                    .musicText(MusicStyle.Typeface.secondaryMedium)
            }
            .foregroundStyle(Color.white.opacity(isHovered ? 0.85 : 0.55))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(DesignTokens.Animation.hover, value: isHovered)
        .accessibilityLabel(MusicOfflineCopy.signedOutDownloads)
    }
}
