import SwiftUI
import SwiftData

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
                    } else if let settings {
                        ForEach(skillService.availableSkills) { skill in
                            let isEnabled = settings.enabledSkillNames.contains(skill.directoryName)
                            Toggle(isOn: Binding(
                                get: { isEnabled },
                                set: { newValue in
                                    var names = settings.enabledSkillNames
                                    if newValue {
                                        if names.contains(skill.directoryName) == false {
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
                                    if skill.description.isEmpty == false {
                                        Text(skill.description)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
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
            .accessibilityIdentifier("skills.root")
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