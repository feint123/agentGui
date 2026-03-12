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
                secondaryText: toolCall.toolResultSummary ?? toolCall.displayPath,
                tertiaryText: toolCall.toolPayloadRef,
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
            let managedStatus = terminalTaskStatus(from: toolCall)
            return ToolCallRowPresentation(
                style: .execute,
                primaryText: toolCall.title ?? toolCall.kind.displayName,
                secondaryText: toolCall.toolResultSummary ?? managedExecutionSummary(for: toolCall, status: managedStatus),
                tertiaryText: managedTertiaryText(for: toolCall, status: managedStatus),
                statusText: managedStatus.map(terminalStatusText(for:)) ?? toolCall.statusDisplay,
                detailText: toolCall.terminalOutput,
                durationText: durationText,
                isExpanded: isExpanded
            )
        case .search:
            return ToolCallRowPresentation(
                style: .search,
                primaryText: toolCall.title ?? toolCall.kind.displayName,
                secondaryText: toolCall.toolResultSummary ?? summaryLine(from: toolCall.terminalOutput),
                tertiaryText: toolCall.toolPayloadRef,
                statusText: toolCall.statusDisplay,
                detailText: toolCall.terminalOutput,
                durationText: durationText,
                isExpanded: isExpanded
            )
        case .fetch:
            return ToolCallRowPresentation(
                style: .fetch,
                primaryText: toolCall.title ?? toolCall.kind.displayName,
                secondaryText: toolCall.toolResultSummary ?? summaryLine(from: toolCall.terminalOutput),
                tertiaryText: toolCall.toolPayloadRef ?? toolCall.filePath,
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
            let auditSummary = storyMemoryAuditSummary(for: toolCall)
            let auditTertiary = storyMemoryAuditTertiary(for: toolCall)
            return ToolCallRowPresentation(
                style: .subagent,
                primaryText: toolCall.subagentAgentName ?? toolCall.title ?? toolCall.kind.displayName,
                secondaryText: auditSummary ?? toolCall.subagentTask,
                tertiaryText: auditTertiary ?? toolCall.subagentResultKind,
                statusText: toolCall.statusDisplay,
                detailText: nil,
                durationText: durationText,
                isExpanded: isExpanded
            )
        default:
            return ToolCallRowPresentation(
                style: .other,
                primaryText: toolCall.title ?? toolCall.kind.displayName,
                secondaryText: toolCall.toolResultSummary ?? summaryLine(from: toolCall.terminalOutput),
                tertiaryText: toolCall.toolPayloadRef ?? toolCall.displayPath,
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

    nonisolated private static func managedExecutionSummary(
        for toolCall: ToolCall,
        status: TerminalTaskStatus?
    ) -> String? {
        if let mode = toolCall.terminalExecutionMode.flatMap(TerminalExecutionMode.init(rawValue:)) {
            switch mode {
            case .background:
                return "后台任务"
            case .interactive:
                return status == .waitingForPrompt || status == .needsUserDecision ? "等待交互" : "交互任务"
            case .foreground:
                return executionSummary(for: toolCall)
            case .auto:
                return executionSummary(for: toolCall)
            }
        }

        return executionSummary(for: toolCall)
    }

    nonisolated private static func managedTertiaryText(
        for toolCall: ToolCall,
        status: TerminalTaskStatus?
    ) -> String? {
        if let promptSummary = toolCall.terminalPromptSummary, !promptSummary.isEmpty {
            return promptSummary
        }

        if let payloadRef = toolCall.toolPayloadRef, !payloadRef.isEmpty {
            return payloadRef
        }

        if status == .runningBackground {
            return summaryLine(from: toolCall.terminalOutput)
        }

        return nil
    }

    nonisolated private static func terminalTaskStatus(from toolCall: ToolCall) -> TerminalTaskStatus? {
        guard let raw = toolCall.terminalTaskStatus else { return nil }
        return TerminalTaskStatus(rawValue: raw)
    }

    nonisolated private static func terminalStatusText(for status: TerminalTaskStatus) -> String {
        switch status {
        case .queued:
            return "已排队"
        case .classifying:
            return "分析中"
        case .launching:
            return "启动中"
        case .runningForeground:
            return "执行中"
        case .waitingForPrompt:
            return "等待输入"
        case .runningBackground:
            return "后台运行中"
        case .completed:
            return "已完成"
        case .failed:
            return "失败"
        case .interrupted:
            return "已中断"
        case .timedOut:
            return "已超时"
        case .needsUserDecision:
            return "等待用户决策"
        }
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

    nonisolated private static func storyMemoryAuditSummary(for toolCall: ToolCall) -> String? {
        toolCall.storyMemoryRiskSummary ?? toolCall.storyMemoryFallbackNote
    }

    nonisolated private static func storyMemoryAuditTertiary(for toolCall: ToolCall) -> String? {
        guard let taskType = toolCall.storyMemoryTaskType,
              let status = toolCall.storyMemoryStatus else {
            return nil
        }
        return "\(taskType) · \(status)"
    }

    nonisolated private static func summaryLine(from text: String?) -> String? {
        guard let text else { return nil }
        return text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    }
}