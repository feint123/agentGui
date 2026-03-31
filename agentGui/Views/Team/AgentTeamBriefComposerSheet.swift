import SwiftUI
import SwiftData

struct AgentTeamBriefComposerRequest: Identifiable {
    let id = UUID()
    let sourceContext: NewSessionMenuAction.SourceContext?
    let draft: AgentTeamMissionBriefDraft

    init(sourceContext: NewSessionMenuAction.SourceContext?) {
        self.sourceContext = sourceContext
        if let sourceContext {
            self.draft = .prefilled(fromSourceContext: sourceContext)
        } else {
            self.draft = .prefilled(from: nil as Session?)
        }
    }
}

struct AgentTeamBriefComposerSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(ClaudeService.self) private var claudeService

    let sourceContext: NewSessionMenuAction.SourceContext?
    let onCancel: () -> Void
    let onSubmit: (AgentTeamMissionBriefDraft) -> Void

    @State private var draft: AgentTeamMissionBriefDraft
    @State private var extractionVM: BriefComposerExtractionViewModel?
    @State private var showAdvancedOptions = false
    @State private var warmupCoordinator = BriefComposerProviderWarmupCoordinator()

    init(
        sourceContext: NewSessionMenuAction.SourceContext?,
        initialDraft: AgentTeamMissionBriefDraft,
        onCancel: @escaping () -> Void,
        onSubmit: @escaping (AgentTeamMissionBriefDraft) -> Void
    ) {
        self.sourceContext = sourceContext
        self.onCancel = onCancel
        self.onSubmit = onSubmit
        _draft = State(initialValue: initialDraft)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            VStack(alignment: .leading, spacing: 6) {
                Text("创建 Team Mission Brief")
                    .font(.title3.weight(.semibold))

                Text(sourceSummary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("agentTeam.brief.sourceSummary")
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {

                    // MARK: 主输入框
                    VStack(alignment: .leading, spacing: 6) {
                        Text("任务描述")
                            .font(.headline)
                        TextEditor(text: $draft.rawInput)
                            .frame(minHeight: 120)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.secondary.opacity(0.18))
                            )
                            .accessibilityIdentifier("agentTeam.brief.rawInput")
                            .onChange(of: draft.rawInput) { _, _ in
                                extractionVM?.scheduleDebounceExtraction(draft: $draft)
                            }

                        HStack {
                            extractionStatusLabel
                            Spacer()
                            Button("解析 Brief") {
                                Task { @MainActor in
                                    var localDraft = draft
                                    await extractionVM?.triggerExtraction(draft: &localDraft)
                                    draft = localDraft
                                }
                            }
                            .disabled(draft.rawInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                      || draft.extractionState == .extracting)
                            .accessibilityIdentifier("agentTeam.brief.extractButton")
                        }
                    }

                    // MARK: 提取结果预览（仅在 done 后展示）
                    if draft.extractionState == .done {
                        extractionResultSection
                    }

                    // MARK: Provider 角色分配区
                    providerRoleSection

                    // MARK: 高级选项（默认折叠）
                    DisclosureGroup("高级选项", isExpanded: $showAdvancedOptions) {
                        VStack(alignment: .leading, spacing: 8) {
                            Stepper(value: $draft.maxActiveProviders, in: 1...6) {
                                Text("并发上限：\(draft.maxActiveProviders)")
                            }
                            .accessibilityIdentifier("agentTeam.brief.maxActiveProviders")

                            Picker("Mode", selection: $draft.mode) {
                                ForEach(AgentTeamMode.allCases, id: \.self) { mode in
                                    Text(mode.displayName).tag(mode)
                                }
                            }
                            .pickerStyle(.menu)
                            .accessibilityIdentifier("agentTeam.brief.mode")

                            Text("Initial Context Summary")
                                .font(.headline)
                            TextEditor(text: $draft.initialContextSummary)
                                .frame(minHeight: 80)
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.18)))
                                .accessibilityIdentifier("agentTeam.brief.contextSummary")
                        }
                        .padding(.top, 4)
                    }
                }
            }

            // Footer
            HStack {
                Spacer()
                Button("取消", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("agentTeam.brief.cancel")

                Button("创建 Team") {
                    onSubmit(draft)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(canSubmit == false)
                .accessibilityIdentifier("agentTeam.brief.submit")
            }
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 520, alignment: .topLeading)
        .accessibilityIdentifier("agentTeam.briefComposer")
        .onAppear {
            draft.reconcileProviderOptions(
                resolvedProviderOptions,
                sourceDefaultProviderID: sourceContext?.defaultExecutionProviderReference.persistedValue
            )
            setupExtractionVM()
        }
        .task(id: sourceContext?.sessionID ?? "") {
            let allOptions = resolvedProviderOptions
            await withTaskGroup(of: Void.self) { group in
                for option in allOptions where option.isEnabled {
                    let ref = ExecutionProviderReference.decodePersisted(option.id)
                    group.addTask { @MainActor in
                        await warmupCoordinator.warmup(
                            provider: ref,
                            claudeService: claudeService,
                            sourceSession: nil,
                            modelContext: modelContext
                        )
                    }
                }
            }
        }
        .onDisappear {
            extractionVM?.cancelDebounce()
        }
    }

    // MARK: - Provider 角色分配区

    private var providerRoleSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Team 成员与角色")
                .font(.headline)

            let options = resolvedProviderOptions
            if options.isEmpty {
                Text("未检测到启用的 Provider，将使用内置 Built-in。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(options, id: \.id) { option in
                    let ref = ExecutionProviderReference.decodePersisted(option.id)
                    ProviderRoleRowView(
                        providerName: option.title,
                        warmupState: warmupCoordinator.warmupState(for: ref),
                        assignment: assignmentBinding(for: ref),
                        modelOptions: warmupCoordinator.modelOptions(for: ref),
                        modeOptions: warmupCoordinator.modeOptions(for: ref)
                    )
                }
            }
        }
    }

    /// 从 roleAssignments 提供 Binding
    private func assignmentBinding(
        for provider: ExecutionProviderReference
    ) -> Binding<AgentTeamProviderRoleAssignment> {
        Binding(
            get: {
                self.draft.roleAssignments.first(where: { $0.providerReference == provider })
                    ?? AgentTeamProviderRoleAssignment(providerReference: provider)
            },
            set: { newValue in
                if let idx = self.draft.roleAssignments.firstIndex(where: { $0.providerReference == provider }) {
                    self.draft.roleAssignments[idx] = newValue
                } else {
                    self.draft.roleAssignments.append(newValue)
                }
            }
        )
    }

    // MARK: - Extraction Status Label

    @ViewBuilder
    private var extractionStatusLabel: some View {
        switch draft.extractionState {
        case .idle:
            EmptyView()
        case .extracting:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("正在解析…").font(.caption).foregroundStyle(.secondary)
            }
        case .done:
            Label("解析完成", systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(2)
        }
    }

    // MARK: - Extraction Result Section

    @ViewBuilder
    private var extractionResultSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("解析结果（可编辑）")
                .font(.headline)

            TextField("Objective", text: $draft.objective, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("agentTeam.brief.objective")

            Text("Constraints")
                .font(.subheadline.weight(.medium))
            TextEditor(text: $draft.constraintsText)
                .frame(minHeight: 72)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.18)))
                .accessibilityIdentifier("agentTeam.brief.constraints")

            Text("Acceptance Criteria")
                .font(.subheadline.weight(.medium))
            TextEditor(text: $draft.acceptanceCriteriaText)
                .frame(minHeight: 72)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.18)))
                .accessibilityIdentifier("agentTeam.brief.acceptance")
        }
    }

    // MARK: - Helpers

    private var canSubmit: Bool {
        let hasInput = draft.rawInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || draft.objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let hasConductor = draft.roleAssignments.contains(where: { $0.isConductor })
        return hasInput && hasConductor
    }

    private var sourceSummary: String {
        let sourceTitle = sourceContext?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if sourceTitle.isEmpty { return "独立 Team Mode 会话" }
        return "来源会话：\(sourceTitle)"
    }

    private var resolvedProviderOptions: [ExecutionOptionItem] {
        SettingsStore(modelContext: modelContext, persistenceCoordinator: nil)
            .defaultExecutionProviderOptions()
            .filter(\.isEnabled)
    }

    private func setupExtractionVM() {
        guard let service = claudeService.service else { return }
        let settings = AppSettings.getOrCreate(in: modelContext)
        extractionVM = BriefComposerExtractionViewModel(
            extractionService: BuiltInMissionBriefExtractionService(
                service: service,
                modelID: settings.selectedModel
            )
        )
    }
}

