// Deci/Audio/Engine/GlitchLog.swift
import Foundation

/// The text of the persisted `[GLITCH]` lines. A report script parses these, so the format is a contract:
///
///     [GLITCH] app="<name>" pid=<pid> dropouts=+<n> latest_ms=<x.x> discontinuities=+<n> devices=<uid,uid> load=<x.xx>
///     [GLITCH] app="Deci music" stalled=1 load=<x.xx>
///
/// `dropouts` and `discontinuities` are the growth since the previous line for the tap (`+0` for a counter that did
/// not move), `latest_ms` is the length of the latest dropout (0.0 on a line with no new dropout), `load` the
/// one-minute load average. Device UIDs are written with any space, comma or quote turned into `_`.
enum GlitchLogLine {
    /// The app name on the music player's lines.
    static let musicAppName = "Deci music"

    /// Whether lines go to the system log. Not from the unit tests' host: the report reads the system log, where
    /// the tests' fake taps and stalls would read as the owner's glitches. The tests get every line from the seam.
    static let isPersisted = !DeciMain.isTestHost

    static func make(
        appName: String,
        pid: pid_t,
        dropouts: UInt32,
        latestDropoutSeconds: Double,
        discontinuities: UInt32,
        devices: [String],
        load: Double
    ) -> String {
        "[GLITCH] app=\"\(quotable(appName))\" pid=\(pid) dropouts=+\(dropouts)"
            + " latest_ms=\(fixed(dropouts > 0 ? latestDropoutSeconds * 1000 : 0, decimals: 1))"
            + " discontinuities=+\(discontinuities)"
            + " devices=\(devices.map(listable).joined(separator: ",")) load=\(fixed(load, decimals: 2))"
    }

    static func makeStall(appName: String, load: Double) -> String {
        "[GLITCH] app=\"\(quotable(appName))\" stalled=1 load=\(fixed(load, decimals: 2))"
    }

    /// The one-minute load average; 0 when the system will not say.
    static func loadAverage() -> Double {
        var loads = [Double](repeating: 0, count: 1)
        guard getloadavg(&loads, 1) >= 1, loads[0].isFinite, loads[0] >= 0 else { return 0 }
        return loads[0]
    }

    /// A number with a point and `decimals` places whatever the user's locale; a non-finite one prints as zero.
    private static func fixed(_ value: Double, decimals: Int) -> String {
        String(format: "%.\(decimals)f", value.isFinite ? value : 0)
    }

    /// A device UID in the comma-separated field: a space, comma or quote (none of which a UID should have) becomes
    /// `_`, so the field cannot run into the next one or split one UID in two.
    private static func listable(_ uid: String) -> String {
        String(uid.map { character -> Character in
            character.isWhitespace || character == "," || character == "\"" ? "_" : character
        })
    }

    /// The name inside the quoted field: a quote becomes an apostrophe and a line break or tab a space, so the
    /// field cannot be cut short and the line stays one line.
    private static func quotable(_ name: String) -> String {
        String(name.map { character -> Character in
            if character == "\"" { return "'" }
            return character.isNewline || character == "\t" ? " " : character
        })
    }
}

/// What a tap's dropout and discontinuity counters have grown by since the last `[GLITCH]` line was written for it.
struct GlitchLogCursor {
    struct Growth: Equatable {
        var dropouts: UInt32
        var discontinuities: UInt32
    }

    private var dropouts: UInt32 = 0
    private var discontinuities: UInt32 = 0

    /// The growth to log, or nil when neither counter moved. The counters are the tap's own and start again at
    /// zero when it is rebuilt, so one that went back is counted again from zero rather than as a negative change.
    mutating func growth(dropouts current: UInt32, discontinuities currentDiscontinuities: UInt32) -> Growth? {
        let newDropouts = current >= dropouts ? current - dropouts : current
        let newDiscontinuities = currentDiscontinuities >= discontinuities
            ? currentDiscontinuities - discontinuities
            : currentDiscontinuities
        dropouts = current
        discontinuities = currentDiscontinuities
        guard newDropouts > 0 || newDiscontinuities > 0 else { return nil }
        return Growth(dropouts: newDropouts, discontinuities: newDiscontinuities)
    }
}
