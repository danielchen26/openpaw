import Foundation
import OpenPawTerminalCore

public struct QuickConnectTarget: Sendable, Hashable, Codable {
    public enum Source: String, Sendable, Hashable, Codable { case magicDNS = "magic_dns", tailnet, explicit }
    public var hostname: String
    public var port: Int
    public var source: Source
    public init(hostname: String, port: Int = 22, source: Source) { self.hostname = hostname; self.port = port; self.source = source }
}

public struct QuickConnectHostKey: Sendable, Hashable, Codable {
    public var algorithm: String
    public var fingerprint: String
    public init(algorithm: String, fingerprint: String) { self.algorithm = algorithm; self.fingerprint = fingerprint }
}

public struct QuickConnectEnvelopeV1: Sendable, Hashable, Codable {
    public var version: Int
    public var issuedAt: Date
    public var expiresAt: Date
    public var pairingCode: String?
    public var nickname: String
    public var username: String
    public var targets: [QuickConnectTarget]
    public var hostKeys: [QuickConnectHostKey]

    public init(version: Int = 1, issuedAt: Date, expiresAt: Date, pairingCode: String?, nickname: String, username: String, targets: [QuickConnectTarget], hostKeys: [QuickConnectHostKey] = []) {
        self.version = version; self.issuedAt = issuedAt; self.expiresAt = expiresAt; self.pairingCode = pairingCode; self.nickname = nickname; self.username = username; self.targets = targets; self.hostKeys = hostKeys
    }
    private enum CodingKeys: String, CodingKey { case version = "v", issuedAt = "issued_at", expiresAt = "expires_at", pairingCode = "pairing_code", nickname, username, targets, hostKeys = "host_keys" }
}

public struct QuickConnectProposal: Identifiable, Sendable, Hashable {
    public var id: String
    public var version: Int
    public var issuedAt: Date?
    public var expiresAt: Date?
    public var pairingCode: String?
    public var nickname: String
    public var username: String
    public var dnsName: String?
    public var tailscaleIPs: [String]
    public var online: Bool
    public var targets: [QuickConnectTarget]
    public var hostKeys: [QuickConnectHostKey]
    public var envelope: QuickConnectEnvelopeV1?

    public static func from(candidate: AddDeviceCandidate, now: Date) -> QuickConnectProposal {
        var targets: [QuickConnectTarget] = []
        if let dns = candidate.dnsName, !dns.isEmpty { targets.append(.init(hostname: dns, source: .magicDNS)) }
        targets += candidate.tailscaleIPs.filter { !$0.isEmpty }.map { .init(hostname: $0, source: .tailnet) }
        if !candidate.hostname.isEmpty, !targets.contains(where: { normalized($0.hostname) == normalized(candidate.hostname) }) { targets.append(.init(hostname: candidate.hostname, source: .explicit)) }
        return QuickConnectProposal(id: candidate.id, version: 1, issuedAt: nil, expiresAt: nil, pairingCode: nil, nickname: candidate.nickname, username: "", dnsName: candidate.dnsName, tailscaleIPs: candidate.tailscaleIPs, online: candidate.online, targets: targets, hostKeys: [], envelope: nil)
    }

    public func matches(existing host: HostRecord) -> Bool {
        guard host.username == username else { return false }
        return targets.contains { $0.port == host.port && QuickConnectProposal.normalized($0.hostname) == QuickConnectProposal.normalized(host.hostname) }
    }

    fileprivate static func normalized(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased() }
}

public enum QuickConnectLinkError: Error, Sendable, Hashable {
    case invalidScheme, invalidHost, missingFragment, invalidFragment, oversizedFragment, oversizedPayload
    case unsupportedVersion(String), versionMismatch, invalidPort, invalidTarget, duplicateTarget
    case expired, expiryTooLong, emptyPairingCode, unsupportedFingerprintAlgorithm(String)
}

public struct QuickConnectLinkCodec: Sendable {
    public static let maxFragmentBytes = 4096
    public static let maxPayloadBytes = 3072
    public var now: @Sendable () -> Date
    public init(now: @escaping @Sendable () -> Date = Date.init) { self.now = now }

    public func encode(_ envelope: QuickConnectEnvelopeV1) throws -> URL {
        try validate(envelope, at: envelope.issuedAt, checkExpiry: false)
        return try encodeWithoutValidation(envelope)
    }

    public func encodeWithoutValidation(_ envelope: QuickConnectEnvelopeV1) throws -> URL {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(envelope)
        guard data.count <= Self.maxPayloadBytes else { throw QuickConnectLinkError.oversizedPayload }
        let payload = base64URL(data)
        guard payload.utf8.count + 3 <= Self.maxFragmentBytes else { throw QuickConnectLinkError.oversizedFragment }
        return URL(string: "openpaw://pair#v1.\(payload)")!
    }

