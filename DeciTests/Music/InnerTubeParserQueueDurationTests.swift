// DeciTests/Music/InnerTubeParserQueueDurationTests.swift
// The lengths read out of a music/get_queue answer, in both renderer shapes.

import Foundation
import Testing
@testable import Deci

@Suite("InnerTubeParser queue durations")
struct InnerTubeParserQueueDurationTests {
    private let answer = """
    {"queueDatas":[
      {"content":{"playlistPanelVideoRenderer":{"videoId":"aaa","lengthText":{"runs":[{"text":"3:05"}]}}}},
      {"content":{"playlistPanelVideoWrapperRenderer":{"primaryRenderer":{"playlistPanelVideoRenderer":
        {"videoId":"bbb","lengthText":{"runs":[{"text":"1:02:03"}]}}}}}},
      {"content":{"playlistPanelVideoRenderer":{"videoId":"ccc"}}},
      {"content":{"playlistPanelVideoRenderer":{"lengthText":{"runs":[{"text":"2:00"}]}}}},
      {"content":{"somethingElse":{}}}
    ]}
    """

    @Test("both renderer shapes give seconds by id, and rows without an id or a length are skipped")
    func readsBothShapes() throws {
        let lengths = try InnerTubeParser.queueDurations(from: Data(answer.utf8))
        #expect(lengths == ["aaa": 185, "bbb": 3723])
    }

    @Test("an answer with no queue data is an empty map, and one that is not JSON throws")
    func emptyAndInvalid() throws {
        #expect(try InnerTubeParser.queueDurations(from: Data("{}".utf8)).isEmpty)
        #expect(throws: MusicError.self) { try InnerTubeParser.queueDurations(from: Data("nope".utf8)) }
    }
}
