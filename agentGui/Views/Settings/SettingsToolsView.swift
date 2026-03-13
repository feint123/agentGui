import SwiftUI

struct SettingsToolsView: View {
    @Bindable var store: SettingsStore

    @State private var ollamaAPIKeyInput: String = ""
    @State private var showOllamaAPIKey: Bool = false

    var body: some View {
        Form {
            toolsSection
        }
        .formStyle(.grouped)
        .navigationTitle("工具")
        .onAppear {
            ollamaAPIKeyInput = store.settings.ollamaAPIKey
        }
    }

    private var settings: AppSettings { store.settings }

    private var toolsSection: some View {
        Section {
            Toggle("启用文本编辑器工具（文件读写）", isOn: store.persistedSettingsBinding(
                get: { settings.enableTextEditorTool },
                userMessage: "文本编辑工具设置未成功保存",
                set: { settings.enableTextEditorTool = $0 }
            ))

            Toggle("启用 Bash 工具（执行 shell 命令）", isOn: store.persistedSettingsBinding(
                get: { settings.enableBashTool },
                userMessage: "Bash 工具设置未成功保存",
                set: { settings.enableBashTool = $0 }
            ))

            if settings.enableBashTool {
                TextField("工作目录（留空使用 HOME）", text: store.persistedSettingsBinding(
                    get: { settings.workingDirectory },
                    userMessage: "工作目录设置未成功保存",
                    set: { settings.workingDirectory = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("settings.tools.workingDirectoryField")
            }

            Toggle("启用 Web Search 工具（Bing 搜索）", isOn: store.persistedSettingsBinding(
                get: { settings.enableWebSearchTool },
                userMessage: "Web Search 设置未成功保存",
                set: { settings.enableWebSearchTool = $0 }
            ))

            if settings.enableWebSearchTool {
                Toggle("优先使用 Ollama Web Search", isOn: store.persistedSettingsBinding(
                    get: { settings.enableOllamaWebSearch },
                    userMessage: "Ollama Web Search 设置未成功保存",
                    set: { settings.enableOllamaWebSearch = $0 }
                ))
                .padding(.leading, 16)

                if settings.enableOllamaWebSearch {
                    HStack {
                        if showOllamaAPIKey {
                            TextField("Ollama API Key", text: $ollamaAPIKeyInput)
                                .textFieldStyle(.roundedBorder)
                        } else {
                            SecureField("Ollama API Key", text: $ollamaAPIKeyInput)
                                .textFieldStyle(.roundedBorder)
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
                    .padding(.leading, 16)
                }
            }

            Toggle("启用 Web Fetch 工具（获取网页内容）", isOn: store.persistedSettingsBinding(
                get: { settings.enableWebFetchTool },
                userMessage: "Web Fetch 设置未成功保存",
                set: { settings.enableWebFetchTool = $0 }
            ))

            Toggle("启用 LSP 工具（语义代码检索）", isOn: store.persistedSettingsBinding(
                get: { settings.enableLSPTools },
                userMessage: "LSP 工具设置未成功保存",
                set: { settings.enableLSPTools = $0 }
            ))

            Toggle("自动启动匹配到的语言服务器", isOn: store.persistedSettingsBinding(
                get: { settings.autoStartLSPServers },
                userMessage: "LSP 自动启动设置未成功保存",
                set: { settings.autoStartLSPServers = $0 }
            ))
            .disabled(!settings.enableLSPTools)

            if settings.enableLSPTools {
                Picker("默认路由策略", selection: store.persistedSettingsBinding(
                    get: { settings.lspDefaultRoutingMode },
                    userMessage: "LSP 路由策略未成功保存",
                    set: { settings.lspDefaultRoutingMode = $0 }
                )) {
                    Text("自动识别").tag("automatic")
                    Text("手动绑定优先").tag("manualBinding")
                    Text("禁用路由").tag("disabled")
                }

                LabeledContent("内建 Profiles") {
                    Text(lspBuiltInProfilesSummary())
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("自定义 Profile JSON")
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
            }
        } header: {
            Text("工具")
        } footer: {
            Text("工具让 Claude 能够读写文件、执行终端命令。仅在可信环境中启用。")
        }
    }

    private func lspBuiltInProfilesSummary() -> String {
        guard let registry = try? LSPServerRegistry(settings: settings) else {
            return "内建 profile 不可用"
        }

        return registry
            .allDefinitions()
            .map { definition in
                let languages = definition.supportedLanguageIDs.joined(separator: ", ")
                return "\(definition.displayName) (\(languages))"
            }
            .joined(separator: "\n")
    }
}