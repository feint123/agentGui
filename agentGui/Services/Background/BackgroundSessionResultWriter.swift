import Foundation
import SwiftData

@MainActor
final class BackgroundSessionResultWriter {
    private let persistenceCoordinator: PersistenceCoordinator

    init(persistenceCoordinator: PersistenceCoordinator) {
        self.persistenceCoordinator = persistenceCoordinator
    }

    convenience init() {
        self.init(persistenceCoordinator: .shared)
    }

    @discardableResult
    func writeSuccessResult(
        task: BackgroundAgentTask,
        output: String,
        summary: String,
        modelContext: ModelContext
    ) throws -> Message? {
        let policy = task.executionPolicy
        guard policy.appendUserVisibleMessage else { return nil }

        let session = try resolveSession(for: task, modelContext: modelContext)
        let message: Message?

        switch policy.resultDeliveryMode {
        case .sessionMessages:
            let systemMessage = Message.systemMessage(text: "后台任务“\(task.title)”已触发并完成。", session: session)
            let agentMessage = Message.agentMessage(text: output, session: session)
            agentMessage.status = .completed
            modelContext.insert(systemMessage)
            modelContext.insert(agentMessage)
            message = agentMessage
        case .summaryOnly:
            let summaryMessage = Message.systemMessage(text: "后台任务“\(task.title)”已完成：\(summary)", session: session)
            modelContext.insert(summaryMessage)
            message = summaryMessage
        }

        try persistenceCoordinator.save(
            modelContext,
            domain: .sessionMessages,
            userMessage: "后台任务结果未成功写回会话",
            metadata: ["taskKey": task.taskKey, "sessionId": task.sessionId]
        )
        return message
    }

    @discardableResult
    func writeFailureResult(
        task: BackgroundAgentTask,
        summary: String,
        modelContext: ModelContext
    ) throws -> Message? {
        let policy = task.executionPolicy
        guard policy.appendUserVisibleMessage else { return nil }

        let session = try resolveSession(for: task, modelContext: modelContext)
        let message: Message?

        switch policy.resultDeliveryMode {
        case .sessionMessages:
            let systemMessage = Message.systemMessage(text: "后台任务“\(task.title)”执行失败。", session: session)
            let errorMessage = Message.errorMessage(text: summary, session: session)
            modelContext.insert(systemMessage)
            modelContext.insert(errorMessage)
            message = errorMessage
        case .summaryOnly:
            let errorMessage = Message.errorMessage(text: "后台任务“\(task.title)”执行失败：\(summary)", session: session)
            modelContext.insert(errorMessage)
            message = errorMessage
        }

        try persistenceCoordinator.save(
            modelContext,
            domain: .sessionMessages,
            userMessage: "后台任务失败摘要未成功写回会话",
            metadata: ["taskKey": task.taskKey, "sessionId": task.sessionId]
        )
        return message
    }

    private func resolveSession(id: String, modelContext: ModelContext) throws -> Session {
        let sessions = try modelContext.fetch(FetchDescriptor<Session>())
        guard let session = sessions.first(where: { $0.sessionId == id }) else {
            throw BackgroundSessionResultWriterError.sessionNotFound(id)
        }
        return session
    }

    private func resolveSession(for task: BackgroundAgentTask, modelContext: ModelContext) throws -> Session {
        let sessions = try modelContext.fetch(FetchDescriptor<Session>())

        if let session = sessions.first(where: { $0.sessionId == task.sessionId }) {
            return session
        }

        if let session = sessions.first(where: {
            $0.kind == .backgroundTask && $0.sourceIdentifier == task.dedicatedSessionSourceIdentifier
        }) {
            task.sessionId = session.sessionId
            return session
        }

        throw BackgroundSessionResultWriterError.sessionNotFound(task.sessionId)
    }
}

enum BackgroundSessionResultWriterError: Error, Equatable {
    case sessionNotFound(String)
}