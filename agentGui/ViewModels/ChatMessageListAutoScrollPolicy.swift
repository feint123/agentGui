import Foundation

// MARK: - Scroll State Machine

enum ChatScrollState: Equatable {
    case tracking
    case paused(unseenCount: Int)

    var isTrackingBottom: Bool { self == .tracking }
    var isPaused: Bool {
        if case .paused = self { return true }
        return false
    }

    var unseenCount: Int {
        if case .paused(let n) = self { return n }
        return 0
    }

    var showsBadge: Bool { unseenCount > 0 }

    var badgeLabel: String {
        unseenCount >= 99 ? "99+" : "\(unseenCount)"
    }
}

// MARK: - Policy (pure logic, no UI dependencies)

enum ChatMessageListAutoScrollPolicy {
    static let bottomAnchorID = "chat.messageList.bottomAnchor"

    /// 新消息到达时是否执行滚动
    static func shouldScrollOnMessageAppend(
        scrollState: ChatScrollState,
        lastMessageIsUser: Bool
    ) -> Bool {
        // 用户自己发的消息：始终滚动到底（让用户看到自己的输入）
        if lastMessageIsUser { return true }
        // 正在追踪底部：跟随
        return scrollState.isTrackingBottom
    }

    /// streaming delta 时是否执行滚动
    static func shouldScrollForStreaming(
        scrollState: ChatScrollState,
        isStreaming: Bool
    ) -> Bool {
        isStreaming && scrollState.isTrackingBottom
    }

    /// 用户回溯后新消息到达时累计未读计数
    /// - 若已在追踪状态则切换为 paused(1)
    /// - 若已暂停则 +1，上限 99
    static func incrementUnseenCount(state: ChatScrollState) -> ChatScrollState {
        switch state {
        case .tracking:
            return .paused(unseenCount: 1)
        case .paused(let n):
            return .paused(unseenCount: min(n + 1, 99))
        }
    }
}