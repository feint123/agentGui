import Foundation

enum SessionKind: String, Codable, CaseIterable, Sendable {
    case local
    case channel
    case backgroundTask
    case agentTeam

    var displayName: String {
        switch self {
        case .local:
            return "本地"
        case .channel:
            return "渠道"
        case .backgroundTask:
            return "后台任务"
        case .agentTeam:
            return "Agent Team"
        }
    }

    var defaultSourceTitle: String {
        switch self {
        case .local:
            return "本地会话"
        case .channel:
            return "渠道会话"
        case .backgroundTask:
            return "后台任务会话"
        case .agentTeam:
            return "Agent Team"
        }
    }

    var defaultReadOnlyReason: String {
        switch self {
        case .local:
            return ""
        case .channel:
            return "渠道会话为只读镜像，请在来源渠道中继续互动，或复制为本地会话后编辑。"
        case .backgroundTask:
            return "后台任务会话由调度器维护，当前仅支持只读查看。"
        case .agentTeam:
            return "Agent Team 会话使用独立承载面，当前不支持普通消息输入。"
        }
    }

    var isReadOnlyByDefault: Bool {
        switch self {
        case .local:
            return false
        case .channel, .backgroundTask, .agentTeam:
            return true
        }
    }
}