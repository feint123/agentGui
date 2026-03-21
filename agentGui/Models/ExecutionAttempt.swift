import Foundation
import SwiftData

enum ExecutionAttemptState: String, Codable, Sendable {
    case running
    case completed
    case failed
    case cancelled
    case interrupted
}

@Model
final class ExecutionAttempt {
    var id: UUID
    var jobID: UUID
    var stateRaw: String
    var startedAt: Date
    var endedAt: Date?
    var runtimeScopeRaw: String?
    var runtimeInstanceKey: String?
    var stopReason: String?
    var errorMessage: String?

    init(
        jobID: UUID,
        runtimeScopeRaw: String? = nil,
        runtimeInstanceKey: String? = nil
    ) {
        self.id = UUID()
        self.jobID = jobID
        self.stateRaw = ExecutionAttemptState.running.rawValue
        self.startedAt = Date()
        self.endedAt = nil
        self.runtimeScopeRaw = runtimeScopeRaw
        self.runtimeInstanceKey = runtimeInstanceKey
        self.stopReason = nil
        self.errorMessage = nil
    }
}

extension ExecutionAttempt {
    var state: ExecutionAttemptState {
        get {
            ExecutionAttemptState(rawValue: stateRaw) ?? .running
        }
        set {
            stateRaw = newValue.rawValue
        }
    }
}