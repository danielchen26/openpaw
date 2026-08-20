import Foundation

/// JSON coders configured for the OpenPaw wire format.
///
/// Timestamps are RFC 3339 with a `Z` designator. Fractional seconds are optional on
/// input (both `2026-08-20T14:30:00Z` and `2026-08-20T14:30:00.000Z` decode) and are
/// emitted on output only when the instant actually carries sub-second precision.
///
/// Each property returns a fresh instance: `JSONDecoder` and `JSONEncoder` are classes,
/// so handing out a shared one would be a data race across tasks.
public enum OpenPawCoding {
    /// Wire protocol version this build speaks.
    public static let version = "1"

    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom(decodeRFC3339)
        return decoder
    }

    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom(encodeRFC3339)
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }

    /// Encoder for diagnostics screens and golden-style output: indented, keys sorted.
    public static var prettyEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom(encodeRFC3339)
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

// MARK: - RFC 3339

/// RFC 3339 parsing and formatting that does not rely on non-`Sendable` formatters.
public enum RFC3339 {
    private static let whole = Date.ISO8601FormatStyle(
        dateSeparator: .dash,
        dateTimeSeparator: .standard,
        timeSeparator: .colon,
        timeZoneSeparator: .omitted,
        includingFractionalSeconds: false,
        timeZone: .gmt
    )

    private static let fractional = Date.ISO8601FormatStyle(
        dateSeparator: .dash,
        dateTimeSeparator: .standard,
        timeSeparator: .colon,
        timeZoneSeparator: .omitted,
        includingFractionalSeconds: true,
        timeZone: .gmt
    )

    /// Parses an RFC 3339 timestamp with or without fractional seconds, with either a
    /// `Z` designator or a numeric UTC offset.
    public static func date(from text: String) -> Date? {
        if let date = try? Date(text, strategy: whole.parseStrategy) { return date }
        if let date = try? Date(text, strategy: fractional.parseStrategy) { return date }
        // Numeric offsets (`+02:00`) are legal RFC 3339 but not accepted by the `Z`
        // styles above; normalize them to UTC first.
        guard let normalized = normalizingNumericOffset(text) else { return nil }
        if let date = try? Date(normalized, strategy: whole.parseStrategy) { return date }
        return try? Date(normalized, strategy: fractional.parseStrategy)
    }

    /// Formats an instant as RFC 3339 in UTC, including sub-second precision only when the
    /// instant is not on a whole second.
    ///
    /// Rust's `time` crate emits the sub-second field with trailing zeros trimmed (`.5Z`,
    /// not `.500Z`); client bytes must equal host bytes. The millisecond count is derived
    /// arithmetically rather than through the formatter's fractional style, which
    /// truncates values such as `.001` that a `Double` cannot hold exactly.
    public static func string(from date: Date) -> String {
        let totalMilliseconds = (date.timeIntervalSince1970 * 1000).rounded()
        let wholeSeconds = (totalMilliseconds / 1000).rounded(.down)
        let milliseconds = Int(totalMilliseconds - wholeSeconds * 1000)
        let base = Date(timeIntervalSince1970: wholeSeconds).formatted(whole)
        guard milliseconds != 0, base.hasSuffix("Z") else { return base }

        var fraction = String(milliseconds)
        while fraction.count < 3 { fraction = "0" + fraction }
        while fraction.hasSuffix("0") { fraction.removeLast() }
        return base.dropLast() + "." + fraction + "Z"
    }

    private static func normalizingNumericOffset(_ text: String) -> String? {
        // Trailing `+HH:MM` / `-HH:MM`.
        guard text.count >= 6 else { return nil }
        var characters = Array(text.suffix(6))
        let base = String(text.dropLast(6))
        guard characters.count == 6, characters[3] == ":" else { return nil }
        let sign: Double
        switch characters[0] {
        case "+": sign = 1
        case "-": sign = -1
        default: return nil
        }
        characters.remove(at: 3)
        guard let hours = Int(String(characters[1...2])), let minutes = Int(String(characters[3...4]))
        else { return nil }
        guard let naive = date(from: base + "Z") else { return nil }
        return string(from: naive.addingTimeInterval(-sign * Double(hours * 3600 + minutes * 60)))
    }
}

@Sendable
private func decodeRFC3339(_ decoder: any Decoder) throws -> Date {
    let container = try decoder.singleValueContainer()
    let raw = try container.decode(String.self)
    guard let date = RFC3339.date(from: raw) else {
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "'\(raw)' is not an RFC 3339 timestamp"
        )
    }
    return date
}

@Sendable
private func encodeRFC3339(_ date: Date, _ encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(RFC3339.string(from: date))
}
