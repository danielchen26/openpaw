import Foundation
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

        guard case .failed = coordinator.stage else {
            Issue.record("expected expired failure, got \(coordinator.stage)")
            return
        }
        #expect(installer.installCount == 0)
        #expect(model.hostStore.hosts.isEmpty)
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
    private func waitForCoordinatorToSettle(_ coordinator: QuickConnectCoordinator) async {
        for _ in 0..<1_000 {
            switch coordinator.stage {
            case .connected, .failed, .cancelled: return
            default: await Task.yield()
            }
        }
        Issue.record("coordinator did not settle")
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

private final class QuickConnectRecordingTerminal: TerminalBackend, @unchecked Sendable {
    private let continuation: AsyncStream<ConnectionState>.Continuation
    let stateStream: AsyncStream<ConnectionState>
    let outputStream = AsyncStream<Data> { $0.finish() }
    private(set) var connectedHosts: [HostRecord.ID] = []
    init() {
        var continuation: AsyncStream<ConnectionState>.Continuation!
        stateStream = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }
    func connect(host: HostRecord) async throws { connectedHosts.append(host.id); continuation.yield(.connected(.ssh)) }
    func disconnect() async { continuation.yield(.disconnected(reason: nil)) }
    func send(text: String) async throws {}
    func send(chord: KeyChord, applicationCursorKeys: Bool) async throws {}
    func resize(columns: Int, rows: Int) async throws {}
    func run(command: String) async throws -> String { "" }
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
