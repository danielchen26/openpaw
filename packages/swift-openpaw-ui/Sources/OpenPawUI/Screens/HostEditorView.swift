import Foundation
import OpenPawProtocol
import OpenPawTerminalCore
import SwiftUI

// MARK: - Validation

/// One specific thing that is wrong with a draft, tied to the field that is wrong so the editor can print it
/// under that field instead of showing a single generic "invalid" banner.
public struct ValidationIssue: Identifiable, Sendable, Hashable {
    public enum Field: String, Sendable, Hashable, CaseIterable {
        case hostname
        case port
        case username
        case terminalType
        case geometry
        case keepalive
        case jumpHost
        case credential
    }

    public let field: Field
    /// Says what is wrong and what an acceptable value looks like. Never "invalid input".
    public let message: String
    /// Index into `HostDraft.jumpHosts` when the issue belongs to a hop rather than the host itself.
    public let hopIndex: Int?

    public init(field: Field, message: String, hopIndex: Int? = nil) {
        self.field = field
        self.message = message
        self.hopIndex = hopIndex
    }

    public var id: String { "\(field.rawValue)|\(hopIndex.map(String.init) ?? "-")|\(message)" }
}

// MARK: - Session profile

/// One hop in a ProxyJump chain. Hops are dialled in order, so index 0 is reached first.
public struct JumpHop: Identifiable, Sendable, Hashable, Codable {
    public var id: UUID
    public var hostname: String
    public var port: Int
    public var username: String

    public init(id: UUID = UUID(), hostname: String = "", port: Int = 22, username: String = "") {
        self.id = id
        self.hostname = hostname
        self.port = port
        self.username = username
    }
}

/// The part of a host's setup that belongs to *this device* rather than to the host itself.
///
/// `HostRecord` is the shared, exportable identity of a machine: where it is, who you log in as, which key, which
/// transport, which multiplexer. Terminal geometry, `TERM`, keepalive and the jump chain are session mechanics —
/// a phone wants 80×24 and a desk iPad wants 200×50 for the same host — so they live here, keyed by host id, and
/// are never written into the exportable host list.
public struct SessionProfile: Sendable, Hashable, Codable {
    public var terminalType: String
    public var columns: Int
    public var rows: Int
    /// Seconds between keepalives. Zero turns them off.
    public var keepaliveSeconds: Int
    public var jumpHosts: [JumpHop]
    /// Last time this device opened a session on the host.
    public var lastConnectedAt: Date?

    public init(
        terminalType: String = "xterm-256color",
        columns: Int = 80,
        rows: Int = 24,
        keepaliveSeconds: Int = 30,
        jumpHosts: [JumpHop] = [],
        lastConnectedAt: Date? = nil
    ) {
        self.terminalType = terminalType
        self.columns = columns
        self.rows = rows
        self.keepaliveSeconds = keepaliveSeconds
        self.jumpHosts = jumpHosts
        self.lastConnectedAt = lastConnectedAt
    }

    private enum CodingKeys: String, CodingKey {
        case terminalType = "terminal_type"
        case columns
        case rows
        case keepaliveSeconds = "keepalive_seconds"
        case jumpHosts = "jump_hosts"
        case lastConnectedAt = "last_connected_at"
    }
}

// MARK: - Draft

/// The editable form of a host.
///
/// A draft is a plain value with plain fields: an in-progress port is an `Int`, not a `KeychainReference` that
/// throws, and a half-typed hostname is just a short string. That is what lets `validate()` be pure, total and
/// testable without a keychain, a network or a view.
public struct HostDraft: Sendable, Hashable {
    public enum AuthKind: String, Sendable, Hashable, CaseIterable {
        case password
        case privateKey
        case agentForwarding

        public var displayName: String {
            switch self {
            case .password: "Password"
            case .privateKey: "Private key"
            case .agentForwarding: "Agent forwarding"
            }
        }

