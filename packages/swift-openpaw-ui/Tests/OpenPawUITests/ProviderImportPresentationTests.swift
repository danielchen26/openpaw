import Foundation
import XCTest
import OpenPawProtocol
@testable import OpenPawUI

final class ProviderImportPresentationTests: XCTestCase {
    func testRailStationsNameRemoteCatalogHostAndLocalWorkspace() throws {
        let p = ProviderImportPresentation(hostName: "Scenario host", provider: .github, canList: .available, canAuthorize: .available, canImport: .available, repos: [try repo()])
        XCTAssertEqual(p.rail.stations.map(\.title), ["Remote catalog", "Selected host", "Local workspace"])
        XCTAssertTrue(p.rail.stations[0].subtitle.contains("GitHub"))
        XCTAssertTrue(p.rail.stations[1].subtitle.contains("Scenario host"))
        XCTAssertTrue(p.rail.stations[2].subtitle.contains("OpenPaw workspace"))
    }

    func testImportPhaseCopyIsExactForEveryContractState() throws {
        let cases: [(RepoImportState, String, String?)] = [
            (.queued, "Queued on Scenario host.", "Cancel host import"),
            (.authorizing, "Host is preparing provider credentials.", "Cancel host import"),
            (.cloning, "Host is cloning the repository into its workspace store.", "Cancel host import"),
            (.validating, "Host is validating the cloned workspace.", "Cancel host import"),
            (.registering, "Host is registering the workspace with OpenPaw.", "Cancel host import"),
            (.completed, "Imported on Scenario host.", "Open workspace"),
            (.failed, "Host import failed.", "Start again"),
            (.cancelled, "Import cancelled on Scenario host.", "Start again"),
            (.recoveryRequired, "Host recovery required before this workspace is safe to open.", nil),
            (.unknown("paused"), "Host reported an unknown import state: paused.", "Check host import")
        ]
        for (state, title, action) in cases {
            let progress = try RepoImportProgress(id: "import", state: state, repoName: "openpaw", destinationName: "openpaw", percent: state == .cloning ? 40 : nil)
            let mapped = ProviderImportPresentation.progress(progress, hostName: "Scenario host")
            XCTAssertEqual(mapped.title, title)
            XCTAssertEqual(mapped.action, action)
        }
    }

    func testOwnershipCopyNeverClaimsPhoneOrCloudClone() throws {
        let auth = ProviderAuthorizationStart(authorizationID: "auth", verificationURL: URL(string: "https://example.com/device")!, userCode: "ABCD-1234", expiresAt: Date(), intervalSeconds: 1)
        let p = ProviderImportPresentation(hostName: "Scenario host", provider: .huggingFace, canList: .available, canAuthorize: .available, canImport: .available, authorizationState: .awaitingUser(auth))
        let text = String(describing: p).lowercased()
        for banned in ["cloud", "iphone clones", "we clone", "/users/", "access_token", "refresh_token", "device_code"] { XCTAssertFalse(text.contains(banned), banned) }
    }

    func testCapabilityDenialProducesRepairCopyAndNoImportAction() {
        let p = ProviderImportPresentation(hostName: "Scenario host", provider: .github, canList: .available, canAuthorize: .available, canImport: .denied)
        XCTAssertFalse(p.capability.allowsImport)
        XCTAssertTrue(p.capability.detail.contains("repos.manage"))
        XCTAssertNil(p.catalog?.primaryAction)
    }

    func testAccessibilityLabelsAreSanitized() throws {
        let progress = try RepoImportProgress(id: "import", state: .cloning, repoName: "openpaw", destinationName: "openpaw", message: "/Users/me https://token@example.com/repo.git access_token raw stderr")
        let mapped = ProviderImportPresentation.progress(progress, hostName: "Scenario host")
        let all = mapped.detail + mapped.accessibilityValue
        for banned in ["/Users/me", "token@example.com", "access_token", "raw stderr"] { XCTAssertFalse(all.contains(banned), banned) }
    }

    private func repo() throws -> ProviderRepo { try ProviderRepo(id: "gh-openpaw", provider: .github, owner: "openpaw", name: "openpaw", displayName: "openpaw/openpaw", isPrivate: false) }
}
