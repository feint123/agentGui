//
//  ContentView.swift
//  agentGui
//
//  Created by feint on 2026/2/10.
//

import SwiftUI
import SwiftData

/// 应用主视图
struct ContentView: View {

    @State private var selectedTab: AppTab = .chat
    @State private var persistenceCoordinator = PersistenceCoordinator.shared
    @Environment(ReliabilityCenterViewModel.self) private var reliabilityCenterViewModel

    var body: some View {
        TabView(selection: $selectedTab) {
            MainSplitView()
                .tabItem {
                    Label("对话", systemImage: selectedTab == .chat ? "bubble.left.and.bubble.right.fill" : "bubble.left.and.bubble.right")
                }
                .tag(AppTab.chat)

            SkillsView()
                .tabItem {
                    Label("Skills", systemImage: selectedTab == .skills ? "wand.and.stars" : "wand.and.stars")
                }
                .tag(AppTab.skills)

            SettingsView()
                .tabItem {
                    Label("设置", systemImage: selectedTab == .settings ? "gearshape.fill" : "gearshape")
                }
                .tag(AppTab.settings)

            ReliabilityCenterView()
                .tabItem {
                    Label(
                        "诊断",
                        systemImage: selectedTab == .reliability ? "cross.case.fill" : "cross.case"
                    )
                }
                .tag(AppTab.reliability)
        }
        .frame(minWidth: 900, minHeight: 600)
        .environment(persistenceCoordinator)
        .alert(
            "保存失败",
            isPresented: Binding(
                get: { persistenceCoordinator.lastFailure != nil },
                set: { if !$0 { persistenceCoordinator.dismissFailure() } }
            )
        ) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(persistenceCoordinator.lastFailureSummary ?? "本次变更未成功保存。")
        }
    }
}

enum AppTab: String, CaseIterable {
    case chat
    case skills
    case settings
    case reliability
}

// MARK: - Settings View

/// 设置视图 — 配置 API Key 和模型
struct SettingsView: View {

