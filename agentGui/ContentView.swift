//
//  ContentView.swift
//  agentGui
//
//  Created by feint on 2026/2/10.
//

import SwiftUI

/// 应用主视图
/// 使用 TabView 组织不同的功能区域
struct ContentView: View {

    // MARK: - Properties

    @State private var selectedTab: AppTab = .chat

    // MARK: - Body

    var body: some View {
        TabView(selection: $selectedTab) {
            // 聊天标签
            MainSplitView()
                .tabItem {
                    Label("聊天", systemImage: selectedTab == .chat ? "bubble.left.and.bubble.right.fill" : "bubble.left.and.bubble.right")
                }
                .tag(AppTab.chat)

            // Agent 管理标签
            AgentListView()
                .tabItem {
                    Label("Agent", systemImage: selectedTab == .agents ? "app.dashed.fill" : "app.dashed")
                }
                .tag(AppTab.agents)

            // 设置标签
            SettingsView()
                .tabItem {
                    Label("设置", systemImage: selectedTab == .settings ? "gearshape.fill" : "gearshape")
                }
                .tag(AppTab.settings)
        }
        .frame(minWidth: 900, minHeight: 600)
    }
}

// MARK: - App Tab

/// 应用标签页
enum AppTab: String, CaseIterable {
    case chat
    case agents
    case settings

    var localizedName: String {
        switch self {
        case .chat:
            return "聊天"
        case .agents:
            return "Agent"
        case .settings:
            return "设置"
        }
    }
}

// MARK: - Settings View

/// 设置视图（占位）
private struct SettingsView: View {
    var body: some View {
        NavigationStack {
            Form {
                Section("通用") {
                    Text("主题设置（即将推出）")
                    Text("语言设置（即将推出）")
                }

                Section("Agent") {
                    Text("默认 Agent（即将推出）")
                    Text("自动重连（即将推出）")
                }

                Section("权限") {
                    Text("自动批准策略（即将推出）")
                    Text("允许的文件操作（即将推出）")
                }

                Section("关于") {
                    HStack {
                        Text("版本")
                        Spacer()
                        Text("1.0.0")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("设置")
        }
    }
}

// MARK: - Preview

#Preview {
    ContentView()
}
