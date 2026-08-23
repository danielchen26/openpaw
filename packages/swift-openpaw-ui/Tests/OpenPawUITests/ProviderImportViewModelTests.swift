import Foundation
import XCTest
import OpenPawProtocol
@testable import OpenPawUI

final class ProviderImportViewModelTests: XCTestCase {
    func testRepoProvidersScenarioSeedsGithubAndHuggingFace() async throws {
        let backend = PreviewBackend(.repoProviders)
        let providers = try await backend.providers()
        XCTAssertEqual(providers.first { $0.id == .github }?.accountLabel, "octo-host")
        XCTAssertEqual(providers.first { $0.id == .github }?.state, .connected)
        XCTAssertEqual(providers.first { $0.id == .huggingFace }?.state, .reauthorizationRequired)
    }

    func testProviderReposReturnPrivateAndPublicRowsWithCursor() async throws {
        let backend = PreviewBackend(.repoProviders)
        let page = try await backend.providerRepos(.github, cursor: nil)
        XCTAssertEqual(page.nextCursor, "debug-next-gh")
        XCTAssertTrue(page.repos.contains { $0.displayName == "openpaw/openpaw" && !$0.isPrivate })
        XCTAssertTrue(page.repos.contains { $0.displayName == "acme/field-agent" && $0.isPrivate })
        let hf = try await backend.providerRepos(.huggingFace, cursor: nil)
        XCTAssertTrue(hf.repos.contains { $0.displayName == "openpaw/whisper-small" })
    }

    func testAuthorizationFixtureUsesFixedClockAndSafeURL() async throws {
        let backend = PreviewBackend(.repoProviders)
        let start = try await backend.beginProviderAuthorization(.huggingFace)
        XCTAssertEqual(start.authorizationID, "auth-hf-debug")
        XCTAssertEqual(start.verificationURL.absoluteString, "https://huggingface.co/device")
        XCTAssertEqual(start.userCode, "HF-0426")
        XCTAssertEqual(start.expiresAt, PreviewBackend.now.addingTimeInterval(600))
        XCTAssertEqual(start.intervalSeconds, 1)
        XCTAssertFalse(String(describing: start).contains("device_code"))
    }

    func testImportFixtureMovesThroughDeterministicPhases() async throws {
        let backend = PreviewBackend(.repoProviders)
        let request = try RepoImportRequest(provider: .github, repoID: "gh-openpaw", requestedName: "openpaw")
        let started = try await backend.importRepo(request)
        XCTAssertEqual(started.state, .queued)
        var states: [RepoImportState] = []
        for _ in 0..<4 { states.append(try await backend.repoImportProgress(started.id).state) }
        XCTAssertEqual(states, [.cloning, .validating, .registering, .completed])
        let cancelled = try await backend.cancelRepoImport(started.id)
        XCTAssertEqual(cancelled.state, .cancelled)
    }
}
