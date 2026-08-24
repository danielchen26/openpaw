import XCTest

@testable import OpenPawTerminalCore

final class HostStoreTests: XCTestCase {

    private let pinnedAt = Date(timeIntervalSince1970: 1_755_697_800)

    private func store() -> HostStore {
        let ed25519 = KnownHostEntry(
            keyType: "ssh-ed25519", fingerprint: "SHA256:AAAA1111", addedAt: pinnedAt)
        let rsa = KnownHostEntry(
            keyType: "rsa-sha2-512", fingerprint: "SHA256:BBBB2222", addedAt: pinnedAt)
        var beta = Fixtures.host(lastSuccessful: .mosh, knownHosts: [ed25519, rsa])
        beta.preferredTransport = .eternalTerminal

        let alpha = HostRecord(
            id: UUID(uuidString: "2A2A2A2A-0000-4000-8000-000000000001")!,
            nickname: "alpha",
            hostname: "alpha.example.com",
            username: "root",
            auth: .agentForwarding,
            multiplexerPreference: .zellij,
            tags: [])
        return HostStore(hosts: [beta, alpha])
    }

    // MARK: export / import

    func testExportImportRoundTripsEverything() throws {
        let original = store()
        let data = try original.export()
        let restored = try HostStore.import(from: data)

        XCTAssertEqual(restored, original)
        XCTAssertEqual(restored.hosts.count, 2)
        XCTAssertEqual(restored.hosts[0].knownHosts, original.hosts[0].knownHosts)
        XCTAssertEqual(restored.hosts[0].preferredTransport, .eternalTerminal)
        XCTAssertEqual(restored.hosts[0].lastSuccessfulTransport, .mosh)
        XCTAssertEqual(restored.hosts[0].multiplexerPreference, .tmux)
        XCTAssertEqual(restored.hosts[0].tags, ["work", "arm64"])
        XCTAssertEqual(restored.hosts[1].auth, .agentForwarding)
    }

    func testHostAPIPortRoundTripsWhenPresent() throws {
        var original = store()
        original.hosts[0].hostAPIPort = 4_317

        let restored = try HostStore.import(from: try original.export())

        XCTAssertEqual(restored.hosts[0].hostAPIPort, 4_317)
        XCTAssertTrue(String(decoding: try original.export(), as: UTF8.self).contains("\"host_api_port\" : 4317"))
    }

    func testLegacyHostWithoutHostAPIPortDecodesAsNil() throws {
        let legacy = #"{"version":1,"hosts":[{"id":"2A2A2A2A-0000-4000-8000-000000000001","nickname":"legacy","hostname":"legacy.example.com","port":22,"username":"root","auth":{"method":"agent-forwarding"},"known_hosts":[],"tags":[]}]}"#

        let restored = try HostStore.import(from: Data(legacy.utf8))

        XCTAssertNil(restored.hosts[0].hostAPIPort)
    }

    func testHostAPIPortIsOptionalAndRoundTripsBackCompatibly() throws {
        var original = store()
        original.hosts[0].hostAPIPort = 4_317

        let restored = try HostStore.import(from: try original.export())
        XCTAssertEqual(restored.hosts[0].hostAPIPort, 4_317)
        XCTAssertNil(restored.hosts[1].hostAPIPort)

        let legacy = #"{"hosts":[{"auth":{"method":"agent-forwarding"},"hostname":"legacy","id":"2A2A2A2A-0000-4000-8000-000000000099","known_hosts":[],"nickname":"legacy","port":22,"tags":[],"username":"me"}],"version":1}"#
        let decoded = try HostStore.import(from: Data(legacy.utf8))
        XCTAssertNil(decoded.hosts[0].hostAPIPort)
    }

    func testExportCarriesReferencesAndNeverKeyMaterial() throws {
        let json = String(decoding: try store().export(), as: UTF8.self)

        XCTAssertTrue(json.contains("\"key_reference\" : \"kc:\\/\\/openpaw\\/beta\\/key\""))
        XCTAssertTrue(json.contains("\"passphrase_reference\""))
        XCTAssertTrue(json.contains("\"method\" : \"private-key\""))
        XCTAssertTrue(json.contains("\"last_successful_transport\" : \"mosh\""))
        XCTAssertFalse(json.contains("BEGIN"))
        XCTAssertFalse(json.contains("PRIVATE KEY"))
    }

    func testExportAlwaysStampsTheCurrentVersion() throws {
        var stale = store()
        stale.version = 0
        let restored = try HostStore.import(from: try stale.export())
        XCTAssertEqual(restored.version, HostStore.currentVersion)
    }

