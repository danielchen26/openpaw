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
import NIOSSH
import OpenPawTerminalCore

/// Validates SSH host keys against an injected trust store.
///
/// NIOSSH hands the offered key to ``validateHostKey(hostKey:validationCompletePromise:)`` during
/// key exchange, before authentication happens, so failing here guarantees no credential is ever
/// sent to an unverified peer.
///
/// The verdict type is `OpenPawTerminalCore.HostKeyVerdict`, and a `.changed` verdict is a hard
/// failure with no "continue anyway" path: it is indistinguishable from an interception.
public final class HostKeyValidator: NIOSSHClientServerAuthenticationDelegate, Sendable {
    private let verify: @Sendable (String, String) -> HostKeyVerdict

    /// - Parameter verify: Consulted with the `SHA256:`-prefixed fingerprint of the offered key.
    public init(verify: @escaping @Sendable (String) -> HostKeyVerdict) {
        self.verify = { _, fingerprint in verify(fingerprint) }
    }

    /// - Parameter verify: Consulted with the key's algorithm name and its `SHA256:` fingerprint.
    ///
    /// Pins are per algorithm in OpenSSH — a host legitimately offers an Ed25519 *and* an ECDSA key
    /// — so `HostRecord.verdict(forKeyType:fingerprint:)` needs both. Use this overload to feed it.
    public init(
        verify: @escaping @Sendable (_ keyType: String, _ fingerprint: String) -> HostKeyVerdict
    ) {
        self.verify = verify
    }

    public func validateHostKey(
        hostKey: NIOSSHPublicKey,
        validationCompletePromise: EventLoopPromise<Void>
    ) {
        let keyType = HostKeyValidator.keyType(of: hostKey)
        let fingerprint = HostKeyValidator.fingerprint(of: hostKey)

        switch self.verify(keyType, fingerprint) {
        case .trusted:
            validationCompletePromise.succeed(())

        case .unknown(let offered):
            // A distinct error so the UI can prompt once and, if the user accepts, pin the
            // fingerprint and reconnect. Nothing is trusted implicitly.
            validationCompletePromise.fail(TransportError.hostKeyUnknown(fingerprint: offered))

        case .changed(let expected, let actual):
            validationCompletePromise.fail(
                TransportError.hostKeyChanged(expected: expected, actual: actual))
        }
    }
}

// MARK: - Key identity

extension HostKeyValidator {
    /// The OpenSSH `SHA256:` fingerprint of a public key.
    ///
    /// OpenSSH hashes the raw SSH wire encoding of the key — the same blob that appears
    /// base64-encoded in an `authorized_keys` line — and renders the digest as unpadded base64.
    /// The formatting is delegated to `KnownHostEntry.format(sha256Digest:)` so the app and this
    /// transport cannot disagree about what a fingerprint looks like.
    public static func fingerprint(of key: NIOSSHPublicKey) -> String {
        guard let blob = self.wireFormat(of: key) else {
            // `String(openSSHPublicKey:)` always emits two space-joined base64 fields, so this is
            // unreachable; a marker beats crashing in the middle of key exchange.
            return "SHA256:<unencodable-host-key>"
        }
        return KnownHostEntry.fingerprint(forPublicKeyBlob: blob)
    }

    /// The key's SSH algorithm name, e.g. `ssh-ed25519` or `ecdsa-sha2-nistp256`.
    public static func keyType(of key: NIOSSHPublicKey) -> String {
        let openSSH = String(openSSHPublicKey: key)
        return String(openSSH.prefix(while: { $0 != " " }))
    }

    /// The raw SSH wire encoding of a public key.
    ///
    /// NIOSSH exposes no direct serializer, but `String(openSSHPublicKey:)` base64-encodes exactly
    /// this blob, so decoding its second field recovers the bytes without reimplementing it.
    static func wireFormat(of key: NIOSSHPublicKey) -> Data? {
        let openSSH = String(openSSHPublicKey: key)
        guard
            let encoded = openSSH.split(
                separator: " ", maxSplits: 2, omittingEmptySubsequences: true
            ).dropFirst().first
        else {
            return nil
        }
        return Data(base64Encoded: String(encoded))
    }
}
