import SwiftUI

struct SettingsMemoryGlossaryItem: Identifiable, Equatable {
    let term: String
    let detail: String

    var id: String { term }
}

enum SettingsMemoryGlossary {
    static let defaultItems: [SettingsMemoryGlossaryItem] = [
        SettingsMemoryGlossaryItem(

            term: "Frontier",
            detail: "Frontier 表示当前尚未关闭的关键问题或待验证 claim。只要 frontier 还开着，agent 就不应把对应结论当成已确认事实。"
        ),
        SettingsMemoryGlossaryItem(
            term: "Counterexample",
            detail: "Counterexample 是已经出现过的错误路径、失败模式或反例，用来提醒 agent 不要重复走回头路，并给出替代动作。"
        ),
        SettingsMemoryGlossaryItem(
            term: "Constraint",
            detail: "Constraint 是当前任务的显式边界，例如只读限制、作用域限制、先验证再编辑等规则。它决定 agent 哪些动作可以做、哪些不能做。"
        ),
        SettingsMemoryGlossaryItem(
            term: "Verification Debt",
            detail: "Verification Debt 是已经形成判断、但证据还不充分的部分。它提醒 agent 这些结论需要后续命令、测试或人工确认来偿还。"
        ),
        SettingsMemoryGlossaryItem(
            term: "Bootstrap Prompt",
            detail: "Bootstrap Prompt 是每轮 agent 开始前注入的上下文补丁。启用 Memory 后，系统会把选中的记忆摘要拼进 bootstrap。"
        ),
        SettingsMemoryGlossaryItem(
            term: "Memory 上下文预算",
            detail: "Memory 上下文预算决定每次 bootstrap 最多带入多少条记忆。数值越大，带入的信息越多，但也会占用更多提示词上下文。"
        )
    ]
}

struct SettingsMemoryView: View {
    @Bindable var store: SettingsStore

    var body: some View {
        Form {
            memorySection
            glossarySection
        }
        .formStyle(.grouped)
        .navigationTitle("记忆")
    }

    private var settings: AppSettings { store.settings }

    private var runtimeEffectSummary: String {
        settings.memoryEnabled
            ? "Memory 已启用，记忆摘要会在 bootstrap 时注入"
            : "Memory 已停用，bootstrap 不会注入记忆上下文"
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
        } header: {
            Text("长期记忆")
        } footer: {
            Text("长期记忆通过文件存储层持久化。当前生效行为：\(runtimeEffectSummary)。")
        }
    }

    private var glossarySection: some View {
        Section {
            ForEach(SettingsMemoryGlossary.defaultItems) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.term)
                        .font(.subheadline.weight(.medium))
                    Text(item.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("术语说明")
        } footer: {
            Text("这些术语帮助理解记忆系统的工作方式。")
        }
    }
}