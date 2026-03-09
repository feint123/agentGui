import SwiftUI

struct ToolCallDetailContentView: View {
    let toolCall: ToolCall
    let row: ToolCallRowPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch row.style {
            case .read:
                readDetail
            case .edit:
                editDetail
            case .execute:
                executeDetail
            case .search, .fetch:
                searchDetail
            case .askUser:
                askUserDetail
            case .subagent, .other:
                fallbackDetail
            }
        }
    }

    @ViewBuilder
    private var readDetail: some View {
        if let path = toolCall.filePath {
            detailTextBlock(label: "路径", text: path, monospaced: false)
        }
        if let output = row.detailText, !output.isEmpty {
            detailTextBlock(label: "摘要", text: output, monospaced: false, lineLimit: 6)
        }
    }

    @ViewBuilder
    private var editDetail: some View {
        if let path = toolCall.filePath {
            detailTextBlock(label: "路径", text: path, monospaced: false)
        }
        if let diff = toolCall.diffContent, !diff.isEmpty {
            detailTextBlock(label: "变更", text: diff, monospaced: true, maxHeight: 180)
        }
    }

    @ViewBuilder
    private var executeDetail: some View {
        detailTextBlock(label: "命令", text: toolCall.title ?? toolCall.kind.displayName, monospaced: true)
        if let output = row.detailText, !output.isEmpty {
            detailTextBlock(label: toolCall.status == .failed ? "错误输出" : "输出", text: output, monospaced: true, maxHeight: 180)
        }
    }

    @ViewBuilder
    private var searchDetail: some View {
        if let tertiary = row.tertiaryText, !tertiary.isEmpty {
            detailTextBlock(label: "目标", text: tertiary, monospaced: false)
        }
        if let output = row.detailText, !output.isEmpty {
            detailTextBlock(label: "结果", text: output, monospaced: false, maxHeight: 160)
        }
    }

    @ViewBuilder
    private var askUserDetail: some View {
        if let output = row.detailText, !output.isEmpty {
            detailTextBlock(label: "回答记录", text: output, monospaced: false, maxHeight: 160)
        }
    }

    @ViewBuilder
    private var fallbackDetail: some View {
        if let output = row.detailText, !output.isEmpty {
            detailTextBlock(label: "详情", text: output, monospaced: false, maxHeight: 160)
        }
    }

    private func detailTextBlock(
        label: String,
        text: String,
        monospaced: Bool,
        lineLimit: Int? = nil,
        maxHeight: CGFloat? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            ScrollView(.vertical, showsIndicators: maxHeight != nil) {
                Text(text)
                    .font(monospaced ? .system(.caption2, design: .monospaced) : .caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(lineLimit)
                    .padding(8)
            }
            .frame(maxHeight: maxHeight)
            .background(Color.primary.opacity(0.03))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}