        /// What will actually happen at connect time, in the user's words.
        public var explanation: String {
            switch self {
            case .password:
                "The password is read from the keychain at connect time. OpenPaw never stores it in the host list."
            case .privateKey:
                "The key stays in the keychain. OpenPaw holds a reference to it, never the key itself."
            case .agentForwarding:
                "Your running SSH agent answers the challenge. Nothing is stored on this device."
            }
        }
    }

    public var nickname: String
    public var hostname: String
    public var port: Int
    public var username: String
    public var authKind: AuthKind
    public var passwordReference: String
    public var keyReference: String
    public var passphraseReference: String
    /// `nil` selects the automatic policy: `TransportSelector` orders the attempts and falls back to SSH.
    public var preferredTransport: TransportKind?
    /// `nil` means "plain login shell, no multiplexer".
    public var multiplexer: MultiplexerKind?
    public var tags: [String]
    public var profile: SessionProfile

    public init(
        nickname: String = "",
        hostname: String = "",
        port: Int = 22,
        username: String = "",
        authKind: AuthKind = .agentForwarding,
        passwordReference: String = "",
        keyReference: String = "",
        passphraseReference: String = "",
        preferredTransport: TransportKind? = nil,
        multiplexer: MultiplexerKind? = .tmux,
        tags: [String] = [],
        profile: SessionProfile = SessionProfile()
    ) {
        self.nickname = nickname
        self.hostname = hostname
        self.port = port
        self.username = username
        self.authKind = authKind
        self.passwordReference = passwordReference
        self.keyReference = keyReference
        self.passphraseReference = passphraseReference
        self.preferredTransport = preferredTransport
        self.multiplexer = multiplexer
        self.tags = tags
        self.profile = profile
    }

    /// A host with no nickname falls back to its hostname everywhere it is displayed, so the nickname field is
    /// genuinely optional rather than a required label people type twice.
    public var resolvedNickname: String {
        nickname.trimmingCharacters(in: .whitespaces).isEmpty
            ? hostname.trimmingCharacters(in: .whitespaces)
            : nickname.trimmingCharacters(in: .whitespaces)
    }

    public var jumpHosts: [JumpHop] {
        get { profile.jumpHosts }
        set { profile.jumpHosts = newValue }
    }

    // MARK: Validation

    public static let portRange = 1...65_535
    public static let columnRange = 20...500
    public static let rowRange = 5...200
    public static let keepaliveRange = 0...3_600

