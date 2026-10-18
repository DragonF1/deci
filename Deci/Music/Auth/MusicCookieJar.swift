import Foundation

/// The YouTube sign-in cookies, kept as plain values so they can be Codable, Sendable and
/// stored as one Keychain item. Callers keep only youtube.com cookies; the jar sends the ones
/// that match a request's host.
struct MusicCookieJar: Codable, Sendable, Equatable {
    /// The cookies that keep the session signed in. A change to one of these is saved to the Keychain
    /// promptly; every other cookie YouTube rotates (YSC, VISITOR_INFO1_LIVE, the *SIDCC family,
    /// __Secure-ROLLOUT_TOKEN) only rides along with a later write. See `MusicJarPersister`.
    static let signInCookieNames: Set<String> = [
        "SID", "HSID", "SSID", "APISID", "SAPISID",
        "__Secure-1PSID", "__Secure-3PSID",
        "__Secure-1PAPISID", "__Secure-3PAPISID",
        "__Secure-1PSIDTS", "__Secure-3PSIDTS",
        "LOGIN_INFO",
    ]

    private(set) var cookies: [StoredCookie]

    init(cookies: [StoredCookie] = []) {
        self.cookies = cookies
    }

    /// Cookies harvested from the sign-in window: expired ones are dropped and a repeated
    /// name/domain/path keeps the last value.
    init(signInCookies: [StoredCookie], now: Date = Date()) {
        self.cookies = []
        for cookie in signInCookies where !Self.isExpired(cookie, at: now) {
            upsert(cookie)
        }
    }

