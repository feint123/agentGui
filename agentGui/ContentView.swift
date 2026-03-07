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
    @State private var showAPIKey: Bool = false
    @State private var isSaved: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                apiKeySection
                modelSection
                appearanceSection
                toolsSection
                skillsSection
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
        }
    }

    // MARK: - Skills Section

    @ViewBuilder
    private var skillsSection: some View {
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
            Text("Skills")
        } footer: {
            Text("展示 ~/.claude/skills 目录中的技能。启用后，Claude 将能在对话中主动调用对应技能的指导。")
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
    }

    private func saveSettings() {
        guard let settings else { return }
        let trimmedKey = apiKeyInput.trimmingCharacters(in: .whitespaces)
        let trimmedURL = baseURLInput.trimmingCharacters(in: .whitespaces)
        settings.apiKey = trimmedKey
        settings.baseURL = trimmedURL
        try? modelContext.save()
        claudeService.configure(apiKey: trimmedKey, baseURL: trimmedURL)

        withAnimation { isSaved = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { isSaved = false }
        }
    }
}

#Preview {
    ContentView()
}
