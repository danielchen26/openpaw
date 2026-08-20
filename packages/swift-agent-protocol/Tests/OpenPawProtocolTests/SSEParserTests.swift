import Foundation
import XCTest

@testable import OpenPawProtocol

final class SSEParserTests: XCTestCase {
    private func collect(_ chunks: [String]) async throws -> [ServerSentEvent] {
        var frames: [ServerSentEvent] = []
        for try await frame in SSE.frames(from: ByteStream(chunks: chunks)) {
            frames.append(frame)
        }
        return frames
    }

    func testMultiLineDataCommentsCRLFAndSplitChunkBoundaries() async throws {
        // A single stream exercising: a keep-alive comment, a multi-line `data:` payload,
        // CRLF terminators, a chunk boundary in the middle of an event, and a final event
        // with no trailing blank line.
        let frames = try await collect([
            ": keep-alive\r\n\r\n",
            "event: message\r\ndata: first\r\ndata: second\r\n",
            "\r\nid: 42\r\ndata: {\"a\":",
            "1}\r\nretry: 3000\r\n\r\n",
            ": another keep-alive\n\n",
            "data: tail-without-blank-line",
        ])

        XCTAssertEqual(frames.count, 3)

        XCTAssertEqual(frames[0].event, "message")
        XCTAssertEqual(frames[0].data, "first\nsecond", "data lines join with a newline")
        XCTAssertNil(frames[0].id)

        XCTAssertEqual(frames[1].data, #"{"a":1}"#, "an event split across chunks reassembles")
        XCTAssertEqual(frames[1].id, "42")
        XCTAssertEqual(frames[1].retry, 3000)
        XCTAssertNil(frames[1].event)

        XCTAssertEqual(frames[2].data, "tail-without-blank-line")
        XCTAssertEqual(frames[2].id, "42", "the last id persists across events per the SSE spec")
    }

    func testKeepAliveOnlyStreamDispatchesNothing() async throws {
        let frames = try await collect([": ping\n\n", ":\n\n", "\n\n"])
        XCTAssertTrue(frames.isEmpty)
    }

    func testBareLineFeedAndBareCarriageReturnBothTerminateLines() async throws {
        let lf = try await collect(["data: a\n\n"])
        let cr = try await collect(["data: a\r\r"])
        let crlf = try await collect(["data: a\r\n\r\n"])
        XCTAssertEqual(lf.map(\.data), ["a"])
        XCTAssertEqual(cr.map(\.data), ["a"])
        XCTAssertEqual(crlf.map(\.data), ["a"])
    }

    func testFieldWithoutValueAndFieldWithoutColon() async throws {
        // `data` alone is an empty data line; `data:` likewise; unknown fields are ignored.
        let frames = try await collect(["data\ndata:\nfoo: bar\ndata: x\n\n"])
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].data, "\n\nx")
    }

    func testOnlyOneLeadingSpaceIsStrippedFromAValue() async throws {
        let frames = try await collect(["data:  two spaces\n\n"])
        XCTAssertEqual(frames[0].data, " two spaces")
    }

    func testOneBytePerChunkStillParses() async throws {
        let text = "event: message\r\ndata: alpha\r\ndata: beta\r\n\r\n"
        let frames = try await collect(text.map(String.init))
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].data, "alpha\nbeta")
        XCTAssertEqual(frames[0].event, "message")
    }

    func testUTF8MultiByteSequenceSplitAcrossFeeds() {
        // "é" is two UTF-8 bytes; feed them in separate calls so the parser must hold a
        // partial scalar across chunk boundaries.
        let bytes = Array("data: caf\u{00E9}\n\n".utf8)
        var parser = SSEParser()
        var frames = parser.consume(bytes[0..<10])
        frames.append(contentsOf: parser.consume(bytes[10...]))
        frames.append(contentsOf: parser.finish())
        XCTAssertEqual(frames.map(\.data), ["café"])
    }

    // MARK: Event decoding

    private func eventJSON(seq: UInt64, type: String, payload: String) -> String {
        """
        {"version":"1","event_id":"evt_0123456789abcdef0123456\(seq)",\
        "session_id":"sess_cc-6f7b","agent":"claude-code","seq":\(seq),\
        "timestamp":"2026-08-20T14:30:00Z","cwd":null,"git_branch":null,\
        "multiplexer_target":null,"type":"\(type)","payload":\(payload)}
        """
    }

    func testEventStreamDecodesBacklogThenLiveFrames() async throws {
        let stream = [
            ": connected\n\n",
            "data: \(eventJSON(seq: 0, type: "agent.started", payload: "{}"))\n\n",
            "data: \(eventJSON(seq: 1, type: "turn.delta", payload: #"{"turn_id":"t","delta":"a","kind":"text"}"#))",
            "\n\n: keep-alive\n\ndata: ",
            "\(eventJSON(seq: 2, type: "agent.completed", payload: #"{"reason":"done"}"#))\n\n",
            "data: [DONE]\n\n",
        ]
        var events: [Event] = []
        for try await event in SSE.events(from: ByteStream(chunks: stream)) {
            events.append(event)
        }
        XCTAssertEqual(events.map(\.seq), [0, 1, 2])
        XCTAssertEqual(events.map { $0.body.typeName }, ["agent.started", "turn.delta", "agent.completed"])
        guard case .turnDelta(let delta) = events[1].body else {
            return XCTFail("expected .turnDelta")
        }
        XCTAssertEqual(delta.delta, "a")
    }

    func testMalformedFrameFailsTheStreamWithADecodingError() async throws {
        let stream = [
            "data: \(eventJSON(seq: 0, type: "agent.started", payload: "{}"))\n\n",
            "data: {\"not\":\"an event\"}\n\n",
        ]
        var events: [Event] = []
        do {
            for try await event in SSE.events(from: ByteStream(chunks: stream)) {
                events.append(event)
            }
            XCTFail("a malformed frame must surface as an error")
        } catch let error as HostClientError {
            guard case .decoding = error else {
                return XCTFail("expected .decoding, got \(error)")
            }
        }
        XCTAssertEqual(events.count, 1, "frames before the failure are still delivered")
    }
}
