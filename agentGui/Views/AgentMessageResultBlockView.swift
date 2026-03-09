import SwiftUI

struct AgentMessageResultBlockView: View {
    let presentation: ResultStepPresentation

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
                MarkdownMessageView(text: presentation.text)
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