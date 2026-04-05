// agentGui/Services/Rewind/ConversationRewindCoordinator.swift
import Foundation
import SwiftData

// MARK: - RewindError

/// ConversationRewindCoordinator 的错误类型
enum RewindError: Error, LocalizedError {
    case messageNotAttachedToSession

    var errorDescription: String? {
        switch self {
        case .messageNotAttachedToSession:
            return "目标消息未关联到任何 Session，无法执行对话截断。"
        }
    }
}

// MARK: - Notification.Name

extension Notification.Name {
    /// 对话截断完成后发出。object 为 sessionID (String)。
    /// 观察者：AgentLoopRunner（清除 compaction 缓存），AgentTeamWorkbenchPresentation（清除内存镜像）
    static let rewindDidPruneConversation = Notification.Name("agentGui.rewindDidPruneConversation")
}

// MARK: - ConversationRewindCoordinator

/// R-C1: 负责通过 SwiftData cascade delete 截断指定用户消息（含该消息本身）及其之后的所有对话记录。
///
/// ## 截断语义
/// 对齐 Claude Code `rewindConversationTo(message)` 的行为：
/// - `targetMessage` 及所有 `sequence >= targetMessage.sequence` 的 `Message` 都被删除
/// - SwiftData cascade 自动清理关联的 `AgentRound` 和 `ToolCall`
///
/// ## 职责边界
/// - 本类 **只做 SwiftData 截断**，不负责取消 agent loop（由 R-C4 先完成）
/// - 不负责文件系统恢复（R-C2）
/// - 不负责填充输入框（R-C4）
/// - Agent team 的内存镜像清理通过 `rewindDidPruneConversation` 通知解耦
@MainActor
final class ConversationRewindCoordinator {

    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - Public API

    /// 截断对话到指定消息（含目标消息）之前。
    ///
    /// - Parameter targetMessage: 对话截断的起始点。此消息本身及其后所有消息均被删除。
    /// - Returns: 实际被删除的消息数量。
    /// - Throws: `RewindError.messageNotAttachedToSession` 若消息未关联 session。
    @discardableResult
    func rewindTo(message targetMessage: Message) async throws -> Int {
        guard let session = targetMessage.session else {
            throw RewindError.messageNotAttachedToSession
        }

        let targetSequence = targetMessage.sequence
        let toDelete = session.messages.filter { $0.sequence >= targetSequence }
        let deletedCount = toDelete.count

        for message in toDelete {
            modelContext.delete(message)
        }

        try modelContext.save()

        NotificationCenter.default.post(
            name: .rewindDidPruneConversation,
            object: session.sessionId
        )

        return deletedCount
    }
}
