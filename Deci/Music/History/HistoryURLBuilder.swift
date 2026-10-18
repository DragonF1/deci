// Deci/Music/History/HistoryURLBuilder.swift
import Foundation

/// Turns playbackTracking.videostatsPlaybackUrl / videostatsWatchtimeUrl `baseUrl` into the request
/// that adds a play to the account's YouTube Music history. The player response names s.youtube.com,
/// but YouTube Music's own web client sends these pings to music.youtube.com, with its own
/// parameters, the media time and one cpn per playback session.
enum HistoryURLBuilder {
    static let clientName = "WEB_REMIX"
    static let version = "2"
    /// Where the pings go.
    static let pingHost = "music.youtube.com"
    /// The entry point the web client reports when the tracking URL names none.
    static let defaultEntryPoint = "detailpage"

    /// Hosts the player response uses for tracking URLs; both are moved to `pingHost`.
    private static let rewrittenHosts: Set<String> = ["s.youtube.com", "www.youtube.com"]

    static func url(for ping: HistoryPing, clientVersion: String) -> URL {
        guard var components = URLComponents(url: ping.url, resolvingAgainstBaseURL: false) else { return ping.url }
        if let host = components.host?.lowercased(), rewrittenHosts.contains(host) {
            components.host = pingHost
        }

        let mediaTime = format(ping.mediaTime)
        var added: [URLQueryItem] = [
            URLQueryItem(name: "ver", value: version),
            URLQueryItem(name: "c", value: clientName),
            URLQueryItem(name: "cpn", value: encode(ping.cpn)),
            URLQueryItem(name: "cver", value: encode(clientVersion)),
            URLQueryItem(name: "cmt", value: mediaTime),
        ]
        if ping.kind == .watchtime {
            added += [
                URLQueryItem(name: "st", value: "0"),
                URLQueryItem(name: "et", value: mediaTime),
            ]
        }
        let names = Set(added.map(\.name))
        // Existing items keep their exact encoding; a repeated name is replaced rather than duplicated.
        let kept = (components.percentEncodedQueryItems ?? []).filter { !names.contains($0.name) }
        // YouTube's own `el` wins: the real tracking URLs carry one already.
        if !kept.contains(where: { $0.name == "el" }) {
            added.append(URLQueryItem(name: "el", value: defaultEntryPoint))
        }
        components.percentEncodedQueryItems = kept + added
        return components.url ?? ping.url
    }

    /// Seconds with three decimals; a negative or non-finite time is sent as zero.
    private static func format(_ seconds: TimeInterval) -> String {
        String(format: "%.3f", seconds.isFinite ? max(0, seconds) : 0)
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }
}
