import CryptoKit
import Foundation

/// What the music.youtube.com home page tells a client about the current web build.
struct BootstrapConfig: Sendable, Equatable {
    var clientVersion: String?
    var visitorData: String?
    var playerJSURL: URL?
    /// Whether the page was served to a brand channel. History pings land on this identity.
    var isBrandChannel: Bool?
    /// The brand channel's page id, which API calls name as `onBehalfOfUser`; nil on the account's own
    /// channel. An account id: never logged.
    var brandPageId: String?
    /// An opaque key for the signed-in channel (see `InnerTubeParser.channelKey`), so a saved session can tell
    /// whose it is. Never the id itself.
    var channelKey: String?
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
    /// videoDetails.viewCount, which YouTube sends as a numeric string; nil when it is missing or not a number.
    let viewCount: Int?
    let playbackTrackingURL: URL?
    let watchtimeTrackingURL: URL?
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
        let dataSyncId = string(merged["DATASYNC_ID"])
        return BootstrapConfig(
            clientVersion: string(merged["INNERTUBE_CLIENT_VERSION"]) ?? string(client?["clientVersion"]),
            visitorData: string(merged["VISITOR_DATA"]) ?? string(client?["visitorData"]),
            playerJSURL: jsPath.flatMap { URL(string: $0, relativeTo: baseURL)?.absoluteURL },
            isBrandChannel: dataSyncId.flatMap(isBrandChannel(dataSyncId:)),
            brandPageId: brandPageId(delegatedSessionId: string(merged["DELEGATED_SESSION_ID"]), dataSyncId: dataSyncId),
            channelKey: channelKey(dataSyncId: dataSyncId)
        )
    }

    /// The first 8 bytes of the SHA-256 of `DATASYNC_ID`, as hex. Stable per channel (the brand and the own channel
    /// of one account differ) and safe to write to disk or compare, because the id cannot be read back from it.
    static func channelKey(dataSyncId: String?) -> String? {
        guard let dataSyncId, !dataSyncId.isEmpty else { return nil }
        return SHA256.hash(data: Data(dataSyncId.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// `DELEGATED_SESSION_ID` when the page has it, else the brand half of a brand channel's `DATASYNC_ID`.
    /// Nil on the account's own channel.
    static func brandPageId(delegatedSessionId: String?, dataSyncId: String?) -> String? {
        if let delegatedSessionId, !delegatedSessionId.isEmpty { return delegatedSessionId }
        guard let dataSyncId, isBrandChannel(dataSyncId: dataSyncId) == true,
              let separator = dataSyncId.range(of: "||") else { return nil }
        return String(dataSyncId[..<separator.lowerBound])
    }

    /// `DATASYNC_ID` reads `<brand id>||<user id>` on a brand channel and `<user id>||` on the
    /// account's own channel. Nil when it is neither shape.
    static func isBrandChannel(dataSyncId: String) -> Bool? {
        guard let separator = dataSyncId.range(of: "||"), separator.lowerBound > dataSyncId.startIndex else { return nil }
        return separator.upperBound < dataSyncId.endIndex
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

    /// The track an unfiltered search names as its Top result, which the songs filter can leave out (an uploaded
    /// video). The Top result is a card whose title runs carry the watch endpoint when it is a song or video; an
    /// artist, album or playlist card has none, so there is no track. A response with no card at all falls back to the
    /// first row of a shelf titled "Top result", the older shape.
    static func searchTopResult(from data: Data) throws -> MusicTrack? {
        let root = try jsonObject(data, what: "search response")
        var cards: [[String: Any]] = []
        collect("musicCardShelfRenderer", in: root, into: &cards)
        if let card = cards.first { return topTrack(fromCard: card) }

        var shelves: [[String: Any]] = []
        collect("musicShelfRenderer", in: root, into: &shelves)
        let top = shelves.first { text(of: runs(path($0, "title"))) == "Top result" }
        let first = (top?["contents"] as? [[String: Any]])?.first
        return (first?["musicResponsiveListItemRenderer"] as? [String: Any]).flatMap(track(from:))
    }

    private static func topTrack(fromCard card: [String: Any]) -> MusicTrack? {
        let titleRuns = runs(card["title"])
        guard let videoId = string(path(titleRuns.first, "navigationEndpoint", "watchEndpoint", "videoId")),
              !videoId.isEmpty,
              let title = text(of: titleRuns)
        else { return nil }
        let subtitle = parseSubtitle(runs(card["subtitle"]))
        return MusicTrack(
            videoId: videoId,
            title: title,
            artist: subtitle.artists.joined(separator: ", "),
            album: subtitle.album,
            durationSeconds: subtitle.durationSeconds,
            thumbnailURL: thumbnailURL(in: card),
            artistLinks: subtitle.artistLinks,
            albumBrowseId: subtitle.albumBrowseId
        )
    }

    static func collect(_ key: String, in node: Any, into found: inout [[String: Any]]) {
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

    static func track(from renderer: [String: Any]) -> MusicTrack? {
        let columns = (renderer["flexColumns"] as? [[String: Any]] ?? []).map { column in
            ((column["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any])?["text"] as? [String: Any])?["runs"] as? [[String: Any]] ?? []
        }
        guard let videoId = videoId(in: renderer, titleRuns: columns.first ?? []) else { return nil }
        let title = (columns.first ?? []).compactMap { $0["text"] as? String }.joined()
        guard !title.isEmpty else { return nil }

        let subtitle = parseSubtitle(columns.count > 1 ? columns[1] : [])
        // Playlist and album rows keep the length in a fixed column and the album in a later flex
        // column (the third, or the fourth after a play count on an artist page); search rows carry
        // both in the second column instead. The play count, where a row shows one, sits in a column of its own.
        let fixed = (renderer["fixedColumns"] as? [[String: Any]])?.first
        let fixedRuns = runs(path(fixed, "musicResponsiveListItemFixedColumnRenderer", "text"))
        let laterColumnAlbum = columns.dropFirst(2).first(where: isAlbumSegment)
        // The album's page comes from its run, else from the row menu's "Go to album" item.
        let options = rowOptions(in: renderer)
        return MusicTrack(
            videoId: videoId,
            title: title,
            artist: subtitle.artists.joined(separator: ", "),
            album: subtitle.album ?? laterColumnAlbum.flatMap(text(of:)),
            durationSeconds: subtitle.durationSeconds ?? duration(of: fixedRuns),
            thumbnailURL: thumbnailURL(in: renderer),
            artistLinks: subtitle.artistLinks,
            albumBrowseId: subtitle.albumBrowseId ?? laterColumnAlbum.flatMap(albumBrowseId(in:)) ?? options.albumBrowseId,
            playlistSetVideoId: options.setVideoId ?? string(path(renderer, "playlistItemData", "playlistSetVideoId")),
            plays: playCount(in: columns)
        )
    }

    /// The play count a row shows after its title: a column of its own ("2B plays"), or one part of a column that has
    /// bullets between its parts.
    private static func playCount(in columns: [[[String: Any]]]) -> Int? {
        for column in columns.dropFirst() {
            for segment in bulletSegments(of: column) {
                if let plays = text(of: segment).flatMap(playCount(from:)) { return plays }
            }
        }
        return nil
    }

    /// The number in a play count such as "2B plays", "271M plays", "1.2K plays", "1,234 plays" or "1 play". The word
    /// "plays" must follow, so a view count ("2B views"), a length or a bare number is never taken, and so must a
    /// number YouTube would not write (a comma that does not split thousands, a decimal with no K, M or B, a number
    /// too large to hold). A fraction past the thousandth, millionth or billionth of the suffix is dropped.
    static func playCount(from text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = trimmed.wholeMatch(of: /(\d{1,3}(?:,\d{3})+|\d+)(?:\.(\d+))?([KMB])?\s+plays?/.ignoresCase()) else {
            return nil
        }
        let scale = ["K": 1_000, "M": 1_000_000, "B": 1_000_000_000][match.3?.uppercased() ?? ""] ?? 1
        let fraction = match.2.map(String.init) ?? ""
        guard fraction.isEmpty || scale > 1, let whole = Int(match.1.replacingOccurrences(of: ",", with: "")) else {
            return nil
        }
        let places = String(scale).count - 1
        let fractional = Int(String((fraction + String(repeating: "0", count: places)).prefix(places))) ?? 0
        let (scaled, scaledOverflow) = whole.multipliedReportingOverflow(by: scale)
        let (total, totalOverflow) = scaled.addingReportingOverflow(fractional)
        return scaledOverflow || totalOverflow ? nil : total
    }

    static func videoId(in renderer: [String: Any], titleRuns: [[String: Any]]) -> String? {
        if let id = string((renderer["playlistItemData"] as? [String: Any])?["videoId"]) { return id }
        let endpoint = (titleRuns.first?["navigationEndpoint"] as? [String: Any])?["watchEndpoint"] as? [String: Any]
        if let id = string(endpoint?["videoId"]) { return id }
        return string(path(renderer, "overlay", "musicItemThumbnailOverlayRenderer", "content", "musicPlayButtonRenderer", "playNavigationEndpoint", "watchEndpoint", "videoId"))
    }

    struct Subtitle {
        var artists: [String] = []
        /// The artists above that have a page, in the order shown.
        var artistLinks: [MusicArtistLink] = []
        var album: String?
        /// The album's page, when its run links to one.
        var albumBrowseId: String?
        var durationSeconds: Int?
    }

    /// Splits "Artist, Artist & Artist • Album • 3:05" into its parts. The bullet runs separate
    /// segments; the artist segment also has comma and ampersand separator runs.
    static func parseSubtitle(_ runs: [[String: Any]]) -> Subtitle {
        var segments = bulletSegments(of: runs)

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
            result.artists = artistNames(in: artistSegment)
            result.artistLinks = artistLinks(in: artistSegment)
        }
        if segments.count > 1, let album = segments.dropFirst().first(where: isAlbumSegment) {
            result.album = text(of: album)
            result.albumBrowseId = albumBrowseId(in: album)
        }
        return result
    }

    static func bulletSegments(of runs: [[String: Any]]) -> [[[String: Any]]] {
        var segments: [[[String: Any]]] = [[]]
        for run in runs {
            if (run["text"] as? String)?.trimmingCharacters(in: .whitespaces) == "\u{2022}" {
                segments.append([])
            } else {
                segments[segments.count - 1].append(run)
            }
        }
        segments.removeAll { $0.isEmpty }
        return segments
    }

    static func artistNames(in segment: [[String: Any]]) -> [String] {
        segment.compactMap { run in
            guard let text = (run["text"] as? String)?.trimmingCharacters(in: .whitespaces),
                  !text.isEmpty, text != ",", text != "&"
            else { return nil }
            return text
        }
    }

    /// The artists in `segment` that have a page behind them: a run whose destination is an artist, or a library
    /// artist (which opens the channel page, as everywhere else). Each artist once, in the order shown. A name with
    /// no destination, or with a page of another kind (album, playlist, user channel), has no link.
    static func artistLinks(in segment: [[String: Any]]) -> [MusicArtistLink] {
        var seen = Set<String>()
        return segment.compactMap { run in
            guard let name = (run["text"] as? String)?.trimmingCharacters(in: .whitespaces),
                  !name.isEmpty, name != ",", name != "&",
                  let browse = path(run, "navigationEndpoint", "browseEndpoint") as? [String: Any],
                  collectionKind(of: browse) == .artist,
                  var browseId = string(browse["browseId"])
            else { return nil }
            if browseId.hasPrefix("MPLAUC") { browseId.removeFirst(4) }
            return seen.insert(browseId).inserted ? MusicArtistLink(name: name, browseId: browseId) : nil
        }
    }

    static func text(of segment: [[String: Any]]) -> String? {
        let joined = segment.compactMap { $0["text"] as? String }.joined().trimmingCharacters(in: .whitespaces)
        return joined.isEmpty ? nil : joined
    }

    static func isAlbumSegment(_ segment: [[String: Any]]) -> Bool {
        segment.contains { run in
            let browse = (run["navigationEndpoint"] as? [String: Any])?["browseEndpoint"] as? [String: Any]
            let configs = browse?["browseEndpointContextSupportedConfigs"] as? [String: Any]
            let music = configs?["browseEndpointContextMusicConfig"] as? [String: Any]
            return string(music?["pageType"]) == "MUSIC_PAGE_TYPE_ALBUM"
        }
    }

    /// "3:05" or "1:02:03" in seconds.
    static func duration(of segment: [[String: Any]]) -> Int? {
        guard let text = text(of: segment), text.wholeMatch(of: /\d{1,2}(?::\d{2}){1,2}/) != nil else { return nil }
        return text.split(separator: ":").reduce(0) { $0 * 60 + (Int($1) ?? 0) }
    }

    /// The thumbnail nearest 120 px, which is what a list row needs.
    static func thumbnailURL(in renderer: [String: Any]) -> URL? {
        let thumbnail = ((renderer["thumbnail"] as? [String: Any])?["musicThumbnailRenderer"] as? [String: Any])?["thumbnail"] as? [String: Any]
        let candidates = thumbnail?["thumbnails"] as? [[String: Any]] ?? []
        let best = candidates.min { lhs, rhs in
            abs((int(lhs["width"]) ?? 1_000) - 120) < abs((int(rhs["width"]) ?? 1_000) - 120)
        }
        return string(best?["url"]).flatMap { URL(string: $0) }
    }

    // MARK: - Radio queue

    /// The first page of a radio: `next` called with a seed video.
    static func radioPage(from data: Data) throws -> MusicQueuePage {
        let root = try jsonObject(data, what: "radio response")
        return try queuePage(in: radioPanel(in: root), what: "radio response")
    }

    /// Where the automix of a playlist goes on: the preview row YouTube puts last in the queue panel of the playlist's
    /// `next` response, which is not a song. Nil when the panel has no such row. A response without the queue panel is a
    /// parse error, like `radioPage`.
    static func automixEndpoint(from data: Data) throws -> MusicAutomixEndpoint? {
        let root = try jsonObject(data, what: "radio response")
        guard let panel = radioPanel(in: root) else { throw MusicError.parse("radio response has no queue") }
        let last = (panel["contents"] as? [Any])?.last
        let endpoint = path(last, "automixPreviewVideoRenderer", "content", "automixPlaylistVideoRenderer", "navigationEndpoint", "watchPlaylistEndpoint")
        guard let playlistId = string(path(endpoint, "playlistId")) else { return nil }
        // The params are posted back as they came, percent escapes and all.
        return MusicAutomixEndpoint(playlistId: playlistId, params: string(path(endpoint, "params")))
    }

    private static func radioPanel(in root: [String: Any]) -> [String: Any]? {
        let tabs = path(root, "contents", "singleColumnMusicWatchNextResultsRenderer", "tabbedRenderer", "watchNextTabbedResultsRenderer", "tabs") as? [Any]
        return path(tabs?.first, "tabRenderer", "content", "musicQueueRenderer", "content", "playlistPanelRenderer") as? [String: Any]
    }

    /// A later page: `next` called with a continuation token.
    static func radioContinuationPage(from data: Data) throws -> MusicQueuePage {
        let root = try jsonObject(data, what: "radio continuation")
        let panel = path(root, "continuationContents", "playlistPanelContinuation")
        return try queuePage(in: panel as? [String: Any], what: "radio continuation")
    }

    /// The two parsers each accept only their own shape. A rejected token comes back as a
    /// first-page-shaped response, and an empty queue would hide that, so a missing panel is an error.
    private static func queuePage(in panel: [String: Any]?, what: String) throws -> MusicQueuePage {
        guard let panel else { throw MusicError.parse("\(what) has no queue") }
        let items = panel["contents"] as? [[String: Any]] ?? []
        return MusicQueuePage(tracks: items.compactMap(queueTrack(from:)), continuation: queueContinuation(in: panel))
    }

    private static func queueTrack(from item: [String: Any]) -> MusicTrack? {
        let wrapped = path(item, "playlistPanelVideoWrapperRenderer", "primaryRenderer", "playlistPanelVideoRenderer")
        guard let renderer = (item["playlistPanelVideoRenderer"] ?? wrapped) as? [String: Any],
              let videoId = string(renderer["videoId"]) ?? string(path(renderer, "navigationEndpoint", "watchEndpoint", "videoId"))
        else { return nil }
        let title = runs(renderer["title"]).compactMap { $0["text"] as? String }.joined()
        guard !title.isEmpty else { return nil }

        let segments = bulletSegments(of: runs(renderer["longBylineText"]))
        let albumSegment = segments.dropFirst().first(where: isAlbumSegment)
        let options = rowOptions(in: renderer)
        return MusicTrack(
            videoId: videoId,
            title: title,
            artist: artistNames(in: segments.first ?? []).joined(separator: ", "),
            album: albumSegment.flatMap(text(of:)),
            durationSeconds: duration(of: runs(renderer["lengthText"])),
            thumbnailURL: largestThumbnailURL(in: renderer),
            artistLinks: artistLinks(in: segments.first ?? []),
            albumBrowseId: albumSegment.flatMap(albumBrowseId(in:)) ?? options.albumBrowseId
        )
    }

    private static func queueContinuation(in panel: [String: Any]) -> String? {
        for entry in panel["continuations"] as? [[String: Any]] ?? [] {
            for key in ["nextRadioContinuationData", "nextContinuationData"] {
                if let token = string((entry[key] as? [String: Any])?["continuation"]) { return token }
            }
        }
        return nil
    }

    /// Queue rows list their thumbnails directly, and the player shows the art large.
    private static func largestThumbnailURL(in renderer: [String: Any]) -> URL? {
        let candidates = (renderer["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]] ?? []
        let best = candidates.max { (int($0["width"]) ?? 0) < (int($1["width"]) ?? 0) }
        return string(best?["url"]).flatMap { URL(string: $0) }
    }

    static func runs(_ text: Any?) -> [[String: Any]] {
        (text as? [String: Any])?["runs"] as? [[String: Any]] ?? []
    }

    // MARK: - Player

    static func playerResponse(from data: Data) throws -> PlayerResponse {
        let root = try jsonObject(data, what: "player response")
        let playability = root["playabilityStatus"] as? [String: Any]
        let streaming = root["streamingData"] as? [String: Any]
        let formats = (streaming?["adaptiveFormats"] as? [[String: Any]] ?? []).compactMap(format(from:))
        let tracking = root["playbackTracking"] as? [String: Any]
        let details = root["videoDetails"] as? [String: Any]
        return PlayerResponse(
            status: string(playability?["status"]) ?? "UNKNOWN",
            reason: reason(in: playability),
            formats: formats,
            expiresInSeconds: int(streaming?["expiresInSeconds"]),
            lengthSeconds: int(details?["lengthSeconds"]),
            viewCount: int(details?["viewCount"]),
            playbackTrackingURL: trackingURL(tracking?["videostatsPlaybackUrl"]),
            watchtimeTrackingURL: trackingURL(tracking?["videostatsWatchtimeUrl"])
        )
    }

    /// `baseUrl` of one playbackTracking entry.
    private static func trackingURL(_ entry: Any?) -> URL? {
        string((entry as? [String: Any])?["baseUrl"]).flatMap { URL(string: $0) }
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

    static func jsonObject(_ data: Data, what: String) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MusicError.parse("\(what) is not a JSON object")
        }
        return object
    }

    static func path(_ node: Any?, _ keys: String...) -> Any? {
        var current = node
        for key in keys { current = (current as? [String: Any])?[key] }
        return current
    }

    static func string(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }

    static func int(_ value: Any?) -> Int? {
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