    init(from decoder: Decoder) throws {
        cookies = try decoder.singleValueContainer().decode([StoredCookie].self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(cookies)
    }

    // MARK: - Lookup

    /// True for youtube.com and its subdomains, with or without the leading dot.
    static func isYouTubeDomain(_ domain: String) -> Bool {
        let domain = domain.lowercased().drop(while: { $0 == "." })
        return domain == "youtube.com" || domain.hasSuffix(".youtube.com")
    }

    /// The first non-empty youtube.com cookie with this name.
    func value(named name: String) -> String? {
        cookies.first { Self.isYouTubeDomain($0.domain) && $0.name == name && !$0.value.isEmpty }?.value
    }

    /// The non-empty cookie with this name that would be sent to `url`.
    func value(named name: String, for url: URL, now: Date) -> String? {
        matching(url, now: now).first { $0.name == name && !$0.value.isEmpty }?.value
    }

    /// True when the jar holds what the SAPISIDHASH authorization is built from.
    var hasSignInCookies: Bool {
        value(named: "SAPISID") != nil || value(named: "__Secure-3PAPISID") != nil
    }

    /// What makes a sign-in cookie the same cookie with the same meaning: its identity, its value and whether
    /// it is Secure. The expiry is left out on purpose. A sign-in cookie that is re-sent unchanged with a
    /// `Max-Age` gets a new expiry on every response, and treating that as a change would write the Keychain
    /// (and prompt) about once a minute. A new expiry still reaches the Keychain, with the next write.
    struct SignInCookieState: Hashable {
        let name: String
        let domain: String
        let path: String
        let value: String
        let isSecure: Bool
    }

    /// The sign-in cookies as they stand. Two snapshots are equal exactly when no sign-in cookie was added,
    /// removed or given another value, domain, path or Secure flag in between; an expiry-only difference is
    /// not a difference.
    var signInSnapshot: Set<SignInCookieState> {
        Set(
            cookies
                .filter { Self.signInCookieNames.contains($0.name) }
                .map {
                    SignInCookieState(
                        name: $0.name,
                        domain: $0.domain.lowercased(),
                        path: Self.normalizedPath($0.path),
                        value: $0.value,
                        isSecure: $0.isSecure
                    )
                }
        )
    }

    // MARK: - Sending

    /// The `Cookie` request header for `url`, nil when no cookie applies.
    func cookieHeader(for url: URL, now: Date = Date()) -> String? {
        let applicable = matching(url, now: now)
        guard !applicable.isEmpty else { return nil }
        return applicable.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    /// Cookies that apply to `url`, longest path first and otherwise in jar order.
    private func matching(_ url: URL, now: Date) -> [StoredCookie] {
        guard let host = url.host?.lowercased() else { return [] }
        let isHTTPS = url.scheme?.lowercased() == "https"
        let requestPath = url.path.isEmpty ? "/" : url.path
        return cookies.enumerated()
            .filter { _, cookie in
                !Self.isExpired(cookie, at: now)
                    && (isHTTPS || !cookie.isSecure)
                    && Self.domain(cookie.domain, matches: host)
                    && Self.path(cookie.path, matches: requestPath)
            }
            .sorted { lhs, rhs in
                let (left, right) = (Self.normalizedPath(lhs.element.path).count, Self.normalizedPath(rhs.element.path).count)
                return left != right ? left > right : lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    // MARK: - Merging

    /// Applies the Set-Cookie headers of a response from `url`. Returns true when the jar changed.
    @discardableResult
    mutating func merge(headerFields: [String: String], for url: URL, now: Date) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        // HTTPCookie only recognises the exact key "Set-Cookie".
        let values = headerFields
            .filter { $0.key.caseInsensitiveCompare("Set-Cookie") == .orderedSame }
            .map(\.value)
        guard !values.isEmpty else { return false }
        let fields = ["Set-Cookie": values.joined(separator: ", ")]
        // HTTPCookie resolves Max-Age against the real clock, so a deletion has to be judged against it too.
        let deletionCutoff = max(now, Date())
        var changed = false
        for cookie in HTTPCookie.cookies(withResponseHeaderFields: fields, for: url) {
            let stored = StoredCookie(cookie)
            guard Self.domain(stored.domain, matches: host), Self.isPlausibleDomain(stored.domain) else { continue }
            if let expires = stored.expires, expires <= deletionCutoff {
                changed = remove(stored) || changed
            } else {
                changed = upsert(stored) || changed
            }
        }
        return changed
    }

    /// Drops expired cookies. Returns true when any were removed.
    @discardableResult
    mutating func prune(now: Date) -> Bool {
        let before = cookies.count
        cookies.removeAll { Self.isExpired($0, at: now) }
        return cookies.count != before
    }

    /// Inserts or replaces by name, domain and path. Returns false when nothing changed.
    @discardableResult
    private mutating func upsert(_ cookie: StoredCookie) -> Bool {
        if let index = cookies.firstIndex(where: { Self.sameIdentity($0, cookie) }) {
            guard cookies[index] != cookie else { return false }
            cookies[index] = cookie
        } else {
            cookies.append(cookie)
        }
        return true
    }

    private mutating func remove(_ cookie: StoredCookie) -> Bool {
        let before = cookies.count
        cookies.removeAll { Self.sameIdentity($0, cookie) }
        return cookies.count != before
    }

    // MARK: - Matching rules

    private static func sameIdentity(_ lhs: StoredCookie, _ rhs: StoredCookie) -> Bool {
        lhs.name == rhs.name
            && lhs.domain.lowercased() == rhs.domain.lowercased()
            && normalizedPath(lhs.path) == normalizedPath(rhs.path)
    }

    private static func isExpired(_ cookie: StoredCookie, at date: Date) -> Bool {
        guard let expires = cookie.expires else { return false }
        return expires <= date
    }

    /// A leading dot means "this domain and every subdomain"; no dot means that exact host.
    private static func domain(_ cookieDomain: String, matches host: String) -> Bool {
        let domain = cookieDomain.lowercased()
        if domain.hasPrefix(".") {
            return host == domain.dropFirst() || host.hasSuffix(domain)
        }
        return host == domain
    }

    /// Refuses a bare top-level domain such as ".com".
    private static func isPlausibleDomain(_ domain: String) -> Bool {
        domain.drop(while: { $0 == "." }).contains(".")
    }

    private static func normalizedPath(_ path: String) -> String {
        path.isEmpty ? "/" : path
    }

    private static func path(_ cookiePath: String, matches requestPath: String) -> Bool {
        let cookiePath = normalizedPath(cookiePath)
        if cookiePath == requestPath { return true }
        guard requestPath.hasPrefix(cookiePath) else { return false }
        if cookiePath.hasSuffix("/") { return true }
        return requestPath[requestPath.index(requestPath.startIndex, offsetBy: cookiePath.count)] == "/"
    }
}
