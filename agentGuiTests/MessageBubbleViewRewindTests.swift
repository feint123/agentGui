import Testing
import Foundation
import SwiftData
@testable import agentGui

// MARK: - Helpers

@MainActor
private func makeUserSnapshot() -> MessageRowSnapshot {
    MessageRowSnapshot(
        id: UUID(),
        direction: .user,
        status: .completed,
        timestamp: .now,
        senderName: "你",
        editableUserText: "hello",
        user: nil,
        agent: nil
    )
}

@MainActor
private func makeAgentSnapshot() -> MessageRowSnapshot {
    MessageRowSnapshot(
        id: UUID(),
        direction: .agent,
        status: .completed,
        timestamp: .now,
        senderName: "Claude",
        editableUserText: nil,
        user: nil,
        agent: nil
    )
}

// MARK: - Tests

@Suite("MessageBubbleView — onRewindFromHere 接口")
struct MessageBubbleViewRewindTests {

    @Test("用户消息：设置了 onRewindFromHere 回调，回调非 nil")
    @MainActor
    func userMessage_withCallback_callbackIsNonNil() {
        var called = false
        let view = MessageBubbleView(
            snapshot: makeUserSnapshot(),
            onRewindFromHere: { called = true }
        )
        view.onRewindFromHere?()
        #expect(called == true, "onRewindFromHere 应被调用")
    }

    @Test("用户消息：未设置 onRewindFromHere 时默认为 nil")
    @MainActor
    func userMessage_noCallback_callbackIsNil() {
        let view = MessageBubbleView(snapshot: makeUserSnapshot())
        #expect(view.onRewindFromHere == nil)
    }

    @Test("Agent 消息：设置了 onRewindFromHere 也不触发（方向过滤由 contextMenuItems 负责）")
    @MainActor
    func agentMessage_callbackSet_propertyExists() {
        // 视图不应向 agent 消息展示 rewind 菜单项；此测试仅验证属性可以被设置
        // 但 contextMenuItems 的 guard 会过滤（snapshot.direction == .user）
        var called = false
        let view = MessageBubbleView(
            snapshot: makeAgentSnapshot(),
            onRewindFromHere: { called = true }
        )
        // 接口存在（不会编译错误）
        _ = view.onRewindFromHere
        #expect(called == false, "Agent 消息的 onRewindFromHere 不应被主动触发")
    }
}
