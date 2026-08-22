import Foundation
import OpenPawProtocol
import OpenPawTerminalCore
import SwiftUI

// MARK: - Adapter rows

/// One adapter as the diagnostics screen shows it: what the host has enabled, which agent format version it parses,
/// and how far along that agent's stream this device has read.
public struct AdapterDiagnostic: Identifiable, Sendable, Hashable {
    /// Host-reported adapter name. Kept as a string because a host may run an adapter this build predates.
    public let name: String
    /// `nil` when this build does not know the adapter the host named.
    public let agent: AgentKind?
    /// The agent format version the adapter parses, independent of the protocol version.
    public let formatVersion: String?
    public let lastSeq: UInt64?
    public let lastEventAt: Date?

    public var id: String { name }

    public init(
        name: String, agent: AgentKind?, formatVersion: String?, lastSeq: UInt64?, lastEventAt: Date?
    ) {
        self.name = name
        self.agent = agent
        self.formatVersion = formatVersion
        self.lastSeq = lastSeq
        self.lastEventAt = lastEventAt
    }

    public var displayName: String { agent?.displayName ?? name }

    /// Every adapter the host mentions, whether it reported a version for it or not. Sorted by name so two
    /// screenshots of the same host are diffable.
    public static func rows(health: HealthInfo?, sessions: [SessionSummary]) -> [AdapterDiagnostic] {
        guard let health else { return [] }
        var names = Set(health.adapterVersions.keys)
        for agent in health.agents { names.insert(agent.rawValue) }

        return names.sorted().map { name in
            let agent = AgentKind(rawValue: name)
            let owned = agent.map { kind in sessions.filter { $0.agent == kind } } ?? []
            return AdapterDiagnostic(
                name: name,
                agent: agent,
                formatVersion: health.adapterVersions[name],
                lastSeq: owned.map(\.lastSeq).max(),
                lastEventAt: owned.compactMap(\.lastEventAt).max()
            )
        }
    }
}

// MARK: - Report

/// The whole screen as plain text, for pasting into an issue.
///
/// Built as a pure function so the copied report and the rendered screen cannot disagree: both read the same values
/// from the same place.
public enum DiagnosticsReport {
    public static func text(
        health: HealthInfo?,
        connection: ConnectionState,
        sessions: [SessionSummary],
        repos: [RepoSummary],
        forwardedPort: Int?,
        generatedAt: Date = Date()
    ) -> String {
        var lines: [String] = []
        lines.append("openpaw diagnostics \(ISO8601DateFormatter().string(from: generatedAt))")
        lines.append("host version: \(health?.version ?? "unknown")")
        lines.append("protocol: \(health?.protocolVersion ?? "unknown")")

        let status = ConnectionPresentation.make(connection)
        lines.append("connection: \(status.label)")
        if let detail = status.detail { lines.append("connection detail: \(detail)") }
        lines.append("transport: \(ConnectionPresentation.transportLabel(connection) ?? "none")")
        lines.append("forwarded port: \(forwardedPort.map(String.init) ?? "not forwarded")")

        let previewPorts = health?.previewPorts ?? []
        lines.append(
            "preview ports: \(previewPorts.isEmpty ? "none" : previewPorts.map(String.init).joined(separator: ","))")
        let capabilities = health?.capabilities ?? []
        lines.append("capabilities: \(capabilities.isEmpty ? "none" : capabilities.joined(separator: ","))")

        for adapter in AdapterDiagnostic.rows(health: health, sessions: sessions) {
            lines.append(
                "adapter \(adapter.name): format_version=\(adapter.formatVersion ?? "not reported") "
                    + "last_seq=\(adapter.lastSeq.map(String.init) ?? "-")")
        }

        for session in sessions.sorted(by: { $0.sessionID < $1.sessionID }) {
            lines.append(
                "session \(session.sessionID): agent=\(session.agent.rawValue) state=\(session.state.rawValue) "
                    + "last_seq=\(session.lastSeq) pending=\(session.pendingInbox)")
        }

        for repo in repos.sorted(by: { $0.name < $1.name }) {
            lines.append(
                "repo \(repo.name): branch=\(repo.branch ?? "detached") dirty=\(repo.dirty) "
                    + "ahead=\(repo.ahead) behind=\(repo.behind)")
        }

        return lines.joined(separator: "\n")
    }
}

// MARK: - Screen

/// The screen a user screenshots when filing a bug.
///
/// Every value is copyable individually and the whole thing copies as one block of text, because the failure mode of
/// a diagnostics screen is a photograph of a phone that nobody can grep.
@MainActor
public struct DiagnosticsView: View {
    private let model: OpenPawModel
    private let forwardedPort: Int?

    @State private var didCopyReport = false

