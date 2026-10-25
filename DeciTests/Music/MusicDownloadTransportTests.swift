// DeciTests/Music/MusicDownloadTransportTests.swift
// The live transport against a URLProtocol stub, so no request leaves the process: how an answer is read (status,
// Content-Range, body), what is refused before its body is read, progress while a body arrives, cancelling, and the
// session's settings. Each test talks to a made-up host of its own, so the tests can run side by side.

import Foundation
import os
import Testing
@testable import Deci

/// A server that answers every request to its own made-up host with one scripted reply.
nonisolated final class StubServer: @unchecked Sendable {
    nonisolated enum Ending: Sendable {
        /// The reply completes normally.
        case finish
        /// The reply stops after its slices and never completes, like a connection gone quiet.
        case hang
        /// The reply fails with this error after its slices.
        case fail(URLError.Code)
    }

    nonisolated struct Reply: Sendable {
        var status = 206
        var headers: [String: String] = [:]
        /// The body, delivered in these pieces.
        var slices: [Data] = []
        var ending = Ending.finish
    }

    private struct State {
        var reply: Reply
        var requests: [URLRequest] = []
        var stops = 0
        var requestWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
        var stopWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    }

    private static let registry = OSAllocatedUnfairLock<[String: StubServer]>(initialState: [:])

    let host = "\(UUID().uuidString.lowercased()).stub.test"
    private let state: OSAllocatedUnfairLock<State>

    init(_ reply: Reply) {
        state = OSAllocatedUnfairLock(initialState: State(reply: reply))
        Self.registry.withLock { $0[host] = self }
    }

    /// Takes the server off the air.
    func close() {
        Self.registry.withLock { $0[host] = nil }
    }

    static func server(forHost host: String) -> StubServer? {
        registry.withLock { $0[host] }
    }

    var url: URL { URL(string: "https://\(host)/a.m4a?clen=100")! }

    var requests: [URLRequest] { state.withLock { $0.requests } }

    /// Called by the protocol as a request starts; returns the reply to give.
    func began(_ request: URLRequest) -> Reply {
        let (reply, ready) = state.withLock { state -> (Reply, [CheckedContinuation<Void, Never>]) in
            state.requests.append(request)
            let ready = state.requestWaiters.filter { $0.count <= state.requests.count }.map(\.continuation)
            state.requestWaiters.removeAll { $0.count <= state.requests.count }
            return (state.reply, ready)
        }
        for continuation in ready { continuation.resume() }
        return reply
    }

    /// Called by the protocol when the client stops a request, whether it finished or was cancelled.
    func stopped() {
        let ready = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.stops += 1
            let ready = state.stopWaiters.filter { $0.count <= state.stops }.map(\.continuation)
            state.stopWaiters.removeAll { $0.count <= state.stops }
            return ready
        }
        for continuation in ready { continuation.resume() }
    }

    /// Returns once `count` requests have started.
    func waitForRequests(_ count: Int) async {
        await withCheckedContinuation { continuation in
            let isReady = state.withLock { state -> Bool in
                if state.requests.count >= count { return true }
                state.requestWaiters.append((count, continuation))
                return false
            }
            if isReady { continuation.resume() }
        }
    }

    /// Returns once the client has stopped `count` requests.
    func waitForStops(_ count: Int) async {
        await withCheckedContinuation { continuation in
            let isReady = state.withLock { state -> Bool in
                if state.stops >= count { return true }
                state.stopWaiters.append((count, continuation))
                return false
            }
            if isReady { continuation.resume() }
        }
    }
}

/// Serves `StubServer` replies to a session that lists it in `protocolClasses`.
nonisolated final class StubProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host, let server = StubServer.server(forHost: host),
              let client
        else {
            self.client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let reply = server.began(request)
        let response = HTTPURLResponse(
            url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers
        )!
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for slice in reply.slices { client.urlProtocol(self, didLoad: slice) }
        switch reply.ending {
        case .finish: client.urlProtocolDidFinishLoading(self)
        case .hang: break
        case .fail(let code): client.urlProtocol(self, didFailWithError: URLError(code))
        }
    }

    override func stopLoading() {
        guard let host = request.url?.host else { return }
        StubServer.server(forHost: host)?.stopped()
    }
}

/// The byte counts a fetch reported to its `received` handler, from whatever queue it was called on.
nonisolated final class ReceivedLog: @unchecked Sendable {
    private let values = OSAllocatedUnfairLock<[Int]>(initialState: [])

    func note(_ count: Int) { values.withLock { $0.append(count) } }

    var all: [Int] { values.withLock { $0 } }
}

@MainActor
@Suite("MusicDownloadTransport")
struct MusicDownloadTransportTests {
    private func makeTransport() -> URLSessionDownloadTransport {
        let configuration = URLSessionDownloadTransport.makeConfiguration()
        configuration.protocolClasses = [StubProtocol.self]
        return URLSessionDownloadTransport(configuration: configuration)
    }

    /// Slices of `size` bytes each, together `total` bytes of the sample payload.
    private func slices(total: Int, size: Int) -> [Data] {
        let payload = DownloadSamples.payload(total)
        return stride(from: 0, to: total, by: size).map { payload.subdata(in: $0..<min($0 + size, total)) }
    }

