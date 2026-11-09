import Foundation

/// The InnerTube clients a stream can be asked from. googlevideo rejects WEB_REMIX URLs that carry no PO token, so
/// the formats come from a client that needs none; WEB_REMIX stays as the last resort and as the source of the
/// playability status and the tracking URLs.
enum StreamClient: String, Sendable, Equatable, CaseIterable {
    /// Anonymous VISIONOS: no cookies, no auth, direct URLs, no solving.
    case visionOS = "visionos"
    /// Signed-in TVHTML5 as yt-dlp's tv_samsung: cookies and SAPISIDHASH, no PO token.
    case tv
    case webRemix = "web_remix"

    /// The clients tried before WEB_REMIX, in order.
    static let preferredOrder: [StreamClient] = [.visionOS, .tv]

    static let playerURL = URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false")!
    static let wwwOrigin = "https://www.youtube.com"

    static let tvVersion = "5.20260707"
    static let tvUserAgent =
        "Mozilla/5.0 (SMART-TV; Linux; Tizen 2.4.0) AppleWebKit/538.1 (KHTML, like Gecko) Version/2.4.0 TV Safari/538.1"
    static let visionVersion = "1.02"
    static let visionUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"

    /// The User-Agent AVPlayer, the ranged fetch and the probe send to googlevideo for this client's URLs.
    var userAgent: String {
        switch self {
        case .visionOS: Self.visionUserAgent
        case .tv: Self.tvUserAgent
        case .webRemix: MusicAuthHeaders.userAgent
        }
    }

    /// Whether the player call carries the account's cookies and SAPISIDHASH.
    var sendsAccount: Bool { self == .tv }

    /// Whether the format must carry a direct `url` (no signatureCipher to solve).
    var needsDirectURL: Bool { self == .visionOS }

    /// `context.client` of the player call; nil for WEB_REMIX, which InnerTubeClient builds itself.
    func contextClient(visitorData: String?) -> [String: Any]? {
        var client: [String: Any]
        switch self {
        case .tv:
            client = [
                "clientName": "TVHTML5",
                "clientVersion": Self.tvVersion,
                "deviceMake": "Samsung",
                "deviceModel": "UKS9800",
                "osName": "Tizen",
                "osVersion": "2.4.0",
                "userAgent": Self.tvUserAgent,
                "hl": "en",
                "gl": "US",
            ]
        case .visionOS:
            client = [
                "clientName": "VISIONOS",
                "clientVersion": Self.visionVersion,
                "deviceMake": "Apple",
                "deviceModel": "RealityDevice17,1",
                "userAgent": Self.visionUserAgent,
                "osName": "visionOS",
                "osVersion": "26.5.23O471",
                "hl": "en",
                "gl": "US",
            ]
        case .webRemix:
            return nil
        }
        if let visitorData, !visitorData.isEmpty { client["visitorData"] = visitorData }
        return client
    }

    /// The headers that do not depend on the account; the TV call adds Cookie and Authorization on top.
    func baseHeaders(visitorData: String?) -> [String: String] {
        var headers: [String: String]
        switch self {
        case .tv:
            headers = [
                "X-YouTube-Client-Name": "7",
                "X-YouTube-Client-Version": Self.tvVersion,
                "User-Agent": Self.tvUserAgent,
                "Content-Type": "application/json",
                "Origin": Self.wwwOrigin,
                "X-Origin": Self.wwwOrigin,
                "X-Goog-AuthUser": "0",
            ]
        case .visionOS:
            headers = [
                "X-YouTube-Client-Name": "101",
                "X-YouTube-Client-Version": Self.visionVersion,
                "User-Agent": Self.visionUserAgent,
                "Content-Type": "application/json",
                "Origin": Self.wwwOrigin,
            ]
        case .webRemix:
            return [:]
        }
        if let visitorData, !visitorData.isEmpty { headers["X-Goog-Visitor-Id"] = visitorData }
        return headers
    }
}
