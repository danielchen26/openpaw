import Foundation

// MARK: - Transport kinds

/// A remote terminal transport implementation.
public enum TransportKind: String, Sendable, Codable, Hashable, CaseIterable {
    /// Plain SSH channel with a PTY. Always available.
    case ssh
    /// Mosh (UDP, roaming, local echo). Requires `mosh-server` on the host.
    case mosh
    /// Eternal Terminal (TCP, reconnecting). Requires `etserver` on the host.
    case eternalTerminal

    /// Human readable name used in user facing fallback explanations.
    public var displayName: String {
        switch self {
        case .ssh: return "SSH"
        case .mosh: return "Mosh"
        case .eternalTerminal: return "Eternal Terminal"
        }
    }

    /// The host side binary whose absence makes this transport unusable.
    public var remoteBinary: String? {
        switch self {
        case .ssh: return nil
        case .mosh: return "mosh-server"
        case .eternalTerminal: return "etserver"
        }
    }
}

// MARK: - Credentials

/// A pointer into the platform keychain. Secret material never travels inside
/// OpenPaw value types, only these opaque identifiers do.
public struct KeychainReference: Sendable, Hashable, Codable, CustomStringConvertible {
    /// Longest identifier we accept. Keychain accounts are short; anything
    /// longer is almost certainly inlined material.
    public static let maximumIdentifierLength = 256

    public let identifier: String

    /// Creates a reference, rejecting anything that looks like inlined secret
    /// material rather than an identifier.
    public init(identifier: String) throws {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw HostStoreError.invalidReference("keychain reference must not be empty")
        }
        guard trimmed.count <= Self.maximumIdentifierLength else {
            throw HostStoreError.invalidReference(
                "keychain reference longer than \(Self.maximumIdentifierLength) characters")
        }
        guard !trimmed.contains(where: { $0 == "\n" || $0 == "\r" }) else {
            throw HostStoreError.inlinedSecret(field: "keychain reference contains a newline")
        }
        for marker in Self.secretMarkers where trimmed.uppercased().contains(marker) {
            throw HostStoreError.inlinedSecret(field: "keychain reference contains \(marker)")
        }
        self.identifier = trimmed
    }

    private static let secretMarkers = [
        "BEGIN OPENSSH PRIVATE KEY",
        "BEGIN RSA PRIVATE KEY",
        "BEGIN EC PRIVATE KEY",
        "BEGIN DSA PRIVATE KEY",
        "BEGIN PRIVATE KEY",
        "BEGIN ENCRYPTED PRIVATE KEY",
        "PUTTY-USER-KEY-FILE",
    ]

    public var description: String { identifier }

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        try self.init(identifier: raw)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(identifier)
    }
}

/// How a connection authenticates. Every variant references the keychain; no
/// variant can carry a password or key blob.
public enum AuthMethod: Sendable, Hashable, Codable {
    case password(reference: KeychainReference)
    case privateKey(reference: KeychainReference, passphraseRef: KeychainReference?)
    case agentForwarding

    private enum CodingKeys: String, CodingKey {
        case method
        case passwordReference = "password_reference"
        case keyReference = "key_reference"
        case passphraseReference = "passphrase_reference"
    }

    private enum Tag: String, Codable {
        case password
        case privateKey = "private-key"
        case agentForwarding = "agent-forwarding"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Tag.self, forKey: .method) {
        case .password:
            self = .password(
                reference: try container.decode(KeychainReference.self, forKey: .passwordReference))
        case .privateKey:
            self = .privateKey(
                reference: try container.decode(KeychainReference.self, forKey: .keyReference),
                passphraseRef: try container.decodeIfPresent(
                    KeychainReference.self, forKey: .passphraseReference))
        case .agentForwarding:
            self = .agentForwarding
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .password(let reference):
            try container.encode(Tag.password, forKey: .method)
            try container.encode(reference, forKey: .passwordReference)
        case .privateKey(let reference, let passphraseRef):
            try container.encode(Tag.privateKey, forKey: .method)
            try container.encode(reference, forKey: .keyReference)
            try container.encodeIfPresent(passphraseRef, forKey: .passphraseReference)
        case .agentForwarding:
            try container.encode(Tag.agentForwarding, forKey: .method)
        }
    }
}

// MARK: - PTY geometry

/// Terminal window size in character cells.
public struct PTYSize: Sendable, Hashable, Codable {
    public var columns: Int
    public var rows: Int

    public init(columns: Int, rows: Int) {
        self.columns = max(1, columns)
        self.rows = max(1, rows)
    }

    public static let `default` = PTYSize(columns: 80, rows: 24)
}

// MARK: - Configuration

/// Everything needed to open a remote terminal, persistable as JSON because it
/// contains no secret material.
public struct ConnectionConfiguration: Sendable, Hashable, Codable {
    public var host: String
    public var port: Int
    public var username: String
    public var auth: AuthMethod
    /// `TERM` advertised to the remote PTY.
    public var terminalType: String
    public var initialSize: PTYSize
    public var keepaliveInterval: Duration?
    /// ProxyJump chain, applied in order: element 0 is dialed first.
    public var jumpHosts: [ConnectionConfiguration]
    /// Extra environment variables requested on the channel.
    public var environment: [String: String]
    /// `nil` means "let the selector decide" (the `auto` policy).
    public var requestedTransport: TransportKind?
    public var connectTimeout: Duration

