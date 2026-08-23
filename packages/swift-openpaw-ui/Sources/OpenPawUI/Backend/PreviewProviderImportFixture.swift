import Foundation
import OpenPawProtocol

actor PreviewProviderImportFixture {
    static let shared = PreviewProviderImportFixture()
    private var pollCount = 0

    func reset() { pollCount = 0 }

    func next(importID: String) throws -> RepoImportProgress {
        pollCount += 1
        switch pollCount {
        case 1:
            return try RepoImportProgress(id: importID, state: .cloning, repoName: "openpaw", destinationName: "openpaw", percent: 40, message: "Cloning into host workspace store")
        case 2:
            return try RepoImportProgress(id: importID, state: .validating, repoName: "openpaw", destinationName: "openpaw", percent: 70, message: "Validating workspace")
        case 3:
            return try RepoImportProgress(id: importID, state: .registering, repoName: "openpaw", destinationName: "openpaw", percent: 90, message: "Registering workspace")
        default:
            return try RepoImportProgress(id: importID, state: .completed, repoName: "openpaw", destinationName: "openpaw", percent: 100, message: "Imported on selected host")
        }
    }
}
