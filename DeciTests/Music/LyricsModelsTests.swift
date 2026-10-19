// DeciTests/Music/LyricsModelsTests.swift
// The small shared types of the lyrics seam: an answer is a result with the credit that goes with it, a provider that
// only knows the older one-method seam still works, and "a known length" means one that is finite and above zero.

import Foundation
import Testing
@testable import Deci

@Suite("Lyrics models")
struct LyricsModelsTests {

    @Test("An answer built with a result and a credit is worth redoing for a length, like a guess")
    func answerDefaults() {
        let answer = LyricsAnswer(result: .plain("First test line"), credit: "Lyrics from LRCLIB")
        #expect(answer.result == .plain("First test line"))
        #expect(answer.credit == "Lyrics from LRCLIB")
        #expect(answer.lengthMatters == true)
    }

    @Test("Answers are equal when the result, the credit and the length flag are")
    func answerEquality() {
        let base = LyricsAnswer(result: .notFound, credit: nil, lengthMatters: false)
        #expect(base == LyricsAnswer(result: .notFound, credit: nil, lengthMatters: false))
        #expect(base != LyricsAnswer(result: .instrumental, credit: nil, lengthMatters: false))
        #expect(base != LyricsAnswer(result: .notFound, credit: "Lyrics from LRCLIB", lengthMatters: false))
        #expect(base != LyricsAnswer(result: .notFound, credit: nil, lengthMatters: true))
    }

    @Test("A provider that only has lyrics(for:) answers with its result, no credit and a length that matters", arguments: [
        LyricsResult.synced(LyricsSamples.syncedLines), .plain(LyricsSamples.plain), .instrumental, .notFound,
    ])
    func defaultAnswer(result: LyricsResult) async throws {
        let provider = ResultOnlyProvider(result: result)
        let answer = try await provider.answer(for: LyricsSamples.query())
        #expect(answer == LyricsAnswer(result: result, credit: nil, lengthMatters: true))
    }

    @Test("The default answer throws what lyrics(for:) throws")
    func defaultAnswerThrows() async {
        struct Failing: LyricsProviding {
            func lyrics(for query: LyricsQuery) async throws -> LyricsResult { throw LyricsError.http(418) }
        }
        await #expect(throws: LyricsError.http(418)) { try await Failing().answer(for: LyricsSamples.query()) }
    }

    @Test("The no-op provider answers not found, with no credit, and never fails")
    func noLyricsAnswer() async throws {
        let answer = try await NoLyricsProvider().answer(for: LyricsSamples.query())
        #expect(answer.result == .notFound)
        #expect(answer.credit == nil)
    }

    @Test("A known length is finite and above zero", arguments: [
        (nil, nil), (0, nil), (-3, nil), (Double.nan, nil), (Double.infinity, nil), (-Double.infinity, nil),
        (0.5, 0.5), (213.4, 213.4), (200, 200),
    ] as [(TimeInterval?, TimeInterval?)])
    func knownDuration(duration: TimeInterval?, expected: TimeInterval?) {
        #expect(LyricsSamples.query(duration: duration).knownDuration == expected)
    }
}
