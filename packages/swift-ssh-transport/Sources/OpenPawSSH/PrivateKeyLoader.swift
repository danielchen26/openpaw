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
import _CryptoExtras

// MARK: - Failures

/// Why a private key could not be turned into a ``NIOSSHPrivateKey``.
///
/// This is internal because callers see ``TransportError``; it exists so each rejection carries a
/// specific reason instead of one opaque "bad key", and so parsing never traps on malformed input.
enum PrivateKeyParseFailure: Error, Equatable {
    /// The blob has no PEM armour we recognise.
    case notAPrivateKey(String)
    /// A length prefix ran past the end of the buffer.
    case truncated(String)
    /// Structurally intact but internally inconsistent.
    case malformed(String)
    case unsupportedCipher(String)
    case unsupportedKDF(String)
    case invalidKDF(String)
    /// The key is encrypted and no passphrase was supplied.
    case passphraseRequired
    /// A passphrase was supplied but the decrypted check integers disagree.
    case incorrectPassphrase
    /// A well-formed key of a type NIOSSH cannot use.
    case unsupportedKeyType(String)

    var detail: String {
        switch self {
        case .notAPrivateKey(let what): return "not a recognised private key: \(what)"
        case .truncated(let what): return "truncated while reading \(what)"
        case .malformed(let what): return "malformed: \(what)"
        case .unsupportedCipher(let name): return "unsupported cipher \(name)"
        case .unsupportedKDF(let name): return "unsupported key derivation function \(name)"
        case .invalidKDF(let what): return "invalid key derivation parameters: \(what)"
        case .passphraseRequired: return "the key is encrypted and no passphrase was supplied"
        case .incorrectPassphrase: return "the passphrase is incorrect"
        case .unsupportedKeyType(let type): return "unsupported key type \(type)"
        }
    }

    /// Map onto the public error surface.
    ///
    /// An unsupported *type* is deliberately distinct from an unparseable key: the user can fix the
    /// former by generating a different key, but not by retyping a passphrase.
    var asTransportError: TransportError {
        switch self {
        case .unsupportedKeyType(let type):
            return .unsupportedKeyType(type)
        default:
            return .invalidPrivateKey(self.detail)
        }
    }
}

// MARK: - Loader

/// Parses private keys into ``NIOSSHPrivateKey``.
///
/// Supported: OpenSSH v1 containers (`-----BEGIN OPENSSH PRIVATE KEY-----`) holding Ed25519 or
/// ECDSA P-256/P-384/P-521 keys, unencrypted or protected with the `bcrypt` KDF and an AES-CTR or
/// AES-CBC cipher; and PKCS#8 / SEC1 PEM keys of the same key types.
///
/// RSA and DSA are parsed far enough to be *identified* and are then rejected with
/// ``TransportError/unsupportedKeyType(_:)``, because the resolved NIOSSH version implements
/// neither: `NIOSSHPrivateKey` can only be built from Ed25519 or NIST-curve keys. That is a real
/// outcome, not a gap — an RSA key genuinely cannot authenticate through this transport.
public enum PrivateKeyLoader {
    /// Parse a PEM-armoured private key.
    public static func load(pem: String, passphrase: String? = nil) throws -> NIOSSHPrivateKey {
        do {
            return try self.parse(pem: pem, passphrase: passphrase)
        } catch let failure as PrivateKeyParseFailure {
            throw failure.asTransportError
        } catch let error as TransportError {
            throw error
        } catch {
            // Anything swift-crypto rejects is a bad key, not a transport fault.
            throw TransportError.invalidPrivateKey(String(describing: error))
        }
    }

    /// Parse a PEM-armoured private key held as bytes, as it comes out of the keychain.
    public static func load(data: Data, passphrase: String? = nil) throws -> NIOSSHPrivateKey {
        guard let text = String(data: data, encoding: .utf8) else {
            throw TransportError.invalidPrivateKey(
                "the key material is not UTF-8 text; expected PEM armour")
        }
        return try self.load(pem: text, passphrase: passphrase)
    }

