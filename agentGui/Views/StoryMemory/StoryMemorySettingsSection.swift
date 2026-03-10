import SwiftUI
import SwiftData

struct StoryMemorySettingsSection: View {
    @Environment(\ .modelContext) private var modelContext

    let settings: AppSettings

    var body: some View {
        Section {
            Toggle("启用创作记忆", isOn: binding(\ .enableStoryMemory))

            if settings.enableStoryMemory {
                Toggle("自动抽取剧情事件", isOn: binding(\ .storyMemoryAutoExtract))

                Stepper(value: binding(\ .storyMemoryPromptBudget), in: 2...12) {
                    HStack {
                        Text("Prompt 记忆预算")
                        Spacer()
                        Text("\(settings.storyMemoryPromptBudget)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }

                Picker("项目绑定模式", selection: binding(\ .storyMemoryProjectMode)) {
                    Text("自动").tag("auto")
                    Text("会话优先").tag("session")
                    Text("手动").tag("manual")
                }

                NavigationLink {
                    StoryProjectListView(session: nil)
                } label: {
                    Label("管理创作项目", systemImage: "books.vertical")
                }
            }
        } header: {
            Text("创作记忆")
        } footer: {
            Text("项目级创作记忆用于维护角色、世界规则、时间线和连续性。默认模式下，主 Agent 只会按需委托给独立的创作记忆子代理；失败或未写入时会在时间线中显式显示，不会静默伪装成成功。它与长期记忆分离，不会写入 ~/.agentgui/memory.md。")
        }
    }

    private func binding<Value>(_ keyPath: ReferenceWritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: {
                settings[keyPath: keyPath] = $0
                try? modelContext.save()
            }
        )
    }
}