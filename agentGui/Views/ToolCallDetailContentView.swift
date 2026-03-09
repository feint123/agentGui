import SwiftUI

struct ToolCallDetailSection: Identifiable, Equatable {
    let id: String
    let label: String
    let text: String
    let monospaced: Bool
    let lineLimit: Int?
    let maxHeight: CGFloat?

    init(
        label: String,
        text: String,
        monospaced: Bool,
        lineLimit: Int? = nil,
        maxHeight: CGFloat? = nil
    ) {
        self.id = label + ":" + text.prefix(32)
        self.label = label
        self.text = text
        self.monospaced = monospaced
        self.lineLimit = lineLimit
        self.maxHeight = maxHeight
    }
}

enum ToolCallDetailPresentation {
    static func sections(for toolCall: ToolCall, row: ToolCallRowPresentation) -> [ToolCallDetailSection] {
        switch row.style {
        case .read:
            return readSections(for: toolCall, row: row)
        case .edit:
            return editSections(for: toolCall)
        case .execute:
            return executeSections(for: toolCall, row: row)
        case .search, .fetch:
            return searchSections(for: row)
        case .askUser:
            return askUserSections(for: row)
        case .subagent, .other:
            return fallbackSections(for: row)
        }
    }

    private static func readSections(for toolCall: ToolCall, row: ToolCallRowPresentation) -> [ToolCallDetailSection] {
        var sections: [ToolCallDetailSection] = []
        if let path = toolCall.filePath {
            sections.append(.init(label: "路径", text: path, monospaced: false))
        }
        if let output = row.detailText, !output.isEmpty {
            sections.append(.init(label: "摘要", text: output, monospaced: false, lineLimit: 6))
        }
        return sections
    }

    private static func editSections(for toolCall: ToolCall) -> [ToolCallDetailSection] {
        var sections: [ToolCallDetailSection] = []
        if let path = toolCall.filePath {
            sections.append(.init(label: "路径", text: path, monospaced: false))
        }
        if let diff = toolCall.diffContent, !diff.isEmpty {
            sections.append(.init(label: "变更", text: diff, monospaced: true, maxHeight: 180))
        }
        return sections
    }

    private static func executeSections(for toolCall: ToolCall, row: ToolCallRowPresentation) -> [ToolCallDetailSection] {
        var sections: [ToolCallDetailSection] = [
            .init(label: "命令", text: toolCall.title ?? toolCall.kind.displayName, monospaced: true)
        ]

        if let taskSummary = managedTaskSummary(for: toolCall) {
            sections.append(.init(label: "任务状态", text: taskSummary, monospaced: false))
        }

        if let promptSummary = toolCall.terminalPromptSummary, !promptSummary.isEmpty {
            sections.append(.init(label: "交互摘要", text: promptSummary, monospaced: false, lineLimit: 4))
        }

        if let agentActions = decodeAgentActions(from: toolCall.terminalAgentActionsJSON) {
            sections.append(.init(label: "Agent操作", text: agentActions, monospaced: false, maxHeight: 140))
        }

        if let output = row.detailText, !output.isEmpty {
            sections.append(
                .init(
                    label: toolCall.status == .failed ? "错误输出" : "输出",
                    text: output,
                    monospaced: true,
                    maxHeight: 180
                )
            )
        }

        return sections
    }

    private static func searchSections(for row: ToolCallRowPresentation) -> [ToolCallDetailSection] {
        var sections: [ToolCallDetailSection] = []
        if let tertiary = row.tertiaryText, !tertiary.isEmpty {
            sections.append(.init(label: "目标", text: tertiary, monospaced: false))
        }
        if let output = row.detailText, !output.isEmpty {
            sections.append(.init(label: "结果", text: output, monospaced: false, maxHeight: 160))
        }
        return sections
    }

    private static func askUserSections(for row: ToolCallRowPresentation) -> [ToolCallDetailSection] {
        guard let output = row.detailText, !output.isEmpty else { return [] }
        return [.init(label: "回答记录", text: output, monospaced: false, maxHeight: 160)]
    }

    private static func fallbackSections(for row: ToolCallRowPresentation) -> [ToolCallDetailSection] {
        guard let output = row.detailText, !output.isEmpty else { return [] }
        return [.init(label: "详情", text: output, monospaced: false, maxHeight: 160)]
    }

    private static func managedTaskSummary(for toolCall: ToolCall) -> String? {
        let modeText = toolCall.terminalExecutionMode
            .flatMap(TerminalExecutionMode.init(rawValue:))
            .map(executionModeText)
        let statusText = toolCall.terminalTaskStatus
            .flatMap(TerminalTaskStatus.init(rawValue:))
            .map(taskStatusText)

        let summary = [modeText, statusText, toolCall.terminalTaskId]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")

        return summary.isEmpty ? nil : summary
    }

    private static func executionModeText(_ mode: TerminalExecutionMode) -> String {
        switch mode {
        case .auto:
            return "自动模式"
        case .foreground:
            return "前台任务"
        case .background:
            return "后台任务"
        case .interactive:
            return "交互任务"
        }
    }

    private static func taskStatusText(_ status: TerminalTaskStatus) -> String {
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

    private static func decodeAgentActions(from json: String?) -> String? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        guard let events = try? JSONDecoder().decode([TerminalTaskEvent].self, from: data) else { return nil }

        let summaries = events.map(\ .summary).filter { !$0.isEmpty }
        guard !summaries.isEmpty else { return nil }
        return summaries.joined(separator: "\n")
    }
}

struct ToolCallDetailContentView: View {
    let toolCall: ToolCall
    let row: ToolCallRowPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(ToolCallDetailPresentation.sections(for: toolCall, row: row)) { section in
                detailTextBlock(
                    label: section.label,
                    text: section.text,
                    monospaced: section.monospaced,
                    lineLimit: section.lineLimit,
                    maxHeight: section.maxHeight
                )
            }
        }
    }

    private func detailTextBlock(
        label: String,
        text: String,
        monospaced: Bool,
        lineLimit: Int? = nil,
        maxHeight: CGFloat? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            ScrollView(.vertical, showsIndicators: maxHeight != nil) {
                Text(text)
                    .font(monospaced ? .system(.caption2, design: .monospaced) : .caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(lineLimit)
                    .padding(8)
            }
            .frame(maxHeight: maxHeight)
            .background(Color.primary.opacity(0.03))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}