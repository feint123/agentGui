//
//  ThinkingBubbleView.swift
//  agentGui
//

import SwiftUI

/// 折叠式 Extended Thinking 展示视图（类似 Claude.ai 的思考过程气泡）
struct ThinkingBubbleView: View {

    let content: String

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded {
                Divider().opacity(0.3)
                thinkingContent
            }
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.purple.opacity(0.2), lineWidth: 1)
        )
    }

    // MARK: - Header

    private var header: some View {
        Button {
            withAnimation(.spring(duration: 0.25)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "brain")
                    .font(.caption2)
                    .foregroundStyle(.purple.opacity(0.8))
                Text("思考过程")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.purple.opacity(0.9))
                Text("·  \(wordCount) 字")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 4)
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Content

    private var thinkingContent: some View {
        ScrollView(.vertical, showsIndicators: true) {
            Text(content)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .frame(maxHeight: 280)
    }

    private var wordCount: Int {
        content.count
    }
}
