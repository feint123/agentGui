import SwiftUI

struct SettingsIntelligenceView: View {
    @Bindable var store: SettingsStore

    var body: some View {
        Form {
            extendedThinkingSection
            ghostTextSection
        }
        .formStyle(.grouped)
        .navigationTitle("智能")
    }

    private var settings: AppSettings { store.settings }

    private var extendedThinkingSection: some View {
        Section {
            Toggle("启用 Extended Thinking（Claude 3.7 及更高版本）", isOn: store.persistedSettingsBinding(
                get: { settings.enableExtendedThinking },
                userMessage: "Extended Thinking 设置未成功保存",
                set: { settings.enableExtendedThinking = $0 }
            ))

            if settings.enableExtendedThinking {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Token 预算")
                        Spacer()
                        Text("\(settings.extendedThinkingBudget)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: store.persistedSettingsBinding(
                            get: { Double(settings.extendedThinkingBudget) },
                            userMessage: "Thinking 预算未成功保存",
                            set: { settings.extendedThinkingBudget = Int($0) }
                        ),
                        in: 1000...32000,
                        step: 1000
                    )
                }
            }
        } header: {
            Text("Extended Thinking")
        } footer: {
            Text("开启后，Claude 3.7 及更高版本会在回答前进行深度推理，结果将以折叠气泡展示。")
        }
    }

    private var ghostTextSection: some View {
        Section {
            Toggle("启用 AI Ghost Text", isOn: store.persistedSettingsBinding(
                get: { settings.enableGhostText },
                userMessage: "Ghost Text 设置未成功保存",
                set: { settings.enableGhostText = $0 }
            ))

            if settings.enableGhostText {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("防抖延迟（毫秒）")
                        Spacer()
                        Text("\(settings.ghostTextDebounceMs) ms")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: store.persistedSettingsBinding(
                            get: { Double(settings.ghostTextDebounceMs) },
                            userMessage: "Ghost Text 防抖设置未成功保存",
                            set: { settings.ghostTextDebounceMs = Int($0) }
                        ),
                        in: 100...2000,
                        step: 100
                    )
                }
            }
        } header: {
            Text("AI Ghost Text")
        } footer: {
            Text("在代码编辑器中实时显示 AI 建议的补全内容。按 Tab 接受全部，⌘→ 接受下一个词，Esc 取消。注意：此功能会将光标附近的代码片段发送至 Anthropic API。")
        }
    }

}