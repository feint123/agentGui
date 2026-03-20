import Foundation
import SwiftData
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
    static func showsPrimaryTerminalScreen(for toolCall: ToolCall, row: ToolCallRowPresentation) -> Bool {
        guard row.style == .execute,
              toolCall.kind == .execute,
              let taskId = toolCall.terminalTaskId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !taskId.isEmpty,
                            let executionMode = TerminalExecutionMode.parse(toolCall.terminalExecutionMode) else {
            return false
        }

        return executionMode == .attached
    }

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

        let isUserTakeoverActive = toolCall.terminalUserTakeoverActive
            || TerminalTaskStatus.parse(toolCall.terminalTaskStatus) == .userTakeover

        if let interactionPhase = toolCall.terminalInteractionPhase
            .flatMap(TerminalInteractionPhase.init(rawValue:))
            .map(interactionPhaseText) {
            sections.append(.init(label: "交互阶段", text: interactionPhase, monospaced: false, lineLimit: 2))
        }

        if let plannerSummary = toolCall.terminalPlannerSummary?.trimmingCharacters(in: .whitespacesAndNewlines), !plannerSummary.isEmpty {
            sections.append(.init(label: "规划摘要", text: plannerSummary, monospaced: false, lineLimit: 4))
        }

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

        if isUserTakeoverActive {
            sections.append(
                .init(
                    label: "接管说明",
                    text: "当前终端任务已进入用户接管。可使用下方输入区直接发送文本，或使用方向键、Space、Enter、Ctrl-C 继续完成 TUI 导航。",
                    monospaced: false,
                    lineLimit: 4
                )
            )
            sections.append(
                .init(
                    label: "快捷键",
                    text: "↑ / ↓: 移动焦点\nSpace: 切换勾选\nEnter: 确认当前界面\nCtrl-C: 取消当前命令",
                    monospaced: true,
                    lineLimit: 6
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
        let modeText = executionModeLabel(from: toolCall.terminalExecutionMode)
        let statusText = toolCall.terminalTaskStatus
            .flatMap(TerminalTaskStatus.parse)
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

    private static func executionModeLabel(from rawValue: String?) -> String? {
        switch rawValue {
        case "interactive":
            return "交互任务"
        case "background":
            return "后台任务"
        default:
            return TerminalExecutionMode.parse(rawValue).map(executionModeText)
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

    private static func executionResultSummary(for toolCall: ToolCall, row: ToolCallRowPresentation) -> String? {
        let summary = toolCall.toolResultSummary ?? summaryLine(from: row.detailText)
        guard let summary else { return nil }

        if summary == executionStateSummary(for: toolCall) {
            return nil
        }

        return summary
    }

    private static func interactionPhaseText(_ phase: TerminalInteractionPhase) -> String {
        switch phase {
        case .planning:
            return "规划中"
        case .autoExecuting:
            return "自动执行"
        case .awaitingApproval:
            return "用户接管"
        case .userTakeover:
            return "用户接管"
        }
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
    @Environment(ClaudeService.self) private var claudeService
    @Environment(\.modelContext) private var modelContext

    let toolCall: ToolCall
    let row: ToolCallRowPresentation

    @State private var terminalInputDraft = ""
    @State private var isSendingTerminalInput = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if ToolCallDetailPresentation.showsPrimaryTerminalScreen(for: toolCall, row: row) {
                ManagedTerminalScreenDetailView(toolCall: toolCall)
            }

            if showsManualTakeoverInput {
                manualTakeoverComposer
            }
        }
        .accessibilityIdentifier("toolDetail.panel")
    }

    private var showsManualTakeoverInput: Bool {
        guard toolCall.kind == .execute else { return false }
        guard let status = TerminalTaskStatus.parse(toolCall.terminalTaskStatus) else {
            return toolCall.terminalUserTakeoverActive
        }
        return toolCall.terminalUserTakeoverActive || status == .userTakeover
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

    private var manualTakeoverComposer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("终端输入")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            HStack(spacing: 6) {
                manualActionButton("↑", actions: [.key(.up)])
                manualActionButton("↓", actions: [.key(.down)])
                manualActionButton("Space", actions: [.key(.space)])
                manualActionButton("Enter", actions: [.key(.enter)])
                manualActionButton("Ctrl-C", actions: [.signal(.interrupt)])
            }

            HStack(spacing: 8) {
                TextField("输入要发送到当前终端任务的文本", text: $terminalInputDraft)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isSendingTerminalInput)

                Button("发送") {
                    sendTextInput(appendEnter: false)
                }
                .buttonStyle(.bordered)
                .disabled(isSendingTerminalInput || terminalInputDraft.isEmpty)

                Button("发送并回车") {
                    sendTextInput(appendEnter: true)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSendingTerminalInput || terminalInputDraft.isEmpty)
            }
        }
        .padding(8)
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func manualActionButton(_ title: String, actions: [TerminalInteractionAction]) -> some View {
        Button(title) {
            Task {
                isSendingTerminalInput = true
                await claudeService.applyManagedTerminalActions(
                    toolCall: toolCall,
                    actions: actions,
                    modelContext: modelContext
                )
                isSendingTerminalInput = false
            }
        }
        .buttonStyle(.bordered)
        .disabled(isSendingTerminalInput)
    }

    private func sendTextInput(appendEnter: Bool) {
        let text = terminalInputDraft
        guard !text.isEmpty else { return }
        terminalInputDraft = ""

        let payload = appendEnter ? text + "\n" : text
        Task {
            isSendingTerminalInput = true
            await claudeService.applyManagedTerminalActions(
                toolCall: toolCall,
                actions: [.text(payload)],
                modelContext: modelContext
            )
            isSendingTerminalInput = false
        }
    }

}