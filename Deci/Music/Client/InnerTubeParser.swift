import Foundation

/// What the music.youtube.com home page tells a client about the current web build.
struct BootstrapConfig: Sendable, Equatable {
    var clientVersion: String?
    var visitorData: String?
    var playerJSURL: URL?
}

struct PlayerFormat: Sendable, Equatable {
    let itag: Int
    let mimeType: String
    let bitrate: Int?
    let url: String?
    let signatureCipher: String?
    let approxDurationMs: Double?
}

struct PlayerResponse: Sendable, Equatable {
    /// playabilityStatus.status, or "UNKNOWN" when the response has none.
    let status: String
    let reason: String?
    let formats: [PlayerFormat]
    let expiresInSeconds: Int?
    let lengthSeconds: Int?
    let playbackTrackingURL: URL?
}

/// Pure parsing of the InnerTube responses. Every lookup tolerates a missing or re-shaped
/// field, because YouTube changes these payloads without notice.
enum InnerTubeParser {
    private static let baseURL = URL(string: "https://music.youtube.com")!

    // MARK: - Bootstrap page

    static func bootstrapConfig(fromHTML html: String) -> BootstrapConfig {
        var merged: [String: Any] = [:]
        for block in ytcfgBlocks(in: html) {
            guard let data = block.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            merged.merge(object) { _, later in later }
        }
        let client = (merged["INNERTUBE_CONTEXT"] as? [String: Any]).flatMap { $0["client"] as? [String: Any] }

        let jsPath = string(merged["PLAYER_JS_URL"])
            ?? nestedPlayerJS(in: merged)
            ?? firstJSURL(in: html)
        return BootstrapConfig(
            clientVersion: string(merged["INNERTUBE_CLIENT_VERSION"]) ?? string(client?["clientVersion"]),
            visitorData: string(merged["VISITOR_DATA"]) ?? string(client?["visitorData"]),
            playerJSURL: jsPath.flatMap { URL(string: $0, relativeTo: baseURL)?.absoluteURL }
        )
    }

    /// The JSON object literal of every `ytcfg.set({...})` call, found by balancing braces
    /// outside of string literals. Blocks that are not JSON are rejected later by the caller.
    private static func ytcfgBlocks(in html: String) -> [String] {
        var blocks: [String] = []
        var cursor = html.startIndex
        while let call = html.range(of: "ytcfg.set(", range: cursor..<html.endIndex) {
            cursor = call.upperBound
            var start = call.upperBound
            while start < html.endIndex, html[start].isWhitespace { start = html.index(after: start) }
            guard start < html.endIndex, html[start] == "{", let end = balancedEnd(of: html, from: start) else { continue }
            blocks.append(String(html[start...end]))
            cursor = html.index(after: end)
        }
        return blocks
    }

