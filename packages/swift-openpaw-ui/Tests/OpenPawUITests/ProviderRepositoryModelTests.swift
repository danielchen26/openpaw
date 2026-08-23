import Foundation
import OpenPawProtocol
import OpenPawTerminalCore
import XCTest

@testable import OpenPawUI

@MainActor
final class ProviderRepositoryModelTests: XCTestCase {
    func testLateProviderAuthorizationFromOldHostIsSuppressedAfterHostSwitch() async throws {
        let hostA = HostRecord(nickname: "A", hostname: "a", username: "u", auth: .agentForwarding)
        let hostB = HostRecord(nickname: "B", hostname: "b", username: "u", auth: .agentForwarding)
        let backend = GatedProviderBackend()
        let model = readyModel(hosts: [hostA, hostB], backend: backend)

        backend.gateBegin = true
        let task = Task { await model.beginProviderAuthorization(.github) }
        await backend.waitForBeginCall()
        model.selectedHostID = hostB.id
        await backend.finishBegin(.success(makeAuthStart("auth-a")))
        await task.value

        XCTAssertEqual(model.providerAuthorizationState, .idle)
        XCTAssertNil(model.selectedProvider)
    }

    func testSameHostReconnectLeaseMismatchSuppressesStaleErrors() async throws {
        let host = HostRecord(nickname: "A", hostname: "a", username: "u", auth: .agentForwarding)
        let backend = GatedProviderBackend()
        let model = readyModel(hosts: [host], backend: backend)

        backend.gateProviders = true
        let task = Task { await model.refreshProviders() }
        await backend.waitForProvidersCall()
        model.connection = .disconnected(reason: "drop")
        model.connection = .connected(.ssh)
        await backend.finishProviders(.failure(HostClientError.server(status: 500, body: "late")))
        await task.value

        XCTAssertNil(model.lastError)
        XCTAssertEqual(model.providerListState, .loading)
    }

    func testPagedProviderReposDedupesPreservingOrderAndExactCursor() async throws {
        let backend = GatedProviderBackend()
        backend.repoPages = [
            ProviderRepoPage(repos: [try repo("1"), try repo("2")], nextCursor: "next-opaque"),
            ProviderRepoPage(repos: [try repo("2"), try repo("3")], nextCursor: nil)
        ]
        let model = readyModel(backend: backend)
        model.selectedProvider = .github

        await model.loadProviderRepos(reset: true)
        await model.loadProviderRepos()

        XCTAssertEqual(backend.providerRepoCalls.map(\.cursor), [nil, "next-opaque"])
        XCTAssertEqual(model.providerRepoPages.repos.map(\.id), ["1", "2", "3"])
        XCTAssertNil(model.providerRepoPages.nextCursor)
    }

    func testDeniedCapabilityBlocksBeforeBackendCallWithRepairError() async throws {
        let backend = GatedProviderBackend(deniedCapabilities: ["repos.manage"])
        let model = readyModel(backend: backend)

        await model.startRepoImport(provider: .github, repoID: "1")

        XCTAssertTrue(backend.importCalls.isEmpty)
        XCTAssertEqual(model.lastError?.title, "This device cannot do that")
        XCTAssertTrue(model.lastError?.detail.contains("repos.manage") == true)
    }

    func testImportProgressPersistsThroughUnrelatedUIStateAndTerminalStates() async throws {
        let backend = GatedProviderBackend()
        backend.importProgress = try RepoImportProgress(id: "imp", state: .cloning, repoName: "repo", destinationName: "repo", percent: 40)
        let model = readyModel(backend: backend)

        await model.startRepoImport(provider: .github, repoID: "1")
        model.selectedSessionID = "unrelated"
        XCTAssertEqual(model.repoImportState, .progress(try RepoImportProgress(id: "imp", state: .cloning, repoName: "repo", destinationName: "repo", percent: 40)))

        for state in [RepoImportState.completed, .failed, .cancelled, .recoveryRequired] {
            backend.pollProgress = try RepoImportProgress(id: "imp", state: state, repoName: "repo", destinationName: "repo")
            await model.pollRepoImport("imp")
            XCTAssertEqual(model.repoImportState, .terminal(try RepoImportProgress(id: "imp", state: state, repoName: "repo", destinationName: "repo")))
        }
    }

