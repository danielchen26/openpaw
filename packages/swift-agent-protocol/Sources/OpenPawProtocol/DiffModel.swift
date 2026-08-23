import Foundation

// MARK: - Session summaries

public enum SessionState: String, Codable, Sendable, Hashable, CaseIterable {
    case idle
    case working
    case waiting
    case failed
    case exited
}

public struct SessionSummary: Codable, Sendable, Hashable, Identifiable {
    public let sessionID: String
    public let agent: AgentKind
    public let title: String?
    public let cwd: String?
    public let gitBranch: String?
    public let multiplexerTarget: String?
    public let state: SessionState
    public var lastEventAt: Date?
    public var lastSeq: UInt64
    public let pendingInbox: Int

    public var id: String { sessionID }

    public init(
        sessionID: String,
        agent: AgentKind,
        title: String? = nil,
        cwd: String? = nil,
        gitBranch: String? = nil,
        multiplexerTarget: String? = nil,
        state: SessionState,
        lastEventAt: Date? = nil,
        lastSeq: UInt64 = 0,
        pendingInbox: Int = 0
    ) {
        self.sessionID = sessionID
        self.agent = agent
        self.title = title
        self.cwd = cwd
        self.gitBranch = gitBranch
        self.multiplexerTarget = multiplexerTarget
        self.state = state
        self.lastEventAt = lastEventAt
        self.lastSeq = lastSeq
        self.pendingInbox = pendingInbox
    }

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case agent
        case title
        case cwd
        case gitBranch = "git_branch"
        case multiplexerTarget = "multiplexer_target"
        case state
        case lastEventAt = "last_event_at"
        case lastSeq = "last_seq"
        case pendingInbox = "pending_inbox"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        agent = try container.decode(AgentKind.self, forKey: .agent)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        gitBranch = try container.decodeIfPresent(String.self, forKey: .gitBranch)
        multiplexerTarget = try container.decodeIfPresent(String.self, forKey: .multiplexerTarget)
        state = try container.decode(SessionState.self, forKey: .state)
        lastEventAt = try container.decodeIfPresent(Date.self, forKey: .lastEventAt)
        lastSeq = try container.decodeIfPresent(UInt64.self, forKey: .lastSeq) ?? 0
        pendingInbox = try container.decodeIfPresent(Int.self, forKey: .pendingInbox) ?? 0
    }
}

// MARK: - Audit

public struct AuditEntry: Codable, Sendable, Hashable, Identifiable {
    public let at: Date
    public let deviceID: String?
    public let action: String
    public let target: String?
    public let result: String

    /// Audit entries have no server side identifier; timestamp plus action is unique
    /// enough for list identity.
    public var id: String { "\(at.timeIntervalSince1970)|\(action)" }

    public init(at: Date, deviceID: String?, action: String, target: String?, result: String) {
        self.at = at
        self.deviceID = deviceID
        self.action = action
        self.target = target
        self.result = result
    }

    enum CodingKeys: String, CodingKey {
        case at
        case deviceID = "device_id"
        case action
        case target
        case result
    }
}

// MARK: - Host responses

public struct HealthInfo: Codable, Sendable, Hashable {
    public let version: String
    public let protocolVersion: String
    public let agents: [AgentKind]
    public let capabilities: [String]
    /// Loopback ports the host will proxy for dev-server preview. Typed rather than encoded into a capability
    /// string, so the preview picker can offer exactly what will work instead of probing and failing.
    public let previewPorts: [Int]
    /// Adapter identity, e.g. `["claude-code": "claude-code/transcript-v1"]`. Shown in diagnostics because these
    /// agent formats move, and knowing which parser is running is the first question in any bug report.
    public let adapterVersions: [String: String]