// MARK: - ProviderRoleRowView

private struct ProviderRoleRowView: View {
    let providerName: String
    let warmupState: BriefComposerProviderWarmupCoordinator.WarmupState
    @Binding var assignment: AgentTeamProviderRoleAssignment
    let modelOptions: [ExecutionOptionItem]
    let modeOptions: [ExecutionOptionItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                warmupStatusView
                Text(providerName)
                    .fontWeight(.medium)
                Spacer()
                ForEach(AgentTeamProviderRole.allCases, id: \.self) { role in
                    RoleChipButton(
                        label: role.displayLabel,
                        isSelected: assignment.roles.contains(role)
                    ) {
                        toggleRole(role)
                    }
                }
            }
            if case .ready = warmupState, !modelOptions.isEmpty {
                HStack(spacing: 12) {
                    if !modelOptions.isEmpty {
                        Picker("模型", selection: Binding(
                            get: { assignment.selectedModelID ?? "" },
                            set: { assignment.selectedModelID = $0.isEmpty ? nil : $0 }
                        )) {
                            Text("默认").tag("")
                            ForEach(modelOptions) { opt in
                                Text(opt.title).tag(opt.id)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 160)
                    }
                    if !modeOptions.isEmpty {
                        Picker("模式", selection: Binding(
                            get: { assignment.selectedModeID ?? "" },
                            set: { assignment.selectedModeID = $0.isEmpty ? nil : $0 }
                        )) {
                            Text("默认").tag("")
                            ForEach(modeOptions) { opt in
                                Text(opt.title).tag(opt.id)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 160)
                    }
                }
                .font(.caption)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.2))
        )
    }

    @ViewBuilder
    private var warmupStatusView: some View {
        switch warmupState {
        case .idle:    Color.clear.frame(width: 10, height: 10)
        case .warming: ProgressView().controlSize(.mini).frame(width: 10, height: 10)
        case .ready:   Circle().fill(.green).frame(width: 8, height: 8)
        case .failed:  Circle().fill(.secondary).frame(width: 8, height: 8)
        }
    }

    private func toggleRole(_ role: AgentTeamProviderRole) {
        var copy = assignment
        if copy.roles.contains(role) {
            copy.roles.remove(role)
        } else {
            copy.roles.insert(role)
        }
        assignment = copy
    }
}

private struct RoleChipButton: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.caption.weight(isSelected ? .semibold : .regular))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(isSelected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

private extension AgentTeamProviderRole {
    var displayLabel: String {
        switch self {
        case .conductor: "指挥"
        case .worker:    "执行"
        case .reviewer:  "审核"
        }
    }
}