    func testHostSwitchClearsProviderAndImportIDs() async throws {
        let hostA = HostRecord(nickname: "A", hostname: "a", username: "u", auth: .agentForwarding)
        let hostB = HostRecord(nickname: "B", hostname: "b", username: "u", auth: .agentForwarding)
        let backend = GatedProviderBackend()
        backend.importProgress = try RepoImportProgress(id: "imp", state: .cloning, repoName: "repo", destinationName: "repo")
        let model = readyModel(hosts: [hostA, hostB], backend: backend)
        model.selectedProvider = .github
        await model.startRepoImport(provider: .github, repoID: "1")

        model.selectedHostID = hostB.id

        XCTAssertNil(model.selectedProvider)
        XCTAssertEqual(model.repoImportState, .idle)
        XCTAssertEqual(model.providerAuthorizationState, .idle)
    }

    func testBackendDeleteCalledWithExactAuthorizationAndImportIDs() async throws {
        let backend = GatedProviderBackend()
        let model = readyModel(backend: backend)
        model.selectedProvider = .github
        await model.beginProviderAuthorization(.github)
        await model.cancelProviderAuthorization()

        backend.importProgress = try RepoImportProgress(id: "import-456", state: .cloning, repoName: "repo", destinationName: "repo")
        await model.startRepoImport(provider: .github, repoID: "1")
        await model.cancelRepoImport()

        XCTAssertEqual(backend.cancelAuthorizationCalls, [.init(provider: .github, authorizationID: "auth-start")])
        XCTAssertEqual(backend.cancelImportCalls, ["import-456"])
    }

    func testNonCapabilityBackendFailsClosedAndExposesUnavailableCapabilities() async throws {
        let model = OpenPawModel(hostStore: HostStore(hosts: [HostRecord(nickname: "A", hostname: "a", username: "u", auth: .agentForwarding)]), backend: NonCapabilityBackend(), terminal: nil)
        model.connection = .connected(.ssh)

        await model.refreshProviders()

        XCTAssertEqual(model.canListProviders, .unavailable)
        XCTAssertEqual(model.canAuthorizeProviders, .unavailable)
        XCTAssertEqual(model.canImportRepos, .unavailable)
        XCTAssertEqual(model.lastError?.title, "This device cannot do that")
    }

    func testProviderSwitchABASuppressesOldRepoPageCompletion() async throws {
        let backend = GatedProviderBackend()
        backend.gateRepoPages = true
        let model = readyModel(backend: backend)
        model.selectedProvider = .github
        let task = Task { await model.loadProviderRepos(reset: true) }
        await backend.waitForRepoPageCall()
        model.selectedProvider = .huggingFace
        model.selectedProvider = .github
        await backend.finishRepoPage(.success(ProviderRepoPage(repos: [try repo("old")], nextCursor: "stale")))
        await task.value

        XCTAssertTrue(model.providerRepoPages.repos.isEmpty)
        XCTAssertNil(model.providerRepoPages.nextCursor)
    }

    func testAuthorizationAutoPollingUsesCapturedProviderAndCanBeCancelled() async throws {
        let backend = GatedProviderBackend()
        backend.startResponse = ProviderAuthorizationStart(authorizationID: "auth-hf", verificationURL: URL(string: "https://example.com/device")!, userCode: "ABCD", expiresAt: Date(), intervalSeconds: 0)
        backend.authorizationStatuses = [
            ProviderAuthorizationStatus(authorizationID: "auth-hf", state: .slowDown, provider: .huggingFace),
            ProviderAuthorizationStatus(authorizationID: "auth-hf", state: .authorized, provider: .huggingFace)
        ]
        let model = readyModel(backend: backend)

        await model.beginProviderAuthorization(.huggingFace)
        model.selectedProvider = .github
        try await Task.sleep(nanoseconds: 20_000_000)
        await model.cancelProviderAuthorization()

        XCTAssertTrue(backend.authorizationStatusCalls.allSatisfy { $0.provider == .huggingFace && $0.authorizationID == "auth-hf" })
        XCTAssertEqual(backend.cancelAuthorizationCalls.last, .init(provider: .huggingFace, authorizationID: "auth-hf"))
    }

