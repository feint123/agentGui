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
