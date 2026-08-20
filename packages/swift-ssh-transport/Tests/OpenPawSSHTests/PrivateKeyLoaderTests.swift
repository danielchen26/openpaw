//===----------------------------------------------------------------------===//
//
// This source file is part of the OpenPaw open source project.
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Crypto
import Foundation
import NIOSSH
import OpenPawTerminalCore
import Testing

@testable import OpenPawSSH

@Suite("PrivateKeyLoader against keys produced by ssh-keygen")
struct PrivateKeyLoaderTests {

    /// The fingerprint of a parsed private key's public half.
    ///
    /// Comparing this to `ssh-keygen -l` proves the *scalar* was decoded correctly, not merely that
    /// parsing did not throw: a wrong seed yields a valid key with the wrong public half.
    private func fingerprint(of key: NIOSSHPrivateKey) -> String {
        HostKeyValidator.fingerprint(of: key.publicKey)
    }

    @Test("an unencrypted Ed25519 OpenSSH key parses to the matching public key")
    func parsesUnencryptedEd25519() throws {
        try #require(SSHKeygen.isAvailable)
        let keygen = try SSHKeygen()
        let generated = try keygen.generate(type: "ed25519", name: "plain")

        let key = try PrivateKeyLoader.load(pem: generated.privatePEM)

        let expected = try keygen.fingerprint(
            ofPublicKeyAt: generated.privatePath.appendingPathExtension("pub"))
        #expect(self.fingerprint(of: key) == expected)

        // Matching fingerprints prove the private scalar itself was decoded correctly: the public
        // half is derived from the parsed scalar, so a wrong seed would yield a different key.
        #expect(HostKeyValidator.keyType(of: key.publicKey) == "ssh-ed25519")
    }

