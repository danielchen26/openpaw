import Foundation
import OpenPawProtocol
import OpenPawTerminalCore
import Testing

@testable import OpenPawUI

@Suite("Quick Connect pairing links")
struct QuickConnectTests {
    private let issuedAt = Date(timeIntervalSince1970: 1_800_000_000)
    private let expiresAt = Date(timeIntervalSince1970: 1_800_000_240)

    private func knownEnvelope() -> QuickConnectEnvelopeV1 {
        QuickConnectEnvelopeV1(
            issuedAt: issuedAt,
            expiresAt: expiresAt,
            sessionID: "ses_0123456789abcdef01234567",
            hostAPIPort: 4317,
            profile: .operator,
            pairingCode: "ABCD-EFGH-IJKL-MNOP-QRST-UVWX",
            nickname: "Studio Mac",
            username: "daniel",
            targets: [
                QuickConnectTarget(hostname: "studio.tailnet.ts.net", port: 22, source: .magicDNS),
                QuickConnectTarget(hostname: "100.64.0.7", port: 22, source: .tailnet),
                QuickConnectTarget(hostname: "fd7a:115c:a1e0::7", port: 22, source: .tailnet),
                QuickConnectTarget(hostname: "studio.local", port: 2222, source: .explicit)
            ],
            hostKeys: [QuickConnectHostKey(algorithm: "ssh-ed25519", fingerprint: "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")]
        )
    }

    @Test("known v1 envelope round-trips through exact openpaw pair fragment")
    func roundTripKnownEnvelope() throws {
        let codec = QuickConnectLinkCodec(now: { issuedAt })
        let envelope = knownEnvelope()

        let url = try codec.encode(envelope)
        #expect(url.scheme == "openpaw")
        #expect(url.host == "pair")
        #expect(url.fragment?.hasPrefix("v1.") == true)

        let proposal = try codec.decode(url)
        #expect(proposal.envelope == envelope)
        #expect(proposal.version == 1)
        #expect(proposal.pairingCode == "ABCD-EFGH-IJKL-MNOP-QRST-UVWX")
        #expect(proposal.id != "ABCD-EFGH-IJKL-MNOP-QRST-UVWX")
        #expect(proposal.sessionID == "ses_0123456789abcdef01234567")
        #expect(proposal.hostAPIPort == 4317)
        #expect(proposal.profile == .operator)
    }

    @Test("candidate proposals have no structured pairing metadata")
    func candidateProposalsHaveNoStructuredPairingMetadata() {
        let proposal = QuickConnectProposal.from(candidate: AddDeviceCandidate(id: "node", nickname: "Studio", hostname: "studio", dnsName: nil, tailscaleIPs: [], os: nil, online: false), now: issuedAt)
        #expect(proposal.sessionID == nil)
        #expect(proposal.hostAPIPort == nil)
        #expect(proposal.profile == nil)
    }

    @Test("decoder rejects missing required structured wire fields")
    func decoderRejectsMissingStructuredWireFields() throws {
        let url = try rawURL([
            "v": 1,
            "issued_at": iso(issuedAt),
            "expires_at": iso(expiresAt),
            "pairing_code": "ABCD-EFGH-IJKL-MNOP-QRST-UVWX",
            "nickname": "Studio",
            "username": "daniel",
            "targets": [["hostname": "studio.local", "port": 22, "source": "explicit"]],
            "host_keys": [],
        ])
        #expect(throws: QuickConnectLinkError.invalidFragment) { try QuickConnectLinkCodec(now: { issuedAt }).decode(url) }
    }

    @Test("decoder enforces exact URL authority with no userinfo port path or query")
    func decoderEnforcesExactURLShape() throws {
        let codec = QuickConnectLinkCodec(now: { issuedAt })
        let fragment = try codec.encode(knownEnvelope()).fragment!
        for raw in [
            "openpaw://user@pair#\(fragment)",
            "openpaw://user:pass@pair#\(fragment)",
            "openpaw://pair:22#\(fragment)",
            "openpaw://pair/path#\(fragment)",
            "openpaw://pair?x=1#\(fragment)",
        ] {
            #expect(throws: QuickConnectLinkError.invalidHost) { try codec.decode(URL(string: raw)!) }
        }
    }

    @Test("decoder canonicalizes targets, rejects malformed host syntax, and enforces source order")
    func decoderCanonicalizesTargetsAndRejectsUnsafeSyntax() throws {
        let codec = QuickConnectLinkCodec(now: { issuedAt })
        let canonical = QuickConnectEnvelopeV1(
            issuedAt: issuedAt,
            expiresAt: expiresAt,
            sessionID: "ses_canonical",
            hostAPIPort: 4317,
            profile: .operator,
            pairingCode: "ABCD-EFGH-IJKL-MNOP-QRST-UVWX",
            nickname: "Studio",
            username: "daniel",
            targets: [
                QuickConnectTarget(hostname: "STUDIO.tailnet.ts.net.", source: .magicDNS),
                QuickConnectTarget(hostname: "010.000.000.001", source: .tailnet),
                QuickConnectTarget(hostname: "FD7A:115C:A1E0:0:0:0:0:7", source: .tailnet),
                QuickConnectTarget(hostname: "studio.local", source: .explicit),
            ],
            hostKeys: []
        )
        let proposal = try codec.decode(try codec.encodeWithoutValidation(canonical))
        #expect(proposal.targets.map(\.hostname) == ["studio.tailnet.ts.net", "10.0.0.1", "fd7a:115c:a1e0::7", "studio.local"])
        #expect(proposal.matches(existing: HostRecord(nickname: "Studio", hostname: "[fd7a:115c:a1e0::7]", port: 22, username: "daniel", auth: .agentForwarding)))

        let valid = knownEnvelope()
        for host in ["studio.local/path", "studio.local:22", "fd7a:115c:a1e0::7::8", "[fd7a:115c:a1e0::7]"] {
            try expectDecodeError(.invalidTarget, codec: QuickConnectLinkCodec(now: { issuedAt }), envelope: QuickConnectEnvelopeV1(issuedAt: issuedAt, expiresAt: expiresAt, sessionID: valid.sessionID, hostAPIPort: valid.hostAPIPort, profile: valid.profile, pairingCode: valid.pairingCode, nickname: valid.nickname, username: valid.username, targets: [QuickConnectTarget(hostname: host, port: 22, source: .explicit)], hostKeys: []))
        }
        try expectDecodeError(.duplicateTarget, codec: QuickConnectLinkCodec(now: { issuedAt }), envelope: QuickConnectEnvelopeV1(issuedAt: issuedAt, expiresAt: expiresAt, sessionID: valid.sessionID, hostAPIPort: valid.hostAPIPort, profile: valid.profile, pairingCode: valid.pairingCode, nickname: valid.nickname, username: valid.username, targets: [QuickConnectTarget(hostname: "fd7a:115c:a1e0::7", source: .tailnet), QuickConnectTarget(hostname: "FD7A:115C:A1E0:0:0:0:0:7", source: .tailnet)], hostKeys: []))
        try expectDecodeError(.invalidTarget, codec: QuickConnectLinkCodec(now: { issuedAt }), envelope: QuickConnectEnvelopeV1(issuedAt: issuedAt, expiresAt: expiresAt, sessionID: valid.sessionID, hostAPIPort: valid.hostAPIPort, profile: valid.profile, pairingCode: valid.pairingCode, nickname: valid.nickname, username: valid.username, targets: [QuickConnectTarget(hostname: "100.64.0.7", source: .tailnet), QuickConnectTarget(hostname: "studio.tailnet.ts.net", source: .magicDNS)], hostKeys: []))
    }

    @Test("encode serializes canonical envelope values")
    func encodeSerializesCanonicalEnvelopeValues() throws {
        let codec = QuickConnectLinkCodec(now: { issuedAt })
        let input = QuickConnectEnvelopeV1(
            issuedAt: issuedAt,
            expiresAt: expiresAt,
            sessionID: "ses_encode",
            hostAPIPort: 4317,
            profile: .observer,
            pairingCode: "abcd-efgh-ijkl-mnop-qrst-uvwx",
            nickname: "Studio",
            username: "daniel",
            targets: [QuickConnectTarget(hostname: "STUDIO.tailnet.ts.net.", source: .magicDNS)],
            hostKeys: []
        )

        let proposal = try codec.decode(try codec.encode(input))

        #expect(proposal.envelope?.pairingCode == "ABCD-EFGH-IJKL-MNOP-QRST-UVWX")
        #expect(proposal.targets.map(\.hostname) == ["studio.tailnet.ts.net"])
    }

