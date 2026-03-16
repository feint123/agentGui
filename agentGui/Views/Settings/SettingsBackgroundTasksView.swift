import SwiftData
import SwiftUI

struct SettingsBackgroundTasksView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(PersistenceCoordinator.self) private var persistenceCoordinator

    @Bindable var store: SettingsStore

    @State private var viewModel: BackgroundTaskManagementViewModel?

    private let notificationCenter = NotificationCenter.default

    var body: some View {
        Group {
            if let viewModel {
                content(viewModel: viewModel)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("后台任务")
        .onAppear(perform: configureViewModel)
    }

    private func configureViewModel() {
        if let viewModel {
            viewModel.refresh()
            return
        }

        self.viewModel = BackgroundTaskManagementViewModel(
            modelContext: modelContext,
            persistenceCoordinator: persistenceCoordinator
        )
    }

    private func content(viewModel: BackgroundTaskManagementViewModel) -> some View {
        Form {
            schedulerSection
            overviewSection(viewModel: viewModel)
            tasksSection(viewModel: viewModel)
        }
        .formStyle(.grouped)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                NavigationLink(value: BackgroundTaskEditorRoute.newTask) {
                    Label("新建任务", systemImage: "plus")
                }
                .disabled(!store.settings.backgroundAgentEnabled || viewModel.sessionOptions.isEmpty)
                .accessibilityIdentifier("settings.background.newTaskButton")
            }
        }
        .navigationDestination(for: BackgroundTaskEditorRoute.self) { route in
            BackgroundTaskEditorView(
                store: store,
                viewModel: viewModel,
                route: route
            )
        }
    }

    private var schedulerSection: some View {
        Section {
            Toggle(
                "启用后台 Agent 调度",
                isOn: persistedSchedulingBinding(
                    get: { store.settings.backgroundAgentEnabled },
                    userMessage: "后台调度设置未成功保存",
                    set: { store.settings.backgroundAgentEnabled = $0 }
                )
            )

            Picker(
                "默认 QoS",
                selection: persistedSchedulingBinding(
                    get: { store.settings.backgroundAgentDefaultQoS },
                    userMessage: "后台任务 QoS 设置未成功保存",
                    set: { store.settings.backgroundAgentDefaultQoS = $0 }
                )
            ) {
                Text("Utility").tag("utility")
                Text("Background").tag("background")
            }

            Stepper(
                value: persistedSchedulingBinding(
                    get: { store.settings.backgroundAgentMaximumConcurrentRuns },
                    userMessage: "后台任务并发设置未成功保存",
                    set: { store.settings.backgroundAgentMaximumConcurrentRuns = max(1, $0) }
                ),
                in: 1...4
            ) {
                settingsValueRow("最大并发", value: "\(store.settings.backgroundAgentMaximumConcurrentRuns)")
            }

            Toggle(
                "默认要求外接电源",
                isOn: persistedSchedulingBinding(
                    get: { store.settings.backgroundAgentRequiresExternalPower },
                    userMessage: "后台任务电源要求未成功保存",
                    set: { store.settings.backgroundAgentRequiresExternalPower = $0 }
                )
            )

            Toggle(
                "允许后台使用网络工具",
                isOn: persistedSchedulingBinding(
                    get: { store.settings.backgroundAgentAllowNetworkTools },
                    userMessage: "后台任务网络工具设置未成功保存",
                    set: { store.settings.backgroundAgentAllowNetworkTools = $0 }
                )
            )
        } header: {
            Text("调度设置")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text("Utility：适合希望较快完成，但不需要立刻打断前台体验的任务。系统通常会更积极地安排它。")
                Text("Background：更偏向节能和合批执行，允许系统为了电量与资源把任务再往后延。")
                Text("当前后台调度会向系统注册 interval、tolerance、repeats 和 QoS，并在真正执行前检查启用状态、冷却期、系统 defer、同任务并发、工作区、网络和外接电源条件。")
            }
        }
    }

    private func overviewSection(viewModel: BackgroundTaskManagementViewModel) -> some View {
        Section {
            settingsValueRow("全部任务", value: "\(viewModel.tasks.count)")
            settingsValueRow("启用中", value: "\(viewModel.tasks.filter(\.isEnabled).count)")
            settingsValueRow("需关注", value: "\(viewModel.tasks.filter { viewModel.requiresAttention($0) }.count)")
        } header: {
            Text("任务概览")
        }
    }

    private func tasksSection(viewModel: BackgroundTaskManagementViewModel) -> some View {
        Section {
            TextField("搜索任务、提示词或会话", text: Binding(
                get: { viewModel.searchText },
                set: { viewModel.searchText = $0 }
            ))

            Picker("列表筛选", selection: Binding(
                get: { viewModel.listFilter },
                set: { viewModel.listFilter = $0 }
            )) {
                ForEach(BackgroundTaskManagementViewModel.ListFilter.allCases, id: \.self) { filter in
                    Text(filter.title).tag(filter)
                }
            }

            if viewModel.tasks.isEmpty {
                Text(viewModel.sessionOptions.isEmpty ? "先创建一个会话，再新增后台任务。" : "还没有后台任务，点击右上角“新建任务”。")
                    .foregroundStyle(.secondary)
            } else if viewModel.visibleTasks.isEmpty {
                Text("没有匹配的任务。")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.visibleTasks) { task in
                    NavigationLink(value: BackgroundTaskEditorRoute.task(task.id)) {
                        BackgroundTaskListRow(
                            title: task.title,
                            subtitle: viewModel.taskListSubtitle(for: task),
                            nextRun: viewModel.nextRunPresentation(for: task).value,
                            statusText: task.isEnabled ? (viewModel.requiresAttention(task) ? "需关注" : "启用") : "停用",
                            statusColor: task.isEnabled ? (viewModel.requiresAttention(task) ? .orange : .green) : .secondary
                        )
                    }
                }
            }
        } header: {
            Text("定时任务")
        } footer: {
            Text("任务详情、策略调整和运行记录在下一级页面查看。预计执行时间按当前本地时区估算。")
        }
    }

    private func settingsValueRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private func persistedSchedulingBinding<Value>(
        get: @escaping () -> Value,
        userMessage: String,
        set: @escaping (Value) -> Void
    ) -> Binding<Value> {
        Binding(
            get: get,
            set: { newValue in
                let didPersist = store.persistSettingsMutation(userMessage) {
                    set(newValue)
                }
                if didPersist {
                    BackgroundTaskSchedulingNotifications.postRefresh(on: notificationCenter)
                }
            }
        )
    }
}

