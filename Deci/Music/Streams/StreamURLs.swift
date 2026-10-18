import Foundation

/// Picks the audio format to play. AVPlayer cannot decode WebM, so only audio/mp4 is considered.
enum FormatPicker {
    /// itag 141 (AAC 256k, Premium), then 140 (AAC 128k), then the highest-bitrate audio/mp4.
    static func pick(from formats: [PlayerFormat]) -> PlayerFormat? {
        let usable = formats.filter { format in
            format.mimeType.lowercased().hasPrefix("audio/mp4")
                && (format.url?.isEmpty == false || format.signatureCipher?.isEmpty == false)
        }
        for itag in [141, 140] {
            if let match = usable.first(where: { $0.itag == itag }) { return match }
        }
        return usable.max { ($0.bitrate ?? 0) < ($1.bitrate ?? 0) }
    }
}

/// What has to be solved before a format's URL can be fetched.
struct StreamPlan: Sendable, Equatable {
    var baseURL: URL
    /// The scrambled `s` value of a signatureCipher format.
    var signatureChallenge: String?
    /// The query parameter that carries the solved signature (the cipher's `sp`).
    var signatureParameter: String
    /// The `n` throttling parameter already present in the URL.
    var nChallenge: String?

    var needsSolving: Bool { signatureChallenge != nil || nChallenge != nil }

    func challengeRequest(playerHash: String) -> ChallengeRequest {
        ChallengeRequest(
            playerHash: playerHash,
            sigInputs: signatureChallenge.map { [$0] } ?? [],
            nInputs: nChallenge.map { [$0] } ?? []
        )
    }
}

struct BuiltStream: Sendable, Equatable {
    let url: URL
    /// The URL's own `expire` parameter, nil when it has none.
    let expiresAt: Date?
}

enum StreamURLBuilder {
    private static let allowedHostSuffixes = [".googlevideo.com", ".youtube.com"]

    /// Reads a format's direct URL or its signatureCipher (`s`, `sp`, `url`, form-encoded).
    static func plan(for format: PlayerFormat) throws -> StreamPlan {
        var urlString: String
        var signature: String?
        var parameter = "signature"
        if let direct = format.url, !direct.isEmpty {
            urlString = direct
        } else if let cipher = format.signatureCipher, !cipher.isEmpty {
            let fields = formFields(cipher)
            guard let url = fields["url"] else { throw MusicError.parse("signatureCipher has no url") }
            urlString = url
            signature = fields["s"]
            if let sp = fields["sp"], isSafeParameterName(sp) { parameter = sp }
        } else {
            throw MusicError.parse("format \(format.itag) has no url")
        }
        guard let url = URL(string: urlString),
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              allowedHostSuffixes.contains(where: { host.hasSuffix($0) })
        else {
            throw MusicError.parse("stream url is not an https YouTube host")
        }
        let n = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "n" }?.value
        return StreamPlan(
            baseURL: url,
            signatureChallenge: signature,
            signatureParameter: parameter,
            nChallenge: n?.isEmpty == false ? n : nil
        )
    }

    /// Applies the solved signature and `n` value to the plan's URL, leaving the other parameters byte-for-byte.
    static func build(_ plan: StreamPlan, solutions: ChallengeSolutions) throws -> BuiltStream {
        guard var components = URLComponents(url: plan.baseURL, resolvingAgainstBaseURL: false) else {
            throw MusicError.parse("stream url is malformed")
        }
        var items = components.percentEncodedQueryItems ?? []

        if let challenge = plan.nChallenge {
            guard let solved = solutions.n[challenge], !solved.isEmpty else {
                throw MusicError.solver("n challenge was not solved")
            }
            let replacement = URLQueryItem(name: "n", value: encode(solved))
            items = items.map { $0.name == "n" ? replacement : $0 }
        }
        if let challenge = plan.signatureChallenge {
            guard let solved = solutions.sig[challenge], !solved.isEmpty else {
                throw MusicError.solver("signature challenge was not solved")
            }
            items.removeAll { $0.name == plan.signatureParameter }
            items.append(URLQueryItem(name: plan.signatureParameter, value: encode(solved)))
        }
        components.percentEncodedQueryItems = items
        guard let url = components.url else { throw MusicError.parse("stream url is malformed") }

        let expire = components.queryItems?.first { $0.name == "expire" }?.value.flatMap(TimeInterval.init)
        return BuiltStream(url: url, expiresAt: expire.map(Date.init(timeIntervalSince1970:)))
    }

    // MARK: - Encoding

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    private static func isSafeParameterName(_ name: String) -> Bool {
        !name.isEmpty && name.unicodeScalars.allSatisfy { unreserved.contains($0) && $0 != "~" }
    }

    /// `application/x-www-form-urlencoded`: plus is a space, everything else percent-decodes.
    private static func formFields(_ text: String) -> [String: String] {
        var fields: [String: String] = [:]
        for pair in text.split(separator: "&", omittingEmptySubsequences: true) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let name = decode(parts[0]) else { continue }
            let value = parts.count > 1 ? decode(parts[1]) : ""
            if fields[name] == nil, let value { fields[name] = value }
        }
        return fields
    }

    private static func decode(_ part: Substring) -> String? {
        part.replacingOccurrences(of: "+", with: " ").removingPercentEncoding
    }
}
