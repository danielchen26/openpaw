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

    public func credentialConfirmationCandidate(in store: HostStore) -> QuickConnectCredentialConfirmation? {
        guard let host = store.hosts.first(where: { matches(existing: $0) }) else { return nil }
        return QuickConnectCredentialConfirmation(choice: .existing(host.auth), profile: host, requiresExplicitConfirmation: true)
    }

    fileprivate static func normalized(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased() }
}

public struct QuickConnectCredentialConfirmation: Sendable, Hashable {
    public var choice: QuickConnectCredentialChoice
    public var profile: HostRecord
    public var requiresExplicitConfirmation: Bool

    public init(choice: QuickConnectCredentialChoice, profile: HostRecord, requiresExplicitConfirmation: Bool = true) {
        self.choice = choice
        self.profile = profile
        self.requiresExplicitConfirmation = requiresExplicitConfirmation
    }
}

public enum QuickConnectCredentialChoice: Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible {
    case existing(AuthMethod)
    case password(label: String, secret: String)
    case privateKey(label: String, key: Data, passphraseLabel: String?, passphrase: String?)

    public var description: String {
        switch self {
        case .existing(let auth):
            return "QuickConnectCredentialChoice.existing(\(auth))"
        case .password(let label, _):
            return "QuickConnectCredentialChoice.password(label: \(String(reflecting: label)), secret: <redacted>)"
        case .privateKey(let label, _, let passphraseLabel, let passphrase):
            let redactedPassphrase = passphrase == nil ? "nil" : "<redacted>"
            return "QuickConnectCredentialChoice.privateKey(label: \(String(reflecting: label)), key: <redacted>, passphraseLabel: \(String(reflecting: passphraseLabel)), passphrase: \(redactedPassphrase))"
        }
    }

    public var debugDescription: String { description }
}

public enum QuickConnectCredentialInstallError: Error, Sendable, Hashable, CustomStringConvertible {
    case invalidLabel
    case emptySecret
    case storageFailed

    public var description: String {
        switch self {
        case .invalidLabel: "Invalid credential label."
        case .emptySecret: "Credential secret is empty."
        case .storageFailed: "Credential storage failed."
        }
    }
}

public protocol QuickConnectCredentialInstalling: Sendable {
    func install(_ choice: QuickConnectCredentialChoice) async throws -> AuthMethod
}

public struct QuickConnectStoredSecretRequest: Sendable, Hashable {
    public var data: Data
    public var reference: KeychainReference
    public var requiresUserPresence: Bool

    public init(data: Data, reference: KeychainReference, requiresUserPresence: Bool) {
        self.data = data
        self.reference = reference
        self.requiresUserPresence = requiresUserPresence
    }
}

public enum QuickConnectCredentialReferences {
    public static let labelLimit = 64

    public static func reference(kind: String, label: String) throws -> KeychainReference {
        let bounded = try boundedLabel(label)
        return try KeychainReference(identifier: "quick-connect/\(kind)/\(bounded)")
    }

    public static func boundedLabel(_ label: String) throws -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= labelLimit else { throw QuickConnectCredentialInstallError.invalidLabel }
        guard trimmed.rangeOfCharacter(from: .controlCharacters) == nil else { throw QuickConnectCredentialInstallError.invalidLabel }
        return trimmed.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-" ? String($0) : "-" }.joined()
    }

    public static func storageRequests(for choice: QuickConnectCredentialChoice) throws -> (auth: AuthMethod, requests: [QuickConnectStoredSecretRequest]) {
        switch choice {
        case .existing(let auth):
            return (auth, [])
        case .password(let label, let secret):
            guard let data = secret.data(using: .utf8), !data.isEmpty else { throw QuickConnectCredentialInstallError.emptySecret }
            let ref = try reference(kind: "password", label: label)
            return (.password(reference: ref), [.init(data: data, reference: ref, requiresUserPresence: false)])
        case .privateKey(let label, let key, let passphraseLabel, let passphrase):
            guard !key.isEmpty else { throw QuickConnectCredentialInstallError.emptySecret }
            let keyRef = try reference(kind: "private-key", label: label)
            var requests = [QuickConnectStoredSecretRequest(data: key, reference: keyRef, requiresUserPresence: true)]
            let passRef: KeychainReference?
            if let passphrase, !passphrase.isEmpty {
                let ref = try reference(kind: "passphrase", label: passphraseLabel ?? "\(label)-passphrase")
                guard let data = passphrase.data(using: .utf8), !data.isEmpty else { throw QuickConnectCredentialInstallError.emptySecret }
                requests.append(.init(data: data, reference: ref, requiresUserPresence: false))
                passRef = ref
            } else {
                passRef = nil
            }
            return (.privateKey(reference: keyRef, passphraseRef: passRef), requests)
        }
    }
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
