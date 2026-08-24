import Foundation
import OpenPawTerminalCore
#if canImport(Darwin)
    import Darwin
#endif

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

public enum QuickConnectProfile: String, Sendable, Hashable, Codable {
    case observer
    case `operator`
}

public struct QuickConnectEnvelopeV1: Sendable, Hashable, Codable {
    public var version: Int
    public var issuedAt: Date
    public var expiresAt: Date
    public var sessionID: String
    public var hostAPIPort: Int
    public var profile: QuickConnectProfile
    public var pairingCode: String
    public var nickname: String
    public var username: String
    public var targets: [QuickConnectTarget]
    public var hostKeys: [QuickConnectHostKey]

    public init(version: Int = 1, issuedAt: Date, expiresAt: Date, sessionID: String, hostAPIPort: Int, profile: QuickConnectProfile, pairingCode: String, nickname: String, username: String, targets: [QuickConnectTarget], hostKeys: [QuickConnectHostKey] = []) {
        self.version = version; self.issuedAt = issuedAt; self.expiresAt = expiresAt; self.sessionID = sessionID; self.hostAPIPort = hostAPIPort; self.profile = profile; self.pairingCode = pairingCode; self.nickname = nickname; self.username = username; self.targets = targets; self.hostKeys = hostKeys
    }
    private enum CodingKeys: String, CodingKey { case version = "v", issuedAt = "issued_at", expiresAt = "expires_at", sessionID = "session_id", hostAPIPort = "host_api_port", profile, pairingCode = "pairing_code", nickname, username, targets, hostKeys = "host_keys" }
}

