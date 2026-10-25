// Deci/Music/Downloads/MusicDownloadDiskUsage.swift
import Foundation

/// What the Downloads folder holds, read from the disk and nothing else: how much room it takes, whether it holds anything
/// but the index, and (from the index file alone) how many songs and collections it lists. Plain functions with no state,
/// meant to run off the main thread: a folder of thousands of songs takes a moment to walk.
nonisolated enum MusicDownloadDiskUsage {
    struct Usage: Equatable, Sendable {
        /// The room the folder takes on the disk: the allocated size of everything under it.
        var bytes: Int64
        /// Something besides the index is there: audio, covers, half-written songs, a marker, a stray file or an empty folder.
        var hasFiles: Bool
    }

    struct Counts: Equatable, Sendable {
        var songs: Int
        var collections: Int
    }

    // MARK: - Room

    /// The allocated size of every file under `root` (blocks, not the bytes the files hold, as Finder counts them), hidden
    /// files, covers, half-written songs and files nobody owns included. A link counts as the link and is never followed,
    /// so nothing outside the folder is read. A folder that cannot be read is skipped and the rest still counts. A root
    /// that is missing, is a link or is not a folder takes no room and holds nothing. A walk whose task is cancelled stops
    /// at once and reads as empty, so a caller that no longer wants the answer never waits out a big folder and never sees a
    /// size that stops halfway.
    static func measure(root: URL) -> Usage {
        let empty = Usage(bytes: 0, hasFiles: false)
        var info = stat()
        guard !Task.isCancelled, lstat(root.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return empty }
        guard let top = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return empty }

        var bytes = allocated(info)
        let hasFiles = top.contains { $0 != MusicDownloadStore.indexName }
        var folders: [(path: String, names: [String])] = [(root.path, top)]
        while let folder = folders.popLast() {
            for name in folder.names {
                if Task.isCancelled { return empty }
                let path = folder.path + "/" + name
                var child = stat()
                guard lstat(path, &child) == 0 else { continue }
                bytes += allocated(child)
                guard (child.st_mode & S_IFMT) == S_IFDIR,
                      let inside = try? FileManager.default.contentsOfDirectory(atPath: path) else { continue }
                folders.append((path, inside))
            }
        }
        return Usage(bytes: bytes, hasFiles: hasFiles)
    }

    private static func allocated(_ info: stat) -> Int64 {
        max(0, Int64(info.st_blocks)) * 512
    }

    // MARK: - Counts

    /// The songs and the collections the index file lists, counted without decoding them: an entry this version cannot
    /// read is still a song on the disk. A missing, empty or broken index, or a list of the wrong shape, counts as none.
    static func storedCounts(at root: URL) -> Counts {
        let url = root.appendingPathComponent(MusicDownloadStore.indexName, isDirectory: false)
        guard let data = try? Data(contentsOf: url),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return Counts(songs: 0, collections: 0)
        }
        return Counts(
            songs: (object["entries"] as? [String: Any])?.count ?? 0,
            collections: (object["collections"] as? [String: Any])?.count ?? 0
        )
    }
}
