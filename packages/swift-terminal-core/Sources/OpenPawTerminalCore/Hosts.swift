import CryptoKit
import Foundation

public typealias HostID = UUID

public enum HostStoreError: Error, Sendable, Hashable, CustomStringConvertible {
    /// Something that must be a keychain identifier contained secret material.
    case inlinedSecret(field: String)
    case invalidReference(String)
    case unsupportedVersion(Int)
    case unknownHost(HostID)

    public var description: String {
        switch self {
        case .inlinedSecret(let field):
            return "refusing to carry private key material: \(field)"
        case .invalidReference(let detail):
            return "invalid keychain reference: \(detail)"
        case .unsupportedVersion(let version):
            return "host store version \(version) is not supported"
        case .unknownHost(let id):
            return "no host with id \(id.uuidString)"
        }
    }
}

// MARK: - Known hosts

/// One trusted host key, stored the way OpenSSH prints it.
public struct KnownHostEntry: Sendable, Hashable, Codable {
    /// e.g. `ssh-ed25519`, `ecdsa-sha2-nistp256`.
    public var keyType: String
    /// `SHA256:` followed by unpadded base64, matching `ssh-keygen -lf`.
    public var fingerprint: String
    public var addedAt: Date

    public init(keyType: String, fingerprint: String, addedAt: Date) {
        self.keyType = keyType
        self.fingerprint = fingerprint
        self.addedAt = addedAt
    }

    public init(keyType: String, publicKeyBlob: Data, addedAt: Date) {
        self.init(
            keyType: keyType,
            fingerprint: Self.fingerprint(forPublicKeyBlob: publicKeyBlob),
            addedAt: addedAt)
    }

    /// Formats an SSH public key blob the way OpenSSH does: `SHA256:` plus
    /// base64 of the digest with padding removed.
    public static func fingerprint(forPublicKeyBlob blob: Data) -> String {
        format(sha256Digest: Data(SHA256.hash(data: blob)))
    }

    /// Formats an already computed SHA-256 digest.
    public static func format(sha256Digest digest: Data) -> String {
        var base64 = digest.base64EncodedString()
        while base64.hasSuffix("=") { base64.removeLast() }
        return "SHA256:" + base64
    }

    private enum CodingKeys: String, CodingKey {
        case keyType = "key_type"
        case fingerprint
        case addedAt = "added_at"
    }
}

/// The outcome of comparing a presented host key against what we trust.
public enum HostKeyVerdict: Sendable, Hashable, CustomStringConvertible {
    case trusted
    case unknown(fingerprint: String)
    case changed(expected: String, actual: String)

    /// A changed host key is a hard block by contract: it is indistinguishable
    /// from an interception, so OpenPaw never offers "continue anyway".
    public var isBlocking: Bool {
        if case .changed = self { return true }
        return false
    }

    public var description: String {
        switch self {
        case .trusted:
            return "trusted"
        case .unknown(let fingerprint):
            return "unknown key \(fingerprint)"
        case .changed(let expected, let actual):
            return "key changed, expected \(expected) but got \(actual)"
        }
    }
}

// MARK: - Host record

public struct HostRecord: Sendable, Hashable, Codable, Identifiable {
    public var id: HostID
    public var nickname: String
    public var hostname: String
    public var port: Int
    /// Optional remote `openpaw-host` structured API port. Nil preserves legacy hosts and means the app default.
    public var hostAPIPort: UInt16?
    public var username: String
    public var auth: AuthMethod
    /// Pinned by the user; `nil` means the `auto` policy chooses.
    public var preferredTransport: TransportKind?
    /// Recorded by ``HostStore/recordSuccessfulTransport(_:for:)`` after a
    /// successful connection so `auto` tries the known-good option first.
    public var lastSuccessfulTransport: TransportKind?
    public var multiplexerPreference: MultiplexerKind?
    public var knownHosts: [KnownHostEntry]
    public var tags: [String]

