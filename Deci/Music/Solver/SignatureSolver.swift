import Foundation
import JavaScriptCore
import os

/// What to solve against one player build: scrambled signatures (`s` of a signatureCipher) and
/// throttling `n` values.
struct ChallengeRequest: Sendable, Equatable {
    var playerHash: String
    var sigInputs: [String]
    var nInputs: [String]
}

/// The solved values, keyed by the challenge that was sent.
struct ChallengeSolutions: Sendable, Equatable {
    var sig: [String: String]
    var n: [String: String]
}

protocol ChallengeSolving: Sendable {
    /// `rawPlayer` downloads the player JS. It is called only when no preprocessed copy of this
    /// player build is cached, so a warm solve does no network work.
    func solve(_ request: ChallengeRequest, rawPlayer: @Sendable () async throws -> String) async throws -> ChallengeSolutions
}

// MARK: - Scripts

/// The three scripts the solver evaluates: meriyah and astring (parser and printer) and the
/// yt-dlp/ejs helper that defines `jsc`.
struct SolverScripts: Sendable, Equatable {
    var meriyah: String
    var astring: String
    var helper: String

    private final class BundleToken {}

    /// Reads the scripts from the app bundle's Resources. A missing file is a solver error, not
    /// a crash.
    static func bundled() throws -> SolverScripts {
        let bundles = [Bundle(for: BundleToken.self), Bundle.main]
        func load(_ name: String, _ ext: String) throws -> String {
            for bundle in bundles {
                if let url = bundle.url(forResource: name, withExtension: ext),
                   let text = try? String(contentsOf: url, encoding: .utf8) {
                    return text
                }
            }
            throw MusicError.solver("missing resource \(name).\(ext)")
        }
        return SolverScripts(
            meriyah: try load("meriyah.umd", "js"),
            astring: try load("astring.umd", "js"),
            helper: try load("yt_ejs_helper", "js")
        )
    }
}

// MARK: - JavaScriptCore session

/// A JavaScriptCore context with the solver scripts loaded. Not Sendable: it is created, used
/// and dropped on the `JSSolverThread` thread only.
final class SolverSession {
    enum PlayerInput: Sendable {
        case raw(String)
        case preprocessed(String)
    }

    struct Output: Sendable {
        var solutions: ChallengeSolutions
        /// The preprocessed player, present when the input was the raw player.
        var preprocessed: String?
    }

    private static let maxErrorLength = 300

    private let context: JSContext
    private var lastException: String?

