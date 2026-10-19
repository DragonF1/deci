// Deci/Music/Lyrics/LyricsDiskCache.swift
import CryptoKit
import Foundation
import os

/// What the lyrics sources said about a video, and who is credited for it, kept on disk so the same song is never
/// asked for twice a month. One small JSON file per video, named by a hash of the video id. Found lyrics last 30
/// days, "not found" 3, and the folder keeps the newest 500 files. Network errors and 429s are never stored: the
/// chain only calls `store` with a real answer.
///
/// Entries are version 2, which carry the credit. A version 1 file (from before YouTube Music, when a "not found"
/// could only mean LRCLIB did not know the song) is a miss and is deleted, so it cannot hide YouTube Music's lyrics.
///
/// An actor, so file reads and writes run off the main thread and two writes never prune over each other.
actor LyricsDiskCache {
    static let defaultMaxEntries = 500
    static let foundLifetime: TimeInterval = 30 * 86_400
    static let notFoundLifetime: TimeInterval = 3 * 86_400

    private struct Entry: Codable {
        var version: Int
        var storedAt: Double
        var kind: String
        var lines: [Line]?
        var text: String?
        var credit: String?

        struct Line: Codable {
            var time: Double
            var text: String
        }
    }

    private static let currentVersion = 2
    private static let log = Logger(subsystem: "com.abraham.Deci", category: "MusicLyrics")

    private let directory: URL
    private let maxEntries: Int
    private let now: @Sendable () -> Date

    init(directory: URL, maxEntries: Int = LyricsDiskCache.defaultMaxEntries, now: @escaping @Sendable () -> Date = Date.init) {
        self.directory = directory
        self.maxEntries = max(1, maxEntries)
        self.now = now
    }

    /// ~/Library/Caches/com.abraham.Deci/Music/Lyrics
    static func liveDirectory() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("com.abraham.Deci/Music/Lyrics", isDirectory: true)
    }

    static func live() -> LyricsDiskCache {
        LyricsDiskCache(directory: liveDirectory())
    }

    /// The video id is hashed so no id, and nothing a hostile one could contain, reaches the file system.
    static func fileName(forVideoId videoId: String) -> String {
        SHA256.hash(data: Data(videoId.utf8)).map { String(format: "%02x", $0) }.joined() + ".json"
    }

    // MARK: - Reading

    /// The stored answer, or nil when there is none, it has expired or the file cannot be read. A file that is
    /// expired, damaged or of another version is deleted on the way. Whatever was stored is final, so the length the
    /// player knows no longer matters to it.
    func cached(videoId: String) -> LyricsAnswer? {
        let url = fileURL(videoId)
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let entry = try? JSONDecoder().decode(Entry.self, from: data), entry.version == Self.currentVersion,
              let result = Self.result(from: entry)
        else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        let lifetime = result == .notFound ? Self.notFoundLifetime : Self.foundLifetime
        guard now().timeIntervalSince1970 - entry.storedAt <= lifetime else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return LyricsAnswer(result: result, credit: entry.credit, lengthMatters: false)
    }

    // MARK: - Writing

    func store(_ result: LyricsResult, credit: String? = nil, videoId: String) {
        let stamp = now()
        let entry = Self.entry(for: result, credit: credit, storedAt: stamp)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = fileURL(videoId)
            try JSONEncoder().encode(entry).write(to: url, options: .atomic)
            // Pruning goes by file date, so the date follows the injected clock.
            try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: url.path)
        } catch {
            Self.log.error("could not write lyrics cache: \(error.localizedDescription, privacy: .public)")
            return
        }
        prune()
    }

    // MARK: - Files

    private func fileURL(_ videoId: String) -> URL {
        directory.appendingPathComponent(Self.fileName(forVideoId: videoId), isDirectory: false)
    }

    /// Keeps the newest `maxEntries` files.
    private func prune() {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ), urls.count > maxEntries else { return }
        let dated = urls.map { url in
            (url: url, date: (try? url.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast)
        }
        for stale in dated.sorted(by: { $0.date > $1.date }).dropFirst(maxEntries) {
            try? FileManager.default.removeItem(at: stale.url)
        }
    }

    // MARK: - Encoding

    private static func entry(for result: LyricsResult, credit: String?, storedAt: Date) -> Entry {
        let stamp = storedAt.timeIntervalSince1970
        switch result {
        case .synced(let lines):
            return Entry(
                version: currentVersion, storedAt: stamp, kind: "synced",
                lines: lines.map { Entry.Line(time: $0.time, text: $0.text) }, text: nil, credit: credit
            )
        case .plain(let text):
            return Entry(version: currentVersion, storedAt: stamp, kind: "plain", lines: nil, text: text, credit: credit)
        case .instrumental:
            return Entry(version: currentVersion, storedAt: stamp, kind: "instrumental", lines: nil, text: nil, credit: credit)
        case .notFound:
            return Entry(version: currentVersion, storedAt: stamp, kind: "notFound", lines: nil, text: nil, credit: credit)
        }
    }

    private static func result(from entry: Entry) -> LyricsResult? {
        switch entry.kind {
        case "synced":
            guard let lines = entry.lines, !lines.isEmpty else { return nil }
            return .synced(lines.map { LyricLine(time: $0.time, text: $0.text) })
        case "plain":
            guard let text = entry.text, !text.isEmpty else { return nil }
            return .plain(text)
        case "instrumental": return .instrumental
        case "notFound": return .notFound
        default: return nil
        }
    }
}
