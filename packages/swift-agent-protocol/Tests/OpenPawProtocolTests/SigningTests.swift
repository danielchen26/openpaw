import CryptoKit
import Foundation
import XCTest

@testable import OpenPawProtocol

final class SigningTests: XCTestCase {
    /// Fixed vector from the protocol contract.
    private static let key = Data((1...32).map { UInt8($0) })
    private static let deviceID = "dev_1"
    private static let token = "tok_secret"
    private static let timestamp: Int64 = 1_787_245_200
    private static let nonce = "n1"

    /// `sha256("")`, the body hash for every GET.
    private static let emptyBodyHash =
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    /// HMAC-SHA256 of the canonical string below under `key`, recorded after computing
    /// it from the specification (see `testSignatureMatchesAnIndependentComputation`).
    private static let expectedSignature =
        "4902019ac151ffb8063b1b2b447ffb019bb265a6bf230e8e7f297247c2a9637b"

    private var signer: RequestSigner {
        RequestSigner(deviceID: Self.deviceID, token: Self.token, hmacKey: Self.key)
    }

    func testCanonicalStringIsExactlyAsSpecified() {
        let canonical = RequestSigner.canonicalString(
            method: "GET",
            pathAndQuery: "/v1/sessions",
            timestamp: Self.timestamp,
            nonce: Self.nonce,
            body: Data()
        )
        XCTAssertEqual(canonical, "GET\n/v1/sessions\n1787245200\nn1\n\(Self.emptyBodyHash)")
        XCTAssertEqual(canonical.split(separator: "\n", omittingEmptySubsequences: false).count, 5)
        XCTAssertEqual(Hashing.sha256Hex(Data()), Self.emptyBodyHash)
    }

    func testSignatureMatchesAnIndependentComputation() {
        // Recompute the vector straight from the spec rather than trusting the type.
        let bodyHash = SHA256.hash(data: Data()).map { String(format: "%02x", $0) }.joined()
        let canonical = ["GET", "/v1/sessions", "1787245200", "n1", bodyHash].joined(separator: "\n")
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data(canonical.utf8), using: SymmetricKey(data: Self.key)
        )
        let independent = mac.map { String(format: "%02x", $0) }.joined()