    public init(model: OpenPawModel, forwardedPort: Int? = nil) {
        self.model = model
        self.forwardedPort = forwardedPort
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: OpenPawTheme.Space.large) {
                hostPanel
                connectionPanel
                adaptersPanel
                sessionsPanel
                logsPanel
                reportPanel
            }
            .padding(OpenPawTheme.Space.large)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .background(OpenPawTheme.ink)
        .navigationTitle("Diagnostics")
        .refreshable { await model.refresh() }
    }

    // MARK: Host

    private var hostPanel: some View {
        Panel(label: "Host") {
            VStack(alignment: .leading, spacing: OpenPawTheme.Space.medium) {
                if let health = model.health {
                    MonoField(label: "Version", value: health.version, isCopyable: true)
                    MonoField(label: "Protocol", value: health.protocolVersion, isCopyable: true)
                    MonoField(label: "Capabilities", value: listValue(health.capabilities), isCopyable: true)
                    MonoField(
                        label: "Preview ports", value: listValue(health.previewPorts.map(String.init)),
                        isCopyable: true)
                    if health.previewPorts.isEmpty {
                        Text("The host proxies no ports, so the repo preview has nothing to show.")
                            .font(OpenPawTheme.Human.caption)
                            .foregroundStyle(OpenPawTheme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text(
                        """
                        This device has not reached the structured host yet. The terminal still works without it; \
                        the inbox, diffs and transcripts need it.
                        """
                    )
                    .font(OpenPawTheme.Human.prose)
                    .foregroundStyle(OpenPawTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func listValue(_ values: [String]) -> String {
        values.isEmpty ? "none" : values.joined(separator: " ")
    }

    // MARK: Connection

    private var connectionPanel: some View {
        let status = ConnectionPresentation.make(model.connection)
        return Panel(label: "Connection") {
            VStack(alignment: .leading, spacing: OpenPawTheme.Space.medium) {
                MonoField(label: "State", value: status.label, isCopyable: true)
                if let detail = status.detail {
                    MonoField(label: "Detail", value: detail, isCopyable: true)
                }
                MonoField(
                    label: "Transport",
                    value: ConnectionPresentation.transportLabel(model.connection) ?? "none",
                    isCopyable: true)
                MonoField(
                    label: "Forwarded port", value: forwardedPort.map(String.init) ?? "not forwarded",
                    isCopyable: true)
                if let host = model.selectedHost {
                    MonoField(
                        label: "Host entry", value: "\(host.username)@\(host.hostname):\(host.port)",
                        isCopyable: true)
                }
            }
        }
    }

    // MARK: Adapters

    private var adapters: [AdapterDiagnostic] {
        AdapterDiagnostic.rows(health: model.health, sessions: model.sessions)
    }

    private var adaptersPanel: some View {
        Panel(label: "Adapters") {
            VStack(alignment: .leading, spacing: OpenPawTheme.Space.medium) {
                if adapters.isEmpty {
                    Text("The host reported no adapters.")
                        .font(OpenPawTheme.Machine.code)
                        .foregroundStyle(OpenPawTheme.textTertiary)
                } else {
                    ForEach(adapters) { adapter in
                        adapterRow(adapter)
                    }
                    Text(
                        """
                        The format version is the agent's own on-disk format that the adapter parses. It moves \
                        independently of the protocol version above.
                        """
                    )
                    .font(OpenPawTheme.Human.caption)
                    .foregroundStyle(OpenPawTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func adapterRow(_ adapter: AdapterDiagnostic) -> some View {
        VStack(alignment: .leading, spacing: OpenPawTheme.Space.tight) {
            HStack(alignment: .firstTextBaseline, spacing: OpenPawTheme.Space.small) {
                Text(adapter.displayName)
                    .font(OpenPawTheme.Machine.body)
                    .foregroundStyle(OpenPawTheme.textPrimary)
                if adapter.agent == nil {
                    Text("unknown to this build").microLabel(OpenPawTheme.warn)
                }
                Spacer(minLength: 0)
            }
            MonoField(label: "Name", value: adapter.name, isCopyable: true)
            MonoField(
                label: "Format version", value: adapter.formatVersion ?? "not reported", isCopyable: true)
            MonoField(label: "Last seq", value: adapter.lastSeq.map(String.init) ?? "none", isCopyable: true)
            if let last = adapter.lastEventAt {
                HStack(spacing: OpenPawTheme.Space.tight) {
                    Text("last event").microLabel()
                    RelativeTime(date: last)
                        .font(OpenPawTheme.Machine.codeSmall)
                        .foregroundStyle(OpenPawTheme.textSecondary)
                }
            }
        }
        .padding(OpenPawTheme.Space.medium)
        .background(OpenPawTheme.well)
        .clipShape(RoundedRectangle(cornerRadius: OpenPawTheme.Radius.machine, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: OpenPawTheme.Radius.machine, style: .continuous).stroke(OpenPawTheme.line, lineWidth: OpenPawTheme.hairline))
    }

    // MARK: Sessions

    private var sessionsPanel: some View {
        Panel(label: "Sessions") {
            VStack(alignment: .leading, spacing: OpenPawTheme.Space.medium) {
                if model.sessions.isEmpty {
                    Text("No sessions reported.")
                        .font(OpenPawTheme.Machine.code)
                        .foregroundStyle(OpenPawTheme.textTertiary)
                } else {
                    ForEach(model.sessions.sorted { $0.sessionID < $1.sessionID }) { session in
                        sessionRow(session)
                    }
                }
            }
        }
    }

    private func sessionRow(_ session: SessionSummary) -> some View {
        VStack(alignment: .leading, spacing: OpenPawTheme.Space.tight) {
            MonoField(label: "Session", value: session.sessionID, isCopyable: true)
            ShellWrap(spacing: OpenPawTheme.Space.large) {
                labelled("agent", session.agent.rawValue)
                labelled("state", session.state.rawValue)
                labelled("last seq", String(session.lastSeq))
                labelled("held events", String(model.events(for: session.sessionID).count))
                labelled("pending", String(session.pendingInbox))
            }
            NavigationLink {
                EventLogView(model: model, sessionID: session.sessionID)
            } label: {
                HStack(spacing: OpenPawTheme.Space.tight) {
                    Text("Event log").font(OpenPawTheme.Machine.label)
                    Image(systemName: "chevron.right").font(OpenPawTheme.Machine.codeSmall)
                }
                .frame(minHeight: 44)
                .foregroundStyle(OpenPawTheme.textPrimary)
                .contentShape(Rectangle())
            }
            // Plain, because a filled capsule per session row would put three loud primaries on a screen whose
            // whole job is to be read.
            .buttonStyle(.plain)
            .accessibilityLabel("Event log for \(session.sessionID)")
        }
        .padding(OpenPawTheme.Space.medium)
        .background(OpenPawTheme.well)
        .clipShape(RoundedRectangle(cornerRadius: OpenPawTheme.Radius.machine, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: OpenPawTheme.Radius.machine, style: .continuous).stroke(OpenPawTheme.line, lineWidth: OpenPawTheme.hairline))
    }

    private func labelled(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: OpenPawTheme.Space.hair) {
            Text(label).microLabel()
            Text(value)
                .font(OpenPawTheme.Machine.codeSmall)
                .foregroundStyle(OpenPawTheme.textSecondary)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Logs

    private var logsPanel: some View {
        Panel(label: "Logs") {
            VStack(alignment: .leading, spacing: OpenPawTheme.Space.medium) {
                Text(
                    """
                    The raw record behind every screen in the app. Each session above links to its own event \
                    stream; the audit log is the host's record of every decision, whoever made it.
                    """
                )
                .font(OpenPawTheme.Human.prose)
                .foregroundStyle(OpenPawTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                NavigationLink {
                    AuditView(model: model)
                } label: {
                    HStack(spacing: OpenPawTheme.Space.tight) {
                        Text("Audit log").font(OpenPawTheme.Machine.headline)
                        Image(systemName: "chevron.right").font(OpenPawTheme.Machine.codeSmall)
                    }
                    .frame(minHeight: 44)
                    .foregroundStyle(OpenPawTheme.textPrimary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Report

    private var reportPanel: some View {
        Panel(label: "Bug report") {
            VStack(alignment: .leading, spacing: OpenPawTheme.Space.medium) {
                Text(
                    """
                    Copies everything on this screen as plain text. It contains versions, ports, session ids and \
                    counts. It contains no command text, no diff and no token.
                    """
                )
                .font(OpenPawTheme.Human.prose)
                .foregroundStyle(OpenPawTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

                Button {
                    OpenPawClipboard.copy(reportText)
                    didCopyReport = true
                } label: {
                    Text(didCopyReport ? "Copied" : "Copy report")
                        .font(OpenPawTheme.Machine.headline)
                        .padding(.horizontal, OpenPawTheme.Space.medium)
                        .frame(minHeight: 44)
                        .foregroundStyle(OpenPawTheme.ink)
                        .background(OpenPawTheme.textPrimary)
                        .clipShape(RoundedRectangle(cornerRadius: OpenPawTheme.Radius.card))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copy the diagnostics report")

                Text(reportText)
                    .font(OpenPawTheme.Machine.codeSmall)
                    .foregroundStyle(OpenPawTheme.textTertiary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(OpenPawTheme.Space.small)
                    .background(OpenPawTheme.well)
                    .clipShape(RoundedRectangle(cornerRadius: OpenPawTheme.Radius.machine, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: OpenPawTheme.Radius.machine, style: .continuous).stroke(OpenPawTheme.line, lineWidth: OpenPawTheme.hairline))
            }
        }
    }

    private var reportText: String {
        DiagnosticsReport.text(
            health: model.health,
            connection: model.connection,
            sessions: model.sessions,
            repos: model.repos,
            forwardedPort: forwardedPort
        )
    }
}

#Preview("Diagnostics") {
    NavigationStack {
        DiagnosticsView(model: PreviewBackend.model(.populated), forwardedPort: 8787)
    }
    .preferredColorScheme(.dark)
}

#Preview("Diagnostics, no host") {
    NavigationStack {
        DiagnosticsView(model: PreviewBackend.model(.disconnected))
    }
    .preferredColorScheme(.dark)
}
