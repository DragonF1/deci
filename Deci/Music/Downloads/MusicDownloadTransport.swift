// Deci/Music/Downloads/MusicDownloadTransport.swift
import Foundation
import os

/// What went wrong with a download that is not the network's own error. Equatable so the tests can name each one.
enum MusicDownloadError: Error, Equatable, Sendable {
    /// The video id is not eleven characters of A-Z, a-z, 0-9, underscore and hyphen, so it has no safe path.
    case invalidVideoId
    /// The address is not https. Nothing goes out over anything else.
    case insecureURL
    /// The server answered with a status that is neither 206 nor the 403 of an expired address. A 200 is among them:
    /// a proxy that ignored the Range header would answer with the whole file.
    case badStatus(Int)
    /// A 206 with no bytes in it, which would ask for the same range forever, or with no Content-Range to say which
    /// bytes it carries.
    case badResponse
    /// No Content-Range total and no clen on the address, so the end of the file is not known.
    case unknownLength
    /// The bytes do not add up: more than the total, more than the range asked for, bytes from somewhere other than
    /// where the file ends so far, a total that changed between answers, or a part whose size is not the expected length.
    case lengthMismatch
    /// The address expired more often than a song is allowed to ask for a fresh one.
    case reResolveLimit
    /// The downloads index could not be read, so nothing is written next to it until the next launch.
    case indexUnavailable
    /// The song is being downloaded already.
    case alreadyDownloading
}

/// One answer to a ranged GET.
struct MusicDownloadChunk: Sendable, Equatable {
    let data: Data
    let status: Int
    /// The size of the whole file as the answer's Content-Range states it, nil when it states none.
    let totalLength: Int64?
    /// The bytes of the file the answer carries, as its Content-Range states them (both ends included), nil when it
    /// states none or a status other than 206 was never read that far.
    let byteRange: ClosedRange<Int64>?

    init(data: Data, status: Int, totalLength: Int64?, byteRange: ClosedRange<Int64>? = nil) {
        self.data = data
        self.status = status
        self.totalLength = totalLength
        self.byteRange = byteRange
    }

    /// The total in a Content-Range header: "bytes 0-9/100" and "bytes */100" give 100, "bytes 0-9/*" and anything
    /// that is not a positive number give nil.
    static func totalLength(inContentRange value: String?) -> Int64? {
        guard let value, value.lowercased().hasPrefix("bytes"), let slash = value.lastIndex(of: "/") else { return nil }
        let total = value[value.index(after: slash)...].trimmingCharacters(in: .whitespaces)
        guard let length = Int64(total), length > 0 else { return nil }
        return length
    }

    /// The byte range in a Content-Range header: "bytes 10-19/100" and "bytes 10-19/*" give 10...19. "bytes */100", a range
    /// that runs backwards or has a negative or non-numeric end, and anything that is not a Content-Range give nil.
    static func byteRange(inContentRange value: String?) -> ClosedRange<Int64>? {
        guard let value, value.lowercased().hasPrefix("bytes") else { return nil }
        let rest = value.dropFirst("bytes".count).trimmingCharacters(in: .whitespaces)
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let ends = rest[..<slash].split(separator: "-", omittingEmptySubsequences: false)
        guard ends.count == 2,
              let first = Int64(ends[0].trimmingCharacters(in: .whitespaces)),
              let last = Int64(ends[1].trimmingCharacters(in: .whitespaces)),
              first >= 0, last >= first else { return nil }
        return first...last
    }
}

/// The one seam between the downloader and the network, so tests serve ranges from memory.
protocol MusicDownloadTransport: Sendable {
    /// One GET of `range` (both ends included) with `headers`. `received` is told how many bytes of the answer's body
    /// have arrived so far, at least every 256 KB while the body comes, and may be called from any thread. Only a 206 is
    /// read: any other status comes back as soon as its headers have, with no data.
    func fetch(
        url: URL, range: ClosedRange<Int64>, headers: [String: String], received: @escaping @Sendable (Int) -> Void
    ) async throws -> MusicDownloadChunk
}

extension MusicDownloadTransport {
    /// A fetch nobody follows the progress of.
    func fetch(url: URL, range: ClosedRange<Int64>, headers: [String: String]) async throws -> MusicDownloadChunk {
        try await fetch(url: url, range: range, headers: headers, received: { _ in })
    }
}

