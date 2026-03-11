import Foundation
import SwiftData

@MainActor
final class DataIntegrityChecker {
    private let persistenceCoordinator: PersistenceCoordinator

    init(persistenceCoordinator: PersistenceCoordinator = .shared) {
        self.persistenceCoordinator = persistenceCoordinator
    }

    func runLightweightChecks(in modelContext: ModelContext) throws -> IntegrityReport {
        let issues = try collectIssues(in: modelContext)

        let existingIssues = try modelContext.fetch(FetchDescriptor<IntegrityIssue>())
        for issue in existingIssues {
            modelContext.delete(issue)
        }
        for issue in issues {
            modelContext.insert(issue)
        }

        try persistenceCoordinator.save(
            modelContext,
            domain: .sessionTaskState,
            userMessage: "完整性检查结果未成功保存"
        )

        return IntegrityReport(issues: issues)
    }

    private func collectIssues(in modelContext: ModelContext) throws -> [IntegrityIssue] {
        var issues: [IntegrityIssue] = []

        let sessions = try modelContext.fetch(FetchDescriptor<Session>())
        for session in sessions where !session.planJson.isEmpty {
            if session.plan == nil {
                issues.append(
                    IntegrityIssue(
                        kind: .brokenPlanJSON,
                        severity: .error,
                        summary: "会话 \(session.title) 的执行计划 JSON 无法解析。",
                        recordIdentifier: session.sessionId
                    )
                )
            }
        }

        let messages = try modelContext.fetch(FetchDescriptor<Message>())
        for message in messages where message.session == nil {
            issues.append(
                IntegrityIssue(
                    kind: .orphanMessage,
                    severity: .warning,
                    summary: "消息 \(message.id.uuidString) 没有关联会话。",
                    recordIdentifier: message.id.uuidString
                )
            )
        }

        let toolCalls = try modelContext.fetch(FetchDescriptor<ToolCall>())
        for toolCall in toolCalls where toolCall.message == nil {
            issues.append(
                IntegrityIssue(
                    kind: .orphanToolCall,
                    severity: .warning,
                    summary: "工具调用 \(toolCall.toolCallId) 没有关联消息。",
                    recordIdentifier: toolCall.toolCallId
                )
            )
        }

        let workflows = try modelContext.fetch(FetchDescriptor<WorkflowInstance>())
        for workflow in workflows where workflow.status == .running {
            if workflow.activations.isEmpty && workflow.messages.isEmpty && workflow.artifacts.isEmpty {
                issues.append(
                    IntegrityIssue(
                        kind: .invalidWorkflowState,
                        severity: .error,
                        summary: "工作流 \(workflow.id.uuidString) 处于运行中，但没有任何执行记录。",
                        recordIdentifier: workflow.id.uuidString
                    )
                )
            }
        }

        return issues.sorted { $0.createdAt > $1.createdAt }
    }
}