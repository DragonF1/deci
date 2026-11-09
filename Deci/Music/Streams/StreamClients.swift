import Foundation

/// The InnerTube clients a stream can be asked from. googlevideo rejects WEB_REMIX URLs that carry no PO token, so
/// the formats come from a client that needs none; WEB_REMIX stays as the last resort and as the source of the
/// playability status and the tracking URLs.
enum StreamClient: String, Sendable, Equatable, CaseIterable {
    /// Signed-in TVHTML5 (yt-dlp's tv_downgraded): cookies and SAPISIDHASH, no PO token.
    case tv
    /// Anonymous ANDROID_VR: no cookies, no auth, direct URLs.
    case androidVR = "android_vr"
    case webRemix = "web_remix"

    /// The clients tried before WEB_REMIX, in order.
    static let preferredOrder: [StreamClient] = [.tv, .androidVR]

    static let playerURL = URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false")!
    static let wwwOrigin = "https://www.youtube.com"

    static let tvVersion = "5.20260114"
    static let tvUserAgent = "Mozilla/5.0 (ChromiumStylePlatform) Cobalt/Version"
    static let vrVersion = "1.65.10"
    static let vrUserAgent =
        "com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip"

    /// The User-Agent AVPlayer, the ranged fetch and the probe send to googlevideo for this client's URLs.
    var userAgent: String {
        switch self {
        case .tv: Self.tvUserAgent
        case .androidVR: Self.vrUserAgent
        case .webRemix: MusicAuthHeaders.userAgent
        }
    }

    /// Whether the player call carries the account's cookies and SAPISIDHASH.
    var sendsAccount: Bool { self == .tv }

    /// `context.client` of the player call; nil for WEB_REMIX, which InnerTubeClient builds itself.
    func contextClient(visitorData: String?) -> [String: Any]? {
        switch self {
        case .tv:
            var client: [String: Any] = [
                "clientName": "TVHTML5",
                "clientVersion": Self.tvVersion,
                "userAgent": Self.tvUserAgent,
                "hl": "en",
                "gl": "US",
            ]
            if let visitorData, !visitorData.isEmpty { client["visitorData"] = visitorData }
            return client
        case .androidVR:
            var client: [String: Any] = [
                "clientName": "ANDROID_VR",
                "clientVersion": Self.vrVersion,
                "deviceMake": "Oculus",
                "deviceModel": "Quest 3",
                "androidSdkVersion": 32,
                "userAgent": Self.vrUserAgent,
                "osName": "Android",
                "osVersion": "12L",
                "hl": "en",
                "gl": "US",
            ]
            if let visitorData, !visitorData.isEmpty { client["visitorData"] = visitorData }
            return client
        case .webRemix:
            return nil
        }
    }

    /// The headers that do not depend on the account; the TV call adds Cookie and Authorization on top.
    func baseHeaders(visitorData: String?) -> [String: String] {
        switch self {
        case .tv:
            var headers = [
                "X-YouTube-Client-Name": "7",
                "X-YouTube-Client-Version": Self.tvVersion,
                "User-Agent": Self.tvUserAgent,
                "Content-Type": "application/json",
                "Origin": Self.wwwOrigin,
                "X-Origin": Self.wwwOrigin,
                "X-Goog-AuthUser": "0",
            ]
            if let visitorData, !visitorData.isEmpty { headers["X-Goog-Visitor-Id"] = visitorData }
            return headers
        case .androidVR:
            var headers = [
                "X-YouTube-Client-Name": "28",
                "X-YouTube-Client-Version": Self.vrVersion,
                "User-Agent": Self.vrUserAgent,
                "Content-Type": "application/json",
            ]
            if let visitorData, !visitorData.isEmpty { headers["X-Goog-Visitor-Id"] = visitorData }
            return headers
        case .webRemix:
            return [:]
        }
    }
}