    @Test("a bcrypt-encrypted Ed25519 key parses with the right passphrase")
    func parsesEncryptedEd25519() throws {
        try #require(SSHKeygen.isAvailable)
        let keygen = try SSHKeygen()
        let passphrase = "hunter2-correct-passphrase"
        let generated = try keygen.generate(
            type: "ed25519", passphrase: passphrase, name: "encrypted")

        // This exercises the whole chain: base64, the OpenSSH container, bcrypt_pbkdf (and hence
        // Blowfish with the salted expand-state), AES-256-CTR, the check integers and the padding.
        let key = try PrivateKeyLoader.load(pem: generated.privatePEM, passphrase: passphrase)

        let expected = try keygen.fingerprint(
            ofPublicKeyAt: generated.privatePath.appendingPathExtension("pub"))
        #expect(
            self.fingerprint(of: key) == expected,
            "decrypted scalar does not match the public key; bcrypt_pbkdf or AES-CTR is wrong")
    }

    @Test("a wrong passphrase is reported as such, not as a corrupt key")
    func wrongPassphraseIsDetected() throws {
        try #require(SSHKeygen.isAvailable)
        let keygen = try SSHKeygen()
        let generated = try keygen.generate(
            type: "ed25519", passphrase: "the-real-passphrase", name: "encrypted")

        let error = try #require(throws: TransportError.self) {
            _ = try PrivateKeyLoader.load(pem: generated.privatePEM, passphrase: "wrong")
        }
        guard case .invalidPrivateKey(let detail) = error else {
            Issue.record("expected .invalidPrivateKey, got \(error)")
            return
        }
        // The check integers are what detect this, and the message must say so usefully.
        #expect(detail.lowercased().contains("passphrase"))
    }

    @Test("an encrypted key with no passphrase reports that one is required")
    func missingPassphraseIsReported() throws {
        try #require(SSHKeygen.isAvailable)
        let keygen = try SSHKeygen()
        let generated = try keygen.generate(
            type: "ed25519", passphrase: "some-passphrase", name: "encrypted")

        let error = try #require(throws: TransportError.self) {
            _ = try PrivateKeyLoader.load(pem: generated.privatePEM, passphrase: nil)
        }
        guard case .invalidPrivateKey(let detail) = error else {
            Issue.record("expected .invalidPrivateKey, got \(error)")
            return
        }
        #expect(detail.contains("encrypted"))
        #expect(detail.contains("passphrase"))
    }

    @Test("an ECDSA P-256 OpenSSH key parses to the matching public key")
    func parsesECDSAP256() throws {
        try #require(SSHKeygen.isAvailable)
        let keygen = try SSHKeygen()
        let generated = try keygen.generate(type: "ecdsa", bits: 256, name: "ecdsa")

        let key = try PrivateKeyLoader.load(pem: generated.privatePEM)
        let expected = try keygen.fingerprint(
            ofPublicKeyAt: generated.privatePath.appendingPathExtension("pub"))
        #expect(self.fingerprint(of: key) == expected)
    }

    @Test("an RSA key is identified and rejected as an unsupported key type")
    func rsaIsRejectedAsUnsupported() throws {
        try #require(SSHKeygen.isAvailable)
        let keygen = try SSHKeygen()

        // Modern ssh-keygen writes RSA into the OpenSSH v1 container, so this goes through the
        // container's public-key type check rather than the PEM label.
        let container = try keygen.generate(type: "rsa", bits: 2048, name: "rsa-container")
        let containerError = try #require(throws: TransportError.self) {
            _ = try PrivateKeyLoader.load(pem: container.privatePEM)
        }
        #expect(containerError == .unsupportedKeyType("ssh-rsa"))

        // `-m PEM` produces PKCS#1, which is recognised by its PEM label instead.
        let pkcs1 = try keygen.generate(type: "rsa", bits: 2048, format: "PEM", name: "rsa-pem")
        #expect(pkcs1.privatePEM.contains("BEGIN RSA PRIVATE KEY"))
        let pkcs1Error = try #require(throws: TransportError.self) {
            _ = try PrivateKeyLoader.load(pem: pkcs1.privatePEM)
        }
        #expect(pkcs1Error == .unsupportedKeyType("ssh-rsa"))
    }

    @Test("a truncated OpenSSH blob yields a truncation error naming the field")
    func truncatedBlobIsRejected() throws {
        try #require(SSHKeygen.isAvailable)
        let keygen = try SSHKeygen()
        let generated = try keygen.generate(type: "ed25519", name: "plain")

        let (label, der) = try PEM.decode(generated.privatePEM)
        #expect(label == "OPENSSH PRIVATE KEY")

        // Cut the container in half: the magic and some header fields survive, so parsing gets far
        // enough to fail on a length prefix rather than on the armour.
        let truncated = Array(der[0..<(der.count / 2)])

        let failure = try #require(throws: PrivateKeyParseFailure.self) {
            _ = try OpenSSHKeyFile.parse(truncated, passphrase: nil)
        }
        guard case .truncated(let what) = failure else {
            Issue.record("expected .truncated, got \(failure)")
            return
        }
        #expect(!what.isEmpty, "a truncation error must name the field it was reading")

        // Through the public API the same input is an invalidPrivateKey mentioning truncation.
        let armoured = """
            -----BEGIN OPENSSH PRIVATE KEY-----
            \(Data(truncated).base64EncodedString())
            -----END OPENSSH PRIVATE KEY-----
            """
        let error = try #require(throws: TransportError.self) {
            _ = try PrivateKeyLoader.load(pem: armoured)
        }
        guard case .invalidPrivateKey(let detail) = error else {
            Issue.record("expected .invalidPrivateKey, got \(error)")
            return
        }
        #expect(detail.contains("truncated"))
    }

    @Test("an empty or non-PEM blob is rejected without crashing")
    func garbageIsRejected() throws {
        for input in ["", "not a key at all", "-----BEGIN OPENSSH PRIVATE KEY-----"] {
            #expect(throws: TransportError.self) {
                _ = try PrivateKeyLoader.load(pem: input)
            }
        }

        // Valid armour, invalid base64 payload.
        let badBase64 = """
            -----BEGIN OPENSSH PRIVATE KEY-----
            !!!!not base64!!!!
            -----END OPENSSH PRIVATE KEY-----
            """
        #expect(throws: TransportError.self) {
            _ = try PrivateKeyLoader.load(pem: badBase64)
        }

        // Correct armour and base64, but the payload is not an OpenSSH container.
        let wrongMagic = """
            -----BEGIN OPENSSH PRIVATE KEY-----
            \(Data(repeating: 0x41, count: 64).base64EncodedString())
            -----END OPENSSH PRIVATE KEY-----
            """
        #expect(throws: TransportError.self) {
            _ = try PrivateKeyLoader.load(pem: wrongMagic)
        }
    }

    @Test("non-UTF-8 key material is rejected rather than misparsed")
    func binaryInputIsRejected() throws {
        // 0xFF is never valid UTF-8, so this cannot be mistaken for PEM text.
        let error = try #require(throws: TransportError.self) {
            _ = try PrivateKeyLoader.load(data: Data([0xFF, 0xFE, 0xFD, 0xFC]))
        }
        guard case .invalidPrivateKey(let detail) = error else {
            Issue.record("expected .invalidPrivateKey, got \(error)")
            return
        }
        #expect(detail.contains("UTF-8"))
    }

    @Test("mpint normalisation strips sign padding and left-pads short scalars")
    func mpintNormalisation() throws {
        // A leading zero is the mpint sign byte for a scalar whose top bit is set.
        #expect(try OpenSSHKeyFile.normalize(mpint: [0x00, 0xFF, 0x01], to: 2) == [0xFF, 0x01])
        // Short scalars are stored without leading zeros and must be left-padded.
        #expect(try OpenSSHKeyFile.normalize(mpint: [0x07], to: 4) == [0x00, 0x00, 0x00, 0x07])
        // Exactly sized input passes through.
        #expect(try OpenSSHKeyFile.normalize(mpint: [0x01, 0x02], to: 2) == [0x01, 0x02])
        // Too long even after stripping is a malformed key, not a silent truncation.
        #expect(throws: PrivateKeyParseFailure.self) {
            _ = try OpenSSHKeyFile.normalize(mpint: [0x01, 0x02, 0x03], to: 2)
        }
        #expect(throws: PrivateKeyParseFailure.self) {
            _ = try OpenSSHKeyFile.normalize(mpint: [], to: 2)
        }
    }

    @Test("OpenSSH trailing padding must be the 1,2,3... sequence")
    func paddingIsVerified() throws {
        // Valid: fewer bytes than the block size, counting up from one.
        #expect(throws: Never.self) { try OpenSSHKeyFile.verifyPadding([1, 2, 3], blockSize: 8) }
        #expect(throws: Never.self) { try OpenSSHKeyFile.verifyPadding([], blockSize: 8) }
        // Wrong values mean a wrong key or corruption, even if lengths look plausible.
        #expect(throws: PrivateKeyParseFailure.self) {
            try OpenSSHKeyFile.verifyPadding([1, 2, 4], blockSize: 8)
        }
        // A full block of padding is never written.
        #expect(throws: PrivateKeyParseFailure.self) {
            try OpenSSHKeyFile.verifyPadding([1, 2, 3, 4, 5, 6, 7, 8], blockSize: 8)
        }
    }

    @Test("SSH blob reads are bounds-checked and name the field on failure")
    func blobReaderIsBoundsChecked() throws {
        // A length prefix claiming more than the buffer holds must not over-read.
        var reader = SSHBlobReader([0x00, 0x00, 0x10, 0x00, 0x41])
        let failure = try #require(throws: PrivateKeyParseFailure.self) {
            _ = try reader.readLengthPrefixed("payload")
        }
        guard case .truncated(let what) = failure else {
            Issue.record("expected .truncated, got \(failure)")
            return
        }
        #expect(what.contains("payload"))

        // Big-endian decoding, and exact-fit reads succeed.
        var good = SSHBlobReader([0x00, 0x00, 0x00, 0x03, 0x61, 0x62, 0x63])
        #expect(try good.readString("word") == "abc")
        #expect(good.remaining == 0)
    }
}

