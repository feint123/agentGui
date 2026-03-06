//
//  AgentStepTimelineView.swift
//  agentGui
//

import SwiftUI

/// 将 agent Message 的所有 AgentRound 渲染为垂直时间线。
/// 每轮（round）是一个分组，轮内按序展示：thinking → 文本 → 工具调用。
struct AgentStepTimelineView: View {

    let message: Message

    private var sortedRounds: [AgentRound] {
        message.agentRounds.sorted { $0.roundIndex < $1.roundIndex }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(sortedRounds.enumerated()), id: \.element.id) { index, round in
                RoundTimelineRow(
                    round: round,
                    isLast: index == sortedRounds.count - 1
                )
            }
        }
    }
}

// MARK: - RoundTimelineRow

private struct RoundTimelineRow: View {

    let round: AgentRound
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Left timeline track
            timelineTrack
            // Content steps for this round
            roundContent
        }
    }

    // MARK: - Timeline Track

    private var timelineTrack: some View {
        VStack(spacing: 0) {
            Circle()
                .fill(roundNodeColor)
                .frame(width: 8, height: 8)
                .padding(.top, 6)
            if !isLast {
                Rectangle()
                    .fill(Color.primary.opacity(0.12))
                    .frame(width: 1)
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(width: 18)
        .padding(.leading, 6)
    }

    private var roundNodeColor: Color {
        if round.hasThinking { return .purple.opacity(0.7) }
        if !round.sortedToolCalls.isEmpty { return .blue.opacity(0.7) }
        return Color.primary.opacity(0.3)
    }

    // MARK: - Round Content

    private var roundContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Thinking block
            if let thinking = round.thinkingContent, !thinking.isEmpty {
                ThinkingBubbleView(content: thinking)
            }

            // Text content for this round
            if let text = round.text, !text.isEmpty {
                MarkdownMessageView(text: text)
            }

            // Tool calls for this round
            let calls = round.sortedToolCalls
            if !calls.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(calls) { toolCall in
                        ToolCallBubbleView(toolCall: toolCall)
                    }
                }
            }
        }
        .padding(.leading, 10)
        .padding(.bottom, isLast ? 4 : 16)
    }
}
