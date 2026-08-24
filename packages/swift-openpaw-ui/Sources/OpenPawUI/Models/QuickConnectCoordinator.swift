import Foundation
import Observation
import OpenPawTerminalCore
import OpenPawProtocol

@MainActor
@Observable
public final class QuickConnectCoordinator {
    public enum FailurePoint: Sendable, Hashable { case reviewing, installingCredential, savingHost, connectingSSH, openingHostAPI, pairing, loadingWorkspace }
    public enum Stage: Sendable, Hashable {
        case idle
        case reviewing
        case installingCredential
        case savingHost
        case connectingSSH
        case awaitingHostTrust
        case openingHostAPI
        case pairing
        case loadingWorkspace
        case connected
        case failed(FailurePoint, String)
        case cancelled
    }

    public private(set) var stage: Stage = .idle
    public private(set) var proposal: QuickConnectProposal?
    public private(set) var currentLease: HostConnectionLease?
    public private(set) var terminalRouteIntent: HostConnectionLease?

    private let model: OpenPawModel
    private let installer: any QuickConnectCredentialInstalling
    private let now: @Sendable () -> Date
    private let persistHostStore: @MainActor @Sendable (HostStore) -> Void
    private var generation = 0
    private var task: Task<Void, Never>?
    private var pendingConfirmation: (proposal: QuickConnectProposal, target: QuickConnectTarget, username: String, auth: AuthMethod, deviceName: String)?

    public init(model: OpenPawModel, installer: any QuickConnectCredentialInstalling, now: @escaping @Sendable () -> Date = Date.init, persistHostStore: @escaping @MainActor @Sendable (HostStore) -> Void = { _ in }) {
        self.model = model
        self.installer = installer
        self.now = now
        self.persistHostStore = persistHostStore
    }

    public func begin(_ proposal: QuickConnectProposal) {
        generation += 1
        task?.cancel()
        self.proposal = proposal
        self.currentLease = nil
        self.terminalRouteIntent = nil
        self.pendingConfirmation = nil
        self.stage = .reviewing
    }

    public func confirm(_ choice: QuickConnectCredentialChoice, target: QuickConnectTarget? = nil, username: String? = nil, deviceName: String = ProcessInfo.processInfo.hostName) {
        guard let proposal else { return }
        let reviewedTarget = target ?? proposal.targets.first
        let reviewedUsername = (username ?? proposal.username).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let reviewedTarget, !reviewedUsername.isEmpty else {
            stage = .failed(.reviewing, "A target and username must be confirmed.")
            return
        }
        generation += 1
        let generation = generation
        task?.cancel()
        let credential = CredentialBox(choice)
        let selectionSnapshot = model.selectedHostID
        let storeSnapshot = model.hostStore
        task = Task { [weak self] in
            await self?.run(proposal: proposal, target: reviewedTarget, username: reviewedUsername, credential: credential, deviceName: deviceName, selectionSnapshot: selectionSnapshot, storeSnapshot: storeSnapshot, generation: generation)
        }
    }

    public func resumeAfterHostTrust() {
        guard case .awaitingHostTrust = stage, let pending = pendingConfirmation else { return }
        let generation = generation
        task?.cancel()
        task = Task { [weak self] in
            await self?.connectAndPair(proposal: pending.proposal, target: pending.target, username: pending.username, auth: pending.auth, deviceName: pending.deviceName, generation: generation)
        }
    }

    public func cancel() {
        generation += 1
        task?.cancel()
        task = nil
        pendingConfirmation = nil
        currentLease = nil
        stage = .cancelled
    }

    private func run(proposal: QuickConnectProposal, target: QuickConnectTarget, username: String, credential: CredentialBox, deviceName: String, selectionSnapshot: HostRecord.ID?, storeSnapshot: HostStore, generation: Int) async {
        do {
            try ensureCurrent(generation, proposal: proposal)
            try ensureNotExpired(proposal)
            stage = .installingCredential
            let auth = try await installCredential(credential.take())
            try ensureCurrent(generation, proposal: proposal)
            guard model.selectedHostID == selectionSnapshot, model.hostStore == storeSnapshot else { throw HostPairingError.staleConnection }
            try ensureNotExpired(proposal)
            await connectAndPair(proposal: proposal, target: target, username: username, auth: auth, deviceName: deviceName, generation: generation)
        } catch is CancellationError {
            if self.generation == generation { stage = .cancelled }
        } catch {
            if self.generation == generation { stage = .failed(.installingCredential, String(describing: error)) }
        }
    }

