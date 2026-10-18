import Foundation

extension InnerTubeParser {
    /// The signed-in account from an `account/account_menu` response. The renderer sits at
    /// `actions[0].openPopupAction.popup.multiPageMenuRenderer.header.activeAccountHeaderRenderer`, but
    /// is searched for rather than addressed, because YouTube re-nests these popups without notice.
    /// Nil when the response has no account header or the header has no readable name.
    static func accountInfo(from data: Data) throws -> MusicAccount? {
        let root = try jsonObject(data, what: "account menu response")
        var headers: [[String: Any]] = []
        collect("activeAccountHeaderRenderer", in: root, into: &headers)
        guard let header = headers.first,
              let name = text(of: runs(header["accountName"]))
        else { return nil }
        return MusicAccount(
            name: name,
            handle: text(of: runs(header["channelHandle"])),
            photoURL: accountPhotoURL(in: header["accountPhoto"])
        )
    }

    /// The largest avatar. Google serves these protocol-relative ("//yt3.ggpht.com/...") as often as
    /// absolute; anything that is not https once resolved is refused, since the URL goes to an image loader.
    private static func accountPhotoURL(in photo: Any?) -> URL? {
        let candidates = (photo as? [String: Any])?["thumbnails"] as? [[String: Any]] ?? []
        let best = candidates.max { (int($0["width"]) ?? 0) < (int($1["width"]) ?? 0) }
        guard var raw = string(best?["url"])?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if raw.hasPrefix("//") { raw = "https:" + raw }
        guard let url = URL(string: raw), url.scheme?.lowercased() == "https", url.host?.isEmpty == false else { return nil }
        return url
    }
}
