// Deci/Music/Client/InnerTubeParser+Like.swift
// The like state of one song, read out of a `next` response.
import Foundation

extension InnerTubeParser {

    /// The like state of `videoId` in a `next` response: the `likeStatus` of the `likeButtonRenderer` whose target is
    /// that song (the player overlay carries one, and other songs' buttons are not taken for it). Nil when there is no
    /// such button or it names a status this build does not know.
    static func likeStatus(from data: Data, videoId: String) throws -> MusicLikeStatus? {
        let root = try jsonObject(data, what: "like status response")
        var buttons: [[String: Any]] = []
        collect("likeButtonRenderer", in: root, into: &buttons)
        guard let button = buttons.first(where: { string(path($0, "target", "videoId")) == videoId }) else { return nil }
        switch string(button["likeStatus"]) {
        case "LIKE": return .like
        case "DISLIKE": return .dislike
        case "INDIFFERENT": return .indifferent
        default: return nil
        }
    }
}
