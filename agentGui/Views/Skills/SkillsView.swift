import SwiftUI
import SwiftData

struct SkillsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(PersistenceCoordinator.self) private var persistenceCoordinator
    @Environment(SkillService.self) private var skillService
    @State private var settings: AppSettings?
    @State private var expandedWhenToUseIDs: Set<String> = []

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
        let presentation = SkillRowPresentation(skill: skill)
        let isEnabled = settings.enabledSkillNames.contains(skill.directoryName)
        let toggleBinding = Binding(
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
        )

        return VStack(alignment: .leading, spacing: 4) {
            // 行 1：名称 + 参数标签 + 控件
            HStack(alignment: .center, spacing: WorkbenchSidebarPanelStyle.settingsRowSpacing) {
                HStack(spacing: 6) {
                    Text(skill.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)

                    if presentation.showArgumentHintTag {
                        SkillChip(label: "接受参数", color: .blue)
                    }
                }

                Spacer(minLength: 0)

                if presentation.toggleIsVisible {
                    Toggle("", isOn: toggleBinding)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .frame(width: WorkbenchSidebarPanelStyle.settingsToggleColumnWidth, alignment: .trailing)
                        .accessibilityLabel(skill.name)
                } else {
                    SkillChip(label: "内置", color: .purple)
                        .frame(width: WorkbenchSidebarPanelStyle.settingsToggleColumnWidth, alignment: .trailing)
                        .accessibilityLabel("\(skill.name) 内置技能")
                }
            }

            // 行 2：描述
            if !skill.description.isEmpty {
                Text(skill.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // 行 3：元数据 chips
            SkillMetadataChipsRow(presentation: presentation)

            // 行 4（可折叠）：whenToUse
            if presentation.showWhenToUseDisclosure, let whenToUse = skill.whenToUse {
                Button {
                    if expandedWhenToUseIDs.contains(skill.id) {
                        expandedWhenToUseIDs.remove(skill.id)
                    } else {
                        expandedWhenToUseIDs.insert(skill.id)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: expandedWhenToUseIDs.contains(skill.id)
                              ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("何时调用")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("skills.row.\(skill.directoryName).whenToUseToggle")

                if expandedWhenToUseIDs.contains(skill.id) {
                    Text(whenToUse)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 14)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                        .accessibilityIdentifier("skills.row.\(skill.directoryName).whenToUseText")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.15), value: expandedWhenToUseIDs)
    }

    private func refreshSkills() {
        skillService.clearCache()
        Task {
            await skillService.loadSkills()
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

// MARK: - Skill Row Subviews

private struct SkillSourceBadge: View {
    let presentation: SkillRowPresentation

    var body: some View {
        Text(presentation.sourceLabel)
            .font(.caption2.weight(.medium))
            .foregroundStyle(sourceColor)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(sourceColor.opacity(0.12), in: Capsule())
    }

    private var sourceColor: Color {
        switch presentation.skill.loadedFrom {
        case .user:    return .secondary
        case .project: return .blue
        case .managed: return .orange
        case .bundled: return .purple
        }
    }
}

private struct SkillMetadataChipsRow: View {
    let presentation: SkillRowPresentation

    var body: some View {
        HStack(spacing: 4) {
            SkillSourceBadge(presentation: presentation)

            if presentation.showForkBadge {
                SkillChip(label: "fork", color: .orange)
            }

            if let version = presentation.versionText {
                SkillChip(label: version, color: .secondary)
            }

            if presentation.showConditionalPathsBadge {
                SkillChip(label: "按路径激活", color: .secondary)
            }
        }
    }
}

private struct SkillChip: View {
    let label: String
    let color: Color

    var body: some View {
        Text(label)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }
}