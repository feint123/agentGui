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
            ForEach(sortedRounds.indices, id: \.self) { index in
                let round = sortedRounds[index]
                RoundTimelineRow(
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

// MARK: - RoundTimelineRow

private struct RoundTimelineRow: View, Equatable {

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
        // Reflection result takes priority over thinking / tool colour
        if let confidence = round.reflectionConfidence {
            return confidence >= 0.7 ? .green.opacity(0.75) : .orange.opacity(0.75)
        }
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

            // Reflection summary (shown when reflection has run for this round)
            if round.reflectionConfidence != nil {
                ReflectionSummaryRow(round: round)
            }
        }
        .padding(.leading, 10)
        .padding(.bottom, isLast ? 4 : 16)
    }
}

// MARK: - ReflectionSummaryRow

private struct ReflectionSummaryRow: View {

    let round: AgentRound

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            // Header with confidence gauge
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(badgeColor)
                Text("反思")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let confidence = round.reflectionConfidence {
                    Text(String(format: "置信度 %.0f%%", confidence * 100))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.secondary)
                    ProgressView(value: confidence)
                        .tint(badgeColor)
                        .frame(width: 56)
                        .scaleEffect(y: 0.8)
                }
            }

            // Concerns list
            if !round.reflectionConcerns.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(round.reflectionConcerns, id: \.self) { concern in
                        Label(concern, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                            .lineLimit(3)
                    }
                }
            }

            // Suggested fixes
            if !round.reflectionSuggestedFixes.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(round.reflectionSuggestedFixes, id: \.self) { fix in
                        Label(fix, systemImage: "wrench.and.screwdriver")
                            .font(.system(size: 11))
                            .foregroundStyle(.blue)
                            .lineLimit(3)
                    }
                }
            }

            // Retry badge
            if round.reflectionShouldRetry {
                Label("已触发重试", systemImage: "arrow.clockwise")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.orange)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(badgeColor.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(badgeColor.opacity(0.25), lineWidth: 1)
                )
        )
    }

    private var badgeColor: Color {
        guard let confidence = round.reflectionConfidence else { return .secondary }
        return confidence >= 0.7 ? .green : .orange
    }
}