    public init(
        version: String,
        protocolVersion: String,
        agents: [AgentKind],
        capabilities: [String],
        previewPorts: [Int] = [],
        adapterVersions: [String: String] = [:]
    ) {
        self.version = version
        self.protocolVersion = protocolVersion
        self.agents = agents
        self.capabilities = capabilities
        self.previewPorts = previewPorts
        self.adapterVersions = adapterVersions
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(String.self, forKey: .version)
        protocolVersion = try container.decode(String.self, forKey: .protocolVersion)
        agents = try container.decodeIfPresent([AgentKind].self, forKey: .agents) ?? []
        capabilities = try container.decodeIfPresent([String].self, forKey: .capabilities) ?? []
        previewPorts = try container.decodeIfPresent([Int].self, forKey: .previewPorts) ?? []
        adapterVersions = try container
            .decodeIfPresent([String: String].self, forKey: .adapterVersions) ?? [:]
    }

    enum CodingKeys: String, CodingKey {
        case version
        case protocolVersion = "protocol"
        case agents
        case capabilities
        case previewPorts = "preview_ports"
        case adapterVersions = "adapter_versions"
    }
}

public struct PairingResult: Codable, Sendable, Hashable {
    public let deviceID: String
    public let token: String
    public let hmacKeyB64: String
    public let capabilities: [String]

    public init(deviceID: String, token: String, hmacKeyB64: String, capabilities: [String]) {
        self.deviceID = deviceID
        self.token = token
        self.hmacKeyB64 = hmacKeyB64
        self.capabilities = capabilities
    }

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case token
        case hmacKeyB64 = "hmac_key_b64"
        case capabilities
    }

    /// Signer built from this pairing, or `nil` if the host sent an unparsable key.
    public var signer: RequestSigner? {
        RequestSigner(deviceID: deviceID, token: token, hmacKeyBase64: hmacKeyB64)
    }
}

public struct ResolveResult: Codable, Sendable, Hashable {
    public let status: String
    public let eventID: String?

    public init(status: String, eventID: String?) {
        self.status = status
        self.eventID = eventID
    }

    enum CodingKeys: String, CodingKey {
        case status
        case eventID = "event_id"
    }
}

public struct UploadResult: Codable, Sendable, Hashable {
    public let path: String
    public let bytes: UInt64
    public let sha256: String

    public init(path: String, bytes: UInt64, sha256: String) {
        self.path = path
        self.bytes = bytes
        self.sha256 = sha256
    }
}

// MARK: - Repositories

public struct RepoSummary: Codable, Sendable, Hashable, Identifiable {
    public let name: String
    public let path: String
    /// `nil` when HEAD is detached.
    public let branch: String?
    public let dirty: Bool
    public let ahead: UInt32
    public let behind: UInt32

    public var id: String { path }

    public init(
        name: String, path: String, branch: String?, dirty: Bool, ahead: UInt32, behind: UInt32
    ) {
        self.name = name
        self.path = path
        self.branch = branch
        self.dirty = dirty
        self.ahead = ahead
        self.behind = behind
    }
}

/// One path in `GET /v1/repos/{repo}/status`.
public struct StatusEntry: Codable, Sendable, Hashable, Identifiable {
    public let path: String
    public let oldPath: String?
    public let change: ChangeKind

    public var id: String { path }

    public init(path: String, oldPath: String? = nil, change: ChangeKind) {
        self.path = path
        self.oldPath = oldPath
        self.change = change
    }

    enum CodingKeys: String, CodingKey {
        case path
        case oldPath = "old_path"
        case change
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        oldPath = try container.decodeIfPresent(String.self, forKey: .oldPath)
        change = try container.decode(ChangeKind.self, forKey: .change)
    }
}

public struct RepoStatus: Codable, Sendable, Hashable {
    public let branch: String
    public let ahead: Int
    public let behind: Int
    public let staged: [StatusEntry]
    public let unstaged: [StatusEntry]
    public let untracked: [StatusEntry]

    public init(
        branch: String,
        ahead: Int = 0,
        behind: Int = 0,
        staged: [StatusEntry] = [],
        unstaged: [StatusEntry] = [],
        untracked: [StatusEntry] = []
    ) {
        self.branch = branch
        self.ahead = ahead
        self.behind = behind
        self.staged = staged
        self.unstaged = unstaged
        self.untracked = untracked
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        branch = try container.decode(String.self, forKey: .branch)
        ahead = try container.decodeIfPresent(Int.self, forKey: .ahead) ?? 0
        behind = try container.decodeIfPresent(Int.self, forKey: .behind) ?? 0
        staged = try container.decodeIfPresent([StatusEntry].self, forKey: .staged) ?? []
        unstaged = try container.decodeIfPresent([StatusEntry].self, forKey: .unstaged) ?? []
        untracked = try container.decodeIfPresent([StatusEntry].self, forKey: .untracked) ?? []
    }