    /// Every problem with this draft, in the order the fields appear in the editor. Empty means savable.
    public func validate() -> [ValidationIssue] {
        var issues: [ValidationIssue] = []

        let host = hostname.trimmingCharacters(in: .whitespaces)
        if host.isEmpty {
            issues.append(
                ValidationIssue(field: .hostname, message: "Enter a hostname or IP address to connect to."))
        } else if host.contains(where: \.isWhitespace) {
            issues.append(ValidationIssue(field: .hostname, message: "A hostname cannot contain spaces."))
        }

        if !Self.portRange.contains(port) {
            issues.append(
                ValidationIssue(
                    field: .port, message: "Use a port between 1 and 65535. SSH usually listens on 22."))
        }

        if username.trimmingCharacters(in: .whitespaces).isEmpty {
            issues.append(ValidationIssue(field: .username, message: "Enter the account name to log in as."))
        } else if username.contains(where: \.isWhitespace) {
            issues.append(ValidationIssue(field: .username, message: "A username cannot contain spaces."))
        }

        if profile.terminalType.trimmingCharacters(in: .whitespaces).isEmpty {
            issues.append(
                ValidationIssue(
                    field: .terminalType, message: "TERM cannot be empty. xterm-256color suits most hosts."))
        }

        if !Self.columnRange.contains(profile.columns) || !Self.rowRange.contains(profile.rows) {
            issues.append(
                ValidationIssue(
                    field: .geometry,
                    message: "Use 20-500 columns and 5-200 rows. The size is renegotiated once the view appears."))
        }

        if !Self.keepaliveRange.contains(profile.keepaliveSeconds) {
            issues.append(
                ValidationIssue(
                    field: .keepalive,
                    message: "Use 0-3600 seconds. Zero turns keepalives off and lets idle NAT entries expire."))
        }

        for (index, hop) in profile.jumpHosts.enumerated() {
            let hopHost = hop.hostname.trimmingCharacters(in: .whitespaces)
            if hopHost.isEmpty {
                issues.append(
                    ValidationIssue(
                        field: .jumpHost, message: "Hop \(index + 1) has no hostname. Remove it or fill it in.",
                        hopIndex: index))
            } else if hopHost.contains(where: \.isWhitespace) {
                issues.append(
                    ValidationIssue(
                        field: .jumpHost, message: "Hop \(index + 1) has a space in its hostname.", hopIndex: index))
            }
            if !Self.portRange.contains(hop.port) {
                issues.append(
                    ValidationIssue(
                        field: .jumpHost, message: "Hop \(index + 1) needs a port between 1 and 65535.",
                        hopIndex: index))
            }
            if hop.username.contains(where: \.isWhitespace) {
                issues.append(
                    ValidationIssue(
                        field: .jumpHost, message: "Hop \(index + 1) has a space in its username.", hopIndex: index))
            }
        }

        switch authKind {
        case .password where passwordReference.trimmingCharacters(in: .whitespaces).isEmpty:
            issues.append(
                ValidationIssue(
                    field: .credential,
                    message: "Name the keychain entry holding the password. OpenPaw stores the name, not the secret."))
        case .privateKey where keyReference.trimmingCharacters(in: .whitespaces).isEmpty:
            issues.append(
                ValidationIssue(
                    field: .credential,
                    message: "Name the keychain entry holding the private key. OpenPaw stores the name, not the key."))
        default:
            break
        }

        return issues
    }

    public var isValid: Bool { validate().isEmpty }

    // MARK: Conversion

    /// The single place a draft becomes a record.
    ///
    /// Throws when a keychain reference is rejected — pasting a whole private key into the reference field is the
    /// common mistake, and `KeychainReference` refuses it rather than persisting key material. Pass `existing` when
    /// editing so pinned host keys and the last known good transport are carried over instead of being dropped.
    public func record(id: HostID = UUID(), existing: HostRecord? = nil) throws -> HostRecord {
        HostRecord(
            id: id,
            nickname: resolvedNickname,
            hostname: hostname.trimmingCharacters(in: .whitespaces),
            port: port,
            username: username.trimmingCharacters(in: .whitespaces),
            auth: try authMethod(),
            preferredTransport: preferredTransport,
            lastSuccessfulTransport: existing?.lastSuccessfulTransport,
            multiplexerPreference: multiplexer,
            knownHosts: existing?.knownHosts ?? [],
            tags: tags
        )
    }

    /// What the transport actually opens. Built here so the geometry, `TERM`, keepalive and jump chain the editor
    /// collects reach the connection unchanged.
    public func configuration() throws -> ConnectionConfiguration {
        let auth = try authMethod()
        let user = username.trimmingCharacters(in: .whitespaces)
        return ConnectionConfiguration(
            host: hostname.trimmingCharacters(in: .whitespaces),
            port: port,
            username: user,
            auth: auth,
            terminalType: profile.terminalType.trimmingCharacters(in: .whitespaces),
            initialSize: PTYSize(columns: profile.columns, rows: profile.rows),
            keepaliveInterval: profile.keepaliveSeconds > 0 ? .seconds(profile.keepaliveSeconds) : nil,
            // Hops reuse the host's credentials, which the editor states plainly rather than hiding a second set
            // of auth fields per hop that almost nobody needs.
            jumpHosts: profile.jumpHosts.map { hop in
                let hopUser = hop.username.trimmingCharacters(in: .whitespaces)
                return ConnectionConfiguration(
                    host: hop.hostname.trimmingCharacters(in: .whitespaces),
                    port: hop.port,
                    username: hopUser.isEmpty ? user : hopUser,
                    auth: auth
                )
            },
            requestedTransport: preferredTransport
        )
    }

