import SwiftUI

struct SettingsMemoryView: View {
    @Bindable var store: SettingsStore

    @State private var memoryContent: String = ""
    @State private var isMemorySaved: Bool = false

    var body: some View {
        Form {
            memorySection
        }
        .formStyle(.grouped)
        .navigationTitle("记忆")
        .onAppear {
            memoryContent = ConfigDirectoryManager.shared.readMemory()
        }
    }

    private var settings: AppSettings { store.settings }

    private var runtimeEffectSummary: String {
        settings.memoryEnabled
            ? "RMS memory 已启用，当前 task 的 state 会参与 bootstrap prompt 注入"
            : "RMS memory 已停用，bootstrap 不会注入 task-bound memory state"
    }

    private var memorySection: some View {
        Section {
            Toggle("启用 Memory", isOn: store.persistedSettingsBinding(
                get: { settings.memoryEnabled },
                userMessage: "Memory 设置未成功保存",
                set: { settings.memoryEnabled = $0 }
            ))

            Stepper(value: store.persistedSettingsBinding(
                get: { settings.memoryContextBudget },
                userMessage: "Memory 上下文预算未成功保存",
                set: { settings.memoryContextBudget = $0 }
            ), in: 4...16) {
                HStack {
                    Text("Memory 上下文预算")
                    Spacer()
                    Text("\(settings.memoryContextBudget)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            NavigationLink(value: SettingsDetailRoute.rmsPanel) {
                HStack(spacing: 12) {
                    Image(systemName: "shield.lefthalf.filled")
                        .font(.title3)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 34, height: 34)
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                    VStack(alignment: .leading, spacing: 3) {
                        Text("打开 RMS 面板")
                            .foregroundStyle(.primary)
                        Text("查看当前 task-bound state 中的 frontiers、反例、约束、债务与下一步动作")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            TextEditor(text: $memoryContent)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 140, maxHeight: 280)
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(6)
                .accessibilityIdentifier("settings.memory.editor")

            Button(isMemorySaved ? "已保存 ✓" : "保存记忆") {
                saveMemory()
            }
            .foregroundStyle(isMemorySaved ? .green : .accentColor)
        } header: {
            Text("长期记忆")
        } footer: {
            Text("内容保存至 ~/.agentgui/memory.md，每次对话开始时自动注入系统提示词。Claude 也可通过 memory_write 工具直接更新记忆。Memory 设置已收敛为单一开关和上下文预算。当前生效行为：\(runtimeEffectSummary)。")
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