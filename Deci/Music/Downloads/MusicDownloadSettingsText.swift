// Deci/Music/Downloads/MusicDownloadSettingsText.swift
import Foundation

/// The words and the rule of the Downloads section in Settings > General, as plain values: how a size and a count read,
/// what the confirmation says it will delete, when the Remove all button works, and what a removal says about how it ended.
nonisolated enum MusicDownloadSettingsText {
    static let sectionTitle = "Downloads"
    static let storageTitle = "Storage used"
    static let removeTitle = "Remove all downloads"
    static let removeDescription = "Deletes every downloaded song, playlist and album from this Mac."
    static let removeButton = "Remove all"
    static let confirmationTitle = "Remove all downloads?"
    static let confirmButton = "Remove"
    static let calculating = "Calculating"
    /// What the row says while a removal runs.
    static let removing = "Removing"

    // MARK: - Sizes

    /// A size in file units as Finder counts them ("4 KB", "1.5 MB"), in this process's locale. Zero reads "0 bytes", and a
    /// size below zero, which no disk reports, reads as zero.
    static func size(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: max(0, bytes))
    }

    /// The size while it may still be measured: "Calculating" until it is known.
    static func sizeText(_ bytes: Int64?) -> String {
        guard let bytes else { return calculating }
        return size(bytes)
    }

    // MARK: - Counts

    /// "12 songs, 1 playlist or album"; "Nothing downloaded" when both are none; "Calculating" while either is unknown.
    static func summary(songs: Int?, collections: Int?, locale: Locale = .current) -> String {
        guard let songs, let collections else { return calculating }
        let songCount = max(0, songs)
        let collectionCount = max(0, collections)
        var parts: [String] = []
        if songCount > 0 {
            parts.append("\(number(songCount, locale)) \(songCount == 1 ? "song" : "songs")")
        }
        if collectionCount > 0 {
            parts.append(
                "\(number(collectionCount, locale)) \(collectionCount == 1 ? "playlist or album" : "playlists and albums")"
            )
        }
        return parts.isEmpty ? "Nothing downloaded" : parts.joined(separator: ", ")
    }

    private static func number(_ value: Int, _ locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = locale
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    // MARK: - Confirmation

    /// What the confirmation says is about to go. Without a size (still being measured) it says so without one.
    static func confirmationMessage(bytes: Int64?) -> String {
        guard let bytes else { return "Everything downloaded will be deleted from this Mac. You can download it again." }
        return "\(size(bytes)) will be deleted from this Mac. You can download them again."
    }

    // MARK: - The button

    /// Remove all works when no removal runs and there is something to remove: a song or a collection, or (when both counts
    /// are none) files left in the folder that no download owns, so an index that could not be read can still be cleared.
    /// Counts or files not known yet count as none.
    static func canRemoveAll(songs: Int?, collections: Int?, hasFiles: Bool?, isRemoving: Bool) -> Bool {
        guard !isRemoving else { return false }
        if (songs ?? 0) > 0 || (collections ?? 0) > 0 { return true }
        return hasFiles == true
    }

    // MARK: - After a removal

    /// A line under the Remove all row, and whether it reports a failure (shown in red).
    struct WipeCaption: Equatable, Sendable {
        var text: String
        var isFailure: Bool
    }

    /// What a removal says about how it ended: nothing when it deleted everything (or none ran); that the folder is not
    /// where Deci expects it, without alarm, when it was refused; and how many items could not be removed, in red, when it
    /// stopped short ("Nothing was removed." when it deleted none, as when the empty index could not be written).
    static func caption(for wipe: MusicDownloadStore.Wipe?) -> WipeCaption? {
        guard let wipe else { return nil }
        if wipe.refused {
            return WipeCaption(
                text: "The Downloads folder is not where Deci expects it, so nothing was removed.", isFailure: false
            )
        }
        guard wipe.failed > 0 else { return nil }
        var text = "Could not remove \(wipe.failed) \(wipe.failed == 1 ? "item" : "items")."
        if wipe.removed == 0 { text += " Nothing was removed." }
        return WipeCaption(text: text, isFailure: true)
    }
}
