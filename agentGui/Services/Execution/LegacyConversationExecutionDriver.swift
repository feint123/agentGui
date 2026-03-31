import Foundation
import SwiftData

enum LegacyConversationExecutionDriverError: Error {
    case unsupportedPayload
}

@MainActor
final class LegacyConversationExecutionDriver: ConversationExecutionDriver {
    private struct ActiveExecution {
        let task: Task<Void, Never>
        let session: Session
        let modelContext: ModelContext
    }

    private let provider: any ConversationExecutionProvider
    private var activeExecutions: [UUID: ActiveExecution] = [:]

    init(provider: any ConversationExecutionProvider) {
        self.provider = provider
    }

    var providerID: ConversationExecutionProviderID {
        provider.id
    }

    var runtimeScope: ConversationExecutionRuntimeScope? {
        provider.runtimeScope
    }

    func execute(_ job: ExecutionJob, context: ExecutionDriverContext) -> AsyncThrowingStream<ExecutionDriverEvent, Error> {
        return AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                continuation.yield(.started(jobID: job.id))
                do {
                    let request = try self.makeRequest(for: job, context: context)
                    try await self.provider.send(request)
                    continuation.yield(.finished(jobID: job.id, outcome: self.resolveOutcome(for: job, in: context)))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.yield(.finished(jobID: job.id, outcome: .cancelled))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }

                self.activeExecutions.removeValue(forKey: job.id)
            }

            self.activeExecutions[job.id] = ActiveExecution(
                task: task,
                session: context.session,
                modelContext: context.modelContext
            )
        }
    }

    func cancel(jobID: UUID, sessionID: String) async {
        guard let execution = activeExecutions[jobID], execution.session.sessionId == sessionID else {
            return
        }

        execution.task.cancel()
        await provider.cancel(session: execution.session, modelContext: execution.modelContext)
    }

    private func makeRequest(
        for job: ExecutionJob,
        context: ExecutionDriverContext
    ) throws -> ConversationExecutionRequest {
        guard let payload = job.payload else {
            throw LegacyConversationExecutionDriverError.unsupportedPayload
        }

        switch payload {
        case let .userPrompt(text, modelID, selectedFilePath, selectedText, directives, teamContext):
            return ConversationExecutionRequest(
                text: text,
                session: context.session,
                modelID: modelID,
                selectedFilePath: selectedFilePath,
                selectedText: selectedText,
                directives: directives,
                teamContext: teamContext,
                modelContext: context.modelContext,
                sourceUserMessageID: job.sourceUserMessageID,
                targetAgentMessageID: job.targetAgentMessageID,
                workingDirectoryOverride: context.workingDirectoryOverride
            )
        }
    }

    private func resolveOutcome(
        for job: ExecutionJob,
        in context: ExecutionDriverContext
    ) -> ExecutionJobState {
        guard let targetAgentMessageID = job.targetAgentMessageID,
              let message = context.session.messages.first(where: { $0.id == targetAgentMessageID }) else {
            return .completed
        }

        switch message.status {
        case .cancelled:
            return .cancelled
        case .failed:
            return .failed
        default:
            return .completed
        }
    }
}