    // MARK: - Before any request

    @Test("only https goes out: http, file and other schemes are refused before any request")
    func onlyHTTPS() async {
        let transport = URLSessionDownloadTransport()
        for address in ["http://media.example.test/a.m4a", "file:///etc/hosts", "ftp://media.example.test/a.m4a"] {
            await #expect(throws: MusicDownloadError.insecureURL, "\(address)") {
                _ = try await transport.fetch(url: URL(string: address)!, range: 0...9, headers: [:])
            }
        }
    }

    @Test("the request is a ranged GET that sends no cookies, with the stream's headers")
    func requestShape() throws {
        let url = URL(string: "https://media.example.test/a.m4a?clen=35")!
        let request = URLSessionDownloadTransport.urlRequest(
            url: url, range: 10...19, headers: ["User-Agent": "test-agent", "Range": "bytes=0-0"]
        )

        #expect(request.url == url)
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Range") == "bytes=10-19")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "test-agent")
        #expect(request.httpShouldHandleCookies == false)
    }

    @Test("the session keeps no cookies, cache or credentials; a silent request fails after 30 s and a chunk after 120 s")
    func configuration() {
        let config = URLSessionDownloadTransport.makeConfiguration()

        #expect(config.httpCookieStorage == nil)
        #expect(config.httpShouldSetCookies == false)
        #expect(config.httpCookieAcceptPolicy == .never)
        #expect(config.urlCache == nil)
        #expect(config.urlCredentialStorage == nil)
        #expect(config.timeoutIntervalForRequest == 30)
        #expect(config.timeoutIntervalForResource == 120)
        #expect(config.waitsForConnectivity == false)
    }

    @Test("a redirect off https is refused, and one to another https host keeps the request")
    func redirects() {
        let origin = URL(string: "https://media.example.test/a.m4a")!
        var toHTTP = URLRequest(url: URL(string: "http://media.example.test/a.m4a")!)
        toHTTP.setValue("bytes=0-9", forHTTPHeaderField: "Range")
        #expect(URLSessionDownloadTransport.redirected(toHTTP, from: origin) == nil)

        var toOtherHost = URLRequest(url: URL(string: "https://other.example.test/a.m4a")!)
        toOtherHost.setValue("bytes=0-9", forHTTPHeaderField: "Range")
        toOtherHost.setValue("secret", forHTTPHeaderField: "Cookie")
        let followed = URLSessionDownloadTransport.redirected(toOtherHost, from: origin)
        #expect(followed?.value(forHTTPHeaderField: "Range") == "bytes=0-9")
        #expect(followed?.value(forHTTPHeaderField: "Cookie") == nil)
    }

    // MARK: - Reading an answer

    @Test("a 206 comes back whole, with its Content-Range read for the byte range and the total")
    func partialContentRead() async throws {
        let body = DownloadSamples.payload(10)
        let server = StubServer(.init(
            status: 206, headers: ["Content-Range": "bytes 10-19/100"], slices: [body.prefix(4), body.suffix(6)]
        ))
        defer { server.close() }

        let chunk = try await makeTransport().fetch(
            url: server.url, range: 10...19, headers: ["User-Agent": "test-agent"]
        )

        #expect(chunk == MusicDownloadChunk(data: body, status: 206, totalLength: 100, byteRange: 10...19))
        let request = try #require(server.requests.first)
        #expect(request.value(forHTTPHeaderField: "Range") == "bytes=10-19")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "test-agent")
    }

    @Test("a Content-Range with an unknown total gives the range and no total")
    func unknownTotal() async throws {
        let body = DownloadSamples.payload(5)
        let server = StubServer(.init(status: 206, headers: ["Content-Range": "bytes 0-4/*"], slices: [body]))
        defer { server.close() }

        let chunk = try await makeTransport().fetch(url: server.url, range: 0...4, headers: [:])

        #expect(chunk.totalLength == nil)
        #expect(chunk.byteRange == 0...4)
    }

    @Test("the Content-Range header is read for its byte range, and anything that is not one is no range")
    func byteRangeParsing() {
        #expect(MusicDownloadChunk.byteRange(inContentRange: "bytes 0-9/100") == 0...9)
        #expect(MusicDownloadChunk.byteRange(inContentRange: "bytes 10-19/*") == 10...19)
        #expect(MusicDownloadChunk.byteRange(inContentRange: "Bytes 5-5/6") == 5...5)
        #expect(MusicDownloadChunk.byteRange(inContentRange: "bytes */100") == nil)
        #expect(MusicDownloadChunk.byteRange(inContentRange: "bytes 9-0/100") == nil)
        #expect(MusicDownloadChunk.byteRange(inContentRange: "bytes -5-9/100") == nil)
        #expect(MusicDownloadChunk.byteRange(inContentRange: "bytes a-9/100") == nil)
        #expect(MusicDownloadChunk.byteRange(inContentRange: "bytes 0-9") == nil)
        #expect(MusicDownloadChunk.byteRange(inContentRange: "garbage") == nil)
        #expect(MusicDownloadChunk.byteRange(inContentRange: "") == nil)
        #expect(MusicDownloadChunk.byteRange(inContentRange: nil) == nil)
    }

    @Test("a status other than 206 is handed back as a status, not thrown: 403 and 416 and 500 and 200")
    func statusMapping() async throws {
        for status in [403, 416, 500, 200] {
            let server = StubServer(.init(
                status: status, headers: status == 416 ? ["Content-Range": "bytes */100"] : [:],
                slices: [DownloadSamples.payload(8)]
            ))
            defer { server.close() }

            let chunk = try await makeTransport().fetch(url: server.url, range: 0...9, headers: [:])

            #expect(chunk.status == status)
            #expect(chunk.byteRange == nil)
            #expect(chunk.totalLength == (status == 416 ? 100 : nil))
        }
    }

    @Test("a status other than 206 is refused from its headers: the body is never read, and the request is stopped")
    func nonPartialRejectedBeforeBody() async throws {
        let server = StubServer(.init(status: 200, slices: slices(total: 512 * 1_024, size: 64 * 1_024)))
        defer { server.close() }
        let received = ReceivedLog()

        let chunk = try await makeTransport().fetch(url: server.url, range: 0...9, headers: [:]) { received.note($0) }

        #expect(chunk.status == 200)
        #expect(chunk.data.isEmpty)
        #expect(received.all.isEmpty)
        await server.waitForStops(1)
    }

    @Test("a network error comes through as it is")
    func networkErrorPassesThrough() async {
        let server = StubServer(.init(
            status: 206, headers: ["Content-Range": "bytes 0-9/100"], slices: [DownloadSamples.payload(4)],
            ending: .fail(.networkConnectionLost)
        ))
        defer { server.close() }

        do {
            _ = try await makeTransport().fetch(url: server.url, range: 0...9, headers: [:])
            Issue.record("The fetch should have failed")
        } catch {
            #expect((error as? URLError)?.code == .networkConnectionLost)
        }
    }

    // MARK: - Progress

    @Test("bytes received are reported at least every 256 KB and end at the size of the body")
    func progressWhileReceiving() async throws {
        let total = 1_024 * 1_024
        let server = StubServer(.init(
            status: 206, headers: ["Content-Range": "bytes 0-\(total - 1)/\(total)"],
            slices: slices(total: total, size: 16 * 1_024)
        ))
        defer { server.close() }
        let received = ReceivedLog()

        let chunk = try await makeTransport().fetch(
            url: server.url, range: 0...Int64(total - 1), headers: [:]
        ) { received.note($0) }

        #expect(chunk.data.count == total)
        let counts = received.all
        #expect(counts.last == total)
        #expect(counts == counts.sorted())
        // The gap from the start to the first report, and between reports, is at most 256 KB.
        let gaps = zip([0] + counts, counts).map { $1 - $0 }
        #expect(gaps.allSatisfy { $0 > 0 && $0 <= 256 * 1_024 }, "reports: \(counts)")
    }

    @Test("a big body arrives intact")
    func bigBodyIntact() async throws {
        let total = 4 * 1_024 * 1_024
        let body = slices(total: total, size: 64 * 1_024)
        let server = StubServer(.init(
            status: 206, headers: ["Content-Range": "bytes 0-\(total - 1)/\(total)"], slices: body
        ))
        defer { server.close() }

        let chunk = try await makeTransport().fetch(url: server.url, range: 0...Int64(total - 1), headers: [:])

        #expect(chunk.data == body.reduce(into: Data()) { $0.append($1) })
        #expect(chunk.byteRange == 0...Int64(total - 1))
    }

    // MARK: - Cancelling

    @Test("cancelling stops the request and ends the fetch with a cancellation, not a network error",
          .timeLimit(.minutes(1)))
    func cancellationStopsRequest() async throws {
        let server = StubServer(.init(
            status: 206, headers: ["Content-Range": "bytes 0-99/100"], slices: [DownloadSamples.payload(10)],
            ending: .hang
        ))
        defer { server.close() }
        let transport = makeTransport()
        let url = server.url
        let task = Task { try await transport.fetch(url: url, range: 0...99, headers: [:]) }
        await server.waitForRequests(1)

        task.cancel()
        let result = await task.result

        guard case .failure(let error) = result else {
            Issue.record("A cancelled fetch finished")
            return
        }
        #expect(error is CancellationError)
        await server.waitForStops(1)
    }

    @Test("a fetch cancelled before it starts sends nothing", .timeLimit(.minutes(1)))
    func cancelledBeforeStart() async {
        let server = StubServer(.init(status: 206, slices: [], ending: .hang))
        defer { server.close() }
        let transport = makeTransport()
        let url = server.url

        let task = Task {
            // Cancelled before the first suspension inside the fetch.
            withUnsafeCurrentTask { $0?.cancel() }
            return try await transport.fetch(url: url, range: 0...9, headers: [:])
        }
        let result = await task.result

        guard case .failure(let error) = result else {
            Issue.record("A cancelled fetch finished")
            return
        }
        #expect(error is CancellationError)
        #expect(server.requests.isEmpty)
    }
}
