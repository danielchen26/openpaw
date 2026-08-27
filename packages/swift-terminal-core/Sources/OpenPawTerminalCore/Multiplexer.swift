import Foundation

// MARK: - Command execution seam

/// Runs a shell command on the remote host and returns its standard output.
///
/// Implementations (`OpenPawSSH.SSHCommandRunner`, test doubles) must throw
/// ``CommandFailure`` for a non-zero exit so adapters can distinguish "the
/// multiplexer is not running" from "the connection broke".
public protocol CommandRunner: Sendable {
    func run(_ command: String) async throws -> String
}

/// A command that ran to completion with a non-zero exit status.
public struct CommandFailure: Error, Sendable, Hashable {
    public var command: String
    public var exitCode: Int32
    /// Combined stdout+stderr, used by adapters to recognise benign failures.
    public var output: String

    public init(command: String, exitCode: Int32, output: String) {
        self.command = command
        self.exitCode = exitCode
        self.output = output
    }
}

public enum MultiplexerError: Error, Sendable, Hashable {
    case malformedOutput(kind: MultiplexerKind, detail: String)
    case unsupportedOperation(kind: MultiplexerKind, operation: String)
}

/// A session operation the UI is allowed to send through the interactive terminal.
///
/// The enum is deliberately closed. Callers choose an operation and typed targets; only this module turns that choice
/// into shell text. That preserves ordinary SSH compatibility without reintroducing a free-form command seam.
public enum MultiplexerCommand: Sendable, Hashable {
    case attach(RemoteSession)
    case create(kind: MultiplexerKind, name: String, directory: String?)
    case focus(kind: MultiplexerKind, window: RemoteWindow)
    case kill(RemoteSession)
    case rename(RemoteSession, to: String)
    case changeDirectory(String)

    public func rendered() throws -> String {
        switch self {
        case .attach(let session):
            try Self.validate(session.id, field: "session")
            if session.kind == .herdr {
                guard let terminalID = session.terminalID else {
                    throw MultiplexerCommandError.invalidValue(field: "Herdr terminal")
                }
                try Self.validate(terminalID, field: "Herdr terminal")
            }
            return MultiplexerAdapters.adapter(for: session.kind).attach(session)
        case .create(let kind, let name, let directory):
            try Self.validate(name, field: "session name")
            if let directory, !directory.isEmpty {
                try Self.validate(directory, field: "directory", maximumUTF8Count: 4_096)
            }
            return MultiplexerAdapters.adapter(for: kind).create(name: name, directory: directory)
        case .focus(let kind, let window):
            try Self.validate(window.id, field: "window")
            try Self.validate(window.sessionID, field: "session")
            try Self.validate(window.name, field: "window name")
            if kind == .herdr {
                guard let terminalID = window.terminalID else {
                    throw MultiplexerCommandError.invalidValue(field: "Herdr terminal")
                }
                try Self.validate(terminalID, field: "Herdr terminal")
            }
            guard window.index >= 0 else { throw MultiplexerCommandError.invalidValue(field: "window index") }
            return MultiplexerAdapters.adapter(for: kind).focus(window: window)
        case .kill(let session):
            try Self.validate(session.id, field: "session")
            return MultiplexerAdapters.adapter(for: session.kind).kill(session)
        case .rename(let session, let name):
            try Self.validate(session.id, field: "session")
            try Self.validate(name, field: "session name")
            return MultiplexerAdapters.adapter(for: session.kind).rename(session, to: name)
        case .changeDirectory(let directory):
            try Self.validate(directory, field: "directory", maximumUTF8Count: 4_096)
            return "cd \(shellQuoted(directory))"
        }
    }

    private static func validate(
        _ value: String,
        field: String,
        maximumUTF8Count: Int = 512
    ) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.utf8.count <= maximumUTF8Count,
              value.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw MultiplexerCommandError.invalidValue(field: field)
        }
    }
}

public enum MultiplexerCommandError: Error, Sendable, Hashable {
    case invalidValue(field: String)
}

// MARK: - Models

public enum MultiplexerKind: String, Sendable, Codable, Hashable, CaseIterable {
    case tmux
    case zellij
    case screen
    case herdr

    public var displayName: String {
        switch self {
        case .tmux: return "tmux"
        case .zellij: return "Zellij"
        case .screen: return "GNU Screen"
        case .herdr: return "Herdr"
        }
    }
}