public struct QuickConnectProposal: Identifiable, Sendable, Hashable {
    public var id: String
    public var version: Int
    public var issuedAt: Date?
    public var expiresAt: Date?
    public var sessionID: String?
    public var hostAPIPort: Int?
    public var profile: QuickConnectProfile?
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
        return QuickConnectProposal(id: candidate.id, version: 1, issuedAt: nil, expiresAt: nil, sessionID: nil, hostAPIPort: nil, profile: nil, pairingCode: nil, nickname: candidate.nickname, username: "", dnsName: candidate.dnsName, tailscaleIPs: candidate.tailscaleIPs, online: candidate.online, targets: targets, hostKeys: [], envelope: nil)
    }

    public func matches(existing host: HostRecord) -> Bool {
        guard host.username == username else { return false }
        return targets.contains { target in
            target.port == host.port && QuickConnectLinkCodec.canonicalTargetKey(target.hostname) == QuickConnectLinkCodec.canonicalTargetKey(host.hostname)
        }
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

public struct QuickConnectStoredSecretRequest: Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible {
    public var data: Data
    public var reference: KeychainReference
    public var requiresUserPresence: Bool

    public init(data: Data, reference: KeychainReference, requiresUserPresence: Bool) {
        self.data = data
        self.reference = reference
        self.requiresUserPresence = requiresUserPresence
    }

    public var description: String {
        "QuickConnectStoredSecretRequest(data: <redacted>, reference: \(reference), requiresUserPresence: \(requiresUserPresence))"
    }

    public var debugDescription: String { description }
}

public enum QuickConnectCredentialReferences {
    public static let labelLimit = 64

    public static func reference(kind: String, transactionID: String, label: String) throws -> KeychainReference {
        let bounded = try boundedLabel(label)
        let transaction = try boundedLabel(transactionID)
        return try KeychainReference(identifier: "quick-connect/\(kind)/\(transaction)/\(bounded)")
    }

    public static func boundedLabel(_ label: String) throws -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= labelLimit else { throw QuickConnectCredentialInstallError.invalidLabel }
        guard trimmed.rangeOfCharacter(from: .controlCharacters) == nil else { throw QuickConnectCredentialInstallError.invalidLabel }
        return trimmed.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-" ? String($0) : "-" }.joined()
    }

    public static func storageRequests(for choice: QuickConnectCredentialChoice, transactionID: String = UUID().uuidString) throws -> (auth: AuthMethod, requests: [QuickConnectStoredSecretRequest]) {
        switch choice {
        case .existing(let auth):
            return (auth, [])
        case .password(let label, let secret):
            guard let data = secret.data(using: .utf8), !data.isEmpty else { throw QuickConnectCredentialInstallError.emptySecret }
            let ref = try reference(kind: "password", transactionID: transactionID, label: label)
            return (.password(reference: ref), [.init(data: data, reference: ref, requiresUserPresence: false)])
        case .privateKey(let label, let key, let passphraseLabel, let passphrase):
            guard !key.isEmpty else { throw QuickConnectCredentialInstallError.emptySecret }
            let keyRef = try reference(kind: "private-key", transactionID: transactionID, label: label)
            var requests = [QuickConnectStoredSecretRequest(data: key, reference: keyRef, requiresUserPresence: true)]
            let passRef: KeychainReference?
            if let passphrase, !passphrase.isEmpty {
                let ref = try reference(kind: "passphrase", transactionID: transactionID, label: passphraseLabel ?? "\(label)-passphrase")
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
    case duplicateJSONKey(String)
    case expired, expiryTooLong, emptyPairingCode, unsupportedFingerprintAlgorithm(String)
}

public struct QuickConnectLinkCodec: Sendable {
    public static let maxFragmentBytes = 4096
    public static let maxPayloadBytes = 3072
    public var now: @Sendable () -> Date
    public init(now: @escaping @Sendable () -> Date = Date.init) { self.now = now }

    public func encode(_ envelope: QuickConnectEnvelopeV1) throws -> URL {
        let canonical = try canonicalEnvelope(envelope, at: envelope.issuedAt, checkExpiry: false)
        return try encodeWithoutValidation(canonical)
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
        guard url.user == nil, url.password == nil, url.port == nil, url.path.isEmpty, url.query == nil else { throw QuickConnectLinkError.invalidHost }
        guard let fragment = url.fragment else { throw QuickConnectLinkError.missingFragment }
        guard fragment.utf8.count <= Self.maxFragmentBytes else { throw QuickConnectLinkError.oversizedFragment }
        guard fragment.hasPrefix("v") else { throw QuickConnectLinkError.invalidFragment }
        let parts = fragment.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { throw QuickConnectLinkError.invalidFragment }
        guard parts[0] == "v1" else { throw QuickConnectLinkError.unsupportedVersion(parts[0]) }
        guard let data = dataFromBase64URL(parts[1]) else { throw QuickConnectLinkError.invalidFragment }
        guard data.count <= Self.maxPayloadBytes else { throw QuickConnectLinkError.oversizedPayload }
        do {
            if let key = try DuplicateJSONKeyScanner.firstDuplicateKey(in: data) {
                throw QuickConnectLinkError.duplicateJSONKey(key)
            }
        } catch let error as QuickConnectLinkError {
            throw error
        } catch {
            throw QuickConnectLinkError.invalidFragment
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let envelope: QuickConnectEnvelopeV1
        do { envelope = try decoder.decode(QuickConnectEnvelopeV1.self, from: data) } catch { throw QuickConnectLinkError.invalidFragment }
        let canonical = try canonicalEnvelope(envelope, at: now(), checkExpiry: true)
        return QuickConnectProposal(id: UUID().uuidString, version: canonical.version, issuedAt: canonical.issuedAt, expiresAt: canonical.expiresAt, sessionID: canonical.sessionID, hostAPIPort: canonical.hostAPIPort, profile: canonical.profile, pairingCode: canonical.pairingCode, nickname: canonical.nickname, username: canonical.username, dnsName: canonical.targets.first(where: { $0.source == .magicDNS })?.hostname, tailscaleIPs: canonical.targets.filter { $0.source == .tailnet }.map(\.hostname), online: false, targets: canonical.targets, hostKeys: canonical.hostKeys, envelope: canonical)
    }

    private func validate(_ envelope: QuickConnectEnvelopeV1, at now: Date, checkExpiry: Bool) throws {
        _ = try canonicalEnvelope(envelope, at: now, checkExpiry: checkExpiry)
    }

    private func canonicalEnvelope(_ envelope: QuickConnectEnvelopeV1, at now: Date, checkExpiry: Bool) throws -> QuickConnectEnvelopeV1 {
        guard envelope.version == 1 else { throw QuickConnectLinkError.versionMismatch }
        if checkExpiry, now > envelope.expiresAt { throw QuickConnectLinkError.expired }
        let lifetime = envelope.expiresAt.timeIntervalSince(envelope.issuedAt)
        guard lifetime > 0, lifetime <= 300 else { throw QuickConnectLinkError.expiryTooLong }
        let sessionID = envelope.sessionID
        let hostAPIPort = envelope.hostAPIPort
        guard Self.validSessionID(sessionID) else { throw QuickConnectLinkError.invalidFragment }
        guard (1...65535).contains(hostAPIPort) else { throw QuickConnectLinkError.invalidPort }
        guard Self.validPrintable(envelope.nickname, max: 80), Self.validUsername(envelope.username) else { throw QuickConnectLinkError.invalidFragment }
        let pairingCode = try Self.canonicalPairingCode(envelope.pairingCode)
        guard (1...8).contains(envelope.targets.count) else { throw QuickConnectLinkError.invalidTarget }
        guard envelope.hostKeys.count <= 4 else { throw QuickConnectLinkError.unsupportedFingerprintAlgorithm(envelope.hostKeys.first?.algorithm ?? "") }
        var seen = Set<String>()
        var lastSourceRank = -1
        var canonicalTargets: [QuickConnectTarget] = []
        for target in envelope.targets {
            guard (1...65535).contains(target.port) else { throw QuickConnectLinkError.invalidPort }
            let rank = Self.sourceRank(target.source)
            guard rank >= lastSourceRank else { throw QuickConnectLinkError.invalidTarget }
            lastSourceRank = rank
            let canonicalHost = try Self.canonicalHost(target.hostname, source: target.source)
            let key = "\(canonicalHost):\(target.port)"
            guard seen.insert(key).inserted else { throw QuickConnectLinkError.duplicateTarget }
            canonicalTargets.append(QuickConnectTarget(hostname: canonicalHost, port: target.port, source: target.source))
        }
        for key in envelope.hostKeys {
            guard ["ssh-ed25519", "ecdsa-sha2-nistp256", "rsa-sha2-512", "rsa-sha2-256", "ssh-rsa"].contains(key.algorithm) else { throw QuickConnectLinkError.unsupportedFingerprintAlgorithm(key.algorithm) }
            guard Self.validSHA256Fingerprint(key.fingerprint) else { throw QuickConnectLinkError.unsupportedFingerprintAlgorithm(key.algorithm) }
        }
        return QuickConnectEnvelopeV1(version: envelope.version, issuedAt: envelope.issuedAt, expiresAt: envelope.expiresAt, sessionID: sessionID, hostAPIPort: hostAPIPort, profile: envelope.profile, pairingCode: pairingCode, nickname: envelope.nickname, username: envelope.username, targets: canonicalTargets, hostKeys: envelope.hostKeys)
    }

    private static func canonicalPairingCode(_ code: String) throws -> String {
        let canonical = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard canonical.range(of: #"^[A-Z2-7]{4}(-[A-Z2-7]{4}){5}$"#, options: .regularExpression) != nil else {
            if canonical.isEmpty { throw QuickConnectLinkError.emptyPairingCode }
            throw QuickConnectLinkError.invalidFragment
        }
        return canonical
    }
    private static func sourceRank(_ source: QuickConnectTarget.Source) -> Int {
        switch source { case .magicDNS: 0; case .tailnet: 1; case .explicit: 2 }
    }

    private static func validSessionID(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 64 && value.range(of: #"^[A-Za-z0-9._:-]+$"#, options: .regularExpression) != nil
    }

    private static func validPrintable(_ value: String, max: Int) -> Bool {
        value == value.trimmingCharacters(in: .whitespacesAndNewlines) && !value.isEmpty && value.count <= max && value.rangeOfCharacter(from: .controlCharacters) == nil
    }

    private static func validUsername(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 64 && value.range(of: #"^[A-Za-z_][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil
    }

    public static func canonicalTargetKey(_ host: String) -> String {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return (canonicalIPv4(trimmed) ?? canonicalIPv6(trimmed) ?? canonicalDNS(trimmed) ?? trimmed.lowercased())
    }

    private static func canonicalHost(_ host: String, source: QuickConnectTarget.Source) throws -> String {
        guard !host.isEmpty, host.rangeOfCharacter(from: .whitespacesAndNewlines) == nil, host.rangeOfCharacter(from: .controlCharacters) == nil, !host.contains("@"), !host.contains("://"), !host.contains("/"), !host.contains("[") && !host.contains("]") else { throw QuickConnectLinkError.invalidTarget }
        if let ip = canonicalIPv4(host) ?? canonicalIPv6(host) {
            return ip
        }
        guard !host.contains(":"), source != .tailnet, let dns = canonicalDNS(host) else { throw QuickConnectLinkError.invalidTarget }
        return dns
    }

    private static func canonicalDNS(_ host: String) -> String? {
        guard !host.hasPrefix(".") else { return nil }
        let lower = host.hasSuffix(".") ? String(host.dropLast()).lowercased() : host.lowercased()
        guard !lower.isEmpty, lower.count <= 253 else { return nil }
        let labels = lower.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ label in
            guard (1...63).contains(label.count), let first = label.first, let last = label.last, first.isASCII, last.isASCII, (first.isLetter || first.isNumber), (last.isLetter || last.isNumber) else { return false }
            return label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }) else { return nil }
        return lower
    }

    private static func canonicalIPv4(_ host: String) -> String? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [String] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isNumber), let value = Int(part), (0...255).contains(value) else { return nil }
            octets.append(String(value))
        }
        return octets.joined(separator: ".")
    }

    private static func canonicalIPv6(_ host: String) -> String? {
        #if canImport(Darwin)
            var addr = in6_addr()
            guard host.withCString({ inet_pton(AF_INET6, $0, &addr) }) == 1 else { return nil }
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            return withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: UInt8.self, capacity: MemoryLayout<in6_addr>.size) { bytes in
                    inet_ntop(AF_INET6, bytes, &buffer, socklen_t(INET6_ADDRSTRLEN)).map { String(cString: $0).lowercased() }
                }
            }
        #else
            return nil
        #endif
    }

    private static func validSHA256Fingerprint(_ fingerprint: String) -> Bool {
        guard fingerprint.hasPrefix("SHA256:") else { return false }
        let payload = String(fingerprint.dropFirst("SHA256:".count))
        guard !payload.isEmpty, !payload.contains("="), payload.range(of: #"^[A-Za-z0-9+/]+$"#, options: .regularExpression) != nil else { return false }
        var padded = payload
        while padded.count % 4 != 0 { padded.append("=") }
        return Data(base64Encoded: padded)?.count == 32
    }
}