/// The live transport. Its own URLSession, apart from the InnerTube client's: no cookies, cache or credentials, a
/// request that goes quiet for about 30 seconds fails, and a chunk that takes more than 2 minutes in all fails. Only
/// https goes out, and a redirect off https is refused.
struct URLSessionDownloadTransport: MusicDownloadTransport {
    private let session: DownloadSession

    init(configuration: URLSessionConfiguration = Self.makeConfiguration()) {
        session = DownloadSession(configuration: configuration)
    }

    static func makeConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        config.waitsForConnectivity = false
        return config
    }

    /// A GET of the range. The stream's headers go first so the Range header is always the one asked for.
    static func urlRequest(url: URL, range: ClosedRange<Int64>, headers: [String: String]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        for (name, value) in headers where name.lowercased() != "range" {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")
        return request
    }

    /// The request a redirect may follow, or nil to refuse it. Anything not https is refused, and a hop to another host
    /// loses the headers that carry credentials.
    static func redirected(_ request: URLRequest, from origin: URL) -> URLRequest? {
        RedirectGuard.redirected(request, from: origin)
    }

    func fetch(
        url: URL, range: ClosedRange<Int64>, headers: [String: String], received: @escaping @Sendable (Int) -> Void
    ) async throws -> MusicDownloadChunk {
        guard url.scheme?.lowercased() == "https" else { throw MusicDownloadError.insecureURL }
        try Task.checkCancellation()
        let exchange = DownloadExchange(origin: url, requestedCount: Int(range.upperBound - range.lowerBound) + 1, received: received)
        let request = Self.urlRequest(url: url, range: range, headers: headers)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                exchange.begin(continuation, task: session.makeTask(request, exchange: exchange))
            }
        } onCancel: {
            exchange.cancel()
        }
    }
}

/// A URLSession with one delegate for all its requests, which hands each event to the fetch it belongs to. The session
/// holds its delegate until it is invalidated, so it is invalidated when the transport is gone.
private final class DownloadSession: Sendable {
    private let router: DownloadRouter
    private let session: URLSession

    init(configuration: URLSessionConfiguration) {
        let router = DownloadRouter()
        self.router = router
        session = URLSession(configuration: configuration, delegate: router, delegateQueue: nil)
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    /// A task for `request` whose events go to `exchange`. Not started.
    func makeTask(_ request: URLRequest, exchange: DownloadExchange) -> URLSessionDataTask {
        let task = session.dataTask(with: request)
        router.add(exchange, for: task)
        return task
    }
}

/// One fetch in flight: what its answer has said so far, the body gathered, and the continuation the fetch awaits. Read
/// by the session's delegate queue and written by the fetch's own task when it is cancelled, so it sits behind a lock.
private final class DownloadExchange: Sendable {
    /// Bytes of body between two reports of progress.
    private static let reportInterval = 128 * 1_024

    private struct State {
        var continuation: CheckedContinuation<MusicDownloadChunk, any Error>?
        var task: URLSessionDataTask?
        var status = 0
        var byteRange: ClosedRange<Int64>?
        var totalLength: Int64?
        var body = Data()
        var reported = 0
        var isCancelled = false
        var isDone = false
    }

    private struct Completion: Sendable {
        let continuation: CheckedContinuation<MusicDownloadChunk, any Error>
        let chunk: MusicDownloadChunk
        let finalReport: Int?
        let isCancelled: Bool
    }

    private enum Step: Sendable {
        case nothing
        case report([Int])
        case overrun(URLSessionDataTask?)
    }

    /// Where the request started, which a redirect is judged against.
    let origin: URL
    private let requestedCount: Int
    private let received: @Sendable (Int) -> Void
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(origin: URL, requestedCount: Int, received: @escaping @Sendable (Int) -> Void) {
        self.origin = origin
        self.requestedCount = requestedCount
        self.received = received
    }

    /// Hands the fetch's continuation over and starts the task, unless the fetch was cancelled in the meantime.
    func begin(_ continuation: CheckedContinuation<MusicDownloadChunk, any Error>, task: URLSessionDataTask) {
        let cancelled = state.withLock { state -> Bool in
            if state.isCancelled {
                state.isDone = true
                return true
            }
            state.continuation = continuation
            state.task = task
            return false
        }
        if cancelled {
            task.cancel()
            continuation.resume(throwing: CancellationError())
        } else {
            task.resume()
        }
    }