/// A multiplexer session living on the host.
public struct RemoteSession: Sendable, Hashable, Codable, Identifiable {
    /// Multiplexer native handle used as a command target (`$3`, `31183.agent`,
    /// or the plain session name).
    public var id: String
    public var name: String
    public var kind: MultiplexerKind
    /// Herdr's terminal transport handle. Herdr manages panes by ``id`` but attaches a stream by this separate ID.
    public var terminalID: String?
    /// Herdr workspace that owns this pane. Nil for other multiplexers and older persisted snapshots.
    public var workspaceID: String?
    /// Herdr tab that owns this pane. Nil for other multiplexers and older persisted snapshots.
    public var tabID: String?
    /// User-visible Herdr tab label captured during discovery.
    public var tabLabel: String?
    public var isAttached: Bool
    /// False for sessions the multiplexer reports as dead/exited but still lists.
    public var isAlive: Bool
    public var windowCount: Int
    public var createdAt: Date?
    public var lastActivityAt: Date?
    /// Age reported as a relative duration (Zellij only reports relative ages).
    public var uptime: TimeInterval?
    public var workingDirectory: String?

    public init(
        id: String,
        name: String,
        kind: MultiplexerKind,
        terminalID: String? = nil,
        workspaceID: String? = nil,
        tabID: String? = nil,
        tabLabel: String? = nil,
        isAttached: Bool = false,
        isAlive: Bool = true,
        windowCount: Int = 0,
        createdAt: Date? = nil,
        lastActivityAt: Date? = nil,
        uptime: TimeInterval? = nil,
        workingDirectory: String? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.terminalID = terminalID
        self.workspaceID = workspaceID
        self.tabID = tabID
        self.tabLabel = tabLabel
        self.isAttached = isAttached
        self.isAlive = isAlive
        self.windowCount = windowCount
        self.createdAt = createdAt
        self.lastActivityAt = lastActivityAt
        self.uptime = uptime
        self.workingDirectory = workingDirectory
    }

    /// Builds the minimal session value needed to address `name` as a command
    /// target, for callers that only persisted the target string.
    public static func target(_ name: String, kind: MultiplexerKind) -> RemoteSession {
        RemoteSession(id: name, name: name, kind: kind)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind
        case terminalID = "terminal_id"
        case workspaceID = "workspace_id"
        case tabID = "tab_id"
        case tabLabel = "tab_label"
        case isAttached = "is_attached"
        case isAlive = "is_alive"
        case windowCount = "window_count"
        case createdAt = "created_at"
        case lastActivityAt = "last_activity_at"
        case uptime
        case workingDirectory = "working_directory"
    }
}

/// A window (tmux) / tab (Zellij) / screen window inside a session.
public struct RemoteWindow: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var sessionID: String
    public var index: Int
    public var name: String
    /// Herdr terminal transport handle when this synthetic window represents a pane.
    public var terminalID: String?
    public var isActive: Bool
    public var paneCount: Int
    public var currentCommand: String?
    public var currentPath: String?

    public init(
        id: String,
        sessionID: String,
        index: Int,
        name: String,
        terminalID: String? = nil,
        isActive: Bool = false,
        paneCount: Int = 1,
        currentCommand: String? = nil,
        currentPath: String? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.index = index
        self.name = name
        self.terminalID = terminalID
        self.isActive = isActive
        self.paneCount = paneCount
        self.currentCommand = currentCommand
        self.currentPath = currentPath
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case sessionID = "session_id"
        case index, name
        case terminalID = "terminal_id"
        case isActive = "is_active"
        case paneCount = "pane_count"
        case currentCommand = "current_command"
        case currentPath = "current_path"
    }
}

/// A tmux pane. Only tmux exposes panes over its CLI.
public struct RemotePane: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var windowID: String
    public var index: Int
    public var isActive: Bool
    public var width: Int
    public var height: Int
    public var currentCommand: String?
    public var currentPath: String?
    public var title: String?

    public init(
        id: String,
        windowID: String,
        index: Int,
        isActive: Bool,
        width: Int,
        height: Int,
        currentCommand: String? = nil,
        currentPath: String? = nil,
        title: String? = nil
    ) {
        self.id = id
        self.windowID = windowID
        self.index = index
        self.isActive = isActive
        self.width = width
        self.height = height
        self.currentCommand = currentCommand
        self.currentPath = currentPath
        self.title = title
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case windowID = "window_id"
        case index
        case isActive = "is_active"
        case width, height
        case currentCommand = "current_command"
        case currentPath = "current_path"
        case title
    }
}

// MARK: - Adapter protocol

public protocol MultiplexerAdapter: Sendable {
    var kind: MultiplexerKind { get }
    func discoverSessions(runner: any CommandRunner) async throws -> [RemoteSession]
    /// The command line to type into the PTY to attach.
    func attach(_ session: RemoteSession) -> String
    func create(name: String, directory: String?) -> String
    /// A command that creates the session and exits, allowing the PTY runner to acknowledge success before attaching.
    func createDetached(name: String, directory: String?) -> String
    func listWindows(session: RemoteSession, runner: any CommandRunner) async throws -> [RemoteWindow]
    func focus(window: RemoteWindow) -> String
    func kill(_ session: RemoteSession) -> String
    func rename(_ session: RemoteSession, to newName: String) -> String
}