    private static func parse(pem: String, passphrase: String?) throws -> NIOSSHPrivateKey {
        let (label, der) = try PEM.decode(pem)

        switch label {
        case "OPENSSH PRIVATE KEY":
            return try OpenSSHKeyFile.parse(der, passphrase: passphrase)

        case "RSA PRIVATE KEY":
            throw PrivateKeyParseFailure.unsupportedKeyType("ssh-rsa")

        case "DSA PRIVATE KEY":
            throw PrivateKeyParseFailure.unsupportedKeyType("ssh-dss")

        case "ENCRYPTED PRIVATE KEY":
            // PKCS#8 PBES2. Deliberately unimplemented: OpenSSH does not produce these, and the
            // remedy is a one-line conversion rather than a second KDF stack.
            throw PrivateKeyParseFailure.unsupportedCipher(
                "PKCS#8 PBES2 (convert with `ssh-keygen -p -m RFC4716 -f <key>`)")

        case "PRIVATE KEY":
            return try self.parsePKCS8(der: der)

        case "EC PRIVATE KEY":
            return try self.parseECDSA(der: der, source: "SEC1")

        default:
            throw PrivateKeyParseFailure.notAPrivateKey("PEM label \"\(label)\"")
        }
    }

    /// Parse a PKCS#8 `PrivateKeyInfo`, dispatching on its algorithm OID.
    private static func parsePKCS8(der: [UInt8]) throws -> NIOSSHPrivateKey {
        let oid = try DER.pkcs8AlgorithmOID(der)

        switch oid {
        case DER.oidRSAEncryption:
            throw PrivateKeyParseFailure.unsupportedKeyType("ssh-rsa")
        case DER.oidDSA:
            throw PrivateKeyParseFailure.unsupportedKeyType("ssh-dss")
        case DER.oidEd25519:
            let key = try Curve25519.Signing.PrivateKey(derRepresentation: der)
            return NIOSSHPrivateKey(ed25519Key: key)
        case DER.oidECPublicKey:
            return try self.parseECDSA(der: der, source: "PKCS#8")
        default:
            throw PrivateKeyParseFailure.unsupportedKeyType("OID \(DER.describe(oid: oid))")
        }
    }

    /// Build a NIST-curve key, trying each curve swift-crypto supports.
    ///
    /// The curve is not read out of the DER: each of P-256/P-384/P-521 has a different scalar
    /// length and swift-crypto validates it, so exactly one initializer can succeed.
    private static func parseECDSA(der: [UInt8], source: String) throws -> NIOSSHPrivateKey {
        if let key = try? P256.Signing.PrivateKey(derRepresentation: der) {
            return NIOSSHPrivateKey(p256Key: key)
        }
        if let key = try? P384.Signing.PrivateKey(derRepresentation: der) {
            return NIOSSHPrivateKey(p384Key: key)
        }
        if let key = try? P521.Signing.PrivateKey(derRepresentation: der) {
            return NIOSSHPrivateKey(p521Key: key)
        }
        throw PrivateKeyParseFailure.malformed(
            "\(source) elliptic curve key is not on P-256, P-384 or P-521")
    }
}

// MARK: - PEM

/// Minimal PEM armour handling.
enum PEM {
    /// Extract the label and base64 payload of the first PEM block in `text`.
    static func decode(_ text: String) throws -> (label: String, der: [UInt8]) {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }

        guard
            let beginIndex = lines.firstIndex(where: {
                $0.hasPrefix("-----BEGIN ") && $0.hasSuffix("-----")
            })
        else {
            throw PrivateKeyParseFailure.notAPrivateKey("no PEM BEGIN line")
        }

        let begin = lines[beginIndex]
        let label = String(begin.dropFirst("-----BEGIN ".count).dropLast("-----".count))
        guard !label.isEmpty else {
            throw PrivateKeyParseFailure.notAPrivateKey("empty PEM label")
        }

        let endMarker = "-----END \(label)-----"
        guard let endIndex = lines[beginIndex...].firstIndex(of: endMarker) else {
            throw PrivateKeyParseFailure.truncated("PEM block for \"\(label)\" has no END line")
        }

        let body = lines[(beginIndex + 1)..<endIndex]
            .filter { !$0.isEmpty && !$0.contains(":") }  // drop RFC 1421 headers, e.g. Proc-Type
            .joined()

        guard !body.isEmpty else {
            throw PrivateKeyParseFailure.truncated("PEM block for \"\(label)\" is empty")
        }
        guard let data = Data(base64Encoded: body, options: [.ignoreUnknownCharacters]) else {
            throw PrivateKeyParseFailure.malformed("PEM body for \"\(label)\" is not valid base64")
        }
        return (label, [UInt8](data))
    }
}