    /// True when any tracked or untracked path differs from HEAD.
    public var isDirty: Bool {
        !staged.isEmpty || !unstaged.isEmpty || !untracked.isEmpty
    }
}

// MARK: - Trees, blobs, search

public enum TreeEntryKind: String, Codable, Sendable, Hashable, CaseIterable {
    case file
    case directory
    case symlink
    case other
}

public struct TreeEntry: Codable, Sendable, Hashable, Identifiable {
    public let name: String
    public let path: String
    public let kind: TreeEntryKind
    public let size: UInt64?
    public let isSymlink: Bool

    public var id: String { path }

    public init(
        name: String, path: String, kind: TreeEntryKind, size: UInt64? = nil, isSymlink: Bool = false
    ) {
        self.name = name
        self.path = path
        self.kind = kind
        self.size = size
        self.isSymlink = isSymlink
    }

    enum CodingKeys: String, CodingKey {
        case name
        case path
        case kind
        case size
        case isSymlink = "is_symlink"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        path = try container.decode(String.self, forKey: .path)
        kind = try container.decode(TreeEntryKind.self, forKey: .kind)
        size = try container.decodeIfPresent(UInt64.self, forKey: .size)
        isSymlink = try container.decodeIfPresent(Bool.self, forKey: .isSymlink) ?? false
    }
}

/// Blob payload. Binary content is never shipped over the wire, only its digest.
public enum BlobContent: Codable, Sendable, Hashable {
    case text(String)
    case binary(sha256: String)

    enum CodingKeys: String, CodingKey {
        case encoding
        case value
    }

    private struct BinaryValue: Codable {
        let sha256: String
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let encoding = try container.decode(String.self, forKey: .encoding)
        switch encoding {
        case "text":
            self = .text(try container.decode(String.self, forKey: .value))
        case "binary":
            self = .binary(sha256: try container.decode(BinaryValue.self, forKey: .value).sha256)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .encoding,
                in: container,
                debugDescription: "unknown blob encoding '\(encoding)'"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let value):
            try container.encode("text", forKey: .encoding)
            try container.encode(value, forKey: .value)
        case .binary(let sha256):
            try container.encode("binary", forKey: .encoding)
            try container.encode(BinaryValue(sha256: sha256), forKey: .value)
        }
    }

    /// UTF-8 text, or `nil` when the host only shipped a digest.
    public var text: String? {
        if case .text(let value) = self { return value }
        return nil
    }
}

public struct Blob: Codable, Sendable, Hashable {
    public let path: String
    public let bytes: UInt64
    public let mime: String
    public let truncated: Bool
    public let content: BlobContent

    public init(path: String, bytes: UInt64, mime: String, truncated: Bool, content: BlobContent) {
        self.path = path
        self.bytes = bytes
        self.mime = mime
        self.truncated = truncated
        self.content = content
    }
}

public struct ContentMatch: Codable, Sendable, Hashable, Identifiable {
    public let path: String
    public let line: UInt32
    public let text: String

    public var id: String { "\(path):\(line)" }

    public init(path: String, line: UInt32, text: String) {
        self.path = path
        self.line = line
        self.text = text
    }
}

// MARK: - Diffs

public enum ChangeKind: String, Codable, Sendable, Hashable, CaseIterable {
    case added
    case modified
    case deleted
    case renamed
    case copied
    case typeChanged = "type_changed"
}

public enum LineKind: String, Codable, Sendable, Hashable, CaseIterable {
    case context
    case added
    case removed
    case noNewline = "no_newline"
}

public struct DiffLine: Codable, Sendable, Hashable {
    public let kind: LineKind
    public let text: String
    public let oldLine: UInt32?
    public let newLine: UInt32?