public enum MultiplexerAdapters {
    /// Every adapter OpenPaw ships, in discovery preference order.
    public static let all: [any MultiplexerAdapter] = [
        TmuxAdapter(), ZellijAdapter(), ScreenAdapter(), HerdrAdapter(),
    ]

    public static func adapter(for kind: MultiplexerKind) -> any MultiplexerAdapter {
        switch kind {
        case .tmux: return TmuxAdapter()
        case .zellij: return ZellijAdapter()
        case .screen: return ScreenAdapter()
        case .herdr: return HerdrAdapter()
        }
    }
}

/// Shared parsing constants.
public enum Multiplexer {
    /// Printable delimiter used by tmux's `q:` format modifier.
    ///
    /// tmux rewrites control and non-ASCII separator characters to `_` in `-F` output. A printable ASCII delimiter,
    /// combined with tmux's backslash escaping for every field, survives both interactive PTYs and SSH exec channels.
    public static let fieldSeparator = "|"
}

/// Markers that mean "this multiplexer simply has nothing running", which is a
/// success with an empty list rather than an error.
private func isBenignEmptyOutput(_ text: String) -> Bool {
    let lowered = text.lowercased()
    return lowered.contains("no server running")
        || lowered.contains("no sessions")
        || lowered.contains("no active zellij sessions")
        || lowered.contains("no sockets found")
        || lowered.contains("error connecting to")
        || lowered.contains("failed to connect to server")
}

private func splitLines(_ text: String) -> [String] {
    text.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }).map(String.init)
}

/// Splits tmux `q:` formatted output. tmux backslash-escapes shell metacharacters, including the printable `|`
/// delimiter and literal backslashes. A trailing escape is malformed rather than being silently discarded.
private func fields(_ line: String) -> [String]? {
    var result: [String] = []
    var field = ""
    var isEscaped = false

    for character in line {
        if isEscaped {
            field.append(character)
            isEscaped = false
        } else if character == "\\" {
            isEscaped = true
        } else if character == Character(Multiplexer.fieldSeparator) {
            result.append(field)
            field = ""
        } else {
            field.append(character)
        }
    }

    guard !isEscaped else { return nil }
    result.append(field)
    return result
}

private func epochDate(_ raw: String) -> Date? {
    guard let seconds = TimeInterval(raw), seconds > 0 else { return nil }
    return Date(timeIntervalSince1970: seconds)
}

// MARK: - tmux

public struct TmuxAdapter: MultiplexerAdapter {
    /// Explicit `-F` formats: tmux's default human output is unparseable for
    /// names containing spaces or brackets.
    public static let sessionFormat = [
        "#{q:session_id}", "#{q:session_name}", "#{q:session_attached}", "#{q:session_windows}",
        "#{q:session_created}", "#{q:session_activity}", "#{q:session_path}",
    ].joined(separator: Multiplexer.fieldSeparator)

    public static let windowFormat = [
        "#{q:window_id}", "#{q:window_index}", "#{q:window_name}", "#{q:window_active}",
        "#{q:window_panes}", "#{q:pane_current_command}", "#{q:pane_current_path}",
    ].joined(separator: Multiplexer.fieldSeparator)

    public static let paneFormat = [
        "#{q:pane_id}", "#{q:pane_index}", "#{q:pane_active}", "#{q:pane_width}", "#{q:pane_height}",
        "#{q:pane_current_command}", "#{q:pane_current_path}", "#{q:pane_title}",
    ].joined(separator: Multiplexer.fieldSeparator)

    public let kind = MultiplexerKind.tmux

    public init() {}

    /// tmux rewrites control and non-ASCII separators to underscores in `-F` output. Every field uses tmux's `q:`
    /// modifier, so a printable `|` delimiter remains literal while delimiter-like field data is backslash-escaped.
    static func shellFormatArgument(_ format: String) -> String {
        shellQuoted(format)
    }

    public var discoverCommand: String {
        "tmux list-sessions -F \(Self.shellFormatArgument(Self.sessionFormat))"
    }

    public func discoverSessions(runner: any CommandRunner) async throws -> [RemoteSession] {
        let output: String
        do {
            output = try await runner.run(discoverCommand)
        } catch let failure as CommandFailure {
            guard isBenignEmptyOutput(failure.output) else { throw failure }
            return []
        }
        if isBenignEmptyOutput(output) { return [] }
        return try splitLines(output).map(parseSession)
    }