private struct DuplicateJSONKeyScanner {
    private enum ScanError: Error { case invalidJSON }

    private let bytes: [UInt8]
    private var index = 0

    static func firstDuplicateKey(in data: Data) throws -> String? {
        var scanner = DuplicateJSONKeyScanner(bytes: Array(data))
        let duplicate = try scanner.scanValue()
        if duplicate != nil { return duplicate }
        scanner.skipWhitespace()
        guard scanner.index == scanner.bytes.count else { throw ScanError.invalidJSON }
        return nil
    }

    private mutating func scanValue() throws -> String? {
        skipWhitespace()
        guard let byte = current else { throw ScanError.invalidJSON }
        switch byte {
        case 0x7B: return try scanObject()
        case 0x5B: return try scanArray()
        case 0x22:
            try scanString()
            return nil
        case 0x74:
            try scanLiteral("true")
            return nil
        case 0x66:
            try scanLiteral("false")
            return nil
        case 0x6E:
            try scanLiteral("null")
            return nil
        case 0x2D, 0x30 ... 0x39:
            try scanNumber()
            return nil
        default:
            throw ScanError.invalidJSON
        }
    }

    private mutating func scanObject() throws -> String? {
        try consume(0x7B)
        skipWhitespace()
        if consumeIfPresent(0x7D) { return nil }

        var keys = Set<String>()
        while true {
            skipWhitespace()
            let keyRange = try scanString()
            let key = try JSONDecoder().decode(String.self, from: Data(bytes[keyRange]))
            if !keys.insert(key).inserted { return key }
            skipWhitespace()
            try consume(0x3A)
            if let nestedDuplicate = try scanValue() { return nestedDuplicate }
            skipWhitespace()
            if consumeIfPresent(0x7D) { return nil }
            try consume(0x2C)
        }
    }

