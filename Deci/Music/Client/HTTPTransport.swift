import Foundation

struct HTTPRequest: Sendable, Equatable {
    var url: URL
    var method: String = "GET"
    var headers: [String: String] = [:]
    var body: Data?
}

struct HTTPResponse: Sendable, Equatable {
    let statusCode: Int
    /// Header fields as received. Repeated Set-Cookie headers arrive comma-joined, which is the
    /// form `HTTPCookie.cookies(withResponseHeaderFields:for:)` expects.
    let headers: [String: String]
    let data: Data

    func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

/// The one seam between the InnerTube client and the network, so tests can record requests.
protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

/// Drops credentials from a redirect that leaves the host they were meant for, and refuses
/// anything that is not https.
enum RedirectGuard {
    private static let credentialHeaders: Set<String> = [
        "cookie", "authorization", "x-goog-authuser", "x-goog-visitor-id", "x-origin", "origin",
    ]

    static func redirected(_ request: URLRequest, from original: URL) -> URLRequest? {
        guard request.url?.scheme?.lowercased() == "https",
              let host = request.url?.host?.lowercased(), !host.isEmpty
        else { return nil }
        guard host != original.host?.lowercased() else { return request }
        var stripped = request
        let names = Array(request.allHTTPHeaderFields?.keys ?? [String: String]().keys)
        for name in names where credentialHeaders.contains(name.lowercased()) {
            stripped.setValue(nil, forHTTPHeaderField: name)
        }
        return stripped
    }
}

/// Plain URLSession with no cookie jar, cache or credential storage: the Cookie header is built
/// by `MusicCookieJar` and nothing else may add to or learn from it.
struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    init(configuration: URLSessionConfiguration = Self.makeConfiguration()) {
        session = URLSession(configuration: configuration)
    }

    static func makeConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 60
        config.waitsForConnectivity = false
        return config
    }

    static func urlRequest(for request: HTTPRequest) -> URLRequest {
        var built = URLRequest(url: request.url)
        built.httpMethod = request.method
        built.httpBody = request.body
        built.httpShouldHandleCookies = false
        for (name, value) in request.headers {
            built.setValue(value, forHTTPHeaderField: name)
        }
        return built
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let (data, response) = try await session.data(
            for: Self.urlRequest(for: request),
            delegate: RedirectDelegate(origin: request.url)
        )
        guard let http = response as? HTTPURLResponse else { throw MusicError.http(0) }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String { headers[key] = value }
        }
        return HTTPResponse(statusCode: http.statusCode, headers: headers, data: data)
    }
}

private final class RedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private let origin: URL

    init(origin: URL) {
        self.origin = origin
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        // The completion-handler form: the async variant crashes the Swift 6.x ObjC thunk lowering.
        completionHandler(RedirectGuard.redirected(request, from: origin))
    }
}