    public func parseSession(_ line: String) throws -> RemoteSession {
        guard let parts = fields(line), parts.count >= 7 else {
            throw MultiplexerError.malformedOutput(kind: .tmux, detail: line)
        }
        return RemoteSession(
            id: parts[0],
            name: parts[1],
            kind: .tmux,
            isAttached: (Int(parts[2]) ?? 0) > 0,
            isAlive: true,
            windowCount: Int(parts[3]) ?? 0,
            createdAt: epochDate(parts[4]),
            lastActivityAt: epochDate(parts[5]),
            uptime: nil,
            workingDirectory: parts[6].isEmpty ? nil : parts[6]
        )
    }

    public func listWindows(session: RemoteSession, runner: any CommandRunner) async throws
        -> [RemoteWindow]
    {
        let command =
            "tmux list-windows -t \(shellQuoted(session.id)) -F \(Self.shellFormatArgument(Self.windowFormat))"
        let output: String
        do {
            output = try await runner.run(command)
        } catch let failure as CommandFailure {
            guard isBenignEmptyOutput(failure.output) else { throw failure }
            return []
        }
        if isBenignEmptyOutput(output) { return [] }
        return try splitLines(output).map { try parseWindow($0, sessionID: session.id) }
    }

    public func parseWindow(_ line: String, sessionID: String) throws -> RemoteWindow {
        guard let parts = fields(line), parts.count >= 7, let index = Int(parts[1]) else {
            throw MultiplexerError.malformedOutput(kind: .tmux, detail: line)
        }
        return RemoteWindow(
            id: parts[0],
            sessionID: sessionID,
            index: index,
            name: parts[2],
            isActive: (Int(parts[3]) ?? 0) > 0,
            paneCount: Int(parts[4]) ?? 1,
            currentCommand: parts[5].isEmpty ? nil : parts[5],
            currentPath: parts[6].isEmpty ? nil : parts[6]
        )
    }

    public func listPanes(window: RemoteWindow, runner: any CommandRunner) async throws
        -> [RemotePane]
    {
        let command =
            "tmux list-panes -t \(shellQuoted(window.id)) -F \(Self.shellFormatArgument(Self.paneFormat))"
        let output: String
        do {
            output = try await runner.run(command)
        } catch let failure as CommandFailure {
            guard isBenignEmptyOutput(failure.output) else { throw failure }
            return []
        }
        if isBenignEmptyOutput(output) { return [] }
        return try splitLines(output).map { try parsePane($0, windowID: window.id) }
    }

    public func parsePane(_ line: String, windowID: String) throws -> RemotePane {
        guard let parts = fields(line), parts.count >= 8, let index = Int(parts[1]), let width = Int(parts[3]),
            let height = Int(parts[4])
        else {
            throw MultiplexerError.malformedOutput(kind: .tmux, detail: line)
        }
        return RemotePane(
            id: parts[0],
            windowID: windowID,
            index: index,
            isActive: (Int(parts[2]) ?? 0) > 0,
            width: width,
            height: height,
            currentCommand: parts[5].isEmpty ? nil : parts[5],
            currentPath: parts[6].isEmpty ? nil : parts[6],
            title: parts[7].isEmpty ? nil : parts[7]
        )
    }

    public func attach(_ session: RemoteSession) -> String {
        "tmux attach-session -t \(shellQuoted(session.id))"
    }

    public func create(name: String, directory: String?) -> String {
        var command = "tmux new-session -A -s \(shellQuoted(name))"
        if let directory, !directory.isEmpty {
            command += " -c \(shellQuoted(directory))"
        }
        return command
    }

    public func createDetached(name: String, directory: String?) -> String {
        var command = "tmux new-session -d -s \(shellQuoted(name))"
        if let directory, !directory.isEmpty {
            command += " -c \(shellQuoted(directory))"
        }
        return command
    }

    public func focus(window: RemoteWindow) -> String {
        "tmux select-window -t \(shellQuoted(window.id))"
    }

    public func kill(_ session: RemoteSession) -> String {
        "tmux kill-session -t \(shellQuoted(session.id))"
    }

    public func rename(_ session: RemoteSession, to newName: String) -> String {
        "tmux rename-session -t \(shellQuoted(session.id)) \(shellQuoted(newName))"
    }
}

// MARK: - Zellij

public struct ZellijAdapter: MultiplexerAdapter {
    public let kind = MultiplexerKind.zellij

    public init() {}

    public var discoverCommand: String { "zellij list-sessions --no-formatting" }

    public func discoverSessions(runner: any CommandRunner) async throws -> [RemoteSession] {
        let output: String
        do {
            output = try await runner.run(discoverCommand)
        } catch let failure as CommandFailure {
            guard isBenignEmptyOutput(failure.output) else { throw failure }
            return []
        }
        if isBenignEmptyOutput(output) { return [] }
        return splitLines(output).compactMap(parseSession)
    }

