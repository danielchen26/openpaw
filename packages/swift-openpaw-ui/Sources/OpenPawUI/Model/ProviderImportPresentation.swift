import Foundation
import OpenPawProtocol

public struct ProviderImportPresentation: Sendable, Equatable {
    public var title: String
    public var subtitle: String
    public var rail: ProviderTransferRailPresentation
    public var capability: ProviderCapabilityPresentation
    public var providerChips: [ProviderChipPresentation]
    public var authorization: AuthorizationPresentation?
    public var catalog: ProviderCatalogPresentation?
    public var importProgress: ImportProgressPresentation?

    public init(hostName: String, provider: ProviderID?, providers: [ProviderStatus] = [], canList: ProviderCapabilityAvailability, canAuthorize: ProviderCapabilityAvailability, canImport: ProviderCapabilityAvailability, repos: [ProviderRepo] = [], importState: RepoImportOperationState = .idle, authorizationState: ProviderAuthorizationFlowState = .idle) {
        let selectedProvider = provider ?? .github
        let progress = Self.progress(from: importState, hostName: hostName)
        self.title = "Import through \(hostName)"
        self.subtitle = "OpenPaw never clones a repository on this phone. The selected host authorizes, clones, validates, and registers the workspace it owns."
        self.rail = ProviderTransferRailPresentation(hostName: hostName, providerName: selectedProvider.displayName, destinationName: progress?.destinationName ?? "OpenPaw workspace", phaseAccessibilityValue: progress?.accessibilityValue ?? "No import in progress")
        self.capability = ProviderCapabilityPresentation(canList: canList, canAuthorize: canAuthorize, canImport: canImport)
        self.providerChips = ProviderID.allCases.map { id in
            let status = providers.first { $0.id == id }
            return ProviderChipPresentation(provider: id, title: id.displayName, subtitle: status?.accountLabel ?? Self.connectionCopy(status?.state ?? .disconnected), isSelected: id == selectedProvider, connectionState: status?.state ?? .disconnected)
        }
        if case .awaitingUser(let start) = authorizationState {
            self.authorization = AuthorizationPresentation(providerName: selectedProvider.displayName, title: "Authorize \(selectedProvider.displayName) on this host", detail: "You authorize the host, not a remote OpenPaw service. Tokens stay on the selected host and are not shown to the app.", userCode: start.userCode, accessibilityLabel: "Provider user code \(Self.spokenCode(start.userCode))", verificationURL: start.verificationURL.absoluteString, primaryAction: "I've authorized, check now", cancelAction: "Cancel authorization")
        } else if case .terminal(let status) = authorizationState, status.state == .cancelled {
            self.authorization = AuthorizationPresentation(providerName: selectedProvider.displayName, title: "Authorization cancelled on this host", detail: "No token was stored for this provider.", userCode: nil, accessibilityLabel: nil, verificationURL: nil, primaryAction: "Start new host authorization", cancelAction: nil)
        }
        self.catalog = ProviderCatalogPresentation(title: "Repository catalog", detail: "Repository names come from the host's provider connection.", repos: repos.map(ProviderRepoRowPresentation.init), primaryAction: canImport == .available ? "Transfer to host workspace" : nil, emptyTitle: repos.isEmpty ? "No repositories returned by \(selectedProvider.displayName) through \(hostName)" : nil)
        self.importProgress = progress
    }

    static func progress(from state: RepoImportOperationState, hostName: String) -> ImportProgressPresentation? {
        switch state {
        case .idle: return nil
        case .starting: return ImportProgressPresentation(title: "Sending repository ID to \(hostName).", detail: "The app sends only provider and repository IDs.", action: "Cancel host import", destinationName: "OpenPaw workspace", accessibilityValue: "Import phase starting")
        case .progress(let p), .polling(let p), .terminal(let p): return progress(p, hostName: hostName)
        case .cancelling(let id): return ImportProgressPresentation(title: "Asking \(hostName) to cancel import \(id).", detail: "Cancellation is performed by the selected host.", action: nil, destinationName: "OpenPaw workspace", accessibilityValue: "Import cancellation in progress")
        case .failed(let id, let error): return ImportProgressPresentation(title: "Host import failed.", detail: sanitize(error.detail), action: id == nil ? nil : "Check host import", destinationName: "OpenPaw workspace", accessibilityValue: "Import failed")
        }
    }

