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

    private var memorySection: some View {
        Section {
            Toggle("启用统一记忆运行时", isOn: store.persistedSettingsBinding(
                get: { settings.enableUnifiedMemoryRuntime },
                userMessage: "统一记忆运行时设置未成功保存",
                set: { settings.enableUnifiedMemoryRuntime = $0 }
            ))

            if settings.enableUnifiedMemoryRuntime {
                Stepper(value: store.persistedSettingsBinding(
                    get: { settings.unifiedMemoryContextBudget },
                    userMessage: "统一记忆上下文预算未成功保存",
                    set: { settings.unifiedMemoryContextBudget = $0 }
                ), in: 4...16) {
                    HStack {
                        Text("统一记忆上下文预算")
                        Spacer()
                        Text("\(settings.unifiedMemoryContextBudget)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }

                Toggle("启用记忆治理层", isOn: store.persistedSettingsBinding(
                    get: { settings.enableMemoryGovernance },
                    userMessage: "记忆治理设置未成功保存",
                    set: { settings.enableMemoryGovernance = $0 }
                ))

                Toggle("启用 Admission V2", isOn: store.persistedSettingsBinding(
                    get: { settings.enableAdmissionV2 },
                    userMessage: "Admission V2 设置未成功保存",
                    set: { settings.enableAdmissionV2 = $0 }
                ))

                Toggle("启用 Goal-conditioned Retrieval", isOn: store.persistedSettingsBinding(
                    get: { settings.enableGoalConditionedRetrieval },
                    userMessage: "Goal-conditioned Retrieval 设置未成功保存",
                    set: { settings.enableGoalConditionedRetrieval = $0 }
                ))

                Toggle("启用 Bridge Expansion", isOn: store.persistedSettingsBinding(
                    get: { settings.enableBridgeExpansion },
                    userMessage: "Bridge Expansion 设置未成功保存",
                    set: { settings.enableBridgeExpansion = $0 }
                ))

                Toggle("启用 Lifecycle Manager", isOn: store.persistedSettingsBinding(
                    get: { settings.enableLifecycleManager },
                    userMessage: "Lifecycle Manager 设置未成功保存",
                    set: { settings.enableLifecycleManager = $0 }
                ))

                Toggle("启用 Experience Distillation", isOn: store.persistedSettingsBinding(
                    get: { settings.enableExperienceDistillation },
                    userMessage: "Experience Distillation 设置未成功保存",
                    set: { settings.enableExperienceDistillation = $0 }
                ))

                Toggle("启用统一写路径", isOn: store.persistedSettingsBinding(
                    get: { settings.enableUnifiedMemoryWritePath },
                    userMessage: "统一写路径设置未成功保存",
                    set: { settings.enableUnifiedMemoryWritePath = $0 }
                ))

                Toggle("允许后台记忆巩固", isOn: store.persistedSettingsBinding(
                    get: { settings.enableBackgroundMemoryConsolidation },
                    userMessage: "后台记忆巩固设置未成功保存",
                    set: { settings.enableBackgroundMemoryConsolidation = $0 }
                ))

                Stepper(value: store.persistedSettingsBinding(
                    get: { settings.memoryBackgroundSchedulerIntervalSeconds },
                    userMessage: "后台调度周期未成功保存",
                    set: { settings.memoryBackgroundSchedulerIntervalSeconds = $0 }
                ), in: 5...600, step: 5) {
                    HStack {
                        Text("后台调度周期")
                        Spacer()
                        Text("\(settings.memoryBackgroundSchedulerIntervalSeconds)s")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }

                Toggle("启用 TTL Sweep", isOn: store.persistedSettingsBinding(
                    get: { settings.enableMemoryTTLSweep },
                    userMessage: "TTL Sweep 设置未成功保存",
                    set: { settings.enableMemoryTTLSweep = $0 }
                ))

                Stepper(value: store.persistedSettingsBinding(
                    get: { settings.memoryTTLSweepIntervalSeconds },
                    userMessage: "TTL Sweep 周期未成功保存",
                    set: { settings.memoryTTLSweepIntervalSeconds = $0 }
                ), in: 60...3600, step: 60) {
                    HStack {
                        Text("TTL Sweep 周期")
                        Spacer()
                        Text("\(settings.memoryTTLSweepIntervalSeconds)s")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("待确认阈值")
                        Spacer()
                        Text(String(format: "%.0f%%", settings.memoryConfirmationThreshold * 100))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(
                        value: store.persistedSettingsBinding(
                            get: { settings.memoryConfirmationThreshold },
                            userMessage: "待确认阈值未成功保存",
                            set: { settings.memoryConfirmationThreshold = $0 }
                        ),
                        in: 0.4...0.95,
                        step: 0.05
                    )
                }

                NavigationLink(value: SettingsDetailRoute.memoryGovernance) {
                    HStack(spacing: 12) {
                        Image(systemName: "shield.lefthalf.filled")
                            .font(.title3)
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 34, height: 34)
                            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                        VStack(alignment: .leading, spacing: 3) {
                            Text("打开记忆治理面板")
                                .foregroundStyle(.primary)
                            Text("查看待确认写入、冲突替代记录与 TTL Sweep 状态")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

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
            Text("内容保存至 ~/.agentgui/memory.md，每次对话开始时自动注入系统提示词。Claude 也可通过 memory_write 工具直接更新记忆。统一记忆运行时用于把 TaskMemory 与统一存储记录组装成单一读视图，治理层用于限制低置信度写入。下方开关用于逐步 rollout admission v2、goal-conditioned retrieval、bridge expansion、lifecycle manager 和 experience distillation。")
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