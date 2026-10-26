// Deci/Music/Client/InnerTubeParser+APIError.swift
// What is safe to log of a Google API error body (the answer to a refused InnerTube call): the status word and the first
// reason, each only when it is a short plain token. The message and every other field are never read out.
import Foundation

extension InnerTubeParser {

    /// The two tokens of an API error body, each nil when the body does not give a usable one.
    struct APIErrorSummary: Equatable {
        /// `error.status`, such as "PERMISSION_DENIED".
        let status: String?
        /// The `reason` of the first entry of `error.errors` that has one, such as "forbidden".
        let reason: String?
    }

    /// The longest token kept. Real statuses and reasons are far shorter, so a longer value is not one.
    private static let apiErrorTokenLimit = 40
    /// The largest body read, in bytes. A real error body is a few hundred bytes; a larger one is not parsed at all.
    private static let apiErrorBodyLimit = 64 * 1024

    /// The status and first reason of an API error body. A body that is not a JSON object, has no `error` object, or is
    /// over 64 KB gives nothing. Never throws.
    static func apiErrorSummary(from data: Data) -> APIErrorSummary {
        guard data.count <= apiErrorBodyLimit,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = root["error"] as? [String: Any]
        else { return APIErrorSummary(status: nil, reason: nil) }
        let entries = (error["errors"] as? [Any] ?? []).lazy.compactMap { $0 as? [String: Any] }
        let firstReason = entries.compactMap { string($0["reason"]) }.first
        return APIErrorSummary(status: apiErrorToken(string(error["status"])), reason: apiErrorToken(firstReason))
    }

    /// The value when it is 1 to 40 ASCII letters, digits or underscores, else nil.
    private static func apiErrorToken(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.utf8.count <= apiErrorTokenLimit else { return nil }
        let plain = value.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x5F: true
            default: false
            }
        }
        return plain ? value : nil
    }
}