    func testCompletedImportSelectsDestinationAndSanitizedErrorsHideRawBodies() async throws {
        let backend = GatedProviderBackend()
        let model = readyModel(backend: backend)
        backend.importProgress = try RepoImportProgress(id: "imp", state: .completed, repoName: "safe", destinationName: "root-safe")
        await model.startRepoImport(provider: .github, repoID: "1")
        XCTAssertEqual(model.selectedRepo, "root-safe")

        backend.importError = HostClientError.server(status: 500, body: "https://token.example/private /Users/me/secret raw_provider_body")
        await model.startRepoImport(provider: .github, repoID: "2")
        XCTAssertFalse(model.lastError?.detail.contains("token.example") == true)
        XCTAssertFalse(model.lastError?.detail.contains("/Users/me") == true)
        XCTAssertFalse(model.lastError?.detail.contains("raw_provider_body") == true)
    }

    func testRevokeClearsProviderWorkflowState() async throws {
        let backend = GatedProviderBackend()
        let model = readyModel(backend: backend)
        model.selectedProvider = .github
        backend.repoPages = [ProviderRepoPage(repos: [try repo("1")], nextCursor: "next")]
        await model.loadProviderRepos(reset: true)
        await model.beginProviderAuthorization(.github)

        await model.revokeProvider(.github)

        XCTAssertNil(model.selectedProvider)
        XCTAssertEqual(model.providerAuthorizationState, .idle)
        XCTAssertTrue(model.providerRepoPages.repos.isEmpty)
        XCTAssertNil(model.providerRepoPages.nextCursor)
    }

    func testImportIDSurvivesReconnectAndCanResumePolling() async throws {
        let backend = GatedProviderBackend()
        let model = readyModel(backend: backend)
        backend.importProgress = try RepoImportProgress(id: "imp", state: .cloning, repoName: "repo", destinationName: "repo")
        await model.startRepoImport(provider: .github, repoID: "1")
        model.connection = .disconnected(reason: "drop")
        model.connection = .connected(.ssh)
        backend.pollProgress = try RepoImportProgress(id: "imp", state: .completed, repoName: "repo", destinationName: "repo")

        model.resumeRepoImportPollingAfterReconnect()
        await model.pollRepoImport()

        XCTAssertEqual(model.selectedRepo, "repo")
        XCTAssertEqual(model.repoImportState, .terminal(try RepoImportProgress(id: "imp", state: .completed, repoName: "repo", destinationName: "repo")))
    }
}

@MainActor
private func readyModel(hosts: [HostRecord] = [HostRecord(nickname: "A", hostname: "a", username: "u", auth: .agentForwarding)], backend: GatedProviderBackend) -> OpenPawModel {
    let store = HostStore(hosts: hosts)
    let model = OpenPawModel(hostStore: store, backend: backend, terminal: nil)
    model.connection = .connected(.ssh)
    return model
}

private func makeAuthStart(_ id: String) -> ProviderAuthorizationStart {
    ProviderAuthorizationStart(authorizationID: id, verificationURL: URL(string: "https://example.com/device")!, userCode: "ABCD", expiresAt: Date(timeIntervalSince1970: 100), intervalSeconds: 5)
}

private func repo(_ id: String) throws -> ProviderRepo {
    try ProviderRepo(id: id, provider: .github, owner: "owner", name: "repo\(id)", displayName: "owner/repo\(id)", isPrivate: false)
}

private struct AuthCancelCall: Equatable { var provider: ProviderID; var authorizationID: String }
private struct ProviderRepoCall: Equatable { var provider: ProviderID; var cursor: String? }
private struct AuthStatusCall: Equatable { var provider: ProviderID; var authorizationID: String }

