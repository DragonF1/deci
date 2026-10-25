// Deci/Music/Downloads/MusicDownloadTreeWipe.swift
import Foundation

/// Empties the Downloads folder with calls made relative to open folder handles, so nothing it deletes is found by looking
/// a path up again: a link swapped in for a folder while the walk runs is unlinked or refused, never followed, and the walk
/// cannot be led out of the folder it was given. Plain functions with no state, meant to run inside the download store.
nonisolated enum MusicDownloadTreeWipe {
    /// How many folders deep the walk goes below the Downloads folder (its own children are level 1). Real downloads are two
    /// levels deep; anything past the cap is left alone and counted as failed, so a loop or a hostile tree cannot make the
    /// walk run for long or exhaust the process's open handles.
    static let maxDepth = 16

    struct Tally: Equatable, Sendable {
        /// Files, links and folders deleted.
        var removed = 0
        /// Items that could not be deleted (or were on another device, or too deep).
        var failed = 0
    }

    enum Opening: Equatable {
        /// The Downloads folder, open for the walk. The caller closes it.
        case folder(Int32)
        /// The folder, or a folder above it, is not there.
        case missing
        /// Application Support, Deci or Downloads is a link or not a folder, so nothing may be deleted through it.
        case refused
        /// The folder could not be opened (no permission, say).
        case unreadable
    }

    private static let openFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC

    // MARK: - Opening

    /// Opens `<...>/Application Support/Deci/Downloads` one level at a time, each relative to the one before and none of
    /// them through a link, so a link at any of the three is refused whatever it points at (even a folder with the very same
    /// shape). Links above Application Support (the home folder on a moved volume, say) are the user's own layout and are
    /// followed.
    static func openFolder(_ root: URL) -> Opening {
        guard root.isFileURL, MusicDownloadStore.hasDownloadsShape(root) else { return .refused }
        let deci = root.deletingLastPathComponent()
        let support = deci.deletingLastPathComponent()

        var parent = open(support.path, openFlags)
        if parent < 0 { return opening(failedWith: errno) }
        for name in [deci.lastPathComponent, root.lastPathComponent] {
            let child = openat(parent, name, openFlags)
            let reason = errno
            close(parent)
            if child < 0 { return opening(failedWith: reason) }
            parent = child
        }
        return .folder(parent)
    }

    private static func opening(failedWith code: Int32) -> Opening {
        switch code {
        case ENOENT: return .missing
        // A link met with no-follow reads as ELOOP, or as "not a directory" once the directory flag is also given.
        case ELOOP, ENOTDIR: return .refused
        default: return .unreadable
        }
    }

    // MARK: - Deleting

    /// Deletes everything inside the open folder `handle`, leaving the handle open. A link is unlinked and its target left
    /// alone. A folder with something left in it (a kept name, or an item that could not go) is not removed itself.
    /// - Parameters:
    ///   - skipping: Names at the top that are left alone and not counted: the index, which the caller replaces.
    ///   - keepingInside: Folders at the top, by name, and the names inside each that stay (the song that is playing).
    ///   - expectedDevice: The device every item must be on. Defaults to the folder's own, so a mount point inside it is
    ///     counted as failed and never deleted through.
    static func deleteContents(
        of handle: Int32,
        skipping: Set<String> = [],
        keepingInside: [String: Set<String>] = [:],
        expectedDevice: dev_t? = nil
    ) -> Tally {
        var own = stat()
        guard fstat(handle, &own) == 0 else { return Tally(removed: 0, failed: 1) }
        var tally = Tally()
        deleteContents(
            of: handle, depth: 0, device: expectedDevice ?? own.st_dev, skipping: skipping, keepingInside: keepingInside,
            tally: &tally
        )
        return tally
    }

    /// - Returns: Whether something in the folder stays, so the caller must not remove it.
    @discardableResult
    private static func deleteContents(
        of handle: Int32, depth: Int, device: dev_t, skipping: Set<String>, keepingInside: [String: Set<String>],
        tally: inout Tally
    ) -> Bool {
        guard let names = list(handle) else {
            tally.failed += 1
            return true
        }
        var leftSomething = false
        for name in names {
            if skipping.contains(name) {
                leftSomething = true
                continue
            }
            var info = stat()
            guard fstatat(handle, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                // Gone already: nothing to delete.
                if errno != ENOENT {
                    tally.failed += 1
                    leftSomething = true
                }
                continue
            }
            guard info.st_dev == device else {
                tally.failed += 1
                leftSomething = true
                continue
            }
            if (info.st_mode & S_IFMT) == S_IFDIR {
                if !deleteFolder(
                    named: name, in: handle, depth: depth + 1, device: device, keeping: keepingInside[name] ?? [], tally: &tally
                ) { leftSomething = true }
            } else if unlinkat(handle, name, 0) == 0 {
                tally.removed += 1
            } else if errno != ENOENT {
                tally.failed += 1
                leftSomething = true
            }
        }
        return leftSomething
    }

    /// Deletes the folder `name` inside `parent`, everything in it first (but the names in `kept`). Returns whether the
    /// folder is gone.
    private static func deleteFolder(
        named name: String, in parent: Int32, depth: Int, device: dev_t, keeping kept: Set<String>, tally: inout Tally
    ) -> Bool {
        guard depth <= maxDepth else {
            tally.failed += 1
            return false
        }
        let folder = openat(parent, name, openFlags)
        guard folder >= 0 else {
            // A link standing where the folder was (ELOOP) or something else swapped in: left, and counted.
            if errno == ENOENT { return true }
            tally.failed += 1
            return false
        }
        var info = stat()
        guard fstat(folder, &info) == 0, info.st_dev == device else {
            close(folder)
            tally.failed += 1
            return false
        }

        let leftSomething = deleteContents(
            of: folder, depth: depth, device: device, skipping: kept, keepingInside: [:], tally: &tally
        )
        close(folder)
        guard !leftSomething else { return false }

        if unlinkat(parent, name, AT_REMOVEDIR) == 0 {
            tally.removed += 1
            return true
        }
        if errno == ENOENT { return true }
        tally.failed += 1
        return false
    }

    // MARK: - Listing

    /// Every name in the open folder, read in full before anything is deleted so the listing is not disturbed by the
    /// deleting. Nil when the folder cannot be read. The handle stays open.
    private static func list(_ handle: Int32) -> [String]? {
        let copy = dup(handle)
        guard copy >= 0, let stream = fdopendir(copy) else {
            if copy >= 0 { close(copy) }
            return nil
        }
        defer { closedir(stream) }
        rewinddir(stream)
        var names: [String] = []
        while let entry = readdir(stream) {
            var raw = entry.pointee.d_name
            let capacity = MemoryLayout.size(ofValue: raw)
            let name = withUnsafePointer(to: &raw) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return names
    }
}
