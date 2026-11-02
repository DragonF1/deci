// Deci/Audio/Engine/ReplayedProcessesPublisher.swift
import Foundation
import os

/// Tells other recorders which processes Deci mutes and plays back itself.
///
/// Deci taps each app with a `.mutedWhenTapped` process tap and replays the audio from its own process. A recorder
/// with a global process tap (GIF Record) sees an app's audio before the mute, so it hears the raw audio and Deci's
/// replay of it, and the sound doubles. Deci publishes the pids it taps in `replayed-processes.json` and the recorder
/// leaves them out of its tap.
///
/// The file, in Application Support/Deci next to settings.json, is one UTF-8 JSON object:
/// `{"version":1,"publisher":12345,"processes":[111,222,333]}`. `publisher` is Deci's own pid, so a reader can tell a
/// file left behind by a crash (the pid is gone). `processes` is sorted ascending and unique. No file means nothing is
/// replayed.
///
/// `publish` is meant to be called often (every health tick). It writes only when the set changed since the last
/// success, so a steady state costs one set comparison.
@MainActor
final class ReplayedProcessesPublisher {
    nonisolated static let fileName = "replayed-processes.json"
    nonisolated static let version = 1

    /// Where the running app publishes: `~/Library/Application Support/Deci/replayed-processes.json`, the folder
    /// `SettingsManager` uses.
    nonisolated static func liveFileURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Deci")
            .appendingPathComponent(fileName)
    }

    /// The file's bytes. Built by hand so the keys always come in the documented order; every value is an integer,
    /// so there is nothing to escape.
    nonisolated static func encode(pids: Set<pid_t>, publisher: pid_t) -> Data {
        let list = pids.sorted().map(String.init).joined(separator: ",")
        return Data(#"{"version":\#(version),"publisher":\#(publisher),"processes":[\#(list)]}"#.utf8)
    }

    private let fileURL: URL
    private let publisherPID: pid_t
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FineTune", category: "ReplayedProcesses")

    /// What the file holds now. Nil until the first success, so the first publish always runs: an empty first set
    /// then clears a file an earlier run left behind. Only a write or removal that worked updates this, so a failed
    /// one is retried by the next publish of the same set.
    private var published: Set<pid_t>?

    /// True once the current run of failures has been logged, so a write that keeps failing logs once, not every tick.
    private var failureLogged = false

    /// How many unchanged publishes go by between checks that the file is still this process's (`recheckEvery`).
    private var unchangedPublishes = 0

    /// An unchanged list is checked against the file once in this many publishes (5 s at the 4 Hz health tick): a
    /// second Deci (a Debug build) may have removed or replaced it, and this one would otherwise never write it again.
    static let recheckEvery = 20

    init(fileURL: URL, publisherPID: pid_t = getpid()) {
        self.fileURL = fileURL
        self.publisherPID = publisherPID
    }

    /// The publisher for the running app.
    static func live() -> ReplayedProcessesPublisher {
        ReplayedProcessesPublisher(fileURL: liveFileURL())
    }

    /// Publishes the pids of every process Deci taps now. Deci's own pid and non-positive pids are dropped. An empty
    /// set removes the file. Does nothing when the set is the one already published.
    func publish(pids: Set<pid_t>) {
        let pids = pids.filter { $0 > 0 && $0 != publisherPID }
        if pids == published {
            unchangedPublishes += 1
            guard !pids.isEmpty, unchangedPublishes >= Self.recheckEvery else { return }
            unchangedPublishes = 0
            guard fileOwner() != publisherPID else { return }
            // Gone or another Deci's: write ours again.
        }
        unchangedPublishes = 0
        do {
            if pids.isEmpty {
                try removeFile()
            } else {
                try writeFile(pids)
            }
            published = pids
            failureLogged = false
        } catch {
            guard !failureLogged else { return }
            failureLogged = true
            logger.error("Could not update \(self.fileURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Removes the file: nothing is replayed any more.
    func clear() {
        publish(pids: [])
    }

    private func writeFile(_ pids: Set<pid_t>) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Atomic: the data goes to a temp file in the same folder and is renamed over the old one, so a reader never
        // sees half a file.
        try Self.encode(pids: pids, publisher: publisherPID).write(to: fileURL, options: .atomic)
    }

    /// The `publisher` pid in the file now, or nil when there is no file or it cannot be read.
    private func fileOwner() -> pid_t? {
        guard let data = try? Data(contentsOf: fileURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let publisher = object["publisher"] as? Int,
              let pid = pid_t(exactly: publisher) else { return nil }
        return pid
    }

    /// A file that is already gone counts as removed. A file another running Deci wrote (a Debug build next to the
    /// installed app) is left alone: it lists that Deci's taps, not this one's. One whose publisher is gone is stale
    /// and goes; so is one whose publisher this user cannot signal (EPERM), since Deci runs as this user.
    private func removeFile() throws {
        if let owner = fileOwner(), owner != publisherPID, kill(owner, 0) == 0 { return }
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        }
    }
}
