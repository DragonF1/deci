// Deci/Music/Client/InnerTubeParser+Browse.swift
// Home, library and playlist/album/artist pages from the `browse` endpoint, and their continuations.
import Foundation

extension InnerTubeParser {

    // MARK: - Continuation tokens

    /// How a continuation token goes back to YouTube. The old style (`nextContinuationData`) is sent
    /// as `ctoken` and `continuation` query parameters next to the original `browseId`; the new style
    /// (`continuationItemRenderer`) is sent as `continuation` in the body, alone.
    enum ContinuationStyle: Equatable {
        case query
        case body
    }

    struct ContinuationToken: Equatable {
        let value: String
        let style: ContinuationStyle
    }

    /// The contract passes a continuation around as one opaque string, so the old style carries
    /// this prefix and a bare token is body style. Real tokens are base64 and never contain a colon.
    static let queryTokenPrefix = "q:"

    static func encodeContinuation(_ token: String, style: ContinuationStyle) -> String {
        style == .query ? queryTokenPrefix + token : token
    }

    /// Nil for a blank token.
    static func decodeContinuation(_ raw: String) -> ContinuationToken? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(queryTokenPrefix) {
            let value = String(trimmed.dropFirst(queryTokenPrefix.count))
            return value.isEmpty ? nil : ContinuationToken(value: value, style: .query)
        }
        return trimmed.isEmpty ? nil : ContinuationToken(value: trimmed, style: .body)
    }

    /// The token for the page after `items`: the container's `nextContinuationData` (old style) or
    /// the trailing `continuationItemRenderer` (new style). Pass the shelf or grid that holds the
    /// items; a page's own section list continues with related shelves, not with more items.
    static func continuationToken(in container: [String: Any]?, items: [[String: Any]]) -> String? {
        for entry in container?["continuations"] as? [[String: Any]] ?? [] {
            for key in ["nextContinuationData", "reloadContinuationData"] {
                if let token = string((entry[key] as? [String: Any])?["continuation"]) {
                    return encodeContinuation(token, style: .query)
                }
            }
        }
        for item in items.reversed() {
            if let token = string(path(item, "continuationItemRenderer", "continuationEndpoint", "continuationCommand", "token")) {
                return encodeContinuation(token, style: .body)
            }
        }
        return nil
    }

    // MARK: - Home

    static func homePage(from data: Data) throws -> MusicHomePage {
        let root = try jsonObject(data, what: "home response")
        var lists: [[String: Any]] = []
        collect("sectionListRenderer", in: root, into: &lists)
        guard let list = lists.first else { throw MusicError.parse("home response has no shelves") }
        let contents = list["contents"] as? [[String: Any]] ?? []
        return MusicHomePage(
            shelves: contents.compactMap(shelf(from:)),
            continuation: continuationToken(in: list, items: contents)
        )
    }

    static func homeContinuationPage(from data: Data) throws -> MusicHomePage {
        let root = try jsonObject(data, what: "home continuation")
        guard let payload = continuationPayload(in: root, keys: ["sectionListContinuation"]) else {
            throw MusicError.parse("home continuation has no shelves")
        }
        return MusicHomePage(
            shelves: payload.items.compactMap(shelf(from:)),
            continuation: continuationToken(in: payload.container, items: payload.items)
        )
    }

    /// A carousel (or a plain shelf) with a title and at least one item Deci can show.
    static func shelf(from entry: [String: Any]) -> MusicShelf? {
        let renderer: [String: Any]
        let titleRuns: [[String: Any]]
        if let carousel = (entry["musicCarouselShelfRenderer"] ?? entry["musicImmersiveCarouselShelfRenderer"]) as? [String: Any] {
            renderer = carousel
            titleRuns = runs(carouselHeader(of: carousel)?["title"])
        } else if let list = entry["musicShelfRenderer"] as? [String: Any] {
            renderer = list
            titleRuns = runs(list["title"])
        } else {
            return nil
        }
        guard let title = text(of: titleRuns) else { return nil }
        let items = uniqueItems((renderer["contents"] as? [[String: Any]] ?? []).compactMap(shelfItem(from:)))
        return items.isEmpty ? nil : MusicShelf(title: title, items: items)
    }

    /// The header's single `...ShelfBasicHeaderRenderer`, whichever of the carousel flavours it is.
    private static func carouselHeader(of carousel: [String: Any]) -> [String: Any]? {
        let header = carousel["header"] as? [String: Any]
        for key in ["musicCarouselShelfBasicHeaderRenderer", "musicImmersiveCarouselShelfBasicHeaderRenderer"] {
            if let match = header?[key] as? [String: Any] { return match }
        }
        return header?.values.lazy.compactMap { $0 as? [String: Any] }.first
    }

    private static func uniqueItems(_ items: [MusicShelfItem]) -> [MusicShelfItem] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.id).inserted }
    }

    // MARK: - Library

    /// A library list: playlists and albums are a grid of tiles, artists a shelf of rows, possibly
    /// inside an item section. An empty library has neither, which is an empty list and not an error.
    static func libraryPage(from data: Data) throws -> MusicCollectionList {
        let root = try jsonObject(data, what: "library response")
        for (key, itemsKey) in [("gridRenderer", "items"), ("musicShelfRenderer", "contents"), ("musicPlaylistShelfRenderer", "contents")] {
            var found: [[String: Any]] = []
            collect(key, in: root, into: &found)
            if let container = found.first {
                let items = container[itemsKey] as? [[String: Any]] ?? []
                return MusicCollectionList(
                    items: collections(in: items),
                    continuation: continuationToken(in: container, items: items)
                )
            }
        }
        return MusicCollectionList(items: [], continuation: nil)
    }

    static func libraryContinuationPage(from data: Data) throws -> MusicCollectionList {
        let root = try jsonObject(data, what: "library continuation")
        guard let payload = continuationPayload(in: root, keys: ["gridContinuation", "musicShelfContinuation", "musicPlaylistShelfContinuation"]) else {
            throw MusicError.parse("library continuation has no items")
        }
        return MusicCollectionList(
            items: collections(in: payload.items),
            continuation: continuationToken(in: payload.container, items: payload.items)
        )
    }

    private static func collections(in items: [[String: Any]]) -> [MusicCollection] {
        var seen = Set<String>()
        return items.compactMap { entry -> MusicCollection? in
            guard case .collection(let collection)? = shelfItem(from: entry) else { return nil }
            return seen.insert(collection.browseId).inserted ? collection : nil
        }
    }

    // MARK: - Pages

    /// A playlist ("VL..."), album ("MPRE...") or artist ("UC...") page, in either the two-column
    /// layout (`musicResponsiveHeaderRenderer`, tracks in the secondary column) or the older single column.
    static func browsePage(from data: Data, browseId: String) throws -> MusicBrowsePage {
        let root = try jsonObject(data, what: "page response")
        guard let header = pageHeader(in: root) else { throw MusicError.parse("page response has no header") }
        guard let title = text(of: runs(header.renderer["title"])) else { throw MusicError.parse("page response has no title") }

        let sections = pageSections(in: root)
        let cover = pickThumbnail(header.renderer["thumbnail"] ?? header.renderer["foregroundThumbnail"], near: nil)
        let rows = trackShelf(in: sections)
        let rowRenderers = (rows?["contents"] as? [[String: Any]] ?? []).compactMap { $0["musicResponsiveListItemRenderer"] as? [String: Any] }
        var tracks = rowRenderers.compactMap(browseTrack(from:))
        var audioPlaylistId: String?

        if browseId.hasPrefix("MPRE") {
            // The rows of an album play from its OLAK audio playlist, which is what its automix is asked of.
            audioPlaylistId = rowRenderers.lazy
                .compactMap { string(watchEndpoint(ofRow: $0)?["playlistId"]) }
                .first { $0.hasPrefix("OLAK") }
            // Album rows leave out what the page already says: the artist, the album and the cover.
            let artist = headerArtists(of: header.renderer)
            tracks = tracks.map { track in
                let ownArtist = !track.artist.isEmpty
                return MusicTrack(
                    videoId: track.videoId,
                    title: track.title,
                    artist: ownArtist ? track.artist : artist.names,
                    album: track.album ?? title,
                    durationSeconds: track.durationSeconds,
                    thumbnailURL: track.thumbnailURL ?? cover,
                    artistLinks: ownArtist ? track.artistLinks : artist.links,
                    albumBrowseId: track.albumBrowseId ?? browseId,
                    playlistSetVideoId: track.playlistSetVideoId,
                    plays: track.plays
                )
            }
        }

        let shelves = header.isArtist
            ? uniqueShelves(sections.filter { $0["musicShelfRenderer"] == nil }.compactMap(shelf(from:)))
            : []
        return MusicBrowsePage(
            browseId: browseId,
            title: title,
            subtitle: header.isArtist ? artistSubtitle(of: header.renderer) : detailSubtitle(of: header.renderer),
            thumbnailURL: cover,
            tracks: uniqueTracks(tracks),
            continuation: rows.flatMap { continuationToken(in: $0, items: $0["contents"] as? [[String: Any]] ?? []) },
            shelves: shelves,
            isEditable: isEditablePlaylist(root: root, browseId: browseId, rows: rowRenderers),
            audioPlaylistId: audioPlaylistId,
            allSongsBrowseId: header.isArtist ? rows.flatMap(allSongsBrowseId(in:)) : nil,
            discographyLinks: header.isArtist ? discographyLinks(in: sections) : []
        )
    }

    /// The discography pages an artist page's carousel shelves open (Albums, Singles), once each, in page order. A
    /// shelf's header is read by its title run first, then its more button. `params` stay as YouTube sent them.
    private static func discographyLinks(in sections: [[String: Any]]) -> [MusicDiscographyLink] {
        var links: [MusicDiscographyLink] = []
        for section in sections {
            guard let carousel = (section["musicCarouselShelfRenderer"] ?? section["musicImmersiveCarouselShelfRenderer"]) as? [String: Any],
                  let header = carouselHeader(of: carousel) else { continue }
            let title = path(runs(header["title"]).first, "navigationEndpoint", "browseEndpoint")
            let more = path(header, "moreContentButton", "buttonRenderer", "navigationEndpoint", "browseEndpoint")
            for case let browse as [String: Any] in [title, more] {
                guard isDiscography(browse), let id = string(browse["browseId"]) else { continue }
                let link = MusicDiscographyLink(browseId: id, params: string(browse["params"]))
                if !links.contains(link) { links.append(link) }
                break
            }
        }
        return links
    }

    /// An artist's discography page, by its page type, else by its "MPAD" id when the endpoint names no page type.
    private static func isDiscography(_ browse: [String: Any]) -> Bool {
        let configs = browse["browseEndpointContextSupportedConfigs"] as? [String: Any]
        let pageType = string((configs?["browseEndpointContextMusicConfig"] as? [String: Any])?["pageType"])
        if let pageType { return pageType == "MUSIC_PAGE_TYPE_ARTIST_DISCOGRAPHY" }
        return (string(browse["browseId"]) ?? "").hasPrefix("MPAD")
    }

    /// The artist's list of all their songs, which the Top songs header links to: the page its title run opens, else the
    /// shelf's bottom endpoint or its more button. Only a playlist counts, and a bare playlist id gets the "VL" its page
    /// is browsed by.
    private static func allSongsBrowseId(in shelf: [String: Any]) -> String? {
        let title = path(runs(shelf["title"]).first, "navigationEndpoint", "browseEndpoint")
        let bottom = path(shelf, "bottomEndpoint", "browseEndpoint")
        let more = path(shelf, "moreContentButton", "buttonRenderer", "navigationEndpoint", "browseEndpoint")
        for case let browse as [String: Any] in [title, bottom, more] {
            guard collectionKind(of: browse) == .playlist, let id = string(browse["browseId"]) else { continue }
            return id.hasPrefix("VL") ? id : "VL" + id
        }
        return nil
    }

    /// The rows after a page's first track list.
    static func tracksContinuationPage(from data: Data) throws -> MusicQueuePage {
        let root = try jsonObject(data, what: "tracks continuation")
        guard let payload = continuationPayload(in: root, keys: ["musicPlaylistShelfContinuation", "musicShelfContinuation"]) else {
            throw MusicError.parse("tracks continuation has no rows")
        }
        let tracks = payload.items.compactMap { ($0["musicResponsiveListItemRenderer"] as? [String: Any]).flatMap(browseTrack(from:)) }
        return MusicQueuePage(
            tracks: uniqueTracks(tracks),
            continuation: continuationToken(in: payload.container, items: payload.items)
        )
    }

    /// A row that plays: not greyed out by YouTube (removed or unavailable songs) and not a podcast episode.
    static func browseTrack(from renderer: [String: Any]) -> MusicTrack? {
        guard !isGreyedOut(renderer), !isPodcastEpisode(watchEndpoint(ofRow: renderer)) else { return nil }
        return track(from: renderer)
    }

    private static func pageHeader(in root: [String: Any]) -> (renderer: [String: Any], isArtist: Bool)? {
        let kinds = [
            ("musicResponsiveHeaderRenderer", false),
            ("musicDetailHeaderRenderer", false),
            ("musicImmersiveHeaderRenderer", true),
            ("musicVisualHeaderRenderer", true),
        ]
        for (key, isArtist) in kinds {
            var found: [[String: Any]] = []
            collect(key, in: root, into: &found)
            if let renderer = found.first { return (renderer, isArtist) }
        }
        return nil
    }

    /// The content sections: the secondary column of the two-column layout, or the first tab of the single column.
    private static func pageSections(in root: [String: Any]) -> [[String: Any]] {
        let contents = root["contents"] as? [String: Any]
        let secondary = path(contents, "twoColumnBrowseResultsRenderer", "secondaryContents", "sectionListRenderer", "contents") as? [[String: Any]]
        let tabs = path(contents, "singleColumnBrowseResultsRenderer", "tabs") as? [[String: Any]]
        let primary = path(tabs?.first, "tabRenderer", "content", "sectionListRenderer", "contents") as? [[String: Any]]
        return (secondary ?? []) + (primary ?? [])
    }

    /// The shelf that lists the page's songs: a playlist's shelf, an album's, an artist's "Top songs".
    private static func trackShelf(in sections: [[String: Any]]) -> [String: Any]? {
        for section in sections {
            if let shelf = (section["musicPlaylistShelfRenderer"] ?? section["musicShelfRenderer"]) as? [String: Any] {
                return shelf
            }
        }
        return nil
    }

    /// "Album • 2023 • 12 songs": the header's kind line plus the track count, without the running time.
    private static func detailSubtitle(of header: [String: Any]) -> String? {
        var parts = bulletSegments(of: runs(header["subtitle"])).compactMap(text(of:))
        let counts = bulletSegments(of: runs(header["secondSubtitle"])).compactMap(text(of:))
        if let count = counts.first(where: { $0.contains("song") || $0.contains("track") }) ?? counts.first {
            parts.append(count)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{2022} ")
    }

    private static func artistSubtitle(of header: [String: Any]) -> String? {
        let subscribers = text(of: runs(path(header, "subscriptionButton", "subscribeButtonRenderer", "longSubscriberCountText")))
        return subscribers ?? text(of: runs(header["monthlyListenerCount"]))
    }

    /// The album's artists, joined for display, and the ones with a page: the strapline, or the artist links in an
    /// older header's subtitle line.
    private static func headerArtists(of header: [String: Any]) -> (names: String, links: [MusicArtistLink]) {
        let strapline = runs(header["straplineTextOne"])
        let names = artistNames(in: strapline)
        if !names.isEmpty { return (names.joined(separator: ", "), artistLinks(in: strapline)) }
        let linked = runs(header["subtitle"]).filter { run in
            let browse = path(run, "navigationEndpoint", "browseEndpoint") as? [String: Any]
            return browse.flatMap(collectionKind(of:)) == .artist
        }
        return (artistNames(in: linked).joined(separator: ", "), artistLinks(in: linked))
    }

    private static func uniqueTracks(_ tracks: [MusicTrack]) -> [MusicTrack] {
        var seen = Set<String>()
        return tracks.filter { seen.insert($0.videoId).inserted }
    }

    private static func uniqueShelves(_ shelves: [MusicShelf]) -> [MusicShelf] {
        var seen = Set<String>()
        return shelves.filter { seen.insert($0.id).inserted }
    }

    // MARK: - Continuations

    /// The items of a continuation response and the container that holds a further old-style token:
    /// `continuationContents.<key>` for the old style, `appendContinuationItemsAction` for the new.
    /// A token with nothing after it can be answered with the page's bare skeleton instead of a last
    /// page; that is the end of the list (no items, no token), and not a response Deci cannot read.
    private static func continuationPayload(in root: [String: Any], keys: [String]) -> (items: [[String: Any]], container: [String: Any]?)? {
        let contents = root["continuationContents"] as? [String: Any]
        for key in keys {
            if let container = contents?[key] as? [String: Any] {
                return ((container["contents"] ?? container["items"]) as? [[String: Any]] ?? [], container)
            }
        }
        for action in root["onResponseReceivedActions"] as? [[String: Any]] ?? [] {
            if let items = path(action, "appendContinuationItemsAction", "continuationItems") as? [[String: Any]] {
                return (items, nil)
            }
        }
        return isBareSkeleton(root) ? ([], nil) : nil
    }

    /// A browse response that is only its tab strip: a column renderer with no section list anywhere in it.
    private static func isBareSkeleton(_ root: [String: Any]) -> Bool {
        guard let contents = root["contents"] as? [String: Any],
              contents["singleColumnBrowseResultsRenderer"] != nil || contents["twoColumnBrowseResultsRenderer"] != nil else { return false }
        var lists: [[String: Any]] = []
        collect("sectionListRenderer", in: contents, into: &lists)
        return lists.isEmpty
    }

    // MARK: - Artist search

    /// The artists of a search made with the artists filter: one per artist, in the order YouTube lists them.
    /// Albums, songs, user channels, greyed-out rows and rows with no usable id are left out.
    static func searchArtists(from data: Data) throws -> [MusicCollection] {
        let root = try jsonObject(data, what: "artist search response")
        var rows: [[String: Any]] = []
        collect("musicResponsiveListItemRenderer", in: root, into: &rows)
        var seen = Set<String>()
        return rows.compactMap(artistResult(from:)).filter { seen.insert($0.browseId).inserted }
    }

    /// An artist row has no video; its destination is the row's own browse endpoint. It shows the largest photo
    /// the row offers, and under the name what YouTube says after the "Artist" label (a follower count).
    private static func artistResult(from row: [String: Any]) -> MusicCollection? {
        guard !isGreyedOut(row), string(path(row, "playlistItemData", "videoId")) == nil,
              let browse = path(row, "navigationEndpoint", "browseEndpoint") as? [String: Any]
        else { return nil }
        let columns = flexColumnRuns(of: row)
        guard let title = text(of: columns.first ?? []),
              case .collection(let artist)? = collection(
                  browse,
                  title: title,
                  subtitle: artistSearchSubtitle(columns.count > 1 ? columns[1] : []),
                  thumbnail: pickThumbnail(row["thumbnail"], near: nil)
              ),
              artist.kind == .artist
        else { return nil }
        return artist
    }

    /// "Artist • 1.2M monthly audience" reads "1.2M monthly audience"; a row that says only "Artist" keeps it.
    private static func artistSearchSubtitle(_ runs: [[String: Any]]) -> String {
        var parts = bulletSegments(of: runs).compactMap(text(of:))
        if parts.first == "Artist" { parts.removeFirst() }
        return parts.isEmpty ? "Artist" : parts.joined(separator: " \u{2022} ")
    }

    // MARK: - Tiles and rows

    /// One tile or row as Deci shows it. Nil for what Deci cannot open: podcasts, episodes (and the
    /// library's "Episodes for later"), user channels, anything greyed out, a tile with no
    /// destination (the library's "New playlist").
    static func shelfItem(from entry: [String: Any]) -> MusicShelfItem? {
        if let tile = entry["musicTwoRowItemRenderer"] as? [String: Any] { return tileItem(from: tile) }
        if let row = entry["musicResponsiveListItemRenderer"] as? [String: Any] { return rowItem(from: row) }
        return nil
    }

    private static func tileItem(from tile: [String: Any]) -> MusicShelfItem? {
        let titleRuns = runs(tile["title"])
        guard !isGreyedOut(tile), let title = text(of: titleRuns) else { return nil }
        let endpoint = (tile["navigationEndpoint"] ?? titleRuns.first?["navigationEndpoint"]) as? [String: Any]
        let subtitleRuns = runs(tile["subtitle"])
        let thumbnail = pickThumbnail(tile["thumbnailRenderer"], near: 300)

        if let browse = endpoint?["browseEndpoint"] as? [String: Any] {
            return collection(
                browse,
                title: title,
                subtitle: text(of: subtitleRuns),
                thumbnail: thumbnail,
                artistLinks: artistLinks(in: subtitleRuns),
                audioPlaylistId: albumPlaylistId(in: tile)
            )
        }
        if let watch = endpoint?["watchEndpoint"] as? [String: Any] {
            if let videoId = string(watch["videoId"]) {
                guard !isPodcastEpisode(watch) else { return nil }
                let subtitle = parseSubtitle(subtitleRuns)
                let options = rowOptions(in: tile)
                return .track(MusicTrack(
                    videoId: videoId,
                    title: title,
                    artist: subtitle.artists.joined(separator: ", "),
                    album: subtitle.album,
                    durationSeconds: subtitle.durationSeconds,
                    thumbnailURL: thumbnail,
                    artistLinks: subtitle.artistLinks,
                    albumBrowseId: subtitle.albumBrowseId ?? options.albumBrowseId
                ))
            }
            return mix(playlistId: string(watch["playlistId"]), title: title, subtitle: text(of: subtitleRuns), thumbnail: thumbnail)
        }
        let playlistId = string((endpoint?["watchPlaylistEndpoint"] as? [String: Any])?["playlistId"])
        return mix(playlistId: playlistId, title: title, subtitle: text(of: subtitleRuns), thumbnail: thumbnail)
    }

    /// A row is a song when it has a video; otherwise a row-level browse endpoint makes it an
    /// artist, album or playlist (the library's artists are rows).
    private static func rowItem(from row: [String: Any]) -> MusicShelfItem? {
        guard !isGreyedOut(row) else { return nil }
        let columns = flexColumnRuns(of: row)
        if string(path(row, "playlistItemData", "videoId")) == nil,
           let browse = path(row, "navigationEndpoint", "browseEndpoint") as? [String: Any] {
            guard let title = text(of: columns.first ?? []) else { return nil }
            return collection(
                browse,
                title: title,
                subtitle: text(of: columns.count > 1 ? columns[1] : []),
                thumbnail: thumbnailURL(in: row)
            )
        }
        return browseTrack(from: row).map { .track($0) }
    }

    /// "Episodes for later" (playlist SE) lists podcast episodes only, which Deci cannot play, so its page would be empty.
    private static let episodesForLaterBrowseId = "VLSE"

    /// `artistLinks` are the subtitle's artists. `audioPlaylistId` is read for every tile but kept only for an album.
    private static func collection(
        _ browse: [String: Any],
        title: String,
        subtitle: String?,
        thumbnail: URL?,
        artistLinks: [MusicArtistLink] = [],
        audioPlaylistId: String? = nil
    ) -> MusicShelfItem? {
        guard var browseId = string(browse["browseId"]), browseId != episodesForLaterBrowseId,
              let kind = collectionKind(of: browse) else { return nil }
        // A library artist links to "MPLA" + its channel id; the artist page is the channel id (as ytmusicapi does).
        if kind == .artist, browseId.hasPrefix("MPLAUC") { browseId.removeFirst(4) }
        return .collection(MusicCollection(
            browseId: browseId,
            kind: kind,
            title: title,
            subtitle: subtitle ?? "",
            thumbnailURL: thumbnail,
            artistLinks: artistLinks,
            audioPlaylistId: kind == .album ? audioPlaylistId : nil
        ))
    }

    /// The playlist of an album's songs, behind the play button over its cover ("OLAK5uy_..."). A radio or mix id, a
    /// blank one, or a tile with no play button gives nil, so no save is offered on a guess.
    private static func albumPlaylistId(in tile: [String: Any]) -> String? {
        let target = path(tile, "thumbnailOverlay", "musicItemThumbnailOverlayRenderer", "content", "musicPlayButtonRenderer", "playNavigationEndpoint") as? [String: Any]
        let endpoint = (target?["watchPlaylistEndpoint"] ?? target?["watchEndpoint"]) as? [String: Any]
        guard let id = string(endpoint?["playlistId"]), id.hasPrefix("OLAK") else { return nil }
        return id
    }

    /// A mix has no page of its own, only a playlist id: its page is "VL" + that id.
    private static func mix(playlistId: String?, title: String, subtitle: String?, thumbnail: URL?) -> MusicShelfItem? {
        guard let playlistId else { return nil }
        let browseId = playlistId.hasPrefix("VL") ? playlistId : "VL" + playlistId
        return .collection(MusicCollection(
            browseId: browseId, kind: .playlist, title: title, subtitle: subtitle ?? "", thumbnailURL: thumbnail
        ))
    }

    /// By YouTube's page type. A destination without one is told apart by its id prefix instead;
    /// a page type Deci does not know (podcast, user channel, audiobook) is nil.
    static func collectionKind(of browse: [String: Any]) -> MusicCollection.Kind? {
        let configs = browse["browseEndpointContextSupportedConfigs"] as? [String: Any]
        let pageType = string((configs?["browseEndpointContextMusicConfig"] as? [String: Any])?["pageType"])
        switch pageType {
        case "MUSIC_PAGE_TYPE_ALBUM": return .album
        case "MUSIC_PAGE_TYPE_PLAYLIST": return .playlist
        case "MUSIC_PAGE_TYPE_ARTIST", "MUSIC_PAGE_TYPE_LIBRARY_ARTIST": return .artist
        case nil:
            let browseId = string(browse["browseId"]) ?? ""
            if browseId.hasPrefix("VL") { return .playlist }
            if browseId.hasPrefix("MPRE") { return .album }
            return browseId.hasPrefix("UC") ? .artist : nil
        default: return nil
        }
    }

    private static func isGreyedOut(_ renderer: [String: Any]) -> Bool {
        string(renderer["musicItemRendererDisplayPolicy"]) == "MUSIC_ITEM_RENDERER_DISPLAY_POLICY_GREY_OUT"
    }

    private static func isPodcastEpisode(_ watch: [String: Any]?) -> Bool {
        string(path(watch, "watchEndpointMusicSupportedConfigs", "watchEndpointMusicConfig", "musicVideoType")) == "MUSIC_VIDEO_TYPE_PODCAST_EPISODE"
    }

    /// The row's play target: the title link, or the play button over the cover.
    private static func watchEndpoint(ofRow row: [String: Any]) -> [String: Any]? {
        let title = path(flexColumnRuns(of: row).first?.first, "navigationEndpoint", "watchEndpoint")
        let overlay = path(row, "overlay", "musicItemThumbnailOverlayRenderer", "content", "musicPlayButtonRenderer", "playNavigationEndpoint", "watchEndpoint")
        return (title ?? overlay) as? [String: Any]
    }

    private static func flexColumnRuns(of row: [String: Any]) -> [[[String: Any]]] {
        (row["flexColumns"] as? [[String: Any]] ?? []).map { column in
            runs(path(column, "musicResponsiveListItemFlexColumnRenderer", "text"))
        }
    }

    /// The thumbnail nearest `target` px wide, or the largest when there is no target.
    /// `holder` is the object that has the `musicThumbnailRenderer` (or the cropped square one).
    static func pickThumbnail(_ holder: Any?, near target: Int?) -> URL? {
        let dictionary = holder as? [String: Any]
        let renderer = (dictionary?["musicThumbnailRenderer"] ?? dictionary?["croppedSquareThumbnailRenderer"]) as? [String: Any]
        let candidates = (renderer?["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]] ?? []
        let width: ([String: Any]) -> Int = { int($0["width"]) ?? 0 }
        let best: [String: Any]?
        if let target {
            best = candidates.min { abs(width($0) - target) < abs(width($1) - target) }
        } else {
            best = candidates.max { width($0) < width($1) }
        }
        return string(best?["url"]).flatMap { URL(string: $0) }
    }
}