    private func authMethod() throws -> AuthMethod {
        switch authKind {
        case .password:
            return .password(reference: try KeychainReference(identifier: passwordReference))
        case .privateKey:
            let passphrase = passphraseReference.trimmingCharacters(in: .whitespaces)
            return .privateKey(
                reference: try KeychainReference(identifier: keyReference),
                passphraseRef: passphrase.isEmpty ? nil : try KeychainReference(identifier: passphrase)
            )
        case .agentForwarding:
            return .agentForwarding
        }
    }

    /// Reads an existing record and its device-local profile back into an editable draft.
    public init(record: HostRecord, profile: SessionProfile = SessionProfile()) {
        var authKind = HostDraft.AuthKind.agentForwarding
        var passwordReference = ""
        var keyReference = ""
        var passphraseReference = ""
        switch record.auth {
        case .password(let reference):
            authKind = .password
            passwordReference = reference.identifier
        case .privateKey(let reference, let passphraseRef):
            authKind = .privateKey
            keyReference = reference.identifier
            passphraseReference = passphraseRef?.identifier ?? ""
        case .agentForwarding:
            authKind = .agentForwarding
        }

        self.init(
            nickname: record.nickname,
            hostname: record.hostname,
            port: record.port,
            username: record.username,
            authKind: authKind,
            passwordReference: passwordReference,
            keyReference: keyReference,
            passphraseReference: passphraseReference,
            preferredTransport: record.preferredTransport,
            multiplexer: record.multiplexerPreference,
            tags: record.tags,
            profile: profile
        )
    }
}

// MARK: - Transport availability

/// Which transports this build can actually open.
///
/// Mosh and Eternal Terminal are designed for, ordered by `TransportSelector` and named in the picker, but their
/// transports are not written yet. The honest thing is to mark the row rather than let someone pin one and watch
/// the connection fail with a shrug.
public enum TransportAvailability: Sendable {
    public static let built: Set<TransportKind> = [.ssh]

    public static func isBuilt(_ kind: TransportKind?) -> Bool {
        guard let kind else { return true }
        return built.contains(kind)
    }

    public static func note(for kind: TransportKind?) -> String? {
        guard let kind, !built.contains(kind) else { return nil }
        return "not built yet"
    }
}

// MARK: - Editor

@MainActor
public struct HostEditorView: View {
    private let model: OpenPawModel
    private let settings: OpenPawSettings
    private let existing: HostRecord?
    private let onDismiss: () -> Void
    private let onCancel: () -> Void
    private let cancelTitle: String

    @State private var draft: HostDraft
    @State private var newTag = ""
    @State private var credentialError: String?
    @State private var hasAttemptedSave = false

    /// Pass `record` to edit, omit it to add. Saving writes into `model.hostStore` and the device-local profile.
    public init(
        model: OpenPawModel,
        settings: OpenPawSettings,
        record: HostRecord? = nil,
        initialDraft: HostDraft? = nil,
        onDismiss: @escaping () -> Void,
        onCancel: (() -> Void)? = nil
    ) {
        self.model = model
        self.settings = settings
        self.existing = record
        self.onDismiss = onDismiss
        self.onCancel = onCancel ?? onDismiss
        self.cancelTitle = onCancel == nil ? "Cancel" : "Back"
        if let record {
            _draft = State(initialValue: HostDraft(record: record, profile: settings.profile(for: record.id)))
        } else {
            _draft = State(initialValue: initialDraft ?? HostDraft())
        }
    }

    private var issues: [ValidationIssue] { draft.validate() }