    public init(kind: LineKind, text: String, oldLine: UInt32? = nil, newLine: UInt32? = nil) {
        self.kind = kind
        self.text = text
        self.oldLine = oldLine
        self.newLine = newLine
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case text
        case oldLine = "old_line"
        case newLine = "new_line"
    }
}

public struct Hunk: Codable, Sendable, Hashable, Identifiable {
    public let header: String
    public let oldStart: UInt32
    public let oldLines: UInt32
    public let newStart: UInt32
    public let newLines: UInt32
    public let lines: [DiffLine]

    public var id: String { header }

    public init(
        header: String,
        oldStart: UInt32,
        oldLines: UInt32,
        newStart: UInt32,
        newLines: UInt32,
        lines: [DiffLine]
    ) {
        self.header = header
        self.oldStart = oldStart
        self.oldLines = oldLines
        self.newStart = newStart
        self.newLines = newLines
        self.lines = lines
    }

    enum CodingKeys: String, CodingKey {
        case header
        case oldStart = "old_start"
        case oldLines = "old_lines"
        case newStart = "new_start"
        case newLines = "new_lines"
        case lines
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        header = try container.decode(String.self, forKey: .header)
        oldStart = try container.decode(UInt32.self, forKey: .oldStart)
        oldLines = try container.decode(UInt32.self, forKey: .oldLines)
        newStart = try container.decode(UInt32.self, forKey: .newStart)
        newLines = try container.decode(UInt32.self, forKey: .newLines)
        lines = try container.decodeIfPresent([DiffLine].self, forKey: .lines) ?? []
    }
}

public struct FileDiff: Codable, Sendable, Hashable, Identifiable {
    public let path: String
    public let oldPath: String?
    public let change: ChangeKind
    public let additions: UInt32
    public let deletions: UInt32
    public let binary: Bool
    public let hunks: [Hunk]

    public var id: String { path }

    public init(
        path: String,
        oldPath: String? = nil,
        change: ChangeKind,
        additions: UInt32 = 0,
        deletions: UInt32 = 0,
        binary: Bool = false,
        hunks: [Hunk] = []
    ) {
        self.path = path
        self.oldPath = oldPath
        self.change = change
        self.additions = additions
        self.deletions = deletions
        self.binary = binary
        self.hunks = hunks
    }

    enum CodingKeys: String, CodingKey {
        case path
        case oldPath = "old_path"
        case change
        case additions
        case deletions
        case binary
        case hunks
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        oldPath = try container.decodeIfPresent(String.self, forKey: .oldPath)
        change = try container.decode(ChangeKind.self, forKey: .change)
        additions = try container.decodeIfPresent(UInt32.self, forKey: .additions) ?? 0
        deletions = try container.decodeIfPresent(UInt32.self, forKey: .deletions) ?? 0
        binary = try container.decodeIfPresent(Bool.self, forKey: .binary) ?? false
        hunks = try container.decodeIfPresent([Hunk].self, forKey: .hunks) ?? []
    }

    /// Side by side rows for a split diff view.
    ///
    /// Removed and added lines arrive as consecutive runs in a unified diff. A run of
    /// *r* removals followed by *a* additions becomes `max(r, a)` rows: the first
    /// `min(r, a)` pair up as replacements, the remainder appear on one side only.
    /// Context lines occupy both sides.
    public func splitRows() -> [(left: DiffLine?, right: DiffLine?)] {
        var rows: [(left: DiffLine?, right: DiffLine?)] = []
        var removed: [DiffLine] = []
        var added: [DiffLine] = []

        func flush() {
            for index in 0..<max(removed.count, added.count) {
                rows.append(
                    (
                        left: index < removed.count ? removed[index] : nil,
                        right: index < added.count ? added[index] : nil
                    )
                )
            }
            removed.removeAll(keepingCapacity: true)
            added.removeAll(keepingCapacity: true)
        }

        for hunk in hunks {
            for line in hunk.lines {
                switch line.kind {
                case .removed:
                    // A removal after additions starts a new change block.
                    if !added.isEmpty { flush() }
                    removed.append(line)
                case .added:
                    added.append(line)
                case .context, .noNewline:
                    flush()
                    rows.append((left: line, right: line))
                }
            }
            flush()
        }
        flush()
        return rows
    }
}