        XCTAssertEqual(independent, Self.expectedSignature)
        XCTAssertEqual(
            signer.signature(
                method: "GET",
                pathAndQuery: "/v1/sessions",
                timestamp: Self.timestamp,
                nonce: Self.nonce,
                body: Data()
            ),
            Self.expectedSignature
        )
        XCTAssertEqual(RequestSigner.sign(key: Self.key, canonical: canonical), Self.expectedSignature)
    }

    func testHeadersCarryTheContractHeaderNamesAndValues() {
        let headers = signer.headers(
            method: "GET",
            pathAndQuery: "/v1/sessions",
            body: Data(),
            date: Date(timeIntervalSince1970: TimeInterval(Self.timestamp)),
            nonce: Self.nonce
        )
        XCTAssertEqual(
            Set(headers.keys),
            [
                "Authorization", "X-OpenPaw-Device", "X-OpenPaw-Timestamp",
                "X-OpenPaw-Nonce", "X-OpenPaw-Signature",
            ]
        )
        XCTAssertEqual(headers["Authorization"], "Bearer tok_secret")
        XCTAssertEqual(headers["X-OpenPaw-Device"], "dev_1")
        XCTAssertEqual(headers["X-OpenPaw-Timestamp"], "1787245200")
        XCTAssertEqual(headers["X-OpenPaw-Nonce"], "n1")
        XCTAssertEqual(headers["X-OpenPaw-Signature"], Self.expectedSignature)
    }

    func testSignatureBindsMethodPathQueryTimestampNonceAndBody() {
        let base = signer.signature(
            method: "GET", pathAndQuery: "/v1/sessions", timestamp: Self.timestamp,
            nonce: Self.nonce, body: Data()
        )
        let variants = [
            signer.signature(
                method: "POST", pathAndQuery: "/v1/sessions", timestamp: Self.timestamp,
                nonce: Self.nonce, body: Data()
            ),
            signer.signature(
                method: "GET", pathAndQuery: "/v1/inbox", timestamp: Self.timestamp,
                nonce: Self.nonce, body: Data()
            ),
            signer.signature(
                method: "GET", pathAndQuery: "/v1/sessions?status=pending",
                timestamp: Self.timestamp, nonce: Self.nonce, body: Data()
            ),
            signer.signature(
                method: "GET", pathAndQuery: "/v1/sessions", timestamp: Self.timestamp + 1,
                nonce: Self.nonce, body: Data()
            ),
            signer.signature(
                method: "GET", pathAndQuery: "/v1/sessions", timestamp: Self.timestamp,
                nonce: "n2", body: Data()
            ),
            signer.signature(
                method: "GET", pathAndQuery: "/v1/sessions", timestamp: Self.timestamp,
                nonce: Self.nonce, body: Data("{}".utf8)
            ),
        ]
        for variant in variants {
            XCTAssertNotEqual(variant, base, "every canonical field must affect the signature")
        }
        XCTAssertEqual(Set(variants).count, variants.count)
    }

    func testVerifyAcceptsOnlyTheCorrectSignature() {
        let canonical = RequestSigner.canonicalString(
            method: "GET", pathAndQuery: "/v1/sessions", timestamp: Self.timestamp,
            nonce: Self.nonce, body: Data()
        )
        XCTAssertTrue(
            RequestSigner.verify(key: Self.key, canonical: canonical, signature: Self.expectedSignature)
        )
        XCTAssertTrue(
            RequestSigner.verify(
                key: Self.key, canonical: canonical, signature: Self.expectedSignature.uppercased()
            ),
            "hex comparison is case insensitive"
        )
        XCTAssertFalse(
            RequestSigner.verify(key: Self.key, canonical: canonical, signature: "deadbeef"),
            "a truncated signature must be rejected without indexing out of bounds"
        )
        var flipped = Array(Self.expectedSignature)
        flipped[0] = flipped[0] == "0" ? "1" : "0"
        XCTAssertFalse(
            RequestSigner.verify(key: Self.key, canonical: canonical, signature: String(flipped))
        )
        XCTAssertFalse(
            RequestSigner.verify(
                key: Data(repeating: 0xAB, count: 32),
                canonical: canonical,
                signature: Self.expectedSignature
            )
        )
    }

    func testBase64KeyInitialiser() throws {
        let base64 = Self.key.base64EncodedString()
        let fromBase64 = try XCTUnwrap(
            RequestSigner(deviceID: Self.deviceID, token: Self.token, hmacKeyBase64: base64)
        )
        XCTAssertEqual(fromBase64.hmacKey, Self.key)
        XCTAssertEqual(
            fromBase64.signature(
                method: "GET", pathAndQuery: "/v1/sessions", timestamp: Self.timestamp,
                nonce: Self.nonce, body: Data()
            ),
            Self.expectedSignature
        )
        XCTAssertNil(
            RequestSigner(deviceID: "d", token: "t", hmacKeyBase64: "not base64!!!"),
            "an unparsable key must not silently produce a signer"
        )
    }

    func testPairingResultBuildsASigner() throws {
        let json = """
            {"device_id":"dev_1","token":"tok_secret",\
            "hmac_key_b64":"\(Self.key.base64EncodedString())",\
            "capabilities":["sessions.read","events.read"]}
            """
        let pairing = try OpenPawCoding.decoder.decode(PairingResult.self, from: Data(json.utf8))
        XCTAssertEqual(pairing.deviceID, "dev_1")
        XCTAssertEqual(pairing.capabilities, ["sessions.read", "events.read"])
        let signer = try XCTUnwrap(pairing.signer)
        XCTAssertEqual(signer.hmacKey, Self.key)
    }

    func testNoncesAreDistinctAndHexEncoded() {
        let nonces = (0..<64).map { _ in RequestSigner.randomNonce() }
        XCTAssertEqual(Set(nonces).count, nonces.count)
        for nonce in nonces {
            XCTAssertEqual(nonce.count, 32)
            XCTAssertTrue(nonce.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        }
    }
}