    /// Field level messages appear once you have tried to save, so the form does not shout at you while you are
    /// still typing the first character of the hostname. Jump hops are the exception: you added them explicitly.
    private func issue(_ field: ValidationIssue.Field, hop: Int? = nil) -> String? {
        guard hasAttemptedSave || field == .jumpHost else { return nil }
        return issues.first { $0.field == field && $0.hopIndex == hop }?.message
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: OpenPawTheme.Space.large) {
                identity
                credentials
                transport
                jumpChain
                session
                tagList
            }
            .padding(OpenPawTheme.Space.large)
            .frame(maxWidth: 620, alignment: .leading)
        }
        .background(OpenPawTheme.ink)
        .tint(OpenPawTheme.textPrimary)
        .navigationTitle(existing == nil ? "Add host" : draft.resolvedNickname)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(cancelTitle, action: onCancel)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
                    .disabled(hasAttemptedSave && !issues.isEmpty)
            }
        }
    }

    // MARK: Sections

    private var identity: some View {
        Panel(label: "Identity") {
            VStack(alignment: .leading, spacing: OpenPawTheme.Space.medium) {
                ShellField(
                    label: "Nickname",
                    placeholder: draft.hostname.isEmpty ? "workshop" : draft.hostname,
                    text: $draft.nickname)
                ShellField(
                    label: "Hostname", placeholder: "10.0.0.4 or box.example.com", text: $draft.hostname,
                    issue: issue(.hostname))
                HStack(alignment: .top, spacing: OpenPawTheme.Space.medium) {
                    ShellNumberField(label: "Port", value: $draft.port, issue: issue(.port))
                        .frame(maxWidth: 140)
                    ShellField(
                        label: "Username", placeholder: "you", text: $draft.username, issue: issue(.username))
                }
            }
        }
    }

    private var credentials: some View {
        Panel(label: "Authentication") {
            VStack(alignment: .leading, spacing: OpenPawTheme.Space.medium) {
                Picker("Authentication", selection: $draft.authKind) {
                    ForEach(HostDraft.AuthKind.allCases, id: \.self) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Text(draft.authKind.explanation)
                    .font(OpenPawTheme.Human.caption)
                    .foregroundStyle(OpenPawTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                switch draft.authKind {
                case .password:
                    ShellField(
                        label: "Keychain entry", placeholder: "workshop-password",
                        text: $draft.passwordReference, issue: issue(.credential))
                case .privateKey:
                    ShellField(
                        label: "Key entry", placeholder: "id_ed25519", text: $draft.keyReference,
                        issue: issue(.credential))
                    ShellField(
                        label: "Passphrase entry", placeholder: "optional", text: $draft.passphraseReference)
                case .agentForwarding:
                    EmptyView()
                }

                if let credentialError {
                    ShellIssueText(credentialError)
                }
            }
        }
    }

    private var transport: some View {
        Panel(label: "Transport") {
            VStack(alignment: .leading, spacing: OpenPawTheme.Space.small) {
                transportRow(nil, title: "Automatic", detail: "Try the best available, fall back to SSH.")
                ForEach(TransportKind.allCases, id: \.self) { kind in
                    transportRow(
                        kind, title: kind.displayName,
                        detail: kind.remoteBinary.map { "Needs \($0) on the host." } ?? "Always available.")
                }
                if let last = existing?.lastSuccessfulTransport {
                    Text("Last connected over \(last.displayName).")
                        .font(OpenPawTheme.Human.caption)
                        .foregroundStyle(OpenPawTheme.textTertiary)
                }
            }
        }
    }

    private func transportRow(_ kind: TransportKind?, title: String, detail: String) -> some View {
        let isSelected = draft.preferredTransport == kind
        let isBuilt = TransportAvailability.isBuilt(kind)
        return Button {
            draft.preferredTransport = kind
        } label: {
            HStack(alignment: .top, spacing: OpenPawTheme.Space.medium) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? OpenPawTheme.textPrimary : OpenPawTheme.textTertiary)
                VStack(alignment: .leading, spacing: OpenPawTheme.Space.hair) {
                    HStack(spacing: OpenPawTheme.Space.small) {
                        Text(title)
                            .font(OpenPawTheme.Machine.body)
                            .foregroundStyle(isBuilt ? OpenPawTheme.textPrimary : OpenPawTheme.textTertiary)
                        if let note = TransportAvailability.note(for: kind) {
                            Text(note).microLabel(OpenPawTheme.warn)
                        }
                    }
                    Text(detail)
                        .font(OpenPawTheme.Human.caption)
                        .foregroundStyle(OpenPawTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isBuilt)
        .accessibilityLabel(isBuilt ? title : "\(title), not built yet")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var jumpChain: some View {
        Panel(label: "Jump hosts") {
            VStack(alignment: .leading, spacing: OpenPawTheme.Space.medium) {
                Text(
                    draft.jumpHosts.isEmpty
                        ? "Connects directly. Add a hop to reach a host through a bastion."
                        : "Dialled in order, top first. Hops reuse the credentials above."
                )
                .font(OpenPawTheme.Human.caption)
                .foregroundStyle(OpenPawTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

                ForEach(Array(draft.jumpHosts.enumerated()), id: \.element.id) { index, hop in
                    hopEditor(index: index)
                        .id(hop.id)
                }

                Button {
                    draft.jumpHosts.append(JumpHop(username: draft.username))
                } label: {
                    Label("Add hop", systemImage: "plus")
                        .font(OpenPawTheme.Machine.body)
                }
                .buttonStyle(.plain)
                .frame(minHeight: 44)
                .foregroundStyle(OpenPawTheme.textPrimary)
            }
        }
    }

    private func hopEditor(index: Int) -> some View {
        VStack(alignment: .leading, spacing: OpenPawTheme.Space.small) {
            HStack(spacing: OpenPawTheme.Space.small) {
                Text("hop \(index + 1)").microLabel()
                Spacer(minLength: 0)
                Button {
                    move(from: index, to: index - 1)
                } label: {
                    Image(systemName: "arrow.up")
                }
                .disabled(index == 0)
                .accessibilityLabel("Move hop \(index + 1) earlier")
                Button {
                    move(from: index, to: index + 1)
                } label: {
                    Image(systemName: "arrow.down")
                }
                .disabled(index == draft.jumpHosts.count - 1)
                .accessibilityLabel("Move hop \(index + 1) later")
                Button {
                    draft.jumpHosts.remove(at: index)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .accessibilityLabel("Remove hop \(index + 1)")
            }
            .buttonStyle(.plain)
            .font(OpenPawTheme.Machine.body)
            .foregroundStyle(OpenPawTheme.textSecondary)

            HStack(alignment: .top, spacing: OpenPawTheme.Space.small) {
                ShellField(
                    label: "Host", placeholder: "bastion.example.com", text: hopBinding(index, \.hostname))
                ShellNumberField(label: "Port", value: hopBinding(index, \.port))
                    .frame(maxWidth: 110)
            }
            ShellField(
                label: "Username", placeholder: draft.username.isEmpty ? "you" : draft.username,
                text: hopBinding(index, \.username))
            if let message = issue(.jumpHost, hop: index) {
                ShellIssueText(message)
            }
        }
        .padding(OpenPawTheme.Space.medium)
        .background(OpenPawTheme.well)
        .overlay(Rectangle().stroke(OpenPawTheme.line, lineWidth: OpenPawTheme.hairline))
    }

    private var session: some View {
        Panel(label: "Session") {
            VStack(alignment: .leading, spacing: OpenPawTheme.Space.medium) {
                HStack(alignment: .top, spacing: OpenPawTheme.Space.medium) {
                    ShellNumberField(label: "Columns", value: $draft.profile.columns)
                    ShellNumberField(label: "Rows", value: $draft.profile.rows)
                }
                if let message = issue(.geometry) {
                    ShellIssueText(message)
                }
                Text("The size is renegotiated the moment the terminal appears; this is only the opening request.")
                    .font(OpenPawTheme.Human.caption)
                    .foregroundStyle(OpenPawTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                ShellField(
                    label: "Terminal type", placeholder: "xterm-256color", text: $draft.profile.terminalType,
                    issue: issue(.terminalType))

                VStack(alignment: .leading, spacing: OpenPawTheme.Space.tight) {
                    Text("Keepalive").microLabel()
                    Stepper(value: $draft.profile.keepaliveSeconds, in: HostDraft.keepaliveRange, step: 15) {
                        Text(draft.profile.keepaliveSeconds == 0 ? "off" : "\(draft.profile.keepaliveSeconds)s")
                            .font(OpenPawTheme.Machine.body)
                            .foregroundStyle(OpenPawTheme.textPrimary)
                    }
                    .frame(minHeight: 44)
                    if let message = issue(.keepalive) {
                        ShellIssueText(message)
                    }
                }

                VStack(alignment: .leading, spacing: OpenPawTheme.Space.tight) {
                    Text("Multiplexer").microLabel()
                    Picker("Multiplexer", selection: $draft.multiplexer) {
                        Text("None").tag(MultiplexerKind?.none)
                        ForEach(MultiplexerKind.allCases, id: \.self) { kind in
                            Text(kind.displayName).tag(MultiplexerKind?.some(kind))
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text(
                        draft.multiplexer == nil
                            ? "A plain login shell. Anything running in it dies when the connection drops."
                            : "Sessions survive a dropped connection, and OpenPaw can reattach to them."
                    )
                    .font(OpenPawTheme.Human.caption)
                    .foregroundStyle(OpenPawTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var tagList: some View {
        Panel(label: "Tags") {
            VStack(alignment: .leading, spacing: OpenPawTheme.Space.medium) {
                if !draft.tags.isEmpty {
                    ShellWrap(spacing: OpenPawTheme.Space.small) {
                        ForEach(draft.tags, id: \.self) { tag in
                            Button {
                                draft.tags.removeAll { $0 == tag }
                            } label: {
                                HStack(spacing: OpenPawTheme.Space.tight) {
                                    Text(tag).font(OpenPawTheme.Machine.codeSmall)
                                    Image(systemName: "xmark").font(OpenPawTheme.Machine.codeSmall)
                                }
                                .padding(.horizontal, OpenPawTheme.Space.medium)
                                .frame(minHeight: 44)
                                .foregroundStyle(OpenPawTheme.textSecondary)
                                .background(OpenPawTheme.well)
                                .clipShape(RoundedRectangle(cornerRadius: OpenPawTheme.Radius.chip))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove tag \(tag)")
                        }
                    }
                }
                HStack(alignment: .bottom, spacing: OpenPawTheme.Space.small) {
                    ShellField(label: "New tag", placeholder: "work", text: $newTag)
                    Button("Add", action: addTag)
                        .buttonStyle(.plain)
                        .frame(minHeight: 44)
                        .foregroundStyle(OpenPawTheme.textPrimary)
                        .disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    // MARK: Mutation

    private func hopBinding<Value>(
        _ index: Int, _ path: WritableKeyPath<JumpHop, Value>
    ) -> Binding<Value> {
        Binding(
            get: { draft.jumpHosts[index][keyPath: path] },
            set: { draft.jumpHosts[index][keyPath: path] = $0 }
        )
    }

    private func move(from index: Int, to destination: Int) {
        guard draft.jumpHosts.indices.contains(index), draft.jumpHosts.indices.contains(destination) else { return }
        draft.jumpHosts.swapAt(index, destination)
    }

    private func addTag() {
        let tag = newTag.trimmingCharacters(in: .whitespaces)
        guard !tag.isEmpty, !draft.tags.contains(tag) else { return }
        draft.tags.append(tag)
        newTag = ""
    }

    private func save() {
        hasAttemptedSave = true
        credentialError = nil
        guard draft.validate().isEmpty else { return }
        do {
            let id = existing?.id ?? UUID()
            let record = try draft.record(id: id, existing: existing)
            model.hostStore.upsert(record)
            settings.setProfile(draft.profile, for: id)
            if model.selectedHostID == nil || existing == nil {
                model.selectedHostID = id
            }
            onDismiss()
        } catch {
            credentialError = String(describing: error)
        }
    }
}

// MARK: - Shared field chrome

/// A labelled text field in the machine register: mono type, recessed well, square corners.
struct ShellField: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    var issue: String?

    var body: some View {
        VStack(alignment: .leading, spacing: OpenPawTheme.Space.tight) {
            // Hidden from accessibility because the label is carried by the field itself below. Combining the two
            // into one element, as this view used to, replaces the text field with a plain group: VoiceOver then
            // offers nothing to type into, and the field cannot be reached at all.
            Text(label).microLabel()
                .accessibilityHidden(true)
            TextField(placeholder, text: $text)
                .font(OpenPawTheme.Machine.body)
                .foregroundStyle(OpenPawTheme.textPrimary)
                .textFieldStyle(.plain)
                .padding(.horizontal, OpenPawTheme.Space.small)
                .frame(minHeight: 44)
                .background(OpenPawTheme.well)
                .overlay(
                    Rectangle().stroke(
                        issue == nil ? OpenPawTheme.line : OpenPawTheme.bad, lineWidth: OpenPawTheme.hairline))
                .autocorrectionDisabled()
                #if os(iOS)
                    .textInputAutocapitalization(.never)
                #endif
                .accessibilityLabel(issue.map { "\(label). \($0)" } ?? label)
                .accessibilityIdentifier(label)
            if let issue {
                ShellIssueText(issue)
            }
        }
    }
}

struct ShellNumberField: View {
    let label: String
    @Binding var value: Int
    var issue: String?

    var body: some View {
        VStack(alignment: .leading, spacing: OpenPawTheme.Space.tight) {
            Text(label).microLabel()
            // No grouping separator: a port is an identifier, not a quantity. "2,222" is not a port.
            TextField(label, value: $value, format: .number.grouping(.never))
                .font(OpenPawTheme.Machine.body)
                .foregroundStyle(OpenPawTheme.textPrimary)
                .textFieldStyle(.plain)
                .padding(.horizontal, OpenPawTheme.Space.small)
                .frame(minHeight: 44)
                .background(OpenPawTheme.well)
                .overlay(
                    Rectangle().stroke(
                        issue == nil ? OpenPawTheme.line : OpenPawTheme.bad, lineWidth: OpenPawTheme.hairline))
                #if os(iOS)
                    .keyboardType(.numberPad)
                #endif
            if let issue {
                ShellIssueText(issue)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(issue.map { "\(label). \($0)" } ?? label)
    }
}

/// Validation text is human register: it is a sentence telling you what to do.
struct ShellIssueText: View {
    let message: String

    init(_ message: String) { self.message = message }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: OpenPawTheme.Space.tight) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(OpenPawTheme.Machine.codeSmall)
            Text(message)
                .font(OpenPawTheme.Human.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(OpenPawTheme.bad)
    }
}

/// Minimal flow layout for chips. `Layout` keeps it Dynamic Type safe: chips reflow instead of clipping when the
/// type size grows.
struct ShellWrap: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let limit = proposal.width ?? .infinity
        var x: CGFloat = 0
        var rowHeight: CGFloat = 0
        var height: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > limit {
                height += rowHeight + spacing
                widest = max(widest, x - spacing)
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        widest = max(widest, x - spacing)
        return CGSize(width: min(widest, limit), height: height + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

#Preview("Edit host") {
    let model = PreviewBackend.model(.populated)
    NavigationStack {
        HostEditorView(
            model: model, settings: OpenPawSettings.preview(), record: model.hostStore.hosts.first) {}
    }
    .preferredColorScheme(.dark)
}

#Preview("Add host") {
    NavigationStack {
        HostEditorView(model: PreviewBackend.model(.empty), settings: OpenPawSettings.preview()) {}
    }
    .preferredColorScheme(.dark)
}
