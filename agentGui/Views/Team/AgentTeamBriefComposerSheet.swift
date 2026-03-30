import SwiftUI

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
                                Text("执行交付").tag(AgentTeamMode.executionDelivery)
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
                            TextField("Token Budget", text: $draft.tokenBudgetText)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityIdentifier("agentTeam.brief.tokenBudget")
                            TextField("Cost Budget", text: $draft.costBudgetText)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityIdentifier("agentTeam.brief.costBudget")
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
    }

    private var canSubmit: Bool {
        draft.objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private var sourceSummary: String {
        let sourceTitle = sourceContext?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if sourceTitle.isEmpty {
            return "独立 Team Mode 会话"
        }
        return "来源会话：\(sourceTitle)"
    }
}