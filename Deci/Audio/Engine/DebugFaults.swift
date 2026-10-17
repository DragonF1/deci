// Deci/Audio/Engine/DebugFaults.swift
//
// Debug-only fault injection for reproducing a stuck tap by hand.
// - `kill -USR1 <Deci pid>` stalls the next primary audio callback for DECI_DEBUG_STALL_MS
//   (default 800 ms), the reader half of the system-wide stall that sticks a drift-off tap
//   (see TapWatchdog). Stall the tapped app's IO thread at the same moment for the writer half.
// - `kill -USR2 <Deci pid>` makes the callback that is primary right now deliver exact zeros
//   from then on, the end state of a stuck tap. The fault belongs to that callback, not to the
//   primary role: a tap built by a rescue or a rebuild is healthy, so the watchdog's recovery
//   can be tested without looping on its own fix.
// - `DECI_DEBUG_STUCK_TARGET=all` makes SIGUSR2 toggle "every tap reads zeros, including ones
//   created later" instead (a rescue's candidate stays silent too, so verify fails). The default,
//   `primary`, sticks only the current primary callback.

#if DEBUG
import Foundation

enum DebugFaults {
    enum StuckTarget: Equatable {
        case primary
        case all

        /// Anything but `all` (case and spaces ignored) is the primary, including a typo.
        static func parse(_ value: String?) -> StuckTarget {
            value?.trimmingCharacters(in: .whitespaces).lowercased() == "all" ? .all : .primary
        }
    }

    /// Read and cleared by the audio callback; set from the main queue.
    nonisolated(unsafe) static var pendingStallMs: Int32 = 0
    /// Read and cleared by the audio callback; set from the main queue.
    nonisolated(unsafe) static var pendingStuckTap = false
    /// Every tap reads zeros (target `all`); set from the main queue, read by the audio callbacks.
    nonisolated(unsafe) static var stuckAll = false
    @MainActor private static var signalSources: [DispatchSourceSignal] = []

    /// Whether this callback's input is forced to exact zeros. `stuckCallbackID` is the callback
    /// that was primary when SIGUSR2 arrived (0 for none yet).
    nonisolated static func isStuck(callbackID: UInt32, stuckCallbackID: UInt32, stuckAll: Bool) -> Bool {
        stuckAll || (stuckCallbackID != 0 && callbackID == stuckCallbackID)
    }

    @MainActor
    static func install() {
        guard signalSources.isEmpty else { return }
        let environment = ProcessInfo.processInfo.environment
        let ms = Int32(environment["DECI_DEBUG_STALL_MS"] ?? "") ?? 800
        let target = StuckTarget.parse(environment["DECI_DEBUG_STUCK_TARGET"])
        signalSources = [
            source(SIGUSR1) { pendingStallMs = ms },
            source(SIGUSR2) {
                switch target {
                case .primary: pendingStuckTap = true
                case .all: stuckAll.toggle()
                }
            },
        ]
    }

    @MainActor
    private static func source(_ sig: Int32, _ handler: @escaping () -> Void) -> DispatchSourceSignal {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler(handler: handler)
        source.resume()
        return source
    }
}
#endif
