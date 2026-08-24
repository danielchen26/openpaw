import Foundation
import OpenPawTerminalCore
import Testing

@testable import OpenPawUI

@Suite("Quick Connect coordinator failure quality")
struct QuickConnectCoordinatorQualityTests {
    @MainActor
    @Test("credential installer failures stay attributed to credential installation")
    func installerFailureUsesInstallingCredentialStage() async {
        let coordinator = makeCoordinator(
            installer: QualityFailingInstaller(error: QuickConnectCredentialInstallError.storageFailed))

        coordinator.begin(proposal())
        coordinator.confirm(.password(label: "Studio login", secret: "do-not-print-me"), username: "daniel")
        await waitForFailure(coordinator)

        #expect(coordinator.stage == .failed(
            .installingCredential,
            "The SSH credential could not be saved. Check Keychain access and try again."))
    }

    @MainActor
    @Test("arbitrary underlying error text is never exposed")
    func arbitraryErrorTextIsRedacted() async {
        let secret = "credential=super-secret-value"
        let coordinator = makeCoordinator(
            installer: QualityFailingInstaller(error: SecretBearingQualityError(message: secret)))

        coordinator.begin(proposal())
        coordinator.confirm(.password(label: "Studio login", secret: "another-secret"), username: "daniel")
        await waitForFailure(coordinator)

        guard case .failed(.installingCredential, let message) = coordinator.stage else {
            Issue.record("expected installingCredential failure, got \(coordinator.stage)")
            return
        }
        #expect(message == "The SSH credential could not be installed. Try again.")
        #expect(message.contains(secret) == false)
    }

    @MainActor
    private func makeCoordinator(installer: any QuickConnectCredentialInstalling) -> QuickConnectCoordinator {
        QuickConnectCoordinator(
            model: OpenPawModel(hostStore: HostStore(), terminal: QualityTerminal()),
            installer: installer,
            now: { Date(timeIntervalSince1970: 1_800_000_000) })
    }

    private func proposal() -> QuickConnectProposal {
        .from(
            candidate: AddDeviceCandidate(
                id: "quality-node",
                nickname: "Studio",
                hostname: "studio.local",
                dnsName: nil,
                tailscaleIPs: [],
                os: nil,
                online: true),
            now: Date(timeIntervalSince1970: 1_800_000_000))
    }

    @MainActor
    private func waitForFailure(_ coordinator: QuickConnectCoordinator) async {
        for _ in 0..<1_000 {
            if case .failed = coordinator.stage { return }
            await Task.yield()
        }
        Issue.record("coordinator did not fail, final stage: \(coordinator.stage)")
    }
}

private struct QualityFailingInstaller: QuickConnectCredentialInstalling {
    let error: any Error & Sendable

    func install(_ choice: QuickConnectCredentialChoice) async throws -> AuthMethod {
        _ = choice
        throw error
    }
}

private struct SecretBearingQualityError: Error, Sendable, CustomStringConvertible {
    let message: String
    var description: String { message }
}

private final class QualityTerminal: TerminalBackend, @unchecked Sendable {
    let stateStream = AsyncStream<ConnectionState> { $0.finish() }
    let outputStream = AsyncStream<Data> { $0.finish() }

    func connect(host: HostRecord) async throws {}
    func disconnect() async {}
    func send(text: String) async throws {}
    func send(chord: KeyChord, applicationCursorKeys: Bool) async throws {}
    func resize(columns: Int, rows: Int) async throws {}
    func run(command: String) async throws -> String { "" }
}