    public init(
        id: HostID = UUID(),
        nickname: String,
        hostname: String,
        port: Int = 22,
        hostAPIPort: UInt16? = nil,
        username: String,
        auth: AuthMethod,
        preferredTransport: TransportKind? = nil,
        lastSuccessfulTransport: TransportKind? = nil,
        multiplexerPreference: MultiplexerKind? = nil,
        knownHosts: [KnownHostEntry] = [],
        tags: [String] = []
    ) {
        self.id = id
        self.nickname = nickname
        self.hostname = hostname
        self.port = port
        self.hostAPIPort = hostAPIPort
        self.username = username
        self.auth = auth
        self.preferredTransport = preferredTransport
        self.lastSuccessfulTransport = lastSuccessfulTransport
        self.multiplexerPreference = multiplexerPreference
        self.knownHosts = knownHosts
        self.tags = tags
    }

    /// Compares a presented key against the pins for this host.
    ///
    /// A pin for the same key type with a different fingerprint is `changed`; no
    /// pin for that key type at all is `unknown`.
    public func verdict(forKeyType keyType: String, fingerprint: String) -> HostKeyVerdict {
        let pinsForType = knownHosts.filter { $0.keyType == keyType }
        if pinsForType.contains(where: { $0.fingerprint == fingerprint }) {
            return .trusted
        }
        if let expected = pinsForType.first {
            return .changed(expected: expected.fingerprint, actual: fingerprint)
        }
        return .unknown(fingerprint: fingerprint)
    }

    private enum CodingKeys: String, CodingKey {
        case id, nickname, hostname, port, username, auth
        case hostAPIPort = "host_api_port"
        case preferredTransport = "preferred_transport"
        case lastSuccessfulTransport = "last_successful_transport"
        case multiplexerPreference = "multiplexer_preference"
        case knownHosts = "known_hosts"
        case tags
    }
}

// MARK: - Host store

/// The device's host list. Serialises to versioned JSON for config sync; by
/// construction it can only carry keychain references, never key material.
public struct HostStore: Sendable, Hashable, Codable {
    public static let currentVersion = 1

    public var version: Int
    public var hosts: [HostRecord]

    public init(version: Int = HostStore.currentVersion, hosts: [HostRecord] = []) {
        self.version = version
        self.hosts = hosts
    }

    public subscript(id: HostID) -> HostRecord? {
        hosts.first { $0.id == id }
    }

    public mutating func upsert(_ host: HostRecord) {
        if let index = hosts.firstIndex(where: { $0.id == host.id }) {
            hosts[index] = host
        } else {
            hosts.append(host)
        }
    }

    public mutating func remove(id: HostID) {
        hosts.removeAll { $0.id == id }
    }

    /// Remembers the transport that actually worked, so the next `auto` plan
    /// leads with it.
    public mutating func recordSuccessfulTransport(_ kind: TransportKind, for id: HostID) throws {
        guard let index = hosts.firstIndex(where: { $0.id == id }) else {
            throw HostStoreError.unknownHost(id)
        }
        hosts[index].lastSuccessfulTransport = kind
    }

    /// Pins a host key, replacing any previous pin of the same key type.
    public mutating func trust(_ entry: KnownHostEntry, for id: HostID) throws {
        guard let index = hosts.firstIndex(where: { $0.id == id }) else {
            throw HostStoreError.unknownHost(id)
        }
        hosts[index].knownHosts.removeAll { $0.keyType == entry.keyType }
        hosts[index].knownHosts.append(entry)
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Versioned JSON for transferring the host list between devices.
    ///
    /// Credentials appear only as keychain identifiers: ``KeychainReference``
    /// cannot hold key material, so an export physically cannot leak a key.
    public func export() throws -> Data {
        var copy = self
        copy.version = Self.currentVersion
        return try Self.encoder().encode(copy)
    }

    public static func `import`(from data: Data) throws -> HostStore {
        let store = try decoder().decode(HostStore.self, from: data)
        guard store.version == currentVersion else {
            throw HostStoreError.unsupportedVersion(store.version)
        }
        return store
    }
}
