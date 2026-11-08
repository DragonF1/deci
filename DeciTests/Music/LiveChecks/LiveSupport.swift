// DeciTests/Music/LiveChecks/LiveSupport.swift
// Opt-in live checks for Mix (TEST_RUNNER_DECI_LIVE=1, arrives here as DECI_LIVE): the songs, their truth beats, the lyrics
// from LRCLIB (cached on disk), the report writer and the paths. Only the network of the app (YouTube, playlist pages,
// radio) is faked; everything else in the checks is the real code.

import Foundation
@testable import Deci

nonisolated let liveGate: Bool = ProcessInfo.processInfo.environment["DECI_LIVE"] == "1"

nonisolated enum LiveDirs {
    static let root = URL(fileURLWithPath: "/Volumes/Storage/_test/deci/live-checks", isDirectory: true)
    static let lyrics = root.appendingPathComponent("lyrics", isDirectory: true)
    static let store = root.appendingPathComponent("analysis", isDirectory: true)
    static let cache = root.appendingPathComponent("trackcache", isDirectory: true)
    static let report = root.appendingPathComponent("report.md")
    static let manifest = URL(fileURLWithPath: "/Volumes/Storage/_build/scratch/deci-harmonix/manifest.json")

    static func make() {
        for dir in [root, lyrics, store, cache] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}

nonisolated struct LiveBeat: Sendable { var time: Double; var inBar: Int }

nonisolated struct LiveSong: Sendable {
    var index: Int
    /// The 11 character id the app sees; the manifest id is `key`.
    var videoId: String
    var key: String
    var title: String
    var artist: String
    var url: URL
    var duration: Double
    var beats: [LiveBeat]

    /// The truth beat nearest to `t` (song seconds), with the signed distance `t - beat`.
    func nearestBeat(to t: Double) -> (beat: LiveBeat, delta: Double)? {
        guard !beats.isEmpty else { return nil }
        var lo = 0, hi = beats.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if beats[mid].time < t { lo = mid + 1 } else { hi = mid }
        }
        var best = beats[lo]
        if lo > 0, abs(beats[lo - 1].time - t) < abs(best.time - t) { best = beats[lo - 1] }
        return (best, t - best.time)
    }

    /// The truth beat period near `t`, seconds.
    func period(near t: Double) -> Double {
        guard let near = nearestBeat(to: t), let index = beats.firstIndex(where: { $0.time == near.beat.time }) else { return 0.5 }
        if index + 1 < beats.count { return beats[index + 1].time - beats[index].time }
        if index > 0 { return beats[index].time - beats[index - 1].time }
        return 0.5
    }

    /// A track as a playlist row shows it.
    func track(artist override: String? = nil) -> MusicTrack {
        MusicSamples.track(videoId, title: title, artist: override ?? artist, seconds: Int(duration.rounded()))
    }

    /// The stream the fake backend resolves the id to: the local file, as a network stream, so the real player, the
    /// analysis coordinator and the planner treat it like any song.
    var stream: ResolvedStream {
        ResolvedStream(
            videoId: videoId, url: url, itag: 140, durationSeconds: duration, expiresAt: .distantFuture,
            playbackTrackingURL: nil, httpHeaders: [:], audioCodec: "mp4a.40.2"
        )
    }
}

nonisolated enum LiveSongs {
    struct Failure: Error, CustomStringConvertible { let description: String }

    static func load() throws -> [LiveSong] {
        let data = try Data(contentsOf: LiveDirs.manifest)
        let json = try JSONSerialization.jsonObject(with: data)
        let items = (json as? [[String: Any]]) ?? ((json as? [String: Any])?["songs"] as? [[String: Any]]) ?? []
        var songs: [LiveSong] = []
        for item in items {
            guard let key = item["id"] as? String, let path = item["song"] as? String,
                  let duration = (item["duration"] as? NSNumber)?.doubleValue,
                  FileManager.default.fileExists(atPath: path) else { continue }
            let index = songs.count
            songs.append(LiveSong(
                index: index, videoId: "Lv" + String(format: "%09d", index), key: key,
                title: (item["title"] as? String) ?? key, artist: (item["artist"] as? String) ?? "Artist",
                url: URL(fileURLWithPath: path), duration: duration,
                beats: truth(path: (item["truth"] as? String) ?? "")
            ))
        }
        guard songs.count >= 12 else { throw Failure(description: "only \(songs.count) songs found") }
        return songs
    }

    private static func truth(path: String) -> [LiveBeat] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        var beats: [LiveBeat] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
            guard parts.count >= 2, let t = Double(parts[0]), let bar = Int(parts[1]) else { continue }
            beats.append(LiveBeat(time: t, inBar: bar))
        }
        return beats.sorted { $0.time < $1.time }
    }
}

