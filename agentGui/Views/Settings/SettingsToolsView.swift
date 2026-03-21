import SwiftUI

struct SettingsToolsView: View {
    @Environment(ClaudeService.self) private var claudeService
    @Bindable var store: SettingsStore

    @State private var ollamaAPIKeyInput: String = ""
    @State private var showOllamaAPIKey: Bool = false

    var body: some View {
        Form {
            toolsSection
            permissionGuidanceSection
        }
        .formStyle(.grouped)
        .navigationTitle("工具")
        .onAppear {
            ollamaAPIKeyInput = store.settings.ollamaAPIKey
        }
    }

    private var settings: AppSettings { store.settings }

    private var toolGuidanceItems: [(title: String, detail: String, risk: String)] {
        [
            (
                title: "文本编辑器工具",
                detail: "全局默认开放。实际是否可写由当前会话、后台任务或渠道的局部授权决定。",
                risk: "会产生真实文件改动"
            ),
            (
                title: "Bash 工具",
                detail: "全局默认开放。命令会在受管终端中运行，并按审批模式决定是否需要人工确认。\(settings.workingDirectory.isEmpty ? "当前未指定工作目录，将回退到 HOME。" : "当前工作目录已配置。")",
                risk: "会执行真实系统命令"
            ),
            (
                title: "Web Search / Web Fetch",
                detail: "全局默认开放网络读取能力。若搜索走 Ollama，需要补充 API Key；实际是否可用仍受局部授权与审批模式约束。",
                risk: "会访问外部网络"
            ),
            (
                title: "LSP 工具",
                detail: "全局默认开放。建议同时配置工作目录，方便绑定语言服务器并自动启动匹配服务。",
                risk: "读取代码结构与诊断信息"
            )
        ]
    }

    private var toolsSection: some View {
        Section {
            TextField("工作目录（留空使用 HOME）", text: store.persistedSettingsBinding(
                get: { settings.workingDirectory },
                userMessage: "工作目录设置未成功保存",
                set: { settings.workingDirectory = $0 }
            ))
            .accessibilityIdentifier("settings.tools.workingDirectoryField")

            Toggle("优先使用 Ollama Web Search", isOn: store.persistedSettingsBinding(
                get: { settings.enableOllamaWebSearch },
                userMessage: "Ollama Web Search 设置未成功保存",
                set: { settings.enableOllamaWebSearch = $0 }
            ))

            if settings.enableOllamaWebSearch {
                HStack {
                    if showOllamaAPIKey {
                        TextField("Ollama API Key", text: $ollamaAPIKeyInput)
                    } else {
                        SecureField("Ollama API Key", text: $ollamaAPIKeyInput)
                    }
                    Button {
                        showOllamaAPIKey.toggle()
                    } label: {
                        Image(systemName: showOllamaAPIKey ? "eye.slash" : "eye")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    Button("保存") {
                        _ = store.persistSettingsMutation("Ollama API Key 未成功保存") {
                            settings.ollamaAPIKey = ollamaAPIKeyInput
                        }
                    }
                    .disabled(ollamaAPIKeyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            Toggle("自动启动匹配到的语言服务器", isOn: store.persistedSettingsBinding(
                get: { settings.autoStartLSPServers },
                userMessage: "LSP 自动启动设置未成功保存",
                set: { settings.autoStartLSPServers = $0 }
            ))

            Picker("默认路由策略", selection: store.persistedSettingsBinding(
                get: { settings.lspDefaultRoutingMode },
                userMessage: "LSP 路由策略未成功保存",
                set: { settings.lspDefaultRoutingMode = $0 }
            )) {
                Text("自动识别").tag("automatic")
                Text("手动绑定优先").tag("manualBinding")
                Text("禁用路由").tag("disabled")
            }

            LSPManagementSectionView(viewModel: lspManagementViewModel)
                .id(claudeService.lspPresentationRevision)

            VStack(alignment: .leading, spacing: 8) {
                Text("高级自定义 Profile JSON")
                    .font(.subheadline)

                TextEditor(text: store.persistedSettingsBinding(
                    get: { settings.lspCustomServerProfilesJSON },
                    userMessage: "LSP 自定义 profile 未成功保存",
                    set: { settings.lspCustomServerProfilesJSON = $0 }
                ))
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 120, maxHeight: 220)
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(6)
                .accessibilityIdentifier("settings.tools.lspCustomProfilesEditor")

                if let validationError = settings.lspCustomServerProfilesValidationError {
                    Text(validationError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        } header: {
            Text("工具")
        } footer: {
            Text("全局工具能力默认开启，风险控制改为通过当前会话、后台任务、渠道授权和审批模式完成。")
        }
    }

    private var permissionGuidanceSection: some View {
        Section {
            ForEach(Array(toolGuidanceItems.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(item.title)
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        Text(item.risk)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(item.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("权限与前提说明")
        } footer: {
            Text("高风险操作不再通过全局开关管理；默认审批会拦截 Bash 与 Web 操作，局部授权负责真正的可用范围。")
        }
    }

    private var lspManagementViewModel: LSPManagementViewModel {
        LSPManagementViewModel(
            settings: settings,
            serviceStateStore: LSPServiceStateStore(
                catalog: .builtInCatalog(),
                serverManager: claudeService.lspServerManager
            ),
            installCoordinator: claudeService.lspInstallCoordinator,
            serverManager: claudeService.lspServerManager,
            persistSettings: { userMessage, mutation in
                store.persistSettingsMutation(userMessage, mutation: mutation)
            }
        )
    }
}
