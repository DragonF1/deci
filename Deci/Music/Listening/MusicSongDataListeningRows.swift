// Deci/Music/Listening/MusicSongDataListeningRows.swift
import Foundation

/// The YOUR LISTENING block of the Song data panel: the listener's own plays of one song, from the local listening
/// store. Pure like the other blocks: no clock but the `now` it is given.
extension MusicSongDataRows {
    static let notCountedNote = "Not played since Deci started counting"

    static func listeningSection(
        _ entry: MusicListeningEntry?, now: Date, timeZone: TimeZone = .autoupdatingCurrent
    ) -> MusicSongDataSection {
        guard let entry else {
            return MusicSongDataSection(title: "Your listening", rows: [], note: notCountedNote)
        }
        return MusicSongDataSection(title: "Your listening", rows: [
            MusicSongDataRow(label: "Plays", value: "\(entry.playCount)", isNumeric: true),
            MusicSongDataRow(label: "Time listened", value: listenedText(entry.totalSeconds), isNumeric: true),
            MusicSongDataRow(label: "Last played", value: lastPlayedText(entry.lastPlayed, now: now), isNumeric: false),
            MusicSongDataRow(label: "First played", value: firstPlayedText(entry.firstPlayed, in: timeZone), isNumeric: false)
        ])
    }

    /// Hours, minutes and seconds, each only when it is not zero: 1h 2m 5s, 2m, 45s. Nothing heard is 0s.
    static func listenedText(_ totalSeconds: TimeInterval) -> String {
        let whole = safeInt(totalSeconds.rounded()).map { max($0, 0) } ?? 0
        let hours = whole / 3600
        let minutes = whole % 3600 / 60
        let seconds = whole % 60
        var parts: [String] = []
        if hours > 0 { parts.append("\(hours)h") }
        if minutes > 0 { parts.append("\(minutes)m") }
        if seconds > 0 || parts.isEmpty { parts.append("\(seconds)s") }
        return parts.joined(separator: " ")
    }

    private static func lastPlayedText(_ date: Date, now: Date) -> String {
        guard now.timeIntervalSince(date) >= 60 else { return "Just now" }
        return relativeFormatter.localizedString(for: date, relativeTo: now)
    }

    /// The day in the listener's own time zone (a formatter is made per call, so a changed zone is followed).
    private static func firstPlayedText(_ date: Date, in timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}