    /// Parses one `zellij list-sessions --no-formatting` line, e.g.
    /// `agent-main [Created 2h 14m 3s ago] (current)` or
    /// `stale [Created 3d 1h 0s ago] (EXITED - attach to resurrect)`.
    public func parseSession(_ line: String) -> RemoteSession? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        guard let bracket = trimmed.firstIndex(of: "[") else {
            // A bare name with no metadata is still a usable target.
            return RemoteSession(id: trimmed, name: trimmed, kind: .zellij)
        }
        let name = String(trimmed[trimmed.startIndex..<bracket]).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        let remainder = String(trimmed[bracket...])
        let uptime = Self.parseCreatedDuration(remainder)
        let exited = remainder.uppercased().contains("EXITED")
        let attached = remainder.contains("(current)") || remainder.contains("(attached)")
        return RemoteSession(
            id: name,
            name: name,
            kind: .zellij,
            isAttached: attached,
            isAlive: !exited,
            uptime: uptime
        )
    }

    /// Extracts `Created 2h 14m 3s ago` into seconds.
    static func parseCreatedDuration(_ text: String) -> TimeInterval? {
        guard let createdRange = text.range(of: "Created ") else { return nil }
        var slice = text[createdRange.upperBound...]
        if let agoRange = slice.range(of: " ago") {
            slice = slice[slice.startIndex..<agoRange.lowerBound]
        }
        var total: TimeInterval = 0
        var matched = false
        for token in slice.split(separator: " ") {
            guard let unit = token.last, let value = Int(token.dropLast()) else { continue }
            let multiplier: TimeInterval?
            switch unit {
            case "d": multiplier = 86_400
            case "h": multiplier = 3_600
            case "m": multiplier = 60
            case "s": multiplier = 1
            default: multiplier = nil
            }
            guard let multiplier else { continue }
            total += TimeInterval(value) * multiplier
            matched = true
        }
        return matched ? total : nil
    }

    public func listWindows(session: RemoteSession, runner: any CommandRunner) async throws
        -> [RemoteWindow]
    {
        let command = "zellij --session \(shellQuoted(session.id)) action query-tab-names"
        let output: String
        do {
            output = try await runner.run(command)
        } catch let failure as CommandFailure {
            guard isBenignEmptyOutput(failure.output) else { throw failure }
            return []
        }
        if isBenignEmptyOutput(output) { return [] }
        // `query-tab-names` emits one tab name per line, in tab order, without
        // an active marker; index is therefore the only stable identity.
        return splitLines(output).enumerated().map { offset, name in
            RemoteWindow(
                id: "\(session.id):\(offset)",
                sessionID: session.id,
                index: offset,
                name: name,
                isActive: false,
                paneCount: 1
            )
        }
    }

    public func attach(_ session: RemoteSession) -> String {
        "zellij attach \(shellQuoted(session.id))"
    }

    public func create(name: String, directory: String?) -> String {
        let launch = "zellij --session \(shellQuoted(name))"
        if let directory, !directory.isEmpty {
            return "cd \(shellQuoted(directory)) && \(launch)"
        }
        return launch
    }

    public func createDetached(name: String, directory: String?) -> String {
        let launch = "zellij attach --create-background \(shellQuoted(name))"
        if let directory, !directory.isEmpty {
            return "cd \(shellQuoted(directory)) && \(launch)"
        }
        return launch
    }

    public func focus(window: RemoteWindow) -> String {
        "zellij --session \(shellQuoted(window.sessionID)) action go-to-tab-name \(shellQuoted(window.name))"
    }

    public func kill(_ session: RemoteSession) -> String {
        "zellij kill-session \(shellQuoted(session.id))"
    }

    public func rename(_ session: RemoteSession, to newName: String) -> String {
        "zellij --session \(shellQuoted(session.id)) action rename-session \(shellQuoted(newName))"
    }
}

// MARK: - GNU screen

public struct ScreenAdapter: MultiplexerAdapter {
    public let kind = MultiplexerKind.screen

    public init() {}

    public var discoverCommand: String { "screen -ls" }

    public func discoverSessions(runner: any CommandRunner) async throws -> [RemoteSession] {
        let output: String
        do {
            output = try await runner.run(discoverCommand)
        } catch let failure as CommandFailure {
            // `screen -ls` exits 1 whenever it lists nothing, and also exits 1
            // in some builds while printing a perfectly good listing.
            output = failure.output
            if isBenignEmptyOutput(output) { return [] }
        }
        if isBenignEmptyOutput(output) { return [] }
        return splitLines(output).compactMap(parseSession)
    }

