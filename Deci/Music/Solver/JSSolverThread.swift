import Foundation

enum JSSolverStack {
    /// 16 MB, enough for meriyah to parse the player.
    static let size = 16 * 1024 * 1024
}

/// One dedicated thread with a large stack that owns a non-Sendable `State` (a JavaScriptCore
/// context) and runs jobs against it one at a time, in order.
///
/// JavaScriptCore objects must stay on one thread, and parsing a 2 MB player with a recursive
/// descent parser overflows the 512 KB stack of a default secondary thread, so the solver gets
/// its own thread with 16 MB. The state is built lazily on that thread and dropped, along with
/// the thread, after `idleTimeout` seconds without work; the next job builds a new one.
///
/// This is the only `@unchecked Sendable` type in the music solver. The invariants that make it
/// safe: the job queue and flags are touched only under `condition`, and `State` is a local of
/// the thread's loop, so it is created, used and released on that one thread.
final class JSSolverThread<State>: @unchecked Sendable {
    struct ShutDown: Error {}

    private struct Item {
        let run: (State) -> Void
        let fail: (Error) -> Void
    }

    private let name: String
    private let stackSize: Int
    private let idleTimeout: TimeInterval
    private let makeState: @Sendable () throws -> State

    private let condition = NSCondition()
    private var queue: [Item] = []        // guarded by condition
    private var isRunning = false         // guarded by condition: a thread is alive
    private var isShutDown = false        // guarded by condition
    private var stateAlive = false        // guarded by condition

    init(
        name: String,
        stackSize: Int = JSSolverStack.size,
        idleTimeout: TimeInterval = 60,
        makeState: @escaping @Sendable () throws -> State
    ) {
        self.name = name
        self.stackSize = stackSize
        self.idleTimeout = idleTimeout
        self.makeState = makeState
    }

    /// True while the thread holds a state.
    var hasState: Bool {
        condition.lock()
        defer { condition.unlock() }
        return stateAlive
    }

    /// Runs `job` on the solver thread with the state, creating the state first if needed.
    func run<T: Sendable>(_ job: @escaping @Sendable (State) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let item = Item(
                run: { state in continuation.resume(with: Result { try job(state) }) },
                fail: { error in continuation.resume(throwing: error) }
            )
            if !enqueue(item) {
                continuation.resume(throwing: ShutDown())
            }
        }
    }

    /// Fails everything still queued, stops the thread after its current job, and refuses new jobs.
    func shutdown() {
        condition.lock()
        isShutDown = true
        let pending = queue
        queue.removeAll()
        condition.broadcast()
        condition.unlock()
        for item in pending { item.fail(ShutDown()) }
    }

    // MARK: - Thread

    private func enqueue(_ item: Item) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard !isShutDown else { return false }
        queue.append(item)
        if !isRunning {
            isRunning = true
            let thread = Thread { [self] in loop() }
            thread.name = name
            thread.stackSize = stackSize
            thread.qualityOfService = .userInitiated
            thread.start()
        }
        condition.signal()
        return true
    }

    private func loop() {
        var state: State?
        while true {
            condition.lock()
            let deadline = Date(timeIntervalSinceNow: idleTimeout)
            var timedOut = false
            while queue.isEmpty && !isShutDown && !timedOut {
                timedOut = !condition.wait(until: deadline)
            }
            if !isShutDown, !queue.isEmpty {
                let item = queue.removeFirst()
                condition.unlock()
                // The thread has no run loop, so without a pool every JSValue a job autoreleases
                // (and the context each one retains) would live until the thread ends.
                autoreleasepool { process(item, state: &state) }
                continue
            }
            // Idle timeout or shutdown: the state goes before the thread is marked gone, so a job
            // that arrives meanwhile never builds a second context while this one is being freed.
            condition.unlock()
            autoreleasepool { state = nil }
            condition.lock()
            stateAlive = false
            if !isShutDown, !queue.isEmpty {
                condition.unlock()
                continue
            }
            isRunning = false
            condition.unlock()
            return
        }
    }

    private func process(_ item: Item, state: inout State?) {
        if state == nil {
            do {
                state = try makeState()
                condition.lock()
                stateAlive = true
                condition.unlock()
            } catch {
                item.fail(error)
                return
            }
        }
        if let state { item.run(state) }
    }
}
