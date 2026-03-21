import Foundation
import SwiftData

struct ExecutionDriverContext {
    let session: Session
    let modelContext: ModelContext
    let workingDirectoryOverride: String?

    init(
        session: Session,
        modelContext: ModelContext,
        workingDirectoryOverride: String? = nil
    ) {
        self.session = session
        self.modelContext = modelContext
        self.workingDirectoryOverride = workingDirectoryOverride
    }
}

enum ExecutionDriverEvent: Equatable, Sendable {
    case started(jobID: UUID)
    case finished(jobID: UUID, outcome: ExecutionJobState)
}

protocol ConversationExecutionDriver {
    var providerID: ConversationExecutionProviderID { get }
    var runtimeScope: ConversationExecutionRuntimeScope? { get }

    func execute(_ job: ExecutionJob, context: ExecutionDriverContext) -> AsyncThrowingStream<ExecutionDriverEvent, Error>
    func cancel(jobID: UUID, sessionID: String) async
}