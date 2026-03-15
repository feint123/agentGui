import SwiftUI

struct SettingsMemoryGlossaryItem: Identifiable, Equatable {
    let term: String
    let detail: String

    var id: String { term }
}

enum SettingsMemoryGlossary {
    static let defaultItems: [SettingsMemoryGlossaryItem] = [
        SettingsMemoryGlossaryItem(
            term: "RMS",
            detail: "RMS 是当前 agent 任务的运行时记忆模型，用来把任务目标、风险、边界和未验证判断整理成结构化状态，而不是把零散聊天记录直接塞回提示词。"
        ),
        SettingsMemoryGlossaryItem(
            term: "RMS State",
            detail: "RMS State 是某一轮任务最新的结构化快照，绑定到当前 session 和 task。它会记录摘要、frontiers、constraints、counterexamples、verification debt 以及建议动作。"
        ),
        SettingsMemoryGlossaryItem(
            term: "RMSInsight",
            detail: "RMSInsight 是从历史执行和反思中沉淀出的长期记忆条目。相比 task-bound 的 RMS State，它更稳定，可在后续 bootstrap 时按需检索注入。"
        ),
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
            detail: "Bootstrap Prompt 是每轮 agent 开始前注入的上下文补丁。启用 Memory 后，系统会把当前 RMS State 和选中的 RMSInsight 摘要拼进 bootstrap，而不是直接拼接 memory.md。"
        ),
        SettingsMemoryGlossaryItem(
            term: "Memory 上下文预算",
            detail: "Memory 上下文预算决定每次 bootstrap 最多带入多少条 RMSInsight。数值越大，带入的信息越多，但也会占用更多提示词上下文。"
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
        } header: {
            Text("长期记忆")
        } footer: {
            Text("长期记忆已收敛为 RMSInsight 持久层，不再通过 memory.md 直接拼接进系统提示词。当前保留的产品设置只有 memoryEnabled 与 memoryContextBudget。当前生效行为：\(runtimeEffectSummary)。")
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
            Text("RMS 术语说明")
        } footer: {
            Text("如果你把 RMS 理解为“当前任务如何思考、哪些结论还没证实、哪些经验可以复用”的结构化记忆层，设置页里的开关和预算就会更容易理解。")
        }
    }
}