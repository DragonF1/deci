// Deci/Models/MultiOutputRevert.swift
// The decision behind "an output device in a Multi selection disconnected": the item (an app, a Chrome tab or the
// music player) goes back to Single, and this says to what. Pure, so the three surfaces share one rule and one number.

import Foundation

enum MultiOutputRevert {
    /// How long the pre-Multi single setting is remembered. A Multi session shorter than this goes back to the single
    /// device (or System Audio) it had before; a longer one goes to System Audio and the old choice is forgotten.
    static let rememberWindow: TimeInterval = 3600

    /// How far in the future a recorded start may be before it is not believed. A small step back of the clock (a time
    /// sync) still counts as a short session; a start further ahead than this cannot be trusted.
    static let futureTolerance: TimeInterval = 300

    enum Target: Equatable {
        /// The single setting from before Multi: its specific device, or System Audio if that is what it was.
        case previousSingle
        /// System Audio, and the old specific device is cleared so it does not pull the item back later.
        case systemAudio
    }

    /// Where an item goes when a device of its Multi selection disconnects. `multiSince` is when it entered Multi; nil
    /// (never recorded, as in a file from an older version) means the pre-Multi setting is not trusted. A start a little
    /// in the future (the clock stepped back) counts as a short session; one more than `futureTolerance` ahead cannot
    /// be believed and is treated like no record at all.
    static func target(multiSince: Date?, now: Date) -> Target {
        guard let multiSince else { return .systemAudio }
        let elapsed = now.timeIntervalSince(multiSince)
        guard elapsed >= -futureTolerance else { return .systemAudio }
        return elapsed < rememberWindow ? .previousSingle : .systemAudio
    }

    /// Whether the disconnect of `uid` concerns an item: it is in Multi and has that device selected.
    static func disconnectAffects(mode: DeviceSelectionMode?, selected: Set<String>, uid: String) -> Bool {
        mode == .multi && selected.contains(uid)
    }
}
