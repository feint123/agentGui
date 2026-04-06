import SwiftUI

// MARK: - RewindConfirmationSheet

/// R-D1 P0 Stub: 确认回滚操作的 Sheet。
///
/// 此处为最小可用实现，提供三个操作选项：
///   1. 恢复对话和文件（default，当 canRestoreFiles 为 true 时）
///   2. 仅恢复对话
///   3. 取消
///
/// R-D2 计划将提供完整版本（含文件 diff 预览、统计数字和更丰富的 UI）。
/// 当 R-D2 完成后，此文件将被整体替换，调用方（MessageRewindSelectorView）无需修改。
struct RewindConfirmationSheet: View {

    @Environment(\.dismiss) private var dismiss

    let pending: MessageRewindSelectorViewModel.PendingConfirmation
    let onExecute: (RewindOption) async -> Void
    let onCancel: () -> Void

    @State private var isExecuting = false

    private var canRestoreFiles: Bool {
        pending.checkpoint != nil && !pending.diffStats.filesChanged.isEmpty
    }

    private var messagePreview: String {
        let raw = pending.message.textContent ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 80 else { return trimmed.isEmpty ? "（空消息）" : trimmed }
        return String(trimmed.prefix(80)) + "…"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 标题
            Text("确认回滚")
                .font(.headline)

            // 目标消息预览
            VStack(alignment: .leading, spacing: 4) {
                Text("回滚到此消息之前：")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(messagePreview)
                    .font(.body)
                    .padding(8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }

            // 文件变化摘要（若有）
            if canRestoreFiles {
                VStack(alignment: .leading, spacing: 4) {
                    Text("文件变化")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("\(pending.diffStats.filesChanged.count) 个文件将被恢复")
                        .font(.body)
                }
            }

            Divider()

            // 操作按钮
            VStack(spacing: 8) {
                if canRestoreFiles {
                    rewindButton(label: "恢复对话和文件", option: .conversationAndFiles, isPrimary: true)
                }
                rewindButton(label: "仅恢复对话", option: .conversationOnly, isPrimary: !canRestoreFiles)
                if canRestoreFiles {
                    rewindButton(label: "仅恢复文件", option: .filesOnly, isPrimary: false)
                }
                Button("取消") {
                    onCancel()
                    dismiss()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(isExecuting)
            }
        }
        .padding(20)
        .frame(minWidth: 320, maxWidth: 480)
    }

    @ViewBuilder
    private func rewindButton(label: String, option: RewindOption, isPrimary: Bool) -> some View {
        if isPrimary {
            Button {
                Task {
                    isExecuting = true
                    await onExecute(option)
                    isExecuting = false
                    dismiss()
                }
            } label: {
                rewindButtonLabel(label: label)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isExecuting)
        } else {
            Button {
                Task {
                    isExecuting = true
                    await onExecute(option)
                    isExecuting = false
                    dismiss()
                }
            } label: {
                rewindButtonLabel(label: label)
            }
            .buttonStyle(.bordered)
            .disabled(isExecuting)
        }
    }

    @ViewBuilder
    private func rewindButtonLabel(label: String) -> some View {
        HStack {
            if isExecuting {
                ProgressView()
                    .scaleEffect(0.7)
                    .frame(width: 16, height: 16)
            }
            Text(label)
                .frame(maxWidth: .infinity)
        }
    }
}
