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

                    // MARK: Provider 选择
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Providers")
                            .font(.headline)

                        if resolvedProviderOptions.isEmpty {
                            Text("当前没有可用 provider。请先在设置中启用至少一个执行器。")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(resolvedProviderOptions) { option in
                                Toggle(isOn: binding(for: option.id)) {
                                    Text(option.title)
                                }
                                .toggleStyle(.checkbox)
                                .accessibilityIdentifier("agentTeam.brief.provider.\(option.id)")
                            }

                            Picker("Conductor", selection: $draft.preferredConductorID) {
                                ForEach(selectedProviderOptions) { option in
                                    Text(option.title).tag(option.id)
                                }
                            }
                            .pickerStyle(.menu)
                            .disabled(selectedProviderOptions.isEmpty)
                            .accessibilityIdentifier("agentTeam.brief.preferredConductor")

                            Picker("Reviewer", selection: $draft.preferredReviewerID) {
                                Text("不指定").tag("")
                                ForEach(reviewerOptions) { option in
                                    Text(option.title).tag(option.id)
                                }
                            }
                            .pickerStyle(.menu)
                            .disabled(selectedProviderOptions.isEmpty)
                            .accessibilityIdentifier("agentTeam.brief.preferredReviewer")
                        }
                    }

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
        .onDisappear {
            extractionVM?.cancelDebounce()
        }
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
        let hasProvider = draft.eligibleProviderIDs.isEmpty == false
            && draft.preferredConductorID.isEmpty == false
        return hasInput && hasProvider
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

    private var selectedProviderOptions: [ExecutionOptionItem] {
        resolvedProviderOptions.filter { draft.eligibleProviderIDs.contains($0.id) }
    }

    private var reviewerOptions: [ExecutionOptionItem] {
        selectedProviderOptions.filter { $0.id != draft.preferredConductorID }
    }

    private func binding(for providerID: String) -> Binding<Bool> {
        Binding(
            get: { draft.eligibleProviderIDs.contains(providerID) },
            set: { isSelected in
                let currentlySelected = draft.eligibleProviderIDs.contains(providerID)
                guard currentlySelected != isSelected else { return }
                draft.toggleEligibleProvider(providerID)
                draft.reconcileProviderOptions(
                    resolvedProviderOptions,
                    sourceDefaultProviderID: sourceContext?.defaultExecutionProviderReference.persistedValue
                )
            }
        )
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