    @Environment(\.modelContext) private var modelContext
    @Environment(ClaudeService.self) private var claudeService
    @Environment(PersistenceCoordinator.self) private var persistenceCoordinator
    @Environment(SkillService.self) private var skillService
    @State private var settings: AppSettings?
    @State private var apiKeyInput: String = ""
    @State private var baseURLInput: String = ""
    @State private var ollamaAPIKeyInput: String = ""
    @State private var proxyEnabled: Bool = false
    @State private var proxyURLInput: String = ""
    @State private var proxyBypassInput: String = ""
    @State private var showAPIKey: Bool = false
    @State private var showOllamaAPIKey: Bool = false
    @State private var isSaved: Bool = false
    @State private var isProxySaved: Bool = false
    @State private var memoryContent: String = ""
    @State private var isMemorySaved: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                apiKeySection
                proxySection
                modelSection
                appearanceSection
                toolsSection
                memorySection
                aboutSection
            }
            .formStyle(.grouped)
            .navigationTitle("设置")
            .onAppear {
                loadSettings()
            }
        }
    }

    // MARK: - API Key Section

    private var apiKeySection: some View {
        Section {
            HStack {
                if showAPIKey {
                    TextField("sk-ant-...", text: $apiKeyInput)
                        .textFieldStyle(.roundedBorder)
                } else {
                    SecureField("sk-ant-...", text: $apiKeyInput)
                        .textFieldStyle(.roundedBorder)
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
                saveSettings()
            }
            .disabled(apiKeyInput.trimmingCharacters(in: .whitespaces).isEmpty)
            .foregroundStyle(isSaved ? .green : .accentColor)

        } header: {
            Text("Anthropic API 配置")
        } footer: {
            Text("API Key 从 console.anthropic.com 获取。Base URL 可用于配置兼容代理服务（如 OpenRouter）。")
        }
    }

    // MARK: - Model Section

    private var isProxyConfigurationValid: Bool {
        let trimmed = proxyURLInput.trimmingCharacters(in: .whitespacesAndNewlines)
        return !proxyEnabled || (!trimmed.isEmpty && URL(string: trimmed) != nil)
    }

    @ViewBuilder
    private var proxySection: some View {
        if let settings {
            Section {
                Toggle("启用代理（网络请求 + Bash）", isOn: $proxyEnabled)

                if proxyEnabled {
                    TextField("http://127.0.0.1:7890 或 socks5://127.0.0.1:1080", text: $proxyURLInput)
                        .textFieldStyle(.roundedBorder)

                    TextField("NO_PROXY / 直连列表，例如 localhost,127.0.0.1,.corp.local", text: $proxyBypassInput)
                        .textFieldStyle(.roundedBorder)
                }

                Button(isProxySaved ? "已应用 ✓" : "应用代理设置") {
                    saveProxySettings(for: settings)
                }
                .disabled(!isProxyConfigurationValid)
                .foregroundStyle(isProxySaved ? .green : .accentColor)
            } header: {
                Text("代理")
            } footer: {
                Text("代理 URL 需包含协议头，例如 http:// 或 socks5://。影响内置 Web Search / Web Fetch / Ollama 请求，以及 Bash 会话中的 HTTP_PROXY、HTTPS_PROXY、ALL_PROXY、NO_PROXY。Anthropic 主 API 如需代理，继续使用上方 Base URL。")
            }
        }
    }

    @ViewBuilder
    private var modelSection: some View {
        if let settings {
            Section("Claude 模型") {
                Picker("使用模型", selection: persistedSettingsBinding(
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
    }

    // MARK: - Appearance Section

    @ViewBuilder
    private var appearanceSection: some View {
        if let settings {
            Section("外观") {
                Picker("主题", selection: persistedSettingsBinding(
                    get: { settings.themeMode },
                    userMessage: "主题设置未成功保存",
                    set: { settings.themeMode = $0 }
                )) {
                    ForEach(ThemeMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
            }
        }
    }

    // MARK: - Tools Section

    @ViewBuilder
    private var toolsSection: some View {
        if let settings {
            Section {
                Toggle("启用文本编辑器工具（文件读写）", isOn: persistedSettingsBinding(
                    get: { settings.enableTextEditorTool },
                    userMessage: "文本编辑工具设置未成功保存",
                    set: { settings.enableTextEditorTool = $0 }
                ))

                Toggle("启用 Bash 工具（执行 shell 命令）", isOn: persistedSettingsBinding(
                    get: { settings.enableBashTool },
                    userMessage: "Bash 工具设置未成功保存",
                    set: { settings.enableBashTool = $0 }
                ))

                if settings.enableBashTool {
                    TextField("工作目录（留空使用 HOME）", text: persistedSettingsBinding(
                        get: { settings.workingDirectory },
                        userMessage: "工作目录设置未成功保存",
                        set: { settings.workingDirectory = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                }

                Toggle("启用 Web Search 工具（Bing 搜索）", isOn: persistedSettingsBinding(
                    get: { settings.enableWebSearchTool },
                    userMessage: "Web Search 设置未成功保存",
                    set: { settings.enableWebSearchTool = $0 }
                ))

                if settings.enableWebSearchTool {
                    Toggle("优先使用 Ollama Web Search", isOn: persistedSettingsBinding(
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
                                _ = persistSettingsMutation("Ollama API Key 未成功保存") {
                                    settings.ollamaAPIKey = ollamaAPIKeyInput
                                }
                            }
                            .disabled(ollamaAPIKeyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                        .padding(.leading, 16)
                    }
                }


                Toggle("启用 Web Fetch 工具（获取网页内容）", isOn: persistedSettingsBinding(
                    get: { settings.enableWebFetchTool },
                    userMessage: "Web Fetch 设置未成功保存",
                    set: { settings.enableWebFetchTool = $0 }
                ))
            } header: {
                Text("工具")
            } footer: {
                Text("工具让 Claude 能够读写文件、执行终端命令。仅在可信环境中启用。")
            }

            Section {
                Toggle("启用 Extended Thinking（Claude 3.7 及更高版本）", isOn: persistedSettingsBinding(
                    get: { settings.enableExtendedThinking },
                    userMessage: "Extended Thinking 设置未成功保存",
                    set: { settings.enableExtendedThinking = $0 }
                ))

                if settings.enableExtendedThinking {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Token 预算")
                            Spacer()
                            Text("\(settings.extendedThinkingBudget)")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Slider(
                            value: persistedSettingsBinding(
                                get: { Double(settings.extendedThinkingBudget) },
                                userMessage: "Thinking 预算未成功保存",
                                set: { settings.extendedThinkingBudget = Int($0) }
                            ),
                            in: 1000...32000,
                            step: 1000
                        )
                    }
                }
            } header: {
                Text("Extended Thinking")
            } footer: {
                Text("开启后，Claude 3.7 及更高版本会在回答前进行深度推理，结果将以折叠气泡展示。")
            }

            Section {
                Toggle("启用反思与自我修正", isOn: persistedSettingsBinding(
                    get: { settings.enableReflection },
                    userMessage: "反思循环设置未成功保存",
                    set: { settings.enableReflection = $0 }
                ))

                if settings.enableReflection {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("置信度阈值")
                            Spacer()
                            Text(String(format: "%.0f%%", settings.reflectionConfidenceThreshold * 100))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Slider(
                            value: persistedSettingsBinding(
                                get: { settings.reflectionConfidenceThreshold },
                                userMessage: "反思阈值未成功保存",
                                set: { settings.reflectionConfidenceThreshold = $0 }
                            ),
                            in: 0.5...1.0,
                            step: 0.05
                        )
                    }
                }
            } header: {
                Text("反思循环")
            } footer: {
                Text("每次 end_turn 后触发一次额外 API 调用，让模型为自己的输出打分。置信度低于阈值时自动重试并修正问题。")
            }

            StoryMemorySettingsSection(settings: settings)
        }
    }

    // MARK: - Memory Section

    private var memorySection: some View {
        Section {
            if let settings {
                Toggle("启用统一记忆运行时", isOn: persistedSettingsBinding(
                    get: { settings.enableUnifiedMemoryRuntime },
                    userMessage: "统一记忆运行时设置未成功保存",
                    set: { settings.enableUnifiedMemoryRuntime = $0 }
                ))

                if settings.enableUnifiedMemoryRuntime {
                    Stepper(value: persistedSettingsBinding(
                        get: { settings.unifiedMemoryContextBudget },
                        userMessage: "统一记忆上下文预算未成功保存",
                        set: { settings.unifiedMemoryContextBudget = $0 }
                    ), in: 4...16) {
                        HStack {
                            Text("统一记忆上下文预算")
                            Spacer()
                            Text("\(settings.unifiedMemoryContextBudget)")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }

                    Toggle("启用记忆治理层", isOn: persistedSettingsBinding(
                        get: { settings.enableMemoryGovernance },
                        userMessage: "记忆治理设置未成功保存",
                        set: { settings.enableMemoryGovernance = $0 }
                    ))

                    Toggle("启用统一写路径", isOn: persistedSettingsBinding(
                        get: { settings.enableUnifiedMemoryWritePath },
                        userMessage: "统一写路径设置未成功保存",
                        set: { settings.enableUnifiedMemoryWritePath = $0 }
                    ))

                    Toggle("允许后台记忆巩固", isOn: persistedSettingsBinding(
                        get: { settings.enableBackgroundMemoryConsolidation },
                        userMessage: "后台记忆巩固设置未成功保存",
                        set: { settings.enableBackgroundMemoryConsolidation = $0 }
                    ))

                    Stepper(value: persistedSettingsBinding(
                        get: { settings.memoryBackgroundSchedulerIntervalSeconds },
                        userMessage: "后台调度周期未成功保存",
                        set: { settings.memoryBackgroundSchedulerIntervalSeconds = $0 }
                    ), in: 5...600, step: 5) {
                        HStack {
                            Text("后台调度周期")
                            Spacer()
                            Text("\(settings.memoryBackgroundSchedulerIntervalSeconds)s")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }

                    Toggle("启用 TTL Sweep", isOn: persistedSettingsBinding(
                        get: { settings.enableMemoryTTLSweep },
                        userMessage: "TTL Sweep 设置未成功保存",
                        set: { settings.enableMemoryTTLSweep = $0 }
                    ))

                    Stepper(value: persistedSettingsBinding(
                        get: { settings.memoryTTLSweepIntervalSeconds },
                        userMessage: "TTL Sweep 周期未成功保存",
                        set: { settings.memoryTTLSweepIntervalSeconds = $0 }
                    ), in: 60...3600, step: 60) {
                        HStack {
                            Text("TTL Sweep 周期")
                            Spacer()
                            Text("\(settings.memoryTTLSweepIntervalSeconds)s")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("待确认阈值")
                            Spacer()
                            Text(String(format: "%.0f%%", settings.memoryConfirmationThreshold * 100))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(
                            value: persistedSettingsBinding(
                                get: { settings.memoryConfirmationThreshold },
                                userMessage: "待确认阈值未成功保存",
                                set: { settings.memoryConfirmationThreshold = $0 }
                            ),
                            in: 0.4...0.95,
                            step: 0.05
                        )
                    }

                    NavigationLink {
                        MemoryManagementPanel()
                    } label: {
                        Label("打开记忆治理面板", systemImage: "tray.full")
                    }
                }
            }

            TextEditor(text: $memoryContent)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 140, maxHeight: 280)
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(6)

            Button(isMemorySaved ? "已保存 ✓" : "保存记忆") {
                saveMemory()
            }
            .foregroundStyle(isMemorySaved ? .green : .accentColor)
        } header: {
            Text("长期记忆")
        } footer: {
            Text("内容保存至 ~/.agentgui/memory.md，每次对话开始时自动注入系统提示词。Claude 也可通过 memory_write 工具直接更新记忆。统一记忆运行时用于把 TaskMemory / StoryMemory 组装成单一读视图，治理层用于限制低置信度写入。")
        }
    }

    // MARK: - About Section

    private var aboutSection: some View {
        Section("关于") {
            HStack {
                Text("版本")
                Spacer()
                Text("2.0.0")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("AI 服务")
                Spacer()
                Text("Anthropic Claude")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("连接状态")
                Spacer()
                HStack(spacing: 6) {
                    Circle()
                        .fill(claudeService.isConfigured ? .green : .red)
                        .frame(width: 8, height: 8)
                    Text(claudeService.isConfigured ? "已配置" : "未配置")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Actions

    private func loadSettings() {
        let s = AppSettings.getOrCreate(in: modelContext, persistenceCoordinator: persistenceCoordinator)
        settings = s
        apiKeyInput = s.apiKey
        baseURLInput = s.baseURL
        ollamaAPIKeyInput = s.ollamaAPIKey
        proxyEnabled = s.enableNetworkProxy
        proxyURLInput = s.networkProxyURL
        proxyBypassInput = s.networkProxyBypassList
        memoryContent = ConfigDirectoryManager.shared.readMemory()
    }

    private func saveSettings() {
        guard let settings else { return }
        let trimmedKey = apiKeyInput.trimmingCharacters(in: .whitespaces)
        let trimmedURL = baseURLInput.trimmingCharacters(in: .whitespaces)
        if !persistSettingsMutation("Anthropic 设置未成功保存", mutation: {
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
    }

    private func saveProxySettings(for settings: AppSettings) {
        guard isProxyConfigurationValid else { return }
        if !persistSettingsMutation("代理设置未成功保存", mutation: {
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
    }

    private func saveMemory() {
        ConfigDirectoryManager.shared.writeMemory(content: memoryContent, mode: .overwrite)
        withAnimation { isMemorySaved = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { isMemorySaved = false }
        }
    }

    @discardableResult
    private func persistSettingsMutation(_ userMessage: String, mutation: () -> Void) -> Bool {
        mutation()
        do {
            try persistenceCoordinator.save(modelContext, domain: .settings, userMessage: userMessage)
            return true
        } catch {
            return false
        }
    }

    private func persistedSettingsBinding<Value>(
        get: @escaping () -> Value,
        userMessage: String,
        set: @escaping (Value) -> Void
    ) -> Binding<Value> {
        Binding(
            get: get,
            set: { newValue in
                _ = persistSettingsMutation(userMessage) {
                    set(newValue)
                }
            }
        )
    }
}

// MARK: - Skills View

struct SkillsView: View {

    @Environment(\.modelContext) private var modelContext
    @Environment(PersistenceCoordinator.self) private var persistenceCoordinator
    @Environment(SkillService.self) private var skillService
    @State private var settings: AppSettings?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if skillService.availableSkills.isEmpty {
                        HStack {
                            Image(systemName: "tray")
                                .foregroundStyle(.secondary)
                            Text("未发现技能")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        if let settings {
                            ForEach(skillService.availableSkills) { skill in
                                let isEnabled = settings.enabledSkillNames.contains(skill.directoryName)
                                Toggle(isOn: Binding(
                                    get: { isEnabled },
                                    set: { newValue in
                                        var names = settings.enabledSkillNames
                                        if newValue {
                                            if !names.contains(skill.directoryName) {
                                                names.append(skill.directoryName)
                                            }
                                        } else {
                                            names.removeAll { $0 == skill.directoryName }
                                        }
                                        _ = persistSettingsMutation("技能启用状态未成功保存") {
                                            settings.enabledSkillNames = names
                                        }
                                    }
                                )) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(skill.name)
                                        if !skill.description.isEmpty {
                                            Text(skill.description)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(2)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    Button("刷新技能列表") {
                        skillService.clearCache()
                        skillService.loadSkills()
                    }
                    .buttonStyle(.glassProminent)
                } header: {
                    Text("已安装的技能")
                } footer: {
                    Text("展示 ~/.claude/skills 目录中的技能。启用后，Claude 将能在对话中主动调用对应技能的指导。")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Skills")
            .onAppear {
                settings = AppSettings.getOrCreate(in: modelContext, persistenceCoordinator: persistenceCoordinator)
            }
        }
    }

    @discardableResult
    private func persistSettingsMutation(_ userMessage: String, mutation: () -> Void) -> Bool {
        mutation()
        do {
            try persistenceCoordinator.save(modelContext, domain: .settings, userMessage: userMessage)
            return true
        } catch {
            return false
        }
    }
}

#Preview {
    ContentView()
}