    private static func balancedEnd(of text: String, from start: String.Index) -> String.Index? {
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if inString {
                if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { inString = false }
            } else if character == "\"" {
                inString = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 { return index }
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func nestedPlayerJS(in config: [String: Any]) -> String? {
        guard let contexts = config["WEB_PLAYER_CONTEXT_CONFIGS"] as? [String: Any] else { return nil }
        for key in contexts.keys.sorted() {
            if let path = string((contexts[key] as? [String: Any])?["jsUrl"]) { return path }
        }
        return nil
    }

    private static func firstJSURL(in html: String) -> String? {
        html.firstMatch(of: /"jsUrl"\s*:\s*"([^"]+)"/).map { String($0.1) }
    }

    // MARK: - Player JS

    /// The 8-hex-digit id in `/s/player/<id>/...`.
    static func playerHash(fromPlayerJSURL url: URL) -> String? {
        let parts = url.pathComponents
        guard let index = parts.firstIndex(of: "player"), index > 0, parts[index - 1] == "s", index + 1 < parts.count else { return nil }
        let hash = parts[index + 1]
        return hash.isEmpty ? nil : hash
    }

    static func signatureTimestamp(fromPlayerJS js: String) -> Int? {
        if let match = js.firstMatch(of: /\bsignatureTimestamp\s*:\s*(\d+)/) { return Int(match.1) }
        if let match = js.firstMatch(of: /\bsts\s*:\s*(\d+)/) { return Int(match.1) }
        return nil
    }

    // MARK: - Search

    static func searchTracks(from data: Data) throws -> [MusicTrack] {
        let root = try jsonObject(data, what: "search response")
        var renderers: [[String: Any]] = []
        collect("musicResponsiveListItemRenderer", in: root, into: &renderers)
        return renderers.compactMap(track(from:))
    }

    private static func collect(_ key: String, in node: Any, into found: inout [[String: Any]]) {
        if let dictionary = node as? [String: Any] {
            if let match = dictionary[key] as? [String: Any] {
                found.append(match)
                return
            }
            for child in dictionary.values { collect(key, in: child, into: &found) }
        } else if let array = node as? [Any] {
            for child in array { collect(key, in: child, into: &found) }
        }
    }

    private static func track(from renderer: [String: Any]) -> MusicTrack? {
        let columns = (renderer["flexColumns"] as? [[String: Any]] ?? []).map { column in
            ((column["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any])?["text"] as? [String: Any])?["runs"] as? [[String: Any]] ?? []
        }
        guard let videoId = videoId(in: renderer, titleRuns: columns.first ?? []) else { return nil }
        let title = (columns.first ?? []).compactMap { $0["text"] as? String }.joined()
        guard !title.isEmpty else { return nil }

        let subtitle = parseSubtitle(columns.count > 1 ? columns[1] : [])
        return MusicTrack(
            videoId: videoId,
            title: title,
            artist: subtitle.artists.joined(separator: ", "),
            album: subtitle.album,
            durationSeconds: subtitle.durationSeconds,
            thumbnailURL: thumbnailURL(in: renderer)
        )
    }

    private static func videoId(in renderer: [String: Any], titleRuns: [[String: Any]]) -> String? {
        if let id = string((renderer["playlistItemData"] as? [String: Any])?["videoId"]) { return id }
        let endpoint = (titleRuns.first?["navigationEndpoint"] as? [String: Any])?["watchEndpoint"] as? [String: Any]
        return string(endpoint?["videoId"])
    }

    private struct Subtitle {
        var artists: [String] = []
        var album: String?
        var durationSeconds: Int?
    }

    /// Splits "Artist, Artist & Artist • Album • 3:05" into its parts. The bullet runs separate
    /// segments; the artist segment also has comma and ampersand separator runs.
    private static func parseSubtitle(_ runs: [[String: Any]]) -> Subtitle {
        var segments: [[[String: Any]]] = [[]]
        for run in runs {
            if (run["text"] as? String)?.trimmingCharacters(in: .whitespaces) == "\u{2022}" {
                segments.append([])
            } else {
                segments[segments.count - 1].append(run)
            }
        }
        segments.removeAll { $0.isEmpty }

        var result = Subtitle()
        if segments.count > 1, let last = segments.last, let seconds = duration(of: last) {
            result.durationSeconds = seconds
            segments.removeLast()
        }
        // An unfiltered search prefixes the kind of result ("Song", "Video").
        if segments.count > 1, let label = text(of: segments[0]), ["Song", "Video"].contains(label) {
            segments.removeFirst()
        }
        if let artistSegment = segments.first {
            result.artists = artistSegment.compactMap { run in
                guard let text = (run["text"] as? String)?.trimmingCharacters(in: .whitespaces),
                      !text.isEmpty, text != ",", text != "&"
                else { return nil }
                return text
            }
        }
        if segments.count > 1, let album = segments.dropFirst().first(where: isAlbumSegment) {
            result.album = text(of: album)
        }
        return result
    }

    private static func text(of segment: [[String: Any]]) -> String? {
        let joined = segment.compactMap { $0["text"] as? String }.joined().trimmingCharacters(in: .whitespaces)
        return joined.isEmpty ? nil : joined
    }

    private static func isAlbumSegment(_ segment: [[String: Any]]) -> Bool {
        segment.contains { run in
            let browse = (run["navigationEndpoint"] as? [String: Any])?["browseEndpoint"] as? [String: Any]
            let configs = browse?["browseEndpointContextSupportedConfigs"] as? [String: Any]
            let music = configs?["browseEndpointContextMusicConfig"] as? [String: Any]
            return string(music?["pageType"]) == "MUSIC_PAGE_TYPE_ALBUM"
        }
    }

    /// "3:05" or "1:02:03" in seconds.
    private static func duration(of segment: [[String: Any]]) -> Int? {
        guard let text = text(of: segment), text.wholeMatch(of: /\d{1,2}(?::\d{2}){1,2}/) != nil else { return nil }
        return text.split(separator: ":").reduce(0) { $0 * 60 + (Int($1) ?? 0) }
    }

    /// The thumbnail nearest 120 px, which is what a list row needs.
    private static func thumbnailURL(in renderer: [String: Any]) -> URL? {
        let thumbnail = ((renderer["thumbnail"] as? [String: Any])?["musicThumbnailRenderer"] as? [String: Any])?["thumbnail"] as? [String: Any]
        let candidates = thumbnail?["thumbnails"] as? [[String: Any]] ?? []
        let best = candidates.min { lhs, rhs in
            abs((int(lhs["width"]) ?? 1_000) - 120) < abs((int(rhs["width"]) ?? 1_000) - 120)
        }
        return string(best?["url"]).flatMap { URL(string: $0) }
    }

    // MARK: - Player

    static func playerResponse(from data: Data) throws -> PlayerResponse {
        let root = try jsonObject(data, what: "player response")
        let playability = root["playabilityStatus"] as? [String: Any]
        let streaming = root["streamingData"] as? [String: Any]
        let formats = (streaming?["adaptiveFormats"] as? [[String: Any]] ?? []).compactMap(format(from:))
        let tracking = (root["playbackTracking"] as? [String: Any])?["videostatsPlaybackUrl"] as? [String: Any]
        return PlayerResponse(
            status: string(playability?["status"]) ?? "UNKNOWN",
            reason: reason(in: playability),
            formats: formats,
            expiresInSeconds: int(streaming?["expiresInSeconds"]),
            lengthSeconds: int((root["videoDetails"] as? [String: Any])?["lengthSeconds"]),
            playbackTrackingURL: string(tracking?["baseUrl"]).flatMap { URL(string: $0) }
        )
    }

    private static func format(from json: [String: Any]) -> PlayerFormat? {
        guard let itag = int(json["itag"]) else { return nil }
        return PlayerFormat(
            itag: itag,
            mimeType: string(json["mimeType"]) ?? "",
            bitrate: int(json["bitrate"]),
            url: string(json["url"]),
            signatureCipher: string(json["signatureCipher"]) ?? string(json["cipher"]),
            approxDurationMs: double(json["approxDurationMs"])
        )
    }

    private static func reason(in playability: [String: Any]?) -> String? {
        if let reason = string(playability?["reason"]) { return reason }
        let message = ((playability?["errorScreen"] as? [String: Any])?["playerErrorMessageRenderer"] as? [String: Any])?["reason"] as? [String: Any]
        if let simple = string(message?["simpleText"]) { return simple }
        let runs = (message?["runs"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined()
        return runs?.isEmpty == false ? runs : nil
    }

    // MARK: - JSON helpers

    private static func jsonObject(_ data: Data, what: String) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MusicError.parse("\(what) is not a JSON object")
        }
        return object
    }

    private static func string(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }

    private static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }

    private static func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }
}
