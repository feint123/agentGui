import SwiftUI

struct SettingsConnectionView: View {
    @Bindable var store: SettingsStore
    @Environment(ClaudeService.self) private var claudeService

    @State private var apiKeyInput: String = ""
    @State private var baseURLInput: String = ""
    @State private var proxyEnabled: Bool = false
    @State private var proxyURLInput: String = ""
    @State private var proxyBypassInput: String = ""
    @State private var showAPIKey: Bool = false
    @State private var isSaved: Bool = false
    @State private var isProxySaved: Bool = false
    @State private var isValidating = false
    @State private var validationMessage: String?
    @State private var validationStatus: ConnectionValidationStatus?

    var body: some View {
        Form {
            readinessSection
            apiKeySection
            proxySection
            modelSection
        }
        .formStyle(.grouped)
        .navigationTitle("连接")
        .onAppear(perform: loadInputs)
    }

    private var settings: AppSettings { store.settings }

    private var readiness: LaunchReadinessStatus {
        LaunchReadinessEvaluator.evaluate(settings: settings)
    }

    private var readinessSection: some View {
        Section("启动就绪状态") {
            VStack(alignment: .leading, spacing: 8) {
                Text(readiness.title)
                    .font(.headline)
                    .accessibilityIdentifier("settings.connection.readinessSummary")
                Text(readiness.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(readiness.items) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: item.isSatisfied ? "checkmark.circle.fill" : (item.isRequired ? "exclamationmark.circle.fill" : "circle.dashed"))
                            .foregroundStyle(item.isSatisfied ? .green : (item.isRequired ? .orange : .secondary))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .font(.subheadline.weight(.medium))
                            Text(item.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var apiKeySection: some View {
        Section {
            HStack {
                if showAPIKey {
                    TextField("sk-ant-...", text: $apiKeyInput)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("settings.connection.apiKeyField")
                } else {
                    SecureField("sk-ant-...", text: $apiKeyInput)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("settings.connection.apiKeyField")
                }

                Button {
                    showAPIKey.toggle()
                } label: {
                    Image(systemName: showAPIKey ? "eye.slash" : "eye")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            TextField("https://api.anthropic.com（留空使用默认）", text: $baseURLInput)
                .textFieldStyle(.roundedBorder)

            Button(isSaved ? "已保存 ✓" : "保存") {
                saveConnectionSettings()
            }
            .disabled(apiKeyInput.trimmingCharacters(in: .whitespaces).isEmpty)
            .foregroundStyle(isSaved ? .green : .accentColor)
            .accessibilityIdentifier("settings.connection.saveButton")

            Button {
                validateConnectionSettings()
            } label: {
                if isValidating {
                    Label("验证中...", systemImage: "hourglass")
                } else {
                    Label("验证配置", systemImage: "checkmark.shield")
                }
            }
            .disabled(isValidating)
            .accessibilityIdentifier("settings.connection.validateButton")

            if let validationMessage, let validationStatus {
                Label(validationMessage, systemImage: validationStatus == .passed ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .font(.caption)
                    .foregroundStyle(validationStatus == .passed ? .green : .red)
            }
        } header: {
            Text("Anthropic API 配置")
        } footer: {
            Text("API Key 从 console.anthropic.com 获取。Base URL 可用于配置兼容代理服务（如 OpenRouter）。")
        }
    }

    private var modelSection: some View {
        Section("Claude 模型") {
            Picker("使用模型", selection: store.persistedSettingsBinding(
                get: { settings.selectedModel },
                userMessage: "模型设置未成功保存",
                set: { settings.selectedModel = $0 }
            )) {
                ForEach(AppSettings.availableModels, id: \.id) { model in
                    Text(model.name).tag(model.id)
                }
            }
        }
    }

    private var proxySection: some View {
        Section {
            Toggle("启用代理（网络请求 + Bash）", isOn: $proxyEnabled)

            if proxyEnabled {
                TextField("http://127.0.0.1:7890 或 socks5://127.0.0.1:1080", text: $proxyURLInput)
                    .textFieldStyle(.roundedBorder)

                TextField("NO_PROXY / 直连列表，例如 localhost,127.0.0.1,.corp.local", text: $proxyBypassInput)
                    .textFieldStyle(.roundedBorder)
            }

            Button(isProxySaved ? "已应用 ✓" : "应用代理设置") {
                saveProxySettings()
            }
            .disabled(!isProxyConfigurationValid)
            .foregroundStyle(isProxySaved ? .green : .accentColor)
        } header: {
            Text("代理")
        } footer: {
            Text("代理 URL 需包含协议头，例如 http:// 或 socks5://。影响内置 Web Search / Web Fetch / Ollama 请求，以及 Bash 会话中的 HTTP_PROXY、HTTPS_PROXY、ALL_PROXY、NO_PROXY。Anthropic 主 API 如需代理，继续使用上方 Base URL。")
        }
    }

    private var isProxyConfigurationValid: Bool {
        let trimmed = proxyURLInput.trimmingCharacters(in: .whitespacesAndNewlines)
        return !proxyEnabled || (!trimmed.isEmpty && isWellFormedURL(trimmed))
    }

    private func isWellFormedURL(_ rawValue: String) -> Bool {
        guard let components = URLComponents(string: rawValue),
              let scheme = components.scheme,
              !scheme.isEmpty,
              let host = components.host,
              !host.isEmpty else {
            return false
        }
        return true
    }

    private func loadInputs() {
        apiKeyInput = settings.apiKey
        baseURLInput = settings.baseURL
        proxyEnabled = settings.enableNetworkProxy
        proxyURLInput = settings.networkProxyURL
        proxyBypassInput = settings.networkProxyBypassList
    }

    private func saveConnectionSettings() {
        let trimmedKey = apiKeyInput.trimmingCharacters(in: .whitespaces)
        let trimmedURL = baseURLInput.trimmingCharacters(in: .whitespaces)
        if !store.persistSettingsMutation("Anthropic 设置未成功保存", mutation: {
            settings.apiKey = trimmedKey
            settings.baseURL = trimmedURL
        }) {
            return
        }
        claudeService.applyConnectionSettings(settings)
        withAnimation { isSaved = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { isSaved = false }
        }
        validationMessage = nil
        validationStatus = nil
    }

    private func saveProxySettings() {
        guard isProxyConfigurationValid else { return }
        if !store.persistSettingsMutation("代理设置未成功保存", mutation: {
            settings.enableNetworkProxy = proxyEnabled
            settings.networkProxyURL = proxyURLInput.trimmingCharacters(in: .whitespacesAndNewlines)
            settings.networkProxyBypassList = proxyBypassInput.trimmingCharacters(in: .whitespacesAndNewlines)
        }) {
            return
        }
        claudeService.applyConnectionSettings(settings)
        withAnimation { isProxySaved = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { isProxySaved = false }
        }
        validationMessage = nil
        validationStatus = nil
    }

    private func validateConnectionSettings() {
        isValidating = true

        let previewSettings = AppSettings.testFixture(
            apiKey: apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines),
            selectedModel: settings.selectedModel
        )
        previewSettings.baseURL = baseURLInput.trimmingCharacters(in: .whitespacesAndNewlines)
        previewSettings.enableNetworkProxy = proxyEnabled
        previewSettings.networkProxyURL = proxyURLInput.trimmingCharacters(in: .whitespacesAndNewlines)
        previewSettings.networkProxyBypassList = proxyBypassInput.trimmingCharacters(in: .whitespacesAndNewlines)

        Task {
            let result = await ConnectionValidationService().validate(settings: previewSettings)
            await MainActor.run {
                validationStatus = result.status
                validationMessage = result.messages.joined(separator: " ")
                isValidating = false
            }
        }
    }
}