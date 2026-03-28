import Foundation
import SwiftUI

struct ACPProviderEditorView: View {
    @Environment(\.dismiss) private var dismiss

    @Bindable var viewModel: ACPProviderSettingsEditorViewModel

    let onSaved: () throws -> Void
    let onDelete: () -> Bool

    var body: some View {
        Form {
            if let saveProgressMessage = viewModel.saveProgressMessage {
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text(saveProgressMessage)
                    }
                } footer: {
                    Text("启用中的 Provider 会先解析可执行文件并执行 initialize 探测，首次校验可能需要几秒。")
                }
            }

            if let errorMessage = viewModel.errorMessage, !errorMessage.isEmpty {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                } header: {
                    Text("保存失败")
                }
            }

            Section {
                overviewRow("名称", value: resolvedDisplayName)
                overviewRow("启用状态", value: viewModel.isEnabled ? "已启用" : "已停用")
                if let snapshot = viewModel.lastValidationSnapshot {
                    overviewRow("最近校验", value: snapshot.status.rawValue)
                    if let verifiedAt = snapshot.verifiedAt {
                        overviewRow("校验时间", value: verifiedAt.formatted(date: .abbreviated, time: .shortened))
                    }
                }
            } header: {
                Text("概览")
            }

            Section("基本信息") {
                TextField("显示名称", text: $viewModel.displayName)
                TextField("可执行文件路径", text: $viewModel.executablePath)
                Toggle("启用此 Provider", isOn: $viewModel.isEnabled)
            }

            Section {
                TextField("例如: --mode fast --sandbox workspace", text: $viewModel.argumentsText)
            } header: {
                Text("启动参数")
            } footer: {
                Text("多个参数用空格分隔；保存启用 Provider 时会按这些参数执行 initialize 探测。")
            }

            if let snapshot = viewModel.lastValidationSnapshot {
                Section("最近验证") {
                    LabeledContent("状态", value: snapshot.status.rawValue)
                    if let agentName = snapshot.agentInfo?.title ?? snapshot.agentInfo?.name {
                        LabeledContent("Agent", value: agentName)
                    }
                    if let version = snapshot.agentInfo?.version,
                       !version.isEmpty {
                        LabeledContent("版本", value: version)
                    }
                    if !snapshot.resolvedExecutablePath.isEmpty {
                        LabeledContent("解析路径", value: snapshot.resolvedExecutablePath)
                    }
                    if !snapshot.message.isEmpty {
                        LabeledContent("消息", value: snapshot.message)
                    }
                }
            }

            if !viewModel.capabilityRows.isEmpty {
                Section {
                    ForEach(viewModel.capabilityRows) { capability in
                        LabeledContent(capability.title, value: capability.value)
                    }
                } header: {
                    Text("Agent Capabilities")
                } footer: {
                    Text("这些能力来自最近一次 initialize 返回，用于判断 Provider 是否支持会话恢复、多模态输入和 MCP 连接。")
                }
            }

            if !viewModel.authMethodNames.isEmpty {
                Section("认证方式") {
                    ForEach(viewModel.authMethodNames, id: \.self) { authMethod in
                        Text(authMethod)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(viewModel.navigationTitle)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                if viewModel.canDelete {
                    Button("删除", role: .destructive) {
                        if onDelete() {
                            dismiss()
                        }
                    }
                    .disabled(viewModel.isSaving)
                }
            }

            ToolbarItem(placement: .primaryAction) {
                Button("保存") {
                    Task {
                        if await viewModel.save(reloading: onSaved) {
                            dismiss()
                        }
                    }
                }
                .disabled(viewModel.isSaving)
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var resolvedDisplayName: String {
        let trimmedName = viewModel.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty {
            return trimmedName
        }

        let trimmedExecutable = viewModel.executablePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedExecutable.isEmpty {
            return "未命名 Provider"
        }

        return URL(fileURLWithPath: trimmedExecutable).lastPathComponent
    }

    private func overviewRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}