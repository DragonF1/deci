import Foundation
import os

/// What is remembered per player build (the 8-hex-digit hash in the player JS URL): the
/// signatureTimestamp the player request needs, and the solver's preprocessed player so a warm
/// resolve skips the 2 MB download and the meriyah parse. Holds no cookies and no stream URLs.
struct PlayerCache: Sendable {
    let directory: URL

    private struct Meta: Codable {
        var sts: Int
        var savedAt: Double
    }

    private static let log = Logger(subsystem: "com.abraham.Deci", category: "MusicPlayerCache")

    /// ~/Library/Caches/com.abraham.Deci/Music
    static func live() -> PlayerCache {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return PlayerCache(directory: caches.appendingPathComponent("com.abraham.Deci/Music", isDirectory: true))
    }

    // MARK: - Reading

    func sts(forHash hash: String) -> Int? {
        meta(forHash: hash)?.sts
    }

    func preprocessedPlayer(forHash hash: String) -> String? {
        guard let url = playerURL(hash), let data = try? Data(contentsOf: url) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        return text.isEmpty ? nil : text
    }

    /// The newest entry that has both halves, optionally skipping one hash.
    func lastGood(excluding hash: String? = nil) -> (hash: String, sts: Int)? {
        entries()
            .filter { $0.hash != hash && FileManager.default.fileExists(atPath: playerURL($0.hash)?.path ?? "") }
            .max { $0.meta.savedAt < $1.meta.savedAt }
            .map { ($0.hash, $0.meta.sts) }
    }

    // MARK: - Writing

    func saveSTS(_ sts: Int, forHash hash: String, now: Date) {
        write(Meta(sts: sts, savedAt: now.timeIntervalSince1970), forHash: hash)
    }

    func savePreprocessed(_ js: String, forHash hash: String) {
        guard let url = playerURL(hash) else { return }
        do {
            try ensureDirectory()
            try Data(js.utf8).write(to: url, options: .atomic)
        } catch {
            Self.log.error("could not write player cache: \(error.localizedDescription, privacy: .public)")
        }
    }

    func removePreprocessed(forHash hash: String) {
        guard let url = playerURL(hash) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Keeps `hash` and the newest others, up to `limit` entries in all, so the last-good player
    /// survives a rollout that breaks the newest one.
    func prune(keeping hash: String, limit: Int = 2) {
        let ordered = entries().sorted { $0.meta.savedAt > $1.meta.savedAt }
        var keep: Set<String> = [hash]
        for entry in ordered where keep.count < limit { keep.insert(entry.hash) }
        for entry in ordered where !keep.contains(entry.hash) {
            try? FileManager.default.removeItem(at: metaURL(entry.hash)!)
            removePreprocessed(forHash: entry.hash)
        }
    }

    // MARK: - Files

    /// Hashes become file names, so anything but a short token of URL-safe characters is refused.
    private static let hashCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
    )

    private static func isValid(_ hash: String) -> Bool {
        (4...32).contains(hash.count) && hash.unicodeScalars.allSatisfy { hashCharacters.contains($0) }
    }

    private func metaURL(_ hash: String) -> URL? {
        Self.isValid(hash) ? directory.appendingPathComponent("\(hash).json") : nil
    }

    private func playerURL(_ hash: String) -> URL? {
        Self.isValid(hash) ? directory.appendingPathComponent("\(hash).js") : nil
    }

    private func meta(forHash hash: String) -> Meta? {
        guard let url = metaURL(hash), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Meta.self, from: data)
    }

    private func entries() -> [(hash: String, meta: Meta)] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names
            .filter { $0.hasSuffix(".json") }
            .compactMap { name -> (String, Meta)? in
                let hash = String(name.dropLast(".json".count))
                return meta(forHash: hash).map { (hash, $0) }
            }
    }

    private func write(_ meta: Meta, forHash hash: String) {
        guard let url = metaURL(hash), let data = try? JSONEncoder().encode(meta) else { return }
        do {
            try ensureDirectory()
            try data.write(to: url, options: .atomic)
        } catch {
            Self.log.error("could not write player cache: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}