// MARK: - Blowfish

@Suite("Blowfish and bcrypt_pbkdf")
struct BlowfishTests {

    /// Published Blowfish test vectors (Eric Young's reference set, also in Schneier's book).
    ///
    /// These validate the pi-derived P-array and S-boxes and the exact round structure. Without
    /// them, an error in the tables would only show up as an unexplained decryption failure.
    @Test(
        "matches the published Blowfish test vectors",
        arguments: [
            (key: "0000000000000000", plaintext: "0000000000000000", cipher: "4EF997456198DD78"),
            (key: "FFFFFFFFFFFFFFFF", plaintext: "FFFFFFFFFFFFFFFF", cipher: "51866FD5B85ECB8A"),
            (key: "3000000000000000", plaintext: "1000000000000001", cipher: "7D856F9A613063F2"),
            (key: "1111111111111111", plaintext: "1111111111111111", cipher: "2466DD878B963C9D"),
            (key: "0123456789ABCDEF", plaintext: "1111111111111111", cipher: "61F9C3802281B096"),
            (key: "FEDCBA9876543210", plaintext: "0123456789ABCDEF", cipher: "0ACEAB0FC6A0A28D"),
            (key: "7CA110454A1A6E57", plaintext: "01A1D6D039776742", cipher: "59C68245EB05282B"),
        ]
    )
    func publishedVectors(key: String, plaintext: String, cipher: String) throws {
        let keyBytes = try Self.bytes(key)
        let input = try #require(UInt64(plaintext, radix: 16))
        let expected = try #require(UInt64(cipher, radix: 16))

        let actual = Blowfish.encryptBlockForTesting(key: keyBytes, plaintext: input)
        #expect(
            actual == expected,
            "expected \(String(expected, radix: 16)), got \(String(actual, radix: 16))")
    }

    @Test("bcrypt_pbkdf is deterministic and length-dependent, not a truncated prefix")
    func bcryptIsDeterministicAndLengthDependent() throws {
        let passphrase = Array("passphrase".utf8)
        let salt = Array("saltysalt".utf8)

        let first = try BcryptPBKDF.derive(
            passphrase: passphrase, salt: salt, rounds: 4, keyLength: 48)
        let again = try BcryptPBKDF.derive(
            passphrase: passphrase, salt: salt, rounds: 4, keyLength: 48)
        #expect(first == again)
        #expect(first.count == 48)

        // bcrypt_pbkdf emits key material non-linearly, so a shorter request is *not* a prefix of a
        // longer one. Asserting this pins the deviation from PBKDF2 that makes the KDF correct.
        let shorter = try BcryptPBKDF.derive(
            passphrase: passphrase, salt: salt, rounds: 4, keyLength: 32)
        #expect(shorter.count == 32)
        #expect(Array(first[0..<32]) != shorter)

        // Rounds and salt both change the output.
        let moreRounds = try BcryptPBKDF.derive(
            passphrase: passphrase, salt: salt, rounds: 5, keyLength: 48)
        #expect(moreRounds != first)
        let otherSalt = try BcryptPBKDF.derive(
            passphrase: passphrase, salt: Array("othersalt".utf8), rounds: 4, keyLength: 48)
        #expect(otherSalt != first)
    }

    @Test("degenerate bcrypt parameters are rejected")
    func degenerateParametersRejected() throws {
        let passphrase = Array("p".utf8)
        let salt = Array("s".utf8)

        #expect(throws: PrivateKeyParseFailure.self) {
            _ = try BcryptPBKDF.derive(passphrase: passphrase, salt: salt, rounds: 0, keyLength: 32)
        }
        #expect(throws: PrivateKeyParseFailure.passphraseRequired) {
            _ = try BcryptPBKDF.derive(passphrase: [], salt: salt, rounds: 1, keyLength: 32)
        }
        #expect(throws: PrivateKeyParseFailure.self) {
            _ = try BcryptPBKDF.derive(passphrase: passphrase, salt: [], rounds: 1, keyLength: 32)
        }
        #expect(throws: PrivateKeyParseFailure.self) {
            _ = try BcryptPBKDF.derive(passphrase: passphrase, salt: salt, rounds: 1, keyLength: 0)
        }
    }

    private static func bytes(_ hex: String) throws -> [UInt8] {
        var result: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else {
                throw BlowfishTestError.badHex(hex)
            }
            result.append(byte)
            index = next
        }
        return result
    }

    enum BlowfishTestError: Error {
        case badHex(String)
    }
}