    public func decode(_ url: URL) throws -> QuickConnectProposal { try decode(url, store: nil) }
    public func decode(_ url: URL, store: inout HostStore) throws -> QuickConnectProposal { try decode(url, store: store) }

    private func decode(_ url: URL, store: HostStore?) throws -> QuickConnectProposal {
        guard url.scheme == "openpaw" else { throw QuickConnectLinkError.invalidScheme }
        guard url.host == "pair" else { throw QuickConnectLinkError.invalidHost }
        guard let fragment = url.fragment else { throw QuickConnectLinkError.missingFragment }
        guard fragment.utf8.count <= Self.maxFragmentBytes else { throw QuickConnectLinkError.oversizedFragment }
        guard fragment.hasPrefix("v") else { throw QuickConnectLinkError.invalidFragment }
        let parts = fragment.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { throw QuickConnectLinkError.invalidFragment }
        guard parts[0] == "v1" else { throw QuickConnectLinkError.unsupportedVersion(parts[0]) }
        guard let data = dataFromBase64URL(parts[1]) else { throw QuickConnectLinkError.invalidFragment }
        guard data.count <= Self.maxPayloadBytes else { throw QuickConnectLinkError.oversizedPayload }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let envelope: QuickConnectEnvelopeV1
        do { envelope = try decoder.decode(QuickConnectEnvelopeV1.self, from: data) } catch { throw QuickConnectLinkError.invalidFragment }
        try validate(envelope, at: now(), checkExpiry: true)
        return QuickConnectProposal(id: envelope.pairingCode ?? UUID().uuidString, version: envelope.version, issuedAt: envelope.issuedAt, expiresAt: envelope.expiresAt, pairingCode: envelope.pairingCode.map(Self.normalizePairingCode), nickname: envelope.nickname, username: envelope.username, dnsName: envelope.targets.first(where: { $0.source == .magicDNS })?.hostname, tailscaleIPs: envelope.targets.filter { $0.source == .tailnet }.map(\.hostname), online: false, targets: envelope.targets, hostKeys: envelope.hostKeys, envelope: envelope)
    }

    private func validate(_ envelope: QuickConnectEnvelopeV1, at now: Date, checkExpiry: Bool) throws {
        guard envelope.version == 1 else { throw QuickConnectLinkError.versionMismatch }
        if checkExpiry, now > envelope.expiresAt { throw QuickConnectLinkError.expired }
        guard envelope.expiresAt.timeIntervalSince(envelope.issuedAt) <= 300 else { throw QuickConnectLinkError.expiryTooLong }
        guard let code = envelope.pairingCode, !Self.normalizePairingCode(code).isEmpty else { throw QuickConnectLinkError.emptyPairingCode }
        guard !envelope.targets.isEmpty else { throw QuickConnectLinkError.invalidTarget }
        var seen = Set<String>()
        for target in envelope.targets {
            guard (1...65535).contains(target.port) else { throw QuickConnectLinkError.invalidPort }
            guard Self.validHost(target.hostname) else { throw QuickConnectLinkError.invalidTarget }
            let key = "\(QuickConnectProposal.normalized(target.hostname)):\(target.port)"
            guard seen.insert(key).inserted else { throw QuickConnectLinkError.duplicateTarget }
        }
        for key in envelope.hostKeys {
            guard ["ssh-ed25519", "ecdsa-sha2-nistp256", "rsa-sha2-512", "rsa-sha2-256", "ssh-rsa"].contains(key.algorithm) else { throw QuickConnectLinkError.unsupportedFingerprintAlgorithm(key.algorithm) }
            guard key.fingerprint.hasPrefix("SHA256:") else { throw QuickConnectLinkError.unsupportedFingerprintAlgorithm(key.algorithm) }
        }
    }

    private static func normalizePairingCode(_ code: String) -> String { code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
    private static func validHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.rangeOfCharacter(from: .whitespacesAndNewlines) == nil, host.rangeOfCharacter(from: .controlCharacters) == nil, !host.contains("@"), !host.contains("://") else { return false }
        return true
    }
}

private func base64URL(_ data: Data) -> String { data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
private func dataFromBase64URL(_ string: String) -> Data? {
    guard string.range(of: #"^[A-Za-z0-9_-]*$"#, options: .regularExpression) != nil else { return nil }
    var base64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while base64.count % 4 != 0 { base64.append("=") }
    return Data(base64Encoded: base64)
}
