import Foundation

/// One dispatched `text/event-stream` frame.
public struct ServerSentEvent: Sendable, Hashable {
    public var event: String?
    public var id: String?
    public var retry: Int?
    /// `data:` field values joined with newlines, as required by the SSE spec.
    public var data: String

    public init(event: String? = nil, id: String? = nil, retry: Int? = nil, data: String) {
        self.event = event
        self.id = id
        self.retry = retry
        self.data = data
    }
}

/// Incremental `text/event-stream` parser.
///
/// Handles multi-line `data:` payloads, `:` keep-alive comments, `field` lines without a
/// value, blank-line dispatch, and LF / CRLF / bare-CR terminators. Bytes may be fed in
/// arbitrarily sized chunks, including chunks that split a line or an event in half.
public struct SSEParser: Sendable {
    private var lineBytes: [UInt8] = []
    private var dataLines: [String] = []
    private var eventName: String?
    private var lastEventID: String?
    private var retry: Int?
    private var skipNextLineFeed = false

    public init() {}

    /// Feeds one byte and returns the event it completed, if any.
    public mutating func consume(_ byte: UInt8) -> ServerSentEvent? {
        switch byte {
        case 0x0A:  // LF
            if skipNextLineFeed {
                skipNextLineFeed = false
                return nil
            }
            return endLine()
        case 0x0D:  // CR, possibly the first half of CRLF
            skipNextLineFeed = true
            return endLine()
        default:
            skipNextLineFeed = false
            lineBytes.append(byte)
            return nil
        }
    }

    /// Feeds a chunk and returns every event completed by it.
    public mutating func consume(_ bytes: some Sequence<UInt8>) -> [ServerSentEvent] {
        var dispatched: [ServerSentEvent] = []
        for byte in bytes {
            if let event = consume(byte) { dispatched.append(event) }
        }
        return dispatched
    }

    /// Dispatches whatever a truncated final line and pending fields amount to.
    /// A stream that ends without a trailing blank line still yields its last event.
    public mutating func finish() -> [ServerSentEvent] {
        var dispatched: [ServerSentEvent] = []
        if !lineBytes.isEmpty, let event = endLine() {
            dispatched.append(event)
        }
        if let event = dispatch() {
            dispatched.append(event)
        }
        return dispatched
    }

    private mutating func endLine() -> ServerSentEvent? {
        let line = String(decoding: lineBytes, as: UTF8.self)
        lineBytes.removeAll(keepingCapacity: true)

        if line.isEmpty {
            return dispatch()
        }
        if line.hasPrefix(":") {
            // Keep-alive comment.
            return nil
        }

        let field: String
        var value: String
        if let colon = line.firstIndex(of: ":") {
            field = String(line[line.startIndex..<colon])
            value = String(line[line.index(after: colon)...])
            if value.hasPrefix(" ") { value.removeFirst() }
        } else {
            field = line
            value = ""
        }

        switch field {
        case "event": eventName = value
        case "data": dataLines.append(value)
        case "id": lastEventID = value
        case "retry": retry = Int(value)
        default: break  // Unknown fields are ignored per the SSE spec.
        }
        return nil
    }

    private mutating func dispatch() -> ServerSentEvent? {
        defer {
            dataLines.removeAll(keepingCapacity: true)
            eventName = nil
            retry = nil
        }
        guard !dataLines.isEmpty else { return nil }
        return ServerSentEvent(
            event: eventName,
            id: lastEventID,
            retry: retry,
            data: dataLines.joined(separator: "\n")
        )
    }
}

// MARK: - Streams

public enum SSE {
    /// Parses a byte stream into SSE frames.
    public static func frames<Bytes: AsyncSequence & Sendable>(
        from bytes: Bytes
    ) -> AsyncThrowingStream<ServerSentEvent, any Error> where Bytes.Element == UInt8 {
        AsyncThrowingStream { continuation in
            let task = Task {
                var parser = SSEParser()
                do {
                    for try await byte in bytes {
                        if let frame = parser.consume(byte) {
                            continuation.yield(frame)
                        }
                    }
                    for frame in parser.finish() {
                        continuation.yield(frame)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Parses a byte stream into normalized events, ignoring frames whose `data` is the
    /// `[DONE]` sentinel or an SSE comment-only keep-alive.
    public static func events<Bytes: AsyncSequence & Sendable>(
        from bytes: Bytes
    ) -> AsyncThrowingStream<Event, any Error> where Bytes.Element == UInt8 {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await frame in frames(from: bytes) {
                        let trimmed = frame.data.trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmed.isEmpty || trimmed == "[DONE]" { continue }
                        do {
                            let event = try OpenPawCoding.decoder.decode(
                                Event.self, from: Data(frame.data.utf8)
                            )
                            continuation.yield(event)
                        } catch {
                            continuation.finish(throwing: HostClientError.decoding(error))
                            return
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
