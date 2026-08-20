//===----------------------------------------------------------------------===//
//
// This source file is part of the OpenPaw open source project.
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Foundation
import OpenPawTerminalCore
import Testing

@testable import OpenPawSSH

#if canImport(Security)

    import Security

    /// Exercises the real platform keychain.
    ///
    /// Each test uses a service name unique to the run and deletes everything it creates, so it can
    /// never collide with a developer's own items or with a concurrent run.
    ///
    /// The stores here pass `usesDataProtectionKeychain: false`. That is not a workaround hiding a
    /// defect: the data-protection keychain requires the `keychain-access-groups` entitlement, and a
    /// SwiftPM test bundle is unsigned, so every operation against it returns
    /// `errSecMissingEntitlement`. ``dataProtectionKeychainRequiresAnEntitlement`` asserts exactly
    /// that, which pins the reason down instead of leaving it as folklore. The read/write/delete
    /// behaviour is identical across both keychains and is genuinely exercised below.
    @Suite("KeychainStore against the real platform keychain", .serialized)
    struct KeychainStoreTests {

        /// A store scoped to this test run, on the keychain an unsigned binary may use.
        private func makeStore() -> KeychainStore {
            KeychainStore(
                service: "dev.openpaw.tests.\(UUID().uuidString)",
                usesDataProtectionKeychain: false
            )
        }

        private func reference(_ name: String) throws -> KeychainReference {
            try KeychainReference(identifier: name)
        }

        /// Whether this environment has a usable keychain at all.
        ///
        /// A headless machine with no login keychain fails every operation; that is an environment
        /// limitation rather than a defect, so those tests skip.
        private func keychainIsUsable(_ store: KeychainStore) -> Bool {
            guard let probe = try? self.reference("availability-probe") else { return false }
            defer { try? store.delete(probe) }
            do {
                try store.store(secret: Data("probe".utf8), for: probe)
                return try store.load(probe) == Data("probe".utf8)
            } catch {
                return false
            }
        }

        @Test("store, load, exists and delete round-trip a secret")
        func roundTrip() throws {
            let store = self.makeStore()
            try #require(self.keychainIsUsable(store), "no usable keychain in this environment")

            let reference = try self.reference("round-trip")
            let secret = Data("-----BEGIN OPENSSH PRIVATE KEY-----\nnot-really\n".utf8)

            defer { try? store.delete(reference) }

            #expect(!store.exists(reference))

            try store.store(secret: secret, for: reference)
            #expect(store.exists(reference))
            #expect(try store.load(reference) == secret)

            try store.delete(reference)
            #expect(!store.exists(reference))

            // Loading a deleted item is a specific error, not an empty result.
            let error = try #require(throws: KeychainError.self) {
                _ = try store.load(reference)
            }
            #expect(error == .notFound(reference.identifier))
        }

        @Test("storing twice replaces the value rather than failing on a duplicate")
        func storeReplaces() throws {
            let store = self.makeStore()
            try #require(self.keychainIsUsable(store), "no usable keychain in this environment")

            let reference = try self.reference("replace")
            defer { try? store.delete(reference) }

            try store.store(secret: Data("first".utf8), for: reference)
            try store.store(secret: Data("second".utf8), for: reference)

            // SecItemAdd rejects duplicates, so the implementation must delete first; without that
            // this would either throw errSecDuplicateItem or still return "first".
            #expect(try store.load(reference) == Data("second".utf8))
        }

        @Test("items in different services do not collide")
        func servicesAreIsolated() throws {
            let first = self.makeStore()
            let second = self.makeStore()
            try #require(self.keychainIsUsable(first), "no usable keychain in this environment")

            let reference = try self.reference("shared-name")
            defer {
                try? first.delete(reference)
                try? second.delete(reference)
            }

            try first.store(secret: Data("one".utf8), for: reference)
            #expect(first.exists(reference))
            // The same account name in a different service must be a different item.
            #expect(!second.exists(reference))

            try second.store(secret: Data("two".utf8), for: reference)
            #expect(try first.load(reference) == Data("one".utf8))
            #expect(try second.load(reference) == Data("two".utf8))
        }

        @Test("deleting an absent item succeeds, so teardown is always safe")
        func deletingAbsentItemIsNotAnError() throws {
            let store = self.makeStore()
            try #require(self.keychainIsUsable(store), "no usable keychain in this environment")

            // Idempotent deletion matters: every test here relies on it in `defer`.
            #expect(throws: Never.self) {
                try store.delete(try self.reference("never-created"))
            }
        }

        @Test("an empty secret is refused before it reaches the keychain")
        func emptySecretIsRefused() throws {
            let store = self.makeStore()
            let reference = try self.reference("empty")

            // No keychain needed: this must fail on validation, not on the Security call.
            let error = try #require(throws: KeychainError.self) {
                try store.store(secret: Data(), for: reference)
            }
            guard case .invalidSecret = error else {
                Issue.record("expected .invalidSecret, got \(error)")
                return
            }
        }

        @Test("the store satisfies SSHSecretResolver and resolves an AuthMethod's password")
        func resolvesCredentialsThroughTheProtocol() async throws {
            let store = self.makeStore()
            try #require(self.keychainIsUsable(store), "no usable keychain in this environment")

            let reference = try self.reference("password-for-auth")
            defer { try? store.delete(reference) }
            try store.store(secret: Data("s3cret".utf8), for: reference)

            // This is the path SSHTransport takes: AuthMethod -> keychain -> SSHCredential.
            let credentials = try await store.resolveCredentials(
                for: .password(reference: reference))
            #expect(credentials.count == 1)
            guard case .password(let password) = credentials[0] else {
                Issue.record("expected a password credential, got \(credentials[0])")
                return
            }
            #expect(password == "s3cret")
        }

        @Test("a stored private key is parsed straight out of the keychain")
        func resolvesAPrivateKeyFromTheKeychain() async throws {
            try #require(SSHKeygen.isAvailable)
            let store = self.makeStore()
            try #require(self.keychainIsUsable(store), "no usable keychain in this environment")

            let keygen = try SSHKeygen()
            let generated = try keygen.generate(type: "ed25519", name: "from-keychain")

            let reference = try self.reference("private-key")
            defer { try? store.delete(reference) }
            try store.store(secret: Data(generated.privatePEM.utf8), for: reference)

            // End to end: keychain bytes -> PEM -> OpenSSH container -> NIOSSHPrivateKey.
            let credentials = try await store.resolveCredentials(
                for: .privateKey(reference: reference, passphraseRef: nil))
            guard case .privateKey(let key) = try #require(credentials.first) else {
                Issue.record("expected a privateKey credential")
                return
            }
            let expected = try keygen.fingerprint(
                ofPublicKeyAt: generated.privatePath.appendingPathExtension("pub"))
            #expect(HostKeyValidator.fingerprint(of: key.publicKey) == expected)
        }

        @Test("an encrypted key plus its passphrase both come from the keychain")
        func resolvesAnEncryptedPrivateKeyWithStoredPassphrase() async throws {
            try #require(SSHKeygen.isAvailable)
            let store = self.makeStore()
            try #require(self.keychainIsUsable(store), "no usable keychain in this environment")

            let passphrase = "keychain-held-passphrase"
            let keygen = try SSHKeygen()
            let generated = try keygen.generate(
                type: "ed25519", passphrase: passphrase, name: "enc-from-keychain")

            let keyRef = try self.reference("enc-private-key")
            let passRef = try self.reference("enc-passphrase")
            defer {
                try? store.delete(keyRef)
                try? store.delete(passRef)
            }
            try store.store(secret: Data(generated.privatePEM.utf8), for: keyRef)
            try store.store(secret: Data(passphrase.utf8), for: passRef)

            let credentials = try await store.resolveCredentials(
                for: .privateKey(reference: keyRef, passphraseRef: passRef))
            guard case .privateKey(let key) = try #require(credentials.first) else {
                Issue.record("expected a privateKey credential")
                return
            }
            let expected = try keygen.fingerprint(
                ofPublicKeyAt: generated.privatePath.appendingPathExtension("pub"))
            #expect(HostKeyValidator.fingerprint(of: key.publicKey) == expected)
        }

        @Test("agent forwarding is reported as unsupported rather than silently doing nothing")
        func agentForwardingIsRejected() async throws {
            let store = self.makeStore()
            // NIOSSH implements no ssh-agent client, so there is genuinely nothing to offer.
            let error = try await #require(throws: TransportError.self) {
                _ = try await store.resolveCredentials(for: .agentForwarding)
            }
            guard case .authenticationFailed(let reason) = error else {
                Issue.record("expected .authenticationFailed, got \(error)")
                return
            }
            #expect(reason.lowercased().contains("agent"))
        }

        @Test("the data-protection keychain requires an entitlement this bundle does not have")
        func dataProtectionKeychainRequiresAnEntitlement() throws {
            // The default configuration, i.e. what the shipping app uses.
            let store = KeychainStore(service: "dev.openpaw.tests.\(UUID().uuidString)")
            let reference = try self.reference("data-protection")
            defer { try? store.delete(reference) }

            do {
                try store.store(secret: Data("guarded".utf8), for: reference)
                // A signed host with the entitlement: the same behaviour must hold there.
                #expect(store.exists(reference))
                #expect(try store.load(reference) == Data("guarded".utf8))
                try store.delete(reference)
                #expect(!store.exists(reference))
            } catch let error as KeychainError {
                // Unsigned test bundle: the flag really did reach Security and was refused for the
                // documented reason, which is what makes `usesDataProtectionKeychain: false`
                // necessary above rather than merely convenient.
                #expect(
                    error.isMissingEntitlement,
                    "expected errSecMissingEntitlement, got \(error)")
            }
        }

        @Test("a biometry-guarded item reports existence without prompting")
        func biometryGuardedItemDoesNotPromptForExistence() throws {
            let store = self.makeStore()
            try #require(self.keychainIsUsable(store), "no usable keychain in this environment")

            let reference = try self.reference("biometry-guarded")
            defer { try? store.delete(reference) }

            // Creating the access control, or storing with it, can legitimately fail where there is
            // no biometry and no passcode policy, or on the file keychain which has no ACL support.
            // Both are environment limits, so skip rather than fail.
            do {
                try store.store(
                    secret: Data("guarded".utf8), for: reference, requireBiometry: true)
            } catch let error as KeychainError {
                switch error {
                case .accessControlUnavailable, .unexpectedStatus:
                    return
                default:
                    throw error
                }
            }

            // `exists` must never trigger user presence: it asks for metadata only and forbids
            // interaction. If it prompted, this test would block instead of returning.
            #expect(store.exists(reference))

            // Deletion never requires authentication either, which is what makes cleanup reliable.
            #expect(throws: Never.self) { try store.delete(reference) }
            #expect(!store.exists(reference))
        }

        @Test("KeychainReference refuses inlined key material")
        func referenceRejectsInlinedSecrets() throws {
            // The point of referencing the keychain by identifier is that secrets cannot be
            // smuggled into persisted configuration. Verify the guard here, because this store is
            // the component that would otherwise receive them.
            #expect(throws: (any Error).self) {
                _ = try KeychainReference(
                    identifier:
                        "-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n-----END OPENSSH PRIVATE KEY-----"
                )
            }
            #expect(throws: (any Error).self) {
                _ = try KeychainReference(identifier: "")
            }
        }
    }

#endif