private final class GatedProviderBackend: OpenPawBackend, PairedHostCapabilityProviding, @unchecked Sendable {
    var deniedCapabilities: Set<String>
    var repoPages: [ProviderRepoPage] = []
    var providerRepoCalls: [ProviderRepoCall] = []
    var importCalls: [RepoImportRequest] = []
    var cancelAuthorizationCalls: [AuthCancelCall] = []
    var cancelImportCalls: [String] = []
    var importProgress: RepoImportProgress?
    var pollProgress: RepoImportProgress?
    var importError: (any Error)?
    var startResponse = makeAuthStart("auth-start")
    var authorizationStatuses: [ProviderAuthorizationStatus] = []
    var authorizationStatusCalls: [AuthStatusCall] = []
    var gateBegin = false
    var gateProviders = false
    var gateRepoPages = false
    private var beginContinuation: CheckedContinuation<Result<ProviderAuthorizationStart, Error>, Never>?
    private var providersContinuation: CheckedContinuation<Result<[ProviderStatus], Error>, Never>?
    private var repoPageContinuation: CheckedContinuation<Result<ProviderRepoPage, Error>, Never>?
    private var beginCalledContinuation: CheckedContinuation<Void, Never>?
    private var providersCalledContinuation: CheckedContinuation<Void, Never>?
    private var repoPageCalledContinuation: CheckedContinuation<Void, Never>?

    init(deniedCapabilities: Set<String> = []) { self.deniedCapabilities = deniedCapabilities }

    func pairedCapabilityStatus(_ capability: String, hostID: HostRecord.ID) -> PairedHostCapabilityStatus {
        deniedCapabilities.contains(capability) ? .denied : .granted
    }

    func waitForBeginCall() async { await withCheckedContinuation { beginCalledContinuation = $0 } }
    func finishBegin(_ result: Result<ProviderAuthorizationStart, Error>) async { beginContinuation?.resume(returning: result); beginContinuation = nil }
    func waitForProvidersCall() async { await withCheckedContinuation { providersCalledContinuation = $0 } }
    func finishProviders(_ result: Result<[ProviderStatus], Error>) async { providersContinuation?.resume(returning: result); providersContinuation = nil }
    func waitForRepoPageCall() async { await withCheckedContinuation { repoPageCalledContinuation = $0 } }
    func finishRepoPage(_ result: Result<ProviderRepoPage, Error>) async { repoPageContinuation?.resume(returning: result); repoPageContinuation = nil }

    func providers() async throws -> [ProviderStatus] {
        providersCalledContinuation?.resume(); providersCalledContinuation = nil
        if !gateProviders { return [] }
        return try await withCheckedContinuation { providersContinuation = $0 }.get()
    }

    func beginProviderAuthorization(_ provider: ProviderID) async throws -> ProviderAuthorizationStart {
        beginCalledContinuation?.resume(); beginCalledContinuation = nil
        if !gateBegin { return startResponse }
        return try await withCheckedContinuation { beginContinuation = $0 }.get()
    }

    func providerAuthorizationStatus(provider: ProviderID, authorizationID: String) async throws -> ProviderAuthorizationStatus {
        authorizationStatusCalls.append(.init(provider: provider, authorizationID: authorizationID))
        if !authorizationStatuses.isEmpty { return authorizationStatuses.removeFirst() }
        return ProviderAuthorizationStatus(authorizationID: authorizationID, state: .authorized, provider: provider)
    }
    func cancelProviderAuthorization(provider: ProviderID, authorizationID: String) async throws -> ProviderAuthorizationStatus { cancelAuthorizationCalls.append(.init(provider: provider, authorizationID: authorizationID)); return ProviderAuthorizationStatus(authorizationID: authorizationID, state: .cancelled, provider: provider) }
    func revokeProvider(_ provider: ProviderID) async throws -> ProviderStatus { ProviderStatus(id: provider, displayName: "GitHub", state: .disconnected, repoListingSupported: true) }
    func providerRepos(_ provider: ProviderID, cursor: String?) async throws -> ProviderRepoPage {
        providerRepoCalls.append(.init(provider: provider, cursor: cursor))
        repoPageCalledContinuation?.resume(); repoPageCalledContinuation = nil
        if gateRepoPages { return try await withCheckedContinuation { repoPageContinuation = $0 }.get() }
        return repoPages.removeFirst()
    }
    func importRepo(_ request: RepoImportRequest) async throws -> RepoImportProgress { importCalls.append(request); if let importError { throw importError }; if let importProgress { return importProgress }; return try RepoImportProgress(id: "import-456", state: .cloning, repoName: "repo", destinationName: "repo") }
    func repoImportProgress(_ importID: String) async throws -> RepoImportProgress { if let pollProgress { return pollProgress }; return try RepoImportProgress(id: importID, state: .completed, repoName: "repo", destinationName: "repo") }
    func cancelRepoImport(_ importID: String) async throws -> RepoImportProgress { cancelImportCalls.append(importID); return try RepoImportProgress(id: importID, state: .cancelled, repoName: "repo", destinationName: "repo") }
    func registerRepo(_ request: RepoRegisterRequest) async throws -> RepoImportProgress { try RepoImportProgress(id: request.rootID, state: .completed, repoName: request.rootID, destinationName: request.requestedName ?? request.rootID) }

