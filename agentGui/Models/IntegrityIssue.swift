import Foundation
import SwiftData

enum IntegrityIssueKind: String, Codable, CaseIterable {
    case brokenPlanJSON
    case orphanMessage
    case orphanToolCall
    case orphanRemoteMessageReceipt
    case invalidWorkflowState
    case staleRemoteConversationBinding
    case duplicateRemoteConversationBinding
    case orphanSessionProjectionBinding
    case orphanChannelProjectionDelivery

    var displayName: String {
        switch self {
        case .brokenPlanJSON:
            return "损坏的计划 JSON"
        case .orphanMessage:
            return "孤立消息"
        case .orphanToolCall:
            return "孤立工具调用"
        case .orphanRemoteMessageReceipt:
            return "孤立远端消息回执"
        case .invalidWorkflowState:
            return "异常工作流状态"
        case .staleRemoteConversationBinding:
            return "失效的远端会话绑定"
        case .duplicateRemoteConversationBinding:
            return "重复的远端会话绑定"
        case .orphanSessionProjectionBinding:
            return "孤立投影绑定"
        case .orphanChannelProjectionDelivery:
            return "孤立投影投递记录"
        }
    }
}

enum IntegrityIssueSeverity: String, Codable, CaseIterable {
    case warning
    case error
}

struct IntegrityReport {
    var issues: [IntegrityIssue]
}

@Model
final class IntegrityIssue {
    var id: UUID
    var kindRaw: String
    var severityRaw: String
    var summary: String
    var recordIdentifier: String
    var createdAt: Date

    init(
        id: UUID = UUID(),
        kind: IntegrityIssueKind,
        severity: IntegrityIssueSeverity,
        summary: String,
        recordIdentifier: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kindRaw = kind.rawValue
        self.severityRaw = severity.rawValue
        self.summary = summary
        self.recordIdentifier = recordIdentifier
        self.createdAt = createdAt
    }
}

extension IntegrityIssue {
    var kind: IntegrityIssueKind {
        IntegrityIssueKind(rawValue: kindRaw) ?? .invalidWorkflowState
    }

    var severity: IntegrityIssueSeverity {
        IntegrityIssueSeverity(rawValue: severityRaw) ?? .warning
    }
}