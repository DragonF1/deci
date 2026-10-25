// Deci/Views/Music/MusicOfflineViews.swift
import SwiftUI

// The pieces of the Music tab that only exist because the network can be gone: the line under the header, the note that
// stands in for a feed, and the environment value that lets every cover show the picture saved with a download.

/// Maps a cover address to the picture saved on this Mac for it, nil when none was saved. The Music tab sets it; outside the
/// tab covers show their address as given.
typealias MusicLocalCoverResolver = @MainActor (URL?) -> URL?

private struct MusicLocalCoverKey: EnvironmentKey {
    static let defaultValue: MusicLocalCoverResolver? = nil
}

extension EnvironmentValues {
    var musicLocalCover: MusicLocalCoverResolver? {
        get { self[MusicLocalCoverKey.self] }
        set { self[MusicLocalCoverKey.self] = newValue }
    }
}

/// What stands in for Home, History, a search or a page the network would fill while there is none: one line of plain
/// centred text, no spinner and no Retry. For a signed-out listener (`signInService`) the Sign in button sits under the
/// line, so the way back is one click; the downloads are reachable either way.
struct MusicOfflineNote: View {
    var text: String = MusicOfflineCopy.note
    /// The service that opens the sign-in window; nil leaves the button out (the network is down: nothing could load).
    var signInService: MusicService?

    var body: some View {
        MusicStateCard(minHeight: MusicBrowseLayout.offlineNoteHeight) {
            MusicStateCardMessage(text: text)
            if let signInService {
                MusicSignInButton(service: signInService)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// The thin line under the Music header while the network is down: the secondary text style, one line, on the column's
/// own surface.
struct MusicOfflineBanner: View {
    var text: String = MusicOfflineCopy.banner

    var body: some View {
        Text(text)
            .musicText(MusicStyle.Typeface.secondary)
            .foregroundStyle(MusicStyle.Palette.textSub)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, MusicStyle.Spacing.page)
            .padding(.vertical, MusicBrowseLayout.offlineBannerPadding)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
            .accessibilityAddTraits(.isStaticText)
    }
}
