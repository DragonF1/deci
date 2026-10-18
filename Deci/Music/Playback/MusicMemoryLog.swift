// Deci/Music/Playback/MusicMemoryLog.swift
import Foundation
import os

/// Debug-only memory checkpoints for the Music tab ("launch", "music-open", "search", "playing").
/// Release builds compile `log` down to nothing.
enum MusicMemoryLog {
    #if DEBUG
    private static let logger = Logger(subsystem: "com.abraham.Deci", category: "Music")
    #endif

    @inline(__always)
    static func log(_ label: String) {
        #if DEBUG
        guard let megabytes = physFootprintMegabytes() else { return }
        logger.info("memory \(label, privacy: .public): \(megabytes, format: .fixed(precision: 1), privacy: .public) MB")
        #endif
    }

    #if DEBUG
    /// The process's phys_footprint, the figure Activity Monitor shows as Memory.
    static func physFootprintMegabytes() -> Double? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        guard result == 0 else { return nil }
        return Double(info.ri_phys_footprint) / 1_048_576
    }
    #endif
}
