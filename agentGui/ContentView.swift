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
        }
        .frame(minWidth: 900, minHeight: 600)
    }
}

enum AppTab: String, CaseIterable {
    case chat
    case skills
    case settings
}

// MARK: - Settings View

/// 设置视图 — 配置 API Key 和模型
struct SettingsView: View {

    @Environment(\.modelContext) private var modelContext
    @Environment(ClaudeService.self) private var claudeService
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
                Picker("使用模型", selection: Binding(
                    get: { settings.selectedModel },
                    set: { settings.selectedModel = $0; try? modelContext.save() }
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
                Picker("主题", selection: Binding(
                    get: { settings.themeMode },
                    set: { settings.themeMode = $0; try? modelContext.save() }
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
                Toggle("启用文本编辑器工具（文件读写）", isOn: Binding(
                    get: { settings.enableTextEditorTool },
                    set: { settings.enableTextEditorTool = $0; try? modelContext.save() }
                ))

                Toggle("启用 Bash 工具（执行 shell 命令）", isOn: Binding(
                    get: { settings.enableBashTool },
                    set: { settings.enableBashTool = $0; try? modelContext.save() }
                ))

                if settings.enableBashTool {
                    TextField("工作目录（留空使用 HOME）", text: Binding(
                        get: { settings.workingDirectory },
                        set: { settings.workingDirectory = $0; try? modelContext.save() }
                    ))
                    .textFieldStyle(.roundedBorder)
                }

                Toggle("启用 Web Search 工具（Bing 搜索）", isOn: Binding(
                    get: { settings.enableWebSearchTool },
                    set: { settings.enableWebSearchTool = $0; try? modelContext.save() }
                ))

                if settings.enableWebSearchTool {
                    Toggle("优先使用 Ollama Web Search", isOn: Binding(
                        get: { settings.enableOllamaWebSearch },
                        set: { settings.enableOllamaWebSearch = $0; try? modelContext.save() }
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
                                settings.ollamaAPIKey = ollamaAPIKeyInput
                                try? modelContext.save()
                            }
                            .disabled(ollamaAPIKeyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                        .padding(.leading, 16)
                    }
                }


                Toggle("启用 Web Fetch 工具（获取网页内容）", isOn: Binding(
                    get: { settings.enableWebFetchTool },
                    set: { settings.enableWebFetchTool = $0; try? modelContext.save() }
                ))
            } header: {
                Text("工具")
            } footer: {
                Text("工具让 Claude 能够读写文件、执行终端命令。仅在可信环境中启用。")
            }

            Section {
                Toggle("启用 Extended Thinking（Claude 3.7 及更高版本）", isOn: Binding(
                    get: { settings.enableExtendedThinking },
                    set: { settings.enableExtendedThinking = $0; try? modelContext.save() }
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
                            value: Binding(
                                get: { Double(settings.extendedThinkingBudget) },
                                set: { settings.extendedThinkingBudget = Int($0); try? modelContext.save() }
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
                Toggle("启用反思与自我修正", isOn: Binding(
                    get: { settings.enableReflection },
                    set: { settings.enableReflection = $0; try? modelContext.save() }
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
                            value: Binding(
                                get: { settings.reflectionConfidenceThreshold },
                                set: { settings.reflectionConfidenceThreshold = $0; try? modelContext.save() }
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
                Toggle("启用统一记忆运行时", isOn: Binding(
                    get: { settings.enableUnifiedMemoryRuntime },
                    set: { settings.enableUnifiedMemoryRuntime = $0; try? modelContext.save() }
                ))

                if settings.enableUnifiedMemoryRuntime {
                    Stepper(value: Binding(
                        get: { settings.unifiedMemoryContextBudget },
                        set: { settings.unifiedMemoryContextBudget = $0; try? modelContext.save() }
                    ), in: 4...16) {
                        HStack {
                            Text("统一记忆上下文预算")
                            Spacer()
                            Text("\(settings.unifiedMemoryContextBudget)")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }

                    Toggle("启用记忆治理层", isOn: Binding(
                        get: { settings.enableMemoryGovernance },
                        set: { settings.enableMemoryGovernance = $0; try? modelContext.save() }
                    ))

                    Toggle("启用统一写路径", isOn: Binding(
                        get: { settings.enableUnifiedMemoryWritePath },
                        set: { settings.enableUnifiedMemoryWritePath = $0; try? modelContext.save() }
                    ))

                    Toggle("允许后台记忆巩固", isOn: Binding(
                        get: { settings.enableBackgroundMemoryConsolidation },
                        set: { settings.enableBackgroundMemoryConsolidation = $0; try? modelContext.save() }
                    ))

                    Toggle("启用 TTL Sweep", isOn: Binding(
                        get: { settings.enableMemoryTTLSweep },
                        set: { settings.enableMemoryTTLSweep = $0; try? modelContext.save() }
                    ))

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("待确认阈值")
                            Spacer()
                            Text(String(format: "%.0f%%", settings.memoryConfirmationThreshold * 100))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(
                            value: Binding(
                                get: { settings.memoryConfirmationThreshold },
                                set: { settings.memoryConfirmationThreshold = $0; try? modelContext.save() }
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
        let s = AppSettings.getOrCreate(in: modelContext)
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
        settings.apiKey = trimmedKey
        settings.baseURL = trimmedURL
        try? modelContext.save()
        claudeService.applyConnectionSettings(settings)

        withAnimation { isSaved = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { isSaved = false }
        }
    }

    private func saveProxySettings(for settings: AppSettings) {
        guard isProxyConfigurationValid else { return }
        settings.enableNetworkProxy = proxyEnabled
        settings.networkProxyURL = proxyURLInput.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.networkProxyBypassList = proxyBypassInput.trimmingCharacters(in: .whitespacesAndNewlines)
        try? modelContext.save()
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
}

// MARK: - Skills View

struct SkillsView: View {

    @Environment(\.modelContext) private var modelContext
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
                                        settings.enabledSkillNames = names
                                        try? modelContext.save()
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
                settings = AppSettings.getOrCreate(in: modelContext)
            }
        }
    }
}

#Preview {
    ContentView()
}
