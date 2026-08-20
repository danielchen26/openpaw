//===----------------------------------------------------------------------===//
//
// This source file is part of the OpenPaw open source project.
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Crypto
import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import OpenPawTerminalCore
import Testing

@testable import OpenPawSSH

/// Generates real key material with `ssh-keygen` in a throwaway directory.
///
/// Using the reference implementation as the producer is the point: it means the parser is tested
/// against bytes OpenSSH actually writes, including its padding and `bcrypt` parameters, rather than
/// against a fixture that could encode the same misunderstanding as the parser.
struct SSHKeygen: ~Copyable {
    let directory: URL

    init() throws {
        self.directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("openpaw-keys-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: self.directory)
    }

    static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: "/usr/bin/ssh-keygen")
    }

    /// Generate a key pair and return the private key PEM and the public key line.
    func generate(
        type: String,
        bits: Int? = nil,
        passphrase: String = "",
        format: String? = nil,
        name: String = "key"
    ) throws -> (privatePEM: String, publicLine: String, privatePath: URL) {
        let path = self.directory.appendingPathComponent(name)
        var arguments = ["-t", type, "-N", passphrase, "-C", "\(name)@openpaw", "-f", path.path, "-q"]
        if let bits { arguments.append(contentsOf: ["-b", String(bits)]) }
        if let format { arguments.append(contentsOf: ["-m", format]) }

        try Self.run("/usr/bin/ssh-keygen", arguments)

        let privatePEM = try String(contentsOf: path, encoding: .utf8)
        let publicLine = try String(
            contentsOf: path.appendingPathExtension("pub"), encoding: .utf8)
        return (privatePEM, publicLine.trimmingCharacters(in: .whitespacesAndNewlines), path)
    }

    /// `ssh-keygen -l`'s fingerprint for a public key file: an oracle computed by OpenSSH itself.
    func fingerprint(ofPublicKeyAt path: URL) throws -> String {
        let output = try Self.capture("/usr/bin/ssh-keygen", ["-l", "-f", path.path])
        // Format: "<bits> SHA256:<base64> <comment> (<TYPE>)"
        let fields = output.split(separator: " ")
        guard fields.count >= 2, fields[1].hasPrefix("SHA256:") else {
            throw KeygenError.unparseableOutput(output)
        }
        return String(fields[1])
    }

    /// Write a public key line to a file so `ssh-keygen -l` can be pointed at it.
    func writePublicKey(_ line: String, name: String) throws -> URL {
        let path = self.directory.appendingPathComponent(name)
        try line.write(to: path, atomically: true, encoding: .utf8)
        return path
    }

    enum KeygenError: Error {
        case failed(String, Int32)
        case unparseableOutput(String)
    }

    @discardableResult
    static func run(_ executable: String, _ arguments: [String]) throws -> String {
        try self.capture(executable, arguments)
    }

    static func capture(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw KeygenError.failed(output, process.terminationStatus)
        }
        return output
    }
}

// MARK: - Host key fingerprints

@Suite("HostKeyValidator")
struct HostKeyValidatorTests {

    @Test("the SHA256 fingerprint matches what ssh-keygen computes for the same key")
    func fingerprintMatchesOpenSSH() throws {
        try #require(SSHKeygen.isAvailable, "ssh-keygen is required to provide an independent oracle")
        let keygen = try SSHKeygen()

        let generated = try keygen.generate(type: "ed25519", name: "fingerprint")
        let expected = try keygen.fingerprint(
            ofPublicKeyAt: generated.privatePath.appendingPathExtension("pub"))

        // Parse the public key back through NIOSSH and fingerprint it with our own code.
        let publicKey = try NIOSSHPublicKey(openSSHPublicKey: generated.publicLine)
        let actual = HostKeyValidator.fingerprint(of: publicKey)

        #expect(actual == expected)
        #expect(actual.hasPrefix("SHA256:"))
        // OpenSSH strips base64 padding.
        #expect(!actual.hasSuffix("="))
    }

    @Test("the fingerprint is the unpadded base64 SHA-256 of the raw wire blob")
    func fingerprintIsComputedFromTheWireBlob() throws {
        // Independent computation: take the base64 blob straight out of an authorized_keys line,
        // SHA-256 it, strip padding. This is the definition OpenSSH documents.
        let key = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey()).publicKey
        let openSSHLine = String(openSSHPublicKey: key)
        let blobBase64 = try #require(openSSHLine.split(separator: " ").dropFirst().first)
        let blob = try #require(Data(base64Encoded: String(blobBase64)))

        var digest = Data(SHA256.hash(data: blob)).base64EncodedString()
        while digest.hasSuffix("=") { digest.removeLast() }

