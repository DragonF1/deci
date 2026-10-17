// Deci/Audio/Engine/DebugFaults.swift
//
// Debug-only fault injection for reproducing a stuck tap by hand.
// - `kill -USR1 <Deci pid>` stalls the next primary audio callback for DECI_DEBUG_STALL_MS
//   (default 800 ms), the reader half of the system-wide stall that sticks a drift-off tap
//   (see TapWatchdog). Stall the tapped app's IO thread at the same moment for the writer half.
// - `kill -USR2 <Deci pid>` makes the next primary callback's tap deliver exact zeros until
//   that tap is rebuilt, the end state of a stuck tap, so the watchdog's rebuild can be tested.

#if DEBUG
import Foundation

enum DebugFaults {
    /// Read and cleared by the audio callback; set from the main queue.
    nonisolated(unsafe) static var pendingStallMs: Int32 = 0
    /// Read and cleared by the audio callback; set from the main queue.
    nonisolated(unsafe) static var pendingStuckTap = false
    @MainActor private static var signalSources: [DispatchSourceSignal] = []

    @MainActor
    static func install() {
        guard signalSources.isEmpty else { return }
        let ms = Int32(ProcessInfo.processInfo.environment["DECI_DEBUG_STALL_MS"] ?? "") ?? 800
        signalSources = [
            source(SIGUSR1) { pendingStallMs = ms },
            source(SIGUSR2) { pendingStuckTap = true },
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
