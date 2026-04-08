import SwiftUI

struct AgentMessageResultBlockView: View {
    let presentation: ResultStepPresentation
    /// 可见字符预算。nil 表示展示全量（非 streaming 时）。
    var charBudget: Int? = nil

    /// streaming 状态派生属性：charBudget 非 nil 时视为正在流式输出。
    var isStreaming: Bool { charBudget != nil }

    private var visibleText: String {
        guard let budget = charBudget, budget < presentation.text.count else {
            return presentation.text
        }
        return String(presentation.text.prefix(budget))
    }

    var body: some View {
        Group {
            if presentation.isError {
                Label {
                    Text(presentation.text)
                        .textSelection(.enabled)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.body)
                .foregroundStyle(.red)
            } else {
                MarkdownMessageView(text: visibleText, showsCursor: isStreaming)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(presentation.isError ? Color.red.opacity(0.06) : Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(presentation.isError ? Color.red.opacity(0.18) : Color.primary.opacity(0.05), lineWidth: 1)
        )
    }
}