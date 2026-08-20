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
    public var isActive: Bool
    public var paneCount: Int
    public var currentCommand: String?
    public var currentPath: String?

    public init(
        id: String,
        sessionID: String,
        index: Int,
        name: String,
        isActive: Bool = false,
        paneCount: Int = 1,
        currentCommand: String? = nil,
        currentPath: String? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.index = index
        self.name = name
        self.isActive = isActive
        self.paneCount = paneCount
        self.currentCommand = currentCommand
        self.currentPath = currentPath
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case sessionID = "session_id"
        case index, name
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
    /// ASCII unit separator. Used as the tmux `-F` field delimiter because it
    /// cannot appear in session, window or path names, unlike tabs or colons.
    public static let fieldSeparator = "\u{1F}"
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

private func fields(_ line: String) -> [String] {
    line.components(separatedBy: Multiplexer.fieldSeparator)
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
        "#{session_id}", "#{session_name}", "#{session_attached}", "#{session_windows}",
        "#{session_created}", "#{session_activity}", "#{session_path}",
    ].joined(separator: Multiplexer.fieldSeparator)

    public static let windowFormat = [
        "#{window_id}", "#{window_index}", "#{window_name}", "#{window_active}",
        "#{window_panes}", "#{pane_current_command}", "#{pane_current_path}",
    ].joined(separator: Multiplexer.fieldSeparator)

    public static let paneFormat = [
        "#{pane_id}", "#{pane_index}", "#{pane_active}", "#{pane_width}", "#{pane_height}",
        "#{pane_current_command}", "#{pane_current_path}", "#{pane_title}",
    ].joined(separator: Multiplexer.fieldSeparator)

    public let kind = MultiplexerKind.tmux

    public init() {}

    public var discoverCommand: String {
        "tmux list-sessions -F \(shellQuoted(Self.sessionFormat))"
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
        let parts = fields(line)
        guard parts.count >= 7 else {
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
            "tmux list-windows -t \(shellQuoted(session.id)) -F \(shellQuoted(Self.windowFormat))"
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
        let parts = fields(line)
        guard parts.count >= 7, let index = Int(parts[1]) else {
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
            "tmux list-panes -t \(shellQuoted(window.id)) -F \(shellQuoted(Self.paneFormat))"
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
        let parts = fields(line)
        guard parts.count >= 8, let index = Int(parts[1]), let width = Int(parts[3]),
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

public struct HerdrAdapter: MultiplexerAdapter {
    public let kind = MultiplexerKind.herdr

    public init() {}

    public var discoverCommand: String { "herdr list --json" }

    private struct SessionDTO: Decodable {
        var id: String
        var name: String?
        var attached: Bool?
        var alive: Bool?
        var windows: Int?
        var created_at: Date?
        var last_activity_at: Date?
        var cwd: String?
    }

    private struct SessionEnvelope: Decodable {
        var sessions: [SessionDTO]
    }

    private struct WindowDTO: Decodable {
        var id: String
        var index: Int
        var name: String?
        var active: Bool?
        var panes: Int?
        var command: String?
        var cwd: String?
    }

    private struct WindowEnvelope: Decodable {
        var windows: [WindowDTO]
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Herdr predates its own `--json` flag on older installs; an unknown
    /// subcommand or flag means "no Herdr here", not a hard failure.
    private static func isUnknownCommand(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.contains("unknown subcommand")
            || lowered.contains("unrecognized subcommand")
            || lowered.contains("unrecognised subcommand")
            || lowered.contains("unknown command")
            || lowered.contains("unexpected argument")
            || lowered.contains("unknown flag")
            || lowered.contains("command not found")
            || lowered.contains("no such subcommand")
    }

    public func discoverSessions(runner: any CommandRunner) async throws -> [RemoteSession] {
        let output: String
        do {
            output = try await runner.run(discoverCommand)
        } catch let failure as CommandFailure {
            if Self.isUnknownCommand(failure.output) || isBenignEmptyOutput(failure.output) {
                return []
            }
            throw failure
        }
        if Self.isUnknownCommand(output) || output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return []
        }
        return try parseSessions(output)
    }

    public func parseSessions(_ json: String) throws -> [RemoteSession] {
        guard let data = json.data(using: .utf8) else {
            throw MultiplexerError.malformedOutput(kind: .herdr, detail: "output is not UTF-8")
        }
        let decoder = Self.decoder()
        let dtos: [SessionDTO]
        if let envelope = try? decoder.decode(SessionEnvelope.self, from: data) {
            dtos = envelope.sessions
        } else if let bare = try? decoder.decode([SessionDTO].self, from: data) {
            dtos = bare
        } else {
            throw MultiplexerError.malformedOutput(kind: .herdr, detail: json)
        }
        return dtos.map { dto in
            RemoteSession(
                id: dto.id,
                name: dto.name ?? dto.id,
                kind: .herdr,
                isAttached: dto.attached ?? false,
                isAlive: dto.alive ?? true,
                windowCount: dto.windows ?? 0,
                createdAt: dto.created_at,
                lastActivityAt: dto.last_activity_at,
                uptime: nil,
                workingDirectory: dto.cwd
            )
        }
    }

    public func listWindows(session: RemoteSession, runner: any CommandRunner) async throws
        -> [RemoteWindow]
    {
        let command = "herdr windows --session \(shellQuoted(session.id)) --json"
        let output: String
        do {
            output = try await runner.run(command)
        } catch let failure as CommandFailure {
            if Self.isUnknownCommand(failure.output) || isBenignEmptyOutput(failure.output) {
                return []
            }
            throw failure
        }
        if Self.isUnknownCommand(output) || output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return []
        }
        return try parseWindows(output, sessionID: session.id)
    }

    public func parseWindows(_ json: String, sessionID: String) throws -> [RemoteWindow] {
        guard let data = json.data(using: .utf8) else {
            throw MultiplexerError.malformedOutput(kind: .herdr, detail: "output is not UTF-8")
        }
        let decoder = Self.decoder()
        let dtos: [WindowDTO]
        if let envelope = try? decoder.decode(WindowEnvelope.self, from: data) {
            dtos = envelope.windows
        } else if let bare = try? decoder.decode([WindowDTO].self, from: data) {
            dtos = bare
        } else {
            throw MultiplexerError.malformedOutput(kind: .herdr, detail: json)
        }
        return dtos.map { dto in
            RemoteWindow(
                id: dto.id,
                sessionID: sessionID,
                index: dto.index,
                name: dto.name ?? "\(dto.index)",
                isActive: dto.active ?? false,
                paneCount: dto.panes ?? 1,
                currentCommand: dto.command,
                currentPath: dto.cwd
            )
        }
    }

    public func attach(_ session: RemoteSession) -> String {
        "herdr attach \(shellQuoted(session.id))"
    }

    public func create(name: String, directory: String?) -> String {
        var command = "herdr new --name \(shellQuoted(name))"
        if let directory, !directory.isEmpty {
            command += " --cwd \(shellQuoted(directory))"
        }
        return command
    }

    public func focus(window: RemoteWindow) -> String {
        "herdr focus --session \(shellQuoted(window.sessionID)) --window \(shellQuoted(window.id))"
    }

    public func kill(_ session: RemoteSession) -> String {
        "herdr kill \(shellQuoted(session.id))"
    }

    public func rename(_ session: RemoteSession, to newName: String) -> String {
        "herdr rename \(shellQuoted(session.id)) \(shellQuoted(newName))"
    }
}