    /// Parses a `screen -ls` body line, e.g. `\t31183.agent-main\t(Detached)`
    /// or `\t28763.stale\t(Dead ???)`.
    public func parseSession(_ rawLine: String) -> RemoteSession? {
        // Only indented lines describe sessions; headers and the socket count
        // line are flush left.
        guard let first = rawLine.first, first == "\t" || first == " " else { return nil }
        let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        var handle = trimmed
        var stateText = ""
        if let open = trimmed.lastIndex(of: "("), let close = trimmed.lastIndex(of: ")"),
            open < close
        {
            handle = String(trimmed[trimmed.startIndex..<open]).trimmingCharacters(in: .whitespaces)
            stateText = String(trimmed[trimmed.index(after: open)..<close])
        }
        guard let dot = handle.firstIndex(of: "."), Int(handle[handle.startIndex..<dot]) != nil
        else { return nil }
        let name = String(handle[handle.index(after: dot)...])
        guard !name.isEmpty else { return nil }

        let lowered = stateText.lowercased()
        let dead = lowered.contains("dead") || lowered.contains("removed")
        return RemoteSession(
            id: handle,
            name: name,
            kind: .screen,
            isAttached: lowered.contains("attached") || lowered.contains("multi"),
            isAlive: !dead,
            windowCount: 0
        )
    }

    public func listWindows(session: RemoteSession, runner: any CommandRunner) async throws
        -> [RemoteWindow]
    {
        let command = "screen -S \(shellQuoted(session.id)) -Q windows"
        let output: String
        do {
            output = try await runner.run(command)
        } catch let failure as CommandFailure {
            guard isBenignEmptyOutput(failure.output) else { throw failure }
            return []
        }
        if isBenignEmptyOutput(output) { return [] }
        return Self.parseWindows(output, sessionID: session.id)
    }

    /// `screen -Q windows` answers on one line, entries separated by two spaces,
    /// each entry `<index><flags> <title>`; `*` marks the current window.
    public static func parseWindows(_ output: String, sessionID: String) -> [RemoteWindow] {
        let line = splitLines(output).first ?? ""
        return line.components(separatedBy: "  ").compactMap { entry -> RemoteWindow? in
            let token = entry.trimmingCharacters(in: .whitespaces)
            guard !token.isEmpty else { return nil }
            let digits = token.prefix(while: \.isNumber)
            guard let index = Int(digits) else { return nil }
            var rest = token.dropFirst(digits.count)
            var flags = ""
            while let head = rest.first, head != " " {
                flags.append(head)
                rest = rest.dropFirst()
            }
            let name = rest.trimmingCharacters(in: .whitespaces)
            return RemoteWindow(
                id: "\(sessionID):\(index)",
                sessionID: sessionID,
                index: index,
                name: name.isEmpty ? "\(index)" : name,
                isActive: flags.contains("*"),
                paneCount: 1
            )
        }
    }

    public func attach(_ session: RemoteSession) -> String {
        // `-x` attaches to an already attached session (multi display) which is
        // what a phone joining a desktop session needs.
        "screen -x \(shellQuoted(session.id))"
    }

    public func create(name: String, directory: String?) -> String {
        let launch = "screen -S \(shellQuoted(name))"
        if let directory, !directory.isEmpty {
            return "cd \(shellQuoted(directory)) && \(launch)"
        }
        return launch
    }

    public func createDetached(name: String, directory: String?) -> String {
        let launch = "screen -dmS \(shellQuoted(name))"
        if let directory, !directory.isEmpty {
            return "cd \(shellQuoted(directory)) && \(launch)"
        }
        return launch
    }

    public func focus(window: RemoteWindow) -> String {
        "screen -S \(shellQuoted(window.sessionID)) -X select \(window.index)"
    }

    public func kill(_ session: RemoteSession) -> String {
        "screen -S \(shellQuoted(session.id)) -X quit"
    }

    public func rename(_ session: RemoteSession, to newName: String) -> String {
        "screen -S \(shellQuoted(session.id)) -X sessionname \(shellQuoted(newName))"
    }
}

// MARK: - Herdr

/// Herdr is not a session multiplexer in the tmux sense: its "sessions" are long-lived server daemons (usually exactly
/// one, named `default`), and the things a user actually works in are *agent panes* inside it. Chat therefore lists
/// agents, addressed by `pane_id`, which is the target every `herdr agent` subcommand accepts.
public struct HerdrAdapter: MultiplexerAdapter {
    public let kind = MultiplexerKind.herdr

    public init() {}

    /// Panes rather than agents: a session created from the phone is a bare shell with no agent running in it yet,
    /// and `herdr agent list` omits those entirely, so a freshly created session would never appear.
    public var discoverCommand: String { "herdr pane list" }

    /// Tab labels are what the user typed when creating a session. A bare shell pane has no title of its own, so
    /// without this its only name would be an opaque pane id.
    public var tabListCommand: String { "herdr tab list" }

    /// Herdr wraps every socket-API reply in `{"id":…, "result":…}`, and reports failures as a JSON `error` object
    /// rather than a non-zero exit, so the envelope has to be unwrapped before anything can be decoded.
    private struct Envelope<T: Decodable>: Decodable {
        var result: T?
        var error: ErrorBody?

