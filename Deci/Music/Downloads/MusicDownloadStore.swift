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
/// The index has room for what later phases need: `collections` will hold the songs of a downloaded playlist or album
/// by video id, so a song two of them share is deleted only when the last lets go.
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

        init(track: MusicTrack, bytes: Int64, downloadedAt: Date, durationSeconds: Double?) {
            self.track = track
            self.bytes = bytes
            self.downloadedAt = downloadedAt
            self.durationSeconds = durationSeconds
        }
    }

    /// A downloaded playlist or album, for a later phase: its title and the songs it holds, by video id.
    struct Collection: Codable, Equatable, Sendable {
        var title: String
        var videoIds: [String]
    }

    /// The whole of `downloads.json`. The store reads it entry by entry (see `parseIndex`); `decode` is all or nothing.
    struct Index: Codable, Equatable, Sendable {
        static let currentVersion = 1

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

    private static let indexName = "downloads.json"
    private static let unreadablePrefix = "downloads.json.unreadable"
    private static let missingMarkerName = "downloads.json.missing"
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

    init(root: URL, now: @escaping @Sendable () -> Date = Date.init) {
        self.root = root
        self.now = now
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

    /// Where the song's audio is, or nil when `videoId` is not a video id.
    nonisolated func audioURL(for videoId: String) -> URL? {
        guard Self.isValidVideoId(videoId) else { return nil }
        return root.appendingPathComponent("audio/\(videoId).\(Self.audioExtension)", isDirectory: false)
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
        entries = kept
        collections = parsed.collections

        let mayJudge = mayJudgeOrphans && preservedEntries.isEmpty && preservedCollections.isEmpty && !leavesMarkers()
        sweepAudioDirectory(names, sweepingOrphans: mayJudge)
        if changed { try? writeIndex() }
        return entries
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
    /// deleted and never listed. A song downloaded again replaces its entry and its file.
    func commit(_ track: MusicTrack, expectedBytes: Int64, durationSeconds: Double?) throws -> Entry {
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

        let entry = Entry(track: track, bytes: expectedBytes, downloadedAt: now(), durationSeconds: durationSeconds)
        let previousPreserved = preservedEntries.removeValue(forKey: videoId)
        entries[videoId] = entry
        do {
            try writeIndex()
        } catch {
            // An audio file with no entry is useless, so it goes rather than waiting for the next launch's sweep. The
            // file it replaced is gone too, so the earlier entry for the song goes with it.
            entries[videoId] = nil
            if let previousPreserved { preservedEntries[videoId] = previousPreserved }
            try? fileManager.removeItem(at: audio)
            throw error
        }
        return entry
    }

    /// Deletes the song's `.part` file, its entry and, unless `keepingFile`, its file. False when `videoId` is not a
    /// video id or had no entry. A file with no entry is never deleted here, and nothing is touched while the index could
    /// not be read. `keepingFile` is for a song that is playing from its file: `removeFileIfUnlisted` deletes it later.
    @discardableResult
    func remove(videoId: String, keepingFile: Bool = false) -> Bool {
        guard !isBlocked, let audio = audioURL(for: videoId), let part = partURL(for: videoId) else { return false }
        try? FileManager.default.removeItem(at: part)
        guard entries.removeValue(forKey: videoId) != nil else { return false }
        if !keepingFile { try? FileManager.default.removeItem(at: audio) }
        do {
            try writeIndex()
        } catch {
            // The file is already gone (or kept), so the next load drops the entry anyway.
            Self.log.error("The downloads index could not be written after a removal")
        }
        return true
    }

    /// Deletes the song's file when nothing lists it: for a file `remove(keepingFile:)` left under the player. A song
    /// downloaded again since, and one whose entry the store holds back unread, keeps its file.
    func removeFileIfUnlisted(videoId: String) {
        guard !isBlocked, entries[videoId] == nil, preservedEntries[videoId] == nil,
              let audio = audioURL(for: videoId) else { return }
        try? FileManager.default.removeItem(at: audio)
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

    private func writeIndex() throws {
        guard !isBlocked else { throw MusicDownloadError.indexUnavailable }
        try prepareRoot()
        var data = try Index(entries: entries, collections: collections).encoded()
        if !preservedEntries.isEmpty || !preservedCollections.isEmpty {
            data = try mergingPreserved(into: data)
        }
        try data.write(to: indexURL, options: .atomic)
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
