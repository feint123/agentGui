import SwiftUI

struct SettingsChannelsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(PersistenceCoordinator.self) private var persistenceCoordinator
    @State private var viewModel: ChannelSettingsViewModel?
    @State private var connectionStatusStore = FeishuChannelConnectionStatusStore.shared
    @State private var isSaved = false

    var body: some View {
        Group {
            if let viewModel {
                Form {
                    Section {
                        Toggle("启用飞书渠道", isOn: binding(for: viewModel, keyPath: \.feishuEnabled))
                            .accessibilityIdentifier("settings.channels.feishuEnabled")
                        TextField("显示名称", text: binding(for: viewModel, keyPath: \.feishuDisplayName))
                            .accessibilityIdentifier("settings.channels.feishuDisplayName")
                        TextField("App ID", text: binding(for: viewModel, keyPath: \.feishuAppID))
                            .accessibilityIdentifier("settings.channels.feishuAppID")
                        SecureField("App Secret", text: binding(for: viewModel, keyPath: \.feishuAppSecret))
                            .accessibilityIdentifier("settings.channels.feishuAppSecret")
                        Picker("默认发送格式", selection: binding(for: viewModel, keyPath: \.feishuMessageFormat)) {
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

                        Button(isSaved ? "已保存 ✓" : "保存渠道设置") {
                            save(viewModel)
                        }
                        .accessibilityIdentifier("settings.channels.saveButton")
                    } header: {
                        Text("飞书")
                    } footer: {
                        Text("飞书凭证通过独立凭证存储管理，不写入普通 AppSettings 字段。")
                    }
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

    private func binding<Value>(for viewModel: ChannelSettingsViewModel, keyPath: ReferenceWritableKeyPath<ChannelSettingsViewModel, Value>) -> Binding<Value> {
        Binding(
            get: { viewModel[keyPath: keyPath] },
            set: { viewModel[keyPath: keyPath] = $0 }
        )
    }

    private func save(_ viewModel: ChannelSettingsViewModel) {
        do {
            try viewModel.save()
            withAnimation {
                isSaved = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                withAnimation {
                    isSaved = false
                }
            }
        } catch {
            isSaved = false
        }
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