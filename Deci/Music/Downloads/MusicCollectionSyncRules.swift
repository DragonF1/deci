// Deci/Music/Downloads/MusicCollectionSyncRules.swift
import Foundation

/// When a sync may delete a song. A page that stops listing a song has not proved the song left the playlist: YouTube
/// greys rows out and keeps them in the playlist, leaves podcast episodes off the page, and sometimes returns fewer songs
/// than the header says. Everything here is a pure decision over what one read of the page found; the service applies it.
///
/// - A greyed-out row counts as still listed: it stays in the stored list and its file stays.
/// - A header that states a count the read came up short of by more than `max(5, 10%)` marks the listing incomplete:
///   new songs are still added, nothing is deleted.
/// - One sync deletes at once only a small set, at most `max(5, 10%)` of the stored list. A bigger drop is held: the
///   songs and their files stay, the ids and the time are recorded, and a later complete read at least an hour after the
///   first that still misses them applies it. Songs that come back leave the hold.
nonisolated enum MusicCollectionSyncRules {
    typealias HeldDrop = MusicDownloadStore.Collection.HeldDrop

    /// The least time between the read that first missed a held song and the one that may delete it.
    static let holdDuration: TimeInterval = 3_600
    /// A drop of this many songs or fewer is small however short the list.
    static let smallFloor = 5

    /// What one read decided.
    struct Decision: Equatable, Sendable {
        /// The list to store: the page's order, with the songs the page did not list but that stay in their old places.
        let order: [String]
        /// The songs to delete now; their files go unless another collection lists them or they were downloaded on their own.
        let deleteNow: [String]
        /// The drop that waits for a later read; nil when nothing waits.
        let held: HeldDrop?
        /// False when the header stated more songs than the read found: nothing was deleted because of it.
        let isComplete: Bool
    }

    /// The decision for a page read to its end, or nil when the page has no playable song (an empty list is never every
    /// song gone). `playable` and `unavailable` are the page's ids in page order; `statedCount` is the number the header
    /// states, nil when it states none.
    static func decide(
        stored: [String], playable: [String], unavailable: [String], statedCount: Int?, held: HeldDrop?, now: Date
    ) -> Decision? {
        var seen = Set<String>()
        let page = playable.filter { seen.insert($0).inserted }
        guard !page.isEmpty else { return nil }
        let pageSet = Set(page)
        let greySet = Set(unavailable).subtracting(pageSet)
        let isComplete = isComplete(listed: pageSet.count + greySet.count, statedCount: statedCount)

        var storedSeen = Set<String>()
        let storedOrder = stored.filter { storedSeen.insert($0).inserted }
        let missing = storedOrder.filter { !pageSet.contains($0) && !greySet.contains($0) }

        var deleteNow: [String] = []
        var newHold: HeldDrop?
        if !isComplete {
            newHold = held
        } else if !missing.isEmpty {
            if isSmall(missing.count, of: storedOrder.count) {
                deleteNow = missing
            } else {
                (deleteNow, newHold) = applyingHold(held, to: missing, now: now)
            }
        }

        let deleted = Set(deleteNow)
        let stays = storedOrder.filter { !pageSet.contains($0) && !deleted.contains($0) }
        return Decision(
            order: arrange(page: page, staying: stays, storedOrder: storedOrder),
            deleteNow: deleteNow,
            held: newHold,
            isComplete: isComplete
        )
    }

    /// Whether a listing of `listed` songs matches the header's `statedCount` closely enough to trust a deletion by.
    private static func isComplete(listed: Int, statedCount: Int?) -> Bool {
        guard let statedCount else { return true }
        let shortBy = statedCount - listed
        return !(shortBy > smallFloor && shortBy * 10 > statedCount)
    }

    private static func isSmall(_ removed: Int, of storedCount: Int) -> Bool {
        removed <= smallFloor || removed * 10 <= storedCount
    }

    /// A big drop against the hold from an earlier read: what to delete now, and the hold to store. `missing` is in stored
    /// order.
    private static func applyingHold(
        _ held: HeldDrop?, to missing: [String], now: Date
    ) -> (deleteNow: [String], held: HeldDrop?) {
        guard let held else { return ([], HeldDrop(videoIds: missing, since: now)) }
        let heldSet = Set(held.videoIds)
        let stillMissing = missing.filter { heldSet.contains($0) }
        let newMisses = missing.filter { !heldSet.contains($0) }
        if now.timeIntervalSince(held.since) >= holdDuration, !stillMissing.isEmpty {
            // The songs the earlier read missed are missing again an hour on: they go. The ones missed only now wait.
            return (stillMissing, newMisses.isEmpty ? nil : HeldDrop(videoIds: newMisses, since: now))
        }
        guard !stillMissing.isEmpty else { return ([], HeldDrop(videoIds: newMisses, since: now)) }
        // Too early: the songs that came back leave the hold, and the first time stays for the rest.
        let kept = stillMissing.count == held.videoIds.count ? held : HeldDrop(videoIds: stillMissing, since: held.since)
        return ([], kept)
    }

    /// The page's songs in the page's order, each of the songs that stay but the page did not list put after the song it
    /// followed in the stored list (at the front when none of the songs before it is on the page).
    private static func arrange(page: [String], staying: [String], storedOrder: [String]) -> [String] {
        guard !staying.isEmpty else { return page }
        let pageSet = Set(page)
        let stayingSet = Set(staying)
        var atFront: [String] = []
        var after: [String: [String]] = [:]
        var anchor: String?
        for videoId in storedOrder {
            if pageSet.contains(videoId) {
                anchor = videoId
            } else if stayingSet.contains(videoId) {
                if let anchor { after[anchor, default: []].append(videoId) } else { atFront.append(videoId) }
            }
        }
        var order = atFront
        order.reserveCapacity(page.count + staying.count)
        for videoId in page {
            order.append(videoId)
            if let followers = after[videoId] { order.append(contentsOf: followers) }
        }
        return order
    }

    // MARK: - The count in the header

    /// The number of songs a page's subtitle states ("1,000 songs", "182 tracks"), nil when it states none. The count must
    /// stand alone in one part of the subtitle, so "Mix of 30 songs by Adele" states none.
    static func statedCount(inSubtitle subtitle: String) -> Int? {
        for part in subtitle.split(separator: "\u{2022}") {
            let text = part.trimmingCharacters(in: .whitespacesAndNewlines)
            let range = NSRange(text.startIndex..., in: text)
            guard let match = countPattern.firstMatch(in: text, range: range),
                  let numberRange = Range(match.range(at: 1), in: text) else { continue }
            let digits = text[numberRange].filter(\.isNumber)
            if let count = Int(digits) { return count }
        }
        return nil
    }

    /// A number (with thousands separators of the kinds YouTube writes), a space, "song" or "track" in the singular or
    /// plural, and then nothing or a comma.
    private static let countPattern: NSRegularExpression = {
        let separators = ",\\u202F\\u00A0 "
        let pattern = "^(\\d{1,3}(?:[\(separators)]\\d{3})+|\\d+)[\\s\\u202F\\u00A0]+(?:songs?|tracks?)(?:,.*)?$"
        // The pattern is a constant, so it always compiles.
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()
}
