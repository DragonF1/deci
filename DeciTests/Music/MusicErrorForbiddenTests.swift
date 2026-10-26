// DeciTests/Music/MusicErrorForbiddenTests.swift
// `MusicError.forbidden`, the error for an HTTP 403 from an InnerTube call: the lines it shows and logs, and that every
// place which sorted the old `.http(403)` (paging, rate limits, the log kind) sorts it the same way.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("MusicError forbidden")
struct MusicErrorForbiddenTests {

    // MARK: - Lines

    @Test("The shown line is neutral and keeps the number, since a read can be refused too")
    func message() {
        let line = MusicService.message(for: MusicError.forbidden)
        #expect(line == "YouTube Music refused that request (403).")
        #expect(!line.contains("channel"))
    }

    @Test("A plain 403 from elsewhere keeps the status line, and the other statuses keep theirs")
    func httpMessagesUnchanged() {
        #expect(MusicService.message(for: MusicError.http(403)) == "YouTube Music returned an error (403).")
        #expect(MusicService.message(for: MusicError.http(500)) == "YouTube Music returned an error (500).")
        #expect(MusicService.message(for: MusicError.signedOut) == "Signed out. Sign in again.")
        #expect(MusicService.message(for: MusicError.rejected) == "YouTube Music didn't accept that. Try again.")
    }

    @Test("The log line is the kind alone, and the plain 403 keeps its own")
    func logDescription() {
        #expect(MusicService.logDescription(of: MusicError.forbidden) == "forbidden")
        #expect(MusicService.logDescription(of: MusicError.http(403)) == "http 403")
        #expect(MusicService.logDescription(of: MusicError.http(500)) == "http 500")
    }

    // MARK: - Identity

    @Test("Forbidden is its own error, equal only to itself, and carries the status 403")
    func identity() {
        #expect(MusicError.forbidden == MusicError.forbidden)
        #expect(MusicError.forbidden != MusicError.http(403))
        #expect(MusicError.forbidden != MusicError.signedOut)
        #expect(MusicError.forbidden.httpStatus == 403)
        #expect(MusicError.http(403).httpStatus == 403)
        #expect(MusicError.http(0).httpStatus == 0)
        let others: [MusicError] = [.signedOut, .parse("x"), .unplayable("x"), .noAudioFormat, .solver("x"), .rejected]
        for error in others {
            #expect(error.httpStatus == nil, "\(error)")
        }
    }

    // MARK: - Classification parity with .http(403)

    @Test("Forbidden ends a queue page's paging, as a 4xx other than 408 and 429 does")
    func endsPaging() {
        #expect(MusicError.endsPaging(MusicError.forbidden))
        #expect(MusicError.endsPaging(MusicError.forbidden) == MusicError.endsPaging(MusicError.http(403)))
    }

    @Test("Forbidden is not a rate limit, as a 403 is not")
    func rateLimit() {
        #expect(MusicDownloadService.isRateLimited(MusicError.forbidden) == false)
        #expect(MusicDownloadService.isRateLimited(MusicError.forbidden) == MusicDownloadService.isRateLimited(MusicError.http(403)))
        // The statuses that are one keep being one.
        #expect(MusicDownloadService.isRateLimited(MusicError.http(429)))
        #expect(MusicDownloadService.isRateLimited(MusicError.http(503)))
        #expect(MusicDownloadService.isRateLimited(MusicError.http(404)) == false)
    }

    @Test("The log kind of a forbidden answer is the one of a 403")
    func logKind() {
        #expect(InnerTubeClient.logKind(of: MusicError.forbidden) == "http 403")
        #expect(InnerTubeClient.logKind(of: MusicError.http(403)) == "http 403")
        #expect(InnerTubeClient.logKind(of: MusicError.http(404)) == "http 404")
        #expect(InnerTubeClient.logKind(of: MusicError.parse("x")) == "parse")
        #expect(InnerTubeClient.logKind(of: MusicError.rejected) == "other")
        #expect(InnerTubeClient.logKind(of: URLError(.timedOut)) == "other")
    }
}
