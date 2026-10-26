// DeciTests/Music/InnerTubeParserAPIErrorTests.swift
// What the parser keeps of a Google API error body for the log: the status word and the first reason, each only when it
// is a short plain token, and never the message. Every body here is hand-made in the shape of Google's error JSON.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("InnerTubeParser API error summary")
struct InnerTubeParserAPIErrorTests {

    private func summary(_ json: String) -> InnerTubeParser.APIErrorSummary {
        InnerTubeParser.apiErrorSummary(from: Data(json.utf8))
    }

    private func body(status: String? = nil, reasons: [String] = []) -> String {
        var fields: [String] = []
        if let status { fields.append(#""status":\#(status)"#) }
        if !reasons.isEmpty { fields.append(#""errors":[\#(reasons.map { #"{"reason":\#($0)}"# }.joined(separator: ","))]"#) }
        return #"{"error":{\#(fields.joined(separator: ","))}}"#
    }

    // MARK: - What is kept

    @Test("A full error body gives its status and its first reason")
    func fullBody() {
        let json = #"""
        {"error":{"code":403,"message":"The caller does not have permission","errors":[{"message":"Forbidden","domain":"global","reason":"forbidden"},{"reason":"second"}],"status":"PERMISSION_DENIED"}}
        """#
        #expect(summary(json) == .init(status: "PERMISSION_DENIED", reason: "forbidden"))
    }

    @Test("Only the status is kept when there are no errors, and only the reason when there is no status")
    func partialBodies() {
        #expect(summary(body(status: #""UNAUTHENTICATED""#)) == .init(status: "UNAUTHENTICATED", reason: nil))
        #expect(summary(body(reasons: [#""authError""#])) == .init(status: nil, reason: "authError"))
    }

    @Test("The reason is the first one that is given, from an entry that has one")
    func firstReasonGiven() {
        let json = #"{"error":{"errors":[{"message":"no reason here"},{"reason":"forbidden"},{"reason":"later"}]}}"#
        #expect(summary(json) == .init(status: nil, reason: "forbidden"))
    }

    @Test("A first reason that is not a plain token is dropped, and a later one does not stand in for it")
    func oddFirstReasonIsNotReplaced() {
        let json = #"{"error":{"errors":[{"reason":"not a token"},{"reason":"forbidden"}],"status":"PERMISSION_DENIED"}}"#
        #expect(summary(json) == .init(status: "PERMISSION_DENIED", reason: nil))
    }

    @Test("The message and everything else in the body are never part of the summary")
    func messageIsNeverKept() {
        let json = #"""
        {"error":{"code":403,"message":"secret-text for user@example.com","errors":[{"message":"secret-detail","domain":"secret-domain","reason":"forbidden","extendedHelp":"https://example.com/secret"}],"status":"PERMISSION_DENIED","details":[{"@type":"secret-type"}]}}
        """#
        let result = summary(json)
        #expect(result == .init(status: "PERMISSION_DENIED", reason: "forbidden"))
        #expect(!"\(result)".contains("secret"))
    }

    // MARK: - Missing fields

    @Test("A body with no error object, or no usable fields in it, gives nothing")
    func missingFields() {
        let none = InnerTubeParser.APIErrorSummary(status: nil, reason: nil)
        let bodies = [
            "{}",
            #"{"error":{}}"#,
            #"{"error":null}"#,
            #"{"error":"PERMISSION_DENIED"}"#,
            #"{"error":["PERMISSION_DENIED"]}"#,
            #"{"error":{"errors":[]}}"#,
            #"{"error":{"errors":{}}}"#,
            #"{"error":{"errors":"forbidden"}}"#,
            #"{"error":{"errors":["forbidden"]}}"#,
            #"{"error":{"errors":[null,1,[]]}}"#,
            #"{"error":{"errors":[{"reason":""}],"status":""}}"#,
            #"{"status":"PERMISSION_DENIED"}"#,
            #"{"errors":[{"reason":"forbidden"}]}"#,
        ]
        for json in bodies {
            #expect(summary(json) == none, "body \(json)")
        }
    }

    @Test("A status or reason that is not a string gives nothing")
    func nonStringFields() {
        let none = InnerTubeParser.APIErrorSummary(status: nil, reason: nil)
        let bodies = [
            #"{"error":{"status":403,"errors":[{"reason":403}]}}"#,
            #"{"error":{"status":true,"errors":[{"reason":false}]}}"#,
            #"{"error":{"status":{"a":"b"},"errors":[{"reason":["forbidden"]}]}}"#,
            #"{"error":{"status":null,"errors":[{"reason":null}]}}"#,
        ]
        for json in bodies {
            #expect(summary(json) == none, "body \(json)")
        }
    }

    // MARK: - Garbage

    @Test("A body that is not a JSON object gives nothing and does not trap")
    func garbage() {
        let none = InnerTubeParser.APIErrorSummary(status: nil, reason: nil)
        let texts = ["", "   ", "<html>blocked</html>", "null", "[]", #"["error"]"#, "42", #""error""#, "{", #"{"error":"#, "}{", "\u{0}"]
        for text in texts {
            #expect(summary(text) == none, "text \(text.debugDescription)")
        }
        #expect(InnerTubeParser.apiErrorSummary(from: Data()) == none)
        #expect(InnerTubeParser.apiErrorSummary(from: Data([0xFF, 0xFE, 0x00, 0x80])) == none)
        #expect(InnerTubeParser.apiErrorSummary(from: Data(repeating: 0x7B, count: 5_000)) == none)
    }

    // MARK: - Tokens

    @Test("A token of exactly 40 characters is kept, one of 41 is dropped")
    func tokenLength() {
        let kept = String(repeating: "A", count: 40)
        let dropped = String(repeating: "A", count: 41)
        #expect(summary(body(status: #""\#(kept)""#, reasons: [#""\#(kept)""#])) == .init(status: kept, reason: kept))
        #expect(summary(body(status: #""\#(dropped)""#, reasons: [#""\#(dropped)""#])) == .init(status: nil, reason: nil))
    }

    @Test("Letters, digits and underscores are a token")
    func plainTokens() {
        for token in ["PERMISSION_DENIED", "forbidden", "rateLimitExceeded", "a", "_", "A1_b2", "9", "0123456789"] {
            #expect(summary(body(status: #""\#(token)""#)).status == token, "token \(token)")
        }
    }

    @Test("A value with anything else in it is not a token")
    func oddTokens() {
        let odd = [
            "PERMISSION DENIED", " forbidden", "forbidden ", "forbidden\\n", "a-b", "a.b", "a/b", "a:b", "a,b", "a=b", "a%20b",
            "<script>", "x'; DROP TABLE t;--", "user@example.com", "https://example.com", "caf\u{00E9}", "\u{1F600}",
            "\u{FF21}\u{FF22}", "\u{0661}\u{0662}", "tab\\there", "nul\\u0000",
        ]
        for token in odd {
            let json = body(status: #""\#(token)""#, reasons: [#""\#(token)""#])
            #expect(summary(json) == .init(status: nil, reason: nil), "token \(token)")
        }
    }

    @Test("A token that is dropped does not take the other one with it")
    func tokensAreIndependent() {
        let tooLong = String(repeating: "x", count: 80)
        #expect(summary(body(status: #""\#(tooLong)""#, reasons: [#""forbidden""#])) == .init(status: nil, reason: "forbidden"))
        #expect(summary(body(status: #""PERMISSION_DENIED""#, reasons: [#""odd reason""#])) == .init(status: "PERMISSION_DENIED", reason: nil))
    }

    // MARK: - Size

    @Test("A body with a thousand error entries, under the size limit, still gives the first reason")
    func largeBody() {
        let entries = (0..<1_000).map { #"{"message":"m\#($0)","reason":"r\#($0)"}"# }.joined(separator: ",")
        let json = #"{"error":{"errors":[\#(entries)],"status":"PERMISSION_DENIED"}}"#
        #expect(json.utf8.count < 64 * 1024)
        #expect(summary(json) == .init(status: "PERMISSION_DENIED", reason: "r0"))
    }

    @Test("A body of exactly 64 KB is read, and one byte more gives nothing")
    func sizeLimit() {
        let head = #"{"error":{"status":"PERMISSION_DENIED","errors":[{"reason":"forbidden","message":""#
        let tail = #""}]}}"#
        let limit = 64 * 1024
        let fill = limit - head.utf8.count - tail.utf8.count
        let atLimit = head + String(repeating: "a", count: fill) + tail
        #expect(atLimit.utf8.count == limit)
        #expect(summary(atLimit) == .init(status: "PERMISSION_DENIED", reason: "forbidden"))

        let over = head + String(repeating: "a", count: fill + 1) + tail
        #expect(over.utf8.count == limit + 1)
        #expect(summary(over) == .init(status: nil, reason: nil))
    }

    @Test("A body of several megabytes gives nothing")
    func hugeBody() {
        let filler = String(repeating: "a", count: 3_000_000)
        let json = #"{"error":{"status":"PERMISSION_DENIED","message":"\#(filler)"}}"#
        #expect(summary(json) == .init(status: nil, reason: nil))
    }
}
