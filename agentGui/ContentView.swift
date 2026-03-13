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

    @State private var selectedTab: AppTab = TestLaunchOptions.current.initialTab
    @State private var persistenceCoordinator = PersistenceCoordinator.shared
    @Environment(ReliabilityCenterViewModel.self) private var reliabilityCenterViewModel

    var body: some View {
        TabView(selection: $selectedTab) {
            MainSplitView()
                .tabItem {
                    Label("对话", systemImage: selectedTab == .chat ? "bubble.left.and.bubble.right.fill" : "bubble.left.and.bubble.right")
                        .accessibilityIdentifier("tab.chat")
                }
                .tag(AppTab.chat)

            SkillsView()
                .tabItem {
                    Label("Skills", systemImage: selectedTab == .skills ? "wand.and.stars" : "wand.and.stars")
                        .accessibilityIdentifier("tab.skills")
                }
                .tag(AppTab.skills)

            ReliabilityCenterView()
                .tabItem {
                    Label(
                        "诊断",
                        systemImage: selectedTab == .reliability ? "cross.case.fill" : "cross.case"
                    )
                    .accessibilityIdentifier("tab.reliability")
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
    case reliability
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