// MARK: - Lyrics (LRCLIB, cached)

nonisolated enum LiveLyrics {
    struct Entry: Sendable {
        var lines: [LyricLine]?
        var instrumental = false
    }

    /// One request per song at most, cached under the live-checks folder (hits and misses both). No email, no cookie.
    static func fetch(_ song: LiveSong) async -> Entry {
        let file = LiveDirs.lyrics.appendingPathComponent(song.videoId + ".json")
        if let data = try? Data(contentsOf: file) { return parse(data) }
        var components = URLComponents(string: "https://lrclib.net/api/get")!
        components.queryItems = [
            URLQueryItem(name: "artist_name", value: song.artist), URLQueryItem(name: "track_name", value: song.title),
            URLQueryItem(name: "duration", value: String(Int(song.duration.rounded()))),
        ]
        guard let url = components.url else { return Entry() }
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue("DeciTests", forHTTPHeaderField: "User-Agent")
        request.httpShouldHandleCookies = false
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 || status == 404 {
                try? (status == 200 ? data : Data("{}".utf8)).write(to: file)
                try? await Task.sleep(for: .milliseconds(150))
                return status == 200 ? parse(data) : Entry()
            }
        } catch {}
        return Entry()
    }

    private static func parse(_ data: Data) -> Entry {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return Entry() }
        if (json["instrumental"] as? Bool) == true { return Entry(lines: nil, instrumental: true) }
        guard let synced = json["syncedLyrics"] as? String, !synced.isEmpty else { return Entry() }
        let lines = LRCParser.parse(synced)
        return LRCParser.sungLineCount(lines) > 3 ? Entry(lines: lines) : Entry()
    }
}

// MARK: - Report

@MainActor
enum LiveReport {
    struct Section {
        var title: String
        var verdict: String
        var lines: [String]
    }

    private static var sections: [Int: Section] = [:]
    private static var notes: [String] = []

    static func note(_ line: String) {
        notes.append(line)
        write()
    }

    static func record(_ number: Int, _ title: String, pass: Bool, _ lines: [String]) {
        sections[number] = Section(title: title, verdict: pass ? "PASS" : "FAIL", lines: lines)
        write()
    }

    static func record(_ number: Int, _ title: String, verdict: String, _ lines: [String]) {
        sections[number] = Section(title: title, verdict: verdict, lines: lines)
        write()
    }

    private static func write() {
        var text = "# Deci Mix live checks\n\n"
        text += "Run: \(ISO8601DateFormatter().string(from: Date()))\n\n"
        text += "| # | Check | Result |\n|---|---|---|\n"
        for number in sections.keys.sorted() {
            let s = sections[number]!
            text += "| \(number) | \(s.title) | \(s.verdict) |\n"
        }
        if !notes.isEmpty { text += "\n## Run notes\n\n" + notes.map { "- \($0)" }.joined(separator: "\n") + "\n" }
        for number in sections.keys.sorted() {
            let s = sections[number]!
            text += "\n## \(number). \(s.title): \(s.verdict)\n\n" + s.lines.map { "- \($0)" }.joined(separator: "\n") + "\n"
        }
        LiveDirs.make()
        try? text.write(to: LiveDirs.report, atomically: true, encoding: .utf8)
    }
}

nonisolated func liveF(_ value: Double, _ digits: Int = 2) -> String {
    value.isFinite ? String(format: "%.\(digits)f", value) : "nan"
}
