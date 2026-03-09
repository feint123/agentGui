//
//  ThinkingBubbleView.swift
//  agentGui
//

import SwiftUI

/// 折叠式 Extended Thinking 展示视图（类似 Claude.ai 的思考过程气泡）
struct ThinkingBubbleView: View {

    let content: String
    let summaryText: String
    let autoExpanded: Bool

    @State private var isExpanded = false
    @State private var hasManualOverride = false

    init(content: String) {
        self.content = content
        self.summaryText = "推理摘要 · \(content.count) 字"
        self.autoExpanded = false
    }

    init(presentation: ThinkingStepPresentation) {
        self.content = presentation.content
        self.summaryText = presentation.summaryText
        self.autoExpanded = presentation.isExpanded
        _isExpanded = State(initialValue: presentation.isExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded {
                Divider().opacity(0.12)
                thinkingContent
            }
        }
        .background(Color.primary.opacity(0.025))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
        )
        .onChange(of: autoExpanded) { _, newValue in
            if !hasManualOverride {
                isExpanded = newValue
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        Button {
            withAnimation(.spring(duration: 0.25)) {
                hasManualOverride = true
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "brain")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(summaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
        }
        .frame(maxHeight: 180)
    }
}