    /// The minimal browser surface the player's top level touches, matching what yt-dlp's
    /// node and bun runtimes provide.
    private static let shims = #"""
        globalThis.XMLHttpRequest = { prototype: {} };
        globalThis.URL = class URL {
            constructor(url) {
                this.href = url;
                const match = url.match(/^(https?:)\/\/([^/:]+)(:(\d+))?(\/[^?#]*)?(\?[^#]*)?(#.*)?$/);
                this.protocol = match ? match[1] : '';
                this.hostname = match ? match[2] : '';
                this.port = match && match[4] ? match[4] : '';
                this.pathname = match && match[5] ? match[5] : '/';
                this.search = match && match[6] ? match[6] : '';
                this.hash = match && match[7] ? match[7] : '';
            }
        };
        globalThis.navigator = {
            userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36'
        };
        const window = Object.assign(Object.create(null), globalThis);
        window.location = new URL("https://www.youtube.com/watch?v=deci-music");
        const document = {};
        let self = globalThis;
        """#

    init(scripts: SolverScripts) throws {
        guard let context = JSContext() else { throw MusicError.solver("could not create a JavaScript context") }
        self.context = context
        context.exceptionHandler = { [weak self] _, exception in
            self?.lastException = exception?.toString() ?? "unknown JavaScript error"
        }
        try evaluate(Self.shims, label: "shims")
        try evaluate(scripts.meriyah, label: "meriyah")
        try evaluate(scripts.astring, label: "astring")
        try evaluate(scripts.helper, label: "helper")
        guard context.objectForKeyedSubscript("jsc")?.isObject == true else {
            throw MusicError.solver("the helper script did not define jsc")
        }
    }

    // MARK: - Solving

    private struct Input: Encodable {
        struct Request: Encodable {
            let type: String
            let challenges: [String]
        }

        let type: String
        let player: String?
        let preprocessedPlayer: String?
        let requests: [Request]
        let outputPreprocessed: Bool?

        enum CodingKeys: String, CodingKey {
            case type, player, requests
            case preprocessedPlayer = "preprocessed_player"
            case outputPreprocessed = "output_preprocessed"
        }
    }

    private struct Response: Decodable {
        struct Item: Decodable {
            let type: String
            let data: [String: String]?
            let error: String?
        }

        let responses: [Item]
        let preprocessedPlayer: String?

        enum CodingKeys: String, CodingKey {
            case responses
            case preprocessedPlayer = "preprocessed_player"
        }
    }

    func solve(_ request: ChallengeRequest, player: PlayerInput) throws -> Output {
        // Only the kinds that have challenges: the helper reports an error when it cannot
        // extract a function, including one nobody asked about.
        var kinds: [(type: String, challenges: [String])] = []
        if !request.nInputs.isEmpty { kinds.append(("n", request.nInputs)) }
        if !request.sigInputs.isEmpty { kinds.append(("sig", request.sigInputs)) }
        guard !kinds.isEmpty else { return Output(solutions: ChallengeSolutions(sig: [:], n: [:]), preprocessed: nil) }

        let input: Input
        switch player {
        case .raw(let js):
            input = Input(type: "player", player: js, preprocessedPlayer: nil,
                          requests: kinds.map { .init(type: $0.type, challenges: $0.challenges) },
                          outputPreprocessed: true)
        case .preprocessed(let js):
            input = Input(type: "preprocessed_player", player: nil, preprocessedPlayer: js,
                          requests: kinds.map { .init(type: $0.type, challenges: $0.challenges) },
                          outputPreprocessed: nil)
        }

        let json: String
        do {
            json = String(decoding: try JSONEncoder().encode(input), as: UTF8.self)
        } catch {
            throw MusicError.solver("could not encode the solver input")
        }

        context.setObject(json, forKeyedSubscript: "swiftInput" as NSString)
        defer { context.setObject(NSNull(), forKeyedSubscript: "swiftInput" as NSString) }
        guard let result = try evaluate("JSON.stringify(jsc(JSON.parse(swiftInput)))", label: "solve"),
              result.isString, let text = result.toString() else {
            throw MusicError.solver("the solver returned no result")
        }

        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: Data(text.utf8))
        } catch {
            throw MusicError.solver("the solver result was not understood")
        }
        guard response.responses.count == kinds.count else {
            throw MusicError.solver("the solver answered \(response.responses.count) of \(kinds.count) requests")
        }

        var solutions = ChallengeSolutions(sig: [:], n: [:])
        for (kind, item) in zip(kinds, response.responses) {
            guard item.type == "result", let data = item.data else {
                throw MusicError.solver(Self.truncated("\(kind.type): \(item.error ?? "no data")"))
            }
            if kind.type == "n" { solutions.n.merge(data) { _, new in new } }
            else { solutions.sig.merge(data) { _, new in new } }
        }
        return Output(solutions: solutions, preprocessed: response.preprocessedPlayer)
    }

    /// Evaluates a script and returns its value; any JavaScript exception becomes a solver error.
    @discardableResult
    func evaluate(_ script: String, label: String) throws -> JSValue? {
        lastException = nil
        let value = context.evaluateScript(script)
        if let message = lastException {
            lastException = nil
            throw MusicError.solver(Self.truncated("\(label): \(message)"))
        }
        return value
    }

    /// JavaScript errors carry stack traces with minified code; keep the reason short.
    private static func truncated(_ message: String) -> String {
        let flat = message.replacingOccurrences(of: "\n", with: " ")
        return flat.count > maxErrorLength ? String(flat.prefix(maxErrorLength)) + "..." : flat
    }
}

// MARK: - Solver

/// Solves challenges with JavaScriptCore on a dedicated thread.
///
/// Cold (no cached copy of this player build): the raw player is downloaded and preprocessed
/// (meriyah parse, astring print), and the preprocessed copy is cached. Warm: the cached copy is
/// fed straight to the helper, skipping the download and the parse.
final class JSChallengeSolver: ChallengeSolving {
    private static let log = Logger(subsystem: "com.abraham.Deci", category: "MusicSolver")

    private let thread: JSSolverThread<SolverSession>
    private let cache: PlayerCache

    init(
        cache: PlayerCache,
        idleTimeout: TimeInterval = 60,
        scripts: @escaping @Sendable () throws -> SolverScripts = { try SolverScripts.bundled() }
    ) {
        self.cache = cache
        thread = JSSolverThread(name: "com.abraham.Deci.music-solver", idleTimeout: idleTimeout) {
            try SolverSession(scripts: try scripts())
        }
    }

    deinit { thread.shutdown() }

    func solve(_ request: ChallengeRequest, rawPlayer: @Sendable () async throws -> String) async throws -> ChallengeSolutions {
        guard !request.sigInputs.isEmpty || !request.nInputs.isEmpty else {
            return ChallengeSolutions(sig: [:], n: [:])
        }
        let hash = request.playerHash

        if let preprocessed = cache.preprocessedPlayer(forHash: hash) {
            let start = ContinuousClock.now
            do {
                let output = try await run(request, player: .preprocessed(preprocessed))
                Self.log.info("warm solve for \(hash, privacy: .public) took \(Self.milliseconds(since: start)) ms")
                return output.solutions
            } catch MusicError.solver(let reason) {
                // A corrupt or stale cache entry: drop it and solve from the raw player.
                Self.log.error("warm solve failed (\(reason, privacy: .public)), retrying cold")
                cache.removePreprocessed(forHash: hash)
            }
        }

        let raw = try await rawPlayer()
        let start = ContinuousClock.now
        let output = try await run(request, player: .raw(raw))
        if let preprocessed = output.preprocessed, !preprocessed.isEmpty {
            cache.savePreprocessed(preprocessed, forHash: hash)
        }
        Self.log.info("cold solve for \(hash, privacy: .public) took \(Self.milliseconds(since: start)) ms")
        return output.solutions
    }

    private func run(_ request: ChallengeRequest, player: SolverSession.PlayerInput) async throws -> SolverSession.Output {
        do {
            return try await thread.run { try $0.solve(request, player: player) }
        } catch is JSSolverThread<SolverSession>.ShutDown {
            throw MusicError.solver("the solver was shut down")
        }
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let elapsed = start.duration(to: .now)
        return Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
    }
}
