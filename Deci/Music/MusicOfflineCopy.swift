// Deci/Music/MusicOfflineCopy.swift
// The words and the surfaces of the Music tab with no network.

import Foundation

/// A place in the Music tab that is a feed or a page of the network, and so may need to say that there is none.
nonisolated enum MusicOfflineSurface: Hashable, Sendable {
    case home
    case history
    /// A page opened from Home, Library or History, by its browse id.
    case page(String)
}

nonisolated enum MusicOfflineCopy {
    /// The thin line under the Music header while offline.
    static let banner = "Offline. Playing downloads only."
    /// Stands in for a feed or a page that needs the network (Home, History, a page that is not downloaded, a search).
    static let note = "You're offline. Your downloads are in Library."
    /// The same stand-in when the network is up and the account is gone: a signed-out listener is not offline, and the
    /// note carries a Sign in button (`signInButton`) beside it.
    static let signedOutNote = "You're signed out. Your downloads are in Library."
    static let signInButton = "Sign in"
    /// Under the sign-in note, for a listener with downloads: opens them. And the Back row that returns to the note.
    static let signedOutDownloads = "Downloads"
    static let signedOutBack = "Sign in"
    static let noDownloadsTitle = "No downloads yet"
    static let noDownloadsDetail = "Download a song from its menu, or a whole playlist or album from its page."

    /// The Downloads tab's answer to words that match nothing in it.
    static func noMatch(query: String) -> String {
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return words.isEmpty ? "Nothing in your downloads matches." : "Nothing in your downloads matches \u{201C}\(words)\u{201D}."
    }
}
