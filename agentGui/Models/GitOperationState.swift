import Foundation

enum GitOperationState: Equatable {
    case idle
    case running(String)
    case failed(String)
}

enum GitCommitDisabledReason: Equatable {
    case missingSummary
    case noStagedChanges
}