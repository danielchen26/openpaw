//===----------------------------------------------------------------------===//
//
// This source file is part of the OpenPaw open source project.
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Foundation
import OpenPawTerminalCore

#if canImport(Security)

    import Security

    #if canImport(LocalAuthentication)
        import LocalAuthentication
    #endif

    /// Stores SSH secrets in the platform keychain.
    ///
    /// Every item is a `kSecClassGenericPassword` in one service, keyed by the
    /// ``KeychainReference`` identifier that `AuthMethod` carries. Three protections are applied
    /// deliberately:
    ///
    /// * `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` — secrets never leave the device and are
    ///   unreadable while it is locked, so an iCloud Keychain sync or an encrypted backup cannot
    ///   carry a private key to another machine.
    /// * `kSecUseDataProtectionKeychain` — opts macOS into the same data-protection keychain iOS
    ///   uses, so behaviour and ACLs match across platforms instead of falling back to the older
    ///   file-based keychain. See ``usesDataProtectionKeychain`` for the entitlement it requires.
    /// * An optional `SecAccessControl` requiring biometry or the device passcode. Private keys are
    ///   non-exportable in the sense that matters: an item stored with `requireBiometry: true`
    ///   cannot be read without a fresh user presence check, so a compromised process cannot
    ///   silently exfiltrate it.
    public struct KeychainStore: SSHSecretResolver, Sendable {
        /// Keychain service under which all of this store's items live.
        public let service: String

        /// Prompt shown when an access-controlled item is read.
        public let authenticationPrompt: String

        /// Whether to use the modern data-protection keychain.
        ///
        /// This is the correct setting for the shipping iOS and macOS apps, and is the default.
        /// It requires the `keychain-access-groups` entitlement: a process without it — an unsigned
        /// binary, a plain command-line tool, a SwiftPM test bundle — gets
        /// `errSecMissingEntitlement` from every operation. Such callers must pass `false` and
        /// accept the older file-based keychain, which supports neither data-protection classes nor
        /// access-control ACLs.
        public let usesDataProtectionKeychain: Bool

        public init(
            service: String = "dev.openpaw.ssh",
            authenticationPrompt: String = "Unlock your SSH key",
            usesDataProtectionKeychain: Bool = true
        ) {
            self.service = service
            self.authenticationPrompt = authenticationPrompt
            self.usesDataProtectionKeychain = usesDataProtectionKeychain
        }

        /// Attributes identifying one item, shared by every operation.
        private func identity(of reference: KeychainReference) -> [String: Any] {
            var attributes: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: self.service,
                kSecAttrAccount as String: reference.identifier,
            ]
            if self.usesDataProtectionKeychain {
                attributes[kSecUseDataProtectionKeychain as String] = true
            }
            return attributes
        }

        // MARK: Writing

        /// Store `secret`, replacing any existing item for `reference`.
        ///
        /// - Parameter requireBiometry: When true the item is guarded by a `SecAccessControl`
        ///   requiring biometry or the passcode, so ``load(_:)`` triggers a user presence check.
        ///   Use it for private keys.
        public func store(
            secret: Data,
            for reference: KeychainReference,
            requireBiometry: Bool = false
        ) throws {
            guard !secret.isEmpty else {
                throw KeychainError.invalidSecret("refusing to store an empty secret")
            }

            // Delete first: SecItemAdd rejects duplicates, and SecItemUpdate cannot change an
            // item's access control, so replacing is the only way to honour a changed
            // `requireBiometry`.
            try? self.delete(reference)

            var attributes = self.identity(of: reference)
            attributes[kSecValueData as String] = secret

            if requireBiometry {
                var error: Unmanaged<CFError>?
                guard
                    let control = SecAccessControlCreateWithFlags(
                        nil,
                        kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                        .userPresence,
                        &error
                    )
                else {
                    throw KeychainError.accessControlUnavailable(
                        error?.takeRetainedValue().localizedDescription
                            ?? "SecAccessControlCreateWithFlags failed")
                }
                // An access control supersedes kSecAttrAccessible; setting both fails with
                // errSecParam.
                attributes[kSecAttrAccessControl as String] = control
            } else {
                attributes[kSecAttrAccessible as String] =
                    kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            }

            let status = SecItemAdd(attributes as CFDictionary, nil)
            guard status == errSecSuccess else {
                throw KeychainError.unexpectedStatus(operation: "store", status: status)
            }
        }

        // MARK: Reading

        /// Read the secret for `reference`.
        ///
        /// For an item stored with `requireBiometry: true` this blocks on a `LAContext`-backed user
        /// presence check, because the access control is evaluated by the Security framework during
        /// `SecItemCopyMatching`.
        public func load(_ reference: KeychainReference) throws -> Data {
            var query = self.identity(of: reference)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne

            #if canImport(LocalAuthentication)
                // `kSecUseOperationPrompt` is deprecated in favour of supplying our own context:
                // it keeps the prompt attributable to OpenPaw and carries the reason string.
                let context = LAContext()
                context.localizedReason = self.authenticationPrompt
                query[kSecUseAuthenticationContext as String] = context
            #endif

            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)

            switch status {
            case errSecSuccess:
                guard let data = item as? Data else {
                    throw KeychainError.unexpectedStatus(operation: "load", status: status)
                }
                return data
            case errSecItemNotFound:
                throw KeychainError.notFound(reference.identifier)
            case errSecUserCanceled, errSecAuthFailed:
                throw KeychainError.authenticationCancelled(reference.identifier)
            default:
                throw KeychainError.unexpectedStatus(operation: "load", status: status)
            }
        }

        /// Whether an item exists, without reading it.
        ///
        /// This deliberately does not request the data and forbids interaction, so it never
        /// triggers a biometry prompt: existence is metadata, not the secret.
        public func exists(_ reference: KeychainReference) -> Bool {
            var query = self.identity(of: reference)
            query[kSecReturnData as String] = false
            query[kSecMatchLimit as String] = kSecMatchLimitOne

            #if canImport(LocalAuthentication)
                // Replaces the deprecated `kSecUseAuthenticationUI: kSecUseAuthenticationUIFail`.
                let context = LAContext()
                context.interactionNotAllowed = true
                query[kSecUseAuthenticationContext as String] = context
            #endif

            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            // An access-controlled item reports `interactionNotAllowed` rather than `success` when
            // UI is suppressed, which still proves it is there.
            return status == errSecSuccess || status == errSecInteractionNotAllowed
        }

        // MARK: Deleting

        /// Delete the item for `reference`. Absent items are not an error, so teardown is safe.
        public func delete(_ reference: KeychainReference) throws {
            let status = SecItemDelete(self.identity(of: reference) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainError.unexpectedStatus(operation: "delete", status: status)
            }
        }

        // MARK: SSHSecretResolver

        public func secret(for reference: KeychainReference) async throws -> Data {
            try self.load(reference)
        }
    }

    /// Why a keychain operation failed.
    public enum KeychainError: Error, Sendable, Hashable, CustomStringConvertible {
        case notFound(String)
        case invalidSecret(String)
        case accessControlUnavailable(String)
        case authenticationCancelled(String)
        case unexpectedStatus(operation: String, status: OSStatus)

        /// True when the failure is the data-protection keychain's entitlement requirement.
        ///
        /// Callers that legitimately run unsigned — command-line tools, test bundles — use this to
        /// tell "this process may not use that keychain" from "the secret is not there".
        public var isMissingEntitlement: Bool {
            if case .unexpectedStatus(_, let status) = self {
                return status == errSecMissingEntitlement
            }
            return false
        }

        public var description: String {
            switch self {
            case .notFound(let account):
                return "no keychain item for \(account)"
            case .invalidSecret(let detail):
                return "invalid secret: \(detail)"
            case .accessControlUnavailable(let detail):
                return "could not create a keychain access control: \(detail)"
            case .authenticationCancelled(let account):
                return "authentication for \(account) was cancelled or failed"
            case .unexpectedStatus(let operation, let status):
                let message =
                    SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
                return "keychain \(operation) failed: \(message)"
            }
        }
    }

#endif