private enum BackgroundTaskEditorRoute: Hashable {
    case newTask
    case task(UUID)
}

private struct BackgroundTaskListRow: View {
    let title: String
    let subtitle: String
    let nextRun: String
    let statusText: String
    let statusColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer(minLength: 12)
                Text(statusText)
                    .foregroundStyle(statusColor)
            }
            HStack {
                Text(subtitle)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Text(nextRun)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            .font(.caption)
        }
    }
}

private struct BackgroundTaskEditorView: View {
    @Environment(\.dismiss) private var dismiss

    @Bindable var store: SettingsStore
    @Bindable var viewModel: BackgroundTaskManagementViewModel

    let route: BackgroundTaskEditorRoute

    @State private var editorMessage: String?

    var body: some View {
        Form {
            if let editorMessage, !editorMessage.isEmpty {
                Section {
                    Label(editorMessage, systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                }
            }

            if viewModel.sessionOptions.isEmpty {
                Section {
                    Text("后台任务必须把结果回写到已有会话。先创建一个会话，再回来配置任务。")
                        .foregroundStyle(.secondary)
                }
            } else {
                overviewSection
                basicsSection
                workspaceSection
                scheduleSection
                executionSection
                toolsSection
                recentRunsSection
                currentStatusSection
            }
        }
        .formStyle(.grouped)
        .navigationTitle(viewModel.editorTitle(for: viewModel.selectedTask))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                if viewModel.selectedTask != nil {
                    Button(role: .destructive, action: deleteTask) {
                        Label("删除", systemImage: "trash")
                            .labelStyle(.iconOnly)
                    }
                    .help("删除任务")
                    .accessibilityLabel("删除任务")
                        .accessibilityIdentifier("settings.background.deleteTaskButton")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button(action: saveTask) {
                    Label("保存", systemImage: "checkmark")
                        .labelStyle(.iconOnly)
                }
                    .help("保存任务")
                    .accessibilityLabel("保存任务")
                    .buttonStyle(.borderedProminent)
                    .disabled(!store.settings.backgroundAgentEnabled || viewModel.sessionOptions.isEmpty)
                    .accessibilityIdentifier("settings.background.saveTaskButton")
            }
        }
        .onAppear(perform: loadRoute)
    }