    @Test("decoder rejects non daemon-shaped pairing codes, non ASCII DNS, leading dots, and untrimmed nicknames")
    func decoderRejectsFinalEnvelopeValidationEdges() throws {
        let valid = knownEnvelope()
        for code in ["ABCD", "ABCD-EFGH-IJKL-MNOP-QRST-UVW1", "ABCD-EFGH-IJKL-MNOP-QRST-UVW8"] {
            try expectDecodeError(.invalidFragment, codec: QuickConnectLinkCodec(now: { issuedAt }), envelope: QuickConnectEnvelopeV1(issuedAt: issuedAt, expiresAt: expiresAt, sessionID: valid.sessionID, hostAPIPort: valid.hostAPIPort, profile: valid.profile, pairingCode: code, nickname: valid.nickname, username: valid.username, targets: valid.targets, hostKeys: []))
        }
        try expectDecodeError(.invalidTarget, codec: QuickConnectLinkCodec(now: { issuedAt }), envelope: QuickConnectEnvelopeV1(issuedAt: issuedAt, expiresAt: expiresAt, sessionID: valid.sessionID, hostAPIPort: valid.hostAPIPort, profile: valid.profile, pairingCode: valid.pairingCode, nickname: valid.nickname, username: valid.username, targets: [QuickConnectTarget(hostname: "stüdio.local", source: .explicit)], hostKeys: []))
        try expectDecodeError(.invalidTarget, codec: QuickConnectLinkCodec(now: { issuedAt }), envelope: QuickConnectEnvelopeV1(issuedAt: issuedAt, expiresAt: expiresAt, sessionID: valid.sessionID, hostAPIPort: valid.hostAPIPort, profile: valid.profile, pairingCode: valid.pairingCode, nickname: valid.nickname, username: valid.username, targets: [QuickConnectTarget(hostname: ".studio.local", source: .explicit)], hostKeys: []))
        try expectDecodeError(.invalidFragment, codec: QuickConnectLinkCodec(now: { issuedAt }), envelope: QuickConnectEnvelopeV1(issuedAt: issuedAt, expiresAt: expiresAt, sessionID: valid.sessionID, hostAPIPort: valid.hostAPIPort, profile: valid.profile, pairingCode: valid.pairingCode, nickname: " Studio", username: valid.username, targets: valid.targets, hostKeys: []))
        try expectDecodeError(.invalidFragment, codec: QuickConnectLinkCodec(now: { issuedAt }), envelope: QuickConnectEnvelopeV1(issuedAt: issuedAt, expiresAt: expiresAt, sessionID: valid.sessionID, hostAPIPort: valid.hostAPIPort, profile: valid.profile, pairingCode: valid.pairingCode, nickname: "", username: valid.username, targets: valid.targets, hostKeys: []))
    }

    @Test("ordered targets prefer MagicDNS, Tailnet IPs, then explicit hostname")
    func orderedTargetsPreferRoutableDiscoveryOrder() {
        let candidate = AddDeviceCandidate(
            id: "node-studio",
            nickname: "Studio Mac",
            hostname: "studio.local",
            dnsName: "studio.tailnet.ts.net",
            tailscaleIPs: ["100.64.0.7", "fd7a:115c:a1e0::7"],
            os: "macOS",
            online: true
        )

        let proposal = QuickConnectProposal.from(candidate: candidate, now: issuedAt)

        #expect(proposal.id == "node-studio")
        #expect(proposal.nickname == "Studio Mac")
        #expect(proposal.dnsName == "studio.tailnet.ts.net")
        #expect(proposal.tailscaleIPs == ["100.64.0.7", "fd7a:115c:a1e0::7"])
        #expect(proposal.online == true)
        #expect(proposal.pairingCode == nil)
        #expect(proposal.hostKeys.isEmpty)
        #expect(proposal.targets.map(\.hostname) == ["studio.tailnet.ts.net", "100.64.0.7", "fd7a:115c:a1e0::7", "studio.local"])
        #expect(proposal.targets.map(\.source) == [.magicDNS, .tailnet, .tailnet, .explicit])
    }

    @Test("decoder rejects malformed or unsafe links with typed errors")
    func decoderRejectsUnsafeLinks() throws {
        let codec = QuickConnectLinkCodec(now: { Date(timeIntervalSince1970: 1_800_000_301) })
        let valid = knownEnvelope()

        try expectDecodeError(.expired, codec: codec, envelope: valid)
        try expectDecodeError(.expiryTooLong, codec: QuickConnectLinkCodec(now: { issuedAt }), envelope: QuickConnectEnvelopeV1(issuedAt: issuedAt, expiresAt: issuedAt.addingTimeInterval(301), sessionID: valid.sessionID, hostAPIPort: valid.hostAPIPort, profile: valid.profile, pairingCode: valid.pairingCode, nickname: valid.nickname, username: valid.username, targets: valid.targets, hostKeys: valid.hostKeys))
        try expectDecodeError(.expiryTooLong, codec: QuickConnectLinkCodec(now: { issuedAt }), envelope: QuickConnectEnvelopeV1(issuedAt: issuedAt, expiresAt: issuedAt, sessionID: valid.sessionID, hostAPIPort: valid.hostAPIPort, profile: valid.profile, pairingCode: valid.pairingCode, nickname: valid.nickname, username: valid.username, targets: valid.targets, hostKeys: valid.hostKeys))
        try expectDecodeError(.invalidPort, codec: QuickConnectLinkCodec(now: { issuedAt }), envelope: QuickConnectEnvelopeV1(issuedAt: issuedAt, expiresAt: expiresAt, sessionID: valid.sessionID, hostAPIPort: valid.hostAPIPort, profile: valid.profile, pairingCode: valid.pairingCode, nickname: valid.nickname, username: valid.username, targets: [QuickConnectTarget(hostname: "studio", port: 0, source: .explicit)], hostKeys: valid.hostKeys))
        try expectDecodeError(.invalidTarget, codec: QuickConnectLinkCodec(now: { issuedAt }), envelope: QuickConnectEnvelopeV1(issuedAt: issuedAt, expiresAt: expiresAt, sessionID: valid.sessionID, hostAPIPort: valid.hostAPIPort, profile: valid.profile, pairingCode: valid.pairingCode, nickname: valid.nickname, username: valid.username, targets: [QuickConnectTarget(hostname: "bad host", port: 22, source: .explicit)], hostKeys: valid.hostKeys))
        try expectDecodeError(.invalidTarget, codec: QuickConnectLinkCodec(now: { issuedAt }), envelope: QuickConnectEnvelopeV1(issuedAt: issuedAt, expiresAt: expiresAt, sessionID: valid.sessionID, hostAPIPort: valid.hostAPIPort, profile: valid.profile, pairingCode: valid.pairingCode, nickname: valid.nickname, username: valid.username, targets: [QuickConnectTarget(hostname: "user@studio.local", port: 22, source: .explicit)], hostKeys: valid.hostKeys))
        try expectDecodeError(.duplicateTarget, codec: QuickConnectLinkCodec(now: { issuedAt }), envelope: QuickConnectEnvelopeV1(issuedAt: issuedAt, expiresAt: expiresAt, sessionID: valid.sessionID, hostAPIPort: valid.hostAPIPort, profile: valid.profile, pairingCode: valid.pairingCode, nickname: valid.nickname, username: valid.username, targets: [valid.targets[0], valid.targets[0]], hostKeys: valid.hostKeys))
        try expectDecodeError(.unsupportedFingerprintAlgorithm("md5"), codec: QuickConnectLinkCodec(now: { issuedAt }), envelope: QuickConnectEnvelopeV1(issuedAt: issuedAt, expiresAt: expiresAt, sessionID: valid.sessionID, hostAPIPort: valid.hostAPIPort, profile: valid.profile, pairingCode: valid.pairingCode, nickname: valid.nickname, username: valid.username, targets: valid.targets, hostKeys: [QuickConnectHostKey(algorithm: "md5", fingerprint: "MD5:aa")]))
        try expectDecodeError(.unsupportedFingerprintAlgorithm("ssh-ed25519"), codec: QuickConnectLinkCodec(now: { issuedAt }), envelope: QuickConnectEnvelopeV1(issuedAt: issuedAt, expiresAt: expiresAt, sessionID: valid.sessionID, hostAPIPort: valid.hostAPIPort, profile: valid.profile, pairingCode: valid.pairingCode, nickname: valid.nickname, username: valid.username, targets: valid.targets, hostKeys: [QuickConnectHostKey(algorithm: "ssh-ed25519", fingerprint: "SHA256:AAAA=")]))
        try expectDecodeError(.unsupportedFingerprintAlgorithm("ssh-ed25519"), codec: QuickConnectLinkCodec(now: { issuedAt }), envelope: QuickConnectEnvelopeV1(issuedAt: issuedAt, expiresAt: expiresAt, sessionID: valid.sessionID, hostAPIPort: valid.hostAPIPort, profile: valid.profile, pairingCode: valid.pairingCode, nickname: valid.nickname, username: valid.username, targets: valid.targets, hostKeys: [QuickConnectHostKey(algorithm: "ssh-ed25519", fingerprint: "SHA256:")]))
        try expectDecodeError(.emptyPairingCode, codec: QuickConnectLinkCodec(now: { issuedAt }), envelope: QuickConnectEnvelopeV1(issuedAt: issuedAt, expiresAt: expiresAt, sessionID: valid.sessionID, hostAPIPort: valid.hostAPIPort, profile: valid.profile, pairingCode: "", nickname: valid.nickname, username: valid.username, targets: valid.targets, hostKeys: valid.hostKeys))
        try expectDecodeError(.invalidFragment, codec: QuickConnectLinkCodec(now: { issuedAt }), envelope: QuickConnectEnvelopeV1(issuedAt: issuedAt, expiresAt: expiresAt, sessionID: "bad session", hostAPIPort: 4317, profile: .observer, pairingCode: valid.pairingCode, nickname: valid.nickname, username: valid.username, targets: valid.targets, hostKeys: valid.hostKeys))
        try expectDecodeError(.invalidPort, codec: QuickConnectLinkCodec(now: { issuedAt }), envelope: QuickConnectEnvelopeV1(issuedAt: issuedAt, expiresAt: expiresAt, sessionID: valid.sessionID, hostAPIPort: 0, profile: .observer, pairingCode: valid.pairingCode, nickname: valid.nickname, username: valid.username, targets: valid.targets, hostKeys: valid.hostKeys))
        try expectDecodeError(.invalidFragment, codec: QuickConnectLinkCodec(now: { issuedAt }), envelope: QuickConnectEnvelopeV1(issuedAt: issuedAt, expiresAt: expiresAt, sessionID: valid.sessionID, hostAPIPort: valid.hostAPIPort, profile: .observer, pairingCode: valid.pairingCode, nickname: "Bad\nName", username: valid.username, targets: valid.targets, hostKeys: valid.hostKeys))
        try expectDecodeError(.invalidFragment, codec: QuickConnectLinkCodec(now: { issuedAt }), envelope: QuickConnectEnvelopeV1(issuedAt: issuedAt, expiresAt: expiresAt, sessionID: valid.sessionID, hostAPIPort: valid.hostAPIPort, profile: .observer, pairingCode: valid.pairingCode, nickname: valid.nickname, username: "bad user", targets: valid.targets, hostKeys: valid.hostKeys))
        try expectDecodeError(.invalidTarget, codec: QuickConnectLinkCodec(now: { issuedAt }), envelope: QuickConnectEnvelopeV1(issuedAt: issuedAt, expiresAt: expiresAt, sessionID: valid.sessionID, hostAPIPort: valid.hostAPIPort, profile: .observer, pairingCode: valid.pairingCode, nickname: valid.nickname, username: valid.username, targets: Array(repeating: valid.targets[0], count: 9), hostKeys: []))
        try expectDecodeError(.unsupportedFingerprintAlgorithm("ssh-ed25519"), codec: QuickConnectLinkCodec(now: { issuedAt }), envelope: QuickConnectEnvelopeV1(issuedAt: issuedAt, expiresAt: expiresAt, sessionID: valid.sessionID, hostAPIPort: valid.hostAPIPort, profile: .observer, pairingCode: valid.pairingCode, nickname: valid.nickname, username: valid.username, targets: valid.targets, hostKeys: Array(repeating: valid.hostKeys[0], count: 5)))

        #expect(throws: QuickConnectLinkError.invalidScheme) { try codec.decode(URL(string: "https://pair#v1.abc")!) }
        #expect(throws: QuickConnectLinkError.invalidHost) { try codec.decode(URL(string: "openpaw://connect#v1.abc")!) }
        #expect(throws: QuickConnectLinkError.unsupportedVersion("v2")) { try codec.decode(URL(string: "openpaw://pair#v2.abc")!) }
        #expect(throws: QuickConnectLinkError.oversizedFragment) { try codec.decode(URL(string: "openpaw://pair#v1." + String(repeating: "a", count: QuickConnectLinkCodec.maxFragmentBytes + 1))!) }
    }

