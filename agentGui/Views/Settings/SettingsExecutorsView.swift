import SwiftUI

struct SettingsExecutorsView: View {
    @Bindable var store: SettingsStore

    var body: some View {
        Form {
            Section("默认执行器") {
                ExecutionOptionPicker(
                    title: "对话默认执行器",
                    options: ConversationExecutionProviderID.optionItems(
                        copilotAvailabilityStatus: store.gitHubCopilotCLIAvailabilityStatus
                    ),
                    selection: store.persistedSettingsBinding(
                        get: { store.settings.defaultExecutionProviderID },
                        userMessage: "默认执行器设置未成功保存",
                        set: { store.settings.defaultExecutionProviderID = $0 }
                    ),
                    accessibilityIdentifier: "settings.executors.defaultProviderPicker"
                )
            }

            Section {
                TextField("Copilot 可执行文件路径", text: store.persistedGitHubCopilotCLIConfigurationBinding(
                    get: { $0.executablePath },
                    userMessage: "Copilot CLI 可执行文件路径未成功保存",
                    set: { $0.executablePath = $1 }
                ))
                .accessibilityIdentifier("settings.executors.copilotPathField")

                ExecutionOptionPicker(
                    title: "默认模型",
                    options: GitHubCopilotCLIConfiguration.modelOptions(
                        inheritingTitle: "跟随 GitHub Copilot CLI 默认",
                        including: store.settings.githubCopilotCLIConfiguration.defaultModel
                    ),
                    selection: store.persistedGitHubCopilotCLIConfigurationBinding(
                        get: { $0.defaultModel },
                        userMessage: "Copilot CLI 默认模型未成功保存",
                        set: { $0.defaultModel = $1 }
                    ),
                    accessibilityIdentifier: "settings.executors.copilotModelField"
                )

                ExecutionOptionPicker(
                    title: "默认审批模式",
                    options: GitHubCopilotCLIApprovalModeOption.allCases.map {
                        ExecutionOptionItem(id: $0.rawValue, title: $0.title)
                    },
                    selection: store.persistedGitHubCopilotCLIConfigurationBinding(
                        get: { $0.normalizedApprovalMode.rawValue },
                        userMessage: "Copilot CLI 审批模式未成功保存",
                        set: { $0.defaultApprovalMode = GitHubCopilotCLIApprovalModeOption.resolved(from: $1).rawValue }
                    ),
                    accessibilityIdentifier: "settings.executors.copilotApprovalModePicker"
                )

                TextField("自定义 Agent 名称（可选）", text: store.persistedGitHubCopilotCLIConfigurationBinding(
                    get: { $0.customAgentName },
                    userMessage: "Copilot CLI Agent 名称未成功保存",
                    set: { $0.customAgentName = $1 }
                ))
                .accessibilityIdentifier("settings.executors.copilotAgentField")

                Toggle("使用 ACP stdio 模式", isOn: store.persistedGitHubCopilotCLIConfigurationBinding(
                    get: { $0.useACPStdIO },
                    userMessage: "Copilot CLI ACP 设置未成功保存",
                    set: { $0.useACPStdIO = $1 }
                ))
                .disabled(true)

                Text(store.gitHubCopilotCLIAvailabilityStatus.summaryText)
                    .foregroundStyle(statusColor)
                    .accessibilityIdentifier("settings.executors.copilotStatus")

                Button("重新检测") {
                    Task {
                        await store.refreshGitHubCopilotCLIAvailabilityStatus()
                    }
                }
                .accessibilityIdentifier("settings.executors.refreshButton")
            } header: {
                Text("GitHub Copilot CLI")
            } footer: {
                Text("第一版仅支持 copilot --acp --stdio。")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("执行器")
        .task {
            await store.refreshGitHubCopilotCLIAvailabilityStatus()
        }
    }

    private var statusColor: Color {
        switch store.gitHubCopilotCLIAvailabilityStatus.kind {
        case .available:
            return .green
        case .failed:
            return .red
        case .notInstalled, .notAuthenticated, .unknown:
            return .secondary
        }
    }
}