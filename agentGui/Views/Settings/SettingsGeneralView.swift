import SwiftUI

struct SettingsGeneralView: View {
    @Bindable var store: SettingsStore
    @Environment(ClaudeService.self) private var claudeService

    var body: some View {
        Form {
            appearanceSection
            codeEditorSection
            aboutSection
        }
        .formStyle(.grouped)
        .navigationTitle("通用")
    }

    private var settings: AppSettings { store.settings }

    private var readiness: LaunchReadinessStatus {
        LaunchReadinessEvaluator.evaluate(settings: settings)
    }

    private var appearanceSection: some View {
        Section("外观") {
            Picker("主题", selection: store.persistedSettingsBinding(
                get: { settings.themeMode },
                userMessage: "主题设置未成功保存",
                set: { settings.themeMode = $0 }
            )) {
                ForEach(ThemeMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
        }
    }

    private var codeEditorSection: some View {
        Section("代码编辑器") {
            Toggle("括号对着色", isOn: store.persistedSettingsBinding(
                get: { settings.isBracketPairColorizationEnabled },
                userMessage: "括号对着色设置未成功保存",
                set: { settings.isBracketPairColorizationEnabled = $0 }
            ))
        }
    }

    private var aboutSection: some View {
        Section("关于") {
            HStack {
                Text("启动状态")
                Spacer()
                Text(readiness.isReadyForFirstMessage ? "可开始" : "需先配置")
                    .foregroundStyle(readiness.isReadyForFirstMessage ? .green : .orange)
            }
            HStack {
                Text("版本")
                Spacer()
                Text("2.0.0")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("AI 服务")
                Spacer()
                Text("Anthropic Claude")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("连接状态")
                Spacer()
                HStack(spacing: 6) {
                    Circle()
                        .fill(claudeService.isConfigured ? .green : .red)
                        .frame(width: 8, height: 8)
                    Text(claudeService.isConfigured ? "已配置" : "未配置")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}