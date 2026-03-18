import SwiftUI

struct SettingsChannelsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(PersistenceCoordinator.self) private var persistenceCoordinator
    @State private var viewModel: ChannelSettingsViewModel?
    @State private var connectionStatusStore = FeishuChannelConnectionStatusStore.shared

    var body: some View {
        Group {
            if let viewModel {
                Form {
                    Section {
                        Toggle("启用飞书渠道", isOn: feishuBinding(for: viewModel, keyPath: \.feishuEnabled))
                            .accessibilityIdentifier("settings.channels.feishuEnabled")
                        TextField("显示名称", text: feishuBinding(for: viewModel, keyPath: \.feishuDisplayName))
                            .accessibilityIdentifier("settings.channels.feishuDisplayName")
                        TextField("App ID", text: feishuBinding(for: viewModel, keyPath: \.feishuAppID))
                            .accessibilityIdentifier("settings.channels.feishuAppID")
                        SecureField("App Secret", text: feishuBinding(for: viewModel, keyPath: \.feishuAppSecret))
                            .accessibilityIdentifier("settings.channels.feishuAppSecret")
                        Picker("默认发送格式", selection: feishuBinding(for: viewModel, keyPath: \.feishuMessageFormat)) {
                            ForEach(FeishuMessageFormat.allCases, id: \.self) { format in
                                Text(displayName(for: format)).tag(format)
                            }
                        }
                        .accessibilityIdentifier("settings.channels.feishuMessageFormat")

                        LabeledContent("配置状态", value: viewModel.connectionStatusText)
                            .accessibilityIdentifier("settings.channels.configurationStatus")
                        LabeledContent("运行状态", value: viewModel.runtimeConnectionStatusText)
                            .accessibilityIdentifier("settings.channels.runtimeStatus")

                        if let lastRuntimeErrorText = viewModel.lastRuntimeErrorText,
                           !lastRuntimeErrorText.isEmpty {
                            Text(lastRuntimeErrorText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .accessibilityIdentifier("settings.channels.lastRuntimeError")
                        }

                        if let handshakeDiagnosticsText = viewModel.handshakeDiagnosticsText,
                           !handshakeDiagnosticsText.isEmpty {
                            Text(handshakeDiagnosticsText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .accessibilityIdentifier("settings.channels.handshakeDiagnostics")
                        }
                    } header: {
                        Text("飞书")
                    } footer: {
                        Text("飞书凭证通过独立凭证存储管理，不写入普通 AppSettings 字段。")
                    }

                    ToolPermissionSectionView(
                        policy: authorizationBinding(for: viewModel),
                        headerTitle: "所有渠道的工具权限",
                        footerText: "这里的权限会统一作用到所有渠道。渠道仍会继承全局工具总开关，再叠加这里的主体授权限制。"
                    )
                }
                .formStyle(.grouped)
                .navigationTitle("渠道")
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            if viewModel == nil {
                viewModel = ChannelSettingsViewModel(
                    modelContext: modelContext,
                    persistenceCoordinator: persistenceCoordinator,
                    connectionStatusStore: connectionStatusStore
                )
            }
        }
    }

    private func feishuBinding<Value>(for viewModel: ChannelSettingsViewModel, keyPath: ReferenceWritableKeyPath<ChannelSettingsViewModel, Value>) -> Binding<Value> {
        Binding(
            get: { viewModel[keyPath: keyPath] },
            set: {
                viewModel[keyPath: keyPath] = $0
                try? viewModel.saveFeishuSettings()
            }
        )
    }

    private func authorizationBinding(for viewModel: ChannelSettingsViewModel) -> Binding<ToolAuthorizationPolicy> {
        Binding(
            get: { viewModel.authorizationPolicy },
            set: {
                viewModel.authorizationPolicy = $0
                try? viewModel.saveAuthorizationPolicy()
            }
        )
    }

    private func displayName(for format: FeishuMessageFormat) -> String {
        switch format {
        case .text:
            return "文本消息"
        case .post:
            return "Post 富文本"
        case .interactive:
            return "卡片消息"
        }
    }
}