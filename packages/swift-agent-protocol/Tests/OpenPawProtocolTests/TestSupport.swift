import Foundation
import XCTest

@testable import OpenPawProtocol

// MARK: - Repository layout

enum Repo {
    /// Walks up from this file until the directory holding `protocol/json-schema` is
    /// found. No SPM resource bundles are involved, so the same fixtures serve Rust.
    static let root: URL = {
        var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while url.path != "/" {
            let marker = url.appendingPathComponent("protocol/json-schema/event.schema.json")
            if FileManager.default.fileExists(atPath: marker.path) { return url }
            url = url.deletingLastPathComponent()
        }
        XCTFail("could not locate the repository root above \(#filePath)")
        return URL(fileURLWithPath: "/")
    }()

    static var normalizedFixtures: URL {
        root.appendingPathComponent("protocol/fixtures/normalized")
    }

    static func fixtureData(_ name: String) throws -> Data {
        try Data(contentsOf: root.appendingPathComponent("protocol/fixtures/\(name).json"))
    }

    /// Golden event files, empty until the `openpaw-agents` slice generates them.
    static func goldenEventFiles() -> [URL] {
        let files =
            (try? FileManager.default.contentsOfDirectory(
                at: normalizedFixtures, includingPropertiesForKeys: nil
            )) ?? []
        return files.filter { $0.lastPathComponent.hasSuffix(".events.json") }.sorted {
            $0.lastPathComponent < $1.lastPathComponent
        }
    }
}

func fixtureData(_ name: String) throws -> Data { try Repo.fixtureData(name) }

// MARK: - Semantic JSON comparison

extension JSONValue {
    /// Canonical form for semantic comparison: integers widen to doubles, `null` valued
    /// keys and empty arrays collapse away. Those three differences are exactly the ones
    /// the protocol declares as immaterial (`cwd` may be `null` or absent, optional
    /// arrays default to empty, `1` and `1.0` are the same number).
    var semanticForm: JSONValue {
        switch self {
        case .integer(let value):
            return .number(Double(value))
        case .array(let values):
            return .array(values.map(\.semanticForm))
        case .object(let values):
            var normalized: [String: JSONValue] = [:]
            normalized.reserveCapacity(values.count)
            for (key, value) in values {
                let form = value.semanticForm
                if form == .null { continue }
                if case .array(let items) = form, items.isEmpty { continue }
                normalized[key] = form
            }
            return .object(normalized)
        case .null, .bool, .number, .string:
            return self
        }
    }
}

func assertSemanticallyEqual(
    _ produced: Data,
    _ expected: Data,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    do {
        let lhs = try JSONValue(data: produced).semanticForm
        let rhs = try JSONValue(data: expected).semanticForm
        if lhs != rhs {
            XCTFail(
                """
                JSON values differ. \(message())
                produced: \(String(decoding: produced, as: UTF8.self))
                expected: \(String(decoding: expected, as: UTF8.self))
                """,
                file: file,
                line: line
            )
        }
    } catch {
        XCTFail("could not parse JSON for comparison: \(error). \(message())", file: file, line: line)
    }
}

/// Decodes an event from a JSON literal, re-encodes it, and asserts the two are
/// semantically identical.
func assertEventRoundTrips(
    _ json: String,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    let data = Data(json.utf8)
    let event = try OpenPawCoding.decoder.decode(Event.self, from: data)
    let reencoded = try OpenPawCoding.encoder.encode(event)
    assertSemanticallyEqual(reencoded, data, "type \(event.body.typeName)", file: file, line: line)
}

// MARK: - Stub byte stream

/// An `AsyncSequence` of `UInt8` fed from fixed chunks, so the SSE parser can be tested
/// without a socket. Chunk boundaries are preserved, which is how a real connection
/// splits an event in half.
struct ByteStream: AsyncSequence, Sendable {
    typealias Element = UInt8

    let chunks: [[UInt8]]

    init(chunks: [String]) {
        self.chunks = chunks.map { Array($0.utf8) }
    }

    init(text: String) {
        self.init(chunks: [text])
    }

    struct Iterator: AsyncIteratorProtocol {
        var chunks: [[UInt8]]
        var chunkIndex = 0
        var byteIndex = 0

        mutating func next() async -> UInt8? {
            while chunkIndex < chunks.count {
                if byteIndex < chunks[chunkIndex].count {
                    let byte = chunks[chunkIndex][byteIndex]
                    byteIndex += 1
                    return byte
                }
                chunkIndex += 1
                byteIndex = 0
                // Yield between chunks so interleaving matches a real stream.
                await Task.yield()
            }
            return nil
        }
    }

    func makeAsyncIterator() -> Iterator {
        Iterator(chunks: chunks)
    }
}