    private mutating func scanArray() throws -> String? {
        try consume(0x5B)
        skipWhitespace()
        if consumeIfPresent(0x5D) { return nil }

        while true {
            if let nestedDuplicate = try scanValue() { return nestedDuplicate }
            skipWhitespace()
            if consumeIfPresent(0x5D) { return nil }
            try consume(0x2C)
        }
    }

    @discardableResult
    private mutating func scanString() throws -> Range<Int> {
        let start = index
        try consume(0x22)
        while let byte = current {
            index += 1
            switch byte {
            case 0x22:
                return start ..< index
            case 0x5C:
                guard let escaped = current else { throw ScanError.invalidJSON }
                index += 1
                if escaped == 0x75 {
                    for _ in 0 ..< 4 {
                        guard let hex = current, Self.isHexDigit(hex) else { throw ScanError.invalidJSON }
                        index += 1
                    }
                } else if ![0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74].contains(escaped) {
                    throw ScanError.invalidJSON
                }
            case 0x00 ... 0x1F:
                throw ScanError.invalidJSON
            default:
                continue
            }
        }
        throw ScanError.invalidJSON
    }

    private mutating func scanLiteral(_ literal: StaticString) throws {
        for expected in String(describing: literal).utf8 { try consume(expected) }
    }

    private mutating func scanNumber() throws {
        let start = index
        while let byte = current, [0x2B, 0x2D, 0x2E, 0x45, 0x65].contains(byte) || (0x30 ... 0x39).contains(byte) {
            index += 1
        }
        guard index > start else { throw ScanError.invalidJSON }
    }

    private mutating func skipWhitespace() {
        while let byte = current, [0x20, 0x09, 0x0A, 0x0D].contains(byte) { index += 1 }
    }

    private var current: UInt8? { index < bytes.count ? bytes[index] : nil }

    private mutating func consume(_ expected: UInt8) throws {
        guard current == expected else { throw ScanError.invalidJSON }
        index += 1
    }

    private mutating func consumeIfPresent(_ expected: UInt8) -> Bool {
        guard current == expected else { return false }
        index += 1
        return true
    }

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        (0x30 ... 0x39).contains(byte) || (0x41 ... 0x46).contains(byte) || (0x61 ... 0x66).contains(byte)
    }
}

private func base64URL(_ data: Data) -> String { data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
private func dataFromBase64URL(_ string: String) -> Data? {
    guard string.range(of: #"^[A-Za-z0-9_-]*$"#, options: .regularExpression) != nil else { return nil }
    var base64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while base64.count % 4 != 0 { base64.append("=") }
    return Data(base64Encoded: base64)
}