    private func connectAndPair(proposal: QuickConnectProposal, target: QuickConnectTarget? = nil, username: String? = nil, auth: AuthMethod, deviceName: String, generation: Int) async {
        do {
            try ensureCurrent(generation, proposal: proposal)
            stage = .savingHost
            let reviewedTarget = target ?? proposal.targets.first!
            let reviewedUsername = username ?? proposal.username
            let host = makeHost(proposal: proposal, target: reviewedTarget, username: reviewedUsername, auth: auth)
            model.hostStore.upsert(host)
            persistHostStore(model.hostStore)
            await model.selectHost(host.id)
            try ensureCurrent(generation, proposal: proposal)
            stage = .connectingSSH
            pendingConfirmation = (proposal, reviewedTarget, reviewedUsername, auth, deviceName)
            let lease = await model.connectSelectedHost(purpose: proposal.pairingCode == nil ? .normal : .awaitingPairing)
            guard let lease else {
                if let prompt = model.hostKeyPrompt, prompt.allowsTrust { stage = .awaitingHostTrust; return }
                throw HostPairingError.staleConnection
            }
            guard model.ownsConnection(lease) else { throw HostPairingError.staleConnection }
            currentLease = lease
            terminalRouteIntent = lease
            if model.hostKeyPrompt != nil { stage = .awaitingHostTrust; return }
            stage = .openingHostAPI
            if let code = proposal.pairingCode {
                stage = .pairing
                _ = try await model.pairHost(pairingCode: code, deviceName: deviceName, lease: lease)
            }
            try ensureCurrent(generation, proposal: proposal)
            guard model.ownsConnection(lease) else { throw HostPairingError.staleConnection }
            stage = .loadingWorkspace
            try ensureCurrent(generation, proposal: proposal)
            guard model.ownsConnection(lease) else { throw HostPairingError.staleConnection }
            stage = .connected
            pendingConfirmation = nil
        } catch is CancellationError {
            if self.generation == generation { stage = .cancelled }
        } catch {
            if self.generation == generation {
                if currentLease != nil || model.connection.isConnected { terminalRouteIntent = currentLease ?? model.currentConnectionLease }
                stage = .failed(failurePoint, String(describing: error))
            }
        }
    }

    private func installCredential(_ choice: QuickConnectCredentialChoice) async throws -> AuthMethod {
        try await installer.install(choice)
    }

    private var failurePoint: FailurePoint {
        switch stage {
        case .savingHost: .savingHost
        case .connectingSSH, .awaitingHostTrust: .connectingSSH
        case .openingHostAPI: .openingHostAPI
        case .pairing: .pairing
        case .loadingWorkspace, .connected: .loadingWorkspace
        default: .reviewing
        }
    }

    private func makeHost(proposal: QuickConnectProposal, target: QuickConnectTarget, username: String, auth: AuthMethod) -> HostRecord {
        let pins = proposal.hostKeys.map { KnownHostEntry(keyType: $0.algorithm, fingerprint: $0.fingerprint, addedAt: now()) }
        if var existing = model.hostStore.hosts.first(where: { $0.username == username && $0.hostname == target.hostname && $0.port == target.port }) {
            existing.nickname = proposal.nickname
            existing.hostAPIPort = proposal.hostAPIPort.flatMap(UInt16.init(exactly:))
            existing.auth = auth
            if !pins.isEmpty { existing.knownHosts = pins }
            return existing
        }
        return HostRecord(nickname: proposal.nickname, hostname: target.hostname, port: target.port, hostAPIPort: proposal.hostAPIPort.flatMap(UInt16.init(exactly:)), username: username, auth: auth, knownHosts: pins)
    }

    private func ensureCurrent(_ generation: Int, proposal: QuickConnectProposal) throws {
        try Task.checkCancellation()
        guard self.generation == generation, self.proposal?.id == proposal.id else { throw HostPairingError.staleConnection }
    }

    private func ensureNotExpired(_ proposal: QuickConnectProposal) throws {
        if let expiresAt = proposal.expiresAt, now() > expiresAt { throw QuickConnectLinkError.expired }
    }
}

private final class CredentialBox: @unchecked Sendable {
    private let lock = NSLock()
    private var choice: QuickConnectCredentialChoice?
    init(_ choice: QuickConnectCredentialChoice) { self.choice = choice }
    func take() -> QuickConnectCredentialChoice {
        lock.withLock {
            defer { choice = nil }
            return choice!
        }
    }
}