        #expect(HostKeyValidator.fingerprint(of: key) == "SHA256:" + digest)
    }

    @Test("an unknown key fails with hostKeyUnknown carrying the offered fingerprint")
    func unknownKeyReportsItsFingerprint() async throws {
        let key = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey())
        let expected = HostKeyValidator.fingerprint(of: key.publicKey)

        let validator = HostKeyValidator(verify: { offered in .unknown(fingerprint: offered) })
        let error = try await #require(throws: TransportError.self) {
            try await Self.validate(key.publicKey, with: validator)
        }

        guard case .hostKeyUnknown(let fingerprint) = error else {
            Issue.record("expected .hostKeyUnknown, got \(error)")
            return
        }
        #expect(fingerprint == expected)
    }

    @Test("a changed key is blocked and reports both fingerprints")
    func changedKeyIsBlocked() async throws {
        let key = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey())
        let actualFingerprint = HostKeyValidator.fingerprint(of: key.publicKey)
        let pinned = "SHA256:AAAApinnedAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

        // A changed pin must fail without any prompt: this is the man-in-the-middle case.
        let validator = HostKeyValidator(verify: { offered in
            .changed(expected: pinned, actual: offered)
        })
        let error = try await #require(throws: TransportError.self) {
            try await Self.validate(key.publicKey, with: validator)
        }

        guard case .hostKeyChanged(let expected, let actual) = error else {
            Issue.record("expected .hostKeyChanged, got \(error)")
            return
        }
        #expect(expected == pinned)
        #expect(actual == actualFingerprint)
        // The two must differ, otherwise the verdict was meaningless.
        #expect(expected != actual)
    }

    @Test("a trusted key is accepted")
    func trustedKeyIsAccepted() async throws {
        let key = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey())
        let fingerprint = HostKeyValidator.fingerprint(of: key.publicKey)

        // The validator must be handed the fingerprint, not the key: assert on what it receives.
        let seen = LockedBox<String?>(nil)
        let validator = HostKeyValidator(verify: { offered in
            seen.set(offered)
            return offered == fingerprint ? .trusted : .unknown(fingerprint: offered)
        })

        try await Self.validate(key.publicKey, with: validator)
        #expect(seen.get() == fingerprint)
    }

    @Test("the keyType overload composes with HostRecord's per-algorithm pinning")
    func composesWithHostRecordPinning() async throws {
        // This is the seam between the two packages: OpenPawSSH extracts the algorithm name and
        // fingerprint from the offered key, and OpenPawTerminalCore decides the verdict.
        let ed25519 = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey())
        let pinnedFingerprint = HostKeyValidator.fingerprint(of: ed25519.publicKey)

        let record = HostRecord(
            nickname: "workstation",
            hostname: "127.0.0.1",
            username: "openpaw",
            auth: .password(reference: try KeychainReference(identifier: "pw")),
            knownHosts: [
                KnownHostEntry(
                    keyType: "ssh-ed25519",
                    fingerprint: pinnedFingerprint,
                    addedAt: Date(timeIntervalSince1970: 0)
                )
            ]
        )

        let validator = HostKeyValidator(verify: { keyType, fingerprint in
            record.verdict(forKeyType: keyType, fingerprint: fingerprint)
        })

        // The pinned key is trusted, and the algorithm name really was extracted correctly:
        // a wrong keyType would make HostRecord report `.unknown` instead.
        #expect(HostKeyValidator.keyType(of: ed25519.publicKey) == "ssh-ed25519")
        try await Self.validate(ed25519.publicKey, with: validator)

        // A different Ed25519 key is a *changed* key, because a pin exists for that algorithm.
        let impostor = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey())
        let changed = try await #require(throws: TransportError.self) {
            try await Self.validate(impostor.publicKey, with: validator)
        }
        guard case .hostKeyChanged(let expected, let actual) = changed else {
            Issue.record("expected .hostKeyChanged, got \(changed)")
            return
        }
        #expect(expected == pinnedFingerprint)
        #expect(actual == HostKeyValidator.fingerprint(of: impostor.publicKey))

        // An ECDSA key is *unknown* rather than changed: nothing is pinned for that algorithm.
        let ecdsa = NIOSSHPrivateKey(p256Key: P256.Signing.PrivateKey())
        #expect(HostKeyValidator.keyType(of: ecdsa.publicKey) == "ecdsa-sha2-nistp256")
        let unknown = try await #require(throws: TransportError.self) {
            try await Self.validate(ecdsa.publicKey, with: validator)
        }
        guard case .hostKeyUnknown = unknown else {
            Issue.record("expected .hostKeyUnknown for an unpinned algorithm, got \(unknown)")
            return
        }
    }

    /// Drive the NIOSSH delegate contract: succeed or fail a promise on a real event loop.
    private static func validate(
        _ key: NIOSSHPublicKey,
        with validator: HostKeyValidator
    ) async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let promise = group.next().makePromise(of: Void.self)
        validator.validateHostKey(hostKey: key, validationCompletePromise: promise)
        do {
            try await promise.futureResult.get()
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
        try? await group.shutdownGracefully()
    }
}

/// Minimal lock box, so a `@Sendable` verification callback can record what it saw.
final class LockedBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func get() -> Value {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.value
    }

    func set(_ newValue: Value) {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.value = newValue
    }
}
