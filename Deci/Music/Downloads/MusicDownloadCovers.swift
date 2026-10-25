// Deci/Music/Downloads/MusicDownloadCovers.swift
import CryptoKit
import Foundation

/// The names saved cover pictures have in `covers/`.
nonisolated enum MusicDownloadCovers {
    /// The file name for the picture at `url`: the SHA-256 of the address as lowercase hexadecimal, and `.img`. The same
    /// address always gives the same name, so songs that share a cover share the file, and no address can name a path.
    static func name(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return digest.map { String(format: "%02x", $0) }.joined() + ".img"
    }
}

/// The one seam between the downloads and the network for pictures, so tests serve them from memory.
protocol MusicCoverFetching: Sendable {
    /// The bytes of the picture at `url`. Throws when it cannot be had.
    func fetch(_ url: URL) async throws -> Data
}

/// Fetches a cover over https. A picture is a few kilobytes: anything that is not a 200 with some bytes, or is larger
/// than `maxBytes`, is refused.
struct URLSessionCoverFetcher: MusicCoverFetching {
    /// Two MiB: far more than a 226 px picture, small enough that a wrong answer cannot fill the disk.
    static let maxBytes = 2 * 1_024 * 1_024
    static let timeout: TimeInterval = 15

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetch(_ url: URL) async throws -> Data {
        guard url.scheme?.lowercased() == "https" else { throw MusicDownloadError.insecureURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = Self.timeout
        let (data, response) = try await session.data(for: request)
        return try Self.accept(data, from: response)
    }

    /// `data` if it is a picture worth saving: the answer is an HTTP 200, and the body is not empty and within `maxBytes`.
    static func accept(_ data: Data, from response: URLResponse) throws -> Data {
        guard let http = response as? HTTPURLResponse else { throw MusicDownloadError.badResponse }
        guard http.statusCode == 200 else { throw MusicDownloadError.badStatus(http.statusCode) }
        guard !data.isEmpty, data.count <= maxBytes else { throw MusicDownloadError.badResponse }
        return data
    }
}
