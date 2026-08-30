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

/// A live, opt-in check that the transport the phone actually runs can reach a real host.
///
/// Skipped unless `OPENPAW_LIVE_HOST` is set, so CI and ordinary `swift test` runs are unaffected.
/// Point it at a machine over Tailscale and it will perform a genuine handshake, authenticate with
/// a real key, allocate a PTY and prove that bytes come back.
struct LiveTailscaleVerification {

    private struct FileSecretResolver: SSHSecretResolver {
        let secrets: [String: Data]

        func secret(for reference: KeychainReference) async throws -> Data {
            guard let value = self.secrets[reference.identifier] else {
                throw TransportError.authenticationFailed(
                    reason: "no secret for \(reference.identifier)")
            }
            return value
        }
    }

    private static var liveHost: String? {
        ProcessInfo.processInfo.environment["OPENPAW_LIVE_HOST"]
    }

    private static var liveUser: String {
        ProcessInfo.processInfo.environment["OPENPAW_LIVE_USER"] ?? NSUserName()
    }

    private static var liveKeyPath: String? {
        ProcessInfo.processInfo.environment["OPENPAW_LIVE_KEY"]
    }

    @Test("live: SSHTransport reaches the host, authenticates and returns PTY output")
    func liveConnectOverTailscale() async throws {
        guard let host = Self.liveHost, let keyPath = Self.liveKeyPath else {
            print("SKIP: set OPENPAW_LIVE_HOST and OPENPAW_LIVE_KEY to run the live check")
            return
        }

        let keyData = try Data(contentsOf: URL(fileURLWithPath: keyPath))
        let reference = try KeychainReference(identifier: "live-key")
        let resolver = FileSecretResolver(secrets: [reference.identifier: keyData])

        let fingerprints = FingerprintRecorder()
        let transport = SSHTransport(
            secretResolver: resolver,
            hostKeyVerification: { fingerprint in
                fingerprints.record(fingerprint)
                return .trusted
            })

        let configuration = ConnectionConfiguration(
            host: host,
            port: 22,
            username: Self.liveUser,
            auth: .privateKey(reference: reference, passphraseRef: nil),
            connectTimeout: .seconds(15))

        // Collect output before connecting so the banner is not missed.
        let collected = OutputCollector()
        let pump = Task {
            for await chunk in transport.output {
                await collected.append(chunk)
            }
        }

        try await transport.connect(configuration: configuration)

        // A PTY is live. Ask the remote shell to compute something, so the expected text exists
        // nowhere in what we typed: seeing it back can only mean the far end really ran the
        // command, rather than the terminal echoing our own keystrokes.
        let left = UInt32.random(in: 100_000...499_999)
        let right = UInt32.random(in: 100_000...499_999)
        let expected = "OPENPAW_LIVE_\(left + right)"
        try await transport.write(Data("echo OPENPAW_LIVE_$((\(left)+\(right)))\n".utf8))

        var sawMarker = false
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(100))
            if await collected.text().contains(expected) {
                sawMarker = true
                break
            }
        }

        let transcript = await collected.text()
        await transport.disconnect()
        pump.cancel()

        #expect(fingerprints.all().isEmpty == false, "the host key should have been offered")
        #expect(sawMarker, "expected \(expected) in PTY output; got: \(transcript.suffix(400))")

        print("LIVE HOST KEY: \(fingerprints.all().joined(separator: ", "))")
        print("LIVE TRANSCRIPT TAIL: \(transcript.suffix(200))")
    }

    private final class FingerprintRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []

        func record(_ value: String) {
            self.lock.lock()
            defer { self.lock.unlock() }
            self.values.append(value)
        }

        func all() -> [String] {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.values
        }
    }

    private actor OutputCollector {
        private var data = Data()

        func append(_ chunk: Data) {
            self.data.append(chunk)
        }

        func text() -> String {
            String(decoding: self.data, as: UTF8.self)
        }
    }
}