        struct ErrorBody: Decodable {
            var code: String?
            var message: String?
        }
    }

    private struct PaneList: Decodable {
        var panes: [AgentDTO]
    }

    private struct WorkspaceCreateResult: Decodable {
        var root_pane: RootPane

        struct RootPane: Decodable {
            var pane_id: String
            var terminal_id: String
        }
    }

    private struct TabList: Decodable {
        var tabs: [TabDTO]
    }

    private struct TabDTO: Decodable {
        var tab_id: String
        var workspace_id: String?
        var label: String?
    }

    private struct AgentDTO: Decodable {
        var pane_id: String
        var terminal_id: String
        var agent: String?
        var agent_status: String?
        var cwd: String?
        var focused: Bool?
        var tab_id: String?
        var terminal_title_stripped: String?
        var terminal_title: String?
        var workspace_id: String?

        /// What the user recognises the pane by. Herdr already strips the status glyph from the raw title, so the
        /// stripped form is preferred; a bare shell has no title, and falls back to the label of the tab it was
        /// created in, then to the agent name, then to the pane id.
        func displayName(tabLabels: [String: String]) -> String {
            var candidates = [terminal_title_stripped, terminal_title]
            if let tab_id { candidates.append(tabLabels[tab_id]) }
            candidates.append(agent)
            for candidate in candidates {
                if let candidate, !candidate.trimmingCharacters(in: .whitespaces).isEmpty { return candidate }
            }
            return pane_id
        }
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Older Herdr builds, and hosts with no Herdr at all, must degrade to "no agents here" rather than surfacing an
    /// error banner over a host where the user simply uses something else.
    private static func isUnknownCommand(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.contains("unknown subcommand")
            || lowered.contains("unrecognized subcommand")
            || lowered.contains("unrecognised subcommand")
            || lowered.contains("unknown command")
            || lowered.contains("unexpected argument")
            || lowered.contains("unknown flag")
            || lowered.contains("unknown option")
            || lowered.contains("command not found")
            || lowered.contains("no such subcommand")
            || lowered.contains("usage: herdr")
    }

    /// True when Herdr is installed but has no server running, which is an empty list rather than a failure.
    private static func isServerDown(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.contains("no such file or directory")
            || lowered.contains("connection refused")
            || lowered.contains("server not running")
            || lowered.contains("could not connect")
    }

    public func discoverSessions(runner: any CommandRunner) async throws -> [RemoteSession] {
        let output: String
        do {
            output = try await runner.run(discoverCommand)
        } catch let failure as CommandFailure {
            if Self.isUnknownCommand(failure.output) || Self.isServerDown(failure.output)
                || isBenignEmptyOutput(failure.output)
            {
                return []
            }
            throw failure
        }
        if Self.isUnknownCommand(output) || Self.isServerDown(output)
            || output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return []
        }
        // Tab labels only improve the names, so a failure here must not lose the panes themselves.
        let tabs = (try? await runner.run(tabListCommand)).map(Self.parseTabMetadata)
            ?? (labels: [:], workspaces: [:])
        return try parseSessions(
            output,
            tabLabels: tabs.labels,
            tabWorkspaces: tabs.workspaces)
    }

    static func parseTabMetadata(_ json: String) -> (
        labels: [String: String], workspaces: [String: String]
    ) {
        guard let data = json.data(using: .utf8) else { return ([:], [:]) }
        let decoder = Self.decoder()
        let tabs: [TabDTO]
        if let envelope = try? decoder.decode(Envelope<TabList>.self, from: data), let result = envelope.result {
            tabs = result.tabs
        } else if let bare = try? decoder.decode(TabList.self, from: data) {
            tabs = bare.tabs
        } else {
            return ([:], [:])
        }
        let labels = Dictionary(
            tabs.compactMap { tab in tab.label.map { (tab.tab_id, $0) } },
            uniquingKeysWith: { first, _ in first })
        let workspaces = Dictionary(
            tabs.compactMap { tab in tab.workspace_id.map { (tab.tab_id, $0) } },
            uniquingKeysWith: { first, _ in first })
        return (labels, workspaces)
    }

    public func parseSessions(_ json: String) throws -> [RemoteSession] {
        try parseSessions(json, tabLabels: [:], tabWorkspaces: [:])
    }