// MARK: - SSH binary format

/// Reader for the SSH wire format: big-endian integers and `uint32`-length-prefixed strings.
///
/// Every read is bounds-checked and reports what it was reading, so a truncated key yields
/// ``PrivateKeyParseFailure/truncated(_:)`` naming the field rather than trapping.
struct SSHBlobReader {
    private let bytes: [UInt8]
    private var offset: Int

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
        self.offset = 0
    }

    var remaining: Int { self.bytes.count - self.offset }

    var rest: [UInt8] { Array(self.bytes[self.offset...]) }

    mutating func readBytes(_ count: Int, _ what: String) throws -> [UInt8] {
        guard count >= 0 else {
            throw PrivateKeyParseFailure.malformed("negative length for \(what)")
        }
        guard self.remaining >= count else {
            throw PrivateKeyParseFailure.truncated(
                "\(what) (need \(count) bytes, \(self.remaining) available)")
        }
        defer { self.offset += count }
        return Array(self.bytes[self.offset..<(self.offset + count)])
    }

    mutating func readUInt32(_ what: String) throws -> UInt32 {
        let raw = try self.readBytes(4, what)
        return (UInt32(raw[0]) << 24) | (UInt32(raw[1]) << 16) | (UInt32(raw[2]) << 8) | UInt32(raw[3])
    }

    /// Read a `uint32`-length-prefixed byte string.
    mutating func readLengthPrefixed(_ what: String) throws -> [UInt8] {
        let length = try self.readUInt32("length of \(what)")
        // Reject absurd lengths before allocating: a corrupt prefix must not be trusted.
        guard length <= UInt32(self.remaining) else {
            throw PrivateKeyParseFailure.truncated(
                "\(what) (claims \(length) bytes, \(self.remaining) available)")
        }
        return try self.readBytes(Int(length), what)
    }

    mutating func readString(_ what: String) throws -> String {
        let raw = try self.readLengthPrefixed(what)
        guard let text = String(bytes: raw, encoding: .utf8) else {
            throw PrivateKeyParseFailure.malformed("\(what) is not UTF-8")
        }
        return text
    }

    mutating func expect(magic: [UInt8], _ what: String) throws {
        let actual = try self.readBytes(magic.count, what)
        guard actual == magic else {
            throw PrivateKeyParseFailure.notAPrivateKey("wrong \(what)")
        }
    }
}

// MARK: - OpenSSH v1 container

/// The `openssh-key-v1` private key container.
enum OpenSSHKeyFile {
    static let magic = Array("openssh-key-v1\0".utf8)

    /// Symmetric ciphers OpenSSH uses to protect these containers.
    enum Cipher: Equatable {
        case none
        case aesCTR(keyLength: Int)
        case aesCBC(keyLength: Int)

        static func named(_ name: String) throws -> Cipher {
            switch name {
            case "none": return .none
            case "aes128-ctr": return .aesCTR(keyLength: 16)
            case "aes192-ctr": return .aesCTR(keyLength: 24)
            case "aes256-ctr": return .aesCTR(keyLength: 32)
            case "aes128-cbc": return .aesCBC(keyLength: 16)
            case "aes192-cbc": return .aesCBC(keyLength: 24)
            case "aes256-cbc": return .aesCBC(keyLength: 32)
            default:
                throw PrivateKeyParseFailure.unsupportedCipher(name)
            }
        }

        var keyLength: Int {
            switch self {
            case .none: return 0
            case .aesCTR(let length), .aesCBC(let length): return length
            }
        }

        var ivLength: Int {
            switch self {
            case .none: return 0
            case .aesCTR, .aesCBC: return 16
            }
        }

        var blockSize: Int {
            switch self {
            case .none: return 8  // OpenSSH still pads unencrypted keys to 8 bytes.
            case .aesCTR, .aesCBC: return 16
            }
        }

