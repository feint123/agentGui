import SwiftUI

// MARK: - RewindConfirmationSheet

/// R-D2：确认回滚操作的 Sheet。
///
/// 展示三个核心信息区域：
///   1. 目标消息预览
///   2. 回滚影响摘要（截断消息数 + 文件 diff 统计）
///   3. 分类文件列表（新增 / 删除 / 修改）
///
/// 并提供三个操作选项（当 canRestoreFiles 时）：
///   - 恢复对话和文件（默认，高亮）
///   - 仅恢复对话
///   - 仅恢复文件
/// 或仅一个选项（无文件变化时）：
///   - 仅恢复对话（默认）
///
/// ## 调用方合约
/// 初始化签名不变：`init(pending:onExecute:onCancel:)`；
/// 所有 diff 数据在 Sheet 打开前已由 ViewModel 预计算完毕，Sheet 本身无异步加载。
struct RewindConfirmationSheet: View {

    @Environment(\.dismiss) private var dismiss

    let pending: MessageRewindSelectorViewModel.PendingConfirmation
    let onExecute: (RewindOption) async -> Void
    let onCancel: () -> Void

    @State private var isExecuting = false

    // MARK: - Testable Computed Properties

    /// 是否可以恢复文件（checkpoint 存在且有文件变化）
    var canRestoreFiles: Bool {
        pending.checkpoint != nil && !pending.diffStats.filesChanged.isEmpty
    }

    /// 消息预览文本（最多 80 字符）
    var messagePreview: String {
        let raw = pending.message.textContent ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "（空消息）" }
        guard trimmed.count > 80 else { return trimmed }
        return String(trimmed.prefix(80)) + "…"
    }

    /// diff 统计摘要行，如 "+42 -18"；若均为 0 则返回空字符串
    var diffSummaryLine: String {
        let s = pending.diffStats
        guard s.totalInsertions > 0 || s.totalDeletions > 0 else { return "" }
        return "+\(s.totalInsertions) -\(s.totalDeletions)"
    }

    /// 截断说明文字，如 "将移除 5 条消息（含 12 次工具调用）"
    var truncationDescription: String {
        let msgCount = pending.messagesAfterCount
        let toolCount = pending.toolCallsAfterCount
        if toolCount > 0 {
            return "将移除 \(msgCount) 条消息（含 \(toolCount) 次工具调用）"
        } else {
            return "将移除 \(msgCount) 条消息"
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    messagePreviewSection
                    impactSummarySection
                    if canRestoreFiles {
                        fileChangesSection
                    }
                }
                .padding(20)
            }
            .frame(maxHeight: 340)
            Divider()
            actionSection
        }
        .frame(minWidth: 380, maxWidth: 520)
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack {
            Label("确认回滚", systemImage: "arrow.uturn.backward.circle")
                .font(.headline)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Message Preview Section

    private var messagePreviewSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("回滚到此消息之前")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Text(messagePreview)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityIdentifier("rewind.confirmation.messagePreview")
        }
    }

    // MARK: - Impact Summary Section

    private var impactSummarySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("回滚影响")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            // 消息截断行
            HStack(spacing: 8) {
                Image(systemName: "message.badge.minus")
                    .foregroundStyle(.orange)
                    .frame(width: 16)
                Text(truncationDescription)
                    .font(.callout)
                    .accessibilityIdentifier("rewind.confirmation.truncationDescription")
            }

            // 文件变化行（若有）
            if canRestoreFiles && !diffSummaryLine.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "doc.badge.arrow.up")
                        .foregroundStyle(.blue)
                        .frame(width: 16)
                    HStack(spacing: 4) {
                        Text("\(pending.diffStats.filesChanged.count) 个文件")
                            .font(.callout)
                        Text(diffSummaryLine)
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("rewind.confirmation.diffSummaryLine")
                    }
                }
            }
        }
    }

    // MARK: - File Changes Section

    private var fileChangesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("文件变化")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                // 新增文件（回滚后将被删除）
                ForEach(pending.diffStats.addedFiles, id: \.self) { path in
                    fileRow(path: path, icon: "doc.badge.plus", iconColor: .orange,
                            label: "将被删除（新增文件）")
                }
                // 已删文件（回滚后将被恢复）
                ForEach(pending.diffStats.deletedFiles, id: \.self) { path in
                    fileRow(path: path, icon: "doc.badge.minus", iconColor: .green,
                            label: "将被恢复（已删文件）")
                }
                // 修改文件（回滚后内容还原）
                ForEach(pending.diffStats.modifiedFiles, id: \.self) { path in
                    fileRow(path: path, icon: "doc.badge.arrow.up", iconColor: .blue,
                            label: "内容将还原")
                }
            }
        }
    }

    @ViewBuilder
    private func fileRow(path: String, icon: String, iconColor: Color, label: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(iconColor)
                .frame(width: 14)
                .accessibilityHidden(true)
            Text(URL(fileURLWithPath: path).lastPathComponent)
                .font(.callout.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .help(path)  // hover 显示完整路径
            Spacer()
        }
        .accessibilityLabel("\(label)：\(path)")
    }

    // MARK: - Action Section

    private var actionSection: some View {
        VStack(spacing: 8) {
            if canRestoreFiles {
                executeButton(
                    label: "恢复对话和文件",
                    subtitle: "截断对话 · 还原文件系统",
                    option: .conversationAndFiles,
                    isPrimary: true,
                    identifier: "rewind.action.conversationAndFiles"
                )
            }
            executeButton(
                label: "仅恢复对话",
                subtitle: "截断对话，不改动文件",
                option: .conversationOnly,
                isPrimary: !canRestoreFiles,
                identifier: "rewind.action.conversationOnly"
            )
            if canRestoreFiles {
                executeButton(
                    label: "仅恢复文件",
                    subtitle: "还原文件系统，保留对话记录",
                    option: .filesOnly,
                    isPrimary: false,
                    identifier: "rewind.action.filesOnly"
                )
            }
            Button {
                onCancel()
                dismiss()
            } label: {
                Text("取消")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(isExecuting)
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("rewind.action.cancel")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private func executeButton(
        label: String,
        subtitle: String,
        option: RewindOption,
        isPrimary: Bool,
        identifier: String
    ) -> some View {
        let buttonLabel = HStack(spacing: 8) {
            if isExecuting {
                ProgressView()
                    .scaleEffect(0.7)
                    .frame(width: 16, height: 16)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.body.weight(.medium))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(isPrimary ? .white.opacity(0.7) : .secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)

        if isPrimary {
            Button {
                Task {
                    isExecuting = true
                    await onExecute(option)
                    isExecuting = false
                    dismiss()
                }
            } label: {
                buttonLabel
            }
            .buttonStyle(.borderedProminent)
            .disabled(isExecuting)
            .accessibilityIdentifier(identifier)
        } else {
            Button {
                Task {
                    isExecuting = true
                    await onExecute(option)
                    isExecuting = false
                    dismiss()
                }
            } label: {
                buttonLabel
            }
            .buttonStyle(.bordered)
            .disabled(isExecuting)
            .accessibilityIdentifier(identifier)
        }
    }
}
