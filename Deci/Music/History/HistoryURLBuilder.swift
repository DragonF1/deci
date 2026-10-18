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
        var replaced = Set(added.map(\.name))
        if ping.kind == .watchtime {
            if let details = ping.details {
                added += watchtimeItems(for: details, mediaTime: mediaTime)
                // The ping speaks for all of these, present or not: one the base URL carries would be stale.
                replaced.formUnion(watchtimeNames)
            } else {
                added += [
                    URLQueryItem(name: "st", value: "0"),
                    URLQueryItem(name: "et", value: mediaTime),
                ]
                replaced.formUnion(["st", "et"])
            }
        }
        // Existing items keep their exact encoding; a repeated name is replaced rather than duplicated.
        let kept = (components.percentEncodedQueryItems ?? []).filter { !replaced.contains($0.name) }
        // YouTube's own `el` wins: the real tracking URLs carry one already.
        if !kept.contains(where: { $0.name == "el" }) {
            added.append(URLQueryItem(name: "el", value: defaultEntryPoint))
        }
        components.percentEncodedQueryItems = kept + added
        return components.url ?? ping.url
    }

    /// Everything `watchtimeItems` can add, so a base URL's own copy of any of them is dropped.
    private static let watchtimeNames: Set<String> = [
        "st", "et", "rt", "rtn", "rti", "lact", "state", "volume", "muted", "final",
    ]

    /// The parameters only the web player's watchtime ping has, in its order. Lists are comma-joined (then percent-encoded
    /// like any value), one entry per stretch. A ping with no stretch reports the one it had before there were any:
    /// from 0 to the media time.
    private static func watchtimeItems(for details: WatchtimeDetails, mediaTime: String) -> [URLQueryItem] {
        let segments = details.segments
        let starts = segments.isEmpty ? ["0.000"] : segments.map { format($0.start) }
        let ends = segments.isEmpty ? [mediaTime] : segments.map { format($0.end) }
        var items = [
            URLQueryItem(name: "st", value: encode(starts.joined(separator: ","))),
            URLQueryItem(name: "et", value: encode(ends.joined(separator: ","))),
            URLQueryItem(name: "rt", value: format(details.realTime)),
        ]
        if let next = details.nextRealTime { items.append(URLQueryItem(name: "rtn", value: format(next))) }
        if let due = details.scheduledRealTime { items.append(URLQueryItem(name: "rti", value: format(due))) }
        items += [
            URLQueryItem(name: "lact", value: String(max(0, details.idleMilliseconds))),
            URLQueryItem(name: "state", value: details.isPlaying ? "playing" : "paused"),
            URLQueryItem(name: "volume", value: encode(segments.isEmpty ? "100" : segments.map { String($0.volume) }.joined(separator: ","))),
            URLQueryItem(name: "muted", value: encode(segments.isEmpty ? "0" : segments.map { $0.muted ? "1" : "0" }.joined(separator: ","))),
        ]
        if details.isFinal { items.append(URLQueryItem(name: "final", value: "1")) }
        return items
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
