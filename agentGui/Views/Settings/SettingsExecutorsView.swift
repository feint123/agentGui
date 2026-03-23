import SwiftUI

struct SettingsExecutorsView: View {
    @Bindable var store: SettingsStore

    var body: some View {
        Form {
            Section("默认执行器") {
                ExecutionOptionPicker(
                    title: "对话默认执行器",
                    options: ConversationExecutionProviderID.optionItems(
                        copilotAvailabilityStatus: store.gitHubCopilotCLIAvailabilityStatus,
                        openCodeAvailabilityStatus: store.openCodeCLIAvailabilityStatus,
                        claudeAdapterAvailabilityStatus: store.claudeAdapterCLIAvailabilityStatus
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
                ExecutionOptionPicker(
                    title: "默认审批模式",
                    options: GitHubCopilotCLIApprovalModeOption.allCases.map {
                        ExecutionOptionItem(id: $0.rawValue, title: $0.title)
                    },
                    selection: store.persistedSettingsBinding(
                        get: { GitHubCopilotCLIApprovalModeOption.resolved(from: store.settings.builtInDefaultApprovalMode).rawValue },
                        userMessage: "内置执行器审批模式未成功保存",
                        set: { store.settings.builtInDefaultApprovalMode = GitHubCopilotCLIApprovalModeOption.resolved(from: $0).rawValue }
                    ),
                    accessibilityIdentifier: "settings.executors.builtInApprovalModePicker"
                )
            } header: {
                Text("内置执行器")
            } footer: {
                Text("default approvals 会审批 Bash 和 Web 操作；bypass approvals 不做操作审批。")
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
                    options: ACPCLIConfiguration.copilotModelOptions(
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
                HStack {
                    Text(store.gitHubCopilotCLIAvailabilityStatus.summaryText)
                        .foregroundStyle(statusColor(for: store.gitHubCopilotCLIAvailabilityStatus))
                        .accessibilityIdentifier("settings.executors.copilotStatus")
                    Spacer()
                    Button("重新检测") {
                        Task {
                            await store.refreshGitHubCopilotCLIAvailabilityStatus()
                        }
                    }
                    .accessibilityIdentifier("settings.executors.refreshButton")
                }
            } header: {
                Text("GitHub Copilot CLI")
            } footer: {
                Text("配置项已统一为可执行文件、默认模型和默认审批模式。")
            }

            Section {
                TextField("OpenCode 可执行文件路径", text: store.persistedOpenCodeCLIConfigurationBinding(
                    get: { $0.executablePath },
                    userMessage: "OpenCode CLI 可执行文件路径未成功保存",
                    set: { $0.executablePath = $1 }
                ))
                .accessibilityIdentifier("settings.executors.openCodePathField")

                ExecutionOptionPicker(
                    title: "默认模型",
                    options: AppSettings.availableModelOptions(inheritingTitle: "跟随 OpenCode 默认"),
                    selection: store.persistedOpenCodeCLIConfigurationBinding(
                        get: { $0.defaultModel },
                        userMessage: "OpenCode CLI 默认模型未成功保存",
                        set: { $0.defaultModel = $1 }
                    ),
                    accessibilityIdentifier: "settings.executors.openCodeModelField"
                )

                ExecutionOptionPicker(
                    title: "默认审批模式",
                    options: GitHubCopilotCLIApprovalModeOption.allCases.map {
                        ExecutionOptionItem(id: $0.rawValue, title: $0.title)
                    },
                    selection: store.persistedOpenCodeCLIConfigurationBinding(
                        get: { GitHubCopilotCLIApprovalModeOption.resolved(from: $0.defaultApprovalMode).rawValue },
                        userMessage: "OpenCode CLI 审批模式未成功保存",
                        set: { $0.defaultApprovalMode = GitHubCopilotCLIApprovalModeOption.resolved(from: $1).rawValue }
                    ),
                    accessibilityIdentifier: "settings.executors.openCodeApprovalModePicker"
                )
                HStack {
                    Text(store.openCodeCLIAvailabilityStatus.summaryText)
                        .foregroundStyle(statusColor(for: store.openCodeCLIAvailabilityStatus))
                        .accessibilityIdentifier("settings.executors.openCodeStatus")
                    Spacer()
                    Button("重新检测") {
                        Task {
                            await store.refreshOpenCodeCLIAvailabilityStatus()
                        }
                    }
                    .accessibilityIdentifier("settings.executors.refreshOpenCodeButton")
                }
            } header: {
                Text("OpenCode CLI")
            } footer: {
                Text("配置项已统一为可执行文件、默认模型和默认审批模式。")
            }

            Section {
                TextField("Claude adapter 可执行文件路径", text: store.persistedClaudeAdapterCLIConfigurationBinding(
                    get: { $0.executablePath },
                    userMessage: "Claude adapter CLI 可执行文件路径未成功保存",
                    set: { $0.executablePath = $1 }
                ))
                .accessibilityIdentifier("settings.executors.claudeAdapterPathField")

                ExecutionOptionPicker(
                    title: "默认模型",
                    options: AppSettings.availableModelOptions(inheritingTitle: "跟随 Claude Code 默认"),
                    selection: store.persistedClaudeAdapterCLIConfigurationBinding(
                        get: { $0.defaultModel },
                        userMessage: "Claude adapter CLI 默认模型未成功保存",
                        set: { $0.defaultModel = $1 }
                    ),
                    accessibilityIdentifier: "settings.executors.claudeAdapterModelField"
                )

                ExecutionOptionPicker(
                    title: "默认审批模式",
                    options: GitHubCopilotCLIApprovalModeOption.allCases.map {
                        ExecutionOptionItem(id: $0.rawValue, title: $0.title)
                    },
                    selection: store.persistedClaudeAdapterCLIConfigurationBinding(
                        get: { GitHubCopilotCLIApprovalModeOption.resolved(from: $0.defaultApprovalMode).rawValue },
                        userMessage: "Claude adapter CLI 审批模式未成功保存",
                        set: { $0.defaultApprovalMode = GitHubCopilotCLIApprovalModeOption.resolved(from: $1).rawValue }
                    ),
                    accessibilityIdentifier: "settings.executors.claudeAdapterApprovalModePicker"
                )
                HStack {
                    Text(store.claudeAdapterCLIAvailabilityStatus.summaryText)
                        .foregroundStyle(statusColor(for: store.claudeAdapterCLIAvailabilityStatus))
                        .accessibilityIdentifier("settings.executors.claudeAdapterStatus")
                    Spacer()
                    Button("重新检测") {
                        Task {
                            await store.refreshClaudeAdapterCLIAvailabilityStatus()
                        }
                    }
                    .accessibilityIdentifier("settings.executors.refreshClaudeAdapterButton")
                }
            } header: {
                Text("Claude Code Adapter")
            } footer: {
                Text("使用 ACP adapter CLI 连接 Claude Code。")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("执行器")
        .task {
            await store.refreshGitHubCopilotCLIAvailabilityStatus()
            await store.refreshOpenCodeCLIAvailabilityStatus()
            await store.refreshClaudeAdapterCLIAvailabilityStatus()
        }
    }

    private func statusColor(for status: ACPCLIAvailabilityStatus) -> Color {
        switch status.kind {
        case .available:
            return .green
        case .failed:
            return .red
        case .notInstalled, .notAuthenticated, .unknown:
            return .secondary
        }
    }
}