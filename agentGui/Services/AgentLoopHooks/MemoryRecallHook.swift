import Foundation
import SwiftAnthropic

/// 在 `.willStartRound` 阶段触发中段记忆召回并以 `messagePatch` 注入结果。
///
/// - `order = 15`：在 MemoryBootstrapHook (order=20) 之前运行；
///   bootstrap 在 `prepareRun` 阶段，recall 在 `willStartRound` 阶段，两者不冲突。
/// - `.subagent` 执行上下文跳过（防递归）。
/// - `recallService` 为 `nil` 时（service 未就绪）直接放行。
struct MemoryRecallHook: AgentLoopHook {
    let id = "memory-recall"
    let order = 15
    let kind: AgentLoopHookKind = .mutator
    let isRequired = false

    let recallService: (any MemoryRecallServiceProtocol)?

    func supports(_ stage: AgentLoopHookStage) -> Bool {
        stage == .willStartRound
    }

    func perform(
        stage: AgentLoopHookStage,
        context: AgentLoopHookContext
    ) async throws -> AgentLoopHookResult {
        guard stage == .willStartRound else { return .continue }
        guard context.executionContext == .mainAgent else { return .continue }
        guard let service = recallService else { return .continue }

        guard let injectionText = await service.recall(
            messagesSnapshot: context.messagesSnapshot,
            now: .now
        ), !injectionText.isEmpty else {
            return .continue
        }

        // 注入方式：在最后一条 user 消息「之前」插入 user+assistant 消息对。
        // 正确顺序：[recall user], [recall ack], [current user query]
        // 错误顺序：[current user query], [recall user], ...  ← Anthropic API 会拒绝连续两条 user 消息
        let insertIndex = max(0, context.messagesSnapshot.count - 1)
        let patch = AgentLoopMessagePatch(
            insertions: [
                .init(
                    index: insertIndex,
                    message: MessageParameter.Message(
                        role: .user,
                        content: .text(injectionText)
                    )
                ),
                .init(
                    index: insertIndex + 1,
                    message: MessageParameter.Message(
                        role: .assistant,
                        content: .text("已加载相关记忆上下文，将在本轮回复中参考以上记忆。")
                    )
                )
            ],
            metadata: ["source": "memory-recall"]
        )
        return .messagePatch(patch)
    }
}