    private var selectedTask: BackgroundAgentTask? {
        viewModel.selectedTask
    }

    private var nextRunPresentation: BackgroundTaskManagementViewModel.NextRunPresentation {
        guard let selectedTask else {
            return BackgroundTaskManagementViewModel.NextRunPresentation(
                value: "暂不安排",
                detail: "保存后会按当前本地时区估算"
            )
        }
        return viewModel.nextRunPresentation(for: selectedTask)
    }

    private var overviewSection: some View {
        Section {
            HStack {
                Text("当前状态")
                Spacer()
                if let selectedTask {
                    Text(statusLabel(for: selectedTask))
                        .foregroundStyle(statusColor(for: selectedTask))
                } else {
                    Text("未保存")
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Text("预计下次执行")
                Spacer()
                Text(nextRunPresentation.value)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            Text(nextRunPresentation.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("概览")
        }
    }

    private var basicsSection: some View {
        Section {
            Toggle("任务启用", isOn: $viewModel.draftIsEnabled)
                .disabled(!store.settings.backgroundAgentEnabled)
            
            TextField("任务标题", text: $viewModel.draftTitle)
           
            Picker("结果写回会话", selection: Binding(
                get: { viewModel.draftSessionID ?? "" },
                set: { newValue in
                    viewModel.draftSessionID = newValue.isEmpty ? nil : newValue
                }
            )) {
                ForEach(viewModel.sessionOptions) { session in
                    Text(session.title).tag(session.id)
                }
            }
        

            if let session = viewModel.sessionOption(for: viewModel.draftSessionID) {
                Text(session.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
    
            TextField("任务提示词", text: $viewModel.draftPrompt, axis: .vertical)
                .lineLimit(5...10)
        
            TextField("系统提示补充（可选）", text: $viewModel.draftSystemPromptOverride, axis: .vertical)
                .lineLimit(3...6)
            
        } header: {
            Text("基础信息")
        }
    }

    private var workspaceSection: some View {
        Section {
            TextField("工作区路径（可选）", text: $viewModel.draftWorkspacePath)
            TextField("工作目录（可选）", text: $viewModel.draftWorkingDirectoryPath)
            TextField("模型覆盖（可选）", text: $viewModel.draftModelIDOverride)
        } header: {
            Text("工作区与模型")
        }
    }

    private var scheduleSection: some View {
        Section {
            Picker("执行间隔", selection: Binding(
                get: { viewModel.selectedScheduleIntervalPresetID },
                set: { viewModel.applyScheduleIntervalPreset(id: $0) }
            )) {
                ForEach(viewModel.scheduleIntervalPresetOptions) { preset in
                    Text(preset.title).tag(preset.id)
                }
            }

            Text(viewModel.selectedScheduleIntervalPresetDetail)
                .font(.caption)
                .foregroundStyle(.secondary)

            Stepper(value: Binding(
                get: {
                    min(
                        Int(viewModel.draftSchedulePolicy.toleranceSeconds / 60),
                        viewModel.toleranceUpperBoundMinutes(for: viewModel.draftSchedulePolicy)
                    )
                },
                set: {
                    let upperBound = viewModel.toleranceUpperBoundMinutes(for: viewModel.draftSchedulePolicy)
                    viewModel.draftSchedulePolicy.toleranceSeconds = TimeInterval(min(max(0, $0), upperBound) * 60)
                    viewModel.draftSchedulePolicy.toleranceSeconds = viewModel.draftSchedulePolicy.sanitizedToleranceSeconds
                }
            ), in: 0...max(0, viewModel.toleranceUpperBoundMinutes(for: viewModel.draftSchedulePolicy)), step: 1) {
                HStack {
                    Text("调度容差")
                    Spacer()
                    Text("\(Int(viewModel.draftSchedulePolicy.toleranceSeconds / 60)) 分钟")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            HStack {
                Text("允许星期")
                Spacer()
                Text(viewModel.allowedWeekdaysSummary(for: viewModel.draftSchedulePolicy))
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 7), spacing: 8) {
                ForEach(viewModel.weekdayOptions) { option in
                    Button {
                        viewModel.setAllowedWeekday(option.weekday, enabled: !viewModel.isAllowedWeekday(option.weekday))
                    } label: {
                        Text(option.shortTitle)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(viewModel.isAllowedWeekday(option.weekday) ? .accentColor : .secondary)
                    .help(option.fullTitle)
                }
            }

            Toggle(
                "限制执行时段",
                isOn: Binding(
                    get: { viewModel.draftSchedulePolicy.allowedHourRange != nil },
                    set: { viewModel.setAllowedHourRangeEnabled($0) }
                )
            )

            if viewModel.draftSchedulePolicy.allowedHourRange != nil {
                Picker("开始时间", selection: Binding(
                    get: { viewModel.draftSchedulePolicy.sanitizedAllowedHourRange?.lowerBound ?? 9 },
                    set: { viewModel.setAllowedHourStart($0) }
                )) {
                    ForEach(0..<24, id: \.self) { hour in
                        Text("\(hour):00").tag(hour)
                    }
                }

                Picker("结束时间", selection: Binding(
                    get: { viewModel.draftSchedulePolicy.sanitizedAllowedHourRange?.upperBound ?? 18 },
                    set: { viewModel.setAllowedHourEnd($0) }
                )) {
                    ForEach(0..<24, id: \.self) { hour in
                        Text("\(hour):00").tag(hour)
                    }
                }

                HStack {
                    Text("允许时段")
                    Spacer()
                    Text(viewModel.allowedHourRangeSummary(for: viewModel.draftSchedulePolicy))
                        .foregroundStyle(.secondary)
                }
            }

            Toggle("重复执行", isOn: $viewModel.draftSchedulePolicy.repeats)
            Toggle("要求网络", isOn: $viewModel.draftSchedulePolicy.requiresNetwork)

            Picker("任务 QoS", selection: $viewModel.draftSchedulePolicy.qualityOfService) {
                Text("Utility").tag(BackgroundTaskQualityOfService.utility)
                Text("Background").tag(BackgroundTaskQualityOfService.background)
            }
        } header: {
            Text("调度策略")
        } footer: {
            Text("执行间隔改为日常预设档位。允许星期留空表示每天都可执行，允许时段关闭表示全天可执行；两者同时设置时，任务需要同时满足这两个条件。预计执行时间会结合当前间隔、冷却期和允许时间窗口，以本地时区估算。")
        }
    }

    private var executionSection: some View {
        Section {
            Stepper(value: $viewModel.draftExecutionPolicy.maxTurns, in: 1...20) {
                HStack {
                    Text("最大轮次")
                    Spacer()
                    Text("\(viewModel.draftExecutionPolicy.maxTurns)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            Stepper(value: Binding(
                get: { Int(viewModel.draftExecutionPolicy.maxExecutionSeconds) },
                set: { viewModel.draftExecutionPolicy.maxExecutionSeconds = TimeInterval(max(60, $0)) }
            ), in: 60...900, step: 30) {
                HStack {
                    Text("最大执行时长")
                    Spacer()
                    Text("\(Int(viewModel.draftExecutionPolicy.maxExecutionSeconds)) 秒")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            Picker("结果投递", selection: $viewModel.draftExecutionPolicy.resultDeliveryMode) {
                Text("写回会话").tag(BackgroundTaskResultDeliveryMode.sessionMessages)
                Text("仅摘要").tag(BackgroundTaskResultDeliveryMode.summaryOnly)
            }

            Toggle("附加用户可见消息", isOn: $viewModel.draftExecutionPolicy.appendUserVisibleMessage)
        } header: {
            Text("执行预算")
        }
    }

    private var toolsSection: some View {
        Section {
            Picker("信任等级", selection: Binding(
                get: { viewModel.draftToolGrantPolicy.trustTier },
                set: { viewModel.setDraftTrustTier($0) }
            )) {
                Text("Observe Only").tag(BackgroundTaskTrustTier.observeOnly)
                Text("Maintain").tag(BackgroundTaskTrustTier.maintain)
                Text("Act Limited").tag(BackgroundTaskTrustTier.actLimited)
            }

            Text(viewModel.trustTierDescription(for: viewModel.draftToolGrantPolicy.trustTier))
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Toggle("允许文件写入", isOn: $viewModel.draftToolGrantPolicy.allowFileWrite)
                    .disabled(!viewModel.isDraftToolOptionAvailable(.allowFileWrite))
                if let explanation = viewModel.draftToolRestrictionExplanation(for: .allowFileWrite) {
                    Text(explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Toggle("允许 Bash", isOn: $viewModel.draftToolGrantPolicy.allowBash)
                    .disabled(!viewModel.isDraftToolOptionAvailable(.allowBash))
                if let explanation = viewModel.draftToolRestrictionExplanation(for: .allowBash) {
                    Text(explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Toggle("允许修改记忆", isOn: $viewModel.draftToolGrantPolicy.allowMemoryMutation)
                    .disabled(!viewModel.isDraftToolOptionAvailable(.allowMemoryMutation))
                if let explanation = viewModel.draftToolRestrictionExplanation(for: .allowMemoryMutation) {
                    Text(explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Toggle("允许联网工具", isOn: $viewModel.draftToolGrantPolicy.allowNetworkAccess)
        } header: {
            Text("工具权限")
        } footer: {
            Text("信任等级会约束下方工具上限。降低等级时，超出该等级允许范围的工具开关会自动关闭。")
        }
    }

    private var recentRunsSection: some View {
        Section {
            if viewModel.recentRuns.isEmpty {
                Text("这个任务还没有运行记录。")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(viewModel.recentRuns.prefix(8))) { run in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(statusLabel(for: run.status))
                                .foregroundStyle(statusColor(for: run.status))
                            Spacer()
                            Text(run.createdAt, formatter: Self.runDateFormatter)
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)

                        if let resultSummary = run.resultSummary, !resultSummary.isEmpty {
                            Text(resultSummary)
                        }

                        if let reason = run.deferReason ?? run.skipReason, !reason.isEmpty {
                            Text(reason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text("最近运行")
        }
    }

    @ViewBuilder
    private var currentStatusSection: some View {
        if let selectedTask {
            Section {
                HStack {
                    Text("最近摘要")
                    Spacer()
                    Text(selectedTask.lastResultSummary ?? "暂无")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
                HStack {
                    Text("连续失败")
                    Spacer()
                    Text("\(selectedTask.consecutiveFailureCount)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                HStack {
                    Text("冷却到")
                    Spacer()
                    Text(selectedTask.cooldownUntil.map { Self.runDateFormatter.string(from: $0) } ?? "未进入冷却")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
            } header: {
                Text("当前状态")
            }
        }
    }

    private func loadRoute() {
        switch route {
        case .newTask:
            viewModel.makeNewTask()
        case let .task(taskID):
            if let task = viewModel.tasks.first(where: { $0.id == taskID }) {
                viewModel.selectTask(task)
            }
        }
        editorMessage = nil
    }

    private func saveTask() {
        do {
            try viewModel.saveDraft()
            editorMessage = "后台任务已保存。"
        } catch {
            editorMessage = validationMessage(for: error)
        }
    }

    private func deleteTask() {
        do {
            try viewModel.deleteSelectedTask()
            dismiss()
        } catch {
            editorMessage = "删除后台任务失败。"
        }
    }

    private func statusLabel(for task: BackgroundAgentTask) -> String {
        if !task.isEnabled {
            return "停用"
        }
        if task.cooldownUntil != nil {
            return "冷却中"
        }
        if task.consecutiveFailureCount > 0 {
            return "需关注"
        }
        return "启用"
    }

    private func statusColor(for task: BackgroundAgentTask) -> Color {
        if !task.isEnabled {
            return .secondary
        }
        if task.cooldownUntil != nil || task.consecutiveFailureCount > 0 {
            return .orange
        }
        return .green
    }

    private func statusLabel(for status: BackgroundTaskRunStatus) -> String {
        switch status {
        case .triggered:
            return "已触发"
        case .running:
            return "运行中"
        case .completed:
            return "已完成"
        case .failed:
            return "失败"
        case .deferred:
            return "已延期"
        case .skipped:
            return "已跳过"
        case .interrupted:
            return "已中断"
        }
    }

    private func statusColor(for status: BackgroundTaskRunStatus) -> Color {
        switch status {
        case .completed:
            return .green
        case .failed, .interrupted:
            return .red
        case .deferred, .skipped:
            return .orange
        case .running:
            return .blue
        case .triggered:
            return .secondary
        }
    }

    private func validationMessage(for error: Error) -> String {
        guard let validationError = error as? BackgroundTaskManagementViewModel.ValidationError else {
            return "后台任务保存失败。"
        }

        switch validationError {
        case .missingTitle:
            return "请输入任务标题。"
        case .missingSession:
            return "请选择结果写回的会话。"
        case .missingPrompt:
            return "请输入任务提示词。"
        }
    }

    private static let runDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
