import SwiftUI

struct SettingsExecutorsView: View {
    @Environment(ClaudeService.self) private var claudeService
    @Bindable var store: SettingsStore

    var body: some View {
        Form {
            Section("默认执行器") {
                ExecutionOptionPicker(
                    title: "对话默认执行器",
                    options: store.defaultExecutionProviderOptions(),
                    selection: store.defaultExecutionProviderSelectionBinding(),
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

            ACPProviderListSection(
                profiles: store.acpProviderProfiles
            )
        }
        .formStyle(.grouped)
        .navigationTitle("执行器")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                NavigationLink(value: ACPProviderEditorRoute.newProvider) {
                    Label("新增 Provider", systemImage: "plus")
                }
                .accessibilityIdentifier("settings.executors.addProviderButton")
            }
        }
        .navigationDestination(for: ACPProviderEditorRoute.self) { route in
            ACPProviderEditorScreen(store: store, route: route, claudeService: claudeService)
        }
        .task {
            try? store.reloadACPProviderProfiles(refreshing: claudeService)
        }
    }
}

enum ACPProviderEditorRoute: Hashable {
    case newProvider
    case provider(UUID)
}

private struct ACPProviderEditorScreen: View {
    let store: SettingsStore
    let route: ACPProviderEditorRoute
    let claudeService: ClaudeService

    @State private var viewModel: ACPProviderSettingsEditorViewModel

    init(store: SettingsStore, route: ACPProviderEditorRoute, claudeService: ClaudeService) {
        self.store = store
        self.route = route
        self.claudeService = claudeService

        switch route {
        case .newProvider:
            _viewModel = State(initialValue: store.makeACPProviderEditorViewModel())
        case .provider(let profileID):
            _viewModel = State(initialValue: store.makeACPProviderEditorViewModel(profileID: profileID))
        }
    }

    var body: some View {
        ACPProviderEditorView(
            viewModel: viewModel,
            onSaved: {
                try? store.reloadACPProviderProfiles(refreshing: claudeService)
            },
            onDelete: {
                _ = store.deleteACPProvider(profileID: viewModel.id)
                try? store.reloadACPProviderProfiles(refreshing: claudeService)
            }
        )
    }
}