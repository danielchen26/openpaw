import Foundation
import OpenPawSSH
import OpenPawTerminalCore
import XCTest

@testable import OpenPawApp

/// Dials a real sshd through the same objects the Connect button uses.
///
/// Every other suite here substitutes the transport, so nothing proves the production `SSHTransport` can complete a
/// handshake, authenticate from the keychain and run a command against a real server. Those are exactly the steps that
/// fail in the field, and a `ControlledTransport` cannot fail them.
///
/// Skipped unless the environment names a reachable host, so a normal test run stays hermetic:
///
///     OPENPAW_LIVE_HOST=127.0.0.1 OPENPAW_LIVE_USER=you OPENPAW_LIVE_KEY=/path/to/key
final class LiveSSHConnectionTests: XCTestCase {

    private struct LiveTarget {
        var host: String
        var port: Int
        var username: String
        var keyPath: String
    }

    private func liveTarget() throws -> LiveTarget {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["OPENPAW_LIVE_HOST"],
            let username = environment["OPENPAW_LIVE_USER"],
            let keyPath = environment["OPENPAW_LIVE_KEY"]
        else {
            throw XCTSkip("set OPENPAW_LIVE_HOST/USER/KEY to run the live SSH test")
        }
        let port = environment["OPENPAW_LIVE_PORT"].flatMap(Int.init) ?? 22
        return LiveTarget(host: host, port: port, username: username, keyPath: keyPath)
    }

    /// Loads the key into the keychain the app reads from, mirroring what the debug seeder does at launch.
    private func seedKey(_ target: LiveTarget) throws -> (KeychainStore, KeychainReference) {
        let keychain = KeychainStore(service: "dev.openpaw.app.ssh.livetest")
        let reference = try KeychainReference(identifier: "openpaw-live-test-key")
        let data = try Data(contentsOf: URL(fileURLWithPath: target.keyPath))
        try keychain.store(secret: data, for: reference, requireBiometry: false)
        addTeardownBlock { try? keychain.delete(reference) }
        return (keychain, reference)
    }

    private func record(_ target: LiveTarget, _ reference: KeychainReference) -> HostRecord {
        HostRecord(
            id: UUID(),
            nickname: "live",
            hostname: target.host,
            port: target.port,
            username: target.username,
            auth: .privateKey(reference: reference, passphraseRef: nil),
            preferredTransport: .ssh
        )
    }

    /// Trust-on-first-use, matching the sheet the user taps through: the first fingerprint is accepted and pinned, so
    /// the test exercises the same pinning code path rather than disabling verification.
    private func makeBackend(_ keychain: KeychainStore) -> (SSHTerminalBackend, Box<[String]>) {
        let pins = Box<[String]>([])
        let backend = SSHTerminalBackend(
            makeTransport: { _ in
                SSHTransport(
                    secretResolver: keychain,
                    hostKeyVerification: { fingerprint in
                        pins.set(pins.get() + [fingerprint])
                        return .trusted
                    }
                )
            },
            makeConfiguration: { $0.connectionConfiguration },
            onHostKeyProblem: { _ in }
        )
        return (backend, pins)
    }

    func testConnectsToRealHostAndRunsCommand() async throws {
        let target = try liveTarget()
        let (keychain, reference) = try seedKey(target)
        let (backend, pins) = makeBackend(keychain)

        try await backend.connect(host: record(target, reference))
        addTeardownBlock { await backend.disconnect() }

        // A real handshake always offers a host key; an empty pin list would mean verification never ran.
        XCTAssertFalse(pins.get().isEmpty, "host key verification did not run")

        let whoami = try await backend.run(command: "whoami")
        XCTAssertEqual(whoami, target.username)

        // Proves the shell is a live session on the far side rather than a replayed buffer.
        let marker = UUID().uuidString
        let echoed = try await backend.run(command: "echo \(marker)")
        XCTAssertEqual(echoed, marker)
    }

    /// Reproduces what a user hits when the host record names a key that is not in the keychain, which is the state
    /// of every fresh install: the record can be created in the editor, but nothing in the app imports the key.
    ///
    /// The failure must arrive as a thrown error the UI can show. If it escapes as a trap or an unhandled failure,
    /// the app disappears from under the user with no explanation.
    func testConnectingWithAMissingKeyFailsWithoutCrashing() async throws {
        let target = try liveTarget()
        let keychain = KeychainStore(service: "dev.openpaw.app.ssh.livetest")
        let reference = try KeychainReference(identifier: "openpaw-live-test-absent-key")
        try? keychain.delete(reference)
        let (backend, _) = makeBackend(keychain)

        do {
            try await backend.connect(host: record(target, reference))
            XCTFail("connecting with no key in the keychain should not report success")
        } catch {
            // Expected: the point is that it throws rather than trapping.
        }
    }

    func testRunSurfacesRemoteFailureExitStatus() async throws {
        let target = try liveTarget()
        let (keychain, reference) = try seedKey(target)
        let (backend, _) = makeBackend(keychain)

        try await backend.connect(host: record(target, reference))
        addTeardownBlock { await backend.disconnect() }

        // A failing remote command must not read as success; the exit status has to cross the transport intact.
        do {
            _ = try await backend.run(command: "exit 3")
            XCTFail("expected a nonzero exit to throw")
        } catch {
            // Expected.
        }
    }
}

/// Minimal mutable box so the verification callback, which must be `@Sendable`, can record what it saw.
final class Box<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Value) {
        lock.lock()
        defer { lock.unlock() }
        value = newValue
    }
}
