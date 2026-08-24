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
            pairingCode: "ABCD-EFGH-IJKL-MNOP-QRST-UVWX",
            nickname: "Studio Mac",
            username: "daniel",
            targets: [
                QuickConnectTarget(hostname: "studio.tailnet.ts.net", port: 22, source: .magicDNS),
                QuickConnectTarget(hostname: "100.64.0.7", port: 22, source: .tailnet),
                QuickConnectTarget(hostname: "fd7a:115c:a1e0::7", port: 22, source: .tailnet),
                QuickConnectTarget(hostname: "studio.local", port: 2222, source: .explicit)
            ],
            hostKeys: [QuickConnectHostKey(algorithm: "ssh-ed25519", fingerprint: "SHA256:abcdefghijklmnopqrstuvwxy12345678901")]
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
        try expectDecodeError(.expiryTooLong, codec: QuickConnectLinkCodec(now: { issuedAt }), envelope: QuickConnectEnvelopeV1(issuedAt: issuedAt, expiresAt: issuedAt.addingTimeInterval(301), pairingCode: valid.pairingCode!, nickname: valid.nickname, username: valid.username, targets: valid.targets, hostKeys: valid.hostKeys))
        try expectDecodeError(.invalidPort, codec: QuickConnectLinkCodec(now: { issuedAt }), envelope: QuickConnectEnvelopeV1(issuedAt: issuedAt, expiresAt: expiresAt, pairingCode: valid.pairingCode!, nickname: valid.nickname, username: valid.username, targets: [QuickConnectTarget(hostname: "studio", port: 0, source: .explicit)], hostKeys: valid.hostKeys))
        try expectDecodeError(.invalidTarget, codec: QuickConnectLinkCodec(now: { issuedAt }), envelope: QuickConnectEnvelopeV1(issuedAt: issuedAt, expiresAt: expiresAt, pairingCode: valid.pairingCode!, nickname: valid.nickname, username: valid.username, targets: [QuickConnectTarget(hostname: "bad host", port: 22, source: .explicit)], hostKeys: valid.hostKeys))
        try expectDecodeError(.invalidTarget, codec: QuickConnectLinkCodec(now: { issuedAt }), envelope: QuickConnectEnvelopeV1(issuedAt: issuedAt, expiresAt: expiresAt, pairingCode: valid.pairingCode!, nickname: valid.nickname, username: valid.username, targets: [QuickConnectTarget(hostname: "user@studio.local", port: 22, source: .explicit)], hostKeys: valid.hostKeys))
        try expectDecodeError(.duplicateTarget, codec: QuickConnectLinkCodec(now: { issuedAt }), envelope: QuickConnectEnvelopeV1(issuedAt: issuedAt, expiresAt: expiresAt, pairingCode: valid.pairingCode!, nickname: valid.nickname, username: valid.username, targets: [valid.targets[0], valid.targets[0]], hostKeys: valid.hostKeys))
        try expectDecodeError(.unsupportedFingerprintAlgorithm("md5"), codec: QuickConnectLinkCodec(now: { issuedAt }), envelope: QuickConnectEnvelopeV1(issuedAt: issuedAt, expiresAt: expiresAt, pairingCode: valid.pairingCode!, nickname: valid.nickname, username: valid.username, targets: valid.targets, hostKeys: [QuickConnectHostKey(algorithm: "md5", fingerprint: "MD5:aa")]))
        try expectDecodeError(.emptyPairingCode, codec: QuickConnectLinkCodec(now: { issuedAt }), envelope: QuickConnectEnvelopeV1(issuedAt: issuedAt, expiresAt: expiresAt, pairingCode: "", nickname: valid.nickname, username: valid.username, targets: valid.targets, hostKeys: valid.hostKeys))

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

    private func expectDecodeError(_ error: QuickConnectLinkError, codec: QuickConnectLinkCodec, envelope: QuickConnectEnvelopeV1) throws {
        let url = try QuickConnectLinkCodec(now: { issuedAt }).encodeWithoutValidation(envelope)
        #expect(throws: error) { try codec.decode(url) }
    }
}
