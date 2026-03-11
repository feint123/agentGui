import CoreData
import Foundation
import Observation
import SwiftData

@Observable
@MainActor
final class PersistenceCoordinator {
    enum SaveDomain: String, Codable {
        case settings
        case sessionMessages
        case toolCalls
        case workflow
        case sessionTaskState
        case backupRestore

        var isCritical: Bool {
            switch self {
            case .sessionMessages, .toolCalls, .workflow:
                return true
            case .settings, .sessionTaskState, .backupRestore:
                return false
            }
        }
    }

    enum FailureCategory: String, Codable {
        case permissionDenied
        case insufficientDiskSpace
        case validationFailed
        case storeCorrupted
        case unknown
    }

    enum SaveError: LocalizedError {
        case failed(category: FailureCategory, userMessage: String, technicalMessage: String)

        var errorDescription: String? {
            switch self {
            case let .failed(_, userMessage, _):
                return userMessage
            }
        }

        var technicalMessage: String {
            switch self {
            case let .failed(_, _, technicalMessage):
                return technicalMessage
            }
        }

        var category: FailureCategory {
            switch self {
            case let .failed(category, _, _):
                return category
            }
        }
    }

    static let shared = PersistenceCoordinator()

    typealias SaveOperation = @MainActor (ModelContext) throws -> Void
    typealias FailureSink = @MainActor (PersistenceFailureRecord) -> Void

    private let saveOperation: SaveOperation
    private let failureSink: FailureSink?

    private(set) var lastFailure: PersistenceFailureRecord?
    private(set) var recentFailures: [PersistenceFailureRecord] = []

    var lastFailureSummary: String? {
        guard let lastFailure else { return nil }
        return lastFailure.userMessage
    }

    init(
        saveOperation: @escaping SaveOperation = { try $0.save() },
        failureSink: FailureSink? = nil
    ) {
        self.saveOperation = saveOperation
        self.failureSink = failureSink
    }

    func save(
        _ context: ModelContext,
        domain: SaveDomain,
        userMessage: String,
        metadata: [String: String] = [:]
    ) throws {
        do {
            try saveOperation(context)
        } catch {
            let category = classify(error)
            let failure = PersistenceFailureRecord(
                domain: domain,
                category: category,
                userMessage: userMessage,
                technicalMessage: error.localizedDescription,
                metadata: metadata,
                isCritical: domain.isCritical
            )
            recordFailure(failure)
            throw SaveError.failed(
                category: category,
                userMessage: userMessage,
                technicalMessage: error.localizedDescription
            )
        }
    }

    func dismissFailure() {
        lastFailure = nil
    }

    private func recordFailure(_ failure: PersistenceFailureRecord) {
        lastFailure = failure
        recentFailures.insert(failure, at: 0)
        if recentFailures.count > 20 {
            recentFailures.removeLast(recentFailures.count - 20)
        }
        failureSink?(failure)
    }

    private func classify(_ error: Error) -> FailureCategory {
        let nsError = error as NSError
        guard nsError.domain == NSCocoaErrorDomain else {
            return .unknown
        }
        let code = CocoaError.Code(rawValue: nsError.code)

        switch code {
        case .fileWriteNoPermission, .fileReadNoPermission:
            return .permissionDenied
        case .fileWriteOutOfSpace:
            return .insufficientDiskSpace
        case .validationMultipleErrors,
             .validationMissingMandatoryProperty,
             .validationRelationshipDeniedDelete,
             .validationNumberTooLarge,
             .validationNumberTooSmall,
             .validationDateTooLate,
             .validationDateTooSoon,
             .validationInvalidDate,
             .validationStringTooLong,
             .validationStringTooShort:
            return .validationFailed
        case .persistentStoreIncompatibleVersionHash,
             .persistentStoreSave,
             .persistentStoreOpen,
             .migration,
             .migrationMissingSourceModel,
             .migrationMissingMappingModel,
             .migrationManagerSourceStore,
             .migrationCancelled:
            return .storeCorrupted
        default:
            return .unknown
        }
    }
}