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
        let baseSections: [ToolCallDetailSection]
        switch row.style {
        case .read:
            baseSections = readSections(for: toolCall, row: row)
        case .edit:
            baseSections = editSections(for: toolCall)
        case .execute:
            baseSections = executeSections(for: toolCall, row: row)
        case .search, .fetch:
            baseSections = searchSections(for: row)
        case .askUser:
            baseSections = askUserSections(for: row)
        case .subagent:
            baseSections = subagentSections(for: toolCall, row: row)
        case .other:
            baseSections = fallbackSections(for: row)
        }

        return baseSections + runtimeMetadataSections(for: toolCall)
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
        if let resultKind = toolCall.subagentResultKind, !resultKind.isEmpty {
            sections.append(.init(label: "结果类型", text: resultKind, monospaced: true, maxHeight: 80))
        }
        if sections.isEmpty {
            return fallbackSections(for: row)
        }
        return sections
    }

    private static func fallbackSections(for row: ToolCallRowPresentation) -> [ToolCallDetailSection] {
        guard let output = row.detailText, !output.isEmpty else { return [] }
        return [.init(label: "详情", text: output, monospaced: false, maxHeight: 160)]
    }

    private static func runtimeMetadataSections(for toolCall: ToolCall) -> [ToolCallDetailSection] {
        var sections: [ToolCallDetailSection] = []

        if let definitionID = toolCall.toolDefinitionID, !definitionID.isEmpty {
            sections.append(.init(label: "工具定义 ID", text: definitionID, monospaced: true, maxHeight: 80))
        }

        if let schemaVersion = toolCall.toolSchemaVersion {
            sections.append(.init(label: "Schema 版本", text: String(schemaVersion), monospaced: true, maxHeight: 80))
        }

        if let exposureSource = toolCall.toolExposureSource, !exposureSource.isEmpty {
            sections.append(.init(label: "暴露来源", text: exposureSource, monospaced: false, maxHeight: 80))
        }

        if let executionContext = toolCall.toolExecutionContext, !executionContext.isEmpty {
            sections.append(.init(label: "执行上下文", text: executionContext, monospaced: false, maxHeight: 80))
        }

        if let payloadRef = toolCall.toolPayloadRef, !payloadRef.isEmpty {
            sections.append(.init(label: "大载荷引用", text: payloadRef, monospaced: true, maxHeight: 80))
        }

        if let summary = toolCall.toolResultSummary, !summary.isEmpty {
            sections.append(.init(label: "结果摘要", text: summary, monospaced: false, maxHeight: 100))
        }

        if let rawChars = toolCall.toolResultRawChars {
            sections.append(.init(label: "原始大小", text: "\(rawChars) chars", monospaced: true, maxHeight: 80))
        }

        if let injectedChars = toolCall.toolResultInjectedChars {
            sections.append(.init(label: "注入大小", text: "\(injectedChars) chars", monospaced: true, maxHeight: 80))
        }

        if let rawChars = toolCall.toolResultRawChars,
           let injectedChars = toolCall.toolResultInjectedChars,
           rawChars > injectedChars {
            sections.append(.init(label: "预算节省", text: "节省 \(rawChars - injectedChars) chars", monospaced: true, maxHeight: 80))
        }

        if let mode = toolCall.toolResultInjectionMode, !mode.isEmpty {
            sections.append(.init(label: "注入模式", text: mode, monospaced: true, maxHeight: 80))
        }

        if let readCount = toolCall.toolPayloadReadCount {
            sections.append(.init(label: "读取次数", text: String(readCount), monospaced: true, maxHeight: 80))
        }

        if let lastRange = toolCall.toolPayloadLastReadRange, !lastRange.isEmpty {
            sections.append(.init(label: "最近读取区间", text: lastRange, monospaced: true, maxHeight: 80))
        }

        if let snapshotID = toolCall.memoryRuntimeSnapshotID, !snapshotID.isEmpty {
            sections.append(.init(label: "记忆上下文快照", text: snapshotID, monospaced: true, maxHeight: 80))
        }

        if let profiles = toolCall.memoryRuntimeProfiles, !profiles.isEmpty {
            sections.append(.init(label: "记忆 Profiles", text: profiles.joined(separator: "\n"), monospaced: false, maxHeight: 120))
        }

        if let layers = toolCall.memoryRuntimeLayers, !layers.isEmpty {
            sections.append(.init(label: "记忆 Layers", text: layers.joined(separator: "\n"), monospaced: false, maxHeight: 120))
        }

        if let warnings = toolCall.memoryRuntimeWarnings, !warnings.isEmpty {
            sections.append(.init(label: "记忆 Warnings", text: warnings.joined(separator: "\n"), monospaced: false, maxHeight: 120))
        }

        if toolCall.memoryBackgroundConsolidationQueued == true {
            sections.append(.init(label: "记忆后台处理", text: "本轮已触发后台巩固 / 写入队列", monospaced: false, maxHeight: 80))
        }

        if let conflictIDs = toolCall.memoryConflictRecordIDs, !conflictIDs.isEmpty {
            sections.append(.init(label: "记忆冲突记录", text: conflictIDs.joined(separator: "\n"), monospaced: true, maxHeight: 120))
        }

        if let confirmationIDs = toolCall.memoryConfirmationCandidateIDs, !confirmationIDs.isEmpty {
            sections.append(.init(label: "待确认写入", text: confirmationIDs.joined(separator: "\n"), monospaced: true, maxHeight: 120))
        }

        return sections
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

    @State private var snapshot: MemoryRuntimeSnapshot?
    @State private var snapshotLoadError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let snapshotID = toolCall.memoryRuntimeSnapshotID, !snapshotID.isEmpty {
                Button("查看记忆上下文快照") {
                    openSnapshot(snapshotID: snapshotID)
                }
                .buttonStyle(.bordered)
                .font(.caption)
            }

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
        .sheet(item: $snapshot) { snapshot in
            NavigationStack {
                MemoryRuntimeSnapshotPanel(viewModel: MemoryRuntimeSnapshotViewModel(snapshot: snapshot))
            }
        }
        .alert("加载快照失败", isPresented: Binding(get: { snapshotLoadError != nil }, set: { if !$0 { snapshotLoadError = nil } })) {
            Button("确定") { snapshotLoadError = nil }
        } message: {
            Text(snapshotLoadError ?? "")
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

    private func openSnapshot(snapshotID: String) {
        do {
            let store = MemoryRuntimeSnapshotStore()
            guard let loaded = try store.snapshot(id: snapshotID) else {
                snapshotLoadError = "未找到快照：\(snapshotID)"
                return
            }
            snapshot = loaded
        } catch {
            snapshotLoadError = error.localizedDescription
        }
    }
}