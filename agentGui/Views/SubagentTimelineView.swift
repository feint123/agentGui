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
            ForEach(sortedRounds.indices, id: \.self) { index in
                let round = sortedRounds[index]
                SubagentRoundRow(
                    round: round,
                    isLast: index == sortedRounds.count - 1
                )
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
        lhs.round.hasThinking == rhs.round.hasThinking &&
        lhs.round.sortedToolCalls.count == rhs.round.sortedToolCalls.count &&
        lhs.isLast == rhs.isLast
    }

    let round: AgentRound
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            timelineTrack
            roundContent
        }
    }

    // MARK: Timeline Track

    private var timelineTrack: some View {
        VStack(spacing: 0) {
            Circle()
                .fill(roundNodeColor)
                .frame(width: 6, height: 6)
                .padding(.top, 6)
            if !isLast {
                Rectangle()
                    .fill(Color.primary.opacity(0.10))
                    .frame(width: 1)
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(width: 14)
        .padding(.leading, 4)
    }

    private var roundNodeColor: Color {
        if round.hasThinking { return .purple.opacity(0.6) }
        if !round.sortedToolCalls.isEmpty { return .blue.opacity(0.6) }
        return Color.primary.opacity(0.25)
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
        .padding(.leading, 8)
        .padding(.bottom, isLast ? 2 : 12)
    }
}