    public func parseSessions(
        _ json: String,
        tabLabels: [String: String],
        tabWorkspaces: [String: String] = [:]
    ) throws -> [RemoteSession] {
        guard let data = json.data(using: .utf8) else {
            throw MultiplexerError.malformedOutput(kind: .herdr, detail: "output is not UTF-8")
        }
        let decoder = Self.decoder()
        let dtos: [AgentDTO]
        if let envelope = try? decoder.decode(Envelope<PaneList>.self, from: data), let result = envelope.result {
            dtos = result.panes
        } else if let bare = try? decoder.decode(PaneList.self, from: data) {
            dtos = bare.panes
        } else if let bare = try? decoder.decode([AgentDTO].self, from: data) {
            dtos = bare
        } else {
            throw MultiplexerError.malformedOutput(kind: .herdr, detail: json)
        }
        return dtos.map { dto in
            RemoteSession(
                id: dto.pane_id,
                name: dto.displayName(tabLabels: tabLabels),
                kind: .herdr,
                terminalID: dto.terminal_id,
                workspaceID: dto.workspace_id ?? dto.tab_id.flatMap { tabWorkspaces[$0] },
                tabID: dto.tab_id,
                tabLabel: dto.tab_id.flatMap { tabLabels[$0] },
                // Herdr has no "attached" concept; the focused pane is the one the user is looking at.
                isAttached: dto.focused ?? false,
                isAlive: true,
                windowCount: 1,
                createdAt: nil,
                lastActivityAt: nil,
                uptime: nil,
                workingDirectory: dto.cwd
            )
        }
    }

    public func listWindows(session: RemoteSession, runner: any CommandRunner) async throws
        -> [RemoteWindow]
    {
        // An agent pane is a leaf: it has no windows of its own, and Herdr's tabs live above agents rather than
        // below them. Reporting the pane itself keeps callers that expect one window per session working.
        [
            RemoteWindow(
                id: session.id,
                sessionID: session.id,
                index: 0,
                name: session.name,
                terminalID: session.terminalID,
                isActive: session.isAttached,
                paneCount: 1,
                currentCommand: nil,
                currentPath: session.workingDirectory
            )
        ]
    }

    public func attach(_ session: RemoteSession) -> String {
        "herdr terminal attach \(shellQuoted(session.terminalID ?? ""))"
    }

    public func paneProbeCommand(_ session: RemoteSession) -> String {
        "herdr pane get \(shellQuoted(session.id))"
    }

    /// Herdr reports socket API failures in an exit-zero JSON envelope. A successful process exit therefore is not an
    /// acknowledgement by itself: the envelope must contain the exact pane that was requested before OpenPaw enters
    /// the interactive terminal or persists restoration state.
    public func validatePaneProbeResponse(_ json: String, expectedPaneID: String) throws {
        guard let data = json.data(using: .utf8),
              let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MultiplexerError.malformedOutput(kind: .herdr, detail: "pane probe was not acknowledged")
        }
        let error = envelope["error"]
        guard error == nil || error is NSNull,
              let result = envelope["result"] as? [String: Any],
              let paneID = result["pane_id"] as? String,
              paneID == expectedPaneID else {
            throw MultiplexerError.malformedOutput(kind: .herdr, detail: "pane probe was not acknowledged")
        }
    }

    /// OpenPaw presents Herdr workspaces through their root panes. A workspace creation receipt gives the exact pane id
    /// the phone must attach, unlike a label which is neither unique nor a valid terminal target.
    public func create(name: String, directory: String?) -> String {
        var command = "herdr workspace create"
        if let directory, !directory.isEmpty {
            command += " --cwd \(shellQuoted(directory))"
        }
        command += " --label \(shellQuoted(name)) --focus"
        return command
    }

    public func createDetached(name: String, directory: String?) -> String {
        var command = "herdr workspace create"
        if let directory, !directory.isEmpty {
            command += " --cwd \(shellQuoted(directory))"
        }
        command += " --label \(shellQuoted(name)) --no-focus"
        return command
    }

    public func parseCreatedSession(
        _ json: String,
        name: String,
        directory: String?
    ) throws -> RemoteSession {
        guard let data = json.data(using: .utf8),
              let envelope = try? Self.decoder().decode(Envelope<WorkspaceCreateResult>.self, from: data),
              let result = envelope.result else {
            throw MultiplexerError.malformedOutput(kind: .herdr, detail: json)
        }
        let paneID = result.root_pane.pane_id
        let terminalID = result.root_pane.terminal_id
        guard !paneID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              paneID.rangeOfCharacter(from: .controlCharacters) == nil,
              !terminalID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              terminalID.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw MultiplexerError.malformedOutput(kind: .herdr, detail: json)
        }
        return RemoteSession(
            id: paneID,
            name: name,
            kind: .herdr,
            terminalID: terminalID,
            isAttached: false,
            isAlive: true,
            windowCount: 1,
            workingDirectory: directory)
    }

    public func focus(window: RemoteWindow) -> String {
        "herdr terminal attach \(shellQuoted(window.terminalID ?? ""))"
    }

    public func kill(_ session: RemoteSession) -> String {
        "herdr pane close \(shellQuoted(session.id))"
    }

    public func rename(_ session: RemoteSession, to newName: String) -> String {
        "herdr pane rename \(shellQuoted(session.id)) \(shellQuoted(newName))"
    }
}
