import Foundation

enum LaunchReadinessBlockingReason: Equatable {
    case missingAPIKey
}

enum LaunchReadinessItemKind: Equatable {
    case apiKey
    case workingDirectory
}

struct LaunchReadinessItem: Equatable, Identifiable {
    let kind: LaunchReadinessItemKind
    let title: String
    let detail: String
    let isSatisfied: Bool
    let isRequired: Bool

    var id: LaunchReadinessItemKind { kind }
}

struct LaunchReadinessStatus: Equatable {
    let items: [LaunchReadinessItem]
    let isReadyForFirstMessage: Bool
    let primaryBlockingReason: LaunchReadinessBlockingReason?

    var title: String {
        if isReadyForFirstMessage {
            return missingRecommendedCount > 0 ? "基础配置已完成" : "可以开始使用 agentGui"
        }
        return "完成首轮配置后即可开始"
    }

    var detail: String {
        if let primaryBlockingReason {
            switch primaryBlockingReason {
            case .missingAPIKey:
                return "先配置 Anthropic API Key。完成后就可以发送第一条消息。"
            }
        }

        if missingRecommendedCount > 0 {
            return "你已经可以开始对话。再补充工作目录后，代码与文件相关能力会更完整。"
        }

        return "当前已满足基础使用条件，可以直接开始提问。"
    }

    var missingRecommendedCount: Int {
        items.filter { !$0.isSatisfied && !$0.isRequired }.count
    }
}

enum LaunchReadinessEvaluator {
    static func evaluate(settings: AppSettings) -> LaunchReadinessStatus {
        let hasAPIKey = !settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasWorkingDirectory = !settings.workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        let items = [
            LaunchReadinessItem(
                kind: .apiKey,
                title: "Anthropic API Key",
                detail: hasAPIKey ? "已配置，可直接发起模型请求。" : "未配置，当前无法发送第一条消息。",
                isSatisfied: hasAPIKey,
                isRequired: true
            ),
            LaunchReadinessItem(
                kind: .workingDirectory,
                title: "工作目录",
                detail: hasWorkingDirectory ? "已选择，文件与代码类任务会带上工作区上下文。" : "未选择，仍可普通聊天，但代码类任务体验会受限。",
                isSatisfied: hasWorkingDirectory,
                isRequired: false
            )
        ]

        return LaunchReadinessStatus(
            items: items,
            isReadyForFirstMessage: hasAPIKey,
            primaryBlockingReason: hasAPIKey ? nil : .missingAPIKey
        )
    }
}