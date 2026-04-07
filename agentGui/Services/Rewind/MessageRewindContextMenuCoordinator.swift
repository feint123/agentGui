import Foundation
import SwiftData

// MARK: - Result

/// 上下文菜单回滚的执行结果。
enum MessageRewindContextMenuResult: Sendable {
    /// Lossless 路径：已直接执行对话截断，无需用户确认。
    case losslessCompleted
    /// 需要用户确认：包含 diff 预览数据，供 RewindConfirmationSheet 展示。
    case needsConfirmation(MessageRewindSelectorViewModel.PendingConfirmation)
}

// MARK: - MessageRewindContextMenuCoordinator

/// R-D4: 从消息上下文菜单触发回滚的协调器。
///
/// ## 执行逻辑
/// 1. 从 ConversationCheckpointService 获取目标消息对应的 checkpoint
/// 2. 调用 RewindPreflightInspector.hasAnyFileChanges 检查是否有文件变化
/// 3. 无变化 → 调用 RewindTransactionCoordinator.execute(.conversationOnly) → 返回 .losslessCompleted
/// 4. 有变化 → 计算 diffStats + 统计消息数 → 返回 .needsConfirmation(pending)
///
/// ## 并发安全
/// `@MainActor`：checkpointService/txCoord 均为 @MainActor 或 actor，统一在主线程调用。
@MainActor
final class MessageRewindContextMenuCoordinator {

    private let checkpointService: ConversationCheckpointService
    private let preflightInspector: RewindPreflightInspector
    private let transactionCoordinator: RewindTransactionCoordinator

    init(
        checkpointService: ConversationCheckpointService,
        preflightInspector: RewindPreflightInspector,
        transactionCoordinator: RewindTransactionCoordinator
    ) {
        self.checkpointService = checkpointService
        self.preflightInspector = preflightInspector
        self.transactionCoordinator = transactionCoordinator
    }

    /// 执行上下文菜单回滚决策。
    ///
    /// - Parameters:
    ///   - message: 用户选择的目标消息（必须是用户消息）。
    ///   - allMessages: 当前 session 的全量消息列表（用于统计 messagesAfterCount）。
    ///   - sessionID: session 的标识符。
    ///   - modelContext: SwiftData ModelContext。
    /// - Returns: `.losslessCompleted`（已执行）或 `.needsConfirmation(pending)`（需弹窗）。
    func execute(
        message: Message,
        allMessages: [Message],
        sessionID: String,
        modelContext: ModelContext
    ) async throws -> MessageRewindContextMenuResult {
        // 1. 获取此 session 的 checkpoints，找到目标消息对应的那个
        let checkpoints = (try? await checkpointService.fetchCheckpoints(
            sessionID: sessionID,
            limit: 50,
            modelContext: modelContext
        )) ?? []
        let checkpoint = checkpoints.first { $0.messageID == message.id }

        // 2. 检查是否有文件变化（先看 hasFileChanges 标志，再调 inspector 精确验证）
        let hasChanges: Bool
        if let cp = checkpoint, cp.hasFileChanges {
            hasChanges = (try? await preflightInspector.hasAnyFileChanges(checkpoint: cp)) ?? false
        } else {
            hasChanges = false
        }

        if !hasChanges {
            // Lossless fast path: 直接截断对话，不动文件
            try await transactionCoordinator.execute(
                targetMessage: message,
                checkpoint: nil,
                option: .conversationOnly,
                repopulateInput: true
            )
            return .losslessCompleted
        } else {
            // Confirmation path: 计算 diff 统计，返回待确认数据
            let diffStats = (try? await preflightInspector.computeDiffStats(
                checkpoint: checkpoint!
            )) ?? .empty
            let targetSeq = message.sequence
            let msgsAfter = allMessages.filter { $0.sequence > targetSeq }
            let toolCallsAfterCount = msgsAfter.reduce(0) { $0 + $1.toolCalls.count }

            let pending = MessageRewindSelectorViewModel.PendingConfirmation(
                message: message,
                checkpoint: checkpoint,
                diffStats: diffStats,
                messagesAfterCount: msgsAfter.count,
                toolCallsAfterCount: toolCallsAfterCount
            )
            return .needsConfirmation(pending)
        }
    }
}
