import Foundation
import OpenPawProtocol

public enum ProviderListLoadingState: Sendable, Equatable {
    case idle
    case loading
    case loaded
    case failed(PresentedError)
}

public enum ProviderAuthorizationFlowState: Sendable, Equatable {
    case idle
    case starting(provider: ProviderID)
    case awaitingUser(ProviderAuthorizationStart)
    case polling(ProviderAuthorizationStatus)
    case terminal(ProviderAuthorizationStatus)
    case cancelling(authorizationID: String)
    case failed(provider: ProviderID, authorizationID: String?, error: PresentedError)
}

public struct ProviderRepoPagesState: Sendable, Equatable {
    public var provider: ProviderID?
    public var repos: [ProviderRepo]
    public var nextCursor: String?
    public var isLoading: Bool
    public var error: PresentedError?

    public init(provider: ProviderID? = nil, repos: [ProviderRepo] = [], nextCursor: String? = nil, isLoading: Bool = false, error: PresentedError? = nil) {
        self.provider = provider
        self.repos = repos
        self.nextCursor = nextCursor
        self.isLoading = isLoading
        self.error = error
    }
}

public enum RepoImportOperationState: Sendable, Equatable {
    case idle
    case starting(provider: ProviderID, repoID: String)
    case progress(RepoImportProgress)
    case polling(RepoImportProgress)
    case cancelling(importID: String)
    case terminal(RepoImportProgress)
    case failed(importID: String?, error: PresentedError)

    public var importID: String? {
        switch self {
        case .progress(let progress), .polling(let progress), .terminal(let progress): return progress.id
        case .cancelling(let importID): return importID
        case .failed(let importID, _): return importID
        case .idle, .starting: return nil
        }
    }
}