        func decrypt(_ ciphertext: [UInt8], key: [UInt8], iv: [UInt8]) throws -> [UInt8] {
            guard ciphertext.count % self.blockSize == 0 else {
                throw PrivateKeyParseFailure.malformed(
                    "encrypted key body is \(ciphertext.count) bytes, not a multiple of \(self.blockSize)")
            }
            let symmetric = SymmetricKey(data: key)
            switch self {
            case .none:
                return ciphertext
            case .aesCTR:
                let nonce = try AES._CTR.Nonce(nonceBytes: iv)
                return [UInt8](try AES._CTR.decrypt(ciphertext, using: symmetric, nonce: nonce))
            case .aesCBC:
                let vector = try AES._CBC.IV(ivBytes: iv)
                // `noPadding`: the container is padded by OpenSSH's own scheme, not PKCS#7.
                return [UInt8](
                    try AES._CBC.decrypt(ciphertext, using: symmetric, iv: vector, noPadding: true))
            }
        }
    }

    /// Parse the container and return the first private key it holds.
    static func parse(_ blob: [UInt8], passphrase: String?) throws -> NIOSSHPrivateKey {
        var reader = SSHBlobReader(blob)
        try reader.expect(magic: self.magic, "openssh-key-v1 magic")

        let cipherName = try reader.readString("cipher name")
        let kdfName = try reader.readString("KDF name")
        let kdfOptions = try reader.readLengthPrefixed("KDF options")

        let keyCount = try reader.readUInt32("key count")
        guard keyCount >= 1 else {
            throw PrivateKeyParseFailure.malformed("container holds no keys")
        }
        // Guard against a corrupt count driving a huge loop; OpenSSH writes exactly one.
        guard keyCount <= 16 else {
            throw PrivateKeyParseFailure.malformed("container claims \(keyCount) keys")
        }

        var publicKeys: [[UInt8]] = []
        for index in 0..<keyCount {
            publicKeys.append(try reader.readLengthPrefixed("public key \(index)"))
        }
        let privateSection = try reader.readLengthPrefixed("private key section")

        // Identify the key type from the *public* half, which is never encrypted. This turns an
        // encrypted RSA key into "unsupported key type" instead of demanding a passphrase we could
        // never use.
        if let advertised = try? Self.keyType(ofPublicKey: publicKeys[0]) {
            try Self.rejectUnusable(keyType: advertised)
        }

        let cipher = try Cipher.named(cipherName)
        let plaintext: [UInt8]

        if cipher == .none {
            guard kdfName == "none" else {
                throw PrivateKeyParseFailure.malformed(
                    "cipher is \"none\" but KDF is \"\(kdfName)\"")
            }
            plaintext = privateSection
        } else {
            guard kdfName == "bcrypt" else {
                throw PrivateKeyParseFailure.unsupportedKDF(kdfName)
            }
            guard let passphrase, !passphrase.isEmpty else {
                throw PrivateKeyParseFailure.passphraseRequired
            }

            var options = SSHBlobReader(kdfOptions)
            let salt = try options.readLengthPrefixed("bcrypt salt")
            let rounds = Int(try options.readUInt32("bcrypt rounds"))

            let derived = try BcryptPBKDF.derive(
                passphrase: Array(passphrase.utf8),
                salt: salt,
                rounds: rounds,
                keyLength: cipher.keyLength + cipher.ivLength
            )
            plaintext = try cipher.decrypt(
                privateSection,
                key: Array(derived[0..<cipher.keyLength]),
                iv: Array(derived[cipher.keyLength...])
            )
        }

        return try Self.parsePrivateSection(plaintext, wasEncrypted: cipher != .none, cipher: cipher)
    }

    /// The algorithm name at the head of an SSH public key blob.
    private static func keyType(ofPublicKey blob: [UInt8]) throws -> String {
        var reader = SSHBlobReader(blob)
        return try reader.readString("public key algorithm")
    }

    /// Reject key types NIOSSH cannot build a `NIOSSHPrivateKey` from.
    private static func rejectUnusable(keyType: String) throws {
        switch keyType {
        case "ssh-ed25519", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521":
            return
        default:
            throw PrivateKeyParseFailure.unsupportedKeyType(keyType)
        }
    }

