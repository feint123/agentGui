//
//  SubagentTimelineView.swift
//  agentGui
//
//  Renders the agentic loop rounds produced by a subagent (stored on a ToolCall record).
//  Similar to AgentStepTimelineView but takes [AgentRound] directly rather than a Message.
//

import SwiftUI

/// 子代理时间线视图 — 将子代理执行的所有 AgentRound 渲染为紧凑的垂直时间线
struct SubagentTimelineView: View {

    let rounds: [AgentRound]

    private var sortedRounds: [AgentRound] {
        rounds.sorted { $0.roundIndex < $1.roundIndex }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(sortedRounds.enumerated()), id: \.element.id) { index, round in
                SubagentRoundRow(
                    round: round,
                    isLast: index == sortedRounds.count - 1
                )
                .equatable()
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .move(edge: .top)),
                    removal: .opacity
                ))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: sortedRounds.count)
    }
}

// MARK: - SubagentRoundRow

private struct SubagentRoundRow: View, Equatable {

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.round.id == rhs.round.id &&
        lhs.isLast == rhs.isLast &&
        lhs.round.hasThinking == rhs.round.hasThinking &&
        lhs.round.text == rhs.round.text &&
        lhs.round.thinkingContent == rhs.round.thinkingContent &&
        lhs.round.sortedToolCalls.count == rhs.round.sortedToolCalls.count
    }

    let round: AgentRound
    let isLast: Bool

    var body: some View {
        roundContent
    }

    // MARK: Round Content

    private var roundContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Thinking block (collapsed by default in subagent context)
            if let thinking = round.thinkingContent, !thinking.isEmpty {
                ThinkingBubbleView(content: thinking)
            }

            // Text output
            if let text = round.text, !text.isEmpty {
                MarkdownMessageView(text: text)
            }

            // Tool calls
            let calls = round.sortedToolCalls
            if !calls.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(calls) { toolCall in
                        ToolCallBubbleView(toolCall: toolCall)
                    }
                }
            }
        }
        .padding(.bottom, isLast ? 2 : 12)
    }
}
