import Foundation

protocol ACPProviderValidationRuntime: Sendable {
    func initialize(_ request: ACPInitializeRequest) async throws -> ACPInitializeResponse
    func close() async
}

enum ACPProviderValidationResult: Equatable, Sendable {
    case ready(ACPProviderValidationSnapshot)
    case missingExecutable(String)
    case initializeFailed(String)

    var message: String {
        switch self {
        case .ready(let snapshot):
            return snapshot.message
        case .missingExecutable(let message), .initializeFailed(let message):
            return message
        }
    }

    var snapshot: ACPProviderValidationSnapshot? {
        guard case .ready(let snapshot) = self else {
            return nil
        }
        return snapshot
    }
}