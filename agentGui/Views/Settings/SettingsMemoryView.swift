import SwiftUI

struct SettingsMemoryView: View {
    @Bindable var store: SettingsStore

    var body: some View {
        Form {
            memorySection
        }
        .formStyle(.grouped)
        .navigationTitle("记忆")
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

            VStack(alignment: .leading, spacing: 10) {
                Label("RMS 面板已改为 task-bound 入口", systemImage: "brain")
                    .font(.headline)
                Text("当前会话的 RMS 状态需要从聊天界面打开，避免设置页在没有 session 上下文时落回空面板或错误语义。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
        } header: {
            Text("长期记忆")
        } footer: {
            Text("长期记忆已收敛为 RMSInsight 持久层，不再通过 memory.md 直接拼接进系统提示词。当前保留的产品设置只有 memoryEnabled 与 memoryContextBudget。当前生效行为：\(runtimeEffectSummary)。")
        }
    }
}