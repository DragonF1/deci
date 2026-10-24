// DeciTests/Music/SignatureSolverTests.swift
// The JavaScriptCore solver, driven by a tiny fake helper script so the tests stay offline.
// The real meriyah/astring/ejs scripts are exercised by the gated live test.

import Foundation
import JavaScriptCore
import os
import Testing
@testable import Deci

nonisolated enum FakeSolverScripts {
    /// Stands in for yt_ejs_helper.js: answers `<kind>|<player input type>|<challenge>`, records
    /// the request kinds it saw, and fails on demand.
    static let helper = #"""
        globalThis.__kinds = [];
        var jsc = function (input) {
          globalThis.__kinds = input.requests.map(function (r) { return r.type; });
          if (input.type === 'preprocessed_player' && input.preprocessed_player === 'CORRUPT') {
            return { type: 'result', responses: input.requests.map(function () {
              return { type: 'error', error: 'Failed to extract function' };
            }) };
          }
          var responses = input.requests.map(function (r) {
            if (r.challenges.indexOf('BOOM') >= 0) {
              return { type: 'error', error: 'Failed to extract ' + r.type + ' function\n    at f (player.js:1:1)' };
            }
            if (r.challenges.indexOf('LONG') >= 0) {
              return { type: 'error', error: 'x'.repeat(2000) };
            }
            if (r.challenges.indexOf('THROW') >= 0) { throw new Error('helper blew up'); }
            if (r.challenges.indexOf('SHORT') >= 0) { return null; }
            var data = {};
            r.challenges.forEach(function (c) { data[c] = r.type + '|' + input.type + '|' + c; });
            return { type: 'result', data: data };
          });
          if (input.requests.some(function (r) { return r.challenges.indexOf('DROP') >= 0; })) { responses.pop(); }
          var out = { type: 'result', responses: responses };
          if (input.type === 'player' && input.output_preprocessed) { out.preprocessed_player = 'PRE:' + input.player; }
          return out;
        };
        """#

    static let scripts = SolverScripts(meriyah: "var meriyahLoaded = true;", astring: "var astringLoaded = true;", helper: helper)

    /// A helper whose answer needs 8000 nested JavaScript calls.
    static let recursiveHelper = #"""
        function depth(n) { return n === 0 ? 0 : 1 + depth(n - 1); }
        var jsc = function (input) {
          var d = depth(8000);
          return { type: 'result', responses: input.requests.map(function (r) {
            var data = {}; r.challenges.forEach(function (c) { data[c] = String(d); });
            return { type: 'result', data: data };
          }) };
        };
        """#
}

@MainActor
@Suite("SolverSession")
struct SolverSessionTests {

    private func session(_ scripts: SolverScripts = FakeSolverScripts.scripts) throws -> SolverSession {
        try SolverSession(scripts: scripts)
    }

    private func request(sig: [String] = [], n: [String] = []) -> ChallengeRequest {
        ChallengeRequest(playerHash: "hash0001", sigInputs: sig, nInputs: n)
    }

    private func solverReason(_ body: () throws -> Void) -> String? {
        do { try body() } catch MusicError.solver(let reason) { return reason } catch { return "other: \(error)" }
        return nil
    }

    @Test("A raw player yields the solutions and the preprocessed player")
    func rawPlayer() throws {
        let output = try session().solve(request(sig: ["A"], n: ["B"]), player: .raw("RAWJS"))
        #expect(output.solutions.sig == ["A": "sig|player|A"])
        #expect(output.solutions.n == ["B": "n|player|B"])
        #expect(output.preprocessed == "PRE:RAWJS")
    }

    @Test("A preprocessed player is passed as such and returns no new preprocessed copy")
    func preprocessedPlayer() throws {
        let output = try session().solve(request(sig: ["A"], n: ["B"]), player: .preprocessed("PRE"))
        #expect(output.solutions.sig == ["A": "sig|preprocessed_player|A"])
        #expect(output.solutions.n == ["B": "n|preprocessed_player|B"])
        #expect(output.preprocessed == nil)
    }

    @Test("Several challenges of one kind are all answered")
    func severalChallenges() throws {
        let output = try session().solve(request(sig: ["S1", "S2"], n: ["N1", "N2", "N3"]), player: .raw("JS"))
        #expect(Set(output.solutions.sig.keys) == ["S1", "S2"])
        #expect(Set(output.solutions.n.keys) == ["N1", "N2", "N3"])
    }

    @Test("Only the kinds that have challenges are sent to the helper")
    func emptyKindsSkipped() throws {
        let session = try session()
        _ = try session.solve(request(n: ["B"]), player: .raw("JS"))
        #expect(try session.evaluate("__kinds.join(',')", label: "t")?.toString() == "n")
        _ = try session.solve(request(sig: ["A"]), player: .raw("JS"))
        #expect(try session.evaluate("__kinds.join(',')", label: "t")?.toString() == "sig")
        _ = try session.solve(request(sig: ["A"], n: ["B"]), player: .raw("JS"))
        #expect(try session.evaluate("__kinds.join(',')", label: "t")?.toString() == "n,sig")
    }

    @Test("A request with nothing to solve never calls the helper")
    func nothingToSolve() throws {
        let session = try session()
        let output = try session.solve(request(), player: .raw("JS"))
        #expect(output.solutions == ChallengeSolutions(sig: [:], n: [:]))
        #expect(output.preprocessed == nil)
        #expect(try session.evaluate("__kinds.length", label: "t")?.toInt32() == 0)
    }

    @Test("An error item from the helper becomes a solver error naming the kind")
    func errorItem() throws {
        let session = try session()
        let reason = solverReason { _ = try session.solve(request(sig: ["BOOM"]), player: .raw("JS")) }
        #expect(reason?.hasPrefix("sig: Failed to extract sig function") == true)
        #expect(reason?.contains("\n") == false)
    }

    @Test("Long helper errors are cut to a short reason")
    func longErrorTruncated() throws {
        let session = try session()
        let reason = try #require(solverReason { _ = try session.solve(request(n: ["LONG"]), player: .raw("JS")) })
        #expect(reason.count <= 310)
        #expect(reason.hasSuffix("..."))
    }

    @Test("A JavaScript exception from the helper becomes a solver error")
    func jsException() throws {
        let session = try session()
        let reason = solverReason { _ = try session.solve(request(n: ["THROW"]), player: .raw("JS")) }
        #expect(reason?.contains("helper blew up") == true)
    }

    @Test("The session is still usable after an error")
    func recoversAfterError() throws {
        let session = try session()
        _ = solverReason { _ = try session.solve(request(n: ["THROW"]), player: .raw("JS")) }
        _ = solverReason { _ = try session.solve(request(sig: ["BOOM"]), player: .raw("JS")) }
        let output = try session.solve(request(n: ["fine"]), player: .raw("JS"))
        #expect(output.solutions.n == ["fine": "n|player|fine"])
    }

    @Test("A malformed item or a wrong number of answers is a solver error")
    func malformedResponses() throws {
        let session = try session()
        #expect(solverReason { _ = try session.solve(request(n: ["SHORT"]), player: .raw("JS")) } != nil)
        #expect(solverReason { _ = try session.solve(request(sig: ["a"], n: ["DROP"]), player: .raw("JS")) } != nil)
    }

    @Test("A syntax error in a script fails construction with a solver error")
    func scriptSyntaxError() {
        let broken = SolverScripts(meriyah: "this is not javascript {", astring: "", helper: FakeSolverScripts.helper)
        let reason = solverReason { _ = try SolverSession(scripts: broken) }
        #expect(reason?.hasPrefix("meriyah:") == true)
    }

    @Test("A helper that defines no jsc fails construction")
    func missingJSC() {
        let none = SolverScripts(meriyah: "", astring: "", helper: "var other = 1;")
        #expect(solverReason { _ = try SolverSession(scripts: none) } == "the helper script did not define jsc")
    }

    @Test("The browser shims the player's top level touches are present")
    func shims() throws {
        let session = try session()
        let value = try session.evaluate(
            "[typeof XMLHttpRequest, new URL('https://a.example:8080/p?q=1#h').hostname, window.location.hostname, typeof document, String(self === globalThis), typeof navigator.userAgent].join('|')",
            label: "t"
        )?.toString()
        #expect(value == "object|a.example|www.youtube.com|object|true|string")
    }

    @Test("The player source does not linger in the context after a solve")
    func inputCleared() throws {
        let session = try session()
        _ = try session.solve(request(n: ["B"]), player: .raw(String(repeating: "x", count: 10_000)))
        #expect(try session.evaluate("String(swiftInput)", label: "t")?.toString() == "null")
    }

    @Test("The bundled scripts are in the app bundle and define jsc under JavaScriptCore")
    func bundledScriptsLoad() throws {
        let scripts = try SolverScripts.bundled()
        #expect(scripts.meriyah.count > 100_000)
        #expect(scripts.astring.count > 10_000)
        #expect(scripts.helper.contains("function main(input)"))
        let session = try SolverSession(scripts: scripts)
        #expect(try session.evaluate("typeof jsc", label: "t")?.toString() == "function")
    }
}

@MainActor
@Suite("JSChallengeSolver")
struct JSChallengeSolverTests {

    private func makeSolver(
        directory: URL = makeTemporaryDirectory("deci-solver"),
        idleTimeout: TimeInterval = 60,
        scripts: SolverScripts = FakeSolverScripts.scripts
    ) -> (JSChallengeSolver, PlayerCache, URL) {
        let cache = PlayerCache(directory: directory)
        return (JSChallengeSolver(cache: cache, idleTimeout: idleTimeout, scripts: { scripts }), cache, directory)
    }

    private func request(_ hash: String = "hash0001", sig: [String] = ["A"], n: [String] = ["B"]) -> ChallengeRequest {
        ChallengeRequest(playerHash: hash, sigInputs: sig, nInputs: n)
    }

    private nonisolated final class Downloads: @unchecked Sendable {
        private let count = OSAllocatedUnfairLock(initialState: 0)
        var value: Int { count.withLock { $0 } }
        func bump() { count.withLock { $0 += 1 } }
    }

    @Test("Cold: downloads the raw player once, solves, and caches the preprocessed copy")
    func cold() async throws {
        let (solver, cache, directory) = makeSolver()
        defer { try? FileManager.default.removeItem(at: directory) }
        let downloads = Downloads()
        let solutions = try await solver.solve(request()) { downloads.bump(); return "RAW" }
        #expect(solutions.sig == ["A": "sig|player|A"])
        #expect(solutions.n == ["B": "n|player|B"])
        #expect(downloads.value == 1)
        #expect(cache.preprocessedPlayer(forHash: "hash0001") == "PRE:RAW")
    }

    @Test("Warm: the cached preprocessed player is used and nothing is downloaded")
    func warm() async throws {
        let (solver, _, directory) = makeSolver()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await solver.solve(request()) { "RAW" }
        let downloads = Downloads()
        let solutions = try await solver.solve(request(sig: ["A2"], n: ["B2"])) { downloads.bump(); return "RAW" }
        #expect(downloads.value == 0)
        #expect(solutions.sig == ["A2": "sig|preprocessed_player|A2"])
        #expect(solutions.n == ["B2": "n|preprocessed_player|B2"])
    }

    @Test("Warm across launches: a new solver with the same cache directory skips the download")
    func warmAcrossLaunches() async throws {
        let (first, _, directory) = makeSolver()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await first.solve(request()) { "RAW" }
        let (second, _, _) = makeSolver(directory: directory)
        let downloads = Downloads()
        let solutions = try await second.solve(request()) { downloads.bump(); return "RAW" }
        #expect(downloads.value == 0)
        #expect(solutions.n == ["B": "n|preprocessed_player|B"])
    }

    @Test("A different player hash is solved cold, not from another build's cache")
    func perHashCache() async throws {
        let (solver, cache, directory) = makeSolver()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await solver.solve(request("hash0001")) { "RAW1" }
        let downloads = Downloads()
        let solutions = try await solver.solve(request("hash0002")) { downloads.bump(); return "RAW2" }
        #expect(downloads.value == 1)
        #expect(solutions.n == ["B": "n|player|B"])
        #expect(cache.preprocessedPlayer(forHash: "hash0002") == "PRE:RAW2")
        #expect(cache.preprocessedPlayer(forHash: "hash0001") == "PRE:RAW1")
    }

    @Test("A corrupt cached player is dropped and the solve falls back to the raw player")
    func corruptCacheFallsBack() async throws {
        let (solver, cache, directory) = makeSolver()
        defer { try? FileManager.default.removeItem(at: directory) }
        cache.savePreprocessed("CORRUPT", forHash: "hash0001")
        let downloads = Downloads()
        let solutions = try await solver.solve(request()) { downloads.bump(); return "FRESH" }
        #expect(downloads.value == 1)
        #expect(solutions.n == ["B": "n|player|B"])
        #expect(cache.preprocessedPlayer(forHash: "hash0001") == "PRE:FRESH")
    }

    @Test("A request with nothing to solve touches neither the network nor the thread")
    func nothingToSolve() async throws {
        let (solver, _, directory) = makeSolver()
        defer { try? FileManager.default.removeItem(at: directory) }
        let downloads = Downloads()
        let solutions = try await solver.solve(request(sig: [], n: [])) { downloads.bump(); return "RAW" }
        #expect(solutions == ChallengeSolutions(sig: [:], n: [:]))
        #expect(downloads.value == 0)
    }

    @Test("A failed download is thrown as is and caches nothing")
    func downloadFailure() async throws {
        let (solver, cache, directory) = makeSolver()
        defer { try? FileManager.default.removeItem(at: directory) }
        await #expect(throws: MusicError.http(503)) {
            _ = try await solver.solve(self.request()) { throw MusicError.http(503) }
        }
        #expect(cache.preprocessedPlayer(forHash: "hash0001") == nil)
    }

    @Test("A solver error on a cold solve is thrown and caches nothing")
    func coldSolverError() async throws {
        let (solver, cache, directory) = makeSolver()
        defer { try? FileManager.default.removeItem(at: directory) }
        await #expect(throws: MusicError.self) {
            _ = try await solver.solve(self.request(sig: ["BOOM"], n: [])) { "RAW" }
        }
        #expect(cache.preprocessedPlayer(forHash: "hash0001") == nil)
    }

    @Test("Missing scripts surface as a solver error")
    func missingScripts() async throws {
        let cache = PlayerCache(directory: makeTemporaryDirectory("deci-solver"))
        defer { try? FileManager.default.removeItem(at: cache.directory) }
        let solver = JSChallengeSolver(cache: cache, scripts: { throw MusicError.solver("missing resource x.js") })
        await #expect(throws: MusicError.solver("missing resource x.js")) {
            _ = try await solver.solve(self.request()) { "RAW" }
        }
    }

    @Test("After the idle timeout the context is rebuilt and solving still works")
    func idleRebuild() async throws {
        let (solver, _, directory) = makeSolver(idleTimeout: 0.1)
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await solver.solve(request()) { "RAW" }
        try await Task.sleep(for: .milliseconds(500))
        let solutions = try await solver.solve(request(n: ["again"])) { Issue.record("should be warm"); return "RAW" }
        #expect(solutions.n == ["again": "n|preprocessed_player|again"])
    }

    @Test("Concurrent solves are all answered correctly")
    func concurrent() async throws {
        let (solver, _, directory) = makeSolver()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await solver.solve(request()) { "RAW" }
        try await withThrowingTaskGroup(of: Bool.self) { group in
            for index in 0..<20 {
                group.addTask {
                    let solutions = try await solver.solve(ChallengeRequest(playerHash: "hash0001", sigInputs: [], nInputs: ["n\(index)"])) { "RAW" }
                    return solutions.n == ["n\(index)": "n|preprocessed_player|n\(index)"]
                }
            }
            for try await ok in group { #expect(ok) }
        }
    }

    // MARK: Scripts and contexts across plays

    private nonisolated final class Loads: @unchecked Sendable {
        private let count = OSAllocatedUnfairLock(initialState: 0)
        var value: Int { count.withLock { $0 } }
        func bump() { count.withLock { $0 += 1 } }
    }

    @Test("A play soon after another reuses the context: one context, one read of the scripts")
    func contextReusedWithinIdleTimeout() async throws {
        let cache = PlayerCache(directory: makeTemporaryDirectory("deci-solver"))
        defer { try? FileManager.default.removeItem(at: cache.directory) }
        let loads = Loads()
        let solver = JSChallengeSolver(cache: cache, idleTimeout: 60, scripts: { loads.bump(); return FakeSolverScripts.scripts })
        _ = try await solver.solve(request()) { "RAW" }
        let second = try await solver.solve(request(n: ["again"])) { Issue.record("should be warm"); return "RAW" }
        #expect(second.n == ["again": "n|preprocessed_player|again"])
        #expect(solver.sessionsBuilt == 1)
        #expect(loads.value == 1)
    }

    @Test("The scripts are read once however many contexts the idle timeout makes the solver build")
    func scriptsReadOnce() async throws {
        let cache = PlayerCache(directory: makeTemporaryDirectory("deci-solver"))
        defer { try? FileManager.default.removeItem(at: cache.directory) }
        let loads = Loads()
        let solver = JSChallengeSolver(cache: cache, idleTimeout: 0.1, scripts: { loads.bump(); return FakeSolverScripts.scripts })
        let first = try await solver.solve(request()) { "RAW" }
        try await Task.sleep(for: .milliseconds(500))
        let second = try await solver.solve(request(n: ["again"])) { Issue.record("should be warm"); return "RAW" }
        try await Task.sleep(for: .milliseconds(500))
        let third = try await solver.solve(request(sig: ["S"], n: [])) { Issue.record("should be warm"); return "RAW" }
        // Three plays, three contexts (each one dropped while the song played), the scripts read from disk the once.
        #expect(solver.sessionsBuilt == 3)
        #expect(loads.value == 1)
        // The answers are the ones a fresh read gives.
        #expect(first.sig == ["A": "sig|player|A"] && first.n == ["B": "n|player|B"])
        #expect(second.n == ["again": "n|preprocessed_player|again"])
        #expect(third.sig == ["S": "sig|preprocessed_player|S"])
    }

    @Test("A failed read of the scripts is not remembered: the next play reads them again")
    func failedReadRetried() async throws {
        let cache = PlayerCache(directory: makeTemporaryDirectory("deci-solver"))
        defer { try? FileManager.default.removeItem(at: cache.directory) }
        let loads = Loads()
        let solver = JSChallengeSolver(cache: cache, idleTimeout: 60, scripts: {
            loads.bump()
            if loads.value == 1 { throw MusicError.solver("missing resource x.js") }
            return FakeSolverScripts.scripts
        })
        await #expect(throws: MusicError.solver("missing resource x.js")) {
            _ = try await solver.solve(self.request()) { "RAW" }
        }
        let solutions = try await solver.solve(request()) { "RAW" }
        #expect(solutions.n == ["B": "n|player|B"])
        #expect(loads.value == 2)
        #expect(solver.sessionsBuilt == 1)
    }

    @Test("The solver thread has the stack JavaScript recursion needs")
    func deepJavaScriptRecursion() async throws {
        let scripts = SolverScripts(meriyah: "", astring: "", helper: FakeSolverScripts.recursiveHelper)
        let (solver, _, directory) = makeSolver(scripts: scripts)
        defer { try? FileManager.default.removeItem(at: directory) }
        let solutions = try await solver.solve(request(sig: [], n: ["x"])) { "RAW" }
        #expect(solutions.n == ["x": "8000"])
    }
}

@Suite("SolverScriptsCache")
struct SolverScriptsCacheTests {
    private nonisolated final class Loads: @unchecked Sendable {
        private let count = OSAllocatedUnfairLock(initialState: 0)
        var value: Int { count.withLock { $0 } }
        func bump() { count.withLock { $0 += 1 } }
    }

    @Test("The first ask loads, every later ask hands back the same scripts without loading")
    func loadsOnce() throws {
        let loads = Loads()
        let cache = SolverScriptsCache { loads.bump(); return FakeSolverScripts.scripts }
        #expect(loads.value == 0)
        let first = try cache.scripts()
        let second = try cache.scripts()
        #expect(first == FakeSolverScripts.scripts)
        #expect(second == first)
        #expect(loads.value == 1)
    }

    @Test("A load that throws throws again and is tried again; one that then works is kept")
    func failureNotKept() throws {
        let loads = Loads()
        let cache = SolverScriptsCache {
            loads.bump()
            if loads.value < 3 { throw MusicError.solver("missing resource x.js") }
            return FakeSolverScripts.scripts
        }
        #expect(throws: MusicError.solver("missing resource x.js")) { _ = try cache.scripts() }
        #expect(throws: MusicError.solver("missing resource x.js")) { _ = try cache.scripts() }
        #expect(loads.value == 2)
        #expect(try cache.scripts() == FakeSolverScripts.scripts)
        #expect(try cache.scripts() == FakeSolverScripts.scripts)
        #expect(loads.value == 3)
    }

    @Test("Asks from many threads at once load once")
    func concurrentAsks() async throws {
        let loads = Loads()
        let cache = SolverScriptsCache { loads.bump(); return FakeSolverScripts.scripts }
        try await withThrowingTaskGroup(of: Bool.self) { group in
            for _ in 0..<16 {
                group.addTask { try cache.scripts() == FakeSolverScripts.scripts }
            }
            for try await same in group { #expect(same) }
        }
        #expect(loads.value == 1)
    }

    @Test("The bundled scripts come through the cache unchanged")
    func bundledThroughCache() throws {
        let direct = try SolverScripts.bundled()
        let cache = SolverScriptsCache { try SolverScripts.bundled() }
        #expect(try cache.scripts() == direct)
        #expect(try cache.scripts() == direct)
    }
}
