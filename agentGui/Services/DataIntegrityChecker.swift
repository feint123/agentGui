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

        let messageIDs = Set(messages.map(\.id))
        let receipts = try modelContext.fetch(FetchDescriptor<RemoteMessageReceipt>())
        for receipt in receipts {
            if let messageID = receipt.messageID, !messageIDs.contains(messageID) {
                issues.append(
                    IntegrityIssue(
                        kind: .orphanRemoteMessageReceipt,
                        severity: .warning,
                        summary: "远端消息回执 \(receipt.externalMessageID) 未关联有效消息。",
                        recordIdentifier: receipt.id.uuidString
                    )
                )
            }
        }

        let remoteBindings = try modelContext.fetch(FetchDescriptor<RemoteConversationBinding>())
        let groupedRemoteBindings = Dictionary(grouping: remoteBindings) {
            "\($0.channelKind.rawValue)::\($0.externalConversationID)"
        }
        for binding in remoteBindings where binding.session == nil {
            issues.append(
                IntegrityIssue(
                    kind: .staleRemoteConversationBinding,
                    severity: .warning,
                    summary: "远端会话绑定 \(binding.externalConversationID) 未关联有效 Session。",
                    recordIdentifier: binding.id.uuidString
                )
            )
        }
        for (groupKey, bindings) in groupedRemoteBindings where bindings.count > 1 {
            issues.append(
                IntegrityIssue(
                    kind: .duplicateRemoteConversationBinding,
                    severity: .warning,
                    summary: "远端会话 \(groupKey) 存在重复绑定，共 \(bindings.count) 条。",
                    recordIdentifier: groupKey
                )
            )
        }

        let projectionBindings = try modelContext.fetch(FetchDescriptor<SessionProjectionBinding>())
        for binding in projectionBindings where binding.session == nil {
            issues.append(
                IntegrityIssue(
                    kind: .orphanSessionProjectionBinding,
                    severity: .warning,
                    summary: "投影绑定 \(binding.externalConversationID) 未关联有效 Session。",
                    recordIdentifier: binding.id.uuidString
                )
            )
        }

        let projectionDeliveries = try modelContext.fetch(FetchDescriptor<ChannelProjectionDelivery>())
        for delivery in projectionDeliveries where delivery.session == nil {
            issues.append(
                IntegrityIssue(
                    kind: .orphanChannelProjectionDelivery,
                    severity: .warning,
                    summary: "投影投递记录 \(delivery.externalMessageID) 未关联有效 Session。",
                    recordIdentifier: delivery.id.uuidString
                )
            )
        }

        return issues.sorted { $0.createdAt > $1.createdAt }
    }
}