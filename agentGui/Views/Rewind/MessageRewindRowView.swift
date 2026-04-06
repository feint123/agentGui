import SwiftUI

/// R-D1: 历史消息选择器中的单行视图。
/// 展示消息文本预览（前 60 字符）、相对时间和文件变化徽标。
struct MessageRewindRowView: View {

    let message: Message
    let hasFileChanges: Bool

    private var previewText: String {
        let raw = message.textContent ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 60 else { return trimmed.isEmpty ? "（空消息）" : trimmed }
        return String(trimmed.prefix(60)) + "…"
    }

    private var relativeTimeText: String {
        message.timestamp.formatted(.relative(presentation: .named))
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(previewText)
                    .font(.body)
                    .lineLimit(2)
                    .foregroundStyle(.primary)
                Text(relativeTimeText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if hasFileChanges {
                Label("含文件变化", systemImage: "doc.badge.clock")
                    .labelStyle(.iconOnly)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help("此消息之后有文件被修改，回滚将恢复这些文件")
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityLabel("回滚到：\(previewText)，\(relativeTimeText)")
    }
}
