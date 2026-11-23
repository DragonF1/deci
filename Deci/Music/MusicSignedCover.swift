// Deci/Music/MusicSignedCover.swift
import Foundation

/// The cover of a playlist with an uploaded picture. YouTube Music serves it from a signed address
/// (`i.ytimg.com/pl_c/<playlist id>/...?sqp=...&rs=...`) that stops working after some days (one 11 days old was a 404), and no unsigned form of
/// it exists. Every other cover address keeps working, so only these need asking for again.
nonisolated enum MusicSignedCover {
    /// The playlist id of a signed cover address, nil for any other address (a video thumbnail, a Google-hosted picture,
    /// nothing).
    static func playlistId(in url: URL?) -> String? {
        // The path first: every cover asks on each draw, and almost none are signed.
        guard let url, url.path.hasPrefix("/pl_c/") else { return nil }
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 3, let host = url.host(percentEncoded: false)?.lowercased(), isImageHost(host) else { return nil }
        return String(parts[1])
    }

    /// `i.ytimg.com` and its numbered mirrors `i1` to `i9`.
    private static func isImageHost(_ host: String) -> Bool {
        if host == "i.ytimg.com" { return true }
        let chars = Array(host)
        return host.hasSuffix(".ytimg.com") && chars.count == "i1.ytimg.com".count && chars[0] == "i" && chars[1].isASCII
            && chars[1].isNumber
    }
}