public struct Diff: Codable, Sendable, Hashable {
    public let files: [FileDiff]
    public let additions: UInt32
    public let deletions: UInt32

    public init(files: [FileDiff], additions: UInt32, deletions: UInt32) {
        self.files = files
        self.additions = additions
        self.deletions = deletions
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        files = try container.decodeIfPresent([FileDiff].self, forKey: .files) ?? []
        additions = try container.decodeIfPresent(UInt32.self, forKey: .additions) ?? 0
        deletions = try container.decodeIfPresent(UInt32.self, forKey: .deletions) ?? 0
    }

    enum CodingKeys: String, CodingKey {
        case files
        case additions
        case deletions
    }
}

/// Which revision pair `GET /v1/repos/{repo}/diff` should compare.
public enum DiffMode: Sendable, Hashable {
    case workingTree
    case staged
    case commit(String)
    case range(base: String, head: String)

    public var queryItems: [URLQueryItem] {
        switch self {
        case .workingTree:
            return []
        case .staged:
            return [URLQueryItem(name: "staged", value: "true")]
        case .commit(let commit):
            return [URLQueryItem(name: "commit", value: commit)]
        case .range(let base, let head):
            return [
                URLQueryItem(name: "base", value: base),
                URLQueryItem(name: "head", value: head),
            ]
        }
    }
}


public struct TailscaleDevicesResponse: Codable, Sendable, Hashable {
    public static let supportedVersion = 1
    public let version: Int
    public let candidates: [TailscaleDeviceCandidate]
    public init(version: Int, candidates: [TailscaleDeviceCandidate]) { self.version = version; self.candidates = candidates }
    public var isSupportedVersion: Bool { version == Self.supportedVersion }
}

public struct TailscaleDeviceCandidate: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let displayName: String
    public let dnsName: String?
    public let tailscaleIPs: [String]
    public let os: String?
    public let online: Bool
    public let lastSeen: Date?
    public init(id: String, displayName: String, dnsName: String? = nil, tailscaleIPs: [String], os: String? = nil, online: Bool, lastSeen: Date? = nil) { self.id = id; self.displayName = displayName; self.dnsName = dnsName; self.tailscaleIPs = tailscaleIPs; self.os = os; self.online = online; self.lastSeen = lastSeen }
    enum CodingKeys: String, CodingKey { case id; case displayName = "display_name"; case dnsName = "dns_name"; case tailscaleIPs = "tailscale_ips"; case os; case online; case lastSeen = "last_seen" }
}

public enum TailscaleDiscoveryErrorCode: Codable, Sendable, Hashable {
    case missingCLI
    case loggedOut
    case timeout
    case outputLimit
    case busy
    case unavailableState
    case commandFailed
    case malformedResponse
    case unsupportedVersion
    case unavailable
    case unknown(String)

    public var rawValue: String {
        switch self {
        case .missingCLI: "missing_cli"
        case .loggedOut: "logged_out"
        case .timeout: "timeout"
        case .outputLimit: "output_limit"
        case .busy: "busy"
        case .unavailableState: "unavailable_state"
        case .commandFailed: "command_failed"
        case .malformedResponse: "malformed_response"
        case .unsupportedVersion: "unsupported_version"
        case .unavailable: "unavailable"
        case .unknown(let value): value
        }
    }

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = switch raw {
        case "missing_cli": .missingCLI
        case "logged_out": .loggedOut
        case "timeout": .timeout
        case "output_limit": .outputLimit
        case "busy": .busy
        case "unavailable_state": .unavailableState
        case "command_failed": .commandFailed
        case "malformed_response": .malformedResponse
        case "unsupported_version": .unsupportedVersion
        case "unavailable": .unavailable
        default: .unknown(raw)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct TailscaleDiscoveryErrorEnvelope: Codable, Sendable, Hashable {
    public struct Payload: Codable, Sendable, Hashable { public let code: TailscaleDiscoveryErrorCode; public let message: String; public init(code: TailscaleDiscoveryErrorCode, message: String) { self.code = code; self.message = message } }
    public let error: Payload
    public init(error: Payload) { self.error = error }
}