    /// The fetch's task was cancelled: the request stops and the fetch ends with a cancellation, not a network error.
    func cancel() {
        let (continuation, task) = state.withLock { state -> (CheckedContinuation<MusicDownloadChunk, any Error>?, URLSessionDataTask?) in
            state.isCancelled = true
            state.isDone = true
            defer { state.continuation = nil }
            return (state.continuation, state.task)
        }
        task?.cancel()
        continuation?.resume(throwing: CancellationError())
    }

    /// The answer's headers. Only a 206 is read on: anything else is handed back now with no data and the request is
    /// stopped, so a proxy that ignored the Range header and sends the whole file is never read.
    func receive(_ response: URLResponse) -> URLSession.ResponseDisposition {
        guard let http = response as? HTTPURLResponse else {
            finish(.failure(MusicDownloadError.badResponse))
            return .cancel
        }
        let contentRange = http.value(forHTTPHeaderField: "Content-Range")
        let total = MusicDownloadChunk.totalLength(inContentRange: contentRange)
        guard http.statusCode == 206 else {
            finish(.success(MusicDownloadChunk(data: Data(), status: http.statusCode, totalLength: total)))
            return .cancel
        }
        state.withLock { state in
            state.status = http.statusCode
            state.totalLength = total
            state.byteRange = MusicDownloadChunk.byteRange(inContentRange: contentRange)
        }
        return .allow
    }

    /// A piece of the body. Progress is reported every 128 KB, outside the lock, one report per step even when the
    /// session delivered several steps at once, so no two reports are further apart than that. A body longer than the
    /// range asked for stops the request.
    func receive(_ data: Data) {
        let step = state.withLock { state -> Step in
            guard !state.isDone else { return .nothing }
            state.body.append(data)
            if state.body.count > requestedCount { return .overrun(state.task) }
            var counts: [Int] = []
            while state.body.count - state.reported >= Self.reportInterval {
                state.reported += Self.reportInterval
                counts.append(state.reported)
            }
            return counts.isEmpty ? .nothing : .report(counts)
        }
        switch step {
        case .nothing: break
        case .report(let counts): for count in counts { received(count) }
        case .overrun(let task):
            finish(.failure(MusicDownloadError.lengthMismatch))
            task?.cancel()
        }
    }

    /// The request ended: the whole body is in, or it failed. A request this fetch already ended has nothing more to say.
    func complete(error: (any Error)?) {
        let completion = state.withLock { state -> Completion? in
            defer { state.isDone = true }
            guard let continuation = state.continuation else { return nil }
            state.continuation = nil
            let chunk = MusicDownloadChunk(
                data: state.body, status: state.status, totalLength: state.totalLength, byteRange: state.byteRange
            )
            return Completion(
                continuation: continuation, chunk: chunk,
                finalReport: state.reported == state.body.count ? nil : state.body.count,
                isCancelled: state.isCancelled
            )
        }
        guard let completion else { return }
        if let error {
            completion.continuation.resume(throwing: completion.isCancelled ? CancellationError() : error)
            return
        }
        if let count = completion.finalReport { received(count) }
        completion.continuation.resume(returning: completion.chunk)
    }

    /// Ends the fetch with `result`, once.
    private func finish(_ result: Result<MusicDownloadChunk, any Error>) {
        let continuation = state.withLock { state -> CheckedContinuation<MusicDownloadChunk, any Error>? in
            state.isDone = true
            defer { state.continuation = nil }
            return state.continuation
        }
        continuation?.resume(with: result)
    }
}

/// The session's one delegate: finds the fetch an event belongs to by its task and passes the event on.
private final class DownloadRouter: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let exchanges = OSAllocatedUnfairLock<[Int: DownloadExchange]>(initialState: [:])

    func add(_ exchange: DownloadExchange, for task: URLSessionTask) {
        exchanges.withLock { $0[task.taskIdentifier] = exchange }
    }

    private func exchange(for task: URLSessionTask) -> DownloadExchange? {
        exchanges.withLock { $0[task.taskIdentifier] }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        completionHandler(exchange(for: dataTask)?.receive(response) ?? .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        exchange(for: dataTask)?.receive(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let exchange = exchanges.withLock { $0.removeValue(forKey: task.taskIdentifier) }
        exchange?.complete(error: error)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        // The completion-handler form, as the InnerTube client's delegate: the async variant crashes the thunk.
        completionHandler(exchange(for: task).flatMap { URLSessionDownloadTransport.redirected(request, from: $0.origin) })
    }
}
