import CryptoKit
import Foundation

/// Signs requests for the host's authenticated routes.
///
/// Every non-public route requires both the bearer token (authentication) and an
/// HMAC-SHA256 signature over the canonical string (request binding), so a leaked token
/// alone cannot be replayed against a different path or body.
public struct RequestSigner: Sendable, Hashable {
    /// Header names, matching `protocol/capability-spec/capabilities.json`.
    public enum Header {
        public static let authorization = "Authorization"
        public static let device = "X-OpenPaw-Device"
        public static let timestamp = "X-OpenPaw-Timestamp"
        public static let nonce = "X-OpenPaw-Nonce"
        public static let signature = "X-OpenPaw-Signature"
    }

    public let deviceID: String
    public let token: String
    public let hmacKey: Data

    public init(deviceID: String, token: String, hmacKey: Data) {
        self.deviceID = deviceID
        self.token = token
        self.hmacKey = hmacKey
    }

    /// Builds a signer from the base64 key the host returns from `POST /v1/pair`.
    public init?(deviceID: String, token: String, hmacKeyBase64: String) {
        guard let key = Data(base64Encoded: hmacKeyBase64) else { return nil }
        self.init(deviceID: deviceID, token: token, hmacKey: key)
    }

    /// `METHOD\nPATH_WITH_QUERY\nTIMESTAMP\nNONCE\nSHA256_HEX(BODY)`
    public static func canonicalString(
        method: String, pathAndQuery: String, timestamp: Int64, nonce: String, body: Data
    ) -> String {
        [
            method.uppercased(),
            pathAndQuery,
            String(timestamp),
            nonce,
            Hashing.sha256Hex(body),
        ].joined(separator: "\n")
    }

    /// Lowercase hex HMAC-SHA256 of `canonical` under `key`.
    public static func sign(key: Data, canonical: String) -> String {
        let code = HMAC<SHA256>.authenticationCode(
            for: Data(canonical.utf8), using: SymmetricKey(data: key)
        )
        return Hashing.hex(code)
    }

    /// Constant time comparison of a received signature against the expected one.
    public static func verify(key: Data, canonical: String, signature: String) -> Bool {
        let expected = sign(key: key, canonical: canonical)
        let lhs = Array(expected.utf8)
        let rhs = Array(signature.lowercased().utf8)
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in lhs.indices {
            difference |= lhs[index] ^ rhs[index]
        }
        return difference == 0
    }

    public func signature(
        method: String, pathAndQuery: String, timestamp: Int64, nonce: String, body: Data
    ) -> String {
        Self.sign(
            key: hmacKey,
            canonical: Self.canonicalString(
                method: method,
                pathAndQuery: pathAndQuery,
                timestamp: timestamp,
                nonce: nonce,
                body: body
            )
        )
    }

    /// All headers a signed request must carry.
    public func headers(
        method: String,
        pathAndQuery: String,
        body: Data,
        date: Date = Date(),
        nonce: String = RequestSigner.randomNonce()
    ) -> [String: String] {
        let timestamp = Int64(date.timeIntervalSince1970.rounded(.down))
        return [
            Header.authorization: "Bearer \(token)",
            Header.device: deviceID,
            Header.timestamp: String(timestamp),
            Header.nonce: nonce,
            Header.signature: signature(
                method: method,
                pathAndQuery: pathAndQuery,
                timestamp: timestamp,
                nonce: nonce,
                body: body
            ),
        ]
    }

    /// 16 random bytes, hex encoded. The host caches nonces for 600 seconds.
    public static func randomNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: UInt8.min...UInt8.max)
        }
        return Hashing.hex(bytes)
    }
}
