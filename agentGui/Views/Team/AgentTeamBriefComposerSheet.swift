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

    let sourceContext: NewSessionMenuAction.SourceContext?
    let onCancel: () -> Void
    let onSubmit: (AgentTeamMissionBriefDraft) -> Void

    @State private var draft: AgentTeamMissionBriefDraft

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
                    TextField("Objective", text: $draft.objective, axis: .vertical)
                        .lineLimit(2...4)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("agentTeam.brief.objective")

                    Text("Constraints")
                        .font(.headline)
                    TextEditor(text: $draft.constraintsText)
                        .frame(minHeight: 92)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.18)))
                        .accessibilityIdentifier("agentTeam.brief.constraints")

                    Text("Acceptance Criteria")
                        .font(.headline)
                    TextEditor(text: $draft.acceptanceCriteriaText)
                        .frame(minHeight: 92)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.18)))
                        .accessibilityIdentifier("agentTeam.brief.acceptance")

                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Mode")
                                .font(.headline)
                            Picker("Mode", selection: $draft.mode) {
                                ForEach(AgentTeamMode.allCases, id: \.self) { mode in
                                    Text(mode.displayName).tag(mode)
                                }
                            }
                            .pickerStyle(.menu)
                            .accessibilityIdentifier("agentTeam.brief.mode")
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Budget")
                                .font(.headline)
                            Stepper(value: $draft.maxActiveProviders, in: 1...6) {
                                Text("并发上限：\(draft.maxActiveProviders)")
                            }
                            .accessibilityIdentifier("agentTeam.brief.maxActiveProviders")
                        }
                    }

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

                    Text("Initial Context Summary")
                        .font(.headline)
                    TextEditor(text: $draft.initialContextSummary)
                        .frame(minHeight: 120)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.18)))
                        .accessibilityIdentifier("agentTeam.brief.contextSummary")
                }
            }

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
        .frame(minWidth: 640, minHeight: 560, alignment: .topLeading)
        .accessibilityIdentifier("agentTeam.briefComposer")
        .onAppear {
            draft.reconcileProviderOptions(
                resolvedProviderOptions,
                sourceDefaultProviderID: sourceContext?.defaultExecutionProviderReference.persistedValue
            )
        }
    }

    private var canSubmit: Bool {
        draft.objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            && draft.eligibleProviderIDs.isEmpty == false
            && draft.preferredConductorID.isEmpty == false
    }

    private var sourceSummary: String {
        let sourceTitle = sourceContext?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if sourceTitle.isEmpty {
            return "独立 Team Mode 会话"
        }
        return "来源会话：\(sourceTitle)"
    }

    private var resolvedProviderOptions: [ExecutionOptionItem] {
        SettingsStore(modelContext: modelContext, persistenceCoordinator: nil)
            .defaultExecutionProviderOptions()
            .filter(\ .isEnabled)
    }

    private var selectedProviderOptions: [ExecutionOptionItem] {
        resolvedProviderOptions.filter { draft.eligibleProviderIDs.contains($0.id) }
    }

    private var reviewerOptions: [ExecutionOptionItem] {
        selectedProviderOptions.filter { $0.id != draft.preferredConductorID }
    }

    private func binding(for providerID: String) -> Binding<Bool> {
        Binding(
            get: {
                draft.eligibleProviderIDs.contains(providerID)
            },
            set: { isSelected in
                let currentlySelected = draft.eligibleProviderIDs.contains(providerID)
                guard currentlySelected != isSelected else {
                    return
                }

                draft.toggleEligibleProvider(providerID)
                draft.reconcileProviderOptions(
                    resolvedProviderOptions,
                    sourceDefaultProviderID: sourceContext?.defaultExecutionProviderReference.persistedValue
                )
            }
        )
    }
}