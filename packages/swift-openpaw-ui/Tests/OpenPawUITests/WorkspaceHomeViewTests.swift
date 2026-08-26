import Foundation
import OpenPawProtocol
import OpenPawUI
import Testing

@Suite("Workspace Home simplification")
struct WorkspaceHomeViewTests {
    @Test("Home uses Tailscale instead of Tailnet in user-visible discovery copy")
    func tailscaleDiscoveryCopy() {
        #expect(WorkspaceHomeCopy.discoveryEyebrow == "tailscale / local identity / candidates")
        #expect(WorkspaceHomeCopy.discoveryTitle == "Tailscale discovery")
        #expect(!WorkspaceHomeCopy.userVisibleCopy.joined(separator: " ").localizedCaseInsensitiveContains("tailnet"))
        for source in [
            HomeTailnetBootstrapState.Source.none,
            .localIdentity,
            .savedAdministrator,
            .pairedHost,
            .merged,
        ] {
            #expect(!source.displayName.localizedCaseInsensitiveContains("tailnet"))
        }
    }

    @Test("Online candidates invite a direct connection while offline candidates remain status-only")
    func candidateConnectionSemantics() {
        let online = AddDeviceCandidate(
            id: "online",
            nickname: "Build Mac",
            hostname: "build.example.ts.net",
            online: true)
        let offline = AddDeviceCandidate(
            id: "offline",
            nickname: "Office Mac",
            hostname: "office.example.ts.net",
            online: false)

        #expect(WorkspaceHomeCandidatePresentation.actionTitle(for: online) == "Connect directly")
        #expect(WorkspaceHomeCandidatePresentation.actionTitle(for: offline) == "Offline")
        #expect(WorkspaceHomeCandidatePresentation.accessibilityLabel(for: online).contains("Connect directly with Quick Connect"))
    }

    @Test("Selecting an online candidate still opens Quick Connect")
    func onlineCandidateKeepsQuickConnect() {
        let candidate = AddDeviceCandidate(
            id: "online",
            nickname: "Build Mac",
            hostname: "build.example.ts.net",
            online: true)
        var received: QuickConnectProposal?

        WorkspaceHomeCandidateSelection.openQuickConnect(candidate) { received = $0 }

        #expect(received?.id == candidate.id)
        #expect(received?.online == true)
    }

    @Test("Populated Home leads with machines instead of a duplicate network summary")
    func populatedHomeOmitsDuplicateNetworkSummary() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let packageRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: packageRoot.appendingPathComponent("Sources/OpenPawUI/Screens/WorkspaceHomeView.swift"),
            encoding: .utf8)
        let populatedBody = try #require(
            source.split(separator: "private var populatedHome", maxSplits: 1).last?
                .split(separator: "private var tailnetBootstrapPanel", maxSplits: 1).first)

        #expect(!populatedBody.contains("networkSummary"))
        #expect(populatedBody.contains("tailnetBootstrapPanel"))
        #expect(populatedBody.contains("deviceGrid"))
    }

    @Test("Home source and snapshot catalog omit remote catalog transfer")
    func remoteCatalogTransferIsAbsent() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let packageRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let homeSource = try String(contentsOf: packageRoot.appendingPathComponent("Sources/OpenPawUI/Screens/WorkspaceHomeView.swift"), encoding: .utf8)
        let catalogSource = try String(contentsOf: packageRoot.appendingPathComponent("../../tools/openpaw-snapshot/Sources/openpaw-snapshot/ScreenCatalog.swift").standardizedFileURL, encoding: .utf8)

        #expect(!homeSource.localizedCaseInsensitiveContains("remote catalog transfer"))
        #expect(catalogSource.contains("WorkspaceHomeView-online-candidate"))
    }
}
