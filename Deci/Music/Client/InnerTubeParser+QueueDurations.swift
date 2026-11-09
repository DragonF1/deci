// Deci/Music/Client/InnerTubeParser+QueueDurations.swift
import Foundation

extension InnerTubeParser {
    /// The length in seconds of each song in a `music/get_queue` answer, by video id. A row holds its renderer directly
    /// or inside the wrapper YouTube uses for songs with a video twin; a row with no id or no readable length is left out.
    static func queueDurations(from root: [String: Any]) -> [String: Int] {
        var lengths: [String: Int] = [:]
        for data in root["queueDatas"] as? [[String: Any]] ?? [] {
            guard let content = data["content"] as? [String: Any] else { continue }
            let wrapped = path(content, "playlistPanelVideoWrapperRenderer", "primaryRenderer", "playlistPanelVideoRenderer")
            guard let renderer = (content["playlistPanelVideoRenderer"] ?? wrapped) as? [String: Any],
                  let videoId = string(renderer["videoId"]),
                  let seconds = duration(of: runs(renderer["lengthText"])), seconds > 0
            else { continue }
            lengths[videoId] = seconds
        }
        return lengths
    }

    static func queueDurations(from data: Data) throws -> [String: Int] {
        queueDurations(from: try jsonObject(data, what: "queue response"))
    }
}