    func health() async throws -> HealthInfo { throw TestError.unexpectedCall }
    func sessions() async throws -> [SessionSummary] { [] }
    func inbox(status: InboxStatus?) async throws -> [InboxItem] { [] }
    func resolve(item: InboxItem, action: ActionID, answer: String?, detailAcknowledged: Bool) async throws -> ResolveResult { throw TestError.unexpectedCall }
    func events(session: String?, afterSeq: UInt64?) -> AsyncThrowingStream<Event, Error> { AsyncThrowingStream { $0.finish() } }
    func repos() async throws -> [RepoSummary] { [] }
    func repoStatus(_ repo: String) async throws -> RepoStatus { throw TestError.unexpectedCall }
    func diff(repo: String, mode: DiffMode, path: String?) async throws -> Diff { throw TestError.unexpectedCall }
    func tree(repo: String, ref: String, path: String) async throws -> [TreeEntry] { throw TestError.unexpectedCall }
    func blob(repo: String, ref: String, path: String) async throws -> Blob { throw TestError.unexpectedCall }
    func search(repo: String, query: String, path: String?) async throws -> [ContentMatch] { throw TestError.unexpectedCall }
    func upload(data: Data, filename: String) async throws -> UploadResult { throw TestError.unexpectedCall }
    func previewURL(port: Int, path: String) throws -> URL { throw TestError.unexpectedCall }
    func tailscaleDevices() async throws -> TailscaleDevicesResponse { throw TestError.unexpectedCall }
    func audit(limit: Int) async throws -> [AuditEntry] { [] }
}

private final class NonCapabilityBackend: OpenPawBackend, @unchecked Sendable {
    func health() async throws -> HealthInfo { throw TestError.unexpectedCall }
    func sessions() async throws -> [SessionSummary] { [] }
    func inbox(status: InboxStatus?) async throws -> [InboxItem] { [] }
    func resolve(item: InboxItem, action: ActionID, answer: String?, detailAcknowledged: Bool) async throws -> ResolveResult { throw TestError.unexpectedCall }
    func events(session: String?, afterSeq: UInt64?) -> AsyncThrowingStream<Event, Error> { AsyncThrowingStream { $0.finish() } }
    func repos() async throws -> [RepoSummary] { [] }
    func repoStatus(_ repo: String) async throws -> RepoStatus { throw TestError.unexpectedCall }
    func diff(repo: String, mode: DiffMode, path: String?) async throws -> Diff { throw TestError.unexpectedCall }
    func tree(repo: String, ref: String, path: String) async throws -> [TreeEntry] { throw TestError.unexpectedCall }
    func blob(repo: String, ref: String, path: String) async throws -> Blob { throw TestError.unexpectedCall }
    func search(repo: String, query: String, path: String?) async throws -> [ContentMatch] { throw TestError.unexpectedCall }
    func upload(data: Data, filename: String) async throws -> UploadResult { throw TestError.unexpectedCall }
    func previewURL(port: Int, path: String) throws -> URL { throw TestError.unexpectedCall }
    func tailscaleDevices() async throws -> TailscaleDevicesResponse { throw TestError.unexpectedCall }
    func audit(limit: Int) async throws -> [AuditEntry] { [] }
}

private enum TestError: Error { case unexpectedCall }
