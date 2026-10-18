import Foundation

/// Turns playbackTracking.videostatsPlaybackUrl.baseUrl into the request that adds a play to the
/// account's YouTube Music history: the web client appends its own parameters and a per-session cpn.
enum HistoryURLBuilder {
    static let clientName = "WEB_REMIX"
    static let version = "2"

    static func url(trackingURL: URL, cpn: String, clientVersion: String) -> URL {
        guard var components = URLComponents(url: trackingURL, resolvingAgainstBaseURL: false) else { return trackingURL }
        let added: [URLQueryItem] = [
            URLQueryItem(name: "ver", value: version),
            URLQueryItem(name: "c", value: clientName),
            URLQueryItem(name: "cpn", value: encode(cpn)),
            URLQueryItem(name: "cver", value: encode(clientVersion)),
        ]
        let names = Set(added.map(\.name))
        // Existing items keep their exact encoding; a repeated name is replaced rather than duplicated.
        let kept = (components.percentEncodedQueryItems ?? []).filter { !names.contains($0.name) }
        components.percentEncodedQueryItems = kept + added
        return components.url ?? trackingURL
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }
}