    public init(
        host: String,
        port: Int = 22,
        username: String,
        auth: AuthMethod,
        terminalType: String = "xterm-256color",
        initialSize: PTYSize = .default,
        keepaliveInterval: Duration? = .seconds(30),
        jumpHosts: [ConnectionConfiguration] = [],
        environment: [String: String] = [:],
        requestedTransport: TransportKind? = nil,
        connectTimeout: Duration = .seconds(15)
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.auth = auth
        self.terminalType = terminalType
        self.initialSize = initialSize
        self.keepaliveInterval = keepaliveInterval
        self.jumpHosts = jumpHosts
        self.environment = environment
        self.requestedTransport = requestedTransport
        self.connectTimeout = connectTimeout
    }

    private enum CodingKeys: String, CodingKey {
        case host
        case port
        case username
        case auth
        case terminalType = "terminal_type"
        case initialSize = "initial_size"
        case keepaliveInterval = "keepalive_interval"
        case jumpHosts = "jump_hosts"
        case environment
        case requestedTransport = "requested_transport"
        case connectTimeout = "connect_timeout"
    }
}

// MARK: - Errors

public enum TransportError: Error, Sendable, Hashable, CustomStringConvertible {
    /// Transport is not compiled into this build.
    case unavailable(TransportKind)
    /// Transport is compiled in but the host lacks its server binary.
    case remoteBinaryMissing(TransportKind, command: String)
    case nameResolutionFailed(host: String)
    case connectionRefused(host: String, port: Int)
    case connectionFailed(String)
    case timeout
    case authenticationFailed(reason: String)
    case hostKeyUnknown(fingerprint: String)
    case hostKeyChanged(expected: String, actual: String)
    case unsupportedKeyType(String)
    case invalidPrivateKey(String)
    case jumpHostFailed(hop: Int, reason: String)
    case ptyRequestFailed(reason: String)
    case channelClosed(reason: String)
    case protocolViolation(detail: String)
    case notConnected
    case outputLimitExceeded
    case cancelled

    public var description: String {
        switch self {
        case .unavailable(let kind):
            return "\(kind.displayName) is not available in this build"
        case .remoteBinaryMissing(let kind, let command):
            return "\(kind.displayName) is not installed on the host (`\(command)` not found)"
        case .nameResolutionFailed(let host):
            return "could not resolve \(host)"
        case .connectionRefused(let host, let port):
            return "connection refused by \(host):\(port)"
        case .connectionFailed(let detail):
            return "connection failed (\(detail))"
        case .timeout:
            return "the connection attempt timed out"
        case .authenticationFailed(let reason):
            return "authentication failed (\(reason))"
        case .hostKeyUnknown(let fingerprint):
            return "host key \(fingerprint) is not known"
        case .hostKeyChanged(let expected, let actual):
            return "host key changed, expected \(expected) but got \(actual)"
        case .unsupportedKeyType(let type):
            return "unsupported host key type \(type)"
        case .invalidPrivateKey(let detail):
            return "private key could not be parsed (\(detail))"
        case .jumpHostFailed(let hop, let reason):
            return "jump host \(hop) failed (\(reason))"
        case .ptyRequestFailed(let reason):
            return "the host refused a PTY (\(reason))"
        case .channelClosed(let reason):
            return "the channel closed (\(reason))"
        case .protocolViolation(let detail):
            return "protocol violation (\(detail))"
        case .notConnected:
            return "not connected"
        case .outputLimitExceeded:
            return "the host produced more output than the transport allows"
        case .cancelled:
            return "the connection attempt was cancelled"
        }
    }

    /// True when retrying a *different* transport can plausibly succeed.
    public var allowsTransportFallback: Bool {
        switch self {
        case .unavailable, .remoteBinaryMissing, .connectionRefused, .timeout,
            .connectionFailed, .ptyRequestFailed, .protocolViolation:
            return true
        case .nameResolutionFailed, .authenticationFailed, .hostKeyUnknown, .hostKeyChanged,
            .unsupportedKeyType, .invalidPrivateKey, .jumpHostFailed, .channelClosed,
            .notConnected, .outputLimitExceeded, .cancelled:
            return false
        }
    }
}

// MARK: - Connection state

public enum ConnectionState: Sendable, Equatable {
    case idle
    case resolving
    case connecting
    case authenticating
    case connected(TransportKind)
    case reconnecting(attempt: Int, reason: String)
    case disconnected(reason: String?)
    case failed(TransportError)

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    public var isTerminal: Bool {
        switch self {
        case .disconnected, .failed: return true
        default: return false
        }
    }
}

// MARK: - The seam

/// The single seam every transport implements. `OpenPawSSH` provides the SSH,
/// mosh and Eternal Terminal conformances; `MockTransport` provides the
/// in-memory one used by tests and previews.
public protocol RemoteTransport: Sendable {
    var state: AsyncStream<ConnectionState> { get }
    var output: AsyncStream<Data> { get }
    func connect(configuration: ConnectionConfiguration) async throws
    func write(_ data: Data) async throws
    func resize(columns: Int, rows: Int) async throws
    func disconnect() async
}
