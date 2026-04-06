// agentGui/Services/Rewind/RewindTransactionCoordinator.swift
import Foundation
import SwiftData

// MARK: - RewindOption

/// 回滚操作选项，控制恢复范围。
/// 对应 Claude Code src/components/MessageSelector.tsx 中的三个选项按钮：
/// "Restore code and conversation" / "Restore conversation" / "Restore code"
enum RewindOption: Sendable {
    /// 同时恢复文件系统 + 截断对话（默认，最常用）
    case conversationAndFiles
    /// 只截断对话，不动文件（保留 agent 的文件改动）
    case conversationOnly
    /// 只恢复文件，不截断对话（保留对话历史但还原文件）
    case filesOnly
}

// MARK: - RewindTransactionError

enum RewindTransactionError: Error, LocalizedError {
    /// option 包含文件恢复但未提供 checkpoint，或 checkpoint 的 hasFileChanges 为 false
    case checkpointRequiredForFileRestore
    /// targetMessage 未关联到任何 Session
    case messageNotAttachedToSession

    var errorDescription: String? {
        switch self {
        case .checkpointRequiredForFileRestore:
            return "文件恢复需要有效的检查点，但当前消息没有对应的文件快照。"
        case .messageNotAttachedToSession:
            return "目标消息未关联到任何 Session，无法执行回滚。"
        }
    }
}

// MARK: - RewindTransactionResult

struct RewindTransactionResult: Sendable, Equatable {
    /// 被截断的消息数量（0 = filesOnly 模式或截断失败）
    var messagesDeleted: Int
    /// 实际被恢复的文件数量（0 = conversationOnly 模式）
    var filesRestored: Int
    /// 与备份相同无需恢复的文件数量
    var filesSkipped: Int
    /// 恢复失败的文件数量（non-zero = 部分成功）
    var filesFailed: Int

    static let conversationOnlyResult = RewindTransactionResult(
        messagesDeleted: 0,
        filesRestored: 0,
        filesSkipped: 0,
        filesFailed: 0
    )
}

// MARK: - Notification.Name

extension Notification.Name {
    /// 回滚事务完成后发出。
    /// userInfo keys：
    ///   - "sessionID": String
    ///   - "repopulateText": String?（若 repopulateInput=true 且消息有文本）
    ///   - "option": String（"conversationAndFiles" / "conversationOnly" / "filesOnly"）
    static let rewindDidComplete = Notification.Name("agentGui.rewindDidComplete")
}

// MARK: - RewindTransactionCoordinator

/// R-C4: Rewind 功能的统一执行入口。
///
/// ## 职责
/// 按顺序协调以下步骤：
/// 1. 取消正在运行的 agent loop（幂等）
/// 2. 文件系统恢复（R-C2），仅 option 含文件时执行
/// 3. 对话截断（R-C1），仅 option 含对话时执行
/// 4. 发出 `rewindDidComplete` 通知（含输入框填充文本）
///
/// ## 设计决策
/// - 使用闭包注入 loop 取消能力，避免直接依赖 ClaudeService（提升可测试性）
/// - 输入框填充通过通知（`rewindDidComplete`）解耦，ChatView 监听并设置 `inputText`
/// - 若 checkpoint 为 nil 且 option 含文件恢复，抛出 `checkpointRequiredForFileRestore`
///
/// ## 并发安全
/// `@MainActor`：SwiftData 访问和 UI 通知都必须在主线程；
/// cancelLoop 闭包标注 @MainActor，保证取消操作在主线程调度。
@MainActor
final class RewindTransactionCoordinator {

    // MARK: - Dependencies

    private let conversationRewindCoordinator: ConversationRewindCoordinator
    private let fileSystemRewindCoordinator: FileSystemRewindCoordinator
    /// 取消正在运行的 agent loop（幂等）。
    /// 闭包签名：(_ sessionID: String, _ modelContext: ModelContext) async -> Void
    private let cancelLoop: @MainActor @Sendable (String, ModelContext) async -> Void
    private let modelContext: ModelContext

    // MARK: - Init

    init(
        conversationRewindCoordinator: ConversationRewindCoordinator,
        fileSystemRewindCoordinator: FileSystemRewindCoordinator,
        cancelLoop: @escaping @MainActor @Sendable (String, ModelContext) async -> Void,
        modelContext: ModelContext
    ) {
        self.conversationRewindCoordinator = conversationRewindCoordinator
        self.fileSystemRewindCoordinator = fileSystemRewindCoordinator
        self.cancelLoop = cancelLoop
        self.modelContext = modelContext
    }

    // MARK: - Public API

    /// 执行回滚事务。
    ///
    /// - Parameters:
    ///   - targetMessage: 回滚目标消息。该消息本身及之后的所有消息将被删除（conversationOnly / conversationAndFiles）。
    ///   - checkpoint: 目标消息对应的文件检查点（由 ConversationCheckpointService 创建）。
    ///                 option 包含文件恢复时必须非 nil。
    ///   - option: 回滚范围选项。
    ///   - repopulateInput: 若为 true，在通知中携带目标消息的文本，供 ChatView 填回输入框。
    /// - Returns: 包含操作结果统计的 `RewindTransactionResult`。
    /// - Throws: `RewindTransactionError`（类型安全，调用方可精确处理）
    @discardableResult
    func execute(
        targetMessage: Message,
        checkpoint: ConversationCheckpoint?,
        option: RewindOption,
        repopulateInput: Bool = true
    ) async throws -> RewindTransactionResult {
        guard let session = targetMessage.session else {
            throw RewindTransactionError.messageNotAttachedToSession
        }

        // 1. 取消正在运行的 agent loop（幂等，总是先执行）
        await cancelLoop(session.sessionId, modelContext)

        var messagesDeleted = 0
        var filesRestored = 0
        var filesSkipped = 0
        var filesFailed = 0

        // 2. 文件系统恢复（仅 option 含文件时执行）
        if option == .filesOnly || option == .conversationAndFiles {
            guard let cp = checkpoint else {
                throw RewindTransactionError.checkpointRequiredForFileRestore
            }
            let fsResult = try await fileSystemRewindCoordinator.rewind(to: cp)
            filesRestored = fsResult.restoredFiles.count
            filesSkipped = fsResult.skippedFiles.count
            filesFailed = fsResult.failedFiles.count
        }

        // 3. 对话截断（仅 option 含对话时执行）
        if option == .conversationOnly || option == .conversationAndFiles {
            messagesDeleted = try await conversationRewindCoordinator.rewindTo(message: targetMessage)
        }

        // 4. 发出完成通知（含可选的输入框填充文本）
        let repopulateText: String? = repopulateInput
            ? targetMessage.textContent.flatMap(\.nilIfEmpty)
            : nil
        NotificationCenter.default.post(
            name: .rewindDidComplete,
            object: session.sessionId,
            userInfo: [
                "sessionID": session.sessionId,
                "repopulateText": repopulateText as Any,
                "option": option.notificationKey
            ]
        )

        return RewindTransactionResult(
            messagesDeleted: messagesDeleted,
            filesRestored: filesRestored,
            filesSkipped: filesSkipped,
            filesFailed: filesFailed
        )
    }
}

// MARK: - Private Helpers

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private extension RewindOption {
    var notificationKey: String {
        switch self {
        case .conversationAndFiles: return "conversationAndFiles"
        case .conversationOnly:     return "conversationOnly"
        case .filesOnly:            return "filesOnly"
        }
    }
}
