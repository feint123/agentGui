import SwiftUI

struct SettingsIntelligenceView: View {
    @Bindable var store: SettingsStore

    var body: some View {
        Form {
            extendedThinkingSection
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

}