    /// Parse the decrypted private section.
    private static func parsePrivateSection(
        _ plaintext: [UInt8],
        wasEncrypted: Bool,
        cipher: Cipher
    ) throws -> NIOSSHPrivateKey {
        var reader = SSHBlobReader(plaintext)

        let check1 = try reader.readUInt32("first check integer")
        let check2 = try reader.readUInt32("second check integer")
        guard check1 == check2 else {
            // These two random words are written identically and are the container's only
            // integrity signal, so a mismatch after decryption means a wrong passphrase.
            throw wasEncrypted
                ? PrivateKeyParseFailure.incorrectPassphrase
                : PrivateKeyParseFailure.malformed("check integers differ in an unencrypted key")
        }

        let keyType = try reader.readString("private key type")
        try Self.rejectUnusable(keyType: keyType)

        let key: NIOSSHPrivateKey
        switch keyType {
        case "ssh-ed25519":
            key = try Self.parseEd25519(&reader)
        case "ecdsa-sha2-nistp256":
            key = try Self.parseECDSA(&reader, curve: "nistp256", scalarSize: 32) {
                NIOSSHPrivateKey(p256Key: try P256.Signing.PrivateKey(rawRepresentation: $0))
            }
        case "ecdsa-sha2-nistp384":
            key = try Self.parseECDSA(&reader, curve: "nistp384", scalarSize: 48) {
                NIOSSHPrivateKey(p384Key: try P384.Signing.PrivateKey(rawRepresentation: $0))
            }
        case "ecdsa-sha2-nistp521":
            key = try Self.parseECDSA(&reader, curve: "nistp521", scalarSize: 66) {
                NIOSSHPrivateKey(p521Key: try P521.Signing.PrivateKey(rawRepresentation: $0))
            }
        default:
            throw PrivateKeyParseFailure.unsupportedKeyType(keyType)
        }

        _ = try reader.readString("comment")
        try Self.verifyPadding(reader.rest, blockSize: cipher.blockSize)
        return key
    }

    private static func parseEd25519(_ reader: inout SSHBlobReader) throws -> NIOSSHPrivateKey {
        let publicKey = try reader.readLengthPrefixed("Ed25519 public key")
        let privateKey = try reader.readLengthPrefixed("Ed25519 private key")

        guard publicKey.count == 32 else {
            throw PrivateKeyParseFailure.malformed(
                "Ed25519 public key is \(publicKey.count) bytes, expected 32")
        }
        // OpenSSH stores seed || public key, so the trailing half must echo the public half.
        guard privateKey.count == 64 else {
            throw PrivateKeyParseFailure.malformed(
                "Ed25519 private key is \(privateKey.count) bytes, expected 64")
        }
        guard Array(privateKey[32..<64]) == publicKey else {
            throw PrivateKeyParseFailure.malformed(
                "Ed25519 private key does not match its public key")
        }

        let seed = Array(privateKey[0..<32])
        do {
            return NIOSSHPrivateKey(ed25519Key: try Curve25519.Signing.PrivateKey(rawRepresentation: seed))
        } catch {
            throw PrivateKeyParseFailure.malformed("Ed25519 seed rejected: \(error)")
        }
    }

    private static func parseECDSA(
        _ reader: inout SSHBlobReader,
        curve expectedCurve: String,
        scalarSize: Int,
        build: ([UInt8]) throws -> NIOSSHPrivateKey
    ) throws -> NIOSSHPrivateKey {
        let curve = try reader.readString("ECDSA curve name")
        guard curve == expectedCurve else {
            throw PrivateKeyParseFailure.malformed(
                "key claims \(expectedCurve) but carries curve \(curve)")
        }
        _ = try reader.readLengthPrefixed("ECDSA public point")
        let scalar = try reader.readLengthPrefixed("ECDSA private scalar")

        let normalized = try Self.normalize(mpint: scalar, to: scalarSize)
        do {
            return try build(normalized)
        } catch let failure as PrivateKeyParseFailure {
            throw failure
        } catch {
            throw PrivateKeyParseFailure.malformed("\(curve) scalar rejected: \(error)")
        }
    }

    /// Convert an SSH `mpint` to a fixed-width big-endian scalar.
    ///
    /// `mpint` is signed, so a scalar whose top bit is set carries a leading zero byte, and small
    /// scalars are stored short. Both must be normalised before swift-crypto will accept them.
    static func normalize(mpint raw: [UInt8], to size: Int) throws -> [UInt8] {
        var value = raw
        while value.first == 0 && value.count > size {
            value.removeFirst()
        }
        guard value.count <= size else {
            throw PrivateKeyParseFailure.malformed(
                "private scalar is \(value.count) bytes, expected at most \(size)")
        }
        guard !value.isEmpty else {
            throw PrivateKeyParseFailure.malformed("private scalar is empty")
        }
        return [UInt8](repeating: 0, count: size - value.count) + value
    }

