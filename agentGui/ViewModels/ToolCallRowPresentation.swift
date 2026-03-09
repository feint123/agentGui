import Foundation

enum ToolRowStyle: Equatable {
    case read
    case edit
    case execute
    case search
    case fetch
    case askUser
    case subagent
    case other
}

struct ToolCallRowPresentation: Equatable {
    let style: ToolRowStyle
    let primaryText: String
    let secondaryText: String?
    let tertiaryText: String?
    let statusText: String
    let detailText: String?
    let durationText: String?
    let isExpanded: Bool

    nonisolated static func make(for toolCall: ToolCall, isExpanded: Bool = false) -> ToolCallRowPresentation {
        let durationText = toolCall.duration.map { String(format: "%.1fs", $0) }

        switch toolCall.kind {
        case .read:
            return ToolCallRowPresentation(
                style: .read,
                primaryText: toolCall.fileName ?? toolCall.title ?? toolCall.kind.displayName,
                secondaryText: toolCall.displayPath,
                tertiaryText: nil,
                statusText: toolCall.statusDisplay,
                detailText: toolCall.terminalOutput,
                durationText: durationText,
                isExpanded: isExpanded
            )
        case .edit:
            let diffSummary = toolCall.diffContent.map(Self.diffSummary(from:))
            return ToolCallRowPresentation(
                style: .edit,
                primaryText: toolCall.fileName ?? toolCall.title ?? toolCall.kind.displayName,
                secondaryText: diffSummary,
                tertiaryText: toolCall.displayPath,
                statusText: toolCall.statusDisplay,
                detailText: toolCall.diffContent,
                durationText: durationText,
                isExpanded: isExpanded
            )
        case .execute:
            return ToolCallRowPresentation(
                style: .execute,
                primaryText: toolCall.title ?? toolCall.kind.displayName,
                secondaryText: executionSummary(for: toolCall),
                tertiaryText: nil,
                statusText: toolCall.statusDisplay,
                detailText: toolCall.terminalOutput,
                durationText: durationText,
                isExpanded: isExpanded
            )
        case .search:
            return ToolCallRowPresentation(
                style: .search,
                primaryText: toolCall.title ?? toolCall.kind.displayName,
                secondaryText: summaryLine(from: toolCall.terminalOutput),
                tertiaryText: nil,
                statusText: toolCall.statusDisplay,
                detailText: toolCall.terminalOutput,
                durationText: durationText,
                isExpanded: isExpanded
            )
        case .fetch:
            return ToolCallRowPresentation(
                style: .fetch,
                primaryText: toolCall.title ?? toolCall.kind.displayName,
                secondaryText: summaryLine(from: toolCall.terminalOutput),
                tertiaryText: toolCall.filePath,
                statusText: toolCall.statusDisplay,
                detailText: toolCall.terminalOutput,
                durationText: durationText,
                isExpanded: isExpanded
            )
        case .askUser:
            return ToolCallRowPresentation(
                style: .askUser,
                primaryText: toolCall.title ?? toolCall.kind.displayName,
                secondaryText: askUserSummary(for: toolCall),
                tertiaryText: nil,
                statusText: toolCall.statusDisplay,
                detailText: toolCall.terminalOutput,
                durationText: durationText,
                isExpanded: isExpanded
            )
        case .subagent:
            return ToolCallRowPresentation(
                style: .subagent,
                primaryText: toolCall.subagentAgentName ?? toolCall.title ?? toolCall.kind.displayName,
                secondaryText: toolCall.subagentTask,
                tertiaryText: toolCall.subagentResultKind,
                statusText: toolCall.statusDisplay,
                detailText: nil,
                durationText: durationText,
                isExpanded: isExpanded
            )
        default:
            return ToolCallRowPresentation(
                style: .other,
                primaryText: toolCall.title ?? toolCall.kind.displayName,
                secondaryText: summaryLine(from: toolCall.terminalOutput),
                tertiaryText: toolCall.displayPath,
                statusText: toolCall.statusDisplay,
                detailText: toolCall.terminalOutput,
                durationText: durationText,
                isExpanded: isExpanded
            )
        }
    }

    nonisolated private static func diffSummary(from diff: String) -> String {
        let inserted = diff.split(separator: "\n").filter { $0.hasPrefix("+") && !$0.hasPrefix("+++") }.count
        let removed = diff.split(separator: "\n").filter { $0.hasPrefix("-") && !$0.hasPrefix("---") }.count
        if inserted == 0 && removed == 0 { return "已修改" }
        return "\(max(inserted, removed)) 处变更"
    }

    nonisolated private static func executionSummary(for toolCall: ToolCall) -> String? {
        if toolCall.status == .failed {
            return summaryLine(from: toolCall.terminalOutput) ?? "执行失败"
        }
        return summaryLine(from: toolCall.terminalOutput)
    }

    nonisolated private static func askUserSummary(for toolCall: ToolCall) -> String? {
        guard let output = toolCall.terminalOutput,
              let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = json["answers"] as? [[String: Any]],
              let first = answers.first else {
            return nil
        }
        let selected = first["selected"] as? [String] ?? []
        return selected.isEmpty ? "等待或已取消" : selected.joined(separator: "、")
    }

    nonisolated private static func summaryLine(from text: String?) -> String? {
        guard let text else { return nil }
        return text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    }
}