    public static func progress(_ p: RepoImportProgress, hostName: String) -> ImportProgressPresentation {
        let phase: String
        let detail: String
        let action: String?
        switch p.state {
        case .queued: phase = "Queued on \(hostName)."; detail = "The host accepted the transfer request."; action = "Cancel host import"
        case .authorizing: phase = "Host is preparing provider credentials."; detail = "Tokens stay on the selected host and are not shown to the app."; action = "Cancel host import"
        case .cloning: phase = "Host is cloning the repository into its workspace store."; detail = "OpenPaw never clones a repository on this phone."; action = "Cancel host import"
        case .validating: phase = "Host is validating the cloned workspace."; detail = "The host checks the workspace before registration."; action = "Cancel host import"
        case .registering: phase = "Host is registering the workspace with OpenPaw."; detail = "The workspace will appear after host registration completes."; action = "Cancel host import"
        case .completed: phase = "Imported on \(hostName)."; detail = "OpenPaw selected \(p.destinationName)."; action = "Open workspace"
        case .failed: phase = "Host import failed."; detail = "Retry starts a new host import after confirmation."; action = "Start again"
        case .cancelled: phase = "Import cancelled on \(hostName)."; detail = "No phone-owned import work was running."; action = "Start again"
        case .recoveryRequired: phase = "Host recovery required before this workspace is safe to open."; detail = "The clone may have completed, but registration did not finish. Reconnect to the same host after recovery."; action = nil
        case .unknown(let value): phase = "Host reported an unknown import state: \(sanitize(value))."; detail = "Reconnect the host and check this import again."; action = "Check host import"
        }
        let pct = p.percent.map { ", \($0) percent" } ?? ""
        let message = p.message.map(sanitize)
        return ImportProgressPresentation(title: phase, detail: [detail, message].compactMap { $0 }.joined(separator: " "), action: action, destinationName: p.destinationName, accessibilityValue: "Import phase \(p.state.accessibilityName)\(pct)")
    }

    static func sanitize(_ value: String) -> String {
        var s = value
        for bad in ["access_token", "refresh_token", "device_code", "client_secret", "raw stderr", "raw_provider_body"] { s = s.replacingOccurrences(of: bad, with: "[redacted]", options: .caseInsensitive) }
        s = s.replacingOccurrences(of: #"https://[^\s@/]+@[^\s]+"#, with: "[redacted]", options: .regularExpression)
        s = s.replacingOccurrences(of: #"/Users/[^\s]+"#, with: "[redacted]", options: .regularExpression)
        return s
    }
    static func spokenCode(_ code: String) -> String { code.map { $0 == "-" ? "hyphen" : String($0) }.joined(separator: " ") }
    static func connectionCopy(_ state: ProviderConnectionState) -> String { switch state { case .connected: "connected"; case .reauthorizationRequired: "reauthorization required"; case .authorizing: "authorizing"; case .outage: "outage"; case .error: "error"; case .unknown(let v): sanitize(v); case .disconnected: "disconnected" } }
}

public struct ProviderTransferRailPresentation: Sendable, Equatable { public var hostName: String; public var providerName: String; public var destinationName: String; public var phaseAccessibilityValue: String; public var stations: [RailStationPresentation] { [RailStationPresentation(title: "Remote catalog", subtitle: providerName), RailStationPresentation(title: "Selected host", subtitle: hostName), RailStationPresentation(title: "Local workspace", subtitle: "\(destinationName) · OpenPaw workspace")] } }
public struct RailStationPresentation: Sendable, Equatable { public var title: String; public var subtitle: String }
public struct ProviderCapabilityPresentation: Sendable, Equatable { public var title: String; public var detail: String; public var allowsImport: Bool; init(canList: ProviderCapabilityAvailability, canAuthorize: ProviderCapabilityAvailability, canImport: ProviderCapabilityAvailability) { if canList == .denied || canAuthorize == .denied || canImport == .denied { title = "This paired device cannot manage provider imports."; detail = "Re-pair this device with providers.read, providers.manage, and repos.manage if you want it to authorize and import repositories."; allowsImport = false } else if canList == .unavailable || canAuthorize == .unavailable || canImport == .unavailable { title = "Provider import is unavailable on this host."; detail = "Install or update openpaw-host with provider support, then reconnect."; allowsImport = false } else { title = "Host provider import ready."; detail = "The selected host can browse providers and transfer repositories."; allowsImport = true } } }
public struct ProviderChipPresentation: Sendable, Equatable { public var provider: ProviderID; public var title: String; public var subtitle: String; public var isSelected: Bool; public var connectionState: ProviderConnectionState }
public struct AuthorizationPresentation: Sendable, Equatable { public var providerName: String; public var title: String; public var detail: String; public var userCode: String?; public var accessibilityLabel: String?; public var verificationURL: String?; public var primaryAction: String; public var cancelAction: String? }
public struct ProviderCatalogPresentation: Sendable, Equatable { public var title: String; public var detail: String; public var repos: [ProviderRepoRowPresentation]; public var primaryAction: String?; public var emptyTitle: String? }
public struct ProviderRepoRowPresentation: Sendable, Equatable, Identifiable { public var id: String; public var provider: ProviderID; public var requestedName: String; public var title: String; public var privacy: String; public var source: String?; public init(_ repo: ProviderRepo) { id = repo.id; provider = repo.provider; requestedName = repo.name; title = repo.displayName; privacy = repo.isPrivate ? "private" : "public"; source = repo.sourceURLRedacted.map(ProviderImportPresentation.sanitize) } }
public struct ImportProgressPresentation: Sendable, Equatable { public var title: String; public var detail: String; public var action: String?; public var destinationName: String; public var accessibilityValue: String }

public extension ProviderID { var displayName: String { switch self { case .github: "GitHub"; case .huggingFace: "Hugging Face" } } }
private extension RepoImportState { var accessibilityName: String { switch self { case .queued: "queued"; case .authorizing: "authorizing"; case .cloning: "cloning"; case .validating: "validating"; case .registering: "registering"; case .completed: "completed"; case .failed: "failed"; case .cancelled: "cancelled"; case .recoveryRequired: "recovery required"; case .unknown(let v): ProviderImportPresentation.sanitize(v) } } }
