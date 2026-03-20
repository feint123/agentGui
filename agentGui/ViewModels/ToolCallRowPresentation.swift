import Foundation

enum ToolRowStyle: Equatable {
    case read
    case edit
    case execute
    case search
    case fetch
    case permission
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

    static func make(for toolCall: ToolCall, isExpanded: Bool = false) -> ToolCallRowPresentation {
        let durationText = toolCall.duration.map { String(format: "%.1fs", $0) }

        if toolCall.isPermissionRequest {
            return ToolCallRowPresentation(
                style: .permission,
                primaryText: "权限批准",
                secondaryText: toolCall.title ?? toolCall.kind.displayName,
                tertiaryText: toolCall.toolResultSummary,
                statusText: toolCall.statusDisplay,
                detailText: toolCall.terminalOutput,
                durationText: durationText,
                isExpanded: isExpanded
            )
        }

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
                statusText: managedStatus.map {
                    terminalStatusText(for: $0, executionMode: TerminalExecutionMode.parse(toolCall.terminalExecutionMode))
                } ?? toolCall.statusDisplay,
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
            let verifierVerdict = toolCall.verifierVerdictText
            let verifierSummary = toolCall.verifierSummary
            return ToolCallRowPresentation(
                style: .subagent,
                primaryText: toolCall.subagentAgentName ?? toolCall.title ?? toolCall.kind.displayName,
                secondaryText: verifierVerdict ?? toolCall.subagentTask,
                tertiaryText: verifierSummary ?? toolCall.subagentResultKind,
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

    private static func diffSummary(from diff: String) -> String {
        let inserted = diff.split(separator: "\n").filter { $0.hasPrefix("+") && !$0.hasPrefix("+++") }.count
        let removed = diff.split(separator: "\n").filter { $0.hasPrefix("-") && !$0.hasPrefix("---") }.count
        if inserted == 0 && removed == 0 { return "已修改" }
        return "\(max(inserted, removed)) 处变更"
    }

    private static func executionSummary(for toolCall: ToolCall) -> String? {
        if toolCall.status == .failed {
            return summaryLine(from: toolCall.terminalOutput) ?? "执行失败"
        }
        return summaryLine(from: toolCall.terminalOutput)
    }

    private static func managedExecutionSummary(
        for toolCall: ToolCall,
        status: TerminalTaskStatus?
    ) -> String? {
        if let interactionPhase = toolCall.terminalInteractionPhase.flatMap(TerminalInteractionPhase.init(rawValue:)) {
            switch interactionPhase {
            case .planning:
                return "规划交互"
            case .autoExecuting:
                return "执行交互计划"
            case .awaitingApproval:
                return "用户接管中"
            case .userTakeover:
                return "用户接管中"
            }
        }

        if let mode = TerminalExecutionMode.parse(toolCall.terminalExecutionMode) {
            switch mode {
            case .detached:
                return "后台任务"
            case .attached:
                return status == .waitingForInput ? "等待交互" : executionSummary(for: toolCall)
            }
        }

        return executionSummary(for: toolCall)
    }

    private static func managedTertiaryText(
        for toolCall: ToolCall,
        status: TerminalTaskStatus?
    ) -> String? {
        if let plannerSummary = toolCall.terminalPlannerSummary, !plannerSummary.isEmpty {
            return plannerSummary
        }

        if let promptSummary = toolCall.terminalPromptSummary, !promptSummary.isEmpty {
            return promptSummary
        }

        if let payloadRef = toolCall.toolPayloadRef, !payloadRef.isEmpty {
            return payloadRef
        }

        if status == .running, toolCall.terminalExecutionMode == TerminalExecutionMode.detached.rawValue {
            return summaryLine(from: toolCall.terminalOutput)
        }

        return nil
    }

    private static func terminalTaskStatus(from toolCall: ToolCall) -> TerminalTaskStatus? {
        TerminalTaskStatus.parse(toolCall.terminalTaskStatus)
    }

    private static func terminalStatusText(
        for status: TerminalTaskStatus,
        executionMode: TerminalExecutionMode?
    ) -> String {
        switch status {
        case .launching:
            return "启动中"
        case .running:
            if executionMode == .detached {
                return "后台运行中"
            }
            return "执行中"
        case .waitingForInput:
            return "等待输入"
        case .planningInteraction:
            return "规划中"
        case .awaitingUserApproval:
            return "用户接管"
        case .userTakeover:
            return "用户接管"
        case .completed:
            return "已完成"
        case .failed:
            return "失败"
        case .interrupted:
            return "已中断"
        case .timedOut:
            return "已超时"
        case .terminated:
            return "已终止"
        }
    }

    private static func askUserSummary(for toolCall: ToolCall) -> String? {
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

    private static func summaryLine(from text: String?) -> String? {
        guard let text else { return nil }
        return text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    }
}