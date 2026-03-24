import SwiftUI
import SwiftData

struct SkillsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(PersistenceCoordinator.self) private var persistenceCoordinator
    @Environment(SkillService.self) private var skillService
    @State private var settings: AppSettings?

    var body: some View {
        VStack(spacing: 0) {
            WorkbenchSidebarPanelHeader {
                WorkbenchSidebarToolbarHeader {
                    HStack(spacing: 8) {
                        Label("技能", systemImage: "wand.and.stars")
                            .font(.subheadline.weight(.semibold))
                        Text("启用后可供代理主动调用")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                } trailing: {
                    Button(action: refreshSkills) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("skills.refresh")
                }
            }

            WorkbenchSidebarPanelScrollView {
                WorkbenchSidebarSectionCard(title: "已安装的技能", systemImage: "square.stack.3d.down.right") {
                    skillsContent
                }

                WorkbenchSidebarSectionCard {
                    Text("展示 ~/.claude/skills 目录中的技能。启用后，Claude 将能在对话中主动调用对应技能的指导。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityIdentifier("skills.root")
        .onAppear {
            settings = AppSettings.getOrCreate(in: modelContext, persistenceCoordinator: persistenceCoordinator)
        }
    }

    @ViewBuilder
    private var skillsContent: some View {
        if skillService.availableSkills.isEmpty {
            WorkbenchSidebarEmptyStateView(
                systemImage: "tray",
                title: "未发现技能",
                message: "刷新后会重新扫描 ~/.claude/skills 目录。"
            ) {
                Button("刷新技能列表") {
                    refreshSkills()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .frame(minHeight: 180)
        } else if let settings {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(skillService.availableSkills.enumerated()), id: \.element.id) { index, skill in
                    if index > 0 {
                        Divider()
                    }
                    skillRow(skill, settings: settings)
                        .padding(.vertical, 10)
                }
            }
        }
    }

    private func skillRow(_ skill: Skill, settings: AppSettings) -> some View {
        let isEnabled = settings.enabledSkillNames.contains(skill.directoryName)
        let isOn = Binding(
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
        )

        return HStack(alignment: .center, spacing: WorkbenchSidebarPanelStyle.settingsRowSpacing) {
            VStack(alignment: .leading, spacing: 4) {
                Text(skill.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                if skill.description.isEmpty == false {
                    Text(skill.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)

            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .frame(width: WorkbenchSidebarPanelStyle.settingsToggleColumnWidth, alignment: .trailing)
                .accessibilityLabel(skill.name)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func refreshSkills() {
        skillService.clearCache()
        skillService.loadSkills()
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