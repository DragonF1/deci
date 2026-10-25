// Deci/Music/Downloads/MusicDownloadStore.swift
import Foundation
import os

/// The downloaded songs on disk: `audio/<videoId>.m4a` for each, and `downloads.json` beside the folder to say what
/// they are. The folder is global, not per channel, so signing out or switching channel never touches it.
///
/// A song is written to `audio/<videoId>.m4a.part` and renamed into place only when every byte is there, so a file
/// named `.m4a` is always whole. A crash between the rename and the index write leaves audio no entry owns; loading
/// sweeps it, and the `.part` files too. Every write to the index is atomic.
///
/// Finished audio is never deleted on the word of an index that was not read in full. The sweep of audio no entry owns
/// runs only when the index was read and every entry in it decoded, and nothing marks an earlier launch's trouble: an
/// index moved aside as unreadable (`downloads.json.unreadable`, numbered when one is there already), an index that was
/// missing while audio existed (`downloads.json.missing`), or an entry this version cannot decode, which is kept as it
/// was and written back with every rewrite. An index that cannot be read at all (not "no such file") blocks the store:
/// nothing is swept or written, and downloads wait for the next launch.
///
/// `collections` holds each downloaded playlist or album: its title, its cover, and its songs by video id in the
/// page's order. A song's file is deleted only when no collection lists it and it was not downloaded on its own
/// (`Entry.standalone`), so a song two collections share goes when the last lets go. Cover pictures live in `covers/`,
/// named by a hash of their address, and are deleted when nothing names them. A record or entry this version cannot read
/// holds everything back: while one exists nothing is deleted on a collection's behalf.
///
/// The index is rewritten whole, so changes that only add (a finished song, a first cover, the flag of a song asked for on
/// its own) wait a couple of seconds and go down together, and `flushIndex()` writes them sooner. Anything that deletes a
/// file, and every change to a collection, writes at once, taking what waits along.
///
/// An actor, so file work runs off the main thread and two writes never interleave.
actor MusicDownloadStore {
    /// One downloaded song.
    struct Entry: Codable, Equatable, Sendable {
        let track: MusicTrack
        let bytes: Int64
        let downloadedAt: Date
        /// The exact length the stream stated. A downloaded fragmented mp4 reads back at double length in AVFoundation,
        /// so playback needs the stored one.
        let durationSeconds: Double?
        /// Asked for on its own, with the song's menu. A song that is not stands only for the collections that list it.
        /// An entry written before collections existed has no flag and stands alone.
        var standalone: Bool
        /// The small picture saved for the song, a file name under `covers/`.
        var coverFile: String?

        init(
            track: MusicTrack, bytes: Int64, downloadedAt: Date, durationSeconds: Double?,
            standalone: Bool = true, coverFile: String? = nil
        ) {
            self.track = track
            self.bytes = bytes
            self.downloadedAt = downloadedAt
            self.durationSeconds = durationSeconds
            self.standalone = standalone
            self.coverFile = coverFile
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            track = try container.decode(MusicTrack.self, forKey: .track)
            bytes = try container.decode(Int64.self, forKey: .bytes)
            downloadedAt = try container.decode(Date.self, forKey: .downloadedAt)
            durationSeconds = try container.decodeIfPresent(Double.self, forKey: .durationSeconds)
            standalone = try container.decodeIfPresent(Bool.self, forKey: .standalone) ?? true
            coverFile = try container.decodeIfPresent(String.self, forKey: .coverFile)
        }
    }

    /// A downloaded playlist or album: what the page said about itself and the songs it holds, by video id, in the page's
    /// order. The list is what the page listed when it was last synced, and some of its songs may not be downloaded yet.
    struct Collection: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable {
            case playlist
            case album
        }

        /// How the last sync ended: every song is here, some could not be downloaded, or the page could not be read (the
        /// list was kept as it was).
        enum SyncResult: Equatable, Sendable, Codable {
            case complete
            case failed(Int)
            case unreachable

            private static let failedPrefix = "failed:"

            init(from decoder: any Decoder) throws {
                let text = try decoder.singleValueContainer().decode(String.self)
                switch text {
                case "complete": self = .complete
                case "unreachable": self = .unreachable
                default:
                    guard text.hasPrefix(Self.failedPrefix), let count = Int(text.dropFirst(Self.failedPrefix.count)),
                          count >= 0 else {
                        throw DecodingError.dataCorrupted(
                            .init(codingPath: decoder.codingPath, debugDescription: "Unknown sync result \(text)")
                        )
                    }
                    self = .failed(count)
                }
            }

            func encode(to encoder: any Encoder) throws {
                var container = encoder.singleValueContainer()
                switch self {
                case .complete: try container.encode("complete")
                case .unreachable: try container.encode("unreachable")
                case .failed(let count): try container.encode("\(Self.failedPrefix)\(count)")
                }
            }
        }

        /// Songs a sync saw leave the page, in a number too large to take for certain (see `MusicCollectionSyncRules`): their
        /// files and their places in the list stay until a later sync, an hour on, still finds them missing.
        struct HeldDrop: Codable, Equatable, Sendable {
            var videoIds: [String]
            /// When a sync first saw them missing.
            var since: Date
        }

        var title: String
        var videoIds: [String]
        var subtitle: String
        var kind: Kind
        /// The cover the page named, as the page gave it.
        var coverURL: URL?
        /// The small picture saved from it, a file name under `covers/`.
        var coverFile: String?
        var addedAt: Date
        /// When the page last matched the list.
        var lastSyncedAt: Date?
        var syncResult: SyncResult?
        /// The account a Liked music list belongs to, so a sync under another one leaves it alone.
        var channelKey: String?
        /// A large drop the page showed that has not been applied yet; nil when nothing is held.
        var heldDrop: HeldDrop?

        init(
            title: String,
            videoIds: [String],
            subtitle: String = "",
            kind: Kind = .playlist,
            coverURL: URL? = nil,
            coverFile: String? = nil,
            addedAt: Date = Date(timeIntervalSince1970: 0),
            lastSyncedAt: Date? = nil,
            syncResult: SyncResult? = nil,
            channelKey: String? = nil,
            heldDrop: HeldDrop? = nil
        ) {
            self.title = title
            self.videoIds = videoIds
            self.subtitle = subtitle
            self.kind = kind
            self.coverURL = coverURL
            self.coverFile = coverFile
            self.addedAt = addedAt
            self.lastSyncedAt = lastSyncedAt
            self.syncResult = syncResult
            self.channelKey = channelKey
            self.heldDrop = heldDrop
        }

        /// Only the title and the songs are needed. A field this version does not know the value of (a kind it has no case
        /// for) fails the record, which the store then keeps as it was.
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            title = try container.decode(String.self, forKey: .title)
            videoIds = try container.decode([String].self, forKey: .videoIds)
            subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle) ?? ""
            kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .playlist
            coverURL = try container.decodeIfPresent(URL.self, forKey: .coverURL)
            coverFile = try container.decodeIfPresent(String.self, forKey: .coverFile)
            addedAt = try container.decodeIfPresent(Date.self, forKey: .addedAt) ?? Date(timeIntervalSince1970: 0)
            lastSyncedAt = try container.decodeIfPresent(Date.self, forKey: .lastSyncedAt)
            syncResult = try container.decodeIfPresent(SyncResult.self, forKey: .syncResult)
            channelKey = try container.decodeIfPresent(String.self, forKey: .channelKey)
            // A hold this version cannot read is dropped, not the record: the next sync starts the hold again.
            heldDrop = (try? container.decodeIfPresent(HeldDrop.self, forKey: .heldDrop)) ?? nil
        }
    }

    /// What `remove(videoId:keepingFile:)` did.
    enum Release: Equatable, Sendable {
        /// Not a video id, no entry for it, or the store is blocked: nothing changed.
        case untouched
        /// The entry and the file are gone.
        case deleted
        /// A collection lists the song (or might, while a record is unread): the entry and the file stay, and only the
        /// song's own flag was cleared. The entry is as it is now.
        case keptForCollection(Entry)
    }

    /// What `removeCollection(_:keepingFiles:)` did.
    struct CollectionRemoval: Equatable, Sendable {
        /// The songs whose entries and files went with the collection.
        var dropped: [String]
        /// The record, put back because the index could not be written; nothing was deleted then.
        var restored: Collection?
    }

    /// The whole of `downloads.json`. The store reads it entry by entry (see `parseIndex`); `decode` is all or nothing.
    struct Index: Codable, Equatable, Sendable {
        static let currentVersion = 2

        var version = Index.currentVersion
        var entries: [String: Entry]
        var collections: [String: Collection]

        init(entries: [String: Entry] = [:], collections: [String: Collection] = [:]) {
            self.entries = entries
            self.collections = collections
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decode(Int.self, forKey: .version)
            entries = try container.decodeIfPresent([String: Entry].self, forKey: .entries) ?? [:]
            collections = try container.decodeIfPresent([String: Collection].self, forKey: .collections) ?? [:]
        }

        /// The index in `data`, or nil when it is not one this version can read: not JSON, or written by a newer one.
        static func decode(_ data: Data) -> Index? {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            guard let index = try? decoder.decode(Index.self, from: data), index.version <= currentVersion else { return nil }
            return index
        }

        func encoded() throws -> Data {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(self)
        }
    }

    static let indexName = "downloads.json"
    private static let unreadablePrefix = "downloads.json.unreadable"
    private static let missingMarkerName = "downloads.json.missing"
    private static let coversName = "covers"
    private static let coverExtension = "img"
    private static let audioExtension = "m4a"
    private static let partSuffix = ".m4a.part"
    private static let log = Logger(subsystem: "com.abraham.Deci", category: "MusicDownloads")

    /// What is downloaded, by video id. Empty until `load()`.
    private(set) var entries: [String: Entry] = [:]

    private let root: URL
    private let now: @Sendable () -> Date
    private var collections: [String: Collection] = [:]
    /// Entries and collections this version could not decode, as the JSON they were. Written back with every rewrite.
    private var preservedEntries: [String: Any] = [:]
    private var preservedCollections: [String: Any] = [:]
    private var hasLoaded = false
    /// The index (or the audio folder) could not be read: nothing is dropped, swept or written, and no download starts.
    private var isBlocked = false
    private var isRootPrepared = false

    /// How long a change that only adds waits before the index is written.
    private let indexFlushDelay: TimeInterval
    /// Changes the index on disk does not have yet: songs and covers added, and a flag set.
    private var isIndexDirty = false
    private var flushTask: Task<Void, Never>?
    /// How many times the index has been written since the store began.
    private(set) var indexWriteCount = 0

    /// Called with the browse id as `saveCollection` and `removeCollection` begin, before they change anything. A test uses
    /// it to hold the store there while the app acts on the songs the record lists; the app passes nothing.
    private let beforeCollectionChange: (@Sendable (String) -> Void)?

    init(
        root: URL,
        now: @escaping @Sendable () -> Date = Date.init,
        indexFlushDelay: TimeInterval = 2,
        beforeCollectionChange: (@Sendable (String) -> Void)? = nil
    ) {
        self.root = root
        self.now = now
        self.indexFlushDelay = indexFlushDelay
        self.beforeCollectionChange = beforeCollectionChange
    }

    deinit {
        flushTask?.cancel()
    }

    /// <Application Support>/Deci/Downloads
    static func liveRoot() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return support.appendingPathComponent("Deci/Downloads", isDirectory: true)
    }

    /// Eleven characters from A-Z, a-z, 0-9, underscore and hyphen: every YouTube video id, and nothing that can name a
    /// path outside the audio folder.
    static func isValidVideoId(_ videoId: String) -> Bool {
        let bytes = videoId.utf8
        guard bytes.count == 11 else { return false }
        return bytes.allSatisfy { byte in
            (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte) || (0x30...0x39).contains(byte)
                || byte == 0x5F || byte == 0x2D
        }
    }

    // MARK: - Paths

    private var audioDirectory: URL { root.appendingPathComponent("audio", isDirectory: true) }
    private var indexURL: URL { root.appendingPathComponent(Self.indexName, isDirectory: false) }
    private var missingMarkerURL: URL { root.appendingPathComponent(Self.missingMarkerName, isDirectory: false) }
    private var coversDirectory: URL { root.appendingPathComponent(Self.coversName, isDirectory: true) }

    /// Where the song's audio is, or nil when `videoId` is not a video id.
    nonisolated func audioURL(for videoId: String) -> URL? {
        guard Self.isValidVideoId(videoId) else { return nil }
        return root.appendingPathComponent("audio/\(videoId).\(Self.audioExtension)", isDirectory: false)
    }

    /// Whether `name` is a file name a cover can have: lowercase hexadecimal digits and `.img`, so no name can reach outside
    /// the covers folder.
    static func isValidCoverName(_ name: String) -> Bool {
        let suffix = ".\(coverExtension)"
        guard name.hasSuffix(suffix) else { return false }
        let stem = name.utf8.dropLast(suffix.utf8.count)
        guard (1...128).contains(stem.count) else { return false }
        return stem.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    /// Where the cover picture called `name` is (or would be), or nil when `name` is not a cover name.
    nonisolated func coverURL(named name: String) -> URL? {
        guard Self.isValidCoverName(name) else { return nil }
        return root.appendingPathComponent("\(Self.coversName)/\(name)", isDirectory: false)
    }

    /// Whether the cover picture called `name` is on disk.
    nonisolated func hasCover(named name: String) -> Bool {
        guard let url = coverURL(named: name) else { return false }
        return (Self.fileSize(at: url) ?? 0) > 0
    }

    /// Whether the index lists a collection, read from the file alone. False when there is no index, or it is not JSON.
    /// For the launch check, which must not wait for the store.
    nonisolated static func indexHasCollections(at root: URL) -> Bool {
        let url = root.appendingPathComponent(indexName, isDirectory: false)
        guard let data = try? Data(contentsOf: url),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let collections = object["collections"] as? [String: Any] else { return false }
        return !collections.isEmpty
    }

    /// Where the song is written while it downloads, or nil when `videoId` is not a video id.
    nonisolated func partURL(for videoId: String) -> URL? {
        guard Self.isValidVideoId(videoId) else { return nil }
        return root.appendingPathComponent("audio/\(videoId)\(Self.partSuffix)", isDirectory: false)
    }

    // MARK: - Loading

    /// Reads the index once and returns what is downloaded. Each entry is decoded on its own, so one this version cannot
    /// read drops only itself from the list (and stays in the file). An entry whose audio is missing, whose key is not a
    /// video id, or whose file is not the size it says is dropped, and the index rewritten; a file of the wrong size goes
    /// with it. `.part` files are deleted. Audio no entry owns is deleted only when the index was read in full and
    /// nothing says an earlier launch could not read it (see the type's comment). Later calls return the current entries.
    func load() -> [String: Entry] {
        guard !hasLoaded else { return entries }
        hasLoaded = true
        let fileManager = FileManager.default

        // Nothing is judged against an audio folder that exists and cannot be listed: every entry would look orphaned.
        let names: [String]
        do {
            names = try fileManager.contentsOfDirectory(atPath: audioDirectory.path)
        } catch where Self.isMissing(error) {
            names = []
        } catch {
            Self.log.error("The audio folder could not be listed, so downloads are off for this launch")
            isBlocked = true
            return entries
        }

        var parsed = ParsedIndex()
        var mayJudgeOrphans = true
        switch readIndexData() {
        case .data(let data):
            if let index = Self.parseIndex(data) {
                parsed = index
            } else {
                mayJudgeOrphans = false
                if !moveUnreadableIndexAside() { isBlocked = true }
            }
        case .missing:
            // No index beside audio is a lost index, not an empty one.
            if names.contains(where: { $0.hasSuffix(".\(Self.audioExtension)") }) {
                mayJudgeOrphans = false
                writeMissingMarker()
            }
        case .failed:
            isBlocked = true
        }
        guard !isBlocked else {
            sweepAudioDirectory(names, sweepingOrphans: false)
            return entries
        }

        var kept: [String: Entry] = [:]
        var changed = false
        preservedEntries = parsed.preservedEntries
        preservedCollections = parsed.preservedCollections
        for (videoId, entry) in parsed.entries {
            guard let audio = audioURL(for: videoId) else {
                changed = true
                continue
            }
            guard entry.track.videoId == videoId else {
                // Valid key, wrong track: not understood, so kept as it was rather than judged.
                preservedEntries[videoId] = Self.rawJSON(of: entry) ?? [:]
                continue
            }
            guard fileManager.fileExists(atPath: audio.path) else {
                changed = true
                continue
            }
            guard Self.fileSize(at: audio) == entry.bytes else {
                try? fileManager.removeItem(at: audio)
                changed = true
                continue
            }
            kept[videoId] = entry
        }
        collections = parsed.collections

        let mayJudge = mayJudgeOrphans && preservedEntries.isEmpty && preservedCollections.isEmpty && !leavesMarkers()
        if mayJudge {
            // A song only a collection stood for, and no collection lists it: nothing wants its file.
            let held = Self.heldIDs(in: collections)
            for (videoId, entry) in kept where !entry.standalone && !held.contains(videoId) {
                kept[videoId] = nil
                changed = true
            }
        }
        entries = kept
        if clearMissingCovers() { changed = true }
        sweepAudioDirectory(names, sweepingOrphans: mayJudge)
        if mayJudge { sweepCovers() }
        if changed { try? writeIndex() }
        return entries
    }

    /// Every video id some collection lists.
    private static func heldIDs(in collections: [String: Collection]) -> Set<String> {
        var held = Set<String>()
        for collection in collections.values { held.formUnion(collection.videoIds) }
        return held
    }

    /// Forgets the cover of an entry or collection whose picture is not on disk, so it is fetched again. True when
    /// something changed.
    private func clearMissingCovers() -> Bool {
        var changed = false
        for (videoId, entry) in entries {
            guard let name = entry.coverFile, !hasCover(named: name) else { continue }
            entries[videoId]?.coverFile = nil
            changed = true
        }
        for (browseId, collection) in collections {
            guard let name = collection.coverFile, !hasCover(named: name) else { continue }
            collections[browseId]?.coverFile = nil
            changed = true
        }
        return changed
    }

    /// Deletes every file in `covers/` that no entry or collection names.
    private func sweepCovers() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: coversDirectory.path)) ?? []
        guard !names.isEmpty else { return }
        let named = namedCovers()
        for name in names where !named.contains(name) {
            try? FileManager.default.removeItem(at: coversDirectory.appendingPathComponent(name))
        }
    }

    private func namedCovers() -> Set<String> {
        var named = Set<String>()
        for entry in entries.values { if let name = entry.coverFile { named.insert(name) } }
        for collection in collections.values { if let name = collection.coverFile { named.insert(name) } }
        return named
    }

    /// Deletes each of the cover files that nothing names any longer. Left alone while an entry or collection this
    /// version could not read might name one.
    private func deleteCoversIfUnnamed(_ names: [String]) {
        guard !isBlocked, preservedEntries.isEmpty, preservedCollections.isEmpty else { return }
        let named = namedCovers()
        for name in Set(names) where !named.contains(name) {
            if let url = coverURL(named: name) { try? FileManager.default.removeItem(at: url) }
        }
    }

    private enum IndexRead {
        case data(Data)
        case missing
        case failed
    }

    /// Only "no such file" is an empty index; any other failure to read it is a failure.
    private func readIndexData() -> IndexRead {
        do {
            return .data(try Data(contentsOf: indexURL))
        } catch where Self.isMissing(error) {
            return .missing
        } catch {
            Self.log.error("The downloads index could not be read, so downloads are off for this launch")
            return .failed
        }
    }

    /// True for an error that says only that there is no such file or folder.
    private static func isMissing(_ error: any Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == CocoaError.fileReadNoSuchFile.rawValue || nsError.code == CocoaError.fileNoSuchFile.rawValue {
            return true
        }
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(ENOENT) { return true }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            return underlying.domain == NSPOSIXErrorDomain && underlying.code == Int(ENOENT)
        }
        return false
    }

    private static func fileSize(at url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }

    /// The index as read entry by entry: what decoded, and the raw JSON of what did not.
    private struct ParsedIndex {
        var entries: [String: Entry] = [:]
        var collections: [String: Collection] = [:]
        var preservedEntries: [String: Any] = [:]
        var preservedCollections: [String: Any] = [:]
    }

    /// nil when `data` is not an index this version can read at all: not a JSON object, a version it does not know, or
    /// entries or collections that are not objects. Otherwise every entry and collection is decoded on its own.
    private static func parseIndex(_ data: Data) -> ParsedIndex? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let version = object["version"] as? Int, (1...Index.currentVersion).contains(version) else { return nil }
        guard let rawEntries = jsonObject(object["entries"]), let rawCollections = jsonObject(object["collections"]) else {
            return nil
        }
        var parsed = ParsedIndex()
        for (key, raw) in rawEntries {
            if let entry: Entry = decodeValue(raw) { parsed.entries[key] = entry } else { parsed.preservedEntries[key] = raw }
        }
        for (key, raw) in rawCollections {
            if let collection: Collection = decodeValue(raw) {
                parsed.collections[key] = collection
            } else {
                parsed.preservedCollections[key] = raw
            }
        }
        return parsed
    }

    /// The JSON object in `value`: empty when the key was absent or null, nil when it is something else.
    private static func jsonObject(_ value: Any?) -> [String: Any]? {
        if value == nil || value is NSNull { return [:] }
        return value as? [String: Any]
    }

    private static func decodeValue<Value: Decodable>(_ raw: Any) -> Value? {
        guard let data = try? JSONSerialization.data(withJSONObject: raw, options: [.fragmentsAllowed]) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(Value.self, from: data)
    }

    private static func rawJSON(of entry: Entry) -> Any? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(entry) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    /// Moves the index nobody can read to a name of its own, the first free of `downloads.json.unreadable`,
    /// `downloads.json.unreadable.1`, and so on, so an earlier one is never replaced. False when it could not be moved.
    private func moveUnreadableIndexAside() -> Bool {
        let fileManager = FileManager.default
        for number in 0..<1000 {
            let name = number == 0 ? Self.unreadablePrefix : "\(Self.unreadablePrefix).\(number)"
            let aside = root.appendingPathComponent(name, isDirectory: false)
            guard !fileManager.fileExists(atPath: aside.path) else { continue }
            do {
                try fileManager.moveItem(at: indexURL, to: aside)
                return true
            } catch {
                break
            }
        }
        Self.log.error("The unreadable downloads index could not be moved aside, so downloads are off for this launch")
        return false
    }

    /// Notes that audio was found with no index, so that no later launch takes it for an orphan.
    private func writeMissingMarker() {
        do {
            try Data().write(to: missingMarkerURL)
        } catch {
            Self.log.error("The missing-index marker could not be written")
        }
    }

    /// Whether an earlier launch left a sign that the index was lost or unreadable.
    private func leavesMarkers() -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.contains { $0 == Self.missingMarkerName || $0.hasPrefix(Self.unreadablePrefix) }
    }

    private func sweepAudioDirectory(_ names: [String], sweepingOrphans: Bool) {
        let fileManager = FileManager.default
        for name in names {
            let isPart = name.hasSuffix(Self.partSuffix)
            let isAudio = name.hasSuffix(".\(Self.audioExtension)")
            var delete = isPart
            if isAudio, sweepingOrphans {
                let videoId = String(name.dropLast(Self.audioExtension.count + 1))
                delete = entries[videoId] == nil
            }
            if delete { try? fileManager.removeItem(at: audioDirectory.appendingPathComponent(name)) }
        }
    }

    // MARK: - Reading

    /// Whether the song has an entry and its file is still there. A `.part` file is never a download.
    func isDownloaded(_ videoId: String) -> Bool {
        guard entries[videoId] != nil, let audio = audioURL(for: videoId) else { return false }
        return FileManager.default.fileExists(atPath: audio.path)
    }

    // MARK: - Writing

    /// An empty `.part` file for the song, ready to be appended to. Anything an earlier try left is truncated. Throws the
    /// disk's own error when the folder cannot be written to, and `indexUnavailable` while the index could not be read.
    func beginPart(videoId: String) throws -> URL {
        guard let part = partURL(for: videoId) else { throw MusicDownloadError.invalidVideoId }
        guard !isBlocked else { throw MusicDownloadError.indexUnavailable }
        try prepareRoot()
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        try Data().write(to: part)
        return part
    }

    /// Deletes the song's `.part` file, if there is one. Nothing else.
    func discardPart(videoId: String) {
        guard let part = partURL(for: videoId) else { return }
        try? FileManager.default.removeItem(at: part)
    }

    /// Renames the finished `.part` file into place and lists the song. A part whose size is not `expectedBytes` is
    /// deleted and never listed. A song downloaded again replaces its entry and its file, and keeps its cover. `standalone`
    /// is whether the song was asked for on its own; a song that already stands alone keeps doing so.
    ///
    /// The index is written a moment later, with the songs that follow (see `flushIndex()`), not once for each. A quit in
    /// between leaves audio no entry owns, which the next load deletes and a sync downloads again.
    func commit(
        _ track: MusicTrack, expectedBytes: Int64, durationSeconds: Double?, standalone: Bool = true
    ) throws -> Entry {
        let videoId = track.videoId
        guard let part = partURL(for: videoId), let audio = audioURL(for: videoId) else {
            throw MusicDownloadError.invalidVideoId
        }
        let fileManager = FileManager.default
        guard !isBlocked else {
            try? fileManager.removeItem(at: part)
            throw MusicDownloadError.indexUnavailable
        }
        guard Self.fileSize(at: part) == expectedBytes else {
            try? fileManager.removeItem(at: part)
            throw MusicDownloadError.lengthMismatch
        }
        if fileManager.fileExists(atPath: audio.path) {
            _ = try fileManager.replaceItemAt(audio, withItemAt: part)
        } else {
            try fileManager.moveItem(at: part, to: audio)
        }

        let existing = entries[videoId]
        let entry = Entry(
            track: track, bytes: expectedBytes, downloadedAt: now(), durationSeconds: durationSeconds,
            standalone: standalone || existing?.standalone == true, coverFile: existing?.coverFile
        )
        _ = preservedEntries.removeValue(forKey: videoId)
        entries[videoId] = entry
        markIndexDirty()
        return entry
    }

    /// Takes the song off the user's list of their own downloads. The store alone says whether the file goes, since only it
    /// knows every collection: a song a collection lists (or might, while a record is unread) keeps its entry and its file
    /// and only loses its own flag, and the answer says so. Otherwise the song's `.part` file, entry and (unless
    /// `keepingFile`) file go. A file with no entry is never deleted here, and nothing is touched while the index could not
    /// be read. `keepingFile` is for a song that is playing from its file: `removeFileIfUnlisted` deletes it later.
    @discardableResult
    func remove(videoId: String, keepingFile: Bool = false) -> Release {
        guard !isBlocked, let audio = audioURL(for: videoId), let part = partURL(for: videoId) else { return .untouched }
        try? FileManager.default.removeItem(at: part)
        guard let current = entries[videoId] else { return .untouched }
        if isHeld(videoId) {
            if current.standalone {
                entries[videoId]?.standalone = false
                writeIndexLoggingFailure("a removal")
            }
            return .keptForCollection(entries[videoId] ?? current)
        }
        entries[videoId] = nil
        if !keepingFile { try? FileManager.default.removeItem(at: audio) }
        do {
            try writeIndex()
        } catch {
            // The file is already gone (or kept), so the next load drops the entry anyway.
            Self.log.error("The downloads index could not be written after a removal")
        }
        deleteCoversIfUnnamed(current.coverFile.map { [$0] } ?? [])
        removeEmptyFolders()
        return .deleted
    }

    /// Drops the song's entry and its file whatever lists it: for a file that is gone or the wrong size, which no
    /// collection can use. A collection that lists the song keeps listing it, and the next sync downloads it again. A song
    /// with no entry is not touched.
    func discard(videoId: String) {
        guard !isBlocked, let audio = audioURL(for: videoId), let current = entries[videoId] else { return }
        entries[videoId] = nil
        try? FileManager.default.removeItem(at: audio)
        writeIndexLoggingFailure("discarding a damaged song")
        deleteCoversIfUnnamed(current.coverFile.map { [$0] } ?? [])
        removeEmptyFolders()
    }

    /// Deletes the song's file when nothing lists it: for a file `remove(keepingFile:)` left under the player. A song
    /// downloaded again since, and one whose entry the store holds back unread, keeps its file. The audio and covers
    /// folders go too when that leaves them empty.
    func removeFileIfUnlisted(videoId: String) {
        guard !isBlocked, entries[videoId] == nil, preservedEntries[videoId] == nil,
              let audio = audioURL(for: videoId) else { return }
        try? FileManager.default.removeItem(at: audio)
        removeEmptyFolders()
    }

    // MARK: - Collections

    /// The downloaded playlists and albums, by browse id.
    func collectionList() -> [String: Collection] { collections }

    /// Whether a collection lists the song. True for every song while a record this version could not read exists, since
    /// that record might list it.
    func isHeld(_ videoId: String) -> Bool {
        !preservedCollections.isEmpty || collections.values.contains { $0.videoIds.contains(videoId) }
    }

    /// Lists the collection (replacing the record `browseId` had), writing the index before anything is deleted. The songs
    /// the old record listed and the new one does not leave with it, unless another collection lists them or they were
    /// downloaded on their own: their entries are returned. `keepingFiles` names songs whose files stay for now, because
    /// they are playing from them (see `removeFileIfUnlisted`). Throws `indexUnavailable` while the index could not be
    /// read, and the disk's error when it cannot be written; nothing has changed then.
    @discardableResult
    func saveCollection(_ browseId: String, _ collection: Collection, keepingFiles: Set<String> = []) throws -> [String] {
        beforeCollectionChange?(browseId)
        guard !isBlocked else { throw MusicDownloadError.indexUnavailable }
        let previous = collections[browseId]
        let previousEntries = entries
        collections[browseId] = collection

        var dropped: [String] = []
        if let previous, preservedCollections.isEmpty {
            let listed = Set(collection.videoIds)
            let held = Self.heldIDs(in: collections)
            var seen = Set<String>()
            for videoId in previous.videoIds where !listed.contains(videoId) && !held.contains(videoId) {
                if seen.insert(videoId).inserted, entries[videoId]?.standalone == false { dropped.append(videoId) }
            }
        }
        var droppedEntries: [Entry] = []
        for videoId in dropped { if let entry = entries.removeValue(forKey: videoId) { droppedEntries.append(entry) } }

        do {
            try writeIndex()
        } catch {
            collections[browseId] = previous
            entries = previousEntries
            throw error
        }
        var coverNames = droppedEntries.compactMap(\.coverFile)
        if let old = previous?.coverFile, old != collection.coverFile { coverNames.append(old) }
        deleteFiles(of: droppedEntries.map(\.track.videoId), except: keepingFiles)
        deleteCoversIfUnnamed(coverNames)
        return dropped
    }

    /// Drops the collection, and with it every song only it listed that was not downloaded on its own: their entries and
    /// files go, and their ids are returned. Nothing is deleted while a record this version could not read exists, or
    /// while the index could not be written, when the record is put back and returned.
    @discardableResult
    func removeCollection(_ browseId: String, keepingFiles: Set<String> = []) -> CollectionRemoval {
        beforeCollectionChange?(browseId)
        guard !isBlocked, let removed = collections.removeValue(forKey: browseId) else {
            return CollectionRemoval(dropped: [], restored: nil)
        }
        let previousEntries = entries

        var dropped: [String] = []
        if preservedCollections.isEmpty {
            let held = Self.heldIDs(in: collections)
            var seen = Set<String>()
            for videoId in removed.videoIds where !held.contains(videoId) {
                if seen.insert(videoId).inserted, entries[videoId]?.standalone == false { dropped.append(videoId) }
            }
        }
        var droppedEntries: [Entry] = []
        for videoId in dropped { if let entry = entries.removeValue(forKey: videoId) { droppedEntries.append(entry) } }

        do {
            try writeIndex()
        } catch {
            Self.log.error("The downloads index could not be written after removing a collection, so nothing was deleted")
            collections[browseId] = removed
            entries = previousEntries
            return CollectionRemoval(dropped: [], restored: removed)
        }
        deleteFiles(of: dropped, except: keepingFiles)
        deleteCoversIfUnnamed(droppedEntries.compactMap(\.coverFile) + (removed.coverFile.map { [$0] } ?? []))
        return CollectionRemoval(dropped: dropped, restored: nil)
    }

    /// Records how the last sync of the collection ended. `syncedAt` is when the list last matched the page; nil leaves
    /// the time of the last good sync as it was.
    func setSyncResult(_ browseId: String, _ result: Collection.SyncResult, syncedAt: Date?) {
        guard !isBlocked, collections[browseId] != nil else { return }
        collections[browseId]?.syncResult = result
        if let syncedAt { collections[browseId]?.lastSyncedAt = syncedAt }
        writeIndexLoggingFailure("a sync result")
    }

    /// The song was asked for on its own. The flag is kept in memory and written with the next index write, so a write that
    /// failed is tried again then.
    func setStandalone(videoId: String) {
        guard !isBlocked, entries[videoId]?.standalone == false else { return }
        entries[videoId]?.standalone = true
        markIndexDirty()
    }

    // MARK: - Covers

    /// Saves a cover picture for the song and names it in the song's entry. False, with nothing written, when the song has
    /// no entry, the name is not a cover name, or the disk refuses. A picture already saved under the name is not written
    /// again: the name is a hash of its address. A picture the song had before is deleted if nothing else names it, and
    /// the index is written first; a first picture is written with the next index write.
    func saveCover(_ data: Data, named name: String, forVideoId videoId: String) -> Bool {
        guard !isBlocked, let entry = entries[videoId], writeCoverFile(data, named: name) else { return false }
        entries[videoId]?.coverFile = name
        guard let old = entry.coverFile, old != name else {
            if entry.coverFile != name { markIndexDirty() }
            return true
        }
        do {
            try writeIndex()
        } catch {
            entries[videoId]?.coverFile = entry.coverFile
            deleteCoversIfUnnamed([name])
            return false
        }
        deleteCoversIfUnnamed([old])
        return true
    }

    /// Saves a cover picture for the collection, as `saveCover(_:named:forVideoId:)` does for a song.
    func saveCover(_ data: Data, named name: String, forCollection browseId: String) -> Bool {
        guard !isBlocked, let collection = collections[browseId], writeCoverFile(data, named: name) else { return false }
        collections[browseId]?.coverFile = name
        guard let old = collection.coverFile, old != name else {
            if collection.coverFile != name { markIndexDirty() }
            return true
        }
        do {
            try writeIndex()
        } catch {
            collections[browseId]?.coverFile = collection.coverFile
            deleteCoversIfUnnamed([name])
            return false
        }
        deleteCoversIfUnnamed([old])
        return true
    }

    private func writeCoverFile(_ data: Data, named name: String) -> Bool {
        guard let url = coverURL(named: name) else { return false }
        // The picture is saved already (the name is a hash of its address): `data` is not needed.
        if hasCover(named: name) { return true }
        guard !data.isEmpty else { return false }
        do {
            try prepareRoot()
            try FileManager.default.createDirectory(at: coversDirectory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            Self.log.error("A cover picture could not be written")
            return false
        }
    }

    // MARK: - Remove all

    /// What `removeAll` did.
    struct Wipe: Equatable, Sendable {
        /// The folder is not the Downloads folder (or is a link, or not a folder), so nothing was touched.
        var refused = false
        /// Files, links and folders deleted. The index, which is replaced and not deleted, is not counted.
        var removed = 0
        /// Items that could not be deleted. Their songs are still listed.
        var failed = 0
        /// What the store lists afterwards: empty after a clean wipe, the songs whose files could not be deleted after a
        /// partial one, and everything after a refusal.
        var entries: [String: Entry] = [:]
    }

    /// Whether `url` has the shape of the Downloads folder: a path that ends in `Application Support/Deci/Downloads`, with
    /// at least one folder above it and no `.` or `..` anywhere. Only the path is read, never the disk.
    nonisolated static func hasDownloadsShape(_ url: URL) -> Bool {
        let parts = url.pathComponents
        guard parts.count >= 5, !parts.contains("."), !parts.contains("..") else { return false }
        return parts.suffix(3).elementsEqual(["Application Support", "Deci", "Downloads"])
    }

    /// Whether the store at `url` may be emptied: the path has the shape of the Downloads folder both as given and with
    /// every link on the way resolved, and Application Support, Deci and Downloads are each a real folder (or not there yet),
    /// never a link. A link at Deci that leads to another folder shaped like the Downloads folder is refused too: the path
    /// would look right on both counts.
    nonisolated static func isDeletableRoot(_ url: URL) -> Bool {
        guard url.isFileURL, hasDownloadsShape(url), hasDownloadsShape(url.resolvingSymlinksInPath()) else { return false }
        let downloads = url
        let deci = downloads.deletingLastPathComponent()
        let support = deci.deletingLastPathComponent()
        for folder in [support, deci, downloads] {
            var info = stat()
            // Nothing below a folder that is not there can be there.
            guard lstat(folder.path, &info) == 0 else { return errno == ENOENT }
            guard (info.st_mode & S_IFMT) == S_IFDIR else { return false }
        }
        return true
    }

    /// Whether `removeAll` would work on this store's folder, without touching it. The service asks before it stops
    /// anything.
    nonisolated func canRemoveAll() -> Bool { Self.isDeletableRoot(root) }

    /// Deletes everything inside the Downloads folder (audio, `.part` files, covers, the markers of an earlier launch's
    /// trouble, files nobody owns) and leaves a fresh empty index. Nothing outside the folder is touched: the folder is
    /// opened through handles that never follow a link, the walk deletes relative to those handles (so a link swapped in
    /// while it runs is unlinked or refused, never followed), a link inside is unlinked and never followed, an item on
    /// another device is left, and a folder that is not the Downloads folder is refused.
    ///
    /// The empty index is written first, and if that fails nothing is deleted and the store is as it was. Files named in
    /// `keepingFiles` (the song playing from its file) stay, unlisted, for `removeFileIfUnlisted`. An item that cannot be
    /// deleted is counted, and a song whose file is still there stays listed, in memory and in the index, so what the store
    /// says matches the disk. The store is unblocked afterwards and the markers are gone, so the next launch sweeps audio
    /// nobody owns again. Changes that were waiting for their timer are dropped with the rest.
    @discardableResult
    func removeAll(keepingFiles: Set<String> = []) -> Wipe {
        guard Self.isDeletableRoot(root) else { return Wipe(refused: true, entries: entries) }
        let handle: Int32
        switch MusicDownloadTreeWipe.openFolder(root) {
        case .refused:
            return Wipe(refused: true, entries: entries)
        case .unreadable:
            Self.log.error("Remove all stopped because the downloads folder could not be opened, so nothing was deleted")
            return Wipe(failed: 1, entries: entries)
        case .missing:
            // A folder that is not there has nothing in it, and is not made for the wipe.
            forgetEverything()
            isIndexDirty = false
            return Wipe()
        case .folder(let opened):
            handle = opened
        }
        defer { close(handle) }

        let fileManager = FileManager.default
        let before = (
            entries: entries, collections: collections, preservedEntries: preservedEntries,
            preservedCollections: preservedCollections, isBlocked: isBlocked, isIndexDirty: isIndexDirty,
            hasLoaded: hasLoaded
        )
        forgetEverything()
        do {
            try writeIndex()
        } catch {
            entries = before.entries
            collections = before.collections
            preservedEntries = before.preservedEntries
            preservedCollections = before.preservedCollections
            isBlocked = before.isBlocked
            isIndexDirty = before.isIndexDirty
            hasLoaded = before.hasLoaded
            if isIndexDirty { markIndexDirty() }
            Self.log.error("Remove all stopped because the empty index could not be written, so nothing was deleted")
            return Wipe(failed: 1, entries: entries)
        }

        let keptNames = Set(keepingFiles.compactMap { id in
            Self.isValidVideoId(id) ? "\(id).\(Self.audioExtension)" : nil
        })
        var tally = MusicDownloadTreeWipe.deleteContents(
            of: handle, skipping: [Self.indexName], keepingInside: keptNames.isEmpty ? [:] : ["audio": keptNames]
        )

        // A song whose file is still there is still a download.
        var survivors: [String: Entry] = [:]
        for (videoId, entry) in before.entries where !keepingFiles.contains(videoId) {
            guard let audio = audioURL(for: videoId), fileManager.fileExists(atPath: audio.path) else { continue }
            var kept = entry
            kept.standalone = true
            if let cover = kept.coverFile, !hasCover(named: cover) { kept.coverFile = nil }
            survivors[videoId] = kept
        }
        if !survivors.isEmpty {
            entries = survivors
            do {
                try writeIndex()
            } catch {
                tally.failed += 1
                Self.log.error("The downloads index could not be written after a partial remove all")
            }
        }
        if tally.failed > 0 {
            Self.log.error("Remove all deleted \(tally.removed, privacy: .public) items and could not delete \(tally.failed, privacy: .public)")
        }
        return Wipe(removed: tally.removed, failed: tally.failed, entries: entries)
    }

    /// Drops everything the store holds in memory and unblocks it, as the start of a wipe does.
    private func forgetEverything() {
        flushTask?.cancel()
        flushTask = nil
        entries = [:]
        collections = [:]
        preservedEntries = [:]
        preservedCollections = [:]
        isBlocked = false
        hasLoaded = true
    }

    /// Removes the audio and covers folders when nothing is left in them, so a folder that holds no download reads as
    /// holding nothing. `rmdir` takes only an empty folder, and every write into these folders happens inside this actor,
    /// so a song or cover being written is never caught between.
    private func removeEmptyFolders() {
        rmdir(audioDirectory.path)
        rmdir(coversDirectory.path)
    }

    // MARK: - Helpers

    private func deleteFiles(of videoIds: [String], except kept: Set<String>) {
        for videoId in videoIds where !kept.contains(videoId) {
            if let audio = audioURL(for: videoId) { try? FileManager.default.removeItem(at: audio) }
            if let part = partURL(for: videoId) { try? FileManager.default.removeItem(at: part) }
        }
    }

    private func writeIndexLoggingFailure(_ what: String) {
        do {
            try writeIndex()
        } catch {
            Self.log.error("The downloads index could not be written after \(what, privacy: .public)")
        }
    }

    /// The root folder, created if need be and left out of backups: the audio is large and can be downloaded again.
    private func prepareRoot() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard !isRootPrepared else { return }
        var folder = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        do {
            try folder.setResourceValues(values)
            isRootPrepared = true
        } catch {
            Self.log.error("The downloads folder could not be left out of backups")
        }
    }

    /// Writes the index now, with everything pending. Counts as a write only when the file was replaced.
    private func writeIndex() throws {
        guard !isBlocked else { throw MusicDownloadError.indexUnavailable }
        try prepareRoot()
        var data = try Index(entries: entries, collections: collections).encoded()
        if !preservedEntries.isEmpty || !preservedCollections.isEmpty {
            data = try mergingPreserved(into: data)
        }
        try data.write(to: indexURL, options: .atomic)
        indexWriteCount += 1
        isIndexDirty = false
        flushTask?.cancel()
        flushTask = nil
    }

    // MARK: - Writing the index later

    /// Notes a change that only adds, which the index gets a moment later: songs finish a few seconds apart, and a
    /// playlist of thousands would otherwise rewrite the whole index for each. Anything that deletes a file writes at once.
    private func markIndexDirty() {
        isIndexDirty = true
        guard flushTask == nil else { return }
        let delay = indexFlushDelay
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.flushIfDue()
        }
    }

    private func flushIfDue() {
        flushTask = nil
        // A folder that is gone (deleted by hand, or by a test) is not brought back for a bookkeeping write.
        guard isIndexDirty, FileManager.default.fileExists(atPath: root.path) else { return }
        flushPendingIndex()
    }

    /// Writes the index if a change is waiting for it. A write that fails is logged and tried again by the next write.
    func flushIndex() {
        flushTask?.cancel()
        flushTask = nil
        guard isIndexDirty else { return }
        flushPendingIndex()
    }

    private func flushPendingIndex() {
        do {
            try writeIndex()
        } catch {
            Self.log.error("The downloads index could not be written, so the change waits for the next write")
        }
    }

    /// The index in `data` with the entries and collections this version could not read put back as they were.
    private func mergingPreserved(into data: Data) throws -> Data {
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.coderInvalidValue)
        }
        var rawEntries = object["entries"] as? [String: Any] ?? [:]
        for (key, raw) in preservedEntries where rawEntries[key] == nil { rawEntries[key] = raw }
        var rawCollections = object["collections"] as? [String: Any] ?? [:]
        for (key, raw) in preservedCollections where rawCollections[key] == nil { rawCollections[key] = raw }
        object["entries"] = rawEntries
        object["collections"] = rawCollections
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
