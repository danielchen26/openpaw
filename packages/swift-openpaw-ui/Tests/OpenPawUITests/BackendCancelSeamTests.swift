import Foundation
import OpenPawProtocol
import XCTest

@testable import OpenPawUI

final class BackendCancelSeamTests: XCTestCase {
    func testCancelProviderAuthorizationForwardsProviderAndAuthorizationID() async throws {
        let backend = RecordingCancelBackend()

        let status = try await backend.cancelProviderAuthorization(provider: .github, authorizationID: "auth-123")

        XCTAssertEqual(backend.cancelProviderAuthorizationCalls, [.init(provider: .github, authorizationID: "auth-123")])
        XCTAssertEqual(status, ProviderAuthorizationStatus(authorizationID: "auth-123", state: .cancelled, provider: .github))
    }

    func testCancelRepoImportForwardsImportID() async throws {
        let backend = RecordingCancelBackend()

        let progress = try await backend.cancelRepoImport("import-456")

        XCTAssertEqual(backend.cancelRepoImportCalls, ["import-456"])
        XCTAssertEqual(progress.id, "import-456")
        XCTAssertEqual(progress.state, .cancelled)
    }

    func testUnsupportedCancelDefaultsFailClosed() async {
        let backend: any OpenPawBackend = DefaultOnlyBackend()

        await XCTAssertThrowsHostBadRequest(try await backend.cancelProviderAuthorization(provider: .huggingFace, authorizationID: "auth-closed"))
        await XCTAssertThrowsHostBadRequest(try await backend.cancelRepoImport("import-closed"))
    }
}

private struct ProviderAuthorizationCancelCall: Equatable {
    var provider: ProviderID
    var authorizationID: String
}

private final class RecordingCancelBackend: DefaultOnlyBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedProviderAuthorizationCalls: [ProviderAuthorizationCancelCall] = []
    private var recordedRepoImportCalls: [String] = []

    var cancelProviderAuthorizationCalls: [ProviderAuthorizationCancelCall] {
        lock.withLock { recordedProviderAuthorizationCalls }
    }

    var cancelRepoImportCalls: [String] {
        lock.withLock { recordedRepoImportCalls }
    }

    func cancelProviderAuthorization(provider: ProviderID, authorizationID: String) async throws -> ProviderAuthorizationStatus {
        lock.withLock { recordedProviderAuthorizationCalls.append(.init(provider: provider, authorizationID: authorizationID)) }
        return ProviderAuthorizationStatus(authorizationID: authorizationID, state: .cancelled, provider: provider)
    }

    func cancelRepoImport(_ importID: String) async throws -> RepoImportProgress {
        lock.withLock { recordedRepoImportCalls.append(importID) }
        return try RepoImportProgress(id: importID, state: .cancelled, repoName: "repo", destinationName: "repo")
    }
}

private class DefaultOnlyBackend: OpenPawBackend, @unchecked Sendable {
    func health() async throws -> HealthInfo { throw TestError.unexpectedCall }
    func sessions() async throws -> [SessionSummary] { throw TestError.unexpectedCall }
    func inbox(status: InboxStatus?) async throws -> [InboxItem] { throw TestError.unexpectedCall }
    func resolve(item: InboxItem, action: ActionID, answer: String?, detailAcknowledged: Bool) async throws -> ResolveResult { throw TestError.unexpectedCall }
    func events(session: String?, afterSeq: UInt64?) -> AsyncThrowingStream<Event, any Error> { AsyncThrowingStream { $0.finish() } }
    func repos() async throws -> [RepoSummary] { throw TestError.unexpectedCall }
    func repoStatus(_ repo: String) async throws -> RepoStatus { throw TestError.unexpectedCall }
    func diff(repo: String, mode: DiffMode, path: String?) async throws -> Diff { throw TestError.unexpectedCall }
    func tree(repo: String, ref: String, path: String) async throws -> [TreeEntry] { throw TestError.unexpectedCall }
    func blob(repo: String, ref: String, path: String) async throws -> Blob { throw TestError.unexpectedCall }
    func search(repo: String, query: String, path: String?) async throws -> [ContentMatch] { throw TestError.unexpectedCall }
    func upload(data: Data, filename: String) async throws -> UploadResult { throw TestError.unexpectedCall }
    func previewURL(port: Int, path: String) throws -> URL { throw TestError.unexpectedCall }
    func tailscaleDevices() async throws -> TailscaleDevicesResponse { throw TestError.unexpectedCall }
    func audit(limit: Int) async throws -> [AuditEntry] { throw TestError.unexpectedCall }
}

private enum TestError: Error {
    case unexpectedCall
}

private func XCTAssertThrowsHostBadRequest(
    _ expression: @autoclosure () async throws -> some Sendable,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("expected HostClientError.badRequest", file: file, line: line)
    } catch HostClientError.badRequest(let message) {
        XCTAssertFalse(message.isEmpty, file: file, line: line)
    } catch {
        XCTFail("expected HostClientError.badRequest, got \(error)", file: file, line: line)
    }
}