    /// OpenSSH pads the private section with the bytes 1, 2, 3, ... up to the cipher block size.
    ///
    /// Checking it catches a wrong-but-lucky passphrase whose check integers happened to collide,
    /// and catches truncation that the length prefixes alone would not.
    static func verifyPadding(_ padding: [UInt8], blockSize: Int) throws {
        guard padding.count < blockSize else {
            throw PrivateKeyParseFailure.malformed(
                "\(padding.count) bytes of trailing padding exceeds the \(blockSize) byte block")
        }
        for (index, byte) in padding.enumerated() {
            guard byte == UInt8(index + 1) else {
                throw PrivateKeyParseFailure.malformed(
                    "padding byte \(index) is \(byte), expected \(index + 1)")
            }
        }
    }
}

// MARK: - DER

/// Just enough DER to read a PKCS#8 algorithm identifier.
///
/// swift-crypto parses the keys themselves; this exists only so an RSA key can be *named* in the
/// error instead of being reported as an unparseable blob.
enum DER {
    static let oidRSAEncryption: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]
    static let oidDSA: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x38, 0x04, 0x01]
    static let oidEd25519: [UInt8] = [0x2B, 0x65, 0x70]
    static let oidECPublicKey: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]

    private static let tagInteger: UInt8 = 0x02
    private static let tagOID: UInt8 = 0x06
    private static let tagSequence: UInt8 = 0x30

    /// `PrivateKeyInfo ::= SEQUENCE { version INTEGER, algorithm SEQUENCE { OID, ... }, ... }`
    static func pkcs8AlgorithmOID(_ der: [UInt8]) throws -> [UInt8] {
        var top = try self.contents(of: self.tagSequence, in: der, what: "PKCS#8 PrivateKeyInfo")
        _ = try self.take(tag: self.tagInteger, from: &top, what: "PKCS#8 version")
        var algorithm = try self.take(tag: self.tagSequence, from: &top, what: "PKCS#8 algorithm")
        return try self.take(tag: self.tagOID, from: &algorithm, what: "PKCS#8 algorithm OID")
    }

    /// Render an OID's content bytes as dotted decimal, for error messages.
    static func describe(oid: [UInt8]) -> String {
        guard let first = oid.first else { return "<empty>" }
        var components = [String(first / 40), String(first % 40)]
        var value = 0
        for byte in oid.dropFirst() {
            value = (value << 7) | Int(byte & 0x7F)
            if byte & 0x80 == 0 {
                components.append(String(value))
                value = 0
            }
        }
        return components.joined(separator: ".")
    }

    /// Contents of a single TLV that must span the whole buffer.
    private static func contents(of tag: UInt8, in der: [UInt8], what: String) throws -> [UInt8] {
        var buffer = der
        let value = try self.take(tag: tag, from: &buffer, what: what)
        return value
    }

    /// Consume one TLV from the front of `buffer` and return its contents.
    private static func take(tag: UInt8, from buffer: inout [UInt8], what: String) throws -> [UInt8] {
        guard let actual = buffer.first else {
            throw PrivateKeyParseFailure.truncated(what)
        }
        guard actual == tag else {
            throw PrivateKeyParseFailure.malformed(
                "\(what): expected DER tag 0x\(String(tag, radix: 16)), found 0x\(String(actual, radix: 16))")
        }
        guard buffer.count >= 2 else {
            throw PrivateKeyParseFailure.truncated("\(what) length")
        }

        var index = 1
        let lengthByte = buffer[index]
        index += 1

        let length: Int
        if lengthByte & 0x80 == 0 {
            length = Int(lengthByte)
        } else {
            let byteCount = Int(lengthByte & 0x7F)
            guard byteCount > 0, byteCount <= 4 else {
                throw PrivateKeyParseFailure.malformed("\(what) has an unsupported DER length form")
            }
            guard buffer.count >= index + byteCount else {
                throw PrivateKeyParseFailure.truncated("\(what) long-form length")
            }
            var accumulated = 0
            for offset in 0..<byteCount {
                accumulated = (accumulated << 8) | Int(buffer[index + offset])
            }
            index += byteCount
            length = accumulated
        }

        guard buffer.count >= index + length else {
            throw PrivateKeyParseFailure.truncated(
                "\(what) (claims \(length) bytes, \(buffer.count - index) available)")
        }
        let value = Array(buffer[index..<(index + length)])
        buffer = Array(buffer[(index + length)...])
        return value
    }
}
