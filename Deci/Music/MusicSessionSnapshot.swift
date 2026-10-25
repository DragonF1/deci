import Foundation

/// What the Music tab was doing, saved so the next launch can pick it up: the song, how far into it, and the queue the
/// way `MusicQueue` models it (upcoming songs, the played ones kept for Previous, the page or radio the queue carries on
/// from, shuffle and the staged autoplay). It belongs to one signed-in channel and is good for `lifetime` after the last
/// save; after that, or in a different format, or for another channel, it is thrown away and the app starts fresh.
struct MusicSessionSnapshot: Codable, Equatable, Sendable {
    /// The file format. A file of any other version is dropped instead of read.
    static let version = 1
    /// How long after the last save the session is still picked up.
    static let lifetime: TimeInterval = 3600
    /// The most songs kept after the current one. A longer queue loses its far end.
    static let maxUpcoming = 500
    /// The most songs kept before the current one, for Previous.
    static let maxPlayed = 100
    /// A restored song starts this far short of its end at the latest, so it does not open on its last breath.
    static let endMargin: TimeInterval = 2

    let version: Int
    /// When the session was last written; the hour counts from here.
    let savedAt: Date
    /// An opaque key for the signed-in channel (see `InnerTubeParser.channelKey`), so one account never resumes
    /// another's queue.
    let channelKey: String
    /// Seconds into the current song. Never negative or non-finite.
    let position: TimeInterval
    let queue: MusicQueue

    init(savedAt: Date, channelKey: String, position: TimeInterval, queue: MusicQueue) {
        version = Self.version
        self.savedAt = savedAt
        self.channelKey = channelKey
        self.position = position.isFinite && position > 0 ? position : 0
        self.queue = queue.trimmed(maxPlayed: Self.maxPlayed, maxUpcoming: Self.maxUpcoming)
    }

    /// Where a restored song starts: the saved position, held `endMargin` short of the end, and the beginning when the
    /// length is not known.
    func clampedPosition(duration: TimeInterval?) -> TimeInterval {
        guard let duration, duration.isFinite, duration > 0 else { return 0 }
        return min(position, max(0, duration - Self.endMargin))
    }

    /// The same song, queue and channel, and a position within a second: nothing the listener would notice has changed,
    /// so there is nothing to write.
    func hasSameState(as other: MusicSessionSnapshot) -> Bool {
        channelKey == other.channelKey && queue == other.queue && abs(position - other.position) <= 1
    }

    // MARK: - File format

    func encoded() throws -> Data {
        try Self.encoder.encode(self)
    }

    /// The largest file read back. The caps keep a real one far below this, so anything bigger is damaged.
    static let maxFileSize = 4 * 1024 * 1024

    /// The snapshot in `data`, or nil when it is empty, damaged, too big, of another version, or holds a queue that
    /// does not stand on one of its own songs. A later format without this one's fields fails the decode itself, so
    /// the file is parsed once.
    static func decode(_ data: Data) -> MusicSessionSnapshot? {
        guard data.count <= maxFileSize,
              let snapshot = try? decoder.decode(MusicSessionSnapshot.self, from: data),
              snapshot.version == version,
              let index = snapshot.queue.currentIndex, snapshot.queue.tracks.indices.contains(index)
        else { return nil }
        return snapshot
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
