import Foundation
import Observation
import OpenPawTerminalCore
import OpenPawProtocol

@MainActor
@Observable
public final class QuickConnectCoordinator {
    private enum ValidationError: Error, CustomStringConvertible {
        case unreviewedTarget
        case conflictingHostKeyPin
        case changedHostKey

        var description: String {
            switch self {
            case .unreviewedTarget: "The confirmed SSH target is not part of this proposal."
            case .conflictingHostKeyPin: "The saved host key conflicts with the reviewed Quick Connect fingerprint."
            case .changedHostKey: "The SSH host key changed and cannot be trusted through Quick Connect."
            }
        }
    }

    private struct PendingConfirmation {
        var proposal: QuickConnectProposal
        var deviceName: String
        var selection: HostSelectionLease
        var operationSnapshot: HostOperationSnapshot
    }

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
    private var pendingConfirmation: PendingConfirmation?

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
        pendingConfirmation = nil
        currentLease = nil
        terminalRouteIntent = nil
        stage = .reviewing
        let credential = CredentialBox(choice)
        let operationSnapshot = model.currentHostOperationSnapshot
        let storeSnapshot = model.hostStore
        task = Task { [weak self] in
            await self?.run(proposal: proposal, target: reviewedTarget, username: reviewedUsername, credential: credential, deviceName: deviceName, operationSnapshot: operationSnapshot, storeSnapshot: storeSnapshot, generation: generation)
        }
    }

    public func resumeAfterHostTrust() {
        guard case .awaitingHostTrust = stage, let pending = pendingConfirmation else { return }
        let generation = generation
        task?.cancel()
        task = Task { [weak self] in
            await self?.resume(pending: pending, generation: generation)
        }
    }

    /// Retries only pairing for the currently owned SSH lease.
    ///
    /// Credential installation, host persistence, host selection, and Terminal connection are deliberately absent.
    public func retryPairing() {
        guard case .failed(let point, _) = stage,
              point == .openingHostAPI || point == .pairing,
              let pending = pendingConfirmation,
              pending.proposal.pairingCode != nil,
              let lease = currentLease else { return }
        guard model.ownsConnection(lease) else {
            currentLease = nil
            terminalRouteIntent = nil
            stage = .failed(.pairing, safeFailureMessage(for: HostPairingError.staleConnection, at: .pairing))
            return
        }
        generation += 1
        let generation = generation
        task?.cancel()
        task = Task { [weak self] in
            await self?.retryPairing(pending: pending, lease: lease, generation: generation)
        }
    }

    public func cancel() {
        generation += 1
        task?.cancel()
        task = nil
        proposal = nil
        pendingConfirmation = nil
        currentLease = nil
        terminalRouteIntent = nil
        stage = .cancelled
    }

    private func run(proposal: QuickConnectProposal, target: QuickConnectTarget, username: String, credential: CredentialBox, deviceName: String, operationSnapshot: HostOperationSnapshot, storeSnapshot: HostStore, generation: Int) async {
        do {
            try ensureCurrent(generation, proposal: proposal)
            try ensureNotExpired(proposal)
            try validateReview(proposal: proposal, target: target, username: username, store: storeSnapshot)
            stage = .installingCredential
            let auth = try await installCredential(credential.take())
            try ensureCurrent(generation, proposal: proposal)
            guard model.ownsHostOperation(operationSnapshot), model.hostStore == storeSnapshot else { throw HostPairingError.staleConnection }
            try ensureNotExpired(proposal)
            await connectAndPair(proposal: proposal, target: target, username: username, auth: auth, deviceName: deviceName, generation: generation)
        } catch is CancellationError {
            if self.generation == generation { stage = .cancelled }
        } catch {
            if self.generation == generation {
                let point = failurePoint
                stage = .failed(point, safeFailureMessage(for: error, at: point))
            }
        }
    }

    private func connectAndPair(proposal: QuickConnectProposal, target: QuickConnectTarget, username: String, auth: AuthMethod, deviceName: String, generation: Int) async {
        do {
            try ensureCurrent(generation, proposal: proposal)
            stage = .savingHost
            let host = makeHost(proposal: proposal, target: target, username: username, auth: auth)
            model.hostStore.upsert(host)
            persistHostStore(model.hostStore)
            guard let selection = await model.selectHost(host.id), model.ownsSelection(selection) else {
                throw HostPairingError.staleConnection
            }
            try ensureCurrent(generation, proposal: proposal)
            let pending = PendingConfirmation(
                proposal: proposal,
                deviceName: deviceName,
                selection: selection,
                operationSnapshot: model.currentHostOperationSnapshot)
            pendingConfirmation = pending
            try await connectOwnedHost(pending: pending, generation: generation)
        } catch is CancellationError {
            if self.generation == generation { stage = .cancelled }
        } catch {
            recordFailure(error, generation: generation)
        }
    }

    private func resume(pending: PendingConfirmation, generation: Int) async {
        do {
            try ensureCurrent(generation, proposal: pending.proposal)
            if let lease = currentLease, model.ownsConnection(lease) {
                try await finishPairing(pending: pending, lease: lease, generation: generation)
                return
            }
            guard model.ownsSelection(pending.selection), model.ownsHostOperation(pending.operationSnapshot) else {
                throw HostPairingError.staleConnection
            }
            try await connectOwnedHost(pending: pending, generation: generation)
        } catch is CancellationError {
            if self.generation == generation { stage = .cancelled }
        } catch {
            recordFailure(error, generation: generation)
        }
    }

    private func retryPairing(pending: PendingConfirmation, lease: HostConnectionLease, generation: Int) async {
        do {
            try ensureCurrent(generation, proposal: pending.proposal)
            guard model.ownsConnection(lease) else { throw HostPairingError.staleConnection }
            stage = .openingHostAPI
            try await model.prepareHostPairing(lease: lease)
            try ensureCurrent(generation, proposal: pending.proposal)
            guard model.ownsConnection(lease) else { throw HostPairingError.staleConnection }
            try await finishPairing(pending: pending, lease: lease, generation: generation)
        } catch is CancellationError {
            if self.generation == generation { stage = .cancelled }
        } catch {
            recordFailure(error, generation: generation)
        }
    }

    private func connectOwnedHost(pending: PendingConfirmation, generation: Int) async throws {
        try ensureCurrent(generation, proposal: pending.proposal)
        guard model.ownsSelection(pending.selection) else { throw HostPairingError.staleConnection }
        stage = .connectingSSH
        let lease = await model.connectSelectedHost(purpose: pending.proposal.pairingCode == nil ? .normal : .awaitingPairing)
        var updatedPending = pending
        updatedPending.operationSnapshot = model.currentHostOperationSnapshot
        pendingConfirmation = updatedPending

        if let prompt = model.hostKeyPrompt {
            guard prompt.allowsTrust else { throw ValidationError.changedHostKey }
            if let lease {
                guard model.ownsConnection(lease) else { throw HostPairingError.staleConnection }
                currentLease = lease
                terminalRouteIntent = lease
            }
            stage = .awaitingHostTrust
            return
        }

        guard let lease, model.ownsConnection(lease) else { throw HostPairingError.staleConnection }
        currentLease = lease
        terminalRouteIntent = lease
        try await finishPairing(pending: updatedPending, lease: lease, generation: generation)
    }

    private func finishPairing(pending: PendingConfirmation, lease: HostConnectionLease, generation: Int) async throws {
        try ensureCurrent(generation, proposal: pending.proposal)
        guard model.ownsConnection(lease) else { throw HostPairingError.staleConnection }
        stage = .openingHostAPI
        if let code = pending.proposal.pairingCode {
            stage = .pairing
            try ensureNotExpired(pending.proposal)
            _ = try await model.pairHost(pairingCode: code, deviceName: pending.deviceName, lease: lease)
        }
        try ensureCurrent(generation, proposal: pending.proposal)
        guard model.ownsConnection(lease) else { throw HostPairingError.staleConnection }
        stage = .loadingWorkspace
        try ensureCurrent(generation, proposal: pending.proposal)
        guard model.ownsConnection(lease) else { throw HostPairingError.staleConnection }
        stage = .connected
        pendingConfirmation = nil
    }

    private func recordFailure(_ error: any Error, generation: Int) {
        guard self.generation == generation else { return }
        if let lease = currentLease, model.ownsConnection(lease) {
            terminalRouteIntent = lease
        } else {
            currentLease = nil
            terminalRouteIntent = nil
        }
        let point = failurePoint
        stage = .failed(point, safeFailureMessage(for: error, at: point))
    }

    private func installCredential(_ choice: QuickConnectCredentialChoice) async throws -> AuthMethod {
        try await installer.install(choice)
    }

    private var failurePoint: FailurePoint {
        switch stage {
        case .installingCredential: .installingCredential
        case .savingHost: .savingHost
        case .connectingSSH, .awaitingHostTrust: .connectingSSH
        case .openingHostAPI: .openingHostAPI
        case .pairing: .pairing
        case .loadingWorkspace, .connected: .loadingWorkspace
        default: .reviewing
        }
    }

    private func safeFailureMessage(for error: any Error, at point: FailurePoint) -> String {
        if let validationError = error as? ValidationError {
            switch validationError {
            case .unreviewedTarget: "The confirmed SSH target is not part of this proposal."
            case .conflictingHostKeyPin: "The saved host key conflicts with the reviewed Quick Connect fingerprint."
            case .changedHostKey: "The SSH host key changed and cannot be trusted through Quick Connect."
            }
        } else if let credentialError = error as? QuickConnectCredentialInstallError {
            switch credentialError {
            case .invalidLabel: "Enter a valid credential label and try again."
            case .emptySecret: "Enter the SSH credential and try again."
            case .storageFailed: "The SSH credential could not be saved. Check Keychain access and try again."
            }
        } else if let linkError = error as? QuickConnectLinkError, linkError == .expired {
            "This Quick Connect link has expired. Scan a new code and try again."
        } else if let pairingError = error as? HostPairingError {
            switch pairingError {
            case .unavailable: "Host pairing is unavailable. Check the host and try again."
            case .staleConnection: "The host connection changed before Quick Connect finished. Start Quick Connect again."
            }
        } else {
            switch point {
            case .reviewing: "The Quick Connect proposal could not be validated. Review the details and try again."
            case .installingCredential: "The SSH credential could not be installed. Try again."
            case .savingHost: "The SSH host could not be saved. Try again."
            case .connectingSSH: "Could not connect to the SSH host. Check the address and network, then try again."
            case .openingHostAPI: "The host API could not be opened. Check the host connection and try again."
            case .pairing: "The host could not be paired. Check the pairing code and try again."
            case .loadingWorkspace: "The workspace could not be loaded. Try reconnecting."
            }
        }
    }

    private func makeHost(proposal: QuickConnectProposal, target: QuickConnectTarget, username: String, auth: AuthMethod) -> HostRecord {
        let pins = proposal.hostKeys.map { KnownHostEntry(keyType: $0.algorithm, fingerprint: $0.fingerprint, addedAt: now()) }
        if var existing = matchingHost(target: target, username: username, in: model.hostStore) {
            existing.hostname = target.hostname
            existing.port = target.port
            existing.username = username
            existing.hostAPIPort = proposal.hostAPIPort.flatMap(UInt16.init(exactly:))
            existing.auth = auth
            if existing.knownHosts.isEmpty, !pins.isEmpty { existing.knownHosts = pins }
            return existing
        }
        return HostRecord(nickname: proposal.nickname, hostname: target.hostname, port: target.port, hostAPIPort: proposal.hostAPIPort.flatMap(UInt16.init(exactly:)), username: username, auth: auth, knownHosts: pins)
    }

    private func validateReview(proposal: QuickConnectProposal, target: QuickConnectTarget, username: String, store: HostStore) throws {
        guard proposal.targets.contains(target) else { throw ValidationError.unreviewedTarget }
        guard let existing = matchingHost(target: target, username: username, in: store), !existing.knownHosts.isEmpty else { return }
        let savedPins = Dictionary(grouping: existing.knownHosts, by: { $0.keyType.lowercased() })
        let conflicts = proposal.hostKeys.contains { proposed in
            guard let pins = savedPins[proposed.algorithm.lowercased()] else { return false }
            return !pins.contains(where: { $0.fingerprint == proposed.fingerprint })
        }
        if conflicts { throw ValidationError.conflictingHostKeyPin }
    }

    private func matchingHost(target: QuickConnectTarget, username: String, in store: HostStore) -> HostRecord? {
        let targetKey = QuickConnectLinkCodec.canonicalTargetKey(target.hostname)
        return store.hosts.first {
            $0.username == username
                && $0.port == target.port
                && QuickConnectLinkCodec.canonicalTargetKey($0.hostname) == targetKey
        }
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
