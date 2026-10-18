import CryptoKit
import Foundation

/// The request headers YouTube Music's web client sends, including the SAPISIDHASH
/// authorization derived from the sign-in cookies. Pure: the clock is a parameter.
enum MusicAuthHeaders {
    static let origin = "https://music.youtube.com"
    static let clientName = "67"
    /// Safari on macOS, sent on every API call and again by AVPlayer on the stream.
    static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.5 Safari/605.1.15"

    // MARK: - Authorization

    /// `SAPISIDHASH`, `SAPISID1PHASH` and `SAPISID3PHASH` parts, each present only when its cookie
    /// is. SAPISID falls back to `__Secure-3PAPISID`; nil when neither exists.
    static func authorization(
        sapisid: String?,
        secure1PAPISID: String?,
        secure3PAPISID: String?,
        timestamp: Int
    ) -> String? {
        let primary = nonEmpty(sapisid) ?? nonEmpty(secure3PAPISID)
        guard primary != nil else { return nil }
        let schemes: [(String, String?)] = [
            ("SAPISIDHASH", primary),
            ("SAPISID1PHASH", nonEmpty(secure1PAPISID)),
            ("SAPISID3PHASH", nonEmpty(secure3PAPISID)),
        ]
        return schemes
            .compactMap { scheme, sid in sid.map { "\(scheme) \(timestamp)_\(hash(timestamp: timestamp, sid: $0))" } }
            .joined(separator: " ")
    }

    /// Reads the three cookies for `url` from the jar. The hash always uses the music origin.
    static func authorization(jar: MusicCookieJar, url: URL, now: Date) -> String? {
        authorization(
            sapisid: jar.value(named: "SAPISID", for: url, now: now),
            secure1PAPISID: jar.value(named: "__Secure-1PAPISID", for: url, now: now),
            secure3PAPISID: jar.value(named: "__Secure-3PAPISID", for: url, now: now),
            timestamp: Int(now.timeIntervalSince1970.rounded(.down))
        )
    }

    private static func hash(timestamp: Int, sid: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data("\(timestamp) \(sid) \(origin)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    // MARK: - Headers

    /// Everything an authenticated InnerTube or stats request needs. Nil when signed out.
    static func apiHeaders(
        jar: MusicCookieJar,
        url: URL,
        clientVersion: String,
        visitorData: String?,
        now: Date
    ) -> [String: String]? {
        guard let authorization = authorization(jar: jar, url: url, now: now) else { return nil }
        var headers = [
            "Authorization": authorization,
            "X-Goog-AuthUser": "0",
            "X-YouTube-Client-Name": clientName,
            "X-YouTube-Client-Version": clientVersion,
            "Origin": origin,
            "X-Origin": origin,
            "Referer": origin + "/",
            "Content-Type": "application/json",
            "User-Agent": userAgent,
        ]
        if let visitorData, !visitorData.isEmpty {
            headers["X-Goog-Visitor-Id"] = visitorData
        }
        if let cookie = jar.cookieHeader(for: url, now: now) {
            headers["Cookie"] = cookie
        }
        return headers
    }
}