    func testImportRefusesInlinedPrivateKeyMaterial() throws {
        var json = String(decoding: try store().export(), as: UTF8.self)
        json = json.replacingOccurrences(
            of: "kc:\\/\\/openpaw\\/beta\\/key",
            with: "-----BEGIN OPENSSH PRIVATE KEY-----b3BlbnNzaA==-----END-----")

        XCTAssertThrowsError(try HostStore.import(from: Data(json.utf8))) { error in
            guard case HostStoreError.inlinedSecret = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
    }

    func testImportRejectsUnsupportedVersion() throws {
        var future = store()
        future.version = 99
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(future)
        XCTAssertThrowsError(try HostStore.import(from: data)) { error in
            XCTAssertEqual(error as? HostStoreError, .unsupportedVersion(99))
        }
    }

    func testKeychainReferenceValidation() {
        XCTAssertThrowsError(try KeychainReference(identifier: "  ")) { error in
            guard case HostStoreError.invalidReference = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
        XCTAssertThrowsError(
            try KeychainReference(identifier: String(repeating: "a", count: 300))
        ) { error in
            guard case HostStoreError.invalidReference = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
        XCTAssertThrowsError(try KeychainReference(identifier: "kc://a\nkc://b")) { error in
            guard case HostStoreError.inlinedSecret = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
        XCTAssertEqual(
            try KeychainReference(identifier: " kc://openpaw/a ").identifier, "kc://openpaw/a")
    }

    // MARK: mutation

    func testUpsertRemoveAndTrust() throws {
        var subject = store()
        let id = subject.hosts[0].id

        var renamed = subject.hosts[0]
        renamed.nickname = "beta-renamed"
        subject.upsert(renamed)
        XCTAssertEqual(subject.hosts.count, 2)
        XCTAssertEqual(subject[id]?.nickname, "beta-renamed")

        // Trusting a key type replaces the previous pin for that type only.
        let rotated = KnownHostEntry(
            keyType: "ssh-ed25519", fingerprint: "SHA256:CCCC3333", addedAt: pinnedAt)
        try subject.trust(rotated, for: id)
        XCTAssertEqual(subject[id]?.knownHosts.count, 2)
        XCTAssertEqual(
            subject[id]?.verdict(forKeyType: "ssh-ed25519", fingerprint: "SHA256:CCCC3333"),
            .trusted)
        XCTAssertEqual(
            subject[id]?.verdict(forKeyType: "rsa-sha2-512", fingerprint: "SHA256:BBBB2222"),
            .trusted)

        subject.remove(id: id)
        XCTAssertEqual(subject.hosts.count, 1)
        XCTAssertNil(subject[id])
        XCTAssertThrowsError(try subject.trust(rotated, for: id))
    }

    // MARK: host key verdicts

    func testVerdictTrustedUnknownAndChanged() {
        let host = store().hosts[0]

        XCTAssertEqual(
            host.verdict(forKeyType: "ssh-ed25519", fingerprint: "SHA256:AAAA1111"), .trusted)

        // Same key type, different fingerprint: this is the interception case
        // and must be a hard block.
        let changed = host.verdict(forKeyType: "ssh-ed25519", fingerprint: "SHA256:ZZZZ9999")
        XCTAssertEqual(
            changed, .changed(expected: "SHA256:AAAA1111", actual: "SHA256:ZZZZ9999"))
        XCTAssertTrue(changed.isBlocking)
        XCTAssertEqual(
            changed.description,
            "key changed, expected SHA256:AAAA1111 but got SHA256:ZZZZ9999")

        // A key type we have never pinned is merely unknown, not a change.
        let unknown = host.verdict(forKeyType: "ecdsa-sha2-nistp256", fingerprint: "SHA256:NEW")
        XCTAssertEqual(unknown, .unknown(fingerprint: "SHA256:NEW"))
        XCTAssertFalse(unknown.isBlocking)

        let unpinned = HostRecord(
            nickname: "fresh", hostname: "fresh.local", username: "dev", auth: .agentForwarding)
        XCTAssertEqual(
            unpinned.verdict(forKeyType: "ssh-ed25519", fingerprint: "SHA256:AAAA1111"),
            .unknown(fingerprint: "SHA256:AAAA1111"))
        XCTAssertFalse(HostKeyVerdict.trusted.isBlocking)
    }

    func testFingerprintFormatting() {
        // SHA-256 of the empty input, base64 with the padding stripped, which is
        // exactly what `ssh-keygen -lf` prints.
        XCTAssertEqual(
            KnownHostEntry.fingerprint(forPublicKeyBlob: Data()),
            "SHA256:47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU")
        XCTAssertEqual(
            KnownHostEntry.format(
                sha256Digest: Data(
                    base64Encoded: "47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=")!),
            "SHA256:47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU")

        let entry = KnownHostEntry(
            keyType: "ssh-ed25519", publicKeyBlob: Data("blob".utf8), addedAt: pinnedAt)
        XCTAssertTrue(entry.fingerprint.hasPrefix("SHA256:"))
        XCTAssertFalse(entry.fingerprint.contains("="))
        XCTAssertEqual(entry.fingerprint.count, "SHA256:".count + 43)
    }
}
