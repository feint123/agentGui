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
            return editSections(for: toolCall, row: row)
        case .execute:
            return executeSections(for: toolCall, row: row)
        case .search, .fetch:
            return searchSections(for: row)
        case .askUser:
            return askUserSections(for: row)
        case .subagent:
            return subagentSections(for: toolCall, row: row)
        case .other:
            return fallbackSections(for: row)
        }
    }

    private static func readSections(for toolCall: ToolCall, row: ToolCallRowPresentation) -> [ToolCallDetailSection] {
        var sections: [ToolCallDetailSection] = []
        if let path = toolCall.filePath {
            sections.append(.init(label: "路径", text: path, monospaced: false))
        }
        if let summary = detailSummaryText(for: row), !summary.isEmpty {
            sections.append(.init(label: "结果摘要", text: summary, monospaced: false, lineLimit: 4))
        }
        return sections
    }

    private static func editSections(for toolCall: ToolCall, row: ToolCallRowPresentation) -> [ToolCallDetailSection] {
        var sections: [ToolCallDetailSection] = []
        if let path = toolCall.filePath {
            sections.append(.init(label: "路径", text: path, monospaced: false))
        }
        if let summary = row.secondaryText, !summary.isEmpty {
            sections.append(.init(label: "变更摘要", text: summary, monospaced: false, lineLimit: 3))
        }
        return sections
    }

    private static func executeSections(for toolCall: ToolCall, row: ToolCallRowPresentation) -> [ToolCallDetailSection] {
        var sections: [ToolCallDetailSection] = [
            .init(label: "命令", text: toolCall.title ?? toolCall.kind.displayName, monospaced: true)
        ]

        if let stateSummary = executionStateSummary(for: toolCall) {
            sections.append(.init(label: "当前状态", text: stateSummary, monospaced: false, lineLimit: 4))
        }

        if let transcriptPath = toolCall.terminalTranscriptPath?.trimmingCharacters(in: .whitespacesAndNewlines), !transcriptPath.isEmpty {
            sections.append(.init(label: "Transcript", text: transcriptPath, monospaced: true, lineLimit: 2))
        }

        if let completionReason = toolCall.terminalCompletionReason?.trimmingCharacters(in: .whitespacesAndNewlines), !completionReason.isEmpty {
            sections.append(.init(label: "完成原因", text: completionReason, monospaced: false, lineLimit: 2))
        }

        if let summary = executionResultSummary(for: toolCall, row: row) {
            sections.append(
                .init(
                    label: toolCall.status == .failed ? "错误摘要" : "结果摘要",
                    text: summary,
                    monospaced: false,
                    lineLimit: 4
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
        if let summary = detailSummaryText(for: row), !summary.isEmpty {
            sections.append(.init(label: "结果摘要", text: summary, monospaced: false, lineLimit: 4))
        }
        return sections
    }

    private static func askUserSections(for row: ToolCallRowPresentation) -> [ToolCallDetailSection] {
        guard let answer = row.secondaryText, !answer.isEmpty else { return [] }
        return [.init(label: "用户选择", text: answer, monospaced: false, lineLimit: 4)]
    }

    private static func subagentSections(for toolCall: ToolCall, row: ToolCallRowPresentation) -> [ToolCallDetailSection] {
        var sections: [ToolCallDetailSection] = []
        if let task = toolCall.subagentTask, !task.isEmpty {
            sections.append(.init(label: "任务", text: task, monospaced: false, maxHeight: 100))
        }
        if let verdict = toolCall.verifierVerdictText {
            sections.append(.init(label: "验证结果", text: verdict, monospaced: false, maxHeight: 80))
        }
        if let summary = toolCall.verifierSummary {
            sections.append(.init(label: "验证摘要", text: summary, monospaced: false, maxHeight: 120))
        }
        if let residualRisk = verifierMetadataValue("verificationResidualRisk", toolCall: toolCall) {
            sections.append(.init(label: "残余风险", text: residualRisk, monospaced: false))
        }
        if let nextProbe = verifierMetadataValue("verificationRecommendedProbe", toolCall: toolCall) {
            sections.append(.init(label: "下一探针", text: nextProbe, monospaced: false, maxHeight: 120))
        }
        if let openClaims = verifierMetadataValue("verificationOpenClaimsCount", toolCall: toolCall) {
            sections.append(.init(label: "未关闭声明", text: openClaims, monospaced: false))
        }
        if let contradictedClaims = verifierMetadataValue("verificationContradictedClaimsCount", toolCall: toolCall) {
            sections.append(.init(label: "已反驳声明", text: contradictedClaims, monospaced: false))
        }
        if sections.isEmpty {
            return fallbackSections(for: row)
        }
        return sections
    }

    private static func verifierMetadataValue(_ key: String, toolCall: ToolCall) -> String? {
        guard let value = toolCall.subagentMessageMetadata?[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func fallbackSections(for row: ToolCallRowPresentation) -> [ToolCallDetailSection] {
        guard let summary = detailSummaryText(for: row), !summary.isEmpty else { return [] }
        return [.init(label: "结果摘要", text: summary, monospaced: false, lineLimit: 4)]
    }

    private static func executionStateSummary(for toolCall: ToolCall) -> String? {
        let modeText = toolCall.terminalExecutionMode
            .flatMap(TerminalExecutionMode.init(rawValue:))
            .map(executionModeText)
        let statusText = toolCall.terminalTaskStatus
            .flatMap(TerminalTaskStatus.init(rawValue:))
            .map(taskStatusText)

        let summary = [modeText, statusText]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")

        let promptSummary = toolCall.terminalPromptSummary?.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = [summary.isEmpty ? nil : summary, promptSummary]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        return lines.isEmpty ? nil : lines
    }

    private static func executionModeText(_ mode: TerminalExecutionMode) -> String {
        switch mode {
        case .attached:
            return "附着任务"
        case .detached:
            return "后台任务"
        }
    }

    private static func taskStatusText(_ status: TerminalTaskStatus) -> String {
        switch status {
        case .launching:
            return "启动中"
        case .running:
            return "执行中"
        case .waitingForInput:
            return "等待输入"
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

    private static func executionResultSummary(for toolCall: ToolCall, row: ToolCallRowPresentation) -> String? {
        let summary = toolCall.toolResultSummary ?? summaryLine(from: row.detailText)
        guard let summary else { return nil }

        if summary == executionStateSummary(for: toolCall) {
            return nil
        }

        return summary
    }

    private static func detailSummaryText(for row: ToolCallRowPresentation) -> String? {
        if let secondary = row.secondaryText?.trimmingCharacters(in: .whitespacesAndNewlines), !secondary.isEmpty {
            return secondary
        }

        return summaryLine(from: row.detailText)
    }

    private static func summaryLine(from text: String?) -> String? {
        guard let text else { return nil }
        return text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
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
        .accessibilityIdentifier("toolDetail.panel")
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