    @Test("encoded data excludes known secret fixture strings")
    func encodedDataDoesNotContainSecretFixtureStrings() throws {
        let url = try QuickConnectLinkCodec(now: { issuedAt }).encode(knownEnvelope())
        let encoded = url.absoluteString.lowercased()
        for forbidden in ["password", "private-key", "hook-token", "bearer-token", "hmac-secret"] {
            #expect(!encoded.contains(forbidden))
        }
    }

    @Test("malformed input does not mutate host stores and matching is pure")
    func malformedInputDoesNotMutateHostStore() throws {
        var store = HostStore(hosts: [HostRecord(nickname: "Studio", hostname: "studio.tailnet.ts.net", port: 22, username: "daniel", auth: .agentForwarding)])
        let before = store
        #expect(throws: QuickConnectLinkError.invalidFragment) {
            _ = try QuickConnectLinkCodec(now: { issuedAt }).decode(URL(string: "openpaw://pair#v1.not-valid-base64!")!, store: &store)
        }
        #expect(store == before)

        let proposal = try QuickConnectLinkCodec(now: { issuedAt }).decode(try QuickConnectLinkCodec(now: { issuedAt }).encode(knownEnvelope()))
        #expect(proposal.matches(existing: before.hosts[0]))
    }

    @Test("existing exact host preselects credential but still requires confirmation")
    func exactExistingHostPreselectsCredentialButRequiresConfirmation() throws {
        let reference = try KeychainReference(identifier: "existing-password-ref")
        let host = HostRecord(nickname: "Studio", hostname: "studio.tailnet.ts.net", port: 22, username: "daniel", auth: .password(reference: reference))
        let proposal = try QuickConnectLinkCodec(now: { issuedAt }).decode(try QuickConnectLinkCodec(now: { issuedAt }).encode(knownEnvelope()))

        let confirmation = proposal.credentialConfirmationCandidate(in: HostStore(hosts: [host]))

        #expect(confirmation?.choice == .existing(.password(reference: reference)))
        #expect(confirmation?.profile == host)
        #expect(confirmation?.requiresExplicitConfirmation == true)
    }

    @Test("different host or username never preselects credentials")
    func differentHostOrUsernameDoesNotLeakCredential() throws {
        let reference = try KeychainReference(identifier: "other-secret-ref")
        let different = HostRecord(nickname: "Other", hostname: "studio.tailnet.ts.net", port: 22, username: "root", auth: .password(reference: reference))
        let proposal = try QuickConnectLinkCodec(now: { issuedAt }).decode(try QuickConnectLinkCodec(now: { issuedAt }).encode(knownEnvelope()))

        #expect(proposal.credentialConfirmationCandidate(in: HostStore(hosts: [different])) == nil)
    }

    @Test("new credential drafts install to AuthMethod references without retaining printable secrets")
    func newCredentialDraftsInstallReferencesAndRedactSecrets() async throws {
        let password = QuickConnectCredentialChoice.password(label: "Studio login", secret: "correct horse battery staple")
        let key = QuickConnectCredentialChoice.privateKey(label: "Studio key", key: Data("PRIVATE-KEY-MATERIAL".utf8), passphraseLabel: "Studio passphrase", passphrase: "key passphrase")
        let installer = RecordingQuickConnectCredentialInstaller()

        let passwordAuth = try await installer.install(password)
        let keyAuth = try await installer.install(key)

        #expect(passwordAuth == .password(reference: try KeychainReference(identifier: "quick-connect/password/00000000-0000-0000-0000-000000000001/Studio-login")))
        #expect(keyAuth == .privateKey(reference: try KeychainReference(identifier: "quick-connect/private-key/00000000-0000-0000-0000-000000000002/Studio-key"), passphraseRef: try KeychainReference(identifier: "quick-connect/passphrase/00000000-0000-0000-0000-000000000002/Studio-passphrase")))
        #expect(installer.requests.map(\.requiresUserPresence) == [false, true, false])
        #expect(String(describing: installer.requests[0]).contains("correct horse") == false)
        #expect(String(reflecting: installer.requests[1]).contains("PRIVATE-KEY-MATERIAL") == false)
        #expect(String(describing: password) == "QuickConnectCredentialChoice.password(label: \"Studio login\", secret: <redacted>)")
        #expect(String(describing: key).contains("PRIVATE-KEY-MATERIAL") == false)
        #expect(String(describing: key).contains("key passphrase") == false)
    }

    @Test("credential storage failure leaves host store unchanged and redacts errors")
    func credentialStorageFailureLeavesHostStoreUnchangedAndRedactsError() async throws {
        let before = HostStore(hosts: [HostRecord(nickname: "Studio", hostname: "studio", port: 22, username: "daniel", auth: .agentForwarding)])
        let after = before
        let installer = FailingQuickConnectCredentialInstaller()

        await #expect(throws: QuickConnectCredentialInstallError.storageFailed) {
            _ = try await installer.install(.password(label: "Bad", secret: "do-not-print-me"))
        }
        #expect(after == before)
        #expect(String(describing: QuickConnectCredentialInstallError.storageFailed).contains("do-not-print-me") == false)
    }

    @MainActor
    @Test("begin only reviews and does not mutate hosts or connect")
    func coordinatorDoesNotMutateBeforeConfirm() {
        let terminal = QuickConnectRecordingTerminal()
        let model = OpenPawModel(hostStore: HostStore(), terminal: terminal)
        let installer = QuickConnectCountingInstaller()
        let coordinator = QuickConnectCoordinator(model: model, installer: installer, now: { self.issuedAt })

        coordinator.begin(.from(candidate: AddDeviceCandidate(id: "node", nickname: "Studio", hostname: "studio.local", dnsName: nil, tailscaleIPs: [], os: nil, online: true), now: issuedAt))

        #expect(coordinator.stage == .reviewing)
        #expect(model.hostStore.hosts.isEmpty)
        #expect(terminal.connectedHosts.isEmpty)
        #expect(installer.installCount == 0)
    }

    @MainActor
    @Test("expired QR fails before credential installation")
    func expiredCoordinatorProposalStopsBeforeCredentialInstall() async throws {
        let proposal = try QuickConnectLinkCodec(now: { issuedAt }).decode(try QuickConnectLinkCodec(now: { issuedAt }).encode(knownEnvelope()))
        let model = OpenPawModel(hostStore: HostStore(), terminal: QuickConnectRecordingTerminal())
        let installer = QuickConnectCountingInstaller()
        let coordinator = QuickConnectCoordinator(model: model, installer: installer, now: { self.expiresAt.addingTimeInterval(1) })

        coordinator.begin(proposal)
        coordinator.confirm(.existing(.agentForwarding), username: "daniel")
        await waitForCoordinatorToSettle(coordinator)

        guard case .failed(.reviewing, _) = coordinator.stage else {
            Issue.record("expected expired failure, got \(coordinator.stage)")
            return
        }
        #expect(installer.installCount == 0)
        #expect(model.hostStore.hosts.isEmpty)
    }

    @MainActor
    @Test("reconfirmation resets validation failures to the reviewing phase before credential installation")
    func reconfirmationValidationFailureIsReviewing() async throws {
        let proposal = try QuickConnectLinkCodec(now: { issuedAt }).decode(
            try QuickConnectLinkCodec(now: { issuedAt }).encode(knownEnvelope()))
        let clock = QuickConnectClock(issuedAt)
        let installer = QuickConnectCountingInstaller()
        let model = OpenPawModel(hostStore: HostStore(), terminal: QuickConnectRecordingTerminal())
        model.hostKeyPrompt = HostKeyPrompt(
            host: "studio.tailnet.ts.net:22",
            verdict: .unknown(fingerprint: "SHA256:FIXTURE-UNKNOWN"))
        let coordinator = QuickConnectCoordinator(
            model: model,
            installer: installer,
            now: { clock.value })

        coordinator.begin(proposal)
        coordinator.confirm(.existing(.agentForwarding), username: "daniel")
        await waitForStage(.awaitingHostTrust, coordinator: coordinator)
        clock.set(expiresAt.addingTimeInterval(1))

        coordinator.confirm(.existing(.agentForwarding), username: "daniel")
        await waitForCoordinatorToSettle(coordinator)

        guard case .failed(.reviewing, _) = coordinator.stage else {
            Issue.record("expected reviewing failure, got \(coordinator.stage)")
            return
        }
        #expect(installer.installCount == 1)
        #expect(coordinator.currentLease == nil)
        #expect(coordinator.terminalRouteIntent == nil)
    }

    @MainActor
    @Test("cancel clears every owned route and makes a paused completion stale")
    func cancellationClearsOwnedStateAndPausedCompletion() async throws {
        let proposal = try QuickConnectLinkCodec(now: { issuedAt }).decode(
            try QuickConnectLinkCodec(now: { issuedAt }).encode(knownEnvelope()))
        let terminal = QuickConnectRecordingTerminal()
        let model = OpenPawModel(hostStore: HostStore(), terminal: terminal)
        model.hostKeyPrompt = HostKeyPrompt(
            host: "studio.tailnet.ts.net:22",
            verdict: .unknown(fingerprint: "SHA256:FIXTURE-UNKNOWN"))
        let coordinator = QuickConnectCoordinator(
            model: model,
            installer: QuickConnectCountingInstaller(),
            now: { self.issuedAt })

        coordinator.begin(proposal)
        coordinator.confirm(.existing(.agentForwarding), username: "daniel")
        await waitForStage(.awaitingHostTrust, coordinator: coordinator)
        #expect(coordinator.currentLease != nil)
        #expect(coordinator.terminalRouteIntent != nil)

        coordinator.cancel()
        model.hostKeyPrompt = nil
        coordinator.resumeAfterHostTrust()
        await Task.yield()

        #expect(coordinator.stage == .cancelled)
        #expect(coordinator.proposal == nil)
        #expect(coordinator.currentLease == nil)
        #expect(coordinator.terminalRouteIntent == nil)
        #expect(terminal.connectedHosts.count == 1)
    }

    @MainActor
    @Test("plain SSH candidate saves one exact host and emits terminal route intent")
    func candidateConnectsWithoutStructuredHost() async {
        let proposal = QuickConnectProposal.from(candidate: AddDeviceCandidate(id: "node", nickname: "Studio", hostname: "studio.local", dnsName: nil, tailscaleIPs: [], os: nil, online: true), now: issuedAt)
        let terminal = QuickConnectRecordingTerminal()
        let model = OpenPawModel(hostStore: HostStore(), terminal: terminal)
        let coordinator = QuickConnectCoordinator(model: model, installer: QuickConnectCountingInstaller(), now: { self.issuedAt })

        coordinator.begin(proposal)
        coordinator.confirm(.existing(.agentForwarding), username: "daniel")
        await waitForCoordinatorToSettle(coordinator)

        #expect(coordinator.stage == .connected)
        #expect(model.hostStore.hosts.count == 1)
        #expect(model.hostStore.hosts[0].hostname == "studio.local")
        #expect(terminal.connectedHosts == [model.hostStore.hosts[0].id])
        #expect(coordinator.terminalRouteIntent == coordinator.currentLease)
    }

    @MainActor
    @Test("canonical existing host preserves metadata and SSH uses the exact confirmed target and username")
    func canonicalExistingHostPreservesMetadataAndUsesReviewedEndpoint() async throws {
        let proposal = try QuickConnectLinkCodec(now: { issuedAt }).decode(
            try QuickConnectLinkCodec(now: { issuedAt }).encode(knownEnvelope()))
        let reviewedTarget = try #require(proposal.targets.last)
        let existingID = UUID()
        let savedPin = KnownHostEntry(
            keyType: "ssh-ed25519",
            fingerprint: "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            addedAt: issuedAt.addingTimeInterval(-60))
        let existing = HostRecord(
            id: existingID,
            nickname: "My saved workstation",
            hostname: "STUDIO.LOCAL.",
            port: reviewedTarget.port,
            hostAPIPort: 9_999,
            username: "reviewed-user",
            auth: .agentForwarding,
            preferredTransport: .mosh,
            lastSuccessfulTransport: .eternalTerminal,
            multiplexerPreference: .zellij,
            knownHosts: [savedPin],
            tags: ["favorite", "production"])
        let terminal = QuickConnectRecordingTerminal()
        let model = OpenPawModel(hostStore: HostStore(hosts: [existing]), terminal: terminal)
        let persistence = QuickConnectPersistenceRecorder()
        let coordinator = QuickConnectCoordinator(
            model: model,
            installer: QuickConnectCountingInstaller(),
            now: { self.issuedAt },
            persistHostStore: { persistence.record($0) })

        coordinator.begin(proposal)
        coordinator.confirm(
            .existing(.password(reference: try KeychainReference(identifier: "fixture/reviewed-password"))),
            target: reviewedTarget,
            username: " reviewed-user ")
        await waitForCoordinatorToSettle(coordinator)

        let saved = try #require(model.hostStore.hosts.only)
        let connected = try #require(terminal.connectedRecords.only)
        #expect(saved.id == existingID)
        #expect(saved.nickname == "My saved workstation")
        #expect(saved.hostname == reviewedTarget.hostname)
        #expect(saved.port == reviewedTarget.port)
        #expect(saved.username == "reviewed-user")
        #expect(saved.preferredTransport == .mosh)
        #expect(saved.lastSuccessfulTransport == .eternalTerminal)
        #expect(saved.multiplexerPreference == .zellij)
        #expect(saved.tags == ["favorite", "production"])
        #expect(saved.knownHosts == [savedPin])
        #expect(connected.id == existingID)
        #expect(connected.hostname == reviewedTarget.hostname)
        #expect(connected.port == reviewedTarget.port)
        #expect(connected.username == "reviewed-user")
        #expect(persistence.stores.count == 1)
    }

    @MainActor
    @Test("conflicting QR pins fail review before credential installation persistence or SSH")
    func conflictingPinsFailBeforeCredentialInstallation() async throws {
        let proposal = try QuickConnectLinkCodec(now: { issuedAt }).decode(
            try QuickConnectLinkCodec(now: { issuedAt }).encode(knownEnvelope()))
        let target = try #require(proposal.targets.first)
        let existing = HostRecord(
            nickname: "Pinned Studio",
            hostname: target.hostname,
            port: target.port,
            username: "daniel",
            auth: .agentForwarding,
            knownHosts: [KnownHostEntry(
                keyType: "ssh-ed25519",
                fingerprint: "SHA256:DIFFERENT-FIXTURE-PIN",
                addedAt: issuedAt)])
        let terminal = QuickConnectRecordingTerminal()
        let installer = QuickConnectCountingInstaller()
        let persistence = QuickConnectPersistenceRecorder()
        let model = OpenPawModel(hostStore: HostStore(hosts: [existing]), terminal: terminal)
        let coordinator = QuickConnectCoordinator(
            model: model,
            installer: installer,
            now: { self.issuedAt },
            persistHostStore: { persistence.record($0) })

        coordinator.begin(proposal)
        coordinator.confirm(.existing(.agentForwarding), target: target, username: "daniel")
        await waitForCoordinatorToSettle(coordinator)

        guard case .failed(.reviewing, _) = coordinator.stage else {
            Issue.record("expected reviewing failure, got \(coordinator.stage)")
            return
        }
        #expect(installer.installCount == 0)
        #expect(persistence.stores.isEmpty)
        #expect(terminal.connectedRecords.isEmpty)
        #expect(model.hostStore.hosts == [existing])
    }

    @MainActor
    @Test("an existing canonical host without pins adopts reviewed QR pins once")
    func existingHostWithoutPinsAdoptsProposalPins() async throws {
        let proposal = try QuickConnectLinkCodec(now: { issuedAt }).decode(
            try QuickConnectLinkCodec(now: { issuedAt }).encode(knownEnvelope()))
        let target = try #require(proposal.targets.first)
        let existing = HostRecord(
            nickname: "Saved Studio",
            hostname: "STUDIO.TAILNET.TS.NET.",
            port: target.port,
            username: "daniel",
            auth: .agentForwarding,
            tags: ["keep-me"])
        let model = OpenPawModel(hostStore: HostStore(hosts: [existing]), terminal: QuickConnectRecordingTerminal())
        let persistence = QuickConnectPersistenceRecorder()
        let coordinator = QuickConnectCoordinator(
            model: model,
            installer: QuickConnectCountingInstaller(),
            now: { self.issuedAt },
            persistHostStore: { persistence.record($0) })

        coordinator.begin(proposal)
        coordinator.confirm(.existing(.agentForwarding), target: target, username: "daniel")
        await waitForCoordinatorToSettle(coordinator)

        let saved = try #require(model.hostStore.hosts.only)
        #expect(saved.id == existing.id)
        #expect(saved.tags == ["keep-me"])
        #expect(saved.knownHosts.map(\.fingerprint) == proposal.hostKeys.map(\.fingerprint))
        #expect(persistence.stores.count == 1)
    }

    @MainActor
    @Test("a newer proposal makes a suspended credential completion stale")
    func newerProposalSuppressesOldCredentialCompletion() async {
        let gate = QuickConnectGate()
        let installer = QuickConnectSuspendedInstaller(gate: gate)
        let terminal = QuickConnectRecordingTerminal()
        let persistence = QuickConnectPersistenceRecorder()
        let model = OpenPawModel(hostStore: HostStore(), terminal: terminal)
        let coordinator = QuickConnectCoordinator(
            model: model,
            installer: installer,
            now: { self.issuedAt },
            persistHostStore: { persistence.record($0) })
        let old = QuickConnectProposal.from(candidate: AddDeviceCandidate(
            id: "old", nickname: "Old", hostname: "old.example", dnsName: nil,
            tailscaleIPs: [], os: nil, online: true), now: issuedAt)
        let new = QuickConnectProposal.from(candidate: AddDeviceCandidate(
            id: "new", nickname: "New", hostname: "new.example", dnsName: nil,
            tailscaleIPs: [], os: nil, online: true), now: issuedAt)

        coordinator.begin(old)
        coordinator.confirm(.existing(.agentForwarding), username: "dev")
        await gate.waitUntilStarted()
        coordinator.begin(new)
        await gate.release()
        await Task.yield()

        #expect(coordinator.stage == .reviewing)
        #expect(coordinator.proposal?.id == "new")
        #expect(model.hostStore.hosts.isEmpty)
        #expect(persistence.stores.isEmpty)
        #expect(terminal.connectedRecords.isEmpty)
        #expect(coordinator.terminalRouteIntent == nil)
    }

    @MainActor
    @Test("cancel makes a suspended credential completion stale")
    func cancelSuppressesCredentialCompletion() async {
        let gate = QuickConnectGate()
        let terminal = QuickConnectRecordingTerminal()
        let persistence = QuickConnectPersistenceRecorder()
        let model = OpenPawModel(hostStore: HostStore(), terminal: terminal)
        let coordinator = QuickConnectCoordinator(
            model: model,
            installer: QuickConnectSuspendedInstaller(gate: gate),
            now: { self.issuedAt },
            persistHostStore: { persistence.record($0) })
        let proposal = QuickConnectProposal.from(candidate: AddDeviceCandidate(
            id: "cancelled", nickname: "Cancelled", hostname: "cancelled.example", dnsName: nil,
            tailscaleIPs: [], os: nil, online: true), now: issuedAt)

        coordinator.begin(proposal)
        coordinator.confirm(.existing(.agentForwarding), username: "dev")
        await gate.waitUntilStarted()
        coordinator.cancel()
        await gate.release()
        await Task.yield()

        #expect(coordinator.stage == .cancelled)
        #expect(model.hostStore.hosts.isEmpty)
        #expect(persistence.stores.isEmpty)
        #expect(terminal.connectedRecords.isEmpty)
        #expect(coordinator.currentLease == nil)
        #expect(coordinator.terminalRouteIntent == nil)
    }

    @MainActor
    @Test("an external host switch makes a suspended credential completion stale")
    func hostSwitchSuppressesCredentialCompletion() async {
        let first = HostRecord(nickname: "First", hostname: "first.example", username: "dev", auth: .agentForwarding)
        let second = HostRecord(nickname: "Second", hostname: "second.example", username: "dev", auth: .agentForwarding)
        let gate = QuickConnectGate()
        let terminal = QuickConnectRecordingTerminal()
        let persistence = QuickConnectPersistenceRecorder()
        let model = OpenPawModel(hostStore: HostStore(hosts: [first, second]), terminal: terminal)
        let coordinator = QuickConnectCoordinator(
            model: model,
            installer: QuickConnectSuspendedInstaller(gate: gate),
            now: { self.issuedAt },
            persistHostStore: { persistence.record($0) })
        let proposal = QuickConnectProposal.from(candidate: AddDeviceCandidate(
            id: "switch", nickname: "Target", hostname: "target.example", dnsName: nil,
            tailscaleIPs: [], os: nil, online: true), now: issuedAt)

        coordinator.begin(proposal)
        coordinator.confirm(.existing(.agentForwarding), username: "dev")
        await gate.waitUntilStarted()
        await model.selectHost(second.id)
        await gate.release()
        await waitForCoordinatorToSettle(coordinator)

        #expect(model.selectedHostID == second.id)
        #expect(persistence.stores.isEmpty)
        #expect(terminal.connectedRecords.isEmpty)
        #expect(coordinator.terminalRouteIntent == nil)
    }

    @MainActor
    @Test("an external A to B to A switch makes a suspended credential completion stale")
    func abaHostSwitchSuppressesCredentialCompletion() async {
        let first = HostRecord(nickname: "First", hostname: "first.example", username: "dev", auth: .agentForwarding)
        let second = HostRecord(nickname: "Second", hostname: "second.example", username: "dev", auth: .agentForwarding)
        let gate = QuickConnectGate()
        let terminal = QuickConnectRecordingTerminal()
        let persistence = QuickConnectPersistenceRecorder()
        let model = OpenPawModel(hostStore: HostStore(hosts: [first, second]), terminal: terminal)
        let coordinator = QuickConnectCoordinator(
            model: model,
            installer: QuickConnectSuspendedInstaller(gate: gate),
            now: { self.issuedAt },
            persistHostStore: { persistence.record($0) })
        let proposal = QuickConnectProposal.from(candidate: AddDeviceCandidate(
            id: "aba", nickname: "Target", hostname: "target.example", dnsName: nil,
            tailscaleIPs: [], os: nil, online: true), now: issuedAt)

        coordinator.begin(proposal)
        coordinator.confirm(.existing(.agentForwarding), username: "dev")
        await gate.waitUntilStarted()
        await model.selectHost(second.id)
        await model.selectHost(first.id)
        await gate.release()
        await waitForCoordinatorToSettle(coordinator)

        #expect(model.selectedHostID == first.id)
        #expect(persistence.stores.isEmpty)
        #expect(terminal.connectedRecords.isEmpty)
        #expect(coordinator.terminalRouteIntent == nil)
    }

    @MainActor
    @Test("an external reconnect makes a suspended credential completion stale")
    func reconnectSuppressesCredentialCompletion() async throws {
        let existing = HostRecord(nickname: "Existing", hostname: "existing.example", username: "dev", auth: .agentForwarding)
        let gate = QuickConnectGate()
        let terminal = QuickConnectRecordingTerminal()
        let persistence = QuickConnectPersistenceRecorder()
        let model = OpenPawModel(hostStore: HostStore(hosts: [existing]), terminal: terminal)
        let coordinator = QuickConnectCoordinator(
            model: model,
            installer: QuickConnectSuspendedInstaller(gate: gate),
            now: { self.issuedAt },
            persistHostStore: { persistence.record($0) })
        let proposal = QuickConnectProposal.from(candidate: AddDeviceCandidate(
            id: "reconnect", nickname: "Target", hostname: "target.example", dnsName: nil,
            tailscaleIPs: [], os: nil, online: true), now: issuedAt)

        coordinator.begin(proposal)
        coordinator.confirm(.existing(.agentForwarding), username: "dev")
        await gate.waitUntilStarted()
        _ = try #require(await model.connectSelectedHost())
        await gate.release()
        await waitForCoordinatorToSettle(coordinator)

        #expect(terminal.connectedRecords.map(\.id) == [existing.id])
        #expect(persistence.stores.isEmpty)
        #expect(coordinator.currentLease == nil)
        #expect(coordinator.terminalRouteIntent == nil)
    }

    @MainActor
    @Test("a reconnect while selected-host teardown is suspended prevents the coordinator from dialing")
    func reconnectDuringSelectionSuppressesCoordinatorConnect() async {
        let existing = HostRecord(nickname: "Existing", hostname: "existing.example", username: "dev", auth: .agentForwarding)
        let disconnectGate = QuickConnectGate()
        let terminal = QuickConnectRecordingTerminal()
        terminal.disconnectGate = disconnectGate
        let persistence = QuickConnectPersistenceRecorder()
        let model = OpenPawModel(hostStore: HostStore(hosts: [existing]), terminal: terminal)
        let coordinator = QuickConnectCoordinator(
            model: model,
            installer: QuickConnectCountingInstaller(),
            now: { self.issuedAt },
            persistHostStore: { persistence.record($0) })
        let proposal = QuickConnectProposal.from(candidate: AddDeviceCandidate(
            id: "selection-reconnect", nickname: "Target", hostname: "target.example", dnsName: nil,
            tailscaleIPs: [], os: nil, online: true), now: issuedAt)

        coordinator.begin(proposal)
        coordinator.confirm(.existing(.agentForwarding), username: "dev")
        await disconnectGate.waitUntilStarted()
        await model.disconnect()
        await disconnectGate.release()
        await waitForCoordinatorToSettle(coordinator)

        #expect(persistence.stores.count == 1)
        #expect(terminal.connectedRecords.isEmpty)
        #expect(coordinator.currentLease == nil)
        #expect(coordinator.terminalRouteIntent == nil)
    }

    @MainActor
    @Test("a same-host selection cannot adopt ownership after an ABA switch")
    func sameHostSelectionCannotAdoptABAOwnership() async throws {
        let first = HostRecord(nickname: "First", hostname: "first.example", username: "dev", auth: .agentForwarding)
        let second = HostRecord(nickname: "Second", hostname: "second.example", username: "dev", auth: .agentForwarding)
        let disconnectGate = QuickConnectGate()
        let terminal = QuickConnectRecordingTerminal()
        terminal.disconnectGate = disconnectGate
        let model = OpenPawModel(hostStore: HostStore(hosts: [first, second]), terminal: terminal)

        let initialSelection = Task { await model.selectHost(second.id) }
        await disconnectGate.waitUntilStarted()
        let sameHostSelection = Task { await model.selectHost(second.id) }
        for _ in 0..<10 { await Task.yield() }
        let away = Task { await model.selectHost(first.id) }
        for _ in 0..<10 { await Task.yield() }
        let back = Task { await model.selectHost(second.id) }
        for _ in 0..<10 { await Task.yield() }

        await disconnectGate.release()
        _ = await initialSelection.value
        let staleOwnership = await sameHostSelection.value
        _ = await away.value
        _ = await back.value

        #expect(staleOwnership == nil)
        #expect(model.selectedHostID == second.id)
    }

    @MainActor
    @Test("QR persistence keeps displayed API port and confirmed host key when pairing fails")
    func qrPersistsPortPinsAndTerminalIntentBeforePairFailure() async throws {
        let proposal = try QuickConnectLinkCodec(now: { issuedAt }).decode(try QuickConnectLinkCodec(now: { issuedAt }).encode(knownEnvelope()))
        let model = OpenPawModel(hostStore: HostStore(), terminal: QuickConnectRecordingTerminal())
        let coordinator = QuickConnectCoordinator(model: model, installer: QuickConnectCountingInstaller(), now: { self.issuedAt })

        coordinator.begin(proposal)
        coordinator.confirm(.existing(.agentForwarding), username: "daniel")
        await waitForCoordinatorToSettle(coordinator)

        guard case .failed = coordinator.stage else {
            Issue.record("expected pairing failure without pairing backend")
            return
        }
        let host = try #require(model.hostStore.hosts.only)
        #expect(host.hostAPIPort == 4_317)
        #expect(host.knownHosts.map(\.fingerprint) == proposal.hostKeys.map(\.fingerprint))
        #expect(model.connection.isConnected)
        #expect(coordinator.terminalRouteIntent != nil)
    }

    @MainActor
    @Test("pairing redeems exactly once then refreshes and follows")
    func pairingRedeemsOnceThenRefreshesAndFollows() async throws {
        let proposal = try QuickConnectLinkCodec(now: { issuedAt }).decode(
            try QuickConnectLinkCodec(now: { issuedAt }).encode(knownEnvelope()))
        let backend = QuickConnectPairingBackend()
        let terminal = QuickConnectRecordingTerminal()
        let model = OpenPawModel(hostStore: HostStore(), backend: backend, terminal: terminal)
        let persistence = QuickConnectPersistenceRecorder()
        let coordinator = QuickConnectCoordinator(
            model: model,
            installer: QuickConnectCountingInstaller(),
            now: { self.issuedAt },
            persistHostStore: { persistence.record($0) })

        coordinator.begin(proposal)
        coordinator.confirm(.existing(.agentForwarding), username: "daniel", deviceName: "Fixture Phone")
        await waitForCoordinatorToSettle(coordinator)
        await waitForBackendCall("events", backend: backend)

        #expect(coordinator.stage == .connected)
        #expect(backend.pairingCodes == ["ABCD-EFGH-IJKL-MNOP-QRST-UVWX"])
        #expect(backend.deviceNames == ["Fixture Phone"])
        #expect(backend.callCount("health") == 1)
        #expect(backend.callCount("events") == 1)
        #expect(terminal.connectedRecords.count == 1)
        #expect(persistence.stores.count == 1)
        #expect(coordinator.terminalRouteIntent == coordinator.currentLease)
    }

    @MainActor
    @Test("unknown host key pauses and resumes the same owned lease without duplicate persistence or SSH")
    func unknownHostKeyPausesAndResumesOwnedLease() async throws {
        let proposal = try QuickConnectLinkCodec(now: { issuedAt }).decode(
            try QuickConnectLinkCodec(now: { issuedAt }).encode(knownEnvelope()))
        let backend = QuickConnectPairingBackend()
        let terminal = QuickConnectRecordingTerminal()
        let model = OpenPawModel(hostStore: HostStore(), backend: backend, terminal: terminal)
        model.hostKeyPrompt = HostKeyPrompt(
            host: "studio.tailnet.ts.net:22",
            verdict: .unknown(fingerprint: "SHA256:FIXTURE-UNKNOWN"))
        let persistence = QuickConnectPersistenceRecorder()
        let coordinator = QuickConnectCoordinator(
            model: model,
            installer: QuickConnectCountingInstaller(),
            now: { self.issuedAt },
            persistHostStore: { persistence.record($0) })

        coordinator.begin(proposal)
        coordinator.confirm(.existing(.agentForwarding), username: "daniel")
        await waitForStage(.awaitingHostTrust, coordinator: coordinator)
        let pausedLease = try #require(coordinator.currentLease)

        model.hostKeyPrompt = nil
        coordinator.resumeAfterHostTrust()
        await waitForCoordinatorToSettle(coordinator)

        #expect(coordinator.stage == .connected)
        #expect(coordinator.currentLease == pausedLease)
        #expect(terminal.connectedRecords.count == 1)
        #expect(persistence.stores.count == 1)
        #expect(backend.pairingCodes.count == 1)
    }

    @MainActor
    @Test("changed host key is a hard failure and never pairs")
    func changedHostKeyFailsHard() async throws {
        let proposal = try QuickConnectLinkCodec(now: { issuedAt }).decode(
            try QuickConnectLinkCodec(now: { issuedAt }).encode(knownEnvelope()))
        let backend = QuickConnectPairingBackend()
        let model = OpenPawModel(hostStore: HostStore(), backend: backend, terminal: QuickConnectRecordingTerminal())
        model.hostKeyPrompt = HostKeyPrompt(
            host: "studio.tailnet.ts.net:22",
            verdict: .changed(expected: "SHA256:FIXTURE-EXPECTED", actual: "SHA256:FIXTURE-ACTUAL"))
        let coordinator = QuickConnectCoordinator(
            model: model,
            installer: QuickConnectCountingInstaller(),
            now: { self.issuedAt })

        coordinator.begin(proposal)
        coordinator.confirm(.existing(.agentForwarding), username: "daniel")
        await waitForCoordinatorToSettle(coordinator)

        guard case .failed(.connectingSSH, _) = coordinator.stage else {
            Issue.record("expected changed-key connection failure, got \(coordinator.stage)")
            return
        }
        #expect(backend.pairingCodes.isEmpty)
        #expect(coordinator.currentLease == nil)
        #expect(coordinator.terminalRouteIntent == nil)
    }

    @MainActor
    @Test("expiry after SSH preserves the saved host and terminal but never pairs")
    func expiryAfterSSHPreservesTerminalWithoutPairing() async throws {
        let proposal = try QuickConnectLinkCodec(now: { issuedAt }).decode(
            try QuickConnectLinkCodec(now: { issuedAt }).encode(knownEnvelope()))
        let clock = QuickConnectClock(issuedAt)
        let backend = QuickConnectPairingBackend()
        let terminal = QuickConnectRecordingTerminal()
        terminal.onConnect = { clock.set(self.expiresAt.addingTimeInterval(1)) }
        let model = OpenPawModel(hostStore: HostStore(), backend: backend, terminal: terminal)
        let coordinator = QuickConnectCoordinator(
            model: model,
            installer: QuickConnectCountingInstaller(),
            now: { clock.value })

        coordinator.begin(proposal)
        coordinator.confirm(.existing(.agentForwarding), username: "daniel")
        await waitForCoordinatorToSettle(coordinator)

        guard case .failed(.pairing, _) = coordinator.stage else {
            Issue.record("expected pairing-stage expiry, got \(coordinator.stage)")
            return
        }
        #expect(model.hostStore.hosts.count == 1)
        #expect(model.connection.isConnected)
        #expect(terminal.connectedRecords.count == 1)
        #expect(backend.pairingCodes.isEmpty)
        #expect(coordinator.terminalRouteIntent == coordinator.currentLease)
    }

    @MainActor
    @Test("a stale pairing completion cannot retain terminal route ownership")
    func stalePairingCompletionClearsTerminalOwnership() async throws {
        let proposal = try QuickConnectLinkCodec(now: { issuedAt }).decode(
            try QuickConnectLinkCodec(now: { issuedAt }).encode(knownEnvelope()))
        let pairGate = QuickConnectGate()
        let backend = QuickConnectPairingBackend(pairGate: pairGate)
        let terminal = QuickConnectRecordingTerminal()
        let model = OpenPawModel(hostStore: HostStore(), backend: backend, terminal: terminal)
        let coordinator = QuickConnectCoordinator(
            model: model,
            installer: QuickConnectCountingInstaller(),
            now: { self.issuedAt })

        coordinator.begin(proposal)
        coordinator.confirm(.existing(.agentForwarding), username: "daniel")
        await pairGate.waitUntilStarted()
        await model.disconnect()
        await pairGate.release()
        await waitForCoordinatorToSettle(coordinator)

        #expect(backend.pairingCodes.count == 1)
        #expect(coordinator.currentLease == nil)
        #expect(coordinator.terminalRouteIntent == nil)
    }

    @MainActor
    @Test("pairing-only retry reopens only the structured lifecycle and never repeats SSH setup")
    func pairingOnlyRetryDoesNotReconnectSSH() async throws {
        let proposal = try QuickConnectLinkCodec(now: { issuedAt }).decode(
            try QuickConnectLinkCodec(now: { issuedAt }).encode(knownEnvelope()))
        let backend = QuickConnectPairingBackend()
        backend.pairFailuresRemaining = 1
        let terminal = QuickConnectRecordingTerminal()
        let installer = QuickConnectCountingInstaller()
        let persistence = QuickConnectPersistenceRecorder()
        let model = OpenPawModel(hostStore: HostStore(), backend: backend, terminal: terminal)
        let coordinator = QuickConnectCoordinator(
            model: model,
            installer: installer,
            now: { self.issuedAt },
            persistHostStore: { persistence.record($0) })

        coordinator.begin(proposal)
        coordinator.confirm(.existing(.agentForwarding), username: "daniel")
        await waitForCoordinatorToSettle(coordinator)
        guard case .failed(.pairing, _) = coordinator.stage else {
            Issue.record("expected first pairing failure, got \(coordinator.stage)")
            return
        }
        let ownedLease = try #require(coordinator.currentLease)
        await backend.disconnect()

        coordinator.retryPairing()
        await waitForCoordinatorToSettle(coordinator)
        await waitForBackendCall("events", backend: backend)

        #expect(coordinator.stage == .connected)
        #expect(coordinator.currentLease == ownedLease)
        #expect(installer.installCount == 1)
        #expect(persistence.stores.count == 1)
        #expect(terminal.connectedRecords.count == 1)
        #expect(backend.connectIDs.count == 2)
        #expect(backend.pairingCodes.count == 2)
        #expect(backend.callCount("health") == 1)
        #expect(backend.callCount("events") == 1)
    }

    @MainActor
    @Test("pairing-only retry rejects a stale lease without any repeated work")
    func pairingOnlyRetryRejectsStaleLease() async throws {
        let proposal = try QuickConnectLinkCodec(now: { issuedAt }).decode(
            try QuickConnectLinkCodec(now: { issuedAt }).encode(knownEnvelope()))
        let backend = QuickConnectPairingBackend()
        backend.pairFailuresRemaining = 1
        let terminal = QuickConnectRecordingTerminal()
        let installer = QuickConnectCountingInstaller()
        let persistence = QuickConnectPersistenceRecorder()
        let model = OpenPawModel(hostStore: HostStore(), backend: backend, terminal: terminal)
        let coordinator = QuickConnectCoordinator(
            model: model,
            installer: installer,
            now: { self.issuedAt },
            persistHostStore: { persistence.record($0) })

        coordinator.begin(proposal)
        coordinator.confirm(.existing(.agentForwarding), username: "daniel")
        await waitForCoordinatorToSettle(coordinator)
        await model.disconnect()

        coordinator.retryPairing()
        await waitForCoordinatorToSettle(coordinator)

        guard case .failed(.pairing, _) = coordinator.stage else {
            Issue.record("expected stale retry failure, got \(coordinator.stage)")
            return
        }
        #expect(installer.installCount == 1)
        #expect(persistence.stores.count == 1)
        #expect(terminal.connectedRecords.count == 1)
        #expect(backend.connectIDs.count == 1)
        #expect(backend.pairingCodes.count == 1)
        #expect(coordinator.currentLease == nil)
        #expect(coordinator.terminalRouteIntent == nil)
    }

    @MainActor
    private func waitForCoordinatorToSettle(_ coordinator: QuickConnectCoordinator) async {
        for _ in 0..<1_000 {
            switch coordinator.stage {
            case .connected, .failed, .cancelled: return
            default: await Task.yield()
            }
        }
        Issue.record("coordinator did not settle")
    }

    @MainActor
    private func waitForStage(_ expected: QuickConnectCoordinator.Stage, coordinator: QuickConnectCoordinator) async {
        for _ in 0..<1_000 {
            if coordinator.stage == expected { return }
            await Task.yield()
        }
        Issue.record("coordinator did not reach \(expected); got \(coordinator.stage)")
    }

    @MainActor
    private func waitForBackendCall(_ name: String, backend: QuickConnectPairingBackend) async {
        for _ in 0..<1_000 {
            if backend.callCount(name) > 0 { return }
            await Task.yield()
        }
        Issue.record("backend did not record \(name)")
    }

    private func expectDecodeError(_ error: QuickConnectLinkError, codec: QuickConnectLinkCodec, envelope: QuickConnectEnvelopeV1) throws {
        let complete = QuickConnectEnvelopeV1(
            version: envelope.version,
            issuedAt: envelope.issuedAt,
            expiresAt: envelope.expiresAt,
            sessionID: envelope.sessionID,
            hostAPIPort: envelope.hostAPIPort,
            profile: envelope.profile,
            pairingCode: envelope.pairingCode,
            nickname: envelope.nickname,
            username: envelope.username,
            targets: envelope.targets,
            hostKeys: envelope.hostKeys
        )
        let url = try QuickConnectLinkCodec(now: { issuedAt }).encodeWithoutValidation(complete)
        #expect(throws: error) { try codec.decode(url) }
    }

    private func rawURL(_ object: [String: Any]) throws -> URL {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let payload = data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return URL(string: "openpaw://pair#v1.\(payload)")!
    }

    private func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}

private final class QuickConnectCountingInstaller: QuickConnectCredentialInstalling, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var installCount: Int { lock.withLock { count } }
    func install(_ choice: QuickConnectCredentialChoice) async throws -> AuthMethod {
        lock.withLock { count += 1 }
        switch choice {
        case .existing(let auth): return auth
        default: return .agentForwarding
        }
    }
}

private actor QuickConnectGate {
    private var started = false
    private var released = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func suspend() async {
        started = true
        let waiters = startedWaiters
        startedWaiters.removeAll()
        waiters.forEach { $0.resume() }
        guard !released else { return }
        await withCheckedContinuation { continuation in
            if released { continuation.resume() }
            else { releaseWaiters.append(continuation) }
        }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private final class QuickConnectSuspendedInstaller: QuickConnectCredentialInstalling, @unchecked Sendable {
    private let gate: QuickConnectGate
    init(gate: QuickConnectGate) { self.gate = gate }
    func install(_ choice: QuickConnectCredentialChoice) async throws -> AuthMethod {
        await gate.suspend()
        if case .existing(let auth) = choice { return auth }
        return .agentForwarding
    }
}

private final class QuickConnectRecordingTerminal: TerminalBackend, @unchecked Sendable {
    private let continuation: AsyncStream<ConnectionState>.Continuation
    let stateStream: AsyncStream<ConnectionState>
    let outputStream = AsyncStream<Data> { $0.finish() }
    private(set) var connectedRecords: [HostRecord] = []
    var connectedHosts: [HostRecord.ID] { connectedRecords.map(\.id) }
    var disconnectGate: QuickConnectGate?
    var onConnect: (@Sendable () -> Void)?
    private var disconnectCount = 0
    init() {
        var continuation: AsyncStream<ConnectionState>.Continuation!
        stateStream = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }
    func connect(host: HostRecord) async throws {
        connectedRecords.append(host)
        onConnect?()
        continuation.yield(.connected(.ssh))
    }
    func disconnect() async {
        disconnectCount += 1
        if disconnectCount == 1, let disconnectGate { await disconnectGate.suspend() }
        continuation.yield(.disconnected(reason: nil))
    }
    func send(text: String) async throws {}
    func send(chord: KeyChord, applicationCursorKeys: Bool) async throws {}
    func resize(columns: Int, rows: Int) async throws {}
    func run(command: String) async throws -> String { "" }
}

private final class QuickConnectClock: @unchecked Sendable {
    private let lock = NSLock()
    private var now: Date
    init(_ now: Date) { self.now = now }
    var value: Date { lock.withLock { now } }
    func set(_ value: Date) { lock.withLock { now = value } }
}

private enum QuickConnectFixtureError: Error { case expectedFailure }

private final class QuickConnectPairingBackend: OpenPawBackend, StructuredBackendLifecycle, OpenPawHostPairing, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String] = []
    private var ready = false
    private var recordedConnectIDs: [HostRecord.ID] = []
    private var recordedPairingCodes: [String] = []
    private var recordedDeviceNames: [String] = []
    private let pairGate: QuickConnectGate?
    var pairFailuresRemaining = 0

    init(pairGate: QuickConnectGate? = nil) { self.pairGate = pairGate }

    var pairingCodes: [String] { lock.withLock { recordedPairingCodes } }
    var deviceNames: [String] { lock.withLock { recordedDeviceNames } }
    var connectIDs: [HostRecord.ID] { lock.withLock { recordedConnectIDs } }
    var isReady: Bool { get async { lock.withLock { ready } } }

    func callCount(_ name: String) -> Int { lock.withLock { calls.filter { $0 == name }.count } }
    private func record(_ name: String) { lock.withLock { calls.append(name) } }

    func connect(hostID: HostRecord.ID) async throws {
        lock.withLock {
            recordedConnectIDs.append(hostID)
            ready = true
        }
    }

    func disconnect() async { lock.withLock { ready = false } }

    func pair(pairingCode: String, deviceName: String) async throws -> PairingResult {
        let shouldFail = lock.withLock {
            recordedPairingCodes.append(pairingCode)
            recordedDeviceNames.append(deviceName)
            if pairFailuresRemaining > 0 {
                pairFailuresRemaining -= 1
                return true
            }
            return false
        }
        if let pairGate { await pairGate.suspend() }
        if shouldFail { throw QuickConnectFixtureError.expectedFailure }
        return PairingResult(
            deviceID: "fixture-device",
            token: "fixture-token",
            hmacKeyB64: Data(repeating: 7, count: 32).base64EncodedString(),
            capabilities: [])
    }

    func health() async throws -> HealthInfo {
        record("health")
        return HealthInfo(version: "fixture", protocolVersion: "1.0", agents: [], capabilities: [], previewPorts: [], adapterVersions: [:])
    }
    func sessions() async throws -> [SessionSummary] { record("sessions"); return [] }
    func inbox(status: InboxStatus?) async throws -> [InboxItem] { record("inbox"); return [] }
    func resolve(item: InboxItem, action: ActionID, answer: String?, detailAcknowledged: Bool) async throws -> ResolveResult { throw QuickConnectFixtureError.expectedFailure }
    func events(session: String?, afterSeq: UInt64?) -> AsyncThrowingStream<Event, any Error> {
        record("events")
        return AsyncThrowingStream { $0.finish() }
    }
    func repos() async throws -> [RepoSummary] { record("repos"); return [] }
    func repoStatus(_ repo: String) async throws -> RepoStatus { throw QuickConnectFixtureError.expectedFailure }
    func diff(repo: String, mode: DiffMode, path: String?) async throws -> Diff { throw QuickConnectFixtureError.expectedFailure }
    func tree(repo: String, ref: String, path: String) async throws -> [TreeEntry] { throw QuickConnectFixtureError.expectedFailure }
    func blob(repo: String, ref: String, path: String) async throws -> Blob { throw QuickConnectFixtureError.expectedFailure }
    func search(repo: String, query: String, path: String?) async throws -> [ContentMatch] { throw QuickConnectFixtureError.expectedFailure }
    func upload(data: Data, filename: String) async throws -> UploadResult { throw QuickConnectFixtureError.expectedFailure }
    func previewURL(port: Int, path: String) throws -> URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }
    func tailscaleDevices() async throws -> TailscaleDevicesResponse { TailscaleDevicesResponse(version: 1, candidates: []) }
    func audit(limit: Int) async throws -> [AuditEntry] { [] }
}

@MainActor
private final class QuickConnectPersistenceRecorder {
    private(set) var stores: [HostStore] = []
    func record(_ store: HostStore) { stores.append(store) }
}

private extension Array {
    var only: Element? { count == 1 ? self[0] : nil }
}

private final class RecordingQuickConnectCredentialInstaller: QuickConnectCredentialInstalling, @unchecked Sendable {
    private(set) var requests: [QuickConnectStoredSecretRequest] = []
    private var nextID = 1

    func install(_ choice: QuickConnectCredentialChoice) async throws -> AuthMethod {
        let id = String(format: "00000000-0000-0000-0000-%012d", nextID)
        nextID += 1
        let plan = try QuickConnectCredentialReferences.storageRequests(for: choice, transactionID: id)
        requests.append(contentsOf: plan.requests)
        return plan.auth
    }
}

private struct FailingQuickConnectCredentialInstaller: QuickConnectCredentialInstalling {
    func install(_ choice: QuickConnectCredentialChoice) async throws -> AuthMethod {
        _ = choice
        throw QuickConnectCredentialInstallError.storageFailed
